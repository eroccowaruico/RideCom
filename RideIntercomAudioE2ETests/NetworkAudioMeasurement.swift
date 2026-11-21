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

private struct NetworkAudioAnalysis {
    let match: Float
    let localMatch: Float
    let continuity: SpeechContinuity
    let mixedContinuity: SpeechContinuity
    let decodedContinuity: SpeechContinuity
    let peak: Float
    let replies: ConversationIdentity?
    let mixedRecording: RenderedAudioProbe.Recording
    let decodedRecording: RenderedAudioProbe.Recording

    var continuityPassed: Bool {
        continuity.passed && continuity.missingActiveRatio == 0 && (replies?.passed ?? true)
    }
}

struct NetworkAudioCounts {
    let transmitted: Int
    let received: Int
    let outputBatches: Int
    let playbackResets: Int
}

extension AudioE2ETests {
    func addAudioE2EJSONAttachment(
        _ payload: [String: Any], name: String, options: JSONSerialization.WritingOptions = []
    ) throws {
        let data = try JSONSerialization.data(withJSONObject: payload, options: options)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func measureNetworkScenarios(_ pair: AudioE2EPair, receiveTrace: NetworkAudioReception) async throws {
        // Preserve every failing quality condition and its recording. Connection
        // setup still throws on timeout, so a missing peer cannot count as a run.
        continueAfterFailure = true
        var continuityFailures: [String] = []
        for scenario in pair.endpoint.run.scenarios {
            try await prepareNetworkScenario(scenario, pair: pair)
            let failures = try await measureNetworkScenario(scenario, pair: pair, receiveTrace: receiveTrace)
            continuityFailures.append(contentsOf: failures)
            try await pair.barrier.meet("measured-" + scenario.id)
        }
        // Report a normal failed test after collecting every condition. With
        // continueAfterFailure=false, XCTest aborts this async Swift test host
        // and adds an unrelated "runner exited with code 75" failure.
        continueAfterFailure = true
        XCTAssertTrue(
            continuityFailures.isEmpty, "Speech continuity failed: " + continuityFailures.joined(separator: "; ")
        )
    }

    @MainActor
    private func prepareNetworkScenario(_ scenario: AudioE2EScenario, pair: AudioE2EPair) async throws {
        let viewModel = pair.endpoint.viewModel
        let barrier = pair.barrier
        let peerID = pair.peerID
        try await barrier.meet("begin-" + scenario.id)
        try scenario.apply(to: viewModel, peerID: peerID)
        try await waitUntil(
            seconds: 60, description: "Reconfigured audio " + scenario.id, status: pair.endpoint.status
        ) {
            viewModel.authenticatedPeerIDs.count == 1 && viewModel.isAudioReady
        }
        let waitingWorker = pair.endpoint.pendingInternetWorker
        if let waitingWorker {
            try await waitUntil(
                seconds: 5, description: "Both Internet requests are pending", status: pair.endpoint.status
            ) {
                await waitingWorker.pendingICEPeers.count == 2
            }
        }
        try await barrier.meet("configured-" + scenario.id)
        // Drain bounded playback and effect tails before measuring a mute.
        try await Task.sleep(for: .seconds(2))
        scenario.verifyApplied(to: viewModel, peerID: peerID)
    }

    @MainActor
    private func measureNetworkScenario(
        _ scenario: AudioE2EScenario, pair: AudioE2EPair, receiveTrace: NetworkAudioReception
    ) async throws -> [String] {
        let endpoint = pair.endpoint
        let window = try await captureNetworkAudio(scenario, endpoint: endpoint, receiveTrace: receiveTrace)
        try await attachNetworkTrace(window, scenario: scenario, endpoint: endpoint)
        let viewModel = endpoint.viewModel
        let counts = NetworkAudioCounts(
            transmitted: viewModel.sentVoicePacketCount - window.before.transmitted,
            received: viewModel.receivedVoicePacketCount - window.before.received,
            outputBatches: observedOutputBatches(viewModel) - window.before.outputBatches,
            playbackResets: (endpoint.audio.output.playbackResetCount ?? 0) - window.before.playbackResets
        )
        XCTAssertEqual(window.rendered.invalid, 0)
        XCTAssertGreaterThan(window.rendered.samples.count, Int(window.rendered.rate * scenario.seconds * 0.8))
        let analysis = try await analyzeNetworkAudio(
            scenario, window: window, audio: endpoint.audio, receiveTrace: receiveTrace
        )
        var failures: [String] = []
        if let replies = analysis.replies, !replies.passed {
            failures.append("\(scenario.id): short reply identity failed: \(replies)")
        }
        XCTAssertLessThanOrEqual(analysis.peak, 1.001, "Limiter must bound the actual output")
        try attachNetworkMeasurement(scenario, endpoint: endpoint, window: window, analysis: analysis, counts: counts)
        try await attachNetworkRecordings(scenario, endpoint: endpoint, window: window, analysis: analysis)
        if let failure = verifyNetworkOutput(scenario, window: window, analysis: analysis, counts: counts,
                                             status: endpoint.status) {
            failures.append(failure)
        }
        return failures
    }

    @MainActor
    private func attachNetworkTrace(
        _ window: NetworkAudioWindow, scenario: AudioE2EScenario, endpoint: AudioE2EEndpoint
    ) async throws {
        let waitsForInternet = endpoint.run.waitsForInternet
        if waitsForInternet { try window.verifyRenderClock() }
        let scenarioID = scenario.id
        let packetTrace = window.packetTrace(scenarioID: scenarioID, waitsForInternet: waitsForInternet)
        let traceData = try await Task.detached { try JSONEncoder().encode(packetTrace) }.value
        let trace = XCTAttachment(data: traceData, uniformTypeIdentifier: "public.json")
        trace.name = "endpoint-\(endpoint.run.role)-\(scenario.id)-packet-timing"
        trace.lifetime = .keepAlways
        add(trace)
    }

    @MainActor
    private func analyzeNetworkAudio(
        _ scenario: AudioE2EScenario, window: NetworkAudioWindow, audio: AudioE2ENativeAudio,
        receiveTrace: NetworkAudioReception
    ) async throws -> NetworkAudioAnalysis {
        let rendered = window.rendered
        let remoteSamples = audio.remote.samples
        let localSamples = audio.input.samples
        let remoteFixture = audio.remoteFixture
        let mixedRecording = audio.mixedProbe.snapshot()
        let decodedRecording = audio.decodedProbe.snapshot()
        // Analysis must not block the app actor and manufacture a keepalive timeout.
        let (match, localMatch, continuity) = await Task.detached {
            (RenderedAudioProbe.speechMatch(reference: remoteSamples, referenceRate: 48_000,
                output: rendered.samples, outputRate: rendered.rate),
             RenderedAudioProbe.speechMatch(reference: localSamples, referenceRate: 48_000,
                output: rendered.samples, outputRate: rendered.rate),
             SpeechContinuity.measure(reference: remoteSamples, referenceRate: 48_000,
                output: rendered.samples, outputRate: rendered.rate))
        }.value
        let mixedContinuity = await Task.detached {
            SpeechContinuity.measure(reference: remoteSamples, referenceRate: 48_000,
                output: mixedRecording.samples, outputRate: mixedRecording.rate)
        }.value
        let decodedContinuity = await Task.detached {
            SpeechContinuity.measure(reference: remoteSamples, referenceRate: 48_000,
                output: decodedRecording.samples, outputRate: decodedRecording.rate)
        }.value
        XCTAssertEqual(receiveTrace.decodeFailures.withLock { $0 } - window.failuresBefore, 0)
        let peak = rendered.samples.reduce(Float(0)) { max($0, abs($1)) }
        let needsReplies = remoteFixture.hasPrefix("conversation") && !scenario.expectsSilence
        let replies = try await Task.detached {
            needsReplies ? try ConversationIdentity.measure(fixture: remoteFixture, reference: remoteSamples,
                output: rendered.samples, outputRate: rendered.rate, referenceOffset: continuity.referenceOffsetSeconds)
            : nil
        }.value
        return NetworkAudioAnalysis(
            match: match, localMatch: localMatch, continuity: continuity, mixedContinuity: mixedContinuity,
            decodedContinuity: decodedContinuity, peak: peak, replies: replies,
            mixedRecording: mixedRecording, decodedRecording: decodedRecording
        )
    }

    @MainActor
    private func attachNetworkMeasurement(
        _ scenario: AudioE2EScenario, endpoint: AudioE2EEndpoint, window: NetworkAudioWindow,
        analysis: NetworkAudioAnalysis, counts: NetworkAudioCounts
    ) throws {
        let viewModel = endpoint.viewModel
        let role = endpoint.run.role
        let transport = endpoint.run.transport
        let input = endpoint.audio.input
        let mixedProbe = endpoint.audio.mixedProbe
        let localFixture = endpoint.audio.localFixture
        let remoteFixture = endpoint.audio.remoteFixture
        let outputEngine = endpoint.audio.outputEngine
        let rendered = window.rendered
        let report = viewModel.audioPipeline.codecRuntimeReport
        let measurement: [String: Any] = ["scenario": scenario.id, "role": role, "transport": transport,
            "localFixture": localFixture, "remoteFixture": remoteFixture,
            "localFixtureDurationSeconds": Double(input.samples.count) / 48_000,
            "continuity": try JSONSerialization.jsonObject(with: JSONEncoder().encode(analysis.continuity)),
            "continuityPassed": analysis.continuityPassed,
            "acknowledgements": try audioE2EOptionalJSON(analysis.replies),
            "outputPlaybackResets": counts.playbackResets,
            "firstCaptureHostTime": window.firstCapture as Any? ?? NSNull(),
            "firstOutputHostTime": window.firstOutput as Any? ?? NSNull(),
            "firstMixedHostTime": mixedProbe.firstOutputTime as Any? ?? NSNull(),
            "mixedContinuity": try JSONSerialization.jsonObject(with: JSONEncoder().encode(analysis.mixedContinuity)),
            "firstDecodedCaptureTime": window.steadyFirstDecoded as Any? ?? NSNull(),
            "decodedContinuity": try audioE2EOptionalJSON(analysis.decodedContinuity),
            "outputPresentationLatencySeconds": outputEngine.outputNode.outputPresentationLatency,
            "captureTiming": input.captureTiming, "captureDiscontinuities": input.captureDiscontinuities,
            "voiceProcessingTimings": input.voiceProcessingTimings,
            "networkDiagnostics": try audioE2EOptionalJSON(viewModel.networkDiagnostics),
            "droppedFramesAndPackets": window.dropped,
            "requestedCodec": scenario.codec, "selectedCodec": report.selectedCodec.rawValue,
            "fallback": report.isFallback, "format": scenario.format, "requestedBitRate": scenario.bitRate,
            "selectedBitRate": report.activeConfiguration.activeBitRate as Any? ?? NSNull(),
            "sessionReport": String(describing: viewModel.lastAudioSessionConfigurationReport),
            "voiceProcessingReport": String(describing: viewModel.lastVoiceProcessingOperationReport),
            "mixer": String(describing: viewModel.audioPipeline.snapshot),
            "remoteSpeechCorrelation": analysis.match, "localSpeechCorrelation": analysis.localMatch,
            "renderedSamples": rendered.samples.count, "sampleRate": rendered.rate,
            "peak": analysis.peak, "transmitted": counts.transmitted, "received": counts.received,
            "outputBatches": counts.outputBatches,
            "expectedSilence": scenario.expectsSilence]
        try addAudioE2EJSONAttachment(
            measurement, name: "endpoint-\(role)-\(scenario.id)-measurement", options: [.sortedKeys]
        )
    }

    @MainActor
    private func attachNetworkRecordings(
        _ scenario: AudioE2EScenario, endpoint: AudioE2EEndpoint,
        window: NetworkAudioWindow, analysis: NetworkAudioAnalysis
    ) async throws {
        let directory = endpoint.directory
        let role = endpoint.run.role
        let waitsForInternet = endpoint.run.waitsForInternet
        let probe = endpoint.audio.probe
        let rendered = window.rendered
        let startupDecoded = window.startupDecoded
        let startupOutput = window.startupOutput
        let continuityPassed = analysis.continuityPassed
        let decodedRecording = analysis.decodedRecording
        let mixedRecording = analysis.mixedRecording
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var recordings = [("speech", rendered)]
        if !scenario.expectsSilence && (!continuityPassed || waitsForInternet) {
            recordings.append(("decoded", decodedRecording))
            recordings.append(("mixed", mixedRecording))
        }
        if let startupDecoded, let startupOutput {
            recordings.append(("startup-decoded", startupDecoded))
            recordings.append(("startup-speech", startupOutput.audio))
        }
        for (stage, snapshot) in recordings where !snapshot.samples.isEmpty {
            let name = "endpoint-\(role)-\(scenario.id)-\(stage)"
            let url = directory.appendingPathComponent("\(name).wav")
            try await Task.detached { try probe.writeWAV(to: url, rendered: snapshot) }.value
            let recording = XCTAttachment(contentsOfFile: url)
            recording.name = name; recording.lifetime = .keepAlways; add(recording)
        }
    }

    private func verifyNetworkOutput(
        _ scenario: AudioE2EScenario, window: NetworkAudioWindow, analysis: NetworkAudioAnalysis,
        counts: NetworkAudioCounts, status: () -> String
    ) -> String? {
        let dropped = window.dropped
        let peak = analysis.peak
        let match = analysis.match
        let localMatch = analysis.localMatch
        let continuity = analysis.continuity
        let transmitted = counts.transmitted
        let received = counts.received
        let outputBatches = counts.outputBatches
        if scenario.expectsSilence {
            XCTAssertLessThan(peak, 0.001, "\(scenario.id) must silence the actual render output")
        } else {
            XCTAssertTrue(dropped.values.allSatisfy { $0 == 0 }, "\(scenario.id): internal drops \(dropped)")
            XCTAssertGreaterThan(transmitted, 20, status())
            XCTAssertGreaterThan(received, 20, status())
            XCTAssertGreaterThan(outputBatches, 20, status())
            XCTAssertGreaterThan(match, 0.45, "Remote speech missing in \(scenario.id): \(status())")
            XCTAssertGreaterThan(match, localMatch + 0.10, "Reject local echo and unrelated audio")
            XCTAssertEqual(continuity.missingActiveRatio, 0, "Even sub-percent missing speech is a regression")
            if !continuity.passed {
                return "\(scenario.id): matched=\(continuity.matchedWindowRatio), "
                    + "missing=\(continuity.missingActiveRatio), longest=\(continuity.longestMissingSeconds)s"
            }
        }
        return nil
    }
}

func audioE2EOptionalJSON<T: Encodable>(_ value: T?) throws -> Any {
    guard let value else { return NSNull() }
    return try JSONSerialization.jsonObject(with: JSONEncoder().encode(value))
}
