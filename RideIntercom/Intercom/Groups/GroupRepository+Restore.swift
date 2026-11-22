import Foundation

/// In-process input from restore authorization. The caller verifies the backup owner,
/// current relationships and current credentials before creating this batch.
/// This is not the cloud format and must not be constructed by decoding a backup.
struct ConfirmedCallRestore {
    struct Call {
        let record: GroupSnapshot.Record
        let credential: GroupAccessCredential
    }

    let owner: AccountPrincipal
    let previousMemberID: String
    let users: [SavedUser]
    let calls: [Call]
}

extension GroupRepository {
    func restoreCallRelationships(
        _ batch: ConfirmedCallRestore, as signer: DeviceIdentitySigner,
        now: TimeInterval = Date().timeIntervalSince1970
    ) throws {
        guard let current = writableSnapshot else { throw IntercomGroupError.storageUnavailable }
        guard let identity = signer.identity, identity.expiresAt > now,
              signer.principal == batch.owner, signer.memberID == localMemberID,
              signer.memberID != batch.previousMemberID else { throw GroupStorageError.identityConflict }

        var empty = GroupSnapshot()
        empty.generation = current.generation
        guard current == empty, !batch.calls.isEmpty || !batch.users.isEmpty,
              batch.users.allSatisfy({ user in
                  user.isRegistered && user.principal != batch.owner
                      && !user.memberIDs.contains(signer.memberID) && !user.memberIDs.contains(batch.previousMemberID)
              }) else { throw GroupStorageError.invalidUpdate }

        let records = try batch.calls.map { try reboundRestoredRecord($0, in: batch, as: signer) }
        try update(records.map { try $0.group() }, credential: nil,
                   additionalCredentials: batch.calls.map(\.credential), users: batch.users, now: now) { next in
            next.groups = records
        }
    }

    private func reboundRestoredRecord(
        _ call: ConfirmedCallRestore.Call, in batch: ConfirmedCallRestore, as signer: DeviceIdentitySigner
    ) throws -> GroupSnapshot.Record {
        let source = call.record
        let previous = batch.previousMemberID
        guard source.id == call.credential.groupID, !call.credential.secret.isEmpty,
              source.pendingInvitation == nil,
              !source.excludesMember(previous, principal: batch.owner),
              !source.excludesMember(signer.memberID, principal: batch.owner) else {
            throw GroupStorageError.invalidUpdate
        }
        var group = try source.group()
        guard let index = group.members.firstIndex(where: { $0.id == previous }),
              !group.members.contains(where: { $0.id == signer.memberID }),
              group.accountDevices[previous].map({
                  $0.principal == batch.owner && $0.publicKey != signer.publicKey
              }) ?? (group.kind == .group) else { throw GroupStorageError.identityConflict }
        if group.kind == .direct {
            guard let peer = group.accountPair?.other(than: batch.owner),
                  batch.users.contains(where: { $0.principal == peer }) else { throw GroupStorageError.invalidUpdate }
        }

        let storedMember = group.members[index]
        group.members[index] = .init(id: signer.memberID, displayName: storedMember.displayName,
                                     localName: storedMember.localName)
        group.members.removeAll { $0.id.hasPrefix(GroupMember.pendingInvitePrefix) }
        group.accountDevices.removeValue(forKey: previous)
        group.accountDevices[signer.memberID] = .init(principal: batch.owner, publicKey: signer.publicKey)
        var record = GroupSnapshot.Record(group)
        record.joinedByInvitation = source.joinedByInvitation
        record.groupTabOfferAcknowledged = source.groupTabOfferAcknowledged
        record.removedMembers = source.removedMembers
        record.invitationDeviceKeys = source.invitationDeviceKeys
        return record
    }
}
