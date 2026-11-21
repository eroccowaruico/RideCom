import AudioCore
import Foundation
import RTC
import SessionManager
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized) struct UserCallAudioPreparationTests {
    @Test(arguments: [RouteKind.multipeer, .webRTC], [false, true])
    func anExplicitCallPreparesAudioBeforePeersButCannotTransmitWithoutAdmission(
        route: RouteKind, enforcesAccess: Bool
    ) async throws {
        let harness = AppTestSupport.makeHarness(enforceCallAccess: enforcesAccess), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        viewModel.setSoundIsolationEnabled(false); viewModel.enabledRTCTransportRoutes = [route]
        viewModel.selectGroup(try #require(viewModel.groups.first))
        await AppTestSupport.waitUntil { viewModel.isAudioReady }
        #expect(viewModel.isAudioReady, "The requested call must prepare native audio before waiting for another rider")
        #expect(harness.inputBackend.startCount == 1 && harness.outputBackend.startCount == 1)
        #expect(harness.callSession.startMediaCallCount == 0, "Audio preparation is not permission to send media")
        viewModel.applyLocalMute(true); viewModel.applyLocalMute(false)
        for index in 0..<8 {
            harness.inputBackend.emit(
                .init(
                    sequenceNumber: UInt64(index), format: .init(sampleRate: 48_000, channelCount: 1),
                capturedAt: ProcessInfo.processInfo.systemUptime, samples: Array(repeating: 0.2, count: 960)))
        }
        await Task.yield()
        #expect(harness.callSession.sentAudioPackets.isEmpty)
        viewModel.disconnect()
        #expect(!viewModel.isAudioReady && harness.inputBackend.stopCount > 0 && harness.outputBackend.stopCount > 0)
    }

    @Test func aLatePeerAndRecoverableLossDoNotRestartTheRequestedNativeCapture() async throws {
        let harness = AppTestSupport.makeHarness(enforceCallAccess: false), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        viewModel.setSoundIsolationEnabled(false); viewModel.selectGroup(try #require(viewModel.groups.first))
        await AppTestSupport.waitUntil { viewModel.isAudioReady }
        try #require(viewModel.isAudioReady)
        let deadline = viewModel.callDisconnectDeadline, starts = harness.inputBackend.startCount
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.callSession.startMediaCallCount > 0 }
        #expect(harness.callSession.startMediaCallCount == 1 && harness.inputBackend.startCount == starts)
        viewModel.handleTransportEvent(.linkFailed(willRetry: true))
        #expect(viewModel.isAudioReady && harness.inputBackend.startCount == starts)
        #expect(viewModel.callDisconnectDeadline == deadline)
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.callSession.startMediaCallCount == 2 }
        #expect(
            viewModel.isAudioReady && harness.inputBackend.startCount == starts
                && viewModel.callDisconnectDeadline == deadline)
    }
    @Test func peerLossDuringActivationStillPreparesTheRequestedCallWithoutSending() async throws {
        let harness = AppTestSupport.makeHarness(), viewModel = harness.viewModel, gate = ManualAsyncGate()
        defer { viewModel.disconnect() }
        harness.audioSessionBackend.activationGate = gate
        viewModel.selectGroup(try #require(viewModel.groups.first)); harness.callSession.authenticate(["member-108"])
        await gate.waitForEntry()
        viewModel.handleTransportEvent(.connected(peerIDs: []))
        await gate.release()
        await AppTestSupport.waitUntil { viewModel.isAudioReady }
        #expect(viewModel.isAudioReady && !viewModel.isCallMediaStarted)
        #expect(harness.inputBackend.startCount == 1 && harness.callSession.startMediaCallCount == 0)
    }

    @Test func anEmptyAuthenticatedSnapshotKeepsWaitingAudioWithoutClaimingConnection() async throws {
        let harness = AppTestSupport.makeHarness(), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        viewModel.selectGroup(try #require(viewModel.groups.first))
        await AppTestSupport.waitUntil { viewModel.isAudioReady }
        harness.callSession.authenticate([])
        #expect(viewModel.isAudioReady && !viewModel.isCallMediaStarted)
        #expect(viewModel.connectionState == .localConnecting)
        #expect(viewModel.standardCallStatus == .connecting)
    }

    @Test(arguments: [RouteKind.multipeer, .webRTC], [false, true])
    func explicitResumeWhileWaitingPreparesAudioWithoutAPeer(route: RouteKind, muted: Bool) async throws {
        let harness = AppTestSupport.makeHarness(enforceCallAccess: true), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        viewModel.setSoundIsolationEnabled(false)
        viewModel.enabledRTCTransportRoutes = [route]
        viewModel.applyLocalMute(muted)
        viewModel.selectGroup(try #require(viewModel.groups.first))
        await AppTestSupport.waitUntil { viewModel.isAudioReady }
        try #require(viewModel.isAudioReady)
        let deadline = viewModel.callDisconnectDeadline, starts = harness.inputBackend.startCount
        viewModel.handleAudioSessionRuntimeEvent(
            .snapshotChanged(.init(reason: .interruptionBegan, snapshot: harness.audioSessionBackend.current)))
        #expect(viewModel.isAudioPausedForDeviceChange && !viewModel.isAudioReady)
        #expect(viewModel.callPresenceLabel == String(localized: "Audio paused"))
        viewModel.resumeAudioAfterDeviceChange()
        await AppTestSupport.waitUntil { viewModel.isAudioReady }
        #expect(viewModel.isAudioReady && !viewModel.isAudioPausedForDeviceChange && viewModel.audioRouteNotice == nil)
        #expect(harness.inputBackend.startCount == starts + 1 && viewModel.isMuted == muted)
        #expect(viewModel.callDisconnectDeadline == deadline && viewModel.authenticatedPeerIDs.isEmpty)
        #expect(!viewModel.isCallMediaStarted && harness.callSession.startMediaCallCount == 0)
        for index in 0..<8 {
            harness.inputBackend.emit(
                .init(
                    sequenceNumber: UInt64(index), format: .init(sampleRate: 48_000, channelCount: 1),
                capturedAt: ProcessInfo.processInfo.systemUptime, samples: Array(repeating: 0.2, count: 960)))
        }
        await Task.yield()
        #expect(harness.callSession.sentAudioPackets.isEmpty)
    }

    @Test func resumingWaitingAudioAfterTheDeadlineEndsTheCallInsteadOfOpeningInput() async throws {
        var now = Date(timeIntervalSince1970: 2_000_000_000)
        let harness = AppTestSupport.makeHarness(callAccessNow: { now }), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        viewModel.setSoundIsolationEnabled(false); viewModel.setCallDisconnectInterval(.oneMinute)
        viewModel.selectGroup(try #require(viewModel.groups.first))
        await AppTestSupport.waitUntil { viewModel.isAudioReady }
        try #require(viewModel.isAudioReady)
        let starts = harness.inputBackend.startCount
        viewModel.handleAudioSessionRuntimeEvent(
            .snapshotChanged(.init(reason: .interruptionBegan, snapshot: harness.audioSessionBackend.current)))
        now = now.addingTimeInterval(60)
        viewModel.resumeAudioAfterDeviceChange()
        await Task.yield()
        #expect(viewModel.callDisconnectDeadline == nil && !viewModel.isAudioReady && viewModel.audioStartTask == nil)
        #expect(harness.inputBackend.startCount == starts && harness.callSession.startMediaCallCount == 0)
    }

}
