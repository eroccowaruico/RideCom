import Foundation
import Testing
@testable import RideIntercom

/// Choosing someone from a list connects at once; a different live call is only
/// replaced after the person confirms the switch.
@MainActor
struct DestinationOpeningTests {
    @Test func choosingWhileIdleConnectsImmediately() throws {
        let harness = try harness(); let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let first = viewModel.groups[0]
        #expect(viewModel.openDestination(.group(first.id)) == .opened)
        #expect(viewModel.activeGroupID == first.id && viewModel.selectedGroup?.id == first.id)
        #expect(viewModel.hasAnyActiveGroupConnection)
    }

    @Test func choosingTheCurrentCallReopensItWithoutReconnecting() throws {
        let harness = try harness(); let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let first = viewModel.groups[0], second = viewModel.groups[1]
        #expect(viewModel.openDestination(.group(first.id)) == .opened)
        let reference = viewModel.currentCallReference
        viewModel.selectGroup(second, connectIfIdle: false)
        #expect(viewModel.openDestination(.group(first.id)) == .opened)
        #expect(viewModel.currentCallReference == reference)
        #expect(viewModel.selectedGroup?.id == first.id)
    }

    /// A connection is one place at a time: another choice shows the live call and never switches or asks.
    @Test func choosingAnotherDestinationDuringACallShowsTheLiveCall() throws {
        let harness = try harness(); let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let first = viewModel.groups[0], second = viewModel.groups[1]
        #expect(viewModel.openDestination(.group(first.id)) == .opened)
        let reference = viewModel.currentCallReference
        #expect(viewModel.openDestination(.group(second.id)) == .showsLiveCall)
        #expect(viewModel.activeGroupID == first.id && viewModel.currentCallReference == reference)
        #expect(viewModel.selectedGroup?.id == first.id)
        #expect(viewModel.groupErrorMessage == nil)
    }

    /// Leaving takes ending the call; then the next choice connects there.
    @Test func afterEndingTheCallTheNextChoiceConnects() throws {
        let harness = try harness(); let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let first = viewModel.groups[0], second = viewModel.groups[1]
        #expect(viewModel.openDestination(.group(first.id)) == .opened)
        #expect(viewModel.endCall(viewModel.currentCallReference))
        #expect(viewModel.openDestination(.group(second.id)) == .opened)
        #expect(viewModel.activeGroupID == second.id && viewModel.hasAnyActiveGroupConnection)
    }

    private func harness() throws -> AppTestSupport.Harness {
        let first = try IntercomGroup(
            name: "First", members: [.init(id: "local", displayName: "You")], accessSecret: "group-key")
        let second = try IntercomGroup(
            name: "Second", members: [.init(id: "local", displayName: "You")], accessSecret: "second-key")
        return AppTestSupport.makeHarness(groups: [first, second])
    }
}
