import Foundation
import RTC
import Testing
@testable import RideIntercom

extension DirectCallTests {
    @Test func directCallMoreMenuFollowsTheSavedUser() throws {
        let testHarness = try harness(local: "alice", remote: "bob")
        let viewModel = testHarness.viewModel
        defer { viewModel.disconnect() }
        let user = try #require(viewModel.savedRemoteUsers.first)
        #expect(viewModel.selectUser(user.id))
        let direct = try #require(viewModel.selectedGroup)
        #expect(viewModel.savedUserID(forDirectCall: direct) == user.id)
        #expect(viewModel.existingDirectCall(for: user.id)?.id == direct.id)
        viewModel.connectLocal()
        #expect(viewModel.isInCall(with: .user(user.id)))
        #expect(viewModel.removeSavedUser(user.id))
        #expect(viewModel.savedUserID(forDirectCall: direct) == nil)
        #expect(viewModel.existingDirectCall(for: user.id) == nil)
    }

    @Test func recipientBoundInviteIsSharedAndReusesSameCallOnBothSides() throws {
        let firstPeer = try harness(local: "alice", remote: "bob")
        let secondPeer = try harness(local: "bob", remote: "alice")
        defer { firstPeer.viewModel.disconnect(); secondPeer.viewModel.disconnect() }
        #expect(firstPeer.viewModel.selectUser(try #require(firstPeer.viewModel.savedRemoteUsers.first).id))
        let invite = try #require(firstPeer.viewModel.makeSelectedGroupInviteURL())
        let token = try GroupInviteTokenCodec.decodeJoinURL(invite)
        #expect(token.recipientMemberID == "bob")
        #expect(token.version == 6)
        try secondPeer.viewModel.acceptInviteURL(invite)
        #expect(secondPeer.viewModel.selectedGroup?.kind == .direct)
        let id = try #require(firstPeer.viewModel.selectedGroup?.id)
        #expect(secondPeer.viewModel.selectedGroup?.id == id)
        #expect(
            try firstPeer.viewModel.groupRepository.credential(for: id)
                == secondPeer.viewModel.groupRepository.credential(for: id))
        secondPeer.viewModel.showGroupSelection()
        #expect(secondPeer.viewModel.selectUser(try #require(secondPeer.viewModel.savedRemoteUsers.first).id))
        #expect(secondPeer.viewModel.selectedGroup?.id == id)
        #expect(secondPeer.viewModel.groups.count == 2)
    }

    @Test func forwardedInviteCannotCreateContactOrCallForThirdPerson() throws {
        let firstPeer = try harness(local: "alice", remote: "bob")
        let thirdPeer = try harness(local: "charlie", remote: "dana")
        defer { firstPeer.viewModel.disconnect(); thirdPeer.viewModel.disconnect() }
        #expect(firstPeer.viewModel.selectUser(try #require(firstPeer.viewModel.savedRemoteUsers.first).id))
        let before = thirdPeer.groupStore.snapshot
        let invite = try #require(firstPeer.viewModel.makeSelectedGroupInviteURL())
        #expect(throws: GroupInviteTokenError.wrongRecipient) { try thirdPeer.viewModel.acceptInviteURL(invite) }
        #expect(thirdPeer.viewModel.groupErrorMessage == "This call invitation is addressed to another rider.")
        #expect(thirdPeer.groupStore.snapshot == before)
    }

    @Test func directCallCannotGrowIntoGroup() throws {
        let testHarness = try harness(local: "alice", remote: "bob")
        let viewModel = testHarness.viewModel
        defer { viewModel.disconnect() }
        let user = try #require(viewModel.savedRemoteUsers.first)
        #expect(viewModel.selectUser(user.id))
        let group = try #require(viewModel.selectedGroup)
        let snapshot = testHarness.groupStore.snapshot
        let draft = GroupInvitationDraft(name: "Other rider", suggestedName: "New person")
        #expect(viewModel.saveGroupInvitations(groupID: group.id, creating: false, name: group.name,
                                        selected: [], newPeople: [draft]) == nil)
        #expect(testHarness.groupStore.snapshot == snapshot)
        viewModel.removeMember("bob", from: group.id)
        #expect(!viewModel.addSavedUsers([user.id], to: group.id))
        #expect(viewModel.selectedGroup?.members.map(\.id) == ["alice", "bob"])
    }

    @Test func simultaneousInvitationsConvergeWithoutCreatingAnotherCall() throws {
        let firstPeer = try harness(local: "alice", remote: "bob")
        let secondPeer = try harness(local: "bob", remote: "alice")
        defer { firstPeer.viewModel.disconnect(); secondPeer.viewModel.disconnect() }
        #expect(firstPeer.viewModel.selectUser(try #require(firstPeer.viewModel.savedRemoteUsers.first).id))
        #expect(secondPeer.viewModel.selectUser(try #require(secondPeer.viewModel.savedRemoteUsers.first).id))
        let conflictingCallID = try #require(secondPeer.viewModel.selectedGroup?.id)
        try secondPeer.viewModel.groupRepository.save(secondPeer.viewModel.groups, credential: .init(
            groupID: conflictingCallID, secret: "bob-conflicting-direct-call-fixture"
        ))
        let left = try #require(firstPeer.viewModel.makeSelectedGroupInviteURL())
        let right = try #require(secondPeer.viewModel.makeSelectedGroupInviteURL())
        try firstPeer.viewModel.acceptInviteURL(right)
        #expect(firstPeer.viewModel.crossedDirectCallToShare?.id == firstPeer.viewModel.selectedGroup?.id)
        try secondPeer.viewModel.acceptInviteURL(left)
        #expect(secondPeer.viewModel.crossedDirectCallToShare == nil)
        let id = try #require(firstPeer.viewModel.selectedGroup?.id)
        #expect(
            try firstPeer.viewModel.groupRepository.credential(for: id)
                == secondPeer.viewModel.groupRepository.credential(for: id))
        #expect(firstPeer.viewModel.groups.count == 2)
        #expect(secondPeer.viewModel.groups.count == 2)
        firstPeer.viewModel.showGroupSelection()
        #expect(firstPeer.viewModel.crossedDirectCallToShare == nil)
    }

    @Test func directCallSurvivesRestartAndRenamingWithoutChangingKey() throws {
        let testHarness = try harness(local: "alice", remote: "bob")
        let viewModel = testHarness.viewModel
        defer { viewModel.disconnect() }
        let user = try #require(viewModel.savedRemoteUsers.first)
        #expect(viewModel.selectUser(user.id))
        let id = try #require(viewModel.selectedGroup?.id)
        let key = try viewModel.groupRepository.credential(for: id)
        #expect(viewModel.renameSavedUser(user.id, displayName: "Bobby"))
        #expect(viewModel.selectedCallTitle == "Bobby")
        viewModel.disconnect()
        viewModel.reloadSavedGroups()
        #expect(viewModel.selectUser(user.id))
        #expect(viewModel.selectedGroup?.id == id)
        #expect(viewModel.selectedGroup?.kind == .direct)
        #expect(viewModel.selectedCallTitle == "Bobby")
        #expect(try viewModel.groupRepository.credential(for: id) == key)
        #expect(viewModel.regularGroups.count == 1)
    }

    @Test func failedPersistenceDoesNotSelectOrConnectAnotherCall() throws {
        let testHarness = try harness(local: "alice", remote: "bob")
        let viewModel = testHarness.viewModel
        defer { viewModel.disconnect() }
        let before = testHarness.groupStore.snapshot
        let selected = viewModel.selectedGroup?.id
        testHarness.groupStore.failSaving = true
        #expect(!viewModel.selectUser(try #require(viewModel.savedRemoteUsers.first).id))
        #expect(testHarness.groupStore.snapshot == before)
        #expect(viewModel.selectedGroup?.id == selected)
        #expect(viewModel.activeGroupID == selected)
    }

    @Test func unexpectedAuthenticatedParticipantStopsDirectCall() throws {
        let testHarness = try harness(local: "alice", remote: "bob")
        let viewModel = testHarness.viewModel
        defer { viewModel.disconnect() }
        #expect(viewModel.selectUser(try #require(viewModel.savedRemoteUsers.first).id))
        viewModel.connectLocal()
        testHarness.callSession.authenticate(["stranger"])
        #expect(viewModel.activeGroupID == nil)
        #expect(viewModel.authenticatedPeerIDs.isEmpty)
        #expect(viewModel.selectedGroup?.members.map(\.id) == ["alice", "bob"])
        #expect(viewModel.groupErrorMessage != nil)
    }

    @Test func versionTwoMigrationPreservesUsersAndKeysAndRejectsMissingCurrentKind() throws {
        let testFixture = try GroupStorageFixture(); defer { testFixture.remove() }
        let group = try IntercomGroup(
            name: "Riders",
            members: [.init(id: "local", displayName: "You"), .init(id: "rider", displayName: "Rider")])
        try testFixture.repository.save(
            [group], credential: .init(groupID: group.id, secret: "key"),
            acceptedInvitation: testAcceptedInvitation(groupID: group.id, inviter: group.members[1]))
        let users = testFixture.repository.users
        var json = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: testFixture.file.url)) as? [String: Any])
        var records = try #require(json["groups"] as? [[String: Any]])
        records[0].removeValue(forKey: "kind")
        json["groups"] = records
        // Missing kind in schema 3 must not silently turn a direct call into a group.
        try JSONSerialization.data(withJSONObject: json).write(to: testFixture.file.url)
        #expect(throws: (any Error).self) { try testFixture.restart().load(localMemberID: "local") }
        json["version"] = 2
        records[0].removeValue(forKey: "invitationDeviceKeys")
        json["groups"] = records
        let old = try JSONSerialization.data(withJSONObject: json)
        try old.write(to: testFixture.file.url)
        testFixture.store.failCommit = true
        #expect(throws: (any Error).self) { try testFixture.restart().load(localMemberID: "local") }
        #expect(try Data(contentsOf: testFixture.file.url) == old)
        testFixture.store.failCommit = false
        let restarted = testFixture.restart()
        #expect(try restarted.load(localMemberID: "local").first?.kind == .group)
        #expect(restarted.users == users)
        #expect(try restarted.credential(for: group.id)?.secret == "key")
        #expect(try testFixture.file.read()?.version == GroupSnapshot.currentVersion)
    }

    @Test func tamperedRecipientOrGroupKindCannotReinterpretExistingCall() throws {
        let testHarness = try harness(local: "alice", remote: "bob")
        let viewModel = testHarness.viewModel
        defer { viewModel.disconnect() }
        #expect(viewModel.selectUser(try #require(viewModel.savedRemoteUsers.first).id))
        let id = try #require(viewModel.selectedGroup?.id)
        let key = try #require(try viewModel.groupRepository.credential(for: id)).secret
        let groupInvite = try GroupInviteToken.make(
            authority: testInvitationAuthority(), signer: testIdentitySigner("bob"),
            credential: .init(groupID: id, secret: key), groupName: "Direct Call", inviterMemberID: "bob")
        #expect(throws: GroupInviteTokenError.incompatibleCall) {
            try viewModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: groupInvite))
        }
        let token = try GroupInviteTokenCodec.decodeJoinURL(#require(viewModel.makeSelectedGroupInviteURL()))
        let tampered = try GroupInviteToken(version: 6,
            groupID: IntercomGroup.directCallID(memberIDs: ["alice", "charlie"]), groupName: token.groupName,
            groupSecret: token.groupSecret, inviterMemberID: "alice", recipientMemberID: "charlie",
            issuedAt: token.issuedAt, expiresAt: token.expiresAt,
            directInvitation: testInvitationAuthority().issue(
                .init(
                    groupID: IntercomGroup.directCallID(memberIDs: ["alice", "charlie"]), inviterMemberID: "alice",
                    inviterDeviceKey: testIdentitySigner("alice").publicKey, recipientMemberID: "charlie",
                    expiresAt: try #require(token.expiresAt))), signature: token.signature,
            identityProof: token.identityProof)
        #expect(throws: GroupInviteTokenError.invalidSignature) {
            try GroupInviteTokenCodec.decodeJoinURL(GroupInviteTokenCodec.joinURL(for: tampered))
        }
        #expect(viewModel.selectedGroup?.kind == .direct)
    }

    func harness(local: String, remote: String) throws -> AppTestSupport.Harness {
        let group = try IntercomGroup(
            name: "Riders", members: [.init(id: local, displayName: "You")], accessSecret: "original-key")
        let testHarness = AppTestSupport.makeHarness(groups: [group])
        let token = try GroupInviteToken.make(
            authority: testInvitationAuthority(), signer: testIdentitySigner(remote),
            credential: .init(groupID: group.id, secret: "original-key"), groupName: group.name,
            inviterMemberID: remote)
        try testHarness.viewModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
        return testHarness
    }
}
