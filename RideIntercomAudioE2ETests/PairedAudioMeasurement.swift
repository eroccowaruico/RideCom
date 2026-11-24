import Foundation
import RTC
import Synchronization
import XCTest
@testable import RideIntercom

struct PairedSpeechExpectation {
    let scenario: String
    let expectsRemoteSpeech: Bool
}

extension AudioE2ETests {
    @MainActor
    func verifyPairedAudio(
        _ pair: AudioE2EPair, trace: PairedAudioTrace, expectation: PairedSpeechExpectation
    ) async throws {
        let viewModel = pair.endpoint.viewModel
        let barrier = pair.barrier
        let probe = pair.endpoint.audio.probe
        let scenario = expectation.scenario
        let movesToBackground = pair.endpoint.run.movesToBackground
        try await waitUntil(
            seconds: 12, description: "Media starts for \(scenario)",
            status: { viewModel.routeLabel },
            condition: {
                viewModel.isCallMediaStarted
            }
        )
        try await barrier.meet("\(scenario)-ready")
        checkBackgroundIfRequested(movesToBackground)
        let udpBefore = localUDPObservation(route: pair.endpoint.run.soleRoute, viewModel: viewModel)
        let decodeBefore = viewModel.audioPipeline.receiveDecodeCounts
        probe.reset()
        trace.reset()
        let start = Date().timeIntervalSince1970
        let firstSent = viewModel.sentVoicePacketCount
        let firstReceived = viewModel.receivedVoicePacketCount
        try await measurePairedSpeechActivity(pair, expectation: expectation)
        let end = Date().timeIntervalSince1970
        let rendered = probe.snapshot()
        let decoded = trace.decoded.snapshot()
        let firstDecodedCaptureTime = trace.decoded.firstOutputTime
        let firstRenderedHostTime = probe.firstOutputTime
        let transmitted = trace.transmitted.withLock { $0 }
        let receivedTrace = trace.received.withLock { $0 }
        let udpAfter = localUDPObservation(route: pair.endpoint.run.soleRoute, viewModel: viewModel)
        let decodeAfter = viewModel.audioPipeline.receiveDecodeCounts
        checkBackgroundIfRequested(movesToBackground)
        let sent = viewModel.sentVoicePacketCount - firstSent
        let received = viewModel.receivedVoicePacketCount - firstReceived
        XCTAssertEqual(viewModel.availableCallRoutes, [pair.endpoint.run.soleRoute])
        XCTAssertEqual(viewModel.authenticatedPeerIDs.count, 1)
        XCTAssertNil(viewModel.audioErrorMessage)
        try await barrier.meet("\(scenario)-measured")
        try await attachPairedMeasurement(
            pair, trace: trace, expectation: expectation,
            sample: PairedAudioSample(
                rendered: rendered, decoded: decoded, firstDecodedCaptureTime: firstDecodedCaptureTime,
                firstRenderedHostTime: firstRenderedHostTime, transmitted: transmitted, receivedTrace: receivedTrace,
                udpBefore: udpBefore, udpAfter: udpAfter,
                decodedPCMPackets: decodeAfter.pcmPackets - decodeBefore.pcmPackets,
                decodeFailures: decodeAfter.failures - decodeBefore.failures, sent: sent, received: received,
                start: start, end: end
            )
        )
    }

    @MainActor
    private func measurePairedSpeechActivity(_ pair: AudioE2EPair, expectation: PairedSpeechExpectation) async throws {
        let viewModel = pair.endpoint.viewModel
        let run = pair.endpoint.run
        let activity = run.mutedWait > 0 ? observePacketActivity(viewModel) : nil
        defer { activity?.cancel() }
        try await Task.sleep(for: .seconds(run.initial.seconds))
        activity?.cancel()
        if let observed = await activity?.value {
            let scenario = expectation.scenario
            XCTAssertEqual(observed.transmit, !viewModel.effectiveInputMuted, "Audio TX indicator in \(scenario)")
            XCTAssertEqual(observed.receive, expectation.expectsRemoteSpeech, "Audio RX indicator in \(scenario)")
        }
    }

    @MainActor
    private func observePacketActivity(
        _ viewModel: IntercomViewModel
    ) -> Task<(transmit: Bool, receive: Bool), Never> {
        Task {
            var transmitted = false
            var received = false
            while !Task.isCancelled {
                let observation = await packetIndicators(viewModel)
                transmitted = transmitted || observation.transmit.state == .passing
                received = received || observation.receive.state == .passing
                try? await Task.sleep(for: .milliseconds(500))
            }
            return (transmitted, received)
        }
    }

    @MainActor
    func verifyQuietPacketIndicators(_ viewModel: IntercomViewModel) async {
        let observation = await packetIndicators(viewModel)
        XCTAssertTrue(observation.transmit.detail.contains("Control Connected"))
        XCTAssertEqual(observation.transmit.state, .waiting)
        XCTAssertEqual(observation.receive.state, .waiting)
    }

    @MainActor
    private func packetIndicators(_ viewModel: IntercomViewModel) async
        -> (transmit: PipelineStep, receive: PipelineStep) {
        let dispatch = await viewModel.callSession.lastOutboundAudioDispatch()
        let input = DiagnosticsInput(viewModel, localDispatch: dispatch)
        return (TransmitPipelinePresentation(input: input).rtcStep,
                ReceivePipelinePresentation(input: input).rtcReceiveStep)
    }

    @MainActor
    private func localUDPObservation(route: RouteKind, viewModel: IntercomViewModel) -> [String: Any]? {
        guard route == .multipeer, let report = viewModel.networkDiagnostics,
              let local = report.routes.first(where: { $0.route == .multipeer }) else { return nil }
        return ["observedAt": report.generatedAt,
                "sentDatagrams": local.statistics.sentMediaDatagrams as Any? ?? NSNull(),
                "receivedDatagrams": local.statistics.receivedMediaDatagrams as Any? ?? NSNull(),
                "routeEventDrops": local.eventDrops["route"].map { $0.overflow + $0.expired } as Any? ?? NSNull(),
                "sessionEventDrops": report.eventDrops.overflow + report.eventDrops.expired]
    }

    @MainActor
    private func attachPairedMeasurement(
        _ pair: AudioE2EPair, trace: PairedAudioTrace, expectation: PairedSpeechExpectation, sample: PairedAudioSample
    ) async throws {
        let seconds = pair.endpoint.run.initial.seconds
        let local = pair.endpoint.audio.input.samples
        let remote = pair.endpoint.audio.remote.samples
        let role = pair.endpoint.run.role
        let transport = pair.endpoint.run.transport
        let scenario = expectation.scenario
        let movesToBackground = pair.endpoint.run.movesToBackground
        let expectsRemoteSpeech = expectation.expectsRemoteSpeech
        let rendered = sample.rendered
        let decoded = sample.decoded
        let received = sample.received
        let (remoteMatch, localMatch, continuity, decodedContinuity) = await Task.detached {
            (RenderedAudioProbe.speechMatch(reference: remote, referenceRate: 48000,
                output: rendered.samples, outputRate: rendered.rate),
             RenderedAudioProbe.speechMatch(reference: local, referenceRate: 48000,
                output: rendered.samples, outputRate: rendered.rate),
             expectsRemoteSpeech ? SpeechContinuity.measure(reference: remote, referenceRate: 48000,
                 output: rendered.samples, outputRate: rendered.rate) : nil,
             expectsRemoteSpeech ? SpeechContinuity.measure(reference: remote, referenceRate: 48000,
                 output: decoded.samples, outputRate: decoded.rate) : nil)
        }.value
        XCTAssertEqual(rendered.invalid, 0)
        XCTAssertGreaterThan(rendered.samples.count, Int(rendered.rate * seconds * 0.8))
        if expectsRemoteSpeech {
            XCTAssertGreaterThan(received, 20)
            XCTAssertGreaterThan(remoteMatch, 0.45, "The matched output must include remote speech for \(scenario)")
            XCTAssertGreaterThan(
                remoteMatch, localMatch + 0.10, "The local fixture cannot satisfy the remote speech oracle"
            )
        } else {
            XCTAssertEqual(received, 0, "The listening endpoint must stay muted")
            XCTAssertLessThan(rendered.samples.reduce(Float(0)) { max($0, abs($1)) }, 0.001)
        }
        let evidence: [String: Any] = ["scenario": scenario, "role": role, "transport": transport,
            "background": movesToBackground, "expectsRemoteSpeech": expectsRemoteSpeech,
            "measurementStartedAt": sample.start, "measurementEndedAt": sample.end,
            "localUDPBefore": sample.udpBefore as Any? ?? NSNull(),
            "localUDPAfter": sample.udpAfter as Any? ?? NSNull(),
            "sentVoicePackets": sample.sent, "decodedPCMPackets": sample.decodedPCMPackets,
            "decodeFailures": sample.decodeFailures,
            "continuity": try audioE2EOptionalJSON(continuity),
            "decodedContinuity": try audioE2EOptionalJSON(decodedContinuity),
            "decodedInvalidSamples": decoded.invalid,
            "firstDecodedCaptureTime": sample.firstDecodedCaptureTime as Any? ?? NSNull(),
            "firstOutputHostTime": sample.firstRenderedHostTime as Any? ?? NSNull(),
            "received": received, "remoteMatch": remoteMatch, "localMatch": localMatch,
            "renderedSamples": rendered.samples.count, "renderedRate": rendered.rate]
        try await attachPairedRecordings(pair, trace: trace, scenario: scenario, sample: sample, evidence: evidence)
    }

    @MainActor
    private func attachPairedRecordings(
        _ pair: AudioE2EPair, trace: PairedAudioTrace, scenario: String,
        sample: PairedAudioSample, evidence: [String: Any]
    ) async throws {
        let directory = pair.endpoint.directory
        let probe = pair.endpoint.audio.probe
        let role = pair.endpoint.run.role
        let rendered = sample.rendered
        let decoded = sample.decoded
        let transmitted = sample.transmitted
        let receivedTrace = sample.receivedTrace
        try addAudioE2EJSONAttachment(evidence, name: "endpoint-\(role)-\(scenario)-measurement")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let wav = directory.appendingPathComponent("\(scenario)-\(role).wav")
        try await Task.detached { try probe.writeWAV(to: wav, rendered: rendered) }.value
        let recording = XCTAttachment(contentsOfFile: wav)
        recording.name = "endpoint-\(role)-\(scenario)-speech"
        recording.lifetime = .keepAlways
        add(recording)
        let traceData = try await Task.detached {
            try JSONEncoder().encode(PacketTimingTrace(transmitted: transmitted, received: receivedTrace))
        }.value
        let timing = XCTAttachment(data: traceData, uniformTypeIdentifier: "public.json")
        timing.name = "endpoint-\(role)-\(scenario)-packet-timing"
        timing.lifetime = .keepAlways
        add(timing)
        if !decoded.samples.isEmpty {
            let url = directory.appendingPathComponent("\(scenario)-\(role)-decoded.wav")
            try await Task.detached { try trace.decoded.writeWAV(to: url, rendered: decoded) }.value
            let recording = XCTAttachment(contentsOfFile: url)
            recording.name = "endpoint-\(role)-\(scenario)-decoded"
            recording.lifetime = .keepAlways
            add(recording)
        }
    }
}

private struct PairedAudioSample {
    let rendered: RenderedAudioProbe.Recording
    let decoded: RenderedAudioProbe.Recording
    let firstDecodedCaptureTime: Double?
    let firstRenderedHostTime: Double?
    let transmitted: [PacketTiming]
    let receivedTrace: [PacketTiming]
    let udpBefore: [String: Any]?
    let udpAfter: [String: Any]?
    let decodedPCMPackets: Int
    let decodeFailures: Int
    let sent: Int
    let received: Int
    let start: Double
    let end: Double
}
