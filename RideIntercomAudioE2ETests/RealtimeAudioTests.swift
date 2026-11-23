import AuthenticationServices
import AVFAudio
import AudioCore
import AudioMixer
import Codec
import Foundation
import Synchronization
import RTC
import SessionManager
import XCTest
@testable import RideIntercom

extension AudioE2ETests {
    @MainActor
    func testTransmitIsolationRestoresTheSameNoiseReductionAfterBypass() throws {
        let format = AudioFormat.intercomMixer
        let rate = Int(format.sampleRate)
        let speech = try SpeechFileInput(name: "speech-ja").samples.prefix(8 * rate)
        let angularFrequency = 2 * Double.pi * 397 / format.sampleRate
        let input = speech.enumerated().map { index, sample in
            sample + Float(0.03 * sin(angularFrequency * Double(index)))
        }
        let probe = RenderedAudioProbe()
        let processor = try AudioFrameProcessor(format: format, outputFormat: format, busID: "tx-bus") { frame, _ in
            probe.append(frame, preservingTimeline: true)
        }
        let effect = try XCTUnwrap(AppAudioPipeline.makeIsolation(on: processor.bus, enabled: true,
            configuration: AppAudioPipeline.transmitIsolationConfiguration))
        try processor.start()
        defer { processor.stop() }
        var sequence: UInt64 = 0
        var processed = 0

        func renderToneAmplitude() throws -> Double {
            probe.reset()
            for offset in stride(from: 0, to: input.count, by: 512) {
                let end = min(input.count, offset + 512)
                try processor.process(.init(sequenceNumber: sequence, format: format,
                    capturedAt: Double(processed) / format.sampleRate, samples: Array(input[offset..<end])))
                sequence += 1
                processed += end - offset
            }
            let rendered = probe.snapshot()
            XCTAssertEqual(rendered.samples.count, input.count)
            XCTAssertEqual(rendered.invalid, 0)

            // Integrate whole tone cycles in the steady-state window.
            let window = Array(rendered.samples.dropFirst(rate).prefix(6 * rate))
            var real = 0.0, imaginary = 0.0
            for (index, sample) in window.enumerated() {
                let angle = angularFrequency * Double(index)
                real += Double(sample) * cos(angle)
                imaginary += Double(sample) * sin(angle)
            }
            return 2 * hypot(real, imaginary) / Double(window.count)
        }

        let initial = try renderToneAmplitude()
        try AppAudioPipeline.setIsolationEnabled(effect, on: processor.bus, enabled: false)
        let bypassed = try renderToneAmplitude()
        try processor.bus.prepareEffect(id: "sound-isolation")
        try AppAudioPipeline.setIsolationEnabled(effect, on: processor.bus, enabled: true)
        let restored = try renderToneAmplitude()
        print("Tone amplitude at 397 Hz: initial=\(initial) bypassed=\(bypassed) restored=\(restored)")
        XCTAssertGreaterThan(initial, 0.005, "The enabled mix should retain part of the original signal")
        XCTAssertLessThan(initial, bypassed * 0.8, "The enabled effect should attenuate the tone")
        XCTAssertEqual(restored, initial, accuracy: initial * 0.2)
    }

    @MainActor
    func activateAudioSessionForTest(configuration: AudioSessionConfiguration = .init()) async throws {
        let session = AudioSessionManager()
        // XCTest awaits this cleanup after each test's stream/engine defers.
        addTeardownBlock { @MainActor in
            let report = await session.requestActive(false).value
            XCTAssertTrue(
                [AudioSessionOperationResult.applied, .ignored(.unsupportedOnCurrentPlatform)].contains(report.result),
                "Audio session cleanup failed: \(report.result)"
            )
        }
        _ = try session.configure(configuration)
        let report = await session.requestActive(true).value
        let allowedResults: [AudioSessionOperationResult] = [.applied, .ignored(.unsupportedOnCurrentPlatform)]
        guard allowedResults.contains(report.result) else {
            throw NSError(domain: "AudioE2E.Activation", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Audio session did not activate: \(report.result)"])
        }
    }

    @MainActor
    func testRealtimeAudioLatencyAndIdentity() async throws {
        try await activateAudioSessionForTest(configuration: .init(prefersEchoCancelledInput: true))
        weak var previousPipeline: AppAudioPipeline?
        for fixture in ["speech-ja", "conversation-ja", "conversation-reply-ja"] {
            for codec: RTCAudioCodecIdentifier in [.pcm16, .opus, .mpeg4AACELD] {
                XCTAssertNil(
                    previousPipeline,
                    "The previous case must release its engine before opening another native I/O graph"
                )
                try await measureRealtimeAudio(fixture: fixture, codec: codec) { previousPipeline = $0 }
            }
        }
    }

    @MainActor
    private func measureRealtimeAudio(
        fixture: String, codec: RTCAudioCodecIdentifier, observePipeline: (AppAudioPipeline) -> Void
    ) async throws {
        let audio = try RealtimeAudioCapture(fixture: fixture, observePipeline: observePipeline)
        defer { audio.tearDown() }
        try audio.start(codec: codec)
        let capture = try await audio.recordWindow(fixture: fixture)
        let analysis = try await analyzeRealtimeAudio(audio, fixture: fixture, recording: capture.recorded)
        try attachRealtimeAudio(audio, capture: capture, analysis: analysis, fixture: fixture, codec: codec)
        verifyRealtimeAudio(audio, capture: capture, analysis: analysis, fixture: fixture)
    }

    @MainActor
    private func analyzeRealtimeAudio(
        _ audio: RealtimeAudioCapture, fixture: String, recording recorded: RenderedAudioProbe.Recording
    ) async throws -> RealtimeAudioAnalysis {
        let input = audio.input
        let probe = audio.probe
        let inputTime = try XCTUnwrap(input.firstCaptureTime)
        let outputTime = try XCTUnwrap(probe.firstOutputTime)
        let continuity = await Task.detached {
            SpeechContinuity.measure(reference: input.samples, referenceRate: 48000,
                output: recorded.samples, outputRate: recorded.rate)
        }.value
        let replies = fixture.hasPrefix("conversation") ? try ConversationIdentity.measure(
            fixture: fixture, reference: input.samples, output: recorded.samples, outputRate: recorded.rate,
            referenceOffset: continuity.referenceOffsetSeconds
        ) : nil
        let latency = outputTime - inputTime - continuity.referenceOffsetSeconds
        var stages: [String: Double] = [:]
        var stageContinuities: [String: Any] = [:]
        for (name, stage) in [("transmitted", audio.meters.transmitted), ("mixed", audio.meters.mixed)] {
            let recording = stage.snapshot()
            let match = SpeechContinuity.measure(reference: input.samples, referenceRate: 48000,
                output: recording.samples, outputRate: recording.rate)
            stageContinuities[name] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(match))
            stages[name] = (stage.firstOutputTime ?? 0) - inputTime - match.referenceOffsetSeconds
        }
        return RealtimeAudioAnalysis(
            inputTime: inputTime, outputTime: outputTime, continuity: continuity, replies: replies, latency: latency,
            stages: stages, stageContinuities: stageContinuities
        )
    }

    @MainActor
    private func attachRealtimeAudio(
        _ audio: RealtimeAudioCapture, capture: RealtimeAudioWindow, analysis: RealtimeAudioAnalysis,
        fixture: String, codec: RTCAudioCodecIdentifier
    ) throws {
        let name = "realtime-\(fixture)-\(codec.rawValue)"
        let input = audio.input
        let pipeline = audio.pipeline
        let playout = capture.playout
        let recorded = capture.recorded
        let continuity = analysis.continuity
        let replies = analysis.replies
        let measurement: [String: Any] = [
            "scenario": name, "role": "pipeline", "transport": "none",
            "codec": pipeline.codecRuntimeReport.selectedCodec.rawValue, "fixture": fixture,
            "acknowledgements": try audioE2EOptionalJSON(replies),
            "captureTiming": input.captureTiming, "captureDiscontinuities": input.captureDiscontinuities,
            "playoutAdjustments": playout?.adjustments ?? 0, "playoutResets": playout?.resets ?? 0,
            "stageLatencies": analysis.stages, "stageContinuities": analysis.stageContinuities,
            "nodeLatencies": capture.nodeLatencies,
            "maximumInputDeliveryAge": audio.meters.inputAges.withLock { $0.max() ?? 0 },
            "maximumEncodeDeliveryAge": audio.meters.txAges.withLock { $0.max() ?? 0 },
            "maximumMixerDeliveryAge": audio.meters.mixAges.max() ?? 0,
            "renderLatencySeconds": analysis.latency,
            "outputPresentationLatencySeconds": audio.engine.outputNode.outputPresentationLatency,
            "inputStartHostTime": analysis.inputTime, "outputStartHostTime": analysis.outputTime,
            "continuity": try JSONSerialization.jsonObject(with: JSONEncoder().encode(continuity)),
            "continuityPassed": continuity.passed && continuity.missingActiveRatio == 0
                && (replies?.passed ?? true),
            "renderedSamples": recorded.samples.count, "sampleRate": recorded.rate,
            "processingFailures": capture.errors, "encodingFailures": pipeline.transmitEncodingFailureCount,
            "captureDroppedFrames": capture.drops.capture,
            "deliveryDroppedFrames": capture.drops.delivery,
            "renderDroppedFrames": capture.drops.render,
            "outputPlaybackResets": capture.playbackResets
        ]
        try addAudioE2EJSONAttachment(measurement, name: name + "-measurement", options: [.sortedKeys])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".wav")
        try audio.probe.writeWAV(to: url, rendered: recorded)
        let attachment = XCTAttachment(contentsOfFile: url)
        attachment.name = name + "-speech"
        attachment.lifetime = .keepAlways
        add(attachment)
        try? FileManager.default.removeItem(at: url)
    }

    @MainActor
    private func verifyRealtimeAudio(
        _ audio: RealtimeAudioCapture, capture: RealtimeAudioWindow, analysis: RealtimeAudioAnalysis, fixture: String
    ) {
        let errors = capture.errors
        let dropped = capture.drops
        let continuity = analysis.continuity
        let latency = analysis.latency
        XCTAssertTrue(errors.isEmpty, errors.joined(separator: "; "))
        XCTAssertEqual(audio.pipeline.transmitEncodingFailureCount, 0)
        XCTAssertEqual(dropped.capture, 0)
        XCTAssertEqual(dropped.delivery, 0)
        XCTAssertEqual(dropped.render, 0)
        XCTAssertTrue(continuity.passed, "\(fixture): \(continuity)")
        XCTAssertEqual(continuity.missingActiveRatio, 0, "Even sub-percent missing speech is a regression")
        if let replies = analysis.replies { XCTAssertTrue(replies.passed, "\(fixture): \(replies)") }
        XCTAssertGreaterThanOrEqual(latency, -0.01)
        XCTAssertLessThanOrEqual(
            latency + 0.01, 0.125, "Include the 10 ms alignment resolution in the latency budget"
        )
    }
}

private struct RealtimeAudioAnalysis {
    let inputTime: Double
    let outputTime: Double
    let continuity: SpeechContinuity
    let replies: ConversationIdentity?
    let latency: Double
    let stages: [String: Double]
    let stageContinuities: [String: Any]
}

#if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS) && targetEnvironment(simulator)
extension AudioE2ETests {
    /// Native capture clock and output with fixture PCM at the microphone boundary.
    /// Compares the post-TX recording with output over two runs; it does not
    /// compare the fixture waveform with the processed recording.
    @MainActor
    func testRecordingCheckPreservesWholeSpeechAcrossNativePlaybackAndRestart() async throws {
        let namespace = "RideIntercom.AudioE2E.AudioCheck." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: namespace))
        let keychain = FixtureKeychain()
        let credentials = KeychainGroupCredentialStore(keychain: keychain, namespace: namespace)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(namespace)
        defer {
            defaults.removePersistentDomain(forName: namespace)
            for ref in (try? credentials.references()) ?? [] { try? credentials.delete(reference: ref) }
            try? FileManager.default.removeItem(at: directory)
        }
        let engine = AVAudioEngine()
        let input = try SpeechFileInput(name: "speech-ja", engine: engine)
        let output = SystemAudioOutputStreamBackend(engine: engine)
        let account = AppleAccountSession(keychain: keychain, defaults: defaults, namespace: namespace,
            credentialState: { _ in .authorized })
        let request = ASAuthorizationAppleIDProvider().createRequest()
        account.prepare(request)
        XCTAssertTrue(account.completeSignIn(userID: "audio-check-e2e", state: request.state))
        let settings = UserDefaultsAppSettingsStore(defaults: defaults)
        settings.save(AppSettings())
        let viewModel = IntercomViewModel(accountSession: account, enforceCallAccess: false,
            groupRepository: GroupRepository(store: FileGroupStore(directory: directory), credentials: credentials),
            appSettingsStore: settings,
            internetSettingsStore: InternetConnectionSettingsStore(keychain: keychain, namespace: namespace),
            localMemberIdentityStore: UserDefaultsLocalMemberIdentityStore(defaults: defaults),
            invitationAuthority: DirectInvitationAuthority(keychain: keychain, namespace: namespace),
            requestMicrophoneAccess: { await AVAudioApplication.requestRecordPermission() },
            audioInputCapture: AudioInputStreamCapture(configuration: .intercom(
                voiceProcessing: IntercomViewModel.defaultVoiceProcessingConfiguration()), backend: input),
            audioOutputRenderer: AudioOutputStreamRenderer(configuration: .intercom, backend: output))

        defer {
            viewModel.cancelAudioCheck()
            viewModel.audioPipeline.onOutputFrame = nil
        }
        XCTAssertFalse(viewModel.isMuted)
        XCTAssertTrue(viewModel.isSoundIsolationEnabled)
        var rows: [[String: Any]] = []
        for cycle in 1...2 {
            rows.append(try await measureAudioCheckCycle(cycle, viewModel: viewModel, engine: engine, input: input))
        }
        let data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys, .prettyPrinted])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Audio Check native speech recording two cycles"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    private func measureAudioCheckCycle(
        _ cycle: Int, viewModel: IntercomViewModel, engine: AVAudioEngine, input: SpeechFileInput
    ) async throws -> [String: Any] {
        var observation = AudioCheckValidationObservation(generation: UUID())
        var referenceInstalled = false
        var renderDrops = 0
        var inputDrops: Int?
        viewModel.startAudioCheck()
        let original = viewModel.audioPipeline.onOutputFrame
        viewModel.audioPipeline.onOutputFrame = { frame in
            original?(frame)
            guard viewModel.audioCheckPhase == .playing else { return }
            if !referenceInstalled, let frames = try? viewModel.audioCheckRecording?.recordedFrames() {
                observation.setInput(frames)
                referenceInstalled = true
            }
            observation.appendOutput(frame)
            renderDrops = max(renderDrops, viewModel.audioPipeline.droppedRenderFrameCount)
            if let count = viewModel.inputFrameDelivery?.droppedFrameCount {
                inputDrops = max(inputDrops ?? 0, count)
            }
        }
        let started = ContinuousClock.now
        while viewModel.audioCheckPhase.isInProgress, started.duration(to: .now) < .seconds(15) {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(viewModel.audioCheckPhase, .completed, viewModel.audioCheckStatusMessage)
        XCTAssertEqual(viewModel.audioCheckRecordedFrameCount, 240_000)
        XCTAssertFalse(viewModel.hasAnyActiveGroupConnection)
        XCTAssertFalse(engine.isRunning)
        XCTAssertTrue(input.captureDiscontinuities.isEmpty, "Native capture must not omit fixture time")
        XCTAssertNotNil(inputDrops, "Input delivery drop count must be sampled during playback")
        XCTAssertEqual(inputDrops, 0)
        var row = observation.record(
            phase: viewModel.audioCheckPhase.rawValue,
            status: .init(droppedRenderFrames: renderDrops, droppedInputFrames: inputDrops ?? -1,
                          inputStopped: !engine.isRunning, outputStopped: !engine.isRunning,
                          nativeBackends: false, watchRoute: false, engineRunning: engine.isRunning)
        )
        row["cycle"] = cycle
        row["nativeCaptureClock"] = true
        row["nativeOutput"] = true
        row["microphonePCMReplacedByFixture"] = true
        row["comparisonReference"] = "Post-TX decoded recording, not the original fixture"
        XCTAssertEqual(row["comparison"] as? String, "measured")
        XCTAssertEqual(row["fullCoverage"] as? Bool, true)
        XCTAssertGreaterThanOrEqual(row["fullSignalCorrelation"] as? Double ?? -1, 0.99)
        XCTAssertLessThanOrEqual(row["fullSignalNormalizedRMSError"] as? Double ?? 1, 0.01)
        XCTAssertLessThanOrEqual(row["silentResidualRMS"] as? Double ?? 1, 0.00001)
        XCTAssertEqual(renderDrops, 0)
        viewModel.audioPipeline.onOutputFrame = original
        return row
    }
}
#endif
