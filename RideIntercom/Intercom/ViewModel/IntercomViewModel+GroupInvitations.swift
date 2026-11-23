import CryptoKit
import Foundation

extension IntercomViewModel {
    func contactGroupAttachment(for groupID: UUID) throws -> ContactGroupInvitation {
        guard canShareGroup(groupID), let group = groups.first(where: { $0.id == groupID && $0.kind == .group }),
              let key = try credential(for: group) else { throw ContactInvitationError.unavailable }
        return .init(id: group.id, name: group.name, secret: key.secret)
    }

    /// Called only by explicit save. Native sharing is a later, separately cancellable operation.
    func saveGroupInvitations(
        groupID: UUID, creating: Bool, name: String, selected: Set<UUID>, newPeople: [GroupInvitationDraft]
    ) -> UUID? {
        guard canEditSavedGroups, requireGroupAccess(), !newPeople.isEmpty else { return nil }
        groupErrorMessage = nil
        do {
            if let saved = groups.first(where: { $0.id == groupID }), newPeople.allSatisfy({ draft in
                contactPerson(draft.id)?.resolvedDisplayName == draft.resolvedName
                    && contactPersonInvitations(draft.id).contains {
                        $0.invitedGroupID == groupID
                            && ($0.state == .pending || $0.state == .confirmed || $0.state == .expired)
                    }
            }) {
                if creating { selectGroup(saved) }
                return groupID
            }
            guard selected.isSubset(of: Set(availableUsers(for: creating ? nil : groupID).map(\.id))),
                  let added = membersForSavedUsers(selected) else { return nil }
            let (group, key) = try groupForInvitationSelection(
                groupID: groupID, creating: creating, name: name, adding: added
            )
            let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID)
            let target = ContactGroupInvitation(id: group.id, name: group.name, secret: key.secret)
            let invitees = try newPeople.map { draft in
                (person: draft.person, token: try ContactInvitationSession.makeToken(
                    authority: invitationAuthority, signer: signer, displayName: localMemberIdentity.displayName,
                    now: callAccessNow().timeIntervalSince1970, invitedGroup: target
                ))
            }
            try groupRepository.saveGroupInvitationSelection(
                group, credential: key, invitees: invitees, now: callAccessNow().timeIntervalSince1970,
                existingMembers: (selected, groupDeliveryRecords(for: selected, groupID: groupID))
            )
            if groups.contains(where: { $0.id == groupID }) {
                refreshStoredAccountCall(groupID)
            } else if let saved = groupRepository.storedGroup(groupID) {
                groups.insert(saved, at: 0)
            }
            refreshGroupStorageStatus()
            if creating, let saved = groups.first(where: { $0.id == groupID }) { selectGroup(saved) }
            requestGroupDeliverySync(.localChange)
            return groupID
        } catch {
            reportGroupStorageError(error)
            if groupErrorMessage == nil { groupErrorMessage = "Could not save these invitations. Try again." }
            return nil
        }
    }

    private func groupForInvitationSelection(
        groupID: UUID, creating: Bool, name: String, adding members: [GroupMember]
    ) throws -> (IntercomGroup, GroupAccessCredential) {
        if creating {
            guard !groups.contains(where: { $0.id == groupID }), IntercomGroup.isValidName(name), !name.contains("|")
            else { throw GroupStorageError.invalidUpdate }
            let local = GroupMember(id: localMemberIdentity.memberID, displayName: localMemberIdentity.displayName)
            let roster = [local] + members
            let group = try IntercomGroup(
                id: groupID, name: name, members: roster, accountDevices: groupAccountDevices(for: roster)
            )
            let secret = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
            return (group, .init(groupID: groupID, secret: secret))
        }
        guard var group = groups.first(where: { $0.id == groupID && $0.kind == .group }),
              let credential = try credential(for: group)
        else { throw ContactInvitationError.unavailable }
        group.members += members
        group.accountDevices.merge(groupAccountDevices(for: members)) { old, _ in old }
        return (group, credential)
    }

    func outgoingGroupInvitation(forPendingMember memberID: String, in groupID: UUID) -> ContactInvitationRecord? {
        guard memberID.hasPrefix(GroupMember.pendingInvitePrefix) else { return nil }
        _ = contactInvitationRevision
        return groupRepository.contactInvitations.first {
            $0.direction == .outgoing && $0.invitedGroupID == groupID
                && $0.pendingGroupMemberID == memberID && $0.state != .cancelled
        }
    }

    func personForGroupInvitation(memberID: String, groupID: UUID) -> SavedUser? {
        outgoingGroupInvitation(forPendingMember: memberID, in: groupID)?.personID.flatMap(contactPerson)
    }

    func personForGroupInvitation(_ invitation: ContactInvitationRecord) -> SavedUser? {
        guard invitation.direction == .outgoing, let groupID = invitation.invitedGroupID else { return nil }
        return personForGroupInvitation(memberID: invitation.pendingGroupMemberID, groupID: groupID)
    }

    func groupInvitationPersonIDs(_ groupID: UUID) -> [UUID] {
        outgoingGroupInvitationPersonIDs(in: groupID)
            .filter { contactPerson($0) != nil }
            .sorted { $0.uuidString < $1.uuidString }
    }

    func groupInvitationPeople(_ groupID: UUID) -> [SavedUser] {
        let people = outgoingGroupInvitationPersonIDs(in: groupID).compactMap(contactPerson)
        let uniquePeople = Dictionary(people.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return uniquePeople.values.sorted {
            $0.resolvedDisplayName.localizedStandardCompare($1.resolvedDisplayName) == .orderedAscending
        }
    }

    private func outgoingGroupInvitationPersonIDs(in groupID: UUID) -> Set<UUID> {
        Set(groupRepository.contactInvitations.filter {
            $0.direction == .outgoing && $0.invitedGroupID == groupID && $0.state != .cancelled
        }.compactMap(\.personID))
    }
}
