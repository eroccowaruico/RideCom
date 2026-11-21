import Foundation
import Observation
import SessionManager
import RTC
import Testing
@testable import RideIntercom

@MainActor @Observable
final class CallAccessSourceFixture {
    var now = Date()
    var value = StoreAccessEvaluation(status: .active, activeUntil: .distantFuture)
}

@MainActor
final class CallAccessPair {
    let sourceA = CallAccessSourceFixture(), sourceB = CallAccessSourceFixture()
    let alice: AppTestSupport.Harness, bob: AppTestSupport.Harness
    var aliceMessageIndex = 0, bobMessageIndex = 0
    init() throws {
        sourceB.now = sourceA.now
        let sourceA = sourceA, sourceB = sourceB
        alice = AppTestSupport.makeHarness(groups: [], localMemberID: "alice", enforceCallAccess: true,
            callAccessEvaluation: { _ in sourceA.value }, callAccessNow: { sourceA.now })
        bob = AppTestSupport.makeHarness(groups: [], localMemberID: "bob", enforceCallAccess: true,
            callAccessEvaluation: { _ in sourceB.value }, callAccessNow: { sourceB.now })
        #expect(alice.viewModel.createTalkGroup(name: "Local friends"))
        try bob.viewModel.acceptInviteURL(#require(alice.viewModel.makeSelectedGroupInviteURL()))
    }
    func connect() async {
        if alice.viewModel.activeGroupID == nil { alice.viewModel.connectLocal() }
        if bob.viewModel.activeGroupID == nil { bob.viewModel.connectLocal() }
        alice.viewModel.enabledRTCTransportRoutes = [.multipeer]; bob.viewModel.enabledRTCTransportRoutes = [.multipeer]
        alice.callSession.authenticate(["bob"]); bob.callSession.authenticate(["alice"])
        await pump()
    }
    func pump() async {
        for _ in 0..<100 {
            await Task.yield()
            let count = aliceMessageIndex + bobMessageIndex
            while aliceMessageIndex < alice.callSession.sentApplicationDataMessages.count {
                let message = alice.callSession.sentApplicationDataMessages[aliceMessageIndex]; aliceMessageIndex += 1
                bob.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "alice", message: message))
            }
            while bobMessageIndex < bob.callSession.sentApplicationDataMessages.count {
                let message = bob.callSession.sentApplicationDataMessages[bobMessageIndex]; bobMessageIndex += 1
                alice.viewModel.handleTransportEvent(.receivedApplicationData(peerID: "bob", message: message))
            }
            if aliceMessageIndex + bobMessageIndex == count, alice.viewModel.audioStartTask == nil,
                bob.viewModel.audioStartTask == nil {
                return
            }
        }
        Issue.record("Call state exchange failed to settle")
    }
    func close() { alice.viewModel.disconnect(); bob.viewModel.disconnect() }
}
