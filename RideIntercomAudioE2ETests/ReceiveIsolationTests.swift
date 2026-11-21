import AVFAudio
import AudioCore
import Codec
import Foundation
import Synchronization
import RTC
import SessionManager
import XCTest
@testable import RideIntercom

private struct ReceiveSwitchTrace: Encodable {
    struct Switch: Encodable {
        let start: TimeInterval
        let end: TimeInterval
        let enabled: Bool
    }

    let switches: [Switch]
    let renderClock: [RenderedAudioProbe.RenderClockBlock]
    let rate: Double
    let baseline: [Double]
}

extension AudioE2ETests {
    @MainActor
    func testReceiveIsolationKeepsItsEffectWhenEnabledAgain() async throws {
        try await activateAudioSessionForTest(configuration: .init(prefersEchoCancelledInput: true))
        let engine = AVAudioEngine(), native = RenderedAudioProbe(recordsRenderClock: true)
        let output = SystemAudioOutputStreamBackend(engine: engine)
        try engine.mainMixerNode.installAudioTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, time in
            native.append(buffer, time: time)
        }
        let pipeline = AppAudioPipeline(makeEngine: { engine }, usesHardwareClock: true)
        defer { pipeline.stop(); engine.mainMixerNode.removeTap(onBus: 0); try? output.stopRendering() }
        let hardware = try output.startRendering(configuration: .intercomCall)
        try pipeline.rebuild(configuration: .init(outputHardwareFormat: hardware,
            transmitSoundIsolationEnabled: false, receiveMaximumBufferedDuration: 0.12, receivePlayoutDelay: 0.002),
            peerIDs: ["one", "two"])

        let frequencies = [600.0, 1100.0]
        let feed = ReceiveIsolationPackets(pipeline: pipeline, frequencies: frequencies)
        defer { feed.stop() }
        let changes = try await measureReceiveEffects(pipeline: pipeline, native: native, frequencies: frequencies)
        let renderClock = try XCTUnwrap(native.stopRecordingRenderClock())
        let rendered = native.snapshot()
        XCTAssertEqual(rendered.invalid, 0)
        try verifyUnaffectedPeer(
            rendered: rendered, renderClock: renderClock, changes: changes, frequencies: frequencies
        )
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("receive-switches.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try native.writeWAV(to: url, rendered: rendered)
        let audio = XCTAttachment(contentsOfFile: url)
        audio.name = "receive-switches"; audio.lifetime = .keepAlways; add(audio)
        let trace = ReceiveSwitchTrace(
            switches: changes.peer, renderClock: renderClock, rate: rendered.rate, baseline: changes.baseline
        )
        let attachment = XCTAttachment(data: try JSONEncoder().encode(trace), uniformTypeIdentifier: "public.json")
        attachment.name = "receive-switches-trace"; attachment.lifetime = .keepAlways; add(attachment)
        for attempt in feed.rejected {
            XCTAssertTrue(changes.receiveMix.contains { $0.overlaps(attempt.start...attempt.end) },
                "A peer effect change cannot reject received audio: \(attempt)")
        }
        XCTAssertTrue(feed.failures.isEmpty)
        XCTAssertEqual(pipeline.droppedRenderFrameCount, 0)
        XCTAssertEqual(output.playbackResetCount ?? 0, 0)
    }

    @MainActor
    private func measureReceiveEffects(
        pipeline: AppAudioPipeline, native: RenderedAudioProbe, frequencies: [Double]
    ) async throws -> ReceiveEffectChanges {
        func steadyTones() async throws -> [Double] {
            try await Task.sleep(for: .milliseconds(650))
            let start = native.sampleCount
            try await Task.sleep(for: .milliseconds(400))
            let recording = native.snapshot()
            XCTAssertEqual(recording.invalid, 0)
            let measured = ToneIntegrity.measure(samples: Array(recording.samples.dropFirst(start)),
                rate: recording.rate, frequencies: frequencies)
            XCTAssertTrue(measured.passed, "\(measured.dictionary)")
            return try XCTUnwrap(measured.amplitudes.count == frequencies.count ? measured.amplitudes : nil)
        }
        let baseline = try await steadyTones()
        var receiveMixChanges: [ClosedRange<TimeInterval>] = []
        var peerChanges: [ReceiveSwitchTrace.Switch] = []
        func updateIsolation(peerOnly: Bool, enabled: Bool) throws {
            let start = ProcessInfo.processInfo.systemUptime
            try pipeline.updateSoundIsolation(transmit: false, receiveMaster: enabled && !peerOnly,
                peers: enabled && peerOnly ? ["one": true] : [:])
            let end = ProcessInfo.processInfo.systemUptime
            if peerOnly {
                peerChanges.append(.init(start: start, end: end, enabled: enabled))
            } else {
                receiveMixChanges.append(start...end)
            }
        }
        for peerOnly in [false, true] {
            try updateIsolation(peerOnly: peerOnly, enabled: true)
            let first = try await steadyTones()
            try updateIsolation(peerOnly: peerOnly, enabled: false)
            let bypassed = try await steadyTones()
            try updateIsolation(peerOnly: peerOnly, enabled: true)
            let enabledAgain = try await steadyTones()
            for index in frequencies.indices {
                let expected = baseline[index] * (peerOnly && index == 1 ? 1 : 0.5)
                XCTAssertEqual(first[index], expected, accuracy: 0.002, "First enable, peerOnly=\(peerOnly)")
                XCTAssertEqual(bypassed[index], baseline[index], accuracy: 0.002, "Bypass, peerOnly=\(peerOnly)")
                XCTAssertEqual(enabledAgain[index], first[index], accuracy: 0.002, "Enable again, peerOnly=\(peerOnly)")
            }
            try updateIsolation(peerOnly: peerOnly, enabled: false)
            _ = try await steadyTones()
        }
        for _ in 0..<8 {
            for enabled in [true, false] {
                try updateIsolation(peerOnly: true, enabled: enabled)
                try await Task.sleep(for: .milliseconds(450))
            }
        }
        return ReceiveEffectChanges(baseline: baseline, receiveMix: receiveMixChanges, peer: peerChanges)
    }

    private func verifyUnaffectedPeer(
        rendered: RenderedAudioProbe.Recording, renderClock: [RenderedAudioProbe.RenderClockBlock],
        changes: ReceiveEffectChanges, frequencies: [Double]
    ) throws {
        let width = Int(rendered.rate * 0.01)
        XCTAssertGreaterThan(width, 0)
        func sampleIndex(at hostTime: Double) -> Int? {
            guard let block = renderClock.last(where: { $0.hostTime <= hostTime }) else { return nil }
            let offset = Int((hostTime - block.hostTime) * rendered.rate)
            return offset <= block.frameCount ? block.startSample + offset : nil
        }
        for change in changes.peer {
            let start = try XCTUnwrap(sampleIndex(at: change.start - 0.02))
            let end = try XCTUnwrap(sampleIndex(at: change.start + 0.25))
            let samples = rendered.samples[start..<end]
            let step = zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 1
            XCTAssertLessThan(step, 0.04, "Peer isolation switch, enabled=\(change.enabled)")
            // Both tones have whole cycles in 10 ms. Measure the unchanged
            // peer independently of the switched voice in the same output.
            let amplitudes = stride(from: start, through: end - width, by: max(1, width / 2)).map { offset in
                ToneIntegrity.measure(samples: Array(rendered.samples[offset..<offset + width]),
                    rate: rendered.rate, frequencies: [frequencies[1]]).amplitudes.first ?? 0
            }
            XCTAssertGreaterThan(try XCTUnwrap(amplitudes.min()), changes.baseline[1] * 0.7,
                "Other peer during isolation switch, enabled=\(change.enabled)")
        }
    }
}

private struct ReceiveEffectChanges {
    let baseline: [Double]
    let receiveMix: [ClosedRange<TimeInterval>]
    let peer: [ReceiveSwitchTrace.Switch]
}

private final class ReceiveIsolationDelivery: Sendable {
    let failures = Mutex<[String]>([])
    let rejected = Mutex<[(start: TimeInterval, end: TimeInterval)]>([])
}

private final class ReceiveIsolationPackets {
    private let queue: DispatchQueue
    private let timer: any DispatchSourceTimer
    private let delivery = ReceiveIsolationDelivery()

    var failures: [String] { delivery.failures.withLock { $0 } }
    var rejected: [(start: TimeInterval, end: TimeInterval)] { delivery.rejected.withLock { $0 } }

    init(pipeline: AppAudioPipeline, frequencies: [Double]) {
        let fixtures = zip(["one", "two"], frequencies).map { peer, frequency in
            let samples = (0..<480).map { Float(0.12 * sin(Double($0) * 2 * .pi * frequency / 48_000)) }
            return (PeerID(rawValue: peer), PCM16Codec.encode(samples))
        }
        let format = RTCAudioFormat(sampleRate: 48_000, channelCount: 1)
        queue = DispatchQueue(label: "receive-isolation-fixture", qos: .userInitiated)
        timer = DispatchSource.makeTimerSource(queue: queue)
        let sequence = Mutex<UInt64>(0)
        let delivery = self.delivery
        let start = DispatchTime.now() + .milliseconds(30)
        let captureOrigin = Double(start.uptimeNanoseconds) / 1e9
        timer.setEventHandler {
            let index = sequence.withLock { value in
                defer { value += 1 }
                return value
            }
            for (peer, payload) in fixtures {
                let packet = RTCAudioPacket(sequenceNumber: index, codec: .pcm16, format: format,
                    capturedAt: captureOrigin + Double(index) / 100, sampleCount: 480, payload: payload)
                let arrival = ProcessInfo.processInfo.systemUptime
                do {
                    _ = try pipeline.processReceivedAudioPacket(.init(peerID: peer, packet: packet))
                } catch AppAudioPipelineError.notConfigured {
                    delivery.rejected.withLock { $0.append((arrival, ProcessInfo.processInfo.systemUptime)) }
                } catch { delivery.failures.withLock { $0.append(String(describing: error)) } }
            }
        }
        timer.schedule(deadline: start, repeating: .milliseconds(10), leeway: .microseconds(100))
        timer.activate()
    }

    func stop() {
        timer.cancel()
        queue.sync {}
    }
}
