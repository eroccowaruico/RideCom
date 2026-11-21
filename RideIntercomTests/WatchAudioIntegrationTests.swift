import AudioCore
import AudioDevice
import CallControl
import Foundation
import RTC
import SessionManager
import Synchronization
import Testing
@testable import RideIntercom

/// Actual local encrypted device link and native AAC, with synthetic Watch
/// input and the existing offline phone graph. No microphone/device claims.
@MainActor struct WatchAudioIntegrationTests {
    @Test(arguments: [0, 32])
    func failedWatchAudioCheckRestoresRouteAndMute(keyCount: Int) async {
        let rig = AppTestSupport.makeHarness(groups: [])
        let model = rig.viewModel, input = rig.viewModel.audioInputCapture,
            output = rig.viewModel.audioOutputRenderer
        await verifyPhoneAudioCheck(rig)
        model.applyLocalMute(true)
        do {
            _ = try await model.attachWatchAudio(.init(sessionID: UUID(), key: Data(repeating: 7, count: keyCount),
                endpoint: .init(name: "invalid", type: "invalid", domain: "invalid")), audioCheck: true)
            Issue.record("Invalid audio-check setup must fail")
        } catch {}
        #expect(model.audioCheckPhase == .failed && !model.audioCheckOwnsAudioPipeline)
        #expect(model.audioInputCapture === input && model.audioOutputRenderer === output)
        #expect(model.watchAudioLink == nil && !model.isUsingWatchAudio && model.isMuted)
        #expect(!model.hasAnyActiveGroupConnection && rig.callSession.startMediaCallCount == 0)
        await verifyPhoneAudioCheck(rig)
    }

    @Test func cancelledWatchAudioCheckRestoresBeforeLateActivation() async throws {
        let rig = AppTestSupport.makeHarness(groups: []), gate = ManualAsyncGate()
        rig.audioSessionBackend.activationGate = gate
        let model = rig.viewModel, input = rig.viewModel.audioInputCapture,
            output = rig.viewModel.audioOutputRenderer
        model.applyLocalMute(true)
        let id = UUID(), key = Data(repeating: 4, count: 32)
        let watch = try AudioDeviceConnection(sessionID: id, key: key, role: .device)
        defer { watch.stop(); model.cancelAudioCheck() }
        let endpoint = try await watch.prepare()
        _ = try await model.attachWatchAudio(.init(sessionID: id, key: key, endpoint: endpoint), audioCheck: true)
        await gate.waitForEntry()
        #expect(model.audioCheckPhase == .preparing && !model.canStartAudioCheck)
        model.cancelAudioCheck()
        await gate.release()
        _ = await model.audioSessionManager.requestActive(false).value
        #expect(model.audioCheckPhase == .idle && !model.audioCheckOwnsAudioPipeline)
        #expect(model.audioInputCapture === input && model.audioOutputRenderer === output)
        #expect(model.watchAudioLink == nil && !model.isUsingWatchAudio && model.isMuted)
        #expect(rig.inputBackend.startCount == 0 && rig.callSession.startMediaCallCount == 0)
        await verifyPhoneAudioCheck(rig)
    }

    @Test func watchAudioCheckRecordsOnPhoneAndRestoresBackendsWithoutStartingCall() async throws {
        let rig = AppTestSupport.makeHarness(groups: [])
        let model = rig.viewModel, owner = AppCallOwner(account: rig.viewModel.accountSession, viewModel: rig.viewModel)
        let originalInput = model.audioInputCapture, originalOutput = model.audioOutputRenderer
        await verifyPhoneAudioCheck(rig)
        let phoneStartsBeforeWatch = rig.inputBackend.startCount
        model.applyLocalMute(true)
        let id = UUID(), key = Data(repeating: 9, count: 32)
        let watch = try AudioDeviceConnection(sessionID: id, key: key, role: .device)
        let watchOutput = AudioOutputStreamRenderer(configuration: .init(maximumBufferedDuration: 0.1), backend: watch)
        defer { _ = watchOutput.stop(); watch.stop(); model.cancelAudioCheck() }
        let endpoint = try await watch.prepare()
        try #require(watchOutput.start().result == .applied)
        let request = WatchControlRequest(
            .startAudioCheck(.init(sessionID: id, key: key, endpoint: endpoint)), snapshot: owner.watchSnapshot())
        let reply = await owner.handleWatchRequest(request)
        #expect(reply.problem == nil && !reply.snapshot.hasCall)
        #expect(watch.connect(to: try #require(reply.audioEndpoint)))
        await AppTestSupport.waitUntil { model.audioCheckPhase == .recording }
        #expect(model.audioCheckPhase == .recording)
        #expect(model.audioCheckWatchSessionID == id)
        #expect(model.audioInputCapture !== originalInput && model.audioOutputRenderer !== originalOutput)
        #expect(rig.inputBackend.startCount == phoneStartsBeforeWatch && rig.callSession.startMediaCallCount == 0)
        await AppTestSupport.waitUntil { watch.isSendReady }
        try #require(watch.isSendReady)
        watch.setSendingAllowed(true)
        try #require(watch.isSendingAllowed)
        for index in 0..<30 {
            let frame = PCMFrame(sequenceNumber: UInt64(index), format: .intercomPacketAudio,
                capturedAt: 100 + Double(index) * 0.01,
                samples: (0..<480).map { Float(sin(Double(index * 480 + $0) * .pi * 880 / 48_000) * 0.3) })
            try #require(watchOutput.schedule(frame).result == .applied)
            try await Task.sleep(for: .milliseconds(10))
        }
        await AppTestSupport.waitUntil { !model.audioCheckRecordedFrames.isEmpty }
        try #require(!model.audioCheckRecordedFrames.isEmpty, "Watch device audio must reach Phone capture")
        watch.setSendingAllowed(false)
        model.finishAudioCheckRecording(playbackDuration: .seconds(5))
        #expect(model.audioCheckPhase == .preparing && model.audioCheckRecordedFrameCount > 0,
            "Phone waits for the Watch to close its microphone before replay")
        #expect(model.audioCheckRecordedNonzeroSamples > 0, "Phone transmit processing must preserve device audio")
        let play = await owner.handleWatchRequest(.init(.playAudioCheck(id), snapshot: owner.watchSnapshot()))
        #expect(play.problem == nil && model.audioCheckPhase == .playing)
        #expect(!model.playWatchAudioCheck(sessionID: id), "Duplicate play requests cannot restart playback")
        let stopped = await owner.handleWatchRequest(.init(.stopAudioCheck(id), snapshot: owner.watchSnapshot()))
        #expect(stopped.problem == nil)
        #expect(model.audioInputCapture === originalInput && model.audioOutputRenderer === originalOutput)
        #expect(model.watchAudioLink == nil && !model.isUsingWatchAudio && model.isMuted)
        #expect(!model.playWatchAudioCheck(sessionID: id), "Cancelled audio cannot replay")
        #expect(!model.hasAnyActiveGroupConnection && rig.callSession.startMediaCallCount == 0)
        await verifyPhoneAudioCheck(rig)
    }

    private func verifyPhoneAudioCheck(_ rig: AppTestSupport.Harness) async {
        let model = rig.viewModel
        // Explicit user unmute: restoring the phone preference never silently
        // changes it just because the Watch check ended.
        model.applyLocalMute(false)
        let previousOutputFrames = rig.outputBackend.scheduledFrames.count
        model.startAudioCheck()
        await AppTestSupport.waitUntil { model.audioCheckPhase == .recording }
        #expect(model.audioCheckPhase == .recording && !model.isUsingWatchAudio)
        rig.inputBackend.emit(.init(sequenceNumber: 1, format: .intercomPacketAudio,
            capturedAt: 200, samples: Array(repeating: 0.3, count: 480)))
        await AppTestSupport.waitUntil { !model.audioCheckRecordedFrames.isEmpty }
        model.finishAudioCheckRecording(playbackDuration: .seconds(5))
        #expect(model.audioCheckPhase == .playing && model.audioCheckRecordedFrameCount == 480)
        await AppTestSupport.waitUntil { rig.outputBackend.scheduledFrames.count > previousOutputFrames }
        #expect(
            rig.outputBackend.scheduledFrames.dropFirst(previousOutputFrames).contains {
                $0.samples.contains { abs($0) > 0.01 }
            },
            "A restored phone route must actually record/process/schedule new phone audio")
        model.completeAudioCheckPlayback()
        #expect(model.audioCheckPhase == .completed && !model.audioCheckOwnsAudioPipeline)
    }

    @Test func watchAudioPassesThroughThePhoneCallWithoutOpeningPhoneInputOrPlayback() async throws {
        let rig = try AppTestSupport.makeHarnessWithSavedUser(remote: "member-108"), received = Mutex<[Float]>([]),
            ready = Mutex(false)
        let model = rig.viewModel
        let owner = AppCallOwner(account: model.accountSession, viewModel: model)
        var actions: [WatchCallAction] = []
        let client = WatchControlClient { request in
            actions.append(request.action)
            return await owner.handleWatchRequest(request)
        }
        client.setReachable(true); _ = await client.perform(.refresh)
        let target = try #require(client.snapshot?.targets.first,
            "The Watch client must expose a saved destination before starting")
        let originalInput = model.audioInputCapture, originalOutput = model.audioOutputRenderer
        model.applyLocalMute(true) // A phone-only preference cannot silence Watch input.
        let key = Data(repeating: 7, count: 32), sessionID = UUID()
        let watch = try AudioDeviceConnection(sessionID: sessionID, key: key, role: .device,
            onAvailability: { value in ready.withLock { $0 = value } })
        let (watchInput, watchOutput) = makeWatchStreams(watch) { samples in received.withLock { $0 += samples } }
        defer { _ = watchInput.stop(); _ = watchOutput.stop(); watch.stop(); model.disconnect() }
        let local = try await watch.prepare()
        try #require(watchInput.start().result == .applied && watchOutput.start().result == .applied)
        let offer = WatchAudioOffer(sessionID: sessionID, key: key, endpoint: local)
        let reply = try #require(await client.perform(.startAudio(target.id, offer)))
        #expect(reply.problem == nil); #expect(watch.connect(to: try #require(reply.audioEndpoint)))
        rig.callSession.authenticate(["member-108"])
        await AppTestSupport.waitUntil { ready.withLock { $0 } && model.isAudioReady }
        #expect(model.isAudioReady && model.isUsingWatchAudio)
        #expect(model.isMuted, "Watch does not overwrite the saved phone microphone preference")
        #expect(model.audioInputCapture !== originalInput && model.audioOutputRenderer !== originalOutput)
        let deadline = model.callDisconnectDeadline, callReference = model.currentCallReference
        try await verifyWatchTraffic(
            rig: rig, watch: watch, output: watchOutput, receivedSamples: { received.withLock { $0 } },
            verifyCallAfterRelease: {
                #expect(model.isAudioReady && model.isUsingWatchAudio && model.currentCallReference == callReference)
                #expect(
                    actions == [.refresh, .startAudio(target.id, offer)],
                    "Press and release never synchronize phone mute")
            })
        watch.setSendingAllowed(false)
        #expect(rig.inputBackend.startCount == 0)
        #expect(rig.outputBackend.scheduledFrames.isEmpty)
        #expect(model.callDisconnectDeadline == deadline)
        let ended = try #require(await client.perform(.end))
        #expect(ended.problem == nil && client.snapshot?.hasCall == false)
        #expect(actions == [.refresh, .startAudio(target.id, offer), .end])
        #expect(model.watchAudioLink == nil && !model.isAudioReady)
        #expect(model.audioInputCapture === originalInput && model.audioOutputRenderer === originalOutput,
            "Ending the device route restores the original local audio backends")
        #expect(model.isMuted, "Returning to phone audio preserves its own microphone preference")
        await verifyEndedAudio(watch: watch, output: watchOutput, rig: rig)
    }
    private func makeWatchStreams(
        _ watch: AudioDeviceConnection, record: @escaping @Sendable ([Float]) -> Void
    ) -> (AudioInputStreamCapture, AudioOutputStreamRenderer) {
        let watchInput = AudioInputStreamCapture(configuration: .init(voiceProcessing:
            .init(soundIsolationEnabled: false, otherAudioDuckingEnabled: false)), backend: watch)
        let watchOutput = AudioOutputStreamRenderer(configuration: .init(maximumBufferedDuration: 0.1), backend: watch)
        watchInput.setRuntimeEventHandler { event in
            if case .inputFrame(let frame) = event { record(frame.samples) }
        }
        return (watchInput, watchOutput)
    }

    private func verifyEndedAudio(watch: AudioDeviceConnection, output: AudioOutputStreamRenderer,
                                  rig: AppTestSupport.Harness) async {
        let sent = rig.callSession.sentAudioPackets.count
        watch.setSendingAllowed(true)
        _ = output.schedule(.init(sequenceNumber: 100, capturedAt: 200, samples: Array(repeating: 0.3, count: 480)))
        for _ in 0..<20 { await Task.yield() }
        #expect(rig.callSession.sentAudioPackets.count == sent, "Ended audio cannot enter a later call")
    }

    private func verifyWatchTraffic(
        rig: AppTestSupport.Harness,
        watch: AudioDeviceConnection,
        output: AudioOutputStreamRenderer,
        receivedSamples: @escaping () -> [Float],
        verifyCallAfterRelease: () -> Void
    ) async throws {
        func deliver(_ indices: Range<Int>) async throws {
            for index in indices {
                let frame = PCMFrame(sequenceNumber: UInt64(index),
                    format: .init(sampleRate: 48_000, channelCount: 1),
                    capturedAt: 100 + Double(index) * 0.01,
                    samples: (0..<480).map { Float(sin(Double(index * 480 + $0) * .pi * 880 / 48_000)) * 0.3 })
                #expect(output.schedule(frame).result == .applied)
                rig.callSession.receive(
                    try AppTestSupport.receivedAudioPacket(peerID: "member-108", frame: frame, codec: .pcm16))
                // Pace the synthetic source at its existing 10-ms media cadence.
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        watch.setSendingAllowed(true)
        try await deliver(0..<60)
        await AppTestSupport.waitUntil {
            !rig.callSession.sentAudioPackets.isEmpty && receivedSamples().contains { abs($0) > 0.01 }
        }
        #expect(!rig.callSession.sentAudioPackets.isEmpty, "Watch input must reach the existing RTC transmit sink")
        #expect(
            receivedSamples().contains { abs($0) > 0.01 },
            "The phone's mixed receive audio must return to the device")

        // Release only the local device gate: no phone mute/control command.
        watch.setSendingAllowed(false)
        let receivedBeforeRelease = receivedSamples().count
        try await deliver(60..<120)
        await AppTestSupport.waitUntil { receivedSamples().count > receivedBeforeRelease }
        #expect(!watch.isSendingAllowed && watch.isSendReady)
        #expect(
            receivedSamples().count > receivedBeforeRelease,
            "Reception continues while the Watch microphone gate is closed")
        #expect(!rig.callSession.sentAudioPackets.contains { (100.6..<101.2).contains($0.capturedAt) },
            "Frames offered while released must not enter the phone RTC transmitter")
        verifyCallAfterRelease()

        watch.setSendingAllowed(true)
        try await deliver(120..<180)
        await AppTestSupport.waitUntil { rig.callSession.sentAudioPackets.contains { $0.capturedAt >= 101.2 } }
        #expect(
            rig.callSession.sentAudioPackets.contains { $0.capturedAt >= 101.2 },
            "A new explicit press resumes Watch transmission")
    }

}
