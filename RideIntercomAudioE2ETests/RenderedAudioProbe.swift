import Accelerate
import AVFAudio
import AudioCore
import Foundation
import SessionManager
import XCTest

/// Reads the actual output engine's render tap, after scheduleBuffer and mixing.
/// Retains only the known fixture output, never microphone audio.
final class RenderedAudioProbe: @unchecked Sendable {
    struct Recording: Sendable {
        let samples: [Float]
        let rate: Double
        let invalid: Int
    }

    struct RenderClockBlock: Encodable, Sendable {
        let startSample: Int
        let frameCount: Int
        let hostTime: Double
    }

    private let lock = NSLock()
    private let capacity = 96_000 * 90
    private let storage: UnsafeMutablePointer<Float>
    private var count = 0
    private var rate: Double = 0
    private var invalidSampleCount = 0
    private var renderClockBlocks: [RenderClockBlock]?

    init(recordsRenderClock: Bool = false) {
        renderClockBlocks = recordsRenderClock ? [] : nil
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }
    deinit { storage.deallocate() }

    private var firstRenderTime: Double?
    var firstOutputTime: Double? { lock.withLock { firstRenderTime } }
    var sampleCount: Int { lock.withLock { count } }

    func stopRecordingRenderClock() -> [RenderClockBlock]? {
        lock.withLock {
            defer { renderClockBlocks = nil }
            return renderClockBlocks
        }
    }

    func append(_ frame: PCMFrame, preservingTimeline: Bool = false) {
        lock.withLock {
            if count == 0 { firstRenderTime = frame.capturedAt }
            rate = frame.format.sampleRate
            if preservingTimeline, let firstRenderTime {
                let position = Int(((frame.capturedAt - firstRenderTime) * rate).rounded())
                if position < count - 1 { invalidSampleCount += count - position }
                // Missing packets remain silence on the capture clock. Do not
                // concatenate across omitted pauses or hide lost voiced time.
                if position > count {
                    let end = min(position, capacity)
                    storage.advanced(by: count).update(repeating: 0, count: end - count)
                    count = end
                }
            }
            for index in stride(from: 0, to: frame.samples.count, by: frame.format.channelCount) {
                guard count < capacity else { invalidSampleCount += 1; continue }
                let value = frame.samples[index]
                if !value.isFinite { invalidSampleCount += 1 }
                storage[count] = value.isFinite ? value : 0
                count += 1
            }
        }
    }

    func append(_ buffer: AVReadOnlyAudioPCMBuffer, time: AVAudioTime? = nil) {
        guard case .float(let data) = buffer.channelData(0) else { return }
        lock.withLock {
            if count == 0 || renderClockBlocks != nil, let time, time.isHostTimeValid {
                let hostTime = AVAudioTime.seconds(forHostTime: time.hostTime)
                if count == 0 { firstRenderTime = hostTime }
                if renderClockBlocks != nil, count < capacity {
                    renderClockBlocks?.append(.init(startSample: count,
                        frameCount: min(Int(buffer.frameLength), capacity - count), hostTime: hostTime))
                }
            }
            rate = buffer.format.sampleRate
            for index in 0..<Int(buffer.frameLength) {
                guard count < capacity else { invalidSampleCount += 1; continue }
                let value = data[index]
                if !value.isFinite { invalidSampleCount += 1 }
                storage[count] = value.isFinite ? value : 0
                count += 1
            }
        }
    }

    // One test owner serializes snapshots and resets. The writer only appends
    // after the captured prefix, so copying a snapshot needs no render lock or
    // copy-on-write allocation in the next audio callback.
    func reset(recordsRenderClock: Bool = false) {
        lock.withLock {
            count = 0
            invalidSampleCount = 0
            firstRenderTime = nil
            renderClockBlocks = recordsRenderClock ? [] : nil
        }
    }

    func snapshot() -> Recording {
        let state = lock.withLock { (count, rate, invalidSampleCount) }
        return Recording(
            samples: Array(UnsafeBufferPointer(start: storage, count: state.0)), rate: state.1, invalid: state.2
        )
    }

    struct TimedRecording {
        let audio: Recording
        let blocks: [RenderClockBlock]?
        let firstHostTime: Double?
    }

    func finishTimedRecording() -> TimedRecording {
        let state = lock.withLock {
            defer { renderClockBlocks = nil }
            return (count, rate, invalidSampleCount, renderClockBlocks, firstRenderTime)
        }
        // Capture the sample prefix and its block index under the same lock.
        // Later callbacks append past that prefix while the test copies it.
        let audio = Recording(
            samples: Array(UnsafeBufferPointer(start: storage, count: state.0)), rate: state.1, invalid: state.2
        )
        return TimedRecording(audio: audio, blocks: state.3, firstHostTime: state.4)
    }

    func writeWAV(to url: URL, rendered: Recording) throws {
        guard rendered.rate > 0, !rendered.samples.isEmpty else { return }
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: rendered.rate, channels: 1))
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rendered.samples.count))
        )
        buffer.frameLength = buffer.frameCapacity
        try rendered.samples.withUnsafeBufferPointer {
            let channel = try XCTUnwrap(buffer.floatChannelData)[0]
            channel.update(from: try XCTUnwrap($0.baseAddress), count: $0.count)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    static func features(_ values: [Float], rate: Double) -> [[Float]] {
        guard values.count > 2 else { return [] }
        let step = rate / 8_000
        let samples: [Float] = (0..<Int(Double(values.count - 1) / step)).map { index in
            let position = Double(index) * step, start = Int(position)
            let fraction = Float(position - Double(start))
            return values[start] * (1 - fraction) + values[start + 1] * fraction
        }
        guard samples.count >= 256,
              let dft = vDSP_DFT_zop_CreateSetup(nil, 256, .FORWARD) else { return [] }
        defer { vDSP_DFT_DestroySetup(dft) }
        let window = (0..<256).map { Float(0.5 - 0.5 * cos(2 * Double.pi * Double($0) / 255)) }
        let boundaries = [2, 4, 6, 8, 11, 14, 18, 23, 29, 36, 44, 54, 66, 81, 99, 120, 129]
        let zero = [Float](repeating: 0, count: 256)
        var real = zero, imaginary = zero, result: [[Float]] = []
        for offset in stride(from: 0, through: samples.count - 256, by: 80) {
            let input = (0..<256).map { samples[offset + $0] * window[$0] }
            vDSP_DFT_Execute(dft, input, zero, &real, &imaginary)
            var bands = (0..<16).map { band -> Float in
                var power: Float = 0
                for bin in boundaries[band]..<boundaries[band + 1] {
                    power += real[bin] * real[bin] + imaginary[bin] * imaginary[bin]
                }
                return log(max(power, 1e-10))
            }
            let mean = bands.reduce(0, +) / 16
            for band in bands.indices { bands[band] -= mean }
            result.append(bands)
        }
        for band in 0..<16 {
            let mean = result.reduce(Float(0)) { $0 + $1[band] } / Float(result.count)
            for frame in result.indices { result[frame][band] -= mean }
        }
        return result
    }

    /// Compare the changing spectrum of 750 ms speech fragments. Centering each
    /// frequency band removes constant coloration from Voice Processing / effects;
    /// the phoneme sequence must still match. This is not a speech-quality score.
    static func speechMatch(reference: [Float], referenceRate: Double, output: [Float], outputRate: Double) -> Float {
        guard referenceRate > 0, outputRate > 0 else { return 0 }
        let ref = features(reference, rate: referenceRate), out = features(output, rate: outputRate)
        let width = 75
        guard ref.count >= width, out.count >= width else { return 0 }
        var energy = [Float](repeating: 0, count: out.count + 1)
        for frame in out.indices { energy[frame + 1] = energy[frame] + out[frame].reduce(0) { $0 + $1 * $1 } }
        var scores: [Float] = []
        for offset in stride(from: 0, through: ref.count - width, by: width) {
            let fragment = Array(ref[offset..<(offset + width)])
            let referenceEnergy = fragment.flatMap { $0 }.reduce(Float(0)) { $0 + $1 * $1 }
            guard referenceEnergy > 0.01 else { continue }
            var correlation = [Float](repeating: 0, count: out.count - width + 1)
            for band in 0..<16 {
                var product = correlation.map { _ in Float(0) }
                vDSP_conv(out.map { $0[band] }, 1, fragment.map { $0[band] }, 1,
                          &product, 1, vDSP_Length(product.count), vDSP_Length(width))
                for index in product.indices { correlation[index] += product[index] }
            }
            var best: Float = 0
            for index in correlation.indices {
                let outputEnergy = energy[index + width] - energy[index]
                if outputEnergy > 0.01 { best = max(best, correlation[index] / sqrt(referenceEnergy * outputEnergy)) }
            }
            scores.append(best)
        }
        // VAD intentionally removes quiet phonemes. Require three distinct
        // reference fragments (2.25 s), rather than penalizing suppressed pauses.
        guard scores.count >= 3 else { return 0 }
        return scores.sorted(by: >).prefix(3).reduce(0, +) / 3
    }
}
