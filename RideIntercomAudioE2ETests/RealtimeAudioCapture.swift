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

struct RealtimeAudioWindow {
    let errors: [String]
    let recorded: RenderedAudioProbe.Recording
    let drops: Drops
    let playbackResets: Int
    let playout: ReceivePlayoutDiagnostics?
    let nodeLatencies: [[String: String]]

    struct Drops {
        let capture: Int
        let delivery: Int
        let render: Int
    }
}

// Callbacks retain their measurements independently of the engine and pipeline.
@MainActor
final class RealtimeAudioMeters {
    let transmitted = RenderedAudioProbe()
    let mixed = RenderedAudioProbe()
    nonisolated let inputAges = Mutex<[Double]>([])
    nonisolated let txAges = Mutex<[Double]>([])
    var mixAges: [Double] = []
    nonisolated let errorStore = Mutex<[String]>([])
}

@MainActor
final class RealtimeAudioCapture {
    let engine: AVAudioEngine
    let input: SpeechFileInput
    let output: SystemAudioOutputStreamBackend
    let probe: RenderedAudioProbe
    let pipeline: AppAudioPipeline
    let meters: RealtimeAudioMeters
    private let delivery: AudioFrameDelivery

    init(fixture: String, observePipeline: (AppAudioPipeline) -> Void) throws {
        engine = AVAudioEngine()
        input = try SpeechFileInput(name: fixture, engine: engine)
        probe = RenderedAudioProbe()
        try input.updateVoiceProcessing(.init(soundIsolationEnabled: false, otherAudioDuckingEnabled: true))
        output = SystemAudioOutputStreamBackend(engine: engine)
        let mixer = engine.mainMixerNode
        try mixer.installAudioTap(onBus: 0, bufferSize: 1024, format: nil) { [probe] buffer, time in
            probe.append(buffer, time: time)
        }
        pipeline = AppAudioPipeline(makeEngine: { [engine] in engine }, usesHardwareClock: true)
        observePipeline(pipeline)
        meters = RealtimeAudioMeters()
        delivery = AudioFrameDelivery(initiallyActive: false) { _ in }
    }

    func tearDown() {
        try? input.stopCapture()
        delivery.finish()
        pipeline.stop()
        engine.mainMixerNode.removeTap(onBus: 0)
        try? output.stopRendering()
    }

    func start(codec: RTCAudioCodecIdentifier) throws {
        pipeline.onTransmitPacket = { [weak pipeline, meters] packet in
            guard let pipeline else { return }
            do {
                meters.txAges.withLock { $0.append(ProcessInfo.processInfo.systemUptime - packet.capturedAt) }
                let frame = try pipeline.processReceivedAudioPacket(
                    .init(peerID: .init(rawValue: "loopback"), packet: packet)
                )
                meters.transmitted.append(frame, preservingTimeline: true)
            } catch { meters.errorStore.withLock { $0.append(String(describing: error)) } }
        }
        pipeline.onOutputFrame = { [meters] frame in
            meters.mixed.append(frame)
            meters.mixAges.append(ProcessInfo.processInfo.systemUptime - frame.capturedAt)
        }
        let captureFrame: (PCMFrame) -> Void = { [delivery, pipeline, meters] frame in
            guard delivery.isActive else { return }
            meters.inputAges.withLock { $0.append(ProcessInfo.processInfo.systemUptime - frame.capturedAt) }
            pipeline.processMicrophoneFrame(frame, shouldProcess: { delivery.isActive })
            delivery.yield(frame)
        }
        _ = try input.startCapture(configuration: .intercom(voiceProcessing: .init()), onFrame: captureFrame)
        // Match startAudioPipelineIfNeeded: input, output, then graph.
        // Starting capture after building the graph stops the shared engine
        // and invalidates players that have already prepared their clocks.
        let hardware = try output.startRendering(configuration: .intercomCall)
        try pipeline.rebuild(configuration: .init(outputHardwareFormat: hardware, preferredCodec: codec,
            transmitSoundIsolationEnabled: true, maximumBufferedDuration: 0.2,
            receiveMaximumBufferedDuration: 0.12, receivePlayoutDelay: 0.002), peerIDs: ["loopback"])
        XCTAssertEqual(pipeline.codecRuntimeReport.selectedCodec.rawValue, codec.rawValue)
        XCTAssertFalse(pipeline.codecRuntimeReport.isFallback)
        delivery.activate()
    }

    func recordWindow(fixture: String) async throws -> RealtimeAudioWindow {
        try await Task.sleep(for: .seconds(1))
        probe.reset()
        meters.transmitted.reset()
        meters.mixed.reset()
        meters.inputAges.withLock { $0.removeAll() }
        meters.txAges.withLock { $0.removeAll() }
        meters.mixAges.removeAll()
        try await Task.sleep(for: .seconds(fixture == "speech-ja" ? 8 : 20))
        let errors = meters.errorStore.withLock { $0 }
        let recorded = probe.snapshot()
        let drops = RealtimeAudioWindow.Drops(
            capture: input.droppedCaptureFrameCount, delivery: delivery.droppedFrameCount,
            render: pipeline.droppedRenderFrameCount
        )
        let playbackResets = output.playbackResetCount ?? 0
        let playout = pipeline.receivePlayoutDiagnostics(peerID: "loopback")
        let nodeLatencies = engine.attachedNodes.map { node in
            ["node": String(describing: type(of: node)), "latency": String(node.latency),
             "presentation": String(node.outputPresentationLatency)]
        }
        // End capture/render before offline analysis. Otherwise the analysis
        // itself starves the app actor and contaminates the drop counters.
        try input.stopCapture()
        delivery.finish()
        pipeline.stop()
        try output.stopRendering()
        return RealtimeAudioWindow(
            errors: errors, recorded: recorded, drops: drops, playbackResets: playbackResets,
            playout: playout, nodeLatencies: nodeLatencies
        )
    }
}
