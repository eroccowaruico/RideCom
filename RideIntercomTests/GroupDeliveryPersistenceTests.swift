import Foundation
import Testing
@testable import RideIntercom

@MainActor struct GroupDeliveryPersistenceTests {
    @Test func aStoredDeliveryCannotDisappearOnSnapshotRoundTrip() throws {
        let key = testIdentitySigner("friend").publicKey
        let peer = AccountPrincipal(issuer: "https://notify.test", userID: String(repeating: "b", count: 64))
        let group = try IntercomGroup(
            name: "Queued group",
            members: [.init(id: "local", displayName: "You"), .init(id: "friend", displayName: "Friend")])
        let person = SavedUser(
            displayName: "Friend", memberIDs: ["friend"], deviceKeys: ["friend": key], principal: peer)
        let snapshot = GroupSnapshot(groups: [.init(group)], users: [person])
        var fields = try #require(JSONSerialization.jsonObject(with: snapshot.encoded()) as? [String: Any])
        fields["version"] = 11
        fields["groupDeliveries"] = [
            [
                "id": UUID().uuidString, "noticeID": UUID().uuidString, "groupID": group.id.uuidString,
                "recipient": ["issuer": peer.issuer, "userID": peer.userID], "recipientMemberID": "friend",
                "recipientKey": key,
                "expiresAt": Date().addingTimeInterval(86400).timeIntervalSince1970, "direction": "outgoing",
                "state": "pending"
            ]
        ]
        let restored = try GroupSnapshot.decode(JSONSerialization.data(withJSONObject: fields))
        let encoded = try #require(JSONSerialization.jsonObject(with: restored.encoded()) as? [String: Any])
        #expect((encoded["groupDeliveries"] as? [[String: Any]])?.count == 1)
        #expect(restored.upgraded().groupDeliveries == restored.groupDeliveries)
    }
    private let author = AccountPrincipal(issuer: "https://notify.test", userID: String(repeating: "a", count: 64))
    private let recipient = AccountPrincipal(issuer: "https://notify.test", userID: String(repeating: "b", count: 64))

    @Test func reopeningAnOldStoreDropsOnlySupersededOutgoingReceipts() throws {
        let fixture = try GroupStorageFixture(); defer { fixture.remove() }
        let keys = [
            "friend-one": testIdentitySigner("friend-one").publicKey,
            "friend-two": testIdentitySigner("friend-two").publicKey
        ]
        let user = SavedUser(
            displayName: "Friend", memberIDs: ["friend-one", "friend-two"], deviceKeys: keys, principal: recipient)
        let local = GroupMember(id: "local", displayName: "You")
        let peer = GroupMember(id: "friend-one", displayName: "Friend")
        let group = try IntercomGroup(name: "Current group", members: [local, peer])
        let other = try IntercomGroup(name: "Other group", members: [local, peer])
        let expiry = Date().addingTimeInterval(86400).timeIntervalSince1970
        let old = GroupDeliveryRecord(groupID: group.id, recipient: recipient, recipientMemberID: peer.id,
            recipientKey: try #require(keys[peer.id]), expiresAt: expiry, state: .received)
        let current = GroupDeliveryRecord(groupID: group.id, recipient: recipient, recipientMemberID: peer.id,
            recipientKey: old.recipientKey, expiresAt: expiry, state: .received)
        let secondDevice = GroupDeliveryRecord(noticeID: current.noticeID, groupID: group.id, recipient: recipient,
            recipientMemberID: "friend-two", recipientKey: try #require(keys["friend-two"]), expiresAt: expiry)
        let unrelated = GroupDeliveryRecord(groupID: other.id, recipient: recipient, recipientMemberID: peer.id,
            recipientKey: old.recipientKey, expiresAt: expiry, state: .received)
        let incoming = GroupDeliveryRecord(groupID: group.id, recipient: author, recipientMemberID: local.id,
            recipientKey: testIdentitySigner(local.id).publicKey, expiresAt: expiry, direction: .incoming,
            state: .received)
        let expected = [unrelated, current, secondDevice, incoming]
        try fixture.file.commit(GroupSnapshot(groups: [.init(group), .init(other)], users: [user],
            groupDeliveries: [old] + expected))
        let reopened = fixture.restart(); _ = try reopened.load(localMemberID: local.id)
        #expect(reopened.groupDeliveries == expected)
        #expect(try fixture.file.read()?.groupDeliveries == expected)
    }

    @Test func legacyGroupKeepsItsRosterWithoutInventingAnInvitationKey() throws {
        let group = try IntercomGroup(name: "Friends", members: [
            .init(id: "local", displayName: "You"), .init(id: "friend", displayName: "Friend")
        ])
        var legacy = GroupSnapshot(groups: [.init(group, credentialReference: UUID())])
        legacy.version = 13
        var upgraded = try GroupSnapshot.decode(legacy.encoded()).upgraded()
        #expect(upgraded.version == GroupSnapshot.currentVersion)
        #expect(upgraded.groups == legacy.groups)
        #expect(upgraded.groups[0].invitationDeviceKeys == nil)
        let key = testIdentitySigner("friend").publicKey
        upgraded.groups[0].invitationDeviceKeys = ["friend": key]
        #expect(try GroupSnapshot.decode(upgraded.encoded()).groups[0].invitationDeviceKeys == ["friend": key])
        upgraded.groups[0].invitationDeviceKeys = ["unknown": key]
        #expect(throws: IntercomGroupError.invalidStoredGroups) { try upgraded.encoded() }
    }

    @Test func groupAndOutboxCommitTogetherAndDeletionReclaimsThePreparedPacket() throws {
        let fixture = try GroupStorageFixture(); defer { fixture.remove() }
        let senderSigner = testIdentitySigner("local"), recipientSigner = testIdentitySigner("friend")
        let user = SavedUser(
            displayName: "Friend", memberIDs: ["friend"], deviceKeys: ["friend": recipientSigner.publicKey],
            principal: recipient
        )
        try fixture.file.commit(GroupSnapshot(users: [user]))
        let repository = fixture.restart(); _ = try repository.load(localMemberID: "local")
        let group = try IntercomGroup(
            name: "Delivery group",
            members: [.init(id: "local", displayName: "You"), .init(id: "friend", displayName: "Friend")])
        let expiry = Date().addingTimeInterval(86400).timeIntervalSince1970
        let record = GroupDeliveryRecord(
            groupID: group.id, recipient: recipient, recipientMemberID: "friend",
            recipientKey: recipientSigner.publicKey,
            expiresAt: expiry)
        let before = try fixture.file.read(); fixture.store.failCommit = true
        #expect(throws: (any Error).self) {
            try repository.save(
                [group], credential: .init(groupID: group.id, secret: "independent-group-key"),
                deliveries: [record])
        }
        #expect(try fixture.file.read() == before)
        fixture.store.failCommit = false; _ = try repository.load(localMemberID: "local")
        try repository.save(
            [group], credential: .init(groupID: group.id, secret: "independent-group-key"), deliveries: [record])
        let token = try GroupInviteToken.make(
            authority: testInvitationAuthority(), signer: senderSigner, groupID: group.id, groupName: group.name,
            groupSecret: "independent-group-key", inviterMemberID: "local", expiresAt: expiry)
        let envelope = try GroupInvitationEnvelope.seal(
            token, sender: author,
            recipient: .init(principal: recipient, memberID: "friend", encryptionKey: recipientSigner.publicKey),
            signer: senderSigner,
            deliveryID: record.id)
        try repository.saveGroupDeliveryEnvelope(envelope)
        let key = try #require(repository.groupDeliveries.first?.credentialReference)
        #expect(try repository.groupDeliveryEnvelope(record.id).ciphertext == envelope.ciphertext)
        let savedData = try #require(try fixture.file.read()).encoded()
        let savedDocument = try #require(String(data: savedData, encoding: .utf8))
        #expect(!savedDocument.contains("independent-group-key"))
        try repository.setGroupDeliveryState(record.id, state: .queued)
        let restarted = fixture.restart(); _ = try restarted.load(localMemberID: "local")
        #expect(restarted.groupDeliveries.first?.state == .queued)
        try verifyDeletionReclaimsPacket(
            group: group, repository: restarted, fixture: fixture, delivery: (record, key), user: user)
    }

    private func verifyDeletionReclaimsPacket(
        group: IntercomGroup, repository restarted: GroupRepository, fixture: GroupStorageFixture,
        delivery: (GroupDeliveryRecord, UUID), user: SavedUser
    ) throws {
        let (record, key) = delivery
        var rotated = group
        rotated.members[1] = .init(id: "new-representative", displayName: "Friend")
        rotated.accountDevices["new-representative"] = .init(
            principal: recipient, publicKey: testIdentitySigner("new-representative").publicKey)
        try restarted.save([rotated])
        #expect(
            restarted.groupDeliveries.first?.state == .queued,
            "Changing the account representative does not cancel the selected person")
        try restarted.delete(group.id, remaining: [])
        #expect(
            restarted.groupDeliveries.first?.state == .cancelled
                && restarted.groupDeliveries.first?.credentialReference == nil)
        #expect(fixture.keys.values[key] == nil && restarted.users == [user])
        #expect(throws: (any Error).self) { try restarted.groupDeliveryEnvelope(record.id) }
        try restarted.removeFinishedGroupDeliveries(now: Date().timeIntervalSince1970, internetCancelledID: record.id)
        #expect(restarted.groupDeliveries.isEmpty)
    }

    @Test func receivedGroupAndReceiptAreAtomicAndARepeatCannotRecreateADeletedGroup() throws {
        let fixture = try GroupStorageFixture(); defer { fixture.remove() }
        let senderSigner = testIdentitySigner("sender"), recipientSigner = testIdentitySigner("local")
        let user = SavedUser(
            displayName: "Sender", memberIDs: ["sender"], deviceKeys: ["sender": senderSigner.publicKey],
            principal: author)
        try fixture.file.commit(GroupSnapshot(users: [user]))
        let repository = fixture.restart(); _ = try repository.load(localMemberID: "local")
        let token = try GroupInviteToken.make(
            authority: testInvitationAuthority(), signer: senderSigner, groupID: UUID(),
            groupName: "Automatically delivered",
            groupSecret: "received-key", inviterMemberID: "sender")
        let envelope = try GroupInvitationEnvelope.seal(
            token, sender: author,
            recipient: .init(principal: recipient, memberID: "local", encryptionKey: recipientSigner.publicKey),
            signer: senderSigner)
        let opened = try envelope.open(recipient: recipientSigner, local: recipient, sender: user)
        let now = Date().timeIntervalSince1970
        let before = try fixture.file.read(); fixture.store.failCommit = true
        #expect(throws: (any Error).self) { try repository.stageGroupDelivery(envelope, token: opened, now: now) }
        #expect(try fixture.file.read() == before)
        fixture.store.failCommit = false; _ = try repository.load(localMemberID: "local")
        #expect(try repository.stageGroupDelivery(envelope, token: opened, now: now) == .pending)
        let reference = try #require(repository.groupDeliveries.first?.credentialReference)
        let staged = try fixture.file.read()
        #expect(repository.storedGroup(token.groupID) == nil)
        #expect(try repository.credential(for: token.groupID) == nil)
        fixture.store.failCommit = true
        #expect(throws: (any Error).self) {
            try repository.receiveGroupDelivery(envelope, token: opened, localDisplayName: "You", now: now)
        }
        #expect(try fixture.file.read() == staged && fixture.keys.values[reference] != nil)
        fixture.store.failCommit = false; _ = try repository.load(localMemberID: "local")
        let recovered = try repository.groupDeliveryEnvelope(envelope.id)
        try repository.receiveGroupDelivery(recovered, token: opened, localDisplayName: "You", now: now)
        #expect(fixture.keys.values[reference] == nil)
        #expect(try repository.credential(for: token.groupID)?.secret == token.groupSecret)
        #expect(
            repository.groupDeliveries.first?.direction == .incoming
                && repository.groupDeliveries.first?.state == .received)
        #expect(!repository.ownsGroup(token.groupID) && repository.users == [user])
        #expect(try fixture.file.read()?.groups.first?.invitationDeviceKeys == ["sender": senderSigner.publicKey])
        try verifyRepeatedDelivery(ReceivedDeliveryContext(
            fixture: fixture, repository: repository, token: token, opened: opened, envelope: envelope,
            senderSigner: senderSigner, recipientSigner: recipientSigner, user: user, now: now))
    }

}

extension GroupDeliveryPersistenceTests {
    private struct ReceivedDeliveryContext {
        let fixture: GroupStorageFixture
        let repository: GroupRepository
        let token: GroupInviteToken
        let opened: GroupInviteToken
        let envelope: GroupInvitationEnvelope
        let senderSigner: DeviceIdentitySigner
        let recipientSigner: DeviceIdentitySigner
        let user: SavedUser
        let now: TimeInterval
    }

    private func verifyRepeatedDelivery(_ context: ReceivedDeliveryContext) throws {
        let fixture = context.fixture, repository = context.repository
        let token = context.token, opened = context.opened, envelope = context.envelope
        let senderSigner = context.senderSigner, recipientSigner = context.recipientSigner
        let user = context.user, now = context.now
        let conflict = try GroupInviteToken.make(
            authority: testInvitationAuthority(), signer: senderSigner, groupID: token.groupID,
            groupName: token.groupName,
            groupSecret: "conflicting-key", inviterMemberID: "sender")
        let packet = try GroupInvitationEnvelope.seal(
            conflict, sender: author,
            recipient: .init(principal: recipient, memberID: "local", encryptionKey: recipientSigner.publicKey),
            signer: senderSigner)
        let saved = try fixture.file.read()
        #expect(try repository.stageGroupDelivery(packet, token: conflict, now: now) == .cancelled)
        #expect(try fixture.file.read() == saved)
        let duplicateGroup = try GroupInvitationEnvelope.seal(
            token, sender: author,
            recipient: .init(principal: recipient, memberID: "local", encryptionKey: recipientSigner.publicKey),
            signer: senderSigner)
        #expect(try repository.stageGroupDelivery(duplicateGroup, token: opened, now: now) == .pending)
        try repository.delete(token.groupID, remaining: [])
        #expect(repository.groupDeliveries.last?.state == .cancelled)
        #expect(
            try repository.receiveGroupDelivery(duplicateGroup, token: opened, localDisplayName: "You", now: now)
                == nil)
        let after = try fixture.file.read()
        #expect(try repository.stageGroupDelivery(envelope, token: opened, now: now) == .received)
        try repository.receiveGroupDelivery(envelope, token: opened, localDisplayName: "You", now: now)
        #expect(try fixture.file.read() == after)
        #expect(repository.storedGroup(token.groupID) == nil)

        let pending = try GroupInvitationEnvelope.seal(
            token, sender: author,
            recipient: .init(principal: recipient, memberID: "local", encryptionKey: recipientSigner.publicKey),
            signer: senderSigner)
        #expect(try repository.stageGroupDelivery(pending, token: opened, now: now) == .pending)
        let pendingReference = try #require(repository.groupDeliveries.last?.credentialReference)
        _ = try repository.removeUser(user.id)
        #expect(fixture.keys.values[pendingReference] == nil)
        #expect(repository.groupDeliveries.last?.state == .cancelled)
        #expect(try repository.receiveGroupDelivery(pending, token: opened, localDisplayName: "You", now: now) == nil)
        #expect(repository.storedGroup(token.groupID) == nil)
    }

    @Test func upgradingSchemaTenKeepsTheSamePendingPerson() throws {
        let person = SavedUser(displayName: "Saved nickname", memberIDs: [], localName: "Saved nickname")
        let record = ContactInvitationRecord(
            id: UUID(), direction: .outgoing, expiresAt: Date().addingTimeInterval(86400).timeIntervalSince1970,
            credentialReference: UUID(), nickname: person.resolvedDisplayName, personID: person.id)
        var old = GroupSnapshot(users: [person], contactInvitations: [record]); old.version = 10
        let upgraded = old.upgraded()
        #expect(upgraded.version == GroupSnapshot.currentVersion && upgraded.users == [person])
        #expect(upgraded.contactInvitations.first?.personID == person.id && upgraded.groupDeliveries.isEmpty)
    }

}
