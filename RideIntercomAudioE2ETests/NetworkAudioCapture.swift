import AVFAudio
import AudioCore
import AudioMixer
import Foundation
import RTC
import SessionManager
import Synchronization
import XCTest
@testable import RideIntercom

struct PacketTiming: Encodable {
    let sequence: UInt64
    let capture: Double
    let host = ProcessInfo.processInfo.systemUptime
    let duration: Double
    let captureToSendQueue: Double?
    var handled: Double?
    var buffered: Double?
    var adjustments: Int?
    var resets: Int?
    var playoutAdjustment: MixerPlayoutAdjustment?
    var receiveProcessing: ReceiveProcessingTiming?
    var playoutReservation: MixerPlayoutReservation?

    init(_ packet: RTCAudioPacket) {
        sequence = packet.sequenceNumber
        capture = packet.capturedAt
        duration = Double(packet.sampleCount ?? 0) / Double(packet.format.channelCount) / packet.format.sampleRate
        captureToSendQueue = packet.captureToSendQueue
    }
}

struct PacketTimingTrace: Encodable {
    var traceForScenario: String?
    let transmitted: [PacketTiming]
    let received: [PacketTiming]
    var startupTransmitted: [PacketTiming]?
    var startupReceived: [PacketTiming]?
    var startupInputDelivery: [SpeechFileInput.DeliveryTiming]?
    var startupFirstDecodedCaptureTime: Double?
    var startupRenderClock: [RenderedAudioProbe.RenderClockBlock]?
    var steadyFirstDecodedCaptureTime: Double?
    var steadyRenderClock: [RenderedAudioProbe.RenderClockBlock]?
    var output: [[String: Double]]?
}

func tracedAudioReception(
    pipeline: AppAudioPipeline,
    observe: @escaping @Sendable (PCMFrame, PacketTiming) -> Void,
    onFailure: @escaping @Sendable () -> Void = {}
) -> @Sendable (RTC.ReceivedAudioPacket) -> AudioPacketReception {
    { received in
        var entry = PacketTiming(received.packet)
        do {
            let frame = try pipeline.processReceivedAudioPacket(received) { playout in
                entry.buffered = playout.bufferedDuration
                entry.adjustments = playout.adjustments
                entry.resets = playout.resets
                entry.playoutAdjustment = playout.adjustment
                entry.receiveProcessing = playout.processingTiming
                entry.playoutReservation = playout.reservation
            }
            entry.handled = ProcessInfo.processInfo.systemUptime
            observe(frame, entry)
            return .processed(level: (try? AudioSignalMeter.measure(frame).rms) ?? 0)
        } catch {
            let failure = AudioPacketReception.failure(error)
            if failure != .unavailable { onFailure() }
            return failure
        }
    }
}

final class PairedAudioTrace: Sendable {
    let decoded = RenderedAudioProbe()
    let transmitted = Mutex<[PacketTiming]>([])
    let received = Mutex<[PacketTiming]>([])

    func reset() {
        decoded.reset()
        transmitted.withLock { $0.removeAll(keepingCapacity: true) }
        received.withLock { $0.removeAll(keepingCapacity: true) }
    }
}

final class NetworkAudioTrace: Sendable {
    let transmittedTiming = Mutex<[PacketTiming]>([])
    let receivedTiming = Mutex<[PacketTiming]>([])
    let decodeFailures = Mutex(0)
    private let pipeline: AppAudioPipeline
    private let decodedProbe: RenderedAudioProbe

    init(pipeline: AppAudioPipeline, decodedProbe: RenderedAudioProbe) {
        self.pipeline = pipeline
        self.decodedProbe = decodedProbe
    }

    func beginWindow(keepStartupTrace: Bool) -> (transmitted: [PacketTiming]?, received: [PacketTiming]?) {
        func takeStartupRecords(_ records: inout [PacketTiming]) -> [PacketTiming]? {
            defer { records.removeAll(keepingCapacity: true) }
            return keepStartupTrace ? records : nil
        }
        return (transmittedTiming.withLock { takeStartupRecords(&$0) },
                receivedTiming.withLock { takeStartupRecords(&$0) })
    }

    func transmitObserver(
        forwarding sink: (@Sendable (RTCAudioPacket) -> Void)?
    ) -> @Sendable (RTCAudioPacket) -> Void {
        { [self] packet in
            transmittedTiming.withLock { $0.append(PacketTiming(packet)) }
            sink?(packet)
        }
    }

    // Observe the same decoder and reservation used for playback. Starting
    // a second decoder would introduce a different priming history.
    var process: @Sendable (RTC.ReceivedAudioPacket) -> AudioPacketReception {
        tracedAudioReception(pipeline: pipeline, observe: { [self] frame, entry in
            receivedTiming.withLock { $0.append(entry) }
            decodedProbe.append(frame, preservingTimeline: true)
        }, onFailure: { [self] in
            decodeFailures.withLock { $0 += 1 }
        })
    }
}

struct NetworkAudioWindow {
    let startupDecoded: RenderedAudioProbe.Recording?
    let startupOutput: RenderedAudioProbe.TimedRecording?
    let startupFirstDecoded: Double?
    let startupSentTrace: [PacketTiming]?
    let startupReceivedTrace: [PacketTiming]?
    let startupInputDelivery: [SpeechFileInput.DeliveryTiming]?
    let steadyOutput: RenderedAudioProbe.TimedRecording
    let firstCapture: Double?
    let steadyFirstDecoded: Double?
    let dropped: [String: Int]
    let sentTrace: [PacketTiming]
    let receivedTrace: [PacketTiming]
    let renderedTrace: [[String: Double]]
    let failuresBefore: Int
    let before: NetworkAudioCounts

    var rendered: RenderedAudioProbe.Recording { steadyOutput.audio }
    var firstOutput: Double? { steadyOutput.firstHostTime }

    func verifyStartupClock() throws {
        let nativeClockObservations = receivedTrace.filter { $0.playoutReservation?.renderAnchorHostTime != nil }
        XCTAssertGreaterThan(
            nativeClockObservations.count, 20, "Collect native render clock positions for received packets"
        )
        XCTAssertFalse(startupSentTrace?.isEmpty ?? true, "Record sent packets before steady playback")
        let input = try XCTUnwrap(startupInputDelivery)
        XCTAssertFalse(input.isEmpty, "Record native input delivery before steady playback")
        XCTAssertTrue(input.allSatisfy { $0.callback <= $0.handedOff && $0.handedOff <= $0.returned })
        XCTAssertTrue(startupReceivedTrace?.contains { $0.playoutReservation?.anchorLead != nil } == true,
                      "Record what set the playout delay before the steady-state sample")
        XCTAssertNotNil(startupFirstDecoded)
        XCTAssertFalse(
            startupOutput?.blocks?.isEmpty ?? true, "Record the native render clock before the steady-state sample"
        )
        XCTAssertNotNil(steadyFirstDecoded)
    }

    func verifySteadyRenderClock() throws {
        let blocks = try XCTUnwrap(steadyOutput.blocks)
        XCTAssertGreaterThan(blocks.count, 20, "Record the native render clock during steady-state speech")
        XCTAssertEqual(blocks.first?.startSample, 0)
        XCTAssertEqual(blocks.first?.hostTime, firstOutput)
        XCTAssertTrue(zip(blocks, blocks.dropFirst()).allSatisfy { previous, next in
            previous.startSample + previous.frameCount == next.startSample && previous.hostTime < next.hostTime
        }, "Give every sample in the steady-state WAV a render block")
        XCTAssertEqual(blocks.last.map { $0.startSample + $0.frameCount }, rendered.samples.count)
    }

    func packetTrace(scenarioID: String) -> PacketTimingTrace {
        PacketTimingTrace(
            traceForScenario: scenarioID, transmitted: sentTrace, received: receivedTrace,
            startupTransmitted: startupSentTrace, startupReceived: startupReceivedTrace,
            startupInputDelivery: startupInputDelivery,
            startupFirstDecodedCaptureTime: startupFirstDecoded, startupRenderClock: startupOutput?.blocks,
            steadyFirstDecodedCaptureTime: steadyFirstDecoded,
            steadyRenderClock: steadyOutput.blocks, output: renderedTrace
        )
    }
}

extension AudioE2ETests {
    @MainActor
    func captureNetworkAudio(
        _ scenario: AudioE2EScenario, endpoint: AudioE2EEndpoint, trace: NetworkAudioTrace
    ) async throws -> NetworkAudioWindow {
        let viewModel = endpoint.viewModel
        let audio = endpoint.audio
        let recordsStartup = endpoint.run.recordsStartupAudio && scenario.id == endpoint.run.initial.id
        let startupDecoded = recordsStartup ? audio.decodedProbe.snapshot() : nil
        let startupOutput = recordsStartup ? audio.probe.finishTimedRecording() : nil
        let startupFirstDecoded = recordsStartup ? audio.decodedProbe.firstOutputTime : nil
        let startupInputDelivery = recordsStartup ? audio.input.finishStartupDelivery() : nil
        audio.probe.reset(recordsRenderClock: true)
        let originalTransmit = viewModel.audioPipeline.onTransmitPacket
        let originalOutput = viewModel.audioPipeline.onOutputFrame
        audio.mixedProbe.reset()
        audio.decodedProbe.reset()
        let startup = trace.beginWindow(keepStartupTrace: recordsStartup)
        let failuresBefore = trace.decodeFailures.withLock { $0 }
        var outputTiming: [[String: Double]] = []
        viewModel.audioPipeline.onOutputFrame = { frame in
            audio.mixedProbe.append(frame)
            outputTiming.append(["capture": frame.capturedAt, "host": ProcessInfo.processInfo.systemUptime,
                "duration": Double(frame.frameCount) / frame.format.sampleRate,
                "queued": audio.output.bufferedOutputDuration ?? 0])
            originalOutput?(frame)
        }
        if !endpoint.run.recordsStartupAudio {
            viewModel.audioPipeline.onTransmitPacket = trace.transmitObserver(forwarding: originalTransmit)
        }
        defer {
            if !endpoint.run.recordsStartupAudio { viewModel.audioPipeline.onTransmitPacket = originalTransmit }
            viewModel.audioPipeline.onOutputFrame = originalOutput
        }
        let dropsBefore = endpoint.dropCounts()
        let before = NetworkAudioCounts(
            transmitted: viewModel.sentVoicePacketCount, received: viewModel.receivedVoicePacketCount,
            outputBatches: observedOutputBatches(viewModel), playbackResets: audio.output.playbackResetCount ?? 0
        )
        try await observeNetworkPlayback(scenario, endpoint: endpoint)
        let steadyOutput = audio.probe.finishTimedRecording()
        let steadyFirstDecoded = audio.decodedProbe.firstOutputTime
        let drops = endpoint.dropCounts().map { ($0.key, $0.value - (dropsBefore[$0.key] ?? 0)) }
        return NetworkAudioWindow(
            startupDecoded: startupDecoded, startupOutput: startupOutput, startupFirstDecoded: startupFirstDecoded,
            startupSentTrace: startup.transmitted, startupReceivedTrace: startup.received,
            startupInputDelivery: startupInputDelivery,
            steadyOutput: steadyOutput, firstCapture: audio.input.firstCaptureTime,
            steadyFirstDecoded: steadyFirstDecoded,
            dropped: Dictionary(uniqueKeysWithValues: drops),
            sentTrace: trace.transmittedTiming.withLock { $0 }, receivedTrace: trace.receivedTiming.withLock { $0 },
            renderedTrace: outputTiming, failuresBefore: failuresBefore, before: before
        )
    }

    @MainActor
    private func observeNetworkPlayback(_ scenario: AudioE2EScenario, endpoint: AudioE2EEndpoint) async throws {
        let viewModel = endpoint.viewModel
        let transport = endpoint.run.transport
        let waitsForInternet = endpoint.run.waitsForInternet
        let waitingWorker = endpoint.pendingInternetWorker
        let start = ContinuousClock.now
        if let waitingWorker {
            let peers = await waitingWorker.pendingICEPeers.count
            XCTAssertEqual(peers, 2, "Both Internet connection requests must be unanswered when measuring Local audio")
        }
        let continuationWorker = endpoint.run.checksCredentialContinuation ? endpoint.worker.fixture : nil
        var receivedAtExpiry: Int?
        if let continuationWorker {
            let receivedAtStart = viewModel.receivedVoicePacketCount
            try await Task.sleep(until: start + .seconds(2), clock: .continuous)
            let received = viewModel.receivedVoicePacketCount
            XCTAssertGreaterThan(received, receivedAtStart)
            receivedAtExpiry = received
            try await continuationWorker.expireCredential(for: endpoint.run.memberID)
        }
        while start.duration(to: .now) < .seconds(scenario.seconds) {
            XCTAssertTrue(viewModel.isAudioReady, "\(scenario.id): \(endpoint.status())")
            XCTAssertEqual(viewModel.authenticatedPeerIDs.count, 1, endpoint.status())
            XCTAssertNil(viewModel.audioErrorMessage, endpoint.status())
            try await Task.sleep(for: .milliseconds(100))
        }
        if let continuationWorker, let receivedAtExpiry {
            let requests = await continuationWorker.measurements()["requests"] as? [String: Int]
            XCTAssertGreaterThan(requests?["expired-credential-pull"] ?? 0, 0)
            XCTAssertGreaterThan(requests?["continued-renewal"] ?? 0, 0)
            XCTAssertEqual(requests?["join"], 2, "Both original media sessions must stay connected")
            XCTAssertGreaterThan(viewModel.receivedVoicePacketCount, receivedAtExpiry)
        }
        if waitsForInternet {
            XCTAssertEqual(viewModel.availableCallRoutes, [.multipeer])
            if let waitingWorker {
                let peers = await waitingWorker.pendingICEPeers.count
                XCTAssertEqual(peers, 2, "Both Internet requests must still be pending after Local playback")
                print("Audio E2E: Measured Local output while \(peers) Internet requests were unanswered")
            }
        }
        if transport == "local", !scenario.expectsSilence {
            let statistics = viewModel.networkDiagnostics?.routes.first { $0.route == .multipeer }?.statistics
            XCTAssertGreaterThan(statistics?.sentMediaDatagrams ?? 0, 0, "Local audio must use the UDP media path")
            XCTAssertGreaterThan(statistics?.receivedMediaDatagrams ?? 0, 0, "Local audio must arrive over UDP")
        }
    }
}

extension AudioE2EEndpoint {
    var pendingInternetWorker: AudioE2EWorker? { run.waitsForInternet ? worker.fixture : nil }

    func dropCounts() -> [String: Int] {
        ["capture": audio.input.droppedCaptureFrameCount,
         "delivery": viewModel.inputFrameDelivery?.droppedFrameCount ?? 0,
         "render": viewModel.audioPipeline.droppedRenderFrameCount,
         "sender": (viewModel.callSession as? RideIntercomCallSessionAdapter)?.droppedAudioPacketCount ?? 0]
    }
}
