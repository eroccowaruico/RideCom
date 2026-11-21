import AudioCore
@preconcurrency import AVFAudio
import Foundation
import Testing
@testable import AudioMixer

final class QuantumFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [PCMFrame] = []
    func append(_ frame: PCMFrame) { lock.withLock { frames.append(frame) } }
    var snapshot: [PCMFrame] { lock.withLock { frames } }
}

@Test func mixerOutputPreservesOtherInputsOnTheSharedDeviceClock() throws {
    let mixer = try AudioMixer(audioFormat: .init())
    let existing = AVAudioSourceNode(format: mixer.format) { _, _, count, list in
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = buffer.mData else { return kAudio_ParamError }
            data.assumingMemoryBound(to: Float.self).update(repeating: 0.1, count: Int(count))
        }
        return noErr
    }
    mixer.engine.attach(existing)
    try mixer.engine.connectNode(existing, to: mixer.engine.mainMixerNode, format: mixer.format)
    let bus = try mixer.createBus("shared")
    let source = try bus.addPCMSource(id: "peer")
    try mixer.routeToOutput(bus)
    try mixer.engine.enableManualRenderingMode(.offline, format: mixer.format, maximumFrameCount: 480)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    try source.schedule(.init(sequenceNumber: 0, samples: Array(repeating: 0.2, count: 480)))
    let output = try #require(AVAudioPCMBuffer(pcmFormat: mixer.format, frameCapacity: 480))
    #expect(try mixer.engine.renderOffline(480, to: output) == .success)
    let samples = try #require(output.floatChannelData)[0]
    #expect((0..<480).allSatisfy { abs(samples[$0] - 0.3) < 0.001 })
}

@Test func sinkDeliversEveryRenderQuantumWithoutHundredMillisecondBatching() async throws {
    let engine = AVAudioEngine()
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("quantum")
    let source = try bus.addPCMSource(id: "capture")
    let received = QuantumFrames()
    _ = try bus.installPCMSink(id: "network", targetFormat: .init(), bufferFrameCount: 128) { frame, _ in
        received.append(frame)
    }
    try mixer.routeToOutput(bus)
    try engine.enableManualRenderingMode(.offline, format: mixer.format, maximumFrameCount: 480)
    try mixer.start()
    defer { mixer.stop() }
    let signal = (0..<4800).map { Float(sin(Double($0) * 0.031)) * 0.2 }
    try source.schedule(.init(sequenceNumber: 0, samples: signal))
    source.start()
    let output = try #require(AVAudioPCMBuffer(pcmFormat: mixer.format, frameCapacity: 480))
    for index in 0..<10 {
        #expect(try engine.renderOffline(480, to: output) == .success)
        let deadline = ContinuousClock.now + .milliseconds(30)
        while received.snapshot.count <= index && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(received.snapshot.count == index + 1, "10 ms must be delivered without waiting for another render")
    }
    let frames = received.snapshot
    #expect(frames.allSatisfy { $0.frameCount == 480 })
    let samples = frames.flatMap(\.samples)
    #expect(samples.count == signal.count)
    #expect(zip(samples, signal).allSatisfy { abs($0 - $1) < 0.00001 })
}
