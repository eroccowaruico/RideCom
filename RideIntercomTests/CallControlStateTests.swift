import CallControl
import Foundation
import Testing
@testable import RideIntercom

/// The destination Control follows the app's published destinations and live call.
struct CallControlStateTests {
    private let user = WidgetCallDestination(id: "user", name: "Haruka", kind: .user)
    private let group = WidgetCallDestination(id: "group", name: "Touring", kind: .group)
    private let observedAt = Date(timeIntervalSince1970: 1_000)
    private let call = CallLivePresentation(
        reference: CallSurfaceReference(accountAccessID: UUID(), connectionGeneration: UUID(), groupID: UUID()),
        status: .inCall, isMuted: false, canControlMicrophone: true)

    @Test func unconfiguredUntilADestinationIsChosen() {
        #expect(CallControlState(configured: nil, snapshot: .init(destinations: [user])) == .unconfigured)
    }

    @Test func readyWhenTheDestinationIsSavedAndNotInACall() {
        let snapshot = WidgetDestinationSnapshot(
            destinations: [user, group], currentDestinationID: group.id, currentCall: call,
            currentCallDeadline: observedAt.addingTimeInterval(60))
        #expect(CallControlState(configured: user, snapshot: snapshot, at: observedAt) == .ready(user))
    }

    @Test func inCallOnlyForTheDestinationOfTheLiveCall() {
        let snapshot = WidgetDestinationSnapshot(
            destinations: [user, group], currentDestinationID: user.id, currentCall: call,
            currentCallDeadline: observedAt.addingTimeInterval(60))
        #expect(
            CallControlState(configured: user, snapshot: snapshot, at: observedAt) == .active(user, status: .inCall))
        #expect(CallControlState(configured: group, snapshot: snapshot, at: observedAt) == .ready(group))
    }

    @Test(arguments: [StandardCallStatus.connecting, .audioPaused, .audioUnavailable])
    func preservesThePublishedStatusOfTheActiveCall(_ status: StandardCallStatus) {
        var active = call
        active.status = status
        let snapshot = WidgetDestinationSnapshot(
            destinations: [user], currentDestinationID: user.id, currentCall: active,
            currentCallDeadline: observedAt.addingTimeInterval(60))
        #expect(CallControlState(configured: user, snapshot: snapshot, at: observedAt) == .active(user, status: status))
    }

    @Test func unavailableWhenTheDestinationWasRemoved() {
        #expect(CallControlState(configured: user, snapshot: .init(destinations: [group])) == .unavailable)
        #expect(CallControlState(configured: user, snapshot: nil) == .unavailable)
    }

    @Test func showsTheCurrentNameFromTheSnapshot() {
        let renamed = WidgetCallDestination(id: user.id, name: "Haruka Y", kind: .user)
        #expect(CallControlState(configured: user, snapshot: .init(destinations: [renamed])) == .ready(renamed))
    }
}
