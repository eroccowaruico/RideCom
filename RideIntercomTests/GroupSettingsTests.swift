import Foundation
import Testing
@testable import RideIntercom

/// Group Settings opens from the call's menu and from list rows; renaming keeps the call.
@MainActor
struct GroupSettingsTests {
    @Test func renamingAGroupSavesTheTrimmedName() throws {
        let testHarness = try harness(); let viewModel = testHarness.viewModel
        let group = viewModel.groups[0]
        #expect(viewModel.renameGroup(group.id, to: "  Weekend Ride  "))
        #expect(viewModel.groups.first { $0.id == group.id }?.name == "Weekend Ride")
        #expect(testHarness.groupStore.snapshot.groups.first { $0.id == group.id }?.name == "Weekend Ride")
    }

    @Test func renamingTheShownCallUpdatesItWithoutReconnecting() throws {
        let testHarness = try harness(); let viewModel = testHarness.viewModel
        defer { viewModel.disconnect() }
        let group = viewModel.groups[0]
        #expect(viewModel.openDestination(.group(group.id)) == .opened)
        let reference = viewModel.currentCallReference
        #expect(viewModel.renameGroup(group.id, to: "Weekend Ride"))
        #expect(viewModel.selectedGroup?.name == "Weekend Ride")
        #expect(viewModel.currentCallReference == reference)
    }

    @Test func invalidNamesAreRejected() throws {
        let testHarness = try harness(); let viewModel = testHarness.viewModel
        let group = viewModel.groups[0]
        #expect(!viewModel.renameGroup(group.id, to: "   "))
        #expect(!viewModel.renameGroup(group.id, to: "A|B"))
        #expect(viewModel.groups[0].name == "First")
        #expect(viewModel.groupErrorMessage != nil)
    }

    /// Whoever made a group owns it and deletes it; someone who joined through an invitation can only leave.
    @Test func theGroupsMakerOwnsItAndAJoinerOnlyLeaves() throws {
        let ownerDevice = AppTestSupport.makeHarness(groups: [], localMemberID: "owner-maker")
        let joiningDevice = AppTestSupport.makeHarness(groups: [], localMemberID: "owner-joiner")
        defer { ownerDevice.viewModel.disconnect(); joiningDevice.viewModel.disconnect() }
        #expect(ownerDevice.viewModel.createTalkGroup(name: "Weekend"))
        let groupID = try #require(ownerDevice.viewModel.selectedGroup?.id)
        try joiningDevice.viewModel.acceptInviteURL(#require(ownerDevice.viewModel.makeSelectedGroupInviteURL()))
        #expect(ownerDevice.viewModel.groupRepository.ownsGroup(groupID))
        #expect(!joiningDevice.viewModel.groupRepository.ownsGroup(groupID))
        // Leaving removes it from this device only.
        joiningDevice.viewModel.deleteGroup(groupID)
        #expect(!joiningDevice.viewModel.groups.contains { $0.id == groupID })
        #expect(ownerDevice.viewModel.groups.contains { $0.id == groupID })
    }

    private func harness() throws -> AppTestSupport.Harness {
        let first = try IntercomGroup(
            name: "First", members: [.init(id: "local", displayName: "You")], accessSecret: "group-key")
        return AppTestSupport.makeHarness(groups: [first])
    }
}
