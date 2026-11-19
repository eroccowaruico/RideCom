import Foundation
import Testing
@testable import RideIntercom

@MainActor struct GroupDeliveryPersistenceTests {
    @Test func aStoredDeliveryCannotDisappearOnSnapshotRoundTrip() throws {
        let key = testIdentitySigner("friend").publicKey
        let peer = AccountPrincipal(issuer: "https://notify.test", userID: String(repeating: "b", count: 64))
        let group = try IntercomGroup(name: "Queued group", members: [.init(id: "local", displayName: "You"), .init(id: "friend", displayName: "Friend")])
        let person = SavedUser(displayName: "Friend", memberIDs: ["friend"], deviceKeys: ["friend": key], principal: peer)
        let snapshot = GroupSnapshot(groups: [.init(group)], users: [person])
        var fields = try #require(JSONSerialization.jsonObject(with: snapshot.encoded()) as? [String: Any])
        fields["version"] = 11
        fields["groupDeliveries"] = [["id": UUID().uuidString, "noticeID": UUID().uuidString, "groupID": group.id.uuidString,
            "recipient": ["issuer": peer.issuer, "userID": peer.userID], "recipientMemberID": "friend", "recipientKey": key,
            "expiresAt": Date().addingTimeInterval(86400).timeIntervalSince1970, "direction": "outgoing", "state": "pending"]]
        let restored = try GroupSnapshot.decode(JSONSerialization.data(withJSONObject: fields))
        let encoded = try #require(JSONSerialization.jsonObject(with: restored.encoded()) as? [String: Any])
        #expect((encoded["groupDeliveries"] as? [[String: Any]])?.count == 1)
        #expect(restored.upgraded().groupDeliveries == restored.groupDeliveries)
    }
    private let author = AccountPrincipal(issuer: "https://notify.test", userID: String(repeating: "a", count: 64))
    private let recipient = AccountPrincipal(issuer: "https://notify.test", userID: String(repeating: "b", count: 64))

    @Test func legacyGroupKeepsItsRosterWithoutInventingAnInvitationKey() throws {
        let group = try IntercomGroup(name: "Friends", members: [
            .init(id: "local", displayName: "You"), .init(id: "friend", displayName: "Friend"),
        ])
        var legacy = GroupSnapshot(groups: [.init(group, credentialReference: UUID())])
        legacy.version = 13
        var upgraded = try GroupSnapshot.decode(legacy.encoded()).upgraded()
        #expect(upgraded.version == 14)
        #expect(upgraded.groups == legacy.groups)
        #expect(upgraded.groups[0].invitationDeviceKeys == nil)
        let key = testIdentitySigner("friend").publicKey
        upgraded.groups[0].invitationDeviceKeys = ["friend": key]
        #expect(try GroupSnapshot.decode(upgraded.encoded()).groups[0].invitationDeviceKeys == ["friend": key])
        upgraded.groups[0].invitationDeviceKeys = ["unknown": key]
        #expect(throws: IntercomGroupError.invalidStoredGroups) { try upgraded.encoded() }
    }

    @Test func groupAndOutboxCommitTogetherAndDeletionReclaimsThePreparedPacket() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let a = testIdentitySigner("local"), b = testIdentitySigner("friend")
        let user = SavedUser(displayName: "Friend", memberIDs: ["friend"], deviceKeys: ["friend": b.publicKey], principal: recipient)
        try f.file.commit(GroupSnapshot(users: [user]))
        let repository = f.restart(); _ = try repository.load(localMemberID: "local")
        let group = try IntercomGroup(name: "Delivery group", members: [.init(id: "local", displayName: "You"), .init(id: "friend", displayName: "Friend")])
        let expiry = Date().addingTimeInterval(86400).timeIntervalSince1970
        let record = GroupDeliveryRecord(groupID: group.id, recipient: recipient, recipientMemberID: "friend", recipientKey: b.publicKey, expiresAt: expiry)
        let before = try f.file.read(); f.store.failCommit = true
        #expect(throws: (any Error).self) { try repository.save([group], credential: .init(groupID: group.id, secret: "independent-group-key"), deliveries: [record]) }
        #expect(try f.file.read() == before)
        f.store.failCommit = false; _ = try repository.load(localMemberID: "local")
        try repository.save([group], credential: .init(groupID: group.id, secret: "independent-group-key"), deliveries: [record])
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: a, groupID: group.id, groupName: group.name,
            groupSecret: "independent-group-key", inviterMemberID: "local", expiresAt: expiry)
        let envelope = try GroupInvitationEnvelope.seal(token, sender: author, recipient: recipient,
            recipientMemberID: "friend", recipientKey: b.publicKey, signer: a, deliveryID: record.id)
        try repository.saveGroupDeliveryEnvelope(envelope)
        let key = try #require(repository.groupDeliveries.first?.credentialReference)
        #expect(try repository.groupDeliveryEnvelope(record.id).ciphertext == envelope.ciphertext)
        #expect(!String(decoding: try #require(try f.file.read()).encoded(), as: UTF8.self).contains("independent-group-key"))
        try repository.setGroupDeliveryState(record.id, state: .queued)
        let restarted = f.restart(); _ = try restarted.load(localMemberID: "local")
        #expect(restarted.groupDeliveries.first?.state == .queued)
        var rotated = group
        rotated.members[1] = .init(id: "new-representative", displayName: "Friend")
        rotated.accountDevices["new-representative"] = .init(principal: recipient, publicKey: testIdentitySigner("new-representative").publicKey)
        try restarted.save([rotated])
        #expect(restarted.groupDeliveries.first?.state == .queued, "Changing the account representative does not cancel the selected person")
        try restarted.delete(group.id, remaining: [])
        #expect(restarted.groupDeliveries.first?.state == .cancelled && restarted.groupDeliveries.first?.credentialReference == nil)
        #expect(f.keys.values[key] == nil && restarted.users == [user])
        #expect(throws: (any Error).self) { try restarted.groupDeliveryEnvelope(record.id) }
        try restarted.removeFinishedGroupDeliveries(now: Date().timeIntervalSince1970, cancelledID: record.id)
        #expect(restarted.groupDeliveries.isEmpty)
    }

    @Test func receivedGroupAndReceiptAreAtomicAndARepeatCannotRecreateADeletedGroup() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let a = testIdentitySigner("sender"), b = testIdentitySigner("local")
        let user = SavedUser(displayName: "Sender", memberIDs: ["sender"], deviceKeys: ["sender": a.publicKey], principal: author)
        try f.file.commit(GroupSnapshot(users: [user]))
        let repository = f.restart(); _ = try repository.load(localMemberID: "local")
        let token = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: a, groupID: UUID(), groupName: "Automatically delivered",
            groupSecret: "received-key", inviterMemberID: "sender")
        let envelope = try GroupInvitationEnvelope.seal(token, sender: author, recipient: recipient,
            recipientMemberID: "local", recipientKey: b.publicKey, signer: a)
        let opened = try envelope.open(recipient: b, local: recipient, sender: user)
        let now = Date().timeIntervalSince1970
        let before = try f.file.read(); f.store.failCommit = true
        #expect(throws: (any Error).self) { try repository.stageGroupDelivery(envelope, token: opened, now: now) }
        #expect(try f.file.read() == before)
        f.store.failCommit = false; _ = try repository.load(localMemberID: "local")
        #expect(try repository.stageGroupDelivery(envelope, token: opened, now: now) == .pending)
        let reference = try #require(repository.groupDeliveries.first?.credentialReference)
        let staged = try f.file.read()
        #expect(repository.storedGroup(token.groupID) == nil)
        #expect(try repository.credential(for: token.groupID) == nil)
        f.store.failCommit = true
        #expect(throws: (any Error).self) { try repository.receiveGroupDelivery(envelope, token: opened, localDisplayName: "You", now: now) }
        #expect(try f.file.read() == staged && f.keys.values[reference] != nil)
        f.store.failCommit = false; _ = try repository.load(localMemberID: "local")
        let recovered = try repository.groupDeliveryEnvelope(envelope.id)
        try repository.receiveGroupDelivery(recovered, token: opened, localDisplayName: "You", now: now)
        #expect(f.keys.values[reference] == nil)
        #expect(try repository.credential(for: token.groupID)?.secret == token.groupSecret)
        #expect(repository.groupDeliveries.first?.direction == .incoming && repository.groupDeliveries.first?.state == .received)
        #expect(!repository.ownsGroup(token.groupID) && repository.users == [user])
        #expect(try f.file.read()?.groups.first?.invitationDeviceKeys == ["sender": a.publicKey])
        let conflict = try GroupInviteToken.make(authority: testInvitationAuthority(), signer: a, groupID: token.groupID, groupName: token.groupName,
            groupSecret: "conflicting-key", inviterMemberID: "sender")
        let packet = try GroupInvitationEnvelope.seal(conflict, sender: author, recipient: recipient,
            recipientMemberID: "local", recipientKey: b.publicKey, signer: a)
        let saved = try f.file.read()
        #expect(try repository.stageGroupDelivery(packet, token: conflict, now: now) == .cancelled)
        #expect(try f.file.read() == saved)
        let duplicateGroup = try GroupInvitationEnvelope.seal(token, sender: author, recipient: recipient,
            recipientMemberID: "local", recipientKey: b.publicKey, signer: a)
        #expect(try repository.stageGroupDelivery(duplicateGroup, token: opened, now: now) == .pending)
        try repository.delete(token.groupID, remaining: [])
        #expect(repository.groupDeliveries.last?.state == .cancelled)
        #expect(try repository.receiveGroupDelivery(duplicateGroup, token: opened, localDisplayName: "You", now: now) == nil)
        let after = try f.file.read()
        #expect(try repository.stageGroupDelivery(envelope, token: opened, now: now) == .received)
        try repository.receiveGroupDelivery(envelope, token: opened, localDisplayName: "You", now: now)
        #expect(try f.file.read() == after)
        #expect(repository.storedGroup(token.groupID) == nil)

        let pending = try GroupInvitationEnvelope.seal(token, sender: author, recipient: recipient,
            recipientMemberID: "local", recipientKey: b.publicKey, signer: a)
        #expect(try repository.stageGroupDelivery(pending, token: opened, now: now) == .pending)
        let pendingReference = try #require(repository.groupDeliveries.last?.credentialReference)
        _ = try repository.removeUser(user.id)
        #expect(f.keys.values[pendingReference] == nil)
        #expect(repository.groupDeliveries.last?.state == .cancelled)
        #expect(try repository.receiveGroupDelivery(pending, token: opened, localDisplayName: "You", now: now) == nil)
        #expect(repository.storedGroup(token.groupID) == nil)
    }

    @Test func upgradingSchemaTenKeepsTheSamePendingPerson() throws {
        let person = SavedUser(displayName: "Saved nickname", memberIDs: [], localName: "Saved nickname")
        let record = ContactInvitationRecord(id: UUID(), direction: .outgoing, expiresAt: Date().addingTimeInterval(86400).timeIntervalSince1970,
            credentialReference: UUID(), nickname: person.resolvedDisplayName, personID: person.id)
        var old = GroupSnapshot(users: [person], contactInvitations: [record]); old.version = 10
        let upgraded = old.upgraded()
        #expect(upgraded.version == GroupSnapshot.currentVersion && upgraded.users == [person])
        #expect(upgraded.contactInvitations.first?.personID == person.id && upgraded.groupDeliveries.isEmpty)
    }

}
