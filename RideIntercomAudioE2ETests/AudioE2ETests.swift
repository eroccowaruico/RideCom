import AVFAudio
import AudioCore
import AudioMixer
import Codec
import Foundation
import RTC
import SessionManager
import Synchronization
import XCTest
@testable import RideIntercom

final class AudioE2ETests: XCTestCase {
    func testFixturePreservesClockGapsWithoutDelayingLaterSpeech() {
        var fixture = CaptureTimedFixture(samples: (0..<48000).map(Float.init))
        XCTAssertEqual(fixture.render(capturedAt: 100, format: .init(), frameCount: 480), (0..<480).map(Float.init))
        XCTAssertEqual(
            fixture.render(capturedAt: 100.02, format: .init(), frameCount: 480), (960..<1440).map(Float.init),
            "A missing 10 ms interval must omit exactly those samples, not shift the rest of the utterance"
        )
        XCTAssertEqual(
            fixture.render(capturedAt: 100.03, format: .init(), frameCount: 480), (1440..<1920).map(Float.init)
        )
    }
    #if os(macOS)
    @MainActor
    func testMacFixturePacesCompletedSamples() async throws {
        let input = SpeechFileInput(samples: Array(repeating: 0.1, count: 48000))
        _ = try input.startCapture(configuration: .intercom(voiceProcessing: .init())) { _ in }
        defer { try? input.stopCapture() }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNotNil(input.firstCaptureTime)
        XCTAssertGreaterThanOrEqual(input.captureTiming["minimumCompletedSampleAge"] ?? -1, -0.001,
            "The fixture must finish capturing every sample before delivering it, just like a microphone")
    }
    #endif
    /// Same production mixer/codec/output, in one process, without RTC or VAD.
    /// Compare 20 ms file delivery with the 100 ms capture batches seen on iOS.
    @MainActor
    func testSpeechContinuityWithoutNetwork() async throws {
        let samples = try SpeechFileInput(name: "speech-ja").samples
        var failures: [String] = []
        for milliseconds in [20, 100] {
            if let failure = try await measureLocalPipeline(samples: samples, milliseconds: milliseconds) {
                failures.append(failure)
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }

    @MainActor
    private func measureLocalPipeline(samples: [Float], milliseconds: Int) async throws -> String? {
        let name = "pipeline-\(milliseconds)ms"
        let probe = RenderedAudioProbe()
        let engine = AVAudioEngine()
        let output = SystemAudioOutputStreamBackend(engine: engine)
        try engine.mainMixerNode.installAudioTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, time in
            probe.append(buffer, time: time)
        }
        defer { engine.mainMixerNode.removeTap(onBus: 0); try? output.stopRendering() }
        let hardware = try output.startRendering(configuration: .intercom)
        let pipeline = AppAudioPipeline(makeEngine: { engine }, usesHardwareClock: true)
        defer { pipeline.stop() }
        let processingFailureStore = Mutex<[String]>([])
        pipeline.onTransmitPacket = { [weak pipeline] packet in
            guard let pipeline else { return }
            do {
                try pipeline.processReceivedAudioPacket(
                    .init(peerID: PeerID(rawValue: "loopback"), packet: packet))
            } catch { processingFailureStore.withLock { $0.append(String(describing: error)) } }
        }
        try rebuildLocalPipeline(pipeline, outputFormat: hardware)
        let resetStart = try await feedLocalPipeline(
            pipeline, samples: samples, milliseconds: milliseconds, probe: probe, output: output
        )
        let rendered = probe.snapshot()
        let processingFailures = processingFailureStore.withLock { $0 }
        let resets = (output.playbackResetCount ?? 0) - resetStart
        let playout = pipeline.receivePlayoutDiagnostics(peerID: "loopback")
        XCTAssertNotNil(playout)
        let mixer = String(describing: pipeline.snapshot)
        pipeline.stop()
        try output.stopRendering()
        let continuity = await Task.detached {
            SpeechContinuity.measure(reference: samples, referenceRate: 48_000,
                                     output: rendered.samples, outputRate: rendered.rate)
        }.value
        let measurement: [String: Any] = ["scenario": name, "role": "pipeline", "transport": "none",
            "remoteFixture": "speech-ja", "continuityPassed": continuity.passed && continuity.missingActiveRatio == 0,
            "continuity": try JSONSerialization.jsonObject(with: JSONEncoder().encode(continuity)),
            "renderedSamples": rendered.samples.count, "sampleRate": rendered.rate,
            "outputPlaybackResets": resets, "playoutAdjustments": playout?.adjustments ?? 0,
            "playoutResets": playout?.resets ?? 0, "mixer": mixer, "processingFailures": processingFailures]
        try attachLocalPipelineRecording(measurement, name: name, probe: probe, rendered: rendered)
        if !continuity.passed || continuity.missingActiveRatio != 0 || !processingFailures.isEmpty
            || rendered.invalid > 0 || rendered.samples.count < Int(rendered.rate * 19) {
            return "\(name): matched=\(continuity.matchedWindowRatio), missing=\(continuity.missingActiveRatio), "
                + "resets=\(resets), errors=\(processingFailures)"
        }
        return nil
    }

    @MainActor
    private func rebuildLocalPipeline(_ pipeline: AppAudioPipeline, outputFormat: AudioFormat) throws {
        try pipeline.rebuild(configuration: .init(rtcSendFormat: .init(sampleRate: 48_000, channelCount: 1),
            outputHardwareFormat: outputFormat, preferredCodec: .pcm16, transmitSoundIsolationEnabled: false,
            maximumBufferedDuration: 0.1,
            receiveMaximumBufferedDuration: AppAudioPipelineConfiguration.callReceiveMaximumBufferedDuration,
            receivePlayoutDelay: AppAudioPipelineConfiguration.callReceivePlayoutDelay), peerIDs: ["loopback"])
    }

    @MainActor
    private func feedLocalPipeline(
        _ pipeline: AppAudioPipeline, samples: [Float], milliseconds: Int,
        probe: RenderedAudioProbe, output: SystemAudioOutputStreamBackend
    ) async throws -> Int {
        let start = ContinuousClock.now
        let count = milliseconds * 48
        let captureDuration = Double(count) / 48_000
        let firstCapturedAt = ProcessInfo.processInfo.systemUptime - captureDuration
        var resetStart = 0
        for index in 0..<(22_000 / milliseconds) {
            try await Task.sleep(until: start + .milliseconds(index * milliseconds), clock: .continuous)
            if index == 2_000 / milliseconds { probe.reset(); resetStart = output.playbackResetCount ?? 0 }
            let block = (0..<count).map { samples[(index * count + $0) % samples.count] }
            try pipeline.processCapturedFrame(PCMFrame(sequenceNumber: UInt64(index),
                format: .init(sampleRate: 48_000, channelCount: 1),
                capturedAt: firstCapturedAt + Double(index) * captureDuration, samples: block))
        }
        try await Task.sleep(until: start + .seconds(22), clock: .continuous)
        return resetStart
    }

    private func attachLocalPipelineRecording(
        _ measurement: [String: Any], name: String, probe: RenderedAudioProbe, rendered: RenderedAudioProbe.Recording
    ) throws {
        try addAudioE2EJSONAttachment(measurement, name: name + "-measurement", options: [.sortedKeys])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try probe.writeWAV(to: url, rendered: rendered)
        let recording = XCTAttachment(contentsOfFile: url)
        recording.name = name + "-speech"; recording.lifetime = .keepAlways; add(recording)
    }

    @MainActor
    func testSystemSessionAcceptsCallProfiles() throws {
        let manager = AudioSessionManager()
        for configuration in [
            AudioSessionConfiguration(),
            AudioSessionConfiguration(prefersEchoCancelledInput: true),
            AudioSessionConfiguration(defaultToSpeaker: true),
            AudioSessionConfiguration(mode: .voiceChat)
        ] {
            let report = try manager.configure(configuration)
            print("SYSTEM SESSION: \(report)")
            for operation in report.operations {
                if case .failed = operation.result { XCTFail("\(configuration): \(operation)") }
            }
        }
    }

    @MainActor
    func testDuplexSpeechOverNetwork() async throws {
        continueAfterFailure = false
        let run = try AudioE2ENetworkRun(environment: ProcessInfo.processInfo.environment)
        run.verifyConfiguration()
        let routes = try AudioE2ERouteFixture(run: run)
        let worker = try await startWorker(for: run)
        let audio = try AudioE2ENativeAudio(run: run)
        defer { audio.removeOutputProbe() }
        let storage = try AudioE2ECallStorage(run: run)
        defer { storage.cleanup() }
        let viewModel = try await storage.makeViewModel(run: run, routes: routes, worker: worker, audio: audio)
        defer { viewModel.disconnect() }
        viewModel.setSoundIsolationEnabled(run.initial.transmitIsolation)
        // The Mac and Simulator share one host audio service. The runner starts
        // the other endpoint after this native setup, before either media test.
        FileHandle.standardOutput.write(Data("AUDIO_E2E_NATIVE_READY\n".utf8))
        let invitation = try storage.makeInvitation(for: run)
        if run.standaloneReceiver {
            try await sendToStandaloneReceiver(viewModel: viewModel, invitation: invitation,
                                               directory: storage.directory, seconds: run.initial.seconds)
            return
        }
        let endpoint = AudioE2EEndpoint(run: run, audio: audio, worker: worker, directory: storage.directory,
                                       viewModel: viewModel)
        try await verifyDuplex(endpoint, invitation: invitation, routes: routes)
    }

    @MainActor
    private func sendToStandaloneReceiver(
        viewModel: IntercomViewModel, invitation: URL, directory: URL, seconds: Double
    ) async throws {
        XCTAssertTrue((6...20).contains(seconds))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let invitationFile = directory.appendingPathComponent("receiver-invitation.url")
        let joinCommand = directory.appendingPathComponent("join")
        try Data(invitation.absoluteString.utf8).write(to: invitationFile, options: .atomic)
        FileHandle.standardOutput.write(Data("AUDIO_E2E_STANDALONE_INVITE_READY\n".utf8))
        // The operator releases the sender only after the receiving app has been
        // in the intended OS state for the required duration.
        try await waitUntil(
            seconds: 600, description: "Standalone receiver wait",
            status: { "join command missing" },
            condition: {
                FileManager.default.fileExists(atPath: joinCommand.path)
            }
        )
        try viewModel.acceptInviteURL(invitation)
        try await waitUntil(
            seconds: 45, description: "Authenticated standalone receiver",
            status: { viewModel.routeLabel },
            condition: {
                viewModel.availableCallRoutes == [.multipeer] && viewModel.authenticatedPeerIDs.count == 1
                    && viewModel.isAudioReady && viewModel.isCallMediaStarted
            }
        )
        let call = viewModel.currentCallReference
        let packets = viewModel.sentVoicePacketCount
        let adapter = try XCTUnwrap(viewModel.callSession as? RideIntercomCallSessionAdapter)
        let queuedDropsBeforeSpeech = adapter.droppedAudioPacketCount
        func localDatagramsSent(_ diagnostics: RTCNetworkDiagnostics?) -> UInt64? {
            diagnostics?.routes.first { $0.route == .multipeer }?.statistics.sentMediaDatagrams
        }
        let diagnosticsBeforeSpeech = viewModel.networkDiagnostics
        let startedAt = Date().timeIntervalSince1970
        try await Task.sleep(for: .seconds(seconds))
        XCTAssertEqual(viewModel.currentCallReference, call)
        XCTAssertEqual(viewModel.authenticatedPeerIDs.count, 1)
        XCTAssertGreaterThan(viewModel.sentVoicePacketCount, packets)
        let diagnosticsAfterSpeech = try XCTUnwrap(viewModel.networkDiagnostics)
        let datagramsAfterSpeech = try XCTUnwrap(localDatagramsSent(diagnosticsAfterSpeech))
        XCTAssertGreaterThan(datagramsAfterSpeech, localDatagramsSent(diagnosticsBeforeSpeech) ?? 0)
        let evidence: [String: Any] = ["startedAt": startedAt, "endedAt": Date().timeIntervalSince1970,
            "sentVoicePackets": viewModel.sentVoicePacketCount - packets,
            "senderQueueDropsDuringSpeech": adapter.droppedAudioPacketCount - queuedDropsBeforeSpeech,
            "localDatagramsBeforeSpeech": localDatagramsSent(diagnosticsBeforeSpeech) as Any? ?? NSNull(),
            "localDatagramsAfterSpeech": datagramsAfterSpeech,
            "localSampleBeforeSpeechAt": diagnosticsBeforeSpeech?.generatedAt as Any? ?? NSNull(),
            "localSampleAfterSpeechAt": diagnosticsAfterSpeech.generatedAt]
        try addAudioE2EJSONAttachment(evidence, name: "standalone-sender-observation")
    }
}

@MainActor
func waitUntil(
    seconds: Double, description: String, status: () -> String, condition: () async -> Bool
) async throws {
    let start = ContinuousClock.now
    while !(await condition()), start.duration(to: .now) < .seconds(seconds) {
        try await Task.sleep(for: .milliseconds(50))
    }
    guard await condition() else {
        XCTFail("\(description) timed out: \(status())")
        throw NSError(domain: "AudioE2E", code: 1)
    }
}

@MainActor
func observedOutputBatches(_ model: IntercomViewModel) -> Int {
    model.nativeRenderedOutputBatchCount + model.scheduledOutputBatchCount
}
