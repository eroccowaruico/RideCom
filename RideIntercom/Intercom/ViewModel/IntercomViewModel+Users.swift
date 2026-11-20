import Foundation

extension IntercomViewModel {
    var savedRemoteUsers: [SavedUser] { directoryUsers.filter(\.isRegistered) }

    /// Includes names explicitly saved before the person has registered.
    var directoryUsers: [SavedUser] {
        savedUsers.filter { !$0.memberIDs.contains(localMemberIdentity.memberID) && ($0.principal == nil || $0.principal != localAccountPrincipal) }
            .sorted {
                let order = $0.resolvedDisplayName.localizedStandardCompare($1.resolvedDisplayName)
                return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
            }
    }

    func availableUsers(for groupID: UUID?) -> [SavedUser] {
        let group = groups.first { $0.id == groupID }
        let members = Set(group?.members.map(\.id) ?? [])
        let principals = Set(group?.accountDevices.values.map(\.principal) ?? [])
        return savedRemoteUsers.filter { members.isDisjoint(with: $0.memberIDs) && ($0.principal.map { !principals.contains($0) } ?? true) }
    }

    func membersForSavedUsers(_ ids: Set<UUID>) -> [GroupMember]? {
        let users = savedRemoteUsers.filter { ids.contains($0.id) }
        guard users.count == ids.count else {
            groupErrorMessage = "Some selected users are no longer available. Reload the user list and try again."
            return nil
        }
        return users.flatMap { user in
            return user.groupMemberIDs.map { GroupMember(id: $0, displayName: user.displayName, localName: user.localName) }
        }
    }

    func groupAccountDevices(for members: [GroupMember]) -> [String: AccountDeviceBinding] {
        var result: [String: AccountDeviceBinding] = [:]
        for member in members {
            if member.id == localMemberIdentity.memberID, let principal = localAccountPrincipal,
               let signer = try? internetSettingsStore.invitationSigner(memberID: member.id) {
                result[member.id] = .init(principal: principal, publicKey: signer.publicKey)
            } else if let user = savedRemoteUsers.first(where: { $0.memberIDs.contains(member.id) }),
                      let principal = user.principal, let key = user.deviceKeys?[member.id] {
                result[member.id] = .init(principal: principal, publicKey: key)
            }
        }
        return result
    }

    @discardableResult
    func addSavedUsers(_ ids: Set<UUID>, to groupID: UUID) -> Bool {
        guard requireGroupAccess() else { return false }
        groupErrorMessage = nil
        guard canEditSavedGroups else { groupErrorMessage = groupStorageNotice; return false }
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else {
            groupErrorMessage = "This group is no longer available. Return to the group list."
            return false
        }
        guard groups[index].kind == .group else {
            groupErrorMessage = "An individual call has only two participants. Create a group to include more people."
            return false
        }
        guard ids.isSubset(of: Set(availableUsers(for: groupID).map(\.id))),
              let members = membersForSavedUsers(ids), !members.isEmpty else { return false }
        let combined = groups[index].members + members
        guard combined.count <= IntercomGroup.maximumMemberCount,
              Set(combined.map(\.id)).count == combined.count else {
            groupErrorMessage = "Choose users who are not already in this group, up to 8 members including you."
            return false
        }
        var updated = groups[index]
        updated.members = combined
        updated.accountDevices.merge(groupAccountDevices(for: members)) { old, _ in old }
        do { try groupRepository.saveGroupMembers(updated, selectedUsers: ids, deliveries: groupDeliveryRecords(for: ids, groupID: groupID)) }
        catch { reportGroupStorageError(error); return false }
        refreshStoredAccountCall(groupID)
        refreshGroupStorageStatus()
        requestGroupDeliverySync(.localChange)
        return true
    }

    /// Deleting a person deletes their direct group too, and ends a call with them.
    @discardableResult
    func removeSavedUser(_ id: UUID) -> Bool {
        guard canEditSavedGroups else { groupErrorMessage = groupStorageNotice; return false }
        let removedGroups: Set<UUID>
        do {
            try notifications.suppressContact(id)
            let signer = try? internetSettingsStore.contactDeletionSigner(memberID: localMemberIdentity.memberID)
            removedGroups = try groupRepository.removeUser(id, signer: signer, now: callAccessNow())
        }
        catch { reportGroupStorageError(error); return false }
        finishSavedUserRemoval(removedGroups)
        requestGroupDeliverySync(.localChange)
        return true
    }

    func receiveContactDeletion(_ notice: ContactDeletionNotice, from peerID: String) throws -> ContactDeletionReceipt {
        guard canEditSavedGroups,
              let recipient = try internetSettingsStore.contactDeletionSigner(memberID: localMemberIdentity.memberID)
        else { throw DeviceIdentityProof.Failure.invalid }
        let result = try groupRepository.receiveContactDeletion(notice, from: peerID, recipient: recipient, now: callAccessNow(),
                                                                beforeRemoving: notifications.suppressContact)
        if let removed = result.removedGroups {
            finishSavedUserRemoval(removed)
            // Let the caller return the receipt on the current connection before recomputing offers.
            Task { [weak self] in self?.requestGroupDeliverySync(.localChange) }
        }
        return result.receipt
    }

    func acknowledgeContactDeletion(_ receipt: ContactDeletionReceipt, from peerID: String) throws {
        guard canEditSavedGroups else { throw DeviceIdentityProof.Failure.invalid }
        try groupRepository.acknowledgeContactDeletion(receipt, from: peerID, now: callAccessNow())
    }

    private func finishSavedUserRemoval(_ removedGroups: Set<UUID>) {
        if let active = activeGroupID, removedGroups.contains(active) { disconnect() }
        if let selected = selectedGroup?.id, removedGroups.contains(selected) { selectedGroup = nil }
        groups.removeAll { removedGroups.contains($0.id) }
        refreshGroupStorageStatus()
        Task { await notifications.retryRevocations() }
        groupErrorMessage = nil
    }

    @discardableResult
    func renameSavedUser(_ id: UUID, displayName: String) -> Bool {
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canEditSavedGroups else { groupErrorMessage = groupStorageNotice; return false }
        guard directoryUsers.contains(where: { $0.id == id }), IntercomGroup.isValidName(name) else {
            groupErrorMessage = "Enter a valid display name."
            return false
        }
        do { try groupRepository.renameUser(id, displayName: name) }
        catch { reportGroupStorageError(error); return false }
        refreshGroupStorageStatus()
        groupErrorMessage = nil
        return true
    }

    func applySavedUserNames() {
        for index in groups.indices {
            let stored = groupRepository.storedMembers(in: groups[index].id)
            for member in groups[index].members.indices {
                let id = groups[index].members[member].id
                if id == localMemberIdentity.memberID {
                    groups[index].members[member].displayName = localMemberIdentity.displayName
                    groups[index].members[member].localName = nil
                } else if let name = stored.first(where: { $0.id == id }) {
                    groups[index].members[member].displayName = name.displayName
                    groups[index].members[member].localName = name.localName
                }
            }
        }
        if let id = selectedGroup?.id { selectedGroup = groups.first { $0.id == id } }
    }
}
