import AVFAudio
import AudioCore
import Codec
import Foundation
import Synchronization
import RTC
import SessionManager
import XCTest
@testable import RideIntercom

struct LiveSettingsAudioResult {
    let windows: [SwitchStageWindow]
    let recordings: SwitchRecordings
    let failures: [String]
    let rejected: [(start: Double, end: Double)]
    let drops: Int
    let resets: Int
    let encodingFailures: Int
}

struct LiveSettingsProbes {
    let native: RenderedAudioProbe
    let decoded: RenderedAudioProbe
    let mixed: RenderedAudioProbe
}

private final class LiveSettingsProcessing: Sendable {
    let failures = Mutex<[String]>([])
    let rejectedReceives = Mutex<[(start: Double, end: Double)]>([])
}

@MainActor
final class LiveSettingsAudioCapture {
    private let engine: AVAudioEngine
    private let output: SystemAudioOutputStreamBackend
    private let pipeline: AppAudioPipeline
    private let processing: LiveSettingsProcessing
    private let delivery: AudioFrameDelivery
    let input: SpeechFileInput
    let probes: LiveSettingsProbes

    init() throws {
        let probe = RenderedAudioProbe()
        engine = AVAudioEngine()
        probes = LiveSettingsProbes(native: probe, decoded: RenderedAudioProbe(), mixed: RenderedAudioProbe())
        input = makeSettingsInput(engine: engine)
        try input.updateVoiceProcessing(.init(soundIsolationEnabled: false, otherAudioDuckingEnabled: true))
        output = SystemAudioOutputStreamBackend(engine: engine)
        try engine.mainMixerNode.installAudioTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, time in
            probe.append(buffer, time: time)
        }
        pipeline = AppAudioPipeline(makeEngine: { [engine] in engine }, usesHardwareClock: true)
        processing = LiveSettingsProcessing()
        delivery = AudioFrameDelivery(initiallyActive: false) { _ in }
    }

    func tearDown() {
        try? input.stopCapture()
        delivery.finish()
        pipeline.stop()
        pipeline.onTransmitPacket = nil
        engine.mainMixerNode.removeTap(onBus: 0)
        try? output.stopRendering()
    }

    func start() throws {
        let decodedProbe = probes.decoded
        let mixedProbe = probes.mixed
        pipeline.onTransmitPacket = { [weak pipeline, processing] packet in
            guard let pipeline else { return }
            let start = ProcessInfo.processInfo.systemUptime
            do {
                decodedProbe.append(
                    try pipeline.processReceivedAudioPacket(.init(peerID: .init(rawValue: "peer"), packet: packet))
                )
            } catch AppAudioPipelineError.notConfigured {
                processing.rejectedReceives.withLock { $0.append((start, ProcessInfo.processInfo.systemUptime)) }
            } catch { processing.failures.withLock { $0.append(String(describing: error)) } }
        }
        pipeline.onOutputFrame = { mixedProbe.append($0) }
        let onFrame: (PCMFrame) -> Void = { [delivery, pipeline, processing] frame in
            guard delivery.isActive else { return }
            do { try pipeline.processCapturedFrame(frame) } catch {
                processing.failures.withLock { $0.append(String(describing: error)) }
            }
            delivery.yield(frame)
        }
        _ = try input.startCapture(configuration: .intercom(voiceProcessing: .init()), onFrame: onFrame)
        let hardware = try output.startRendering(configuration: .intercomCall)
        try pipeline.rebuild(configuration: .init(outputHardwareFormat: hardware, preferredCodec: .pcm16,
            transmitSoundIsolationEnabled: false, maximumBufferedDuration: 0.2,
            receiveMaximumBufferedDuration: 0.12, receivePlayoutDelay: 0.002), peerIDs: ["peer"])
        delivery.activate()
    }

    func record(intervalMilliseconds: Int, acceptance: Bool) async throws -> LiveSettingsAudioResult {
        try await Task.sleep(for: .seconds(1))
        probes.native.reset()
        probes.decoded.reset()
        probes.mixed.reset()
        var boundaries: [SwitchProbeIndices] = []
        var changeHostTimes: [Double] = []
        var changeDurations: [Double] = []
        let stages = LiveSettingsStage.sequence
        for stage in stages {
            boundaries.append(.init(output: probes.native.sampleCount,
                                    decoded: acceptance ? 0 : probes.decoded.sampleCount,
                                    mixed: acceptance ? 0 : probes.mixed.sampleCount))
            let changeStart = ProcessInfo.processInfo.systemUptime
            changeHostTimes.append(changeStart)
            try stage.operation.apply(to: pipeline)
            changeDurations.append(ProcessInfo.processInfo.systemUptime - changeStart)
            try await Task.sleep(for: .milliseconds(intervalMilliseconds))
        }
        let failures = processing.failures.withLock { $0 }
        let rejected = processing.rejectedReceives.withLock { $0 }
        let recorded = probes.native.snapshot()
        let drops = input.droppedCaptureFrameCount + delivery.droppedFrameCount + pipeline.droppedRenderFrameCount
        let resets = output.playbackResetCount ?? 0
        let encodingFailures = pipeline.transmitEncodingFailureCount
        try input.stopCapture()
        delivery.finish()
        pipeline.stop()
        try output.stopRendering()
        let decoded = probes.decoded.snapshot(), mixed = probes.mixed.snapshot()
        boundaries.append(.init(output: recorded.samples.count, decoded: decoded.samples.count,
                                mixed: mixed.samples.count))
        let windows = stages.enumerated().map { index, stage in
            SwitchStageWindow(name: stage.name, time: changeHostTimes[index], duration: changeDurations[index],
                              start: boundaries[index], end: boundaries[index + 1])
        }
        return LiveSettingsAudioResult(
            windows: windows, recordings: SwitchRecordings(final: recorded, decoded: decoded, mixed: mixed),
            failures: failures, rejected: rejected, drops: drops, resets: resets, encodingFailures: encodingFailures
        )
    }
}

@MainActor
func makeSettingsInput(engine: AVAudioEngine) -> SpeechFileInput {
    let samples = (0..<48000).map { Float(0.15 * sin(Double($0) * 2 * .pi * 600 / 48000)) }
    return SpeechFileInput(samples: samples, engine: engine)
}

private struct LiveSettingsStage {
    let name: String
    let operation: Operation

    static let sequence: [Self] = [
        .init(name: "PCM", operation: .unchanged),
        .init(name: "isolation-on", operation: .isolation(transmit: true, receiveMix: false, peers: [:])),
        .init(name: "Opus", operation: .encoding(.opus, format: .init(), aacBitRate: 64000, opusBitRate: 48000)),
        .init(name: "AAC-48k", operation: .encoding(
            .mpeg4AACELD, format: .init(), aacBitRate: 64000, opusBitRate: 48000
        )),
        .init(name: "AAC-16k", operation: .encoding(
            .mpeg4AACELD, format: .init(sampleRate: 16000, channelCount: 1), aacBitRate: 48000, opusBitRate: 48000
        )),
        .init(name: "AAC-24k", operation: .encoding(
            .mpeg4AACELD, format: .init(sampleRate: 24000, channelCount: 1), aacBitRate: 32000, opusBitRate: 48000
        )),
        .init(name: "AAC-48k-high", operation: .encoding(
            .mpeg4AACELD, format: .init(), aacBitRate: 64000, opusBitRate: 48000
        )),
        .init(name: "isolation-off", operation: .isolation(transmit: false, receiveMix: false, peers: [:])),
        .init(name: "receive-master-on", operation: .isolation(transmit: false, receiveMix: true, peers: [:])),
        .init(name: "receive-master-off", operation: .isolation(transmit: false, receiveMix: false, peers: [:])),
        .init(
            name: "receive-peer-on", operation: .isolation(transmit: false, receiveMix: false, peers: ["peer": true])
        ),
        .init(name: "receive-peer-off", operation: .isolation(transmit: false, receiveMix: false, peers: [:])),
        .init(name: "isolation-on-again", operation: .isolation(transmit: true, receiveMix: false, peers: [:])),
        .init(name: "isolation-off-again", operation: .isolation(transmit: false, receiveMix: false, peers: [:]))
    ]

    enum Operation {
        case unchanged
        case isolation(transmit: Bool, receiveMix: Bool, peers: [String: Bool])
        case encoding(RTCAudioCodecIdentifier, format: AudioFormat, aacBitRate: Int, opusBitRate: Int)

        @MainActor
        func apply(to pipeline: AppAudioPipeline) throws {
            switch self {
            case .unchanged:
                break
            case .isolation(let transmit, let receiveMix, let peers):
                try pipeline.updateSoundIsolation(transmit: transmit, receiveMaster: receiveMix, peers: peers)
            case .encoding(let codec, let format, let aacBitRate, let opusBitRate):
                try pipeline.updateEncoding(preferred: codec, format: format,
                                            aacELDv2BitRate: aacBitRate, opusBitRate: opusBitRate)
            }
        }
    }
}
