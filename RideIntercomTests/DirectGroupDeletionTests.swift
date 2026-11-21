import Foundation
import Testing
@testable import RideIntercom

/// A saved person and their direct group are one thing: deleting the person deletes the group.
@MainActor
struct DirectGroupDeletionTests {
    @Test func removingUserDeletesTheirDirectGroupAndKeyButKeepsRegularGroups() throws {
        let fixture = try GroupStorageFixture(); defer { fixture.remove() }
        let (regular, direct) = try saveRiderInRegularAndDirectGroups(fixture.repository)
        let user = try #require(fixture.repository.users.first)

        let removed = try fixture.repository.removeUser(user.id)

        #expect(removed == [direct.id])
        let restarted = fixture.restart()
        let groups = try restarted.load(localMemberID: "local")
        #expect(groups.map(\.id) == [regular.id])
        #expect(groups[0].members.map(\.id) == ["local", "rider"])
        #expect(restarted.users.isEmpty)
        #expect(try restarted.credential(for: direct.id) == nil)
        #expect(try restarted.credential(for: regular.id)?.secret == "regular-key")
        #expect(fixture.keys.values.values.sorted() == ["regular-key"])
    }

    @Test func failedRemovalKeepsBothUserAndDirectGroup() throws {
        let fixture = try GroupStorageFixture(); defer { fixture.remove() }
        let (_, direct) = try saveRiderInRegularAndDirectGroups(fixture.repository)
        let user = try #require(fixture.repository.users.first)
        fixture.store.failCommit = true

        #expect(throws: (any Error).self) { try fixture.repository.removeUser(user.id) }

        fixture.store.failCommit = false
        let restarted = fixture.restart()
        #expect(try restarted.load(localMemberID: "local").contains { $0.id == direct.id })
        #expect(restarted.users.map(\.id) == [user.id])
        #expect(try restarted.credential(for: direct.id)?.secret == "direct-key")
    }

    @Test func loadingRemovesDirectGroupsLeftByAnEarlierUserDeletion() throws {
        let fixture = try GroupStorageFixture(); defer { fixture.remove() }
        let (regular, direct) = try saveRiderInRegularAndDirectGroups(fixture.repository)
        // The state an earlier version left: the user is gone, their direct group is not.
        var snapshot = try #require(try fixture.file.read())
        snapshot.users = []
        snapshot.synchronizeUserReferences()
        try fixture.file.commit(snapshot)

        let restarted = fixture.restart()
        let groups = try restarted.load(localMemberID: "local")

        #expect(groups.map(\.id) == [regular.id])
        #expect(try restarted.credential(for: direct.id) == nil)
        #expect(try fixture.file.read()?.groups.map(\.id) == [regular.id])
        #expect(fixture.keys.values.values.sorted() == ["regular-key"])
    }

    @Test func deletingTheUserInACallEndsThatCall() throws {
        let harness = AppTestSupport.makeHarness(groups: [])
        let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        _ = try saveRiderInRegularAndDirectGroups(
            viewModel.groupRepository, local: viewModel.localMemberIdentity.memberID)
        viewModel.groups = try viewModel.groupRepository.load(localMemberID: viewModel.localMemberIdentity.memberID)
        viewModel.refreshGroupStorageStatus()
        let user = try #require(viewModel.savedRemoteUsers.first)
        let direct = try #require(viewModel.existingDirectCall(for: user.id))
        viewModel.selectGroup(direct)
        viewModel.connectLocal()
        #expect(viewModel.activeGroupID == direct.id)

        #expect(viewModel.removeSavedUser(user.id))

        #expect(viewModel.activeGroupID == nil)
        #expect(viewModel.selectedGroup == nil)
        #expect(!viewModel.groups.contains { $0.id == direct.id })
        #expect(viewModel.groups.map(\.kind) == [.group])
    }

    /// One rider, saved through the direct group's invitation, also in a regular group.
    private func saveRiderInRegularAndDirectGroups(_ repository: GroupRepository, local: String = "local") throws
        -> (regular: IntercomGroup, direct: IntercomGroup) {
        let rider = GroupMember(id: "rider", displayName: "Rider")
        let members = [GroupMember(id: local, displayName: "You"), rider]
        let direct = try IntercomGroup(id: IntercomGroup.directCallID(memberIDs: members.map(\.id)),
                                       name: "Direct Call", members: members, kind: .direct)
        try repository.save([direct], credential: .init(groupID: direct.id, secret: "direct-key"),
            acceptedInvitation: testAcceptedInvitation(groupID: direct.id, inviter: rider, invitee: local))
        let regular = try IntercomGroup(name: "Friends", members: members)
        try repository.save([direct, regular], credential: .init(groupID: regular.id, secret: "regular-key"))
        return (regular, direct)
    }
}
