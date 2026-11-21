import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct UserDirectoryTests {
    @Test func groupMemberCannotClaimAnUnissuedDirectInvitation() throws {
        let harness = AppTestSupport.makeHarness(groups: [try group()])
        let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let group = try #require(viewModel.groups.first)
        viewModel.selectGroup(group)
        harness.callSession.authenticate(["stranger"])
        let receipt = DirectInvitationReceipt(
            groupID: group.id, inviterMemberID: "local", inviteeMemberID: "stranger", displayName: "Not a friend")
        viewModel.handleTransportEvent(
            .receivedApplicationData(
                peerID: "stranger",
                message: .init(
                    namespace: DirectInvitationReceipt.namespace, payload: try JSONEncoder().encode(receipt))))
        #expect(viewModel.savedUsers.isEmpty)
        #expect(harness.groupStore.snapshot.users.isEmpty)
    }

    @Test func directInvitationsStillSaveAfterCorruptionReset() throws {
        let fixture = try GroupStorageFixture(); defer { fixture.remove() }
        try Data("broken".utf8).write(to: fixture.file.url)
        let repository = fixture.restart()
        #expect(throws: (any Error).self) { try repository.load(localMemberID: "local") }
        try repository.reset()
        let group = try group()
        try repository.save(
            [group], credential: .init(groupID: group.id, secret: "key"),
            acceptedInvitation: testAcceptedInvitation(groupID: group.id, inviter: group.members[1]))
        #expect(repository.users.map(\.memberIDs) == [["rider"]])
        #expect(repository.pendingInvitation(for: group.id)?.inviteeMemberID == "local")
    }

    @Test func groupPresenceDoesNotSaveUnrelatedPeople() throws {
        let harness = AppTestSupport.makeHarness(groups: [try group()])
        let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        #expect(viewModel.savedUsers.isEmpty)
        viewModel.selectGroup(try #require(viewModel.groups.first))
        harness.callSession.authenticate(["rider", "stranger"])
        #expect(!viewModel.groups[0].members.contains { $0.id == "stranger" })
        let profile = try testPeerProfile(viewModel, peerID: "stranger", displayName: "Stranger")
        viewModel.receiveSharedDisplayName(
            peerID: "stranger",
            message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(profile)))
        #expect(viewModel.groups[0].members.contains { $0.id == "stranger" })
        #expect(viewModel.savedUsers.isEmpty)
        #expect(harness.groupStore.snapshot.users.isEmpty)
        let count = viewModel.groups.count
        #expect(!viewModel.createTalkGroup(userIDs: [UUID()]))
        #expect(!viewModel.addSavedUsers([UUID()], to: try #require(viewModel.groups.first).id))
        #expect(viewModel.groups.count == count)
    }

    @Test func removingSavedUserPreservesGroupAndActiveCall() throws {
        let harness = try invitedHarness()
        let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        viewModel.selectGroup(try #require(viewModel.groups.first))
        harness.callSession.authenticate(["rider"])
        let group = try #require(viewModel.selectedGroup)
        let user = try #require(viewModel.savedRemoteUsers.first)
        let disconnects = harness.callSession.disconnectCallCount
        #expect(viewModel.removeSavedUser(user.id))
        #expect(viewModel.savedRemoteUsers.isEmpty)
        #expect(viewModel.selectedGroup?.members.map(\.id) == group.members.map(\.id))
        #expect(viewModel.authenticatedPeerIDs == ["rider"])
        #expect(harness.callSession.disconnectCallCount == disconnects)
        #expect(harness.groupStore.snapshot.groups[0].members.last?.userID == nil)
        #expect(viewModel.commitGroups(viewModel.groups))
        #expect(viewModel.savedRemoteUsers.isEmpty)
    }

    @Test func directInvitationReceiptIsAddressedAuthenticatedAndAcknowledged() throws {
        let harness = AppTestSupport.makeHarness(groups: [try group()])
        let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let group = try #require(viewModel.groups.first)
        viewModel.selectGroup(group)
        var receipt = try testInvitationReceipt(
            groupID: group.id, inviter: .init(id: "local", displayName: "You"), invitee: "rider",
            authority: viewModel.invitationAuthority)
        func deliver(_ value: DirectInvitationReceipt, peer: String = "rider") throws {
            viewModel.handleTransportEvent(
                .receivedApplicationData(
                    peerID: peer,
                    message: .init(
                        namespace: DirectInvitationReceipt.namespace, payload: try JSONEncoder().encode(value))))
        }
        try deliver(receipt)
        #expect(viewModel.savedUsers.isEmpty) // Not authenticated yet.
        harness.callSession.authenticate(["rider", "stranger"])
        var unrelated = receipt; unrelated.inviterMemberID = "stranger"
        try deliver(unrelated)
        try deliver(receipt, peer: "stranger")
        #expect(viewModel.savedUsers.isEmpty)
        try deliver(receipt)
        let user = try #require(viewModel.savedRemoteUsers.first)
        #expect(user.memberIDs == ["rider"])
        let ack = try #require(harness.callSession.sentApplicationDataMessages.last)
        #expect(try JSONDecoder().decode(DirectInvitationReceipt.self, from: ack.payload).kind == .acknowledged)
        #expect(viewModel.removeSavedUser(user.id))
        try deliver(receipt) // A retry cannot undo explicit deletion.
        #expect(viewModel.savedUsers.isEmpty)
        receipt.id = UUID() // Altering a replay cannot undo deletion.
        try deliver(receipt)
        #expect(viewModel.savedRemoteUsers.isEmpty)
        receipt = try testInvitationReceipt(
            groupID: group.id, inviter: .init(id: "local", displayName: "You"), invitee: "rider",
            authority: viewModel.invitationAuthority)
        try deliver(receipt)
        #expect(viewModel.savedRemoteUsers.count == 1)
    }

    @Test func invitationReceiptSurvivesRestartAndDeletionDoesNotReplay() throws {
        let fixture = try GroupStorageFixture(); defer { fixture.remove() }
        let group = try group()
        try fixture.repository.save(
            [group], credential: .init(groupID: group.id, secret: "key"),
            acceptedInvitation: testAcceptedInvitation(groupID: group.id, inviter: group.members[1]))
        let pending = try #require(fixture.repository.pendingInvitation(for: group.id))
        let restarted = fixture.restart()
        _ = try restarted.load(localMemberID: "local")
        #expect(restarted.pendingInvitation(for: group.id) == pending)
        let acknowledgement = try pending.acknowledged(by: testIdentitySigner(pending.inviterMemberID))
        try restarted.acknowledgeInvitation(acknowledgement)
        #expect(restarted.pendingInvitation(for: group.id) == nil)
        let authority = testInvitationAuthority()
        let receipt = try testInvitationReceipt(
            groupID: group.id, inviter: .init(id: "local", displayName: "You"), invitee: "rider",
            authority: authority)
        try restarted.receiveInvitation(#require(try authority.verify(receipt)))
        try restarted.removeUser(try #require(restarted.users.first).id)
        let again = fixture.restart()
        #expect(try again.load(localMemberID: "local").first?.members.count == 2)
        try again.receiveInvitation(#require(try authority.verify(receipt)))
        #expect(again.users.isEmpty)
        #expect(try again.credential(for: group.id)?.secret == "key")
    }

    @Test func acceptedInvitationReceiptWaitsForItsAuthenticatedInviter() throws {
        let harness = try invitedHarness()
        let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let group = try #require(viewModel.groups.first)
        viewModel.selectGroup(group)
        viewModel.sendPendingInvitationReceipt()
        #expect(harness.callSession.sentApplicationDataMessages.isEmpty)
        harness.callSession.authenticate(["rider", "stranger"])
        let sent = try #require(harness.callSession.sentApplicationDataMessages.last)
        var receipt = try JSONDecoder().decode(DirectInvitationReceipt.self, from: sent.payload)
        #expect(receipt.inviterMemberID == "rider")
        receipt = try receipt.acknowledged(by: testIdentitySigner(receipt.inviterMemberID))
        var unrelated = receipt; unrelated.inviterMemberID = "stranger"
        viewModel.handleTransportEvent(
            .receivedApplicationData(
                peerID: "stranger",
                message: .init(
                    namespace: DirectInvitationReceipt.namespace, payload: try JSONEncoder().encode(unrelated))))
        #expect(viewModel.groupRepository.pendingInvitation(for: group.id) != nil)
        viewModel.handleTransportEvent(
            .receivedApplicationData(
                peerID: "rider",
                message: .init(
                    namespace: DirectInvitationReceipt.namespace, payload: try JSONEncoder().encode(receipt))))
        #expect(viewModel.groupRepository.pendingInvitation(for: group.id) == nil)
        let count = harness.callSession.sentApplicationDataMessages.count
        viewModel.broadcastMetadataKeepalive()
        #expect(harness.callSession.sentApplicationDataMessages.count == count)
    }

    @Test func savedUserCanBeRemovedAfterLastGroupWasDeleted() throws {
        let harness = try invitedHarness()
        let viewModel = harness.viewModel
        let rider = try #require(viewModel.savedRemoteUsers.first)
        viewModel.deleteGroup(try #require(viewModel.groups.first).id)
        #expect(viewModel.savedRemoteUsers == [rider])
        #expect(viewModel.removeSavedUser(rider.id))
        #expect(viewModel.savedRemoteUsers.isEmpty)
        viewModel.reloadSavedGroups()
        #expect(viewModel.savedRemoteUsers.isEmpty)
        #expect(!harness.groupStore.snapshot.users.contains { $0.id == rider.id })
    }

    private func invitedHarness() throws -> AppTestSupport.Harness {
        let group = try group()
        let harness = AppTestSupport.makeHarness(groups: [group])
        try harness.viewModel.groupRepository.acceptInvitation(
            testAcceptedInvitation(groupID: group.id, inviter: group.members[1]),
            inviterName: group.members[1].displayName)
        harness.viewModel.refreshGroupStorageStatus()
        return harness
    }

    private func group() throws -> IntercomGroup {
        try IntercomGroup(name: "Friends", members: [
            .init(id: "local", displayName: "You"), .init(id: "rider", displayName: "Rider")
        ], accessSecret: "fixture-group-secret")
    }

}

extension UserDirectoryTests {
    @Test func oldManifestMigratesOnceWithoutChangingGroupKeys() throws {
        let fixture = try GroupStorageFixture(); defer { fixture.remove() }
        let group = try group()
        try fixture.repository.save([group], credential: .init(groupID: group.id, secret: "key"))
        var json = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.file.url)) as? [String: Any])
        json["version"] = 1; json.removeValue(forKey: "users")
        let old = try JSONSerialization.data(withJSONObject: json)
        try old.write(to: fixture.file.url)
        fixture.store.failCommit = true
        #expect(throws: (any Error).self) { try fixture.restart().load(localMemberID: "local") }
        #expect(try Data(contentsOf: fixture.file.url) == old)
        #expect(fixture.keys.values.values.sorted() == ["key"])
        fixture.store.failCommit = false
        let restarted = fixture.restart()
        #expect(try restarted.load(localMemberID: "local").map(\.id) == [group.id])
        #expect(try restarted.credential(for: group.id)?.secret == "key")
        #expect(try fixture.file.read()?.version == GroupSnapshot.currentVersion)
        let again = fixture.restart()
        _ = try again.load(localMemberID: "local")
        #expect(again.users == restarted.users)
        #expect(again.users.isEmpty) // Legacy group membership cannot prove a direct invitation.
    }

    @Test func invalidCurrentDirectoryIsNeverSilentlyRecreated() throws {
        let fixture = try GroupStorageFixture(); defer { fixture.remove() }
        let group = try group()
        try fixture.repository.save(
            [group], credential: .init(groupID: group.id, secret: "key"),
            acceptedInvitation: testAcceptedInvitation(groupID: group.id, inviter: group.members[1]))
        let original = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.file.url)) as? [String: Any])
        for badUsers: Any? in [nil, "broken", [] as [Any]] {
            var json = original
            json["users"] = badUsers
            let bytes = try JSONSerialization.data(withJSONObject: json)
            try bytes.write(to: fixture.file.url)
            #expect(throws: (any Error).self) { try fixture.restart().load(localMemberID: "local") }
            #expect(try Data(contentsOf: fixture.file.url) == bytes)
        }
    }

    @Test func placeholdersAreExcludedAndNamesDoNotMergeDifferentPeople() throws {
        let fixture = try GroupStorageFixture(); defer { fixture.remove() }
        var first = try group()
        first.members.append(.init(id: "invite-pending-slot", displayName: "Invite"))
        let second = try IntercomGroup(name: "Other", members: [
            .init(id: "local", displayName: "You"), .init(id: "other-rider", displayName: "Rider")
        ])
        try fixture.repository.save(
            [first, second], credential: .init(groupID: first.id, secret: "key"),
            acceptedInvitation: testAcceptedInvitation(groupID: first.id, inviter: first.members[1]))
        try fixture.repository.acceptInvitation(
            testAcceptedInvitation(groupID: second.id, inviter: second.members[1]),
            inviterName: second.members[1].displayName)
        #expect(fixture.repository.users.count == 2)
        #expect(fixture.repository.users.filter { $0.displayName == "Rider" }.count == 2)
        #expect(!fixture.repository.users.flatMap(\.memberIDs).contains("invite-pending-slot"))
        let saved = fixture.repository.users
        try fixture.repository.save([first])
        #expect(fixture.repository.users == saved)
        let snapshot = try #require(try fixture.file.read())
        for member in snapshot.groups[0].members where !member.id.hasPrefix(GroupMember.pendingInvitePrefix) {
            #expect(member.userID == saved.first { $0.memberIDs.contains(member.id) }?.id)
        }
    }

    @Test func renamingUpdatesEveryGroupAndSurvivesDeletionAndRestart() throws {
        let fixture = try GroupStorageFixture(); defer { fixture.remove() }
        let first = try group()
        let second = try IntercomGroup(name: "Other", members: first.members)
        try fixture.repository.save(
            [first, second], credential: .init(groupID: first.id, secret: "key"),
            acceptedInvitation: testAcceptedInvitation(groupID: first.id, inviter: first.members[1]))
        let user = try #require(fixture.repository.users.first { $0.memberIDs == ["rider"] })
        let stale = fixture.restart()
        _ = try stale.load(localMemberID: "local")
        try fixture.repository.renameUser(user.id, displayName: "Alex")
        #expect(throws: GroupStorageError.changedByAnotherProcess) {
            try stale.renameUser(user.id, displayName: "Stale")
        }
        // Older group data must not undo a name edited in the directory.
        try fixture.repository.save([first, second])
        let restarted = fixture.restart()
        let groups = try restarted.load(localMemberID: "local")
        #expect(groups.allSatisfy { $0.members.last?.resolvedDisplayName == "Alex" })
        #expect(try restarted.credential(for: first.id)?.secret == "key")
        fixture.store.failCommit = true
        #expect(throws: (any Error).self) { try restarted.renameUser(user.id, displayName: "Lost") }
        #expect(restarted.users.first { $0.id == user.id }?.resolvedDisplayName == "Alex")
        fixture.store.failCommit = false
        _ = try restarted.load(localMemberID: "local")
        try restarted.save([])
        #expect(restarted.users.first { $0.id == user.id }?.resolvedDisplayName == "Alex")
    }

    @Test func userSelectionCreatesGroupsAndAddsMembersWithoutAuthenticatingThem() throws {
        let harness = try invitedHarness()
        let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let rider = try #require(viewModel.savedRemoteUsers.first)
        viewModel.deleteGroup(try #require(viewModel.groups.first).id)
        #expect(viewModel.groups.isEmpty)
        #expect(viewModel.savedRemoteUsers == [rider])
        #expect(viewModel.createTalkGroup(name: "Weekend", userIDs: [rider.id]))
        let created = try #require(viewModel.groups.first)
        #expect(created.name == "Weekend")
        #expect(created.members.map(\.id) == ["local", "rider"])
        #expect(viewModel.authenticatedPeerIDs.isEmpty)
        #expect(try viewModel.credential(for: created) != nil)
        #expect(viewModel.renameSavedUser(rider.id, displayName: "Alex"))
        #expect(viewModel.selectedGroup?.members.last?.resolvedDisplayName == "Alex")
        viewModel.disconnect()
        #expect(viewModel.createTalkGroup())
        let solo = try #require(viewModel.groups.first)
        #expect(viewModel.addSavedUsers([rider.id], to: solo.id))
        #expect(viewModel.selectedGroup?.members.last?.resolvedDisplayName == "Alex")
        #expect(!viewModel.addSavedUsers([rider.id], to: solo.id))
        #expect(!viewModel.createTalkGroup(userIDs: [UUID()]))
        #expect(viewModel.groups.count == 2)
    }

    @Test func userSelectionRejectsExcessMembersAndPreservesGroupsOnWriteFailure() throws {
        let harness = try invitedHarness()
        let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let rider = try #require(viewModel.savedRemoteUsers.first)
        let full = try IntercomGroup(name: "Full", members: [.init(id: "local", displayName: "You")]
            + (1...7).map { .init(id: "other-\($0)", displayName: "Other \($0)") })
        #expect(viewModel.commitGroups(viewModel.groups + [full]))
        #expect(!viewModel.addSavedUsers([rider.id], to: full.id))
        let before = viewModel.groups
        harness.groupStore.failSaving = true
        #expect(!viewModel.renameSavedUser(rider.id, displayName: "Lost"))
        #expect(viewModel.groups == before)
        #expect(viewModel.savedRemoteUsers.contains { $0.id == rider.id && $0.displayName == "Rider" })
    }

    @Test func deletingLastGroupPreservesUsersAcrossRestart() throws {
        let fixture = try GroupStorageFixture(); defer { fixture.remove() }
        let group = try IntercomGroup(name: "Friends", members: [
            .init(id: "local", displayName: "You"), .init(id: "rider", displayName: "Rider")
        ])
        try fixture.repository.save(
            [group], credential: .init(groupID: group.id, secret: "group-key"),
            acceptedInvitation: testAcceptedInvitation(groupID: group.id, inviter: group.members[1]))
        let before = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.file.url)) as? [String: Any])
        let users = try #require(before["users"] as? [[String: Any]])
        #expect(users.count == 1)
        let ids = Set(users.compactMap { $0["id"] as? String })
        try fixture.repository.delete(group.id, remaining: [])
        #expect(try fixture.restart().load(localMemberID: "local").isEmpty)
        let after = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.file.url)) as? [String: Any])
        let retained = try #require(after["users"] as? [[String: Any]])
        #expect(Set(retained.compactMap { $0["id"] as? String }) == ids)
        #expect(fixture.keys.references().isEmpty)
    }
}
