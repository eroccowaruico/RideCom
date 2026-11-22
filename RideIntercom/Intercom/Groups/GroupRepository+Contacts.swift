import CryptoKit
import Foundation

extension GroupRepository {
    func saveContactPerson(_ id: UUID, name: String, usesProvisionalName: Bool = false) throws {
        guard let snapshot, IntercomGroup.isValidName(name), !snapshot.users.contains(where: { $0.id == id }) else {
            throw GroupStorageError.invalidUpdate
        }
        try amend(snapshot) { next in
            next.users.append(
                SavedUser(
                    id: id, displayName: name, memberIDs: [], localName: name,
                    usesProvisionalName: usesProvisionalName))
        }
    }

    /// The displayed pair of names is checked at the manifest's atomic commit point.
    func resolveProvisionalName(_ id: UUID, localName: String, sharedName: String, useSharedName: Bool) throws {
        guard let snapshot, let index = snapshot.users.firstIndex(where: { $0.id == id }),
              snapshot.users[index].needsNameConfirmation,
              snapshot.users[index].localName == localName, snapshot.users[index].displayName == sharedName else {
            throw GroupStorageError.invalidUpdate
        }
        try amend(snapshot) { next in
            if useSharedName { next.users[index].localName = nil }
            next.users[index].usesProvisionalName = false
        }
    }

    func renameUser(_ id: UUID, displayName: String) throws {
        guard IntercomGroup.isValidName(displayName) else { throw GroupStorageError.invalidUpdate }
        try setUserLocalName(id, displayName)
    }

    func resetUserName(_ id: UUID) throws { try setUserLocalName(id, nil) }

    private func setUserLocalName(_ id: UUID, _ localName: String?) throws {
        guard let snapshot, let index = snapshot.users.firstIndex(where: { $0.id == id }) else {
            throw GroupStorageError.invalidUpdate
        }
        try amend(snapshot) { next in
            next.users[index].localName = localName
            next.users[index].usesProvisionalName = false
        }
    }

    func storedMembers(in groupID: UUID) -> [GroupSnapshot.Member] {
        snapshot?.groups.first { $0.id == groupID }?.members ?? []
    }

    func setMemberName(_ memberID: String, in groupID: UUID, localName: String?) throws {
        guard let snapshot, memberID != self.localMemberID,
              let index = snapshot.groups.firstIndex(where: { $0.id == groupID }),
              let member = snapshot.groups[index].members.firstIndex(where: { $0.id == memberID }),
              localName.map(IntercomGroup.isValidName) ?? true else { throw GroupStorageError.invalidUpdate }
        if let user = snapshot.users.first(where: { $0.memberIDs.contains(memberID)
            || ($0.principal != nil && $0.principal == snapshot.groups[index].accountDevices[memberID]?.principal) }) {
            if let localName { try renameUser(user.id, displayName: localName) } else { try resetUserName(user.id) }
            return
        }
        var groups = try snapshot.groups.map { try $0.group() }
        groups[index].members[member].localName = localName
        try update(groups, credential: nil)
    }

    @discardableResult
    func receiveProfile(_ profile: VerifiedPeerProfile, connectedMemberIDs: Set<String> = []) throws -> Bool {
        let name = profile.displayName, memberID = profile.identity.memberID, groupID = profile.groupID
        guard let snapshot else { throw IntercomGroupError.storageUnavailable }
        guard memberID != localMemberID, IntercomGroup.isValidName(name),
              let index = snapshot.groups.firstIndex(where: { $0.id == groupID }),
            snapshot.groups[index].matchesInvitationDeviceKey(profile.identity.publicKey, for: memberID)
        else { return false }
        var groups = try snapshot.groups.map { try $0.group() }
        var users = snapshot.users
        var principal = profile.identity.principal
        if let user = users.firstIndex(where: { $0.memberIDs.contains(memberID) }) {
            guard users[user].deviceKeys?[memberID] == profile.identity.publicKey,
                  users[user].principal == nil || profile.identity.principal == nil
                    || users[user].principal == profile.identity.principal else { return false }
            users[user].displayName = name
            principal = principal ?? users[user].principal
        }
        if snapshot.groups[index].excludesMember(memberID, principal: principal) { return false }
        guard applyMemberProfile(profile, retaining: connectedMemberIDs, to: &groups[index], users: &users)
        else { return false }
        if groups[index] != (try snapshot.groups[index].group()) || users != snapshot.users {
            try update(groups, credential: nil, users: users)
        }
        return true
    }

    private func applyMemberProfile(
        _ profile: VerifiedPeerProfile, retaining connectedMemberIDs: Set<String>,
        to group: inout IntercomGroup, users: inout [SavedUser]
    ) -> Bool {
        let name = profile.displayName, memberID = profile.identity.memberID
        if group.accountPair != nil {
            guard
                group.bindAccountDevice(
                    profile.identity, name: name, localMemberID: localMemberID, retaining: connectedMemberIDs)
            else { return false }
        } else if group.kind == .group {
            guard
                group.bindGroupRepresentative(
                    profile.identity, name: name, localMemberID: localMemberID, retaining: connectedMemberIDs)
            else { return false }
            if let principal = profile.identity.principal,
                let user = users.firstIndex(where: { $0.principal == principal }) {
                users[user].displayName = name
            }
        } else {
            guard let member = group.members.firstIndex(where: { $0.id == memberID }) else { return false }
            group.members[member].displayName = name
        }
        return true
    }

    func singleDeviceCall(for user: SavedUser) throws -> (peerID: String, secret: String)? {
        guard let snapshot, let localMemberID else { return nil }
        let peers = Set(user.memberIDs)
        var match: (peerID: String, groupID: UUID)?
        for group in snapshot.groups where group.kind == .direct && group.accountPair == nil {
            guard let peer = group.members.first(where: { $0.id != localMemberID && peers.contains($0.id) }) else {
                continue
            }
            guard match == nil else { return nil }
            match = (peer.id, group.id)
        }
        guard let match, let credential = try credential(for: match.groupID) else { return nil }
        return (match.peerID, credential.secret)
    }

    /// A saved person and their direct group are one thing. Removing the person removes
    /// that group and its key in the same commit; regular groups keep the member.
    /// Returns the removed direct groups so a live call to one of them can end.
    @discardableResult
    func removeUser(_ id: UUID, signer: DeviceIdentitySigner? = nil, sender: AccountPrincipal? = nil,
                    now: Date = Date()) throws -> Set<UUID> {
        guard let snapshot, let user = snapshot.users.first(where: { $0.id == id }) else {
            throw GroupStorageError.invalidUpdate
        }
        return try removeUser(user, from: snapshot, now: now) { calls, next in
            if let signer, signer.memberID == self.localMemberID {
                try self.stageContactDeletions(
                    for: user, directCalls: calls, sender: (signer, sender), now: now, in: &next
                )
            }
        }
    }

    private func removeUser(_ user: SavedUser, from snapshot: GroupSnapshot, now: Date,
                            modify: ([GroupSnapshot.Record], inout GroupSnapshot) throws -> Void) throws -> Set<UUID> {
        let directCalls = snapshot.groups.filter { belongs($0, to: user) }
        let removed = Set(directCalls.map(\.id))
        try update(snapshot.groups.filter { !removed.contains($0.id) }.map { try $0.group() },
            credential: nil, users: snapshot.users.filter { $0.id != user.id }, now: now.timeIntervalSince1970
        ) { next in
            Self.cancelPendingGroupReceipts(in: &next) { record in
                record.senderMemberID.map(user.memberIDs.contains) == true
            }
            try modify(directCalls, &next)
            rememberLastBackupRemoval(user.id, kind: .contact, afterRemovingFrom: &next)
        }
        return removed
    }

    struct ContactDeletionResult {
        let receipt: ContactDeletionReceipt
        let removedGroups: Set<UUID>?
        let saved: Bool
    }

    func receiveContactDeletion(
        _ notice: ContactDeletionNotice, from peerID: String,
        recipient identity: (signer: DeviceIdentitySigner, principal: AccountPrincipal?), now: Date,
        beforeRemoving: (UUID) throws -> Void
    ) throws -> ContactDeletionResult {
        guard let snapshot = writableSnapshot else { throw IntercomGroupError.storageUnavailable }
        let recipient = identity.signer
        let target = notice.target
        guard peerID == target.senderMemberID, localMemberID == recipient.memberID,
              target.recipientMemberID == recipient.memberID, target.recipientKey == recipient.publicKey
        else { throw DeviceIdentityProof.Failure.invalid }
        if let receipt = snapshot.contactDeletionReceipts.first(where: { $0.id == notice.id }) {
            try receipt.verify(for: notice, now: now)
            return try withCurrentSnapshot(snapshot) { .init(receipt: receipt, removedGroups: nil, saved: false) }
        }
        if !snapshot.users.contains(where: { $0.memberIDs.contains(peerID) }) {
            let receipt = try receiveDeletionOfFormerContact(notice, snapshot: snapshot, recipient: recipient,
                                                              localAccount: identity.principal, now: now)
            return .init(receipt: receipt, removedGroups: nil, saved: true)
        }
        // A single device's pair credential cannot authorize removal of a multi-device entry.
        guard let user = snapshot.users.first(where: { $0.memberIDs == [peerID] }),
              let senderKey = user.deviceKeys?[peerID] else { throw DeviceIdentityProof.Failure.invalid }
        let pairID = IntercomGroup.directCallID(memberIDs: [recipient.memberID, peerID])
        guard snapshot.groups.contains(where: { $0.id == pairID && $0.kind == .direct && $0.accountPair == nil }),
              let pair = try credential(for: pairID) else { throw DeviceIdentityProof.Failure.invalid }
        try notice.verify(from: peerID, senderKey: senderKey, recipient: recipient, pairSecret: pair.secret, now: now)
        let receipt = try ContactDeletionReceipt(for: notice, recipient: recipient)
        let address = ContactDeletionRelayAddress(
            owner: user.principal, recipient: identity.principal, pairSecret: pair.secret,
                                                   senderID: peerID, recipientID: recipient.memberID)
        let removed = try removeUser(user, from: snapshot, now: now) { _, next in
            try Self.stageContactDeletionReceipt(receipt, address: address, signer: recipient, in: &next)
            try beforeRemoving(user.id)
        }
        return .init(receipt: receipt, removedGroups: removed, saved: true)
    }

    func canUseFormerContactDeletionPair(
        _ former: ContactDeletionFormerPair, signer: DeviceIdentitySigner, now: Date
    ) -> Bool {
        guard former.canVerify(for: signer, now: now), let snapshot else { return false }
        return !snapshot.users.contains {
            $0.memberIDs.contains(former.peerID) || (former.relay != nil && $0.principal == former.relay?.owner)
        }
    }

    private func receiveDeletionOfFormerContact(_ notice: ContactDeletionNotice, snapshot: GroupSnapshot,
                                                recipient: DeviceIdentitySigner, localAccount: AccountPrincipal?,
                                                now: Date) throws -> ContactDeletionReceipt {
        let peerID = notice.target.senderMemberID
        for former in snapshot.contactDeletionFormerPairs.reversed()
        where former.peerID == peerID && former.peerKey == notice.proof.publicKey
            && canUseFormerContactDeletionPair(former, signer: recipient, now: now) {
            guard let stored = try credentialSecret(reference: former.keyReference),
                  let bytes = IdentityEncoding.decode(stored), bytes.count == 32,
                  (try? notice.verify(from: peerID, senderKey: former.peerKey, recipient: recipient,
                                      pairKey: SymmetricKey(data: bytes), now: now)) != nil
            else { continue }
            let receipt = try ContactDeletionReceipt(for: notice, recipient: recipient)
            let address = former.relay.flatMap { $0.recipient == localAccount ? $0 : nil }
            try amend(snapshot, now: now.timeIntervalSince1970) { next in
                try Self.stageContactDeletionReceipt(receipt, address: address, signer: recipient, in: &next)
                next.contactDeletionFormerPairs.removeAll { $0.keyReference == former.keyReference }
            }
            return receipt
        }
        throw DeviceIdentityProof.Failure.invalid
    }

    private static func stageContactDeletionReceipt(
        _ receipt: ContactDeletionReceipt, address: ContactDeletionRelayAddress?,
        signer: DeviceIdentitySigner, in next: inout GroupSnapshot
    ) throws {
        if let address {
            next.contactDeletionRelayReceipts.append(
                try ContactDeletionRelayReceipt(receipt: receipt, address: address, signer: signer))
        }
        next.contactDeletionReceipts.append(receipt)
    }

    func acknowledgeContactDeletion(_ receipt: ContactDeletionReceipt, from peerID: String, now: Date) throws {
        guard let snapshot = writableSnapshot else { throw IntercomGroupError.storageUnavailable }
        guard let notice = snapshot.contactDeletions.first(where: { $0.id == receipt.id }) else { return }
        guard peerID == notice.target.recipientMemberID else { throw DeviceIdentityProof.Failure.invalid }
        try receipt.verify(for: notice, now: now)
        try amend(snapshot, now: now.timeIntervalSince1970) { next in
            next.contactDeletions.removeAll { $0.id == receipt.id }
            if let index = next.contactDeletionPublications.firstIndex(where: { $0.id == receipt.id }) {
                next.contactDeletionPublications[index].markForRetirement()
            }
        }
    }

    func finishContactDeletionRelay(_ publication: ContactDeletionPublication, now: Date) throws {
        guard publication.payload == nil, let snapshot, snapshot.contactDeletionPublications.contains(publication)
        else { return }
        try amend(snapshot, now: now.timeIntervalSince1970) { next in
            next.contactDeletionPublications.removeAll { $0 == publication }
        }
    }

    func finishContactDeletionRelay(_ receipt: ContactDeletionRelayReceipt, now: Date) throws {
        guard let snapshot, snapshot.contactDeletionRelayReceipts.contains(receipt) else { return }
        try amend(snapshot, now: now.timeIntervalSince1970) { next in
            next.contactDeletionRelayReceipts.removeAll { $0 == receipt }
        }
    }

    private func stageContactDeletions(
        for user: SavedUser, directCalls: [GroupSnapshot.Record],
        sender: (signer: DeviceIdentitySigner, principal: AccountPrincipal?), now: Date,
        in next: inout GroupSnapshot
    ) throws {
        let signer = sender.signer
        for call in directCalls where call.accountPair == nil {
            guard let peer = call.members.first(where: { $0.id != signer.memberID }),
                  let peerKey = user.deviceKeys?[peer.id],
                  call.id == IntercomGroup.directCallID(memberIDs: [signer.memberID, peer.id]),
                  let reference = call.credentialReference, let secret = try credentialSecret(reference: reference)
            else { continue }
            let notice = try ContactDeletionNotice(signer: signer, recipientMemberID: peer.id, recipientKey: peerKey,
                                                   pairSecret: secret, now: now)
            let verificationKey = ContactDeletionNotice.pairKey(secret).withUnsafeBytes {
                IdentityEncoding.encode(Data($0))
            }
            let address = ContactDeletionRelayAddress(
                owner: user.principal, recipient: sender.principal, pairSecret: secret,
                senderID: peer.id, recipientID: signer.memberID
            )
            next.contactDeletionFormerPairs.append(.init(localMemberID: signer.memberID, localKey: signer.publicKey,
                peerID: peer.id, peerKey: peerKey, expiresAt: notice.target.expiresAt,
                keyReference: try prepareKey(verificationKey), relay: address))
            next.contactDeletions.append(notice)
            if let sender = sender.principal, let recipient = user.principal,
               sender.issuer == recipient.issuer, sender != recipient {
                next.contactDeletionPublications.append(try ContactDeletionPublication(
                    notice: notice, sender: sender, recipient: recipient, signer: signer, pairSecret: secret))
            }
        }
    }

    private func belongs(_ record: GroupSnapshot.Record, to user: SavedUser) -> Bool {
        guard record.kind == .direct else { return false }
        if let principal = user.principal, let pair = record.accountPair,
           let local = localMemberID.flatMap({ record.accountDevices[$0]?.principal }),
           pair.other(than: local) == principal { return true }
        return record.members.contains { $0.id != localMemberID && user.memberIDs.contains($0.id) }
    }

    /// A direct group whose person is no longer saved, as an earlier version left after deleting them.
    func isOrphanedDirectGroup(_ record: GroupSnapshot.Record, users: [SavedUser]) -> Bool {
        guard record.kind == .direct, record.members.contains(where: { $0.id != localMemberID }) else { return false }
        return !users.contains { belongs(record, to: $0) }
    }
}
