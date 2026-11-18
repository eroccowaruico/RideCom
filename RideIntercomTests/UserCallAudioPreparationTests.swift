import AudioCore
import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized) struct UserCallAudioPreparationTests {
    @Test(arguments: [RouteKind.multipeer, .webRTC], [false, true])
    func anExplicitCallPreparesAudioBeforePeersButCannotTransmitWithoutAdmission(route: RouteKind, enforcesAccess: Bool) async throws {
        let h = AppTestSupport.makeHarness(enforceCallAccess: enforcesAccess), vm = h.viewModel
        defer { vm.disconnect() }
        vm.setSoundIsolationEnabled(false); vm.enabledRTCTransportRoutes = [route]
        vm.selectGroup(try #require(vm.groups.first))
        await AppTestSupport.waitUntil { vm.isAudioReady }
        #expect(vm.isAudioReady, "The requested call must prepare native audio before waiting for another rider")
        #expect(h.inputBackend.startCount == 1 && h.outputBackend.startCount == 1)
        #expect(h.callSession.startMediaCallCount == 0, "Audio preparation is not permission to send media")
        vm.applyLocalMute(true); vm.applyLocalMute(false)
        for index in 0..<8 {
            h.inputBackend.emit(.init(sequenceNumber: UInt64(index), format: .init(sampleRate: 48_000, channelCount: 1),
                capturedAt: ProcessInfo.processInfo.systemUptime, samples: Array(repeating: 0.2, count: 960)))
        }
        await Task.yield()
        #expect(h.callSession.sentAudioPackets.isEmpty)
        vm.disconnect()
        #expect(!vm.isAudioReady && h.inputBackend.stopCount > 0 && h.outputBackend.stopCount > 0)
    }

    @Test func aLatePeerAndRecoverableLossDoNotRestartTheRequestedNativeCapture() async throws {
        let h = AppTestSupport.makeHarness(enforceCallAccess: false), vm = h.viewModel
        defer { vm.disconnect() }
        vm.setSoundIsolationEnabled(false); vm.selectGroup(try #require(vm.groups.first))
        await AppTestSupport.waitUntil { vm.isAudioReady }
        try #require(vm.isAudioReady)
        let deadline = vm.callDisconnectDeadline, starts = h.inputBackend.startCount
        h.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { h.callSession.startMediaCallCount > 0 }
        #expect(h.callSession.startMediaCallCount == 1 && h.inputBackend.startCount == starts)
        vm.handleTransportEvent(.linkFailed(willRetry: true))
        #expect(vm.isAudioReady && h.inputBackend.startCount == starts)
        #expect(vm.callDisconnectDeadline == deadline)
        h.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { h.callSession.startMediaCallCount == 2 }
        #expect(vm.isAudioReady && h.inputBackend.startCount == starts && vm.callDisconnectDeadline == deadline)
    }
    @Test func peerLossDuringActivationStillPreparesTheRequestedCallWithoutSending() async throws {
        let h = AppTestSupport.makeHarness(), vm = h.viewModel, gate = ManualAsyncGate()
        defer { vm.disconnect() }
        h.audioSessionBackend.activationGate = gate
        vm.selectGroup(try #require(vm.groups.first)); h.callSession.authenticate(["member-108"])
        await gate.waitForEntry()
        vm.handleTransportEvent(.connected(peerIDs: []))
        await gate.release()
        await AppTestSupport.waitUntil { vm.isAudioReady }
        #expect(vm.isAudioReady && !vm.isCallMediaStarted)
        #expect(h.inputBackend.startCount == 1 && h.callSession.startMediaCallCount == 0)
    }

    @Test func anEmptyAuthenticatedSnapshotKeepsWaitingAudioWithoutClaimingConnection() async throws {
        let h = AppTestSupport.makeHarness(), vm = h.viewModel
        defer { vm.disconnect() }
        vm.selectGroup(try #require(vm.groups.first))
        await AppTestSupport.waitUntil { vm.isAudioReady }
        h.callSession.authenticate([])
        #expect(vm.isAudioReady && !vm.isCallMediaStarted)
        #expect(vm.connectionState == .localConnecting)
        #expect(vm.standardCallStatus == .connecting)
    }

}
