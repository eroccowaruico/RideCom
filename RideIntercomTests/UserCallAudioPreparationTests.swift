import AudioCore
import AudioMixer
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
        let harness = AppTestSupport.makeHarness(
            hasInternetCallCredential: route == .webRTC, enforceCallAccess: enforcesAccess)
        let viewModel = harness.viewModel
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

    @Test(arguments: [RouteKind.multipeer, .webRTC])
    func mutedCallReceivesAfterWaitingAndRecoverableLoss(route: RouteKind) async throws {
        var now = Date()
        var group = try #require(IntercomSeedData.recentGroups.first)
        group.members = Array(group.members.prefix(1))
        let harness = AppTestSupport.makeHarness(groups: [group], hasInternetCallCredential: true,
                                                enforceCallAccess: false, callAccessNow: { now })
        let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        viewModel.setSoundIsolationEnabled(false)
        viewModel.setRTCTransportRoutes([route])
        viewModel.setCallDisconnectInterval(.tenMinutes)
        viewModel.applyLocalMute(true)
        viewModel.selectGroup(try #require(viewModel.groups.first))
        await AppTestSupport.waitUntil { viewModel.isAudioReady }
        try #require(viewModel.isAudioReady)

        let deadline = try #require(viewModel.callDisconnectDeadline)
        let reference = viewModel.currentCallReference
        let inputStarts = harness.inputBackend.startCount, outputStarts = harness.outputBackend.startCount
        let peerID = "member-108"
        let peerBusID = "rx-peer-\(peerID)"

        now = now.addingTimeInterval(300)
        viewModel.handleCallTick(now: now.timeIntervalSince1970)
        #expect(harness.callSession.enabledRouteValues.last == [route])
        #expect(viewModel.isMuted && viewModel.lastReceivedAudioAt == nil)
        #expect(!viewModel.isCallMediaStarted && viewModel.callDisconnectDeadline == deadline)
        #expect(!viewModel.audioPipeline.snapshot.busIDs.contains(peerBusID))

        harness.callSession.authenticate([peerID], route: route)
        await AppTestSupport.waitUntil { harness.callSession.startMediaCallCount == 1 }
        #expect(viewModel.audioPipeline.snapshot.busIDs.contains(peerBusID))
        #expect(viewModel.lastReceivedAudioAt == nil)
        try receivePeerAudio(0.2, sequence: 1, from: peerID, through: harness.callSession)
        await AppTestSupport.waitUntil(timeout: .seconds(5)) { outputContains(0.2, in: harness.outputBackend) }
        #expect(outputContains(0.2, in: harness.outputBackend))

        viewModel.handleTransportEvent(.linkFailed(willRetry: true))
        #expect(viewModel.isAudioReady && !viewModel.isCallMediaStarted)
        now = now.addingTimeInterval(60)
        viewModel.handleCallTick(now: now.timeIntervalSince1970)
        harness.callSession.authenticate([peerID], route: route)
        await AppTestSupport.waitUntil { harness.callSession.startMediaCallCount == 2 }
        #expect(viewModel.audioPipeline.snapshot.busIDs.contains(peerBusID))
        let capturedAt = ProcessInfo.processInfo.systemUptime
        for index in 0..<8 {
            harness.inputBackend.emit(.init(sequenceNumber: UInt64(index), format: .intercomPacketAudio,
                capturedAt: capturedAt + Double(index) * 0.02, samples: Array(repeating: 0.2, count: 960)))
        }
        try receivePeerAudio(-0.3, sequence: 2, from: peerID, through: harness.callSession)
        await AppTestSupport.waitUntil(timeout: .seconds(5)) { outputContains(-0.3, in: harness.outputBackend) }
        #expect(outputContains(-0.3, in: harness.outputBackend), "The recovered call must schedule the new peer audio")
        #expect(viewModel.isMuted && harness.callSession.sentAudioPackets.isEmpty)
        #expect(viewModel.callDisconnectDeadline == deadline && viewModel.currentCallReference == reference)
        #expect(harness.inputBackend.startCount == inputStarts && harness.outputBackend.startCount == outputStarts)
    }

    @Test(arguments: [RouteKind.multipeer, .webRTC])
    func anActiveCallPreparesTheNextPeerWithoutRestartingMedia(route: RouteKind) async throws {
        var group = try #require(IntercomSeedData.recentGroups.first)
        group.members = Array(group.members.prefix(1))
        let harness = AppTestSupport.makeHarness(groups: [group], hasInternetCallCredential: true,
                                                enforceCallAccess: false)
        let model = harness.viewModel
        defer { model.disconnect() }
        model.setSoundIsolationEnabled(false)
        model.setRTCTransportRoutes([route])
        model.selectGroup(try #require(model.groups.first))
        await AppTestSupport.waitUntil { model.isAudioReady }
        try #require(model.isAudioReady)

        let first = "member-108", second = "member-215"
        harness.callSession.authenticate([first], route: route)
        await AppTestSupport.waitUntil { model.isCallMediaStarted }
        try #require(model.isCallMediaStarted)
        #expect(!model.audioPipeline.snapshot.busIDs.contains("rx-peer-\(second)"))
        try receivePeerAudio(0.2, sequence: 1, from: first, through: harness.callSession)
        await AppTestSupport.waitUntil(timeout: .seconds(5)) { outputContains(0.2, in: harness.outputBackend) }
        #expect(outputContains(0.2, in: harness.outputBackend))

        harness.callSession.authenticate([first, second], route: route)
        #expect(model.audioPipeline.snapshot.busIDs.contains("rx-peer-\(second)"))
        #expect(harness.callSession.startMediaCallCount == 1)
        try receivePeerAudio(0.3, sequence: 1, from: second, through: harness.callSession)
        await AppTestSupport.waitUntil(timeout: .seconds(5)) { outputContains(0.3, in: harness.outputBackend) }
        #expect(outputContains(0.3, in: harness.outputBackend))

        model.handleTransportEvent(.connected(peerIDs: [first]))
        #expect(!model.audioPipeline.snapshot.busIDs.contains("rx-peer-\(second)"))
        #expect(model.audioPipeline.snapshot.busIDs.contains("rx-peer-\(first)"))
        #expect(model.isCallMediaStarted && harness.callSession.startMediaCallCount == 1)
        try receivePeerAudio(-0.2, sequence: 2, from: first, through: harness.callSession)
        await AppTestSupport.waitUntil(timeout: .seconds(5)) { outputContains(-0.2, in: harness.outputBackend) }
        #expect(outputContains(-0.2, in: harness.outputBackend))
    }

    private func outputContains(_ sample: Float, in output: FakeOutputStreamBackend) -> Bool {
        output.scheduledFrames.contains { frame in
            frame.samples.contains { abs($0 - sample) < 0.001 }
        }
    }

    private func receivePeerAudio(
        _ sample: Float, sequence: UInt64, from peerID: String, through session: RecordingCallSession
    ) throws {
        let frame = PCMFrame(sequenceNumber: sequence, format: .intercomPacketAudio,
            capturedAt: ProcessInfo.processInfo.systemUptime, samples: Array(repeating: sample, count: 960))
        session.receive(try AppTestSupport.receivedAudioPacket(peerID: peerID, frame: frame, codec: .pcm16))
    }

    @Test func aRetiredAudioInputCannotSendThroughTheNextCall() async throws {
        let harness = AppTestSupport.makeHarness(enforceCallAccess: false), model = harness.viewModel
        defer { model.disconnect() }
        let group = try #require(model.groups.first)
        model.setSoundIsolationEnabled(false)
        model.selectGroup(group)
        await AppTestSupport.waitUntil { model.isAudioReady }
        try #require(model.isAudioReady)
        harness.callSession.authenticate(["member-108"])
        try #require(model.isCallMediaStarted)
        let retiredSend = try #require(model.audioPipeline.onTransmitPacket)

        model.disconnect()
        model.connectLocal()
        await AppTestSupport.waitUntil { model.isAudioReady }
        try #require(model.isAudioReady)
        harness.callSession.authenticate(["member-108"])
        try #require(model.isCallMediaStarted)
        let currentSend = try #require(model.audioPipeline.onTransmitPacket)

        retiredSend(.init(sequenceNumber: 1, codec: .pcm16, payload: Data([0, 0])))
        currentSend(.init(sequenceNumber: 2, codec: .pcm16, payload: Data([0, 0])))
        #expect(harness.callSession.sentAudioPackets.map(\.sequenceNumber) == [2])
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
        let harness = AppTestSupport.makeHarness(
            hasInternetCallCredential: route == .webRTC, enforceCallAccess: true)
        let viewModel = harness.viewModel
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
