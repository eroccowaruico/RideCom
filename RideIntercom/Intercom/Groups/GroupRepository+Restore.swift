import Foundation

/// In-process input from restore authorization. The caller verifies the backup owner,
/// current relationships and current credentials before creating this batch.
/// This is not the cloud format and must not be constructed by decoding a backup.
struct ConfirmedCallRestore {
    struct Call {
        let record: GroupSnapshot.Record
        let transferredCredential: CallRelationshipRestoreCredential
        let request: CallRelationshipRestoreRequest
        let confirmation: CallRelationshipRestoreConfirmation
    }

    let owner: AccountPrincipal
    let previousMemberID: String
    let users: [SavedUser]
    let calls: [Call]
}

extension GroupRepository {
    func restoreCallRelationships(
        _ batch: ConfirmedCallRestore, as signer: DeviceIdentitySigner, trust: DeviceIdentityTrust,
        now: TimeInterval = Date().timeIntervalSince1970
    ) throws {
        guard let current = writableSnapshot else { throw IntercomGroupError.storageUnavailable }
        guard let identity = signer.identity, identity.expiresAt > now,
              signer.principal == batch.owner, signer.memberID == localMemberID,
              signer.memberID != batch.previousMemberID else { throw GroupStorageError.identityConflict }

        var empty = GroupSnapshot()
        empty.generation = current.generation
        guard current == empty, !batch.calls.isEmpty,
              batch.users.allSatisfy({ user in
                  user.isRegistered && user.principal != batch.owner
                      && !user.memberIDs.contains(signer.memberID) && !user.memberIDs.contains(batch.previousMemberID)
              }) else { throw GroupStorageError.invalidUpdate }

        let restored = try batch.calls.map { call in
            let context = CallRelationshipRestoreCredential.Context(
                request: call.request, confirmation: call.confirmation, record: call.record)
            let received = try call.transferredCredential.open(for: context,
                as: signer, trust: trust, now: Date(timeIntervalSince1970: now))
            let record = try reboundRestoredRecord(
                call.record, replacing: batch.previousMemberID, verified: received.confirmation)
            return (record: record, credential: received.credential)
        }
        let records = restored.map(\.record)
        let confirmedPeers = Set(records.compactMap { $0.accountPair?.other(than: batch.owner) })
        guard batch.users.count == confirmedPeers.count,
              Set(batch.users.compactMap(\.principal)) == confirmedPeers else { throw GroupStorageError.invalidUpdate }
        try update(records.map { try $0.group() }, credential: nil,
                   additionalCredentials: restored.map(\.credential), users: batch.users, now: now) { next in
            next.groups = records
        }
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
