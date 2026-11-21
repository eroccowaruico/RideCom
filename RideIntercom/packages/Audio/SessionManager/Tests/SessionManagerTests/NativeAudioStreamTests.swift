import AudioCore
import Testing

@testable import SessionManager

#if canImport(AVFAudio)
import AVFAudio
import XCTest

@Test func pcmBufferPreservesInterleavedChannelsAndRejectsUnsupportedHardware() throws {
    let stereo = try #require(
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48000, channels: 2, interleaved: true))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: stereo, frameCapacity: 2))
    buffer.frameLength = 2
    let samples = try #require(buffer.floatChannelData)[0]
    for (index, value) in [Float(0.1), 0.2, 0.3, 0.4].enumerated() { samples[index] = value }
    #expect(PCMFrame(buffer: buffer, sequenceNumber: 0, capturedAt: 0)?.samples == [0.1, 0.2, 0.3, 0.4])
    let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_A))
    let surround = AVAudioFormat(standardFormatWithSampleRate: 48000, channelLayout: layout)
    let unsupported = try #require(AVAudioPCMBuffer(pcmFormat: surround, frameCapacity: 1))
    unsupported.frameLength = 1
    #expect(PCMFrame(buffer: unsupported, sequenceNumber: 0, capturedAt: 0) == nil)
}

@Test func outputPCMConversionPreservesClockAcrossBlockPartitions() throws {
    let source = AudioFormat(sampleRate: 44_100, channelCount: 1)
    let hardware = AudioFormat(sampleRate: 48_000, channelCount: 2)
    let samples = (0..<4410).map { Float(sin(Double($0) * 0.04) * 0.2) }
    func render(blocks: [Int]) throws -> [PCMFrame] {
        let backend = FakeOutputStreamBackend(actualHardwareFormat: hardware)
        let renderer = AudioOutputStreamRenderer(backend: backend)
        #expect(renderer.start().result == .applied)
        var position = 0
        var index = 0
        while position < samples.count {
            let count = min(blocks[index % blocks.count], samples.count - position)
            let report = renderer.schedule(
                .init(
                    sequenceNumber: UInt64(index), format: source,
                    capturedAt: 10 + Double(position) / source.sampleRate,
                    samples: Array(samples[position..<(position + count)])))
            try #require(report.result == .applied)
            position += count
            index += 1
        }
        return backend.scheduledFrames
    }
    let whole = try render(blocks: [4410])
    let split = try render(blocks: [1, 17, 128, 511, 37])
    let expected = whole.flatMap(\.samples)
    let actual = split.flatMap(\.samples)
    #expect(abs(actual.count - expected.count) <= hardware.channelCount)
    #expect(abs(actual.count / hardware.channelCount - 4800) < 128)
    #expect(zip(actual, expected).allSatisfy { abs($0 - $1) < 0.00001 })
    var emitted = 0
    for frame in split {
        #expect(frame.format == hardware)
        #expect(abs(frame.capturedAt - (10 + Double(emitted) / hardware.sampleRate)) < 1e-9)
        emitted += frame.frameCount
    }
}

@Test func outputPCMConversionDiscardsHistoryOnStopAndFormatChange() throws {
    let hardware = AudioFormat(sampleRate: 48_000, channelCount: 1)
    let backend = FakeOutputStreamBackend(actualHardwareFormat: hardware)
    let renderer = AudioOutputStreamRenderer(backend: backend)
    #expect(renderer.start().result == .applied)
    func frame(rate: Double, value: Float, time: Double) -> PCMFrame {
        .init(
            sequenceNumber: 0, format: .init(sampleRate: rate, channelCount: 1),
            capturedAt: time, samples: Array(repeating: value, count: 600))
    }
    #expect(renderer.schedule(frame(rate: 44_100, value: 0.2, time: 10)).result == .applied)
    #expect(renderer.stop().result == .applied)
    #expect(renderer.start().result == .applied)
    let afterRestart = backend.scheduledFrames.count
    #expect(renderer.schedule(frame(rate: 44_100, value: 0, time: 10 + 600.0 / 44_100)).result == .applied)
    #expect(backend.scheduledFrames.dropFirst(afterRestart).flatMap(\.samples).allSatisfy { $0 == 0 })
    #expect(renderer.schedule(frame(rate: 44_100, value: 0.2, time: 20)).result == .applied)
    let afterChange = backend.scheduledFrames.count
    #expect(renderer.schedule(frame(rate: 32_000, value: 0, time: 20 + 600.0 / 44_100)).result == .applied)
    #expect(backend.scheduledFrames.dropFirst(afterChange).flatMap(\.samples).allSatisfy { $0 == 0 })
}

@Test func outputPCMConversionKeepsTheNativePlaybackBudget() throws {
    let engine = AVAudioEngine()
    let hardware = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    try engine.enableManualRenderingMode(.offline, format: hardware, maximumFrameCount: 4800)
    let renderer = AudioOutputStreamRenderer(configuration: .init(maximumBufferedDuration: 0.1), engine: engine)
    try #require(renderer.start().result == .applied)
    defer { _ = renderer.stop() }
    for index in 0..<3 {
        let report = renderer.schedule(
            .init(
                sequenceNumber: UInt64(index),
                format: .init(sampleRate: 44_100, channelCount: 1), capturedAt: Double(index) * 0.08,
                samples: Array(repeating: 0.2, count: 3528)))
        #expect(report.result == .applied)
    }
    let oversized = renderer.schedule(
        .init(
            sequenceNumber: 3,
            format: .init(sampleRate: 44_100, channelCount: 1), capturedAt: 0.24,
            samples: Array(repeating: 0.2, count: 4411)))
    #expect(oversized.result == .failed(.invalidFrame("Frame exceeds live playback budget")))
    #expect(oversized.snapshot.playbackResetCount == 1)
    #expect((oversized.snapshot.bufferedOutputDuration ?? 1) <= 0.081)
}

@Test func outputGraphUsesTheDeviceClockWithoutAnotherPCMQueue() throws {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 480)
    let renderer = AudioOutputStreamRenderer(engine: engine)
    #expect(renderer.renderingEngine === engine)
    defer { _ = renderer.stop() }
    let source = AVAudioSourceNode(format: format) { _, _, count, list in
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = buffer.mData else { return kAudio_ParamError }
            data.assumingMemoryBound(to: Float.self).update(repeating: 0.2, count: Int(count))
        }
        return noErr
    }
    engine.attach(source)
    try engine.connectNode(source, to: engine.mainMixerNode, format: format)
    #expect(renderer.start().result == .applied)
    let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
    let samples = try #require(output.floatChannelData)[0]
    #expect(try engine.renderOffline(480, to: output) == .success)
    #expect((0..<480).allSatisfy { abs(samples[$0] - 0.2) < 0.001 })
    #expect(AudioOutputStreamRenderer(backend: FakeOutputStreamBackend()).renderingEngine == nil)
}

@Test func liveOutputReleasesAccumulatedSilenceButPreservesUnplayedVoice() throws {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
    let backend = SystemAudioOutputStreamBackend(engine: engine)
    let hardware = try backend.startRendering(configuration: .init(maximumBufferedDuration: 0.2))
    defer { try? backend.stopRendering() }
    let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
    let samples = try #require(output.floatChannelData)[0]
    try backend.schedule(
        .init(
            sequenceNumber: 0, format: hardware,
            samples: Array(repeating: 0.2, count: 960)))
    try backend.schedule(
        .init(
            sequenceNumber: 1, format: hardware,
            samples: Array(repeating: 0, count: 4800)))
    #expect(backend.playbackResetCount == 0, "A silent new frame cannot erase queued speech")
    Thread.sleep(forTimeInterval: 0.01)
    #expect(try engine.renderOffline(960, to: output) == .success)
    #expect((0..<960).allSatisfy { abs(samples[$0] - 0.2) < 0.001 })
    try backend.schedule(
        .init(
            sequenceNumber: 2, format: hardware,
            samples: Array(repeating: 0.00001, count: 480)))
    #expect(
        (backend.bufferedOutputDuration ?? 1) <= 0.0101,
        "A temporary 100 ms backlog must not persist through conversation pauses")
    try backend.schedule(
        .init(
            sequenceNumber: 3, format: hardware,
            samples: Array(repeating: 0.4, count: 480)))
    Thread.sleep(forTimeInterval: 0.01)
    #expect(try engine.renderOffline(960, to: output) == .success)
    #expect((480..<960).allSatisfy { abs(samples[$0] - 0.4) < 0.001 })
}

@Test func pcmFrameRoundTripsThroughPCMBuffer() throws {
    let frame = PCMFrame(
        sequenceNumber: 3,
        format: AudioFormat(sampleRate: 16_000, channelCount: 2),
        capturedAt: 20,
        samples: [0.1, -0.1, 0.2, -0.2]
    )

    let buffer = try frame.makePCMBuffer()
    let restored = try #require(
        PCMFrame(
            buffer: buffer,
            sequenceNumber: frame.sequenceNumber,
            capturedAt: frame.capturedAt
        ))

    #expect(restored == frame)
}

@Test func overlappingOutputBatchesPreserveUnplayedTail() throws {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
    let backend = SystemAudioOutputStreamBackend(engine: engine)
    let hardware = try backend.startRendering(configuration: .init(maximumBufferedDuration: 0.1))
    defer { try? backend.stopRendering() }
    let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
    let samples = try #require(output.floatChannelData)[0]
    try backend.schedule(
        .init(
            sequenceNumber: 0, format: hardware,
            samples: Array(repeating: 0.2, count: 4800)))
    Thread.sleep(forTimeInterval: 0.01)
    #expect(try engine.renderOffline(4560, to: output) == .success)
    #expect((0..<4560).allSatisfy { abs(samples[$0] - 0.2) < 0.001 })
    for sequence in 1...10 {
        let value: Float = sequence.isMultiple(of: 2) ? 0.2 : 0.4
        try backend.schedule(
            .init(
                sequenceNumber: UInt64(sequence), format: hardware,
                samples: Array(repeating: value, count: 4800)))
        // Let the player command queue settle without advancing the offline clock.
        Thread.sleep(forTimeInterval: 0.01)
        #expect(try engine.renderOffline(4800, to: output) == .success)
        #expect((0..<240).allSatisfy { abs(samples[$0] - (0.6 - value)) < 0.001 })
        #expect((240..<4800).allSatisfy { abs(samples[$0] - value) < 0.001 })
    }
    #expect(backend.playbackResetCount == 0)
}

@Test func renderedOutputBatchesDoNotCountAsPendingPlayback() throws {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
    let backend = SystemAudioOutputStreamBackend(engine: engine)
    let actual = try backend.startRendering(
        configuration: .init(preferredFormat: .init(), maximumBufferedDuration: 0.1))
    defer { try? backend.stopRendering() }
    let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
    for sequence in 0..<10 {
        try backend.schedule(
            .init(
                sequenceNumber: UInt64(sequence), format: actual,
                samples: Array(repeating: 0.2, count: 4800)))
        #expect(try engine.renderOffline(4800, to: output) == .success)
        #expect((backend.bufferedOutputDuration ?? 1) < 1 / 48000.0)
    }
    #expect(backend.playbackResetCount == 0)
}

@Test func constructingAndStoppingUnusedInputBackendDoesNotOpenHardware() throws {
    let engine = ObservedInputEngine()
    let backend = SystemAudioInputStreamBackend(engine: engine)
    #expect(engine.inputNodeRequests == 0)
    try backend.stopCapture()
    try backend.stopCapture()
    #expect(engine.inputNodeRequests == 0)
    #expect(!engine.isRunning)
}

@Test func explicitDuplexPreparationOpensBothNodesBeforeStarting() throws {
    let engine = ObservedDuplexEngine()
    try AudioDuplexIO.prepare(engine: engine)
    #expect(engine.nodeRequests == ["output", "input"])
    try AudioDuplexIO.prepare(engine: engine)
    #expect(engine.nodeRequests == ["output", "input", "output", "input"])
    #expect(!engine.isRunning)
}

@Test func duplexPreparationRejectsRunningEngine() throws {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 512)
    try engine.start()
    defer { engine.stop() }
    #expect(throws: AudioStreamError.self) { try AudioDuplexIO.prepare(engine: engine) }
}

private final class ObservedDuplexEngine: AVAudioEngine, @unchecked Sendable {
    var nodeRequests: [String] = []
    override var inputNode: AVAudioInputNode {
        nodeRequests.append("input")
        return super.inputNode
    }
    override var outputNode: AVAudioOutputNode {
        nodeRequests.append("output")
        return super.outputNode
    }
}

private final class ObservedInputEngine: AVAudioEngine, @unchecked Sendable {
    var inputNodeRequests = 0
    override var inputNode: AVAudioInputNode {
        inputNodeRequests += 1
        return super.inputNode
    }
}

@Test(arguments: 0..<20) func outputBackendDropsStalledPlaybackAndRetainsNewestAudio(_ iteration: Int) async throws {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
    let backend = SystemAudioOutputStreamBackend(engine: engine)
    let actual = try backend.startRendering(
        configuration: .init(
            preferredFormat: .init(sampleRate: 48000, channelCount: 1), maximumBufferedDuration: 0.1))
    defer { try? backend.stopRendering() }
    for sequence in 0..<6 {
        try backend.schedule(
            .init(
                sequenceNumber: UInt64(sequence), format: actual, capturedAt: 0,
                samples: Array(repeating: sequence == 5 ? Float(0.8) : Float(0.1), count: 960)))
    }
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
    // AVAudioPlayerNode applies interrupts asynchronously at a render boundary.
    // Require fresh audio within 64 ms, and no old backlog after it arrives.
    // Offline rendering can consume all three blocks before the player has run its
    // scheduling callback. Advance at the device rate while measuring the same 3072 samples.
    let clock = ContinuousClock()
    let start = clock.now
    var rendered: [Float] = []
    for block in 0..<3 {
        try await clock.sleep(until: start + .seconds(Double(block * 1024) / actual.sampleRate))
        #expect(try engine.renderOffline(1024, to: buffer) == .success)
        let samples = try #require(buffer.floatChannelData)[0]
        rendered += (0..<Int(buffer.frameLength)).map { abs(samples[$0]) }
    }
    let fresh = try #require(
        rendered.firstIndex { $0 > 0.79 && $0 < 0.81 },
        "Replacement must arrive within 64 ms, iteration \(iteration)")
    #expect(
        !rendered[fresh...].contains { abs($0 - 0.1) < 0.001 },
        "Old backlog must never resume after fresh audio")
    #expect(backend.playbackResetCount == 1)
    #expect(backend.bufferedOutputDuration == 0)
    #expect(throws: (any Error).self) {
        try backend.schedule(
            .init(
                sequenceNumber: 9, format: actual, capturedAt: 0, samples: Array(repeating: 0.2, count: 9600)))
    }
    try backend.schedule(
        .init(sequenceNumber: 10, format: actual, capturedAt: 0, samples: Array(repeating: 0.3, count: 960)))
    try backend.stopRendering()
    #expect(backend.bufferedOutputDuration == 0)
    _ = try backend.startRendering(configuration: .init(preferredFormat: actual, maximumBufferedDuration: 0.1))
    #expect(try engine.renderOffline(1024, to: buffer) == .success)
    let samples = try #require(buffer.floatChannelData)[0]
    #expect((0..<Int(buffer.frameLength)).allSatisfy { abs(samples[$0]) < 0.001 })
}

final class OutputDeviceFormatTests: XCTestCase {
    func testOutputReportsTheRunningDeviceRatherThanTheProvisionalGraphFormat() throws {
        let engine = AVAudioEngine()
        // Meter installation can materialize the mixer's provisional 44.1 kHz
        // graph before the device's final clock is negotiated at engine start.
        try engine.mainMixerNode.installAudioTap(onBus: 0, bufferSize: 1024, format: nil) { _, _ in }
        let player = AVAudioPlayerNode()
        let backend = SystemAudioOutputStreamBackend(engine: engine, playerNode: player)
        defer {
            engine.mainMixerNode.removeTap(onBus: 0)
            try? backend.stopRendering()
        }
        let reported = try backend.startRendering(configuration: .init())
        let device = engine.outputNode.outputFormat(forBus: 0)
        let playback = player.outputFormat(forBus: 0)
        XCTAssertEqual(reported.sampleRate, device.sampleRate)
        // Physical devices can expose more channels than the supported PCM
        // stream. The player connection is the format callers must schedule.
        XCTAssertEqual(reported.channelCount, Int(playback.channelCount))
        XCTAssertEqual(reported.sampleRate, playback.sampleRate)
        XCTAssertEqual(engine.mainMixerNode.outputFormat(forBus: 0).sampleRate, device.sampleRate)
        XCTAssertNoThrow(
            try backend.schedule(
                .init(
                    sequenceNumber: 0, format: reported,
                    samples: Array(repeating: 0, count: 128 * reported.channelCount))))
    }
}
#endif
