import AVFAudio
import Foundation
import AudioCore
import AudioMixer
import Codec
import RTC
import SessionManager
import Testing
import VADGate
import SoundIsolation
import PeakLimiter
@testable import RideIntercom

extension AppTests {
@MainActor
struct CallLifecycleTests {
    @Test func browsingPreservesCallButConnectingRejectsQueuedOldEvents() async {
        let harness = AppTestSupport.makeHarness()
        let firstGroup = IntercomSeedData.recentGroups[0]
        let secondGroup = IntercomSeedData.recentGroups[1]
        harness.viewModel.selectGroup(firstGroup)
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        let oldHandler = harness.callSession.onEvent
        harness.viewModel.selectGroup(secondGroup)
        #expect(harness.viewModel.activeGroupID == firstGroup.id)
        #expect(harness.viewModel.isAudioReady)
        #expect(harness.callSession.disconnectCallCount == 0)
        harness.viewModel.connectLocal()
            oldHandler?(
                .authenticated(members: [
                    .init(
                        peer: .init(id: .init(rawValue: "old-peer"), displayName: "Rider"), route: .multipeer,
                        isConnected: true, membershipID: UUID())
                ]))
        oldHandler?(.routeMetrics(RTC.RouteMetrics(route: .multipeer, receivedAudioFrameCount: 999)))
        oldHandler?(.networkDiagnostics(.init(generatedAt: 123)))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(harness.viewModel.activeGroupID == secondGroup.id)
        #expect(harness.callSession.connectedGroup?.id == secondGroup.id)
        #expect(harness.viewModel.authenticatedPeerIDs.isEmpty)
        #expect(harness.viewModel.receivedVoicePacketCount == 0)
        #expect(harness.viewModel.networkDiagnostics?.generatedAt != 123)
        #expect(!harness.viewModel.isCallMediaStarted)
        harness.viewModel.disconnect()
    }

    @Test func lastPeerDisconnectStopsNetworkMediaButKeepsNativeAudioForAuthenticatedReconnect() async {
        let harness = AppTestSupport.makeHarness()
        harness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        harness.callSession.authenticate(["member-108", "member-215"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        harness.viewModel.handleTransportEvent(.connected(peerIDs: ["member-215"]))
        #expect(harness.viewModel.isAudioReady)
        #expect(harness.viewModel.authenticatedPeerIDs == ["member-215"])
        harness.viewModel.handleTransportEvent(.connected(peerIDs: []))
        #expect(!harness.viewModel.isCallMediaStarted)
        #expect(harness.viewModel.isAudioReady)
        #expect(!harness.viewModel.audioPipeline.snapshot.busIDs.isEmpty)
        #expect(harness.viewModel.activeGroupID != nil)
        harness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        #expect(harness.viewModel.isAudioReady)
        harness.viewModel.disconnect()
    }

    @Test func outputRestartFailureReleasesInputAndAllowsRetry() async {
        let testHarness = AppTestSupport.makeHarness()
        testHarness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        testHarness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { testHarness.viewModel.isAudioReady }
        testHarness.outputBackend.startError = AudioStreamError.engineOperationFailed("removed")
        testHarness.viewModel.refreshAudioDevicesIfNeeded()
        await AppTestSupport.waitUntil { testHarness.viewModel.audioErrorMessage != nil }
        #expect(!testHarness.viewModel.isAudioReady)
        #expect(testHarness.viewModel.audioPipeline.snapshot.busIDs.isEmpty)
        #expect(testHarness.inputBackend.stopCount > 0)
        #expect(testHarness.viewModel.audioErrorMessage != nil)
        testHarness.outputBackend.startError = nil
        testHarness.viewModel.resumeAudioAfterDeviceChange()
        await AppTestSupport.waitUntil { testHarness.viewModel.isAudioReady }
        #expect(testHarness.viewModel.isAudioReady)
        testHarness.viewModel.disconnect()
    }

    @Test func internetConflictKeepsLocalAudioAndExplainsManualRecovery() async {
        let testHarness = AppTestSupport.makeHarness()
        testHarness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        testHarness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { testHarness.viewModel.isAudioReady }
            testHarness.viewModel.handleTransportEvent(
                .serviceBlocked("End the existing Internet call, then reconnect here."))
        #expect(testHarness.viewModel.isAudioReady)
        #expect(testHarness.viewModel.audioErrorMessage == nil)
        #expect(testHarness.viewModel.connectivityNotice?.contains("End the existing Internet call") == true)
        #expect(testHarness.viewModel.connectivityNotice?.contains("automatically") == false)
        #expect(testHarness.viewModel.internetFailureDetail != nil)
        testHarness.viewModel.disconnect()
        #expect(testHarness.viewModel.internetFailureDetail == nil)
    }

    @Test func blockedInternetOnlyCallOffersConnectInsteadOfClaimingAutomaticRecovery() {
        let testHarness = AppTestSupport.makeHarness(hasInternetCallCredential: true)
        testHarness.viewModel.enabledRTCTransportRoutes = [.webRTC]
        testHarness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        testHarness.viewModel.handleTransportEvent(.serviceBlocked("End the existing Internet call, then try again."))
        testHarness.viewModel.handleTransportEvent(.linkFailed(willRetry: false))
        #expect(testHarness.viewModel.connectionState == .idle)
        #expect(!testHarness.viewModel.canDisconnectCall)
        #expect(testHarness.viewModel.connectivityNotice != nil)
        testHarness.viewModel.connectLocal()
        #expect(testHarness.viewModel.internetFailureDetail == nil)
        #expect(testHarness.viewModel.connectivityNotice == nil)
        #expect(testHarness.viewModel.connectionState != .idle)
        testHarness.viewModel.disconnect()
    }

    @Test func blockedInternetDoesNotSuppressIndependentLocalRecovery() {
        let testHarness = AppTestSupport.makeHarness()
        testHarness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        testHarness.viewModel.handleTransportEvent(.serviceBlocked("Reconnect Internet manually."))
        testHarness.viewModel.handleTransportEvent(.linkFailed(willRetry: true))
        #expect(testHarness.viewModel.connectionState == .reconnectingOffline)
        #expect(testHarness.viewModel.internetFailureDetail != nil)
        testHarness.viewModel.disconnect()
    }

    @Test func internetFailureDoesNotMisreportHealthyLocalAudio() async {
        let testHarness = AppTestSupport.makeHarness(hasInternetCallCredential: true)
        testHarness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        testHarness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { testHarness.viewModel.isAudioReady }
        testHarness.viewModel.handleTransportEvent(.serviceError("quota"))
        #expect(testHarness.viewModel.isAudioReady)
        #expect(testHarness.viewModel.audioErrorMessage == nil)
        #expect(testHarness.viewModel.connectivityNotice?.contains("Retrying automatically") == true)
        #expect(testHarness.viewModel.internetFailureDetail == "quota")
        testHarness.viewModel.handleTransportEvent(.routesChanged(.init(
            activeRoute: .multipeer, mediaRoute: .multipeer,
            availableRoutes: [.multipeer, .webRTC], isHandoverInProgress: false)))
        #expect(testHarness.viewModel.connectivityNotice == nil)
        #expect(testHarness.viewModel.internetFailureDetail == nil)
        #expect(testHarness.viewModel.isAudioReady)
        testHarness.viewModel.disconnect()
    }

    @Test func deviceResumeRetriesFailureAndPreservesMuteIntent() async {
        let testHarness = AppTestSupport.makeHarness()
        testHarness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        testHarness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { testHarness.viewModel.isAudioReady }
        testHarness.viewModel.toggleMute()
        testHarness.viewModel.toggleOutputMute()
        testHarness.viewModel.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(
            reason: .routeChanged(.oldDeviceUnavailable), snapshot: testHarness.audioSessionBackend.current)))
        #expect(testHarness.viewModel.isAudioPausedForDeviceChange)
        #expect(testHarness.viewModel.callPresenceLabel == "Connected / Audio Paused")
        let paused = DiagnosticsInput(testHarness.viewModel)
        #expect(paused.pausedCall?.status == "Connected / Audio Paused")
        #expect(paused.pausedCall?.reason?.hasPrefix("Audio device disconnected.") == true)
        #expect(TransmitPipelinePresentation(input: paused).inputStreamStep.state == .muted)
        #expect(ReceivePipelinePresentation(input: paused).rtcReceiveStep.state == .idle)
        testHarness.inputBackend.startError = AudioStreamError.engineOperationFailed("missing")
        testHarness.viewModel.resumeAudioAfterDeviceChange()
        await AppTestSupport.waitUntil { testHarness.viewModel.audioErrorMessage != nil }
        #expect(testHarness.viewModel.isAudioPausedForDeviceChange)
        #expect(!testHarness.viewModel.isAudioReady)
        let retry = DiagnosticsInput(testHarness.viewModel).pausedCall
        #expect(retry?.reason == (testHarness.viewModel.audioRouteNotice ?? testHarness.viewModel.audioPauseError))
        testHarness.inputBackend.startError = nil
        testHarness.viewModel.resumeAudioAfterDeviceChange()
        await AppTestSupport.waitUntil { testHarness.viewModel.isAudioReady }
        #expect(testHarness.viewModel.isAudioReady)
        #expect(!testHarness.viewModel.isAudioPausedForDeviceChange)
        #expect(DiagnosticsInput(testHarness.viewModel).pausedCall == nil)
        #expect(testHarness.viewModel.isMuted && testHarness.viewModel.isOutputMuted)
        #expect(testHarness.viewModel.audioRouteNotice == nil)
        testHarness.viewModel.disconnect()
        #expect(testHarness.viewModel.availableCallRoutes.isEmpty)
    }

    @Test func diagnosticsShowsPauseOnTheActiveCallWhileWaitingForPeers() async throws {
        let harness = AppTestSupport.makeHarness()
        let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let group = try #require(viewModel.groups.first)
        viewModel.selectGroup(group)
        await AppTestSupport.waitUntil { viewModel.isAudioReady }
        try #require(viewModel.isAudioReady)

        viewModel.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(
            reason: .routeChanged(.oldDeviceUnavailable), snapshot: harness.audioSessionBackend.current)))
        let paused = try #require(DiagnosticsInput(viewModel).pausedCall)
        #expect(paused.status == "Audio paused")
        #expect(paused.reason?.hasPrefix("Audio device disconnected.") == true)
        #expect(viewModel.activeGroupID == group.id)

        let other = try #require(viewModel.groups.first { $0.id != group.id })
        viewModel.selectGroup(other, connectIfIdle: false)
        #expect(DiagnosticsInput(viewModel).pausedCall == nil)
        #expect(viewModel.activeGroupID == group.id)
        viewModel.selectGroup(group, connectIfIdle: false)
        #expect(DiagnosticsInput(viewModel).pausedCall?.status == "Audio paused")
    }

    @Test func actualDefaultDeviceChangeRestartsBothStreamsAndInterruptsAudioCheck() async {
        let testHarness = AppTestSupport.makeHarness()
        testHarness.viewModel.startAudioCheck()
        testHarness.viewModel.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(
            reason: .routeChanged(.oldDeviceUnavailable), snapshot: testHarness.audioSessionBackend.current)))
        #expect(testHarness.viewModel.audioCheckPhase == .idle)
        #expect(!testHarness.viewModel.audioCheckOwnsAudioPipeline)
        testHarness.viewModel.selectGroup(IntercomSeedData.recentGroups[0])
        testHarness.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { testHarness.viewModel.isAudioReady }
        let starts = testHarness.inputBackend.startCount
        var snapshot = testHarness.audioSessionBackend.current
        snapshot.currentOutput = .builtInSpeaker
        testHarness.viewModel.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(
            reason: .defaultOutputChanged, snapshot: snapshot)))
        await AppTestSupport.waitUntil { testHarness.viewModel.isAudioReady }
        #expect(testHarness.viewModel.isAudioReady)
        #expect(testHarness.inputBackend.startCount == starts + 1)
        testHarness.viewModel.disconnect()
    }

}
}
