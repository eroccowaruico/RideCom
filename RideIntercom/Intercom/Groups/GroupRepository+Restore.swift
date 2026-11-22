import Foundation

struct CallRelationshipRestoreResponse: Codable {
    let confirmation: CallRelationshipRestoreConfirmation
    let credential: CallRelationshipRestoreCredential
}

/// In-process input from restore authorization. The caller verifies the backup owner,
/// current relationships and current credentials before creating this batch.
/// This is not the cloud format and must not be constructed by decoding a backup.
struct ConfirmedCallRestore {
    struct Call {
        let context: CallRelationshipRestoreContext
        let transferredCredential: CallRelationshipRestoreCredential
    }

    let owner: AccountPrincipal
    let previousMemberID: String
    let users: [SavedUser]
    let calls: [Call]
}

extension GroupRepository {
    var canRestoreCallRelationships: Bool {
        guard let current = writableSnapshot else { return false }
        var empty = GroupSnapshot()
        empty.generation = current.generation
        return current == empty
    }

    func canRestoreDirectContact(_ id: UUID, peer: AccountPrincipal, owner: AccountPrincipal) -> Bool {
        guard let current = writableSnapshot, current.completedDirectRestore == nil else { return false }
        let callID = AccountCallPair(owner, peer).id
        return !current.directCallRestoreExclusions.contains(callID)
            && !current.users.contains { $0.id == id || $0.principal == peer }
            && !current.groups.contains { $0.id == callID }
    }

    func restoreCallRelationships(
        _ batch: ConfirmedCallRestore, as signer: DeviceIdentitySigner, trust: DeviceIdentityTrust,
        completion: DirectRestoreCompletion? = nil,
        now: TimeInterval = Date().timeIntervalSince1970
    ) throws {
        guard let previous = writableSnapshot else { throw IntercomGroupError.storageUnavailable }
        guard let identity = signer.identity, identity.expiresAt > now,
              signer.principal == batch.owner, signer.memberID == localMemberID,
              signer.memberID != batch.previousMemberID else { throw GroupStorageError.identityConflict }

        guard !batch.calls.isEmpty,
              batch.users.allSatisfy({ user in
                  user.isRegistered && user.principal != batch.owner
                      && !user.memberIDs.contains(signer.memberID) && !user.memberIDs.contains(batch.previousMemberID)
              }) else { throw GroupStorageError.invalidUpdate }
        if let completion {
            guard completion.isValid, completion.canRetire(in: identity, now: Date(timeIntervalSince1970: now)),
                  batch.calls.count == 1, batch.calls.first?.context.record.kind == .direct,
                  batch.users.count == 1, let user = batch.users.first, let peer = user.principal,
                  canRestoreDirectContact(user.id, peer: peer, owner: batch.owner)
            else { throw GroupStorageError.invalidUpdate }
        } else if !canRestoreCallRelationships {
            throw GroupStorageError.invalidUpdate
        }

        let restored = try batch.calls.map { call in
            let context = call.context
            let received = try call.transferredCredential.open(for: context,
                as: signer, trust: trust, now: Date(timeIntervalSince1970: now))
            let record = try reboundRestoredRecord(
                context.record, replacing: batch.previousMemberID, verified: received.confirmation)
            return (record: record, credential: received.credential)
        }
        let records = restored.map(\.record)
        let confirmedPeers = Set(records.compactMap { $0.accountPair?.other(than: batch.owner) })
        guard batch.users.count == confirmedPeers.count,
              Set(batch.users.compactMap(\.principal)) == confirmedPeers else { throw GroupStorageError.invalidUpdate }
        for user in batch.users {
            guard let principal = user.principal, let deviceKeys = user.deviceKeys,
                  let call = records.first(where: { $0.accountPair?.other(than: batch.owner) == principal }),
                  user.memberIDs.allSatisfy({ memberID in
                      guard let key = deviceKeys[memberID] else { return false }
                      return call.accountDevices[memberID] == .init(principal: principal, publicKey: key)
                  }) else { throw GroupStorageError.invalidUpdate }
        }
        let groups = previous.groups + records
        try update(groups.map { try $0.group() }, credential: nil,
                   additionalCredentials: restored.map(\.credential), users: previous.users + batch.users,
                   now: now) { next in
            next.groups = groups
            next.completedDirectRestore = completion
        }
    }

    func removeDirectRestoreCompletion(_ completed: DirectRestoreCompletion) throws {
        guard let current = writableSnapshot else { throw IntercomGroupError.storageUnavailable }
        guard current.completedDirectRestore == completed else { return }
        try amend(current) { $0.completedDirectRestore = nil }
    }

    private func reboundRestoredRecord(
        _ source: GroupSnapshot.Record, replacing expectedPreviousMemberID: String,
        verified: CallRelationshipRestoreConfirmation.Verified
    ) throws -> GroupSnapshot.Record {
        let previous = verified.previousMemberID
        let replacement = verified.requesterMemberID
        let requester = verified.requester
        guard source.id == verified.callID, previous == expectedPreviousMemberID,
              source.accountDevices[verified.responderMemberID] == verified.responder,
              source.pendingInvitation == nil,
              !source.excludesMember(previous, principal: requester.principal),
              !source.excludesMember(replacement, principal: requester.principal) else {
            throw GroupStorageError.invalidUpdate
        }
        var group = try source.group()
        guard let index = group.members.firstIndex(where: { $0.id == previous }),
              !group.members.contains(where: { $0.id == replacement }),
              source.invitationDeviceKeys?[previous] != requester.publicKey,
              group.accountDevices[previous].map({
                  $0.principal == requester.principal && $0.publicKey != requester.publicKey
              }) ?? (group.kind == .group) else { throw GroupStorageError.identityConflict }
        guard group.kind != .direct || group.accountPair?.other(than: requester.principal) != nil
        else { throw GroupStorageError.invalidUpdate }

        let storedMember = group.members[index]
        group.members[index] = .init(id: replacement, displayName: storedMember.displayName,
                                     localName: storedMember.localName)
        group.members.removeAll { $0.id.hasPrefix(GroupMember.pendingInvitePrefix) }
        group.accountDevices.removeValue(forKey: previous)
        group.accountDevices[replacement] = requester
        var record = GroupSnapshot.Record(group)
        record.joinedByInvitation = source.joinedByInvitation
        record.groupTabOfferAcknowledged = source.groupTabOfferAcknowledged
        record.removedMembers = source.removedMembers
        record.invitationDeviceKeys = source.invitationDeviceKeys
        return record
    }
}
