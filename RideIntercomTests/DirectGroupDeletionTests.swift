import Foundation
import Testing
@testable import RideIntercom

/// A saved person and their direct group are one thing: deleting the person deletes the group.
@MainActor
struct DirectGroupDeletionTests {
    @Test func removingUserDeletesTheirDirectGroupAndKeyButKeepsRegularGroups() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let (regular, direct) = try saveRiderInRegularAndDirectGroups(f.repository)
        let user = try #require(f.repository.users.first)

        let removed = try f.repository.removeUser(user.id)

        #expect(removed == [direct.id])
        let restarted = f.restart()
        let groups = try restarted.load(localMemberID: "local")
        #expect(groups.map(\.id) == [regular.id])
        #expect(groups[0].members.map(\.id) == ["local", "rider"])
        #expect(restarted.users.isEmpty)
        #expect(try restarted.credential(for: direct.id) == nil)
        #expect(try restarted.credential(for: regular.id)?.secret == "regular-key")
        #expect(f.keys.values.values.sorted() == ["regular-key"])
    }

    @Test func failedRemovalKeepsBothUserAndDirectGroup() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let (_, direct) = try saveRiderInRegularAndDirectGroups(f.repository)
        let user = try #require(f.repository.users.first)
        f.store.failCommit = true

        #expect(throws: (any Error).self) { try f.repository.removeUser(user.id) }

        f.store.failCommit = false
        let restarted = f.restart()
        #expect(try restarted.load(localMemberID: "local").contains { $0.id == direct.id })
        #expect(restarted.users.map(\.id) == [user.id])
        #expect(try restarted.credential(for: direct.id)?.secret == "direct-key")
    }

    @Test func loadingRemovesDirectGroupsLeftByAnEarlierUserDeletion() throws {
        let f = try GroupStorageFixture(); defer { f.remove() }
        let (regular, direct) = try saveRiderInRegularAndDirectGroups(f.repository)
        // The state an earlier version left: the user is gone, their direct group is not.
        var snapshot = try #require(try f.file.read())
        snapshot.users = []
        snapshot.synchronizeUserReferences()
        try f.file.commit(snapshot)

        let restarted = f.restart()
        let groups = try restarted.load(localMemberID: "local")

        #expect(groups.map(\.id) == [regular.id])
        #expect(try restarted.credential(for: direct.id) == nil)
        #expect(try f.file.read()?.groups.map(\.id) == [regular.id])
        #expect(f.keys.values.values.sorted() == ["regular-key"])
    }

    @Test func deletingTheUserInACallEndsThatCall() throws {
        let h = AppTestSupport.makeHarness(groups: [])
        let vm = h.viewModel
        defer { vm.disconnect() }
        _ = try saveRiderInRegularAndDirectGroups(vm.groupRepository, local: vm.localMemberIdentity.memberID)
        vm.groups = try vm.groupRepository.load(localMemberID: vm.localMemberIdentity.memberID)
        vm.refreshGroupStorageStatus()
        let user = try #require(vm.savedRemoteUsers.first)
        let direct = try #require(vm.existingDirectCall(for: user.id))
        vm.selectGroup(direct)
        vm.connectLocal()
        #expect(vm.activeGroupID == direct.id)

        #expect(vm.removeSavedUser(user.id))

        #expect(vm.activeGroupID == nil)
        #expect(vm.selectedGroup == nil)
        #expect(!vm.groups.contains { $0.id == direct.id })
        #expect(vm.groups.map(\.kind) == [.group])
    }

    /// One rider, saved through the direct group's invitation, also in a regular group.
    private func saveRiderInRegularAndDirectGroups(_ repository: GroupRepository, local: String = "local") throws -> (regular: IntercomGroup, direct: IntercomGroup) {
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
