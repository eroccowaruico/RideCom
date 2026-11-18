import Foundation

struct PreparedContactInvitationShare: Identifiable {
    let id: UUID
    let accountAccessID: UUID
    let url: URL
}

extension IntercomViewModel {
    /// An open sheet can resolve a newly identified duplicate to the already saved person without
    /// replacing its presentation identity or losing the current screen.
    func contactPerson(_ id: UUID) -> SavedUser? {
        _ = contactInvitationRevision
        if let user = directoryUsers.first(where: { $0.id == id }) { return user }
        guard let peer = groupRepository.contactInvitations.first(where: { $0.personID == id && $0.state == .confirmed })?.peerMemberID else { return nil }
        return savedRemoteUsers.first { $0.memberIDs.contains(peer) }
    }

    func showContactPerson(_ id: UUID) {
        guard canEditSavedGroups, contactPerson(id) != nil else { return }
        contactInvitationMessage = nil
        contactInvitationPresentation = .person(id)
    }

    @discardableResult
    func saveContactPerson(_ id: UUID, name: String, usesProvisionalName: Bool = false) -> Bool {
        guard canEditSavedGroups, contactInvitationPresentation == .person(id) else { return false }
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard IntercomGroup.isValidName(name) else {
            contactInvitationMessage = "Enter a valid display name."
            return false
        }
        do {
            try groupRepository.saveContactPerson(id, name: name, usesProvisionalName: usesProvisionalName)
            refreshGroupStorageStatus()
            contactInvitationMessage = nil
            return true
        } catch {
            reportGroupStorageError(error)
            contactInvitationMessage = "Could not save this person. Try again."
            return false
        }
    }

    @discardableResult
    func resolveContactPersonName(_ person: SavedUser, useSharedName: Bool) -> Bool {
        guard canEditSavedGroups, let current = contactPerson(person.id), current.needsNameConfirmation else { return false }
        guard let local = person.localName, current.localName == local, current.displayName == person.displayName else {
            contactInvitationMessage = "This name changed. Review it again."
            groupErrorMessage = contactInvitationMessage
            return false
        }
        do {
            try groupRepository.resolveProvisionalName(person.id, localName: local, sharedName: person.displayName, useSharedName: useSharedName)
            refreshGroupStorageStatus()
            contactInvitationMessage = nil
            groupErrorMessage = nil
            return true
        } catch {
            reportGroupStorageError(error)
            contactInvitationMessage = "Could not save the name choice. Try again."
            return false
        }
    }

    func contactPersonInvitations(_ id: UUID) -> [ContactInvitationRecord] {
        _ = contactInvitationRevision
        let members = contactPerson(id)?.memberIDs ?? []
        return groupRepository.contactInvitations.filter {
            $0.personID == id || ($0.peerMemberID.map(members.contains) ?? false)
        }.sorted { $0.expiresAt > $1.expiresAt }
    }

    /// Kept only for old, unlinked exchanges. A person's delivery record never adds a second row.
    var unlinkedContactInvitations: [ContactInvitationRecord] {
        pendingContactInvitations.filter { record in
            record.personID == nil && !(record.peerMemberID.map { peer in savedRemoteUsers.contains { $0.memberIDs.contains(peer) } } ?? false)
        }
    }

    func prepareContactPersonShare(_ id: UUID, expectedAccountAccessID: UUID) throws -> PreparedContactInvitationShare {
        guard canEditSavedGroups, expectedAccountAccessID == accountAccessID,
              let person = directoryUsers.first(where: { $0.id == id }), !person.isRegistered else {
            throw ContactInvitationError.unavailable
        }
        contactInvitationMessage = nil
        do {
            let record = contactPersonInvitations(id).first { $0.direction == .outgoing && ($0.state == .pending || $0.state == .expired) }
            if let record, record.state == .pending, !contactInvitationIsExpired(record) {
                let share = try prepareContactInvitationShare(record.id, expectedAccountAccessID: expectedAccountAccessID)
                _ = resumeContactInvitation(record.id)
                return share
            }
            let target = try record?.invitedGroupID.map { try contactGroupAttachment(for: $0) }
            let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID)
            let token = try ContactInvitationSession.makeToken(authority: invitationAuthority, signer: signer,
                displayName: localMemberIdentity.displayName, now: callAccessNow().timeIntervalSince1970, invitedGroup: target)
            try groupRepository.stageContactInvitation(token, now: callAccessNow().timeIntervalSince1970,
                replacingExpiredInvitation: record?.id, personID: id)
            guard let invitationID = token.directInvitation?.context.id else { throw ContactInvitationError.unavailable }
            let share = try prepareContactInvitationShare(invitationID, expectedAccountAccessID: expectedAccountAccessID)
            refreshContactInvitationGroup(invitationID)
            refreshGroupStorageStatus()
            _ = resumeContactInvitation(invitationID)
            return share
        } catch {
            contactInvitationMessage = "Could not prepare this invitation. Try again."
            throw error
        }
    }

    func resumeContactPersonInvitation(_ id: UUID) {
        guard let record = contactPersonInvitations(id).first(where: { $0.canResume && !contactInvitationIsComplete($0) }) else { return }
        _ = resumeContactInvitation(record.id)
    }

    func suspendContactInvitationForBackground() {
        guard endContactInvitationBackgroundTime == nil else { return }
        pauseContactInvitationSession()
    }

    /// Preserve the current attempt's durable checkpoint for the same account.
    func pauseContactInvitationSession() {
        guard let id = contactInvitationID else { return }
        stopContactInvitationSession()
        suspendedContactInvitation = (id, accountAccessID)
    }

    func resumeSuspendedContactInvitation() {
        guard let suspended = suspendedContactInvitation else { return }
        suspendedContactInvitation = nil
        guard suspended.access == accountAccessID else { return }
        _ = resumeContactInvitation(suspended.id)
    }
}
