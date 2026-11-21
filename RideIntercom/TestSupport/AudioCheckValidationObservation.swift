#if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS) && targetEnvironment(simulator)
import AudioCore
import Foundation

/// Ephemeral measurement only: PCM never leaves memory or enters the evidence file.
struct AudioCheckValidationObservation {
    struct PlaybackStatus {
        let droppedRenderFrames: Int
        let droppedInputFrames: Int
        let inputStopped: Bool
        let outputStopped: Bool
        let nativeBackends: Bool
        let watchRoute: Bool
        let engineRunning: Bool?
    }

    private struct SignalProducts {
        var dot = 0.0
        var inputEnergy = 0.0
        var outputEnergy = 0.0

        var correlation: Double? {
            guard inputEnergy > 1e-10, outputEnergy > 1e-10 else { return nil }
            return dot / sqrt(inputEnergy * outputEnergy)
        }
    }

    let generation: UUID
    private var input: [Float] = []
    private var output: [Float] = []
    private var rate: Double = 0
    private var channels: Int = 0
    private var incompatible = false
    private var overflow = false
    private var firstOutputAt: Double?
    private var lastOutputAt: Double?
    private var lastOutputEnd: Double?
    private var timestampGapCount = 0
    private var inputTimestampGapCount = 0

    mutating func setInput(_ frames: [PCMFrame]) {
        guard let first = frames.first else { return }
        rate = first.format.sampleRate
        channels = first.format.channelCount
        var previousEnd: Double?
        for frame in frames {
            if frame.format.sampleRate != rate || frame.format.channelCount != channels { incompatible = true }
            if let end = previousEnd, abs(frame.capturedAt - end) > 2 / rate { inputTimestampGapCount += 1 }
            previousEnd = frame.capturedAt + Double(frame.frameCount) / rate
            let remaining = max(0, Int(rate * 6) * channels - input.count)
            if frame.samples.count > remaining { overflow = true }
            input.append(contentsOf: frame.samples.prefix(remaining))
        }
    }

    mutating func appendOutput(_ frame: PCMFrame) {
        guard rate > 0, channels > 0 else { return }
        guard frame.format.sampleRate == rate, frame.format.channelCount > 0, channels == 1 else {
            incompatible = true
            return
        }
        // Hardware output can be stereo after route negotiation or restart.
        // Compare its mono fold-down with the recorded mono input.
        let samples: [Float]
        if frame.format.channelCount == 1 { samples = frame.samples } else {
            samples = (0..<frame.frameCount).map { index in
                let start = index * frame.format.channelCount
                let end = start + frame.format.channelCount
                return frame.samples[start..<end].reduce(0, +) / Float(frame.format.channelCount)
            }
        }
        if let end = lastOutputEnd, abs(frame.capturedAt - end) > 2 / rate { timestampGapCount += 1 }
        if firstOutputAt == nil { firstOutputAt = frame.capturedAt }
        lastOutputAt = frame.capturedAt
        lastOutputEnd = frame.capturedAt + Double(frame.frameCount) / rate
        let remaining = max(0, Int(rate * 6) * channels - output.count)
        if samples.count > remaining { overflow = true }
        output.append(contentsOf: samples.prefix(remaining))
    }

    func record(phase: String, status: PlaybackStatus) -> [String: Any] {
        let inputFrames = channels > 0 ? input.count / channels : 0
        let outputFrames = channels > 0 ? output.count / channels : 0
        var result: [String: Any] = [
            "generation": generation.uuidString, "phase": phase, "recordedAt": Date().timeIntervalSince1970,
            "sampleRate": rate, "channels": channels, "inputFrames": inputFrames,
            "outputFrames": outputFrames, "inputNonzero": input.filter { abs($0) > 0.00001 }.count,
            "outputNonzero": output.filter { abs($0) > 0.00001 }.count,
            "inputDuration": rate > 0 ? Double(inputFrames) / rate : 0,
            "outputDuration": rate > 0 ? Double(outputFrames) / rate : 0,
            "outputFirstAt": firstOutputAt.map { $0 as Any } ?? NSNull(),
            "outputLastAt": lastOutputAt.map { $0 as Any } ?? NSNull(),
            "outputEndAt": lastOutputEnd.map { $0 as Any } ?? NSNull(), "timestampGapCount": timestampGapCount,
            "droppedRenderFramesCombined": status.droppedRenderFrames, "inputDroppedFrames": status.droppedInputFrames,
            "inputTimestampGapCount": inputTimestampGapCount, "overflow": overflow,
            "inputStopped": status.inputStopped, "outputStopped": status.outputStopped,
            "nativeBackends": status.nativeBackends, "watchRoute": status.watchRoute,
            "engineRunning": status.engineRunning as Any? ?? NSNull(),
            "comparison": "unidentifiable"
        ]
        guard !incompatible, rate > 0, channels == 1 else {
            result["comparison"] = "unsupportedFormat"
            return result
        }
        let window = Int(rate * 0.2), full = Int(rate * 5)
        guard window > 0, input.count >= full, output.count >= window,
              let anchor = strongestInputWindow(window: window, full: full),
              let lag = alignmentLag(anchor: anchor, window: window) else { return result }
        let hasFullCoverage = lag + full <= output.count
        result["lagSeconds"] = Double(lag) / rate
        result["fullCoverage"] = hasFullCoverage
        let offsets = [0, full / 2 - window / 2, full - window]
        let scores = offsets.map { signalProducts($0, lag + $0, count: window)?.correlation }
        result["windowCorrelations"] = scores.map { $0 as Any? ?? NSNull() }
        if hasFullCoverage { measureAlignedSignal(lag: lag, full: full, result: &result) }
        return result
    }

    private func signalProducts(
        _ inputStart: Int,
        _ outputStart: Int,
        count: Int,
        sampleStride: Int = 1
    ) -> SignalProducts? {
        guard inputStart >= 0, outputStart >= 0, inputStart + count <= input.count,
              outputStart + count <= output.count else { return nil }
        var products = SignalProducts()
        for index in stride(from: 0, to: count, by: sampleStride) {
            let inputSample = Double(input[inputStart + index])
            let outputSample = Double(output[outputStart + index])
            products.dot += inputSample * outputSample
            products.inputEnergy += inputSample * inputSample
            products.outputEnergy += outputSample * outputSample
        }
        return products
    }

    private func strongestInputWindow(window: Int, full: Int) -> Int? {
        // VAD can leave any fixed window silent. Align on the strongest
        // recorded window, retaining unidentifiable for an all-silent input.
        var anchor = 0, anchorEnergy = 0.0
        for start in stride(from: 0, through: full - window, by: max(1, window / 2)) {
            let energy = stride(from: start, to: start + window, by: 16).reduce(0.0) {
                $0 + Double(input[$1]) * Double(input[$1])
            }
            if energy > anchorEnergy { anchor = start; anchorEnergy = energy }
        }
        return anchorEnergy > 1e-10 ? anchor : nil
    }

    private func alignmentLag(anchor: Int, window: Int) -> Int? {
        let maxLag = min(Int(rate * 0.25), output.count - window)
        var bestLag = 0, best = -Double.infinity
        for lag in 0...maxLag {
            if let score = signalProducts(anchor, anchor + lag, count: window, sampleStride: 16)?.correlation,
               score > best {
                best = score
                bestLag = lag
            }
        }
        guard best.isFinite else { return nil }
        let lower = max(0, bestLag - 16), upper = min(maxLag, bestLag + 16)
        best = -Double.infinity
        for lag in lower...upper {
            if let score = signalProducts(anchor, anchor + lag, count: window)?.correlation, score > best {
                best = score
                bestLag = lag
            }
        }
        return bestLag
    }

    private func measureAlignedSignal(lag: Int, full: Int, result: inout [String: Any]) {
        guard let products = signalProducts(0, lag, count: full), let correlation = products.correlation else { return }
        let gain = products.dot / products.inputEnergy
        var residual = 0.0, silentResidual = 0.0, silentCount = 0
        for index in 0..<full {
            let error = Double(output[lag + index]) - gain * Double(input[index])
            residual += error * error
            if abs(input[index]) <= 0.00001 { silentResidual += error * error; silentCount += 1 }
        }
        result["fullSignalCorrelation"] = min(1, max(-1, correlation))
        result["fullSignalNormalizedRMSError"] = sqrt(residual / products.outputEnergy)
        result["silentComparedSampleCount"] = silentCount
        result["silentResidualRMS"] = silentCount > 0 ? sqrt(silentResidual / Double(silentCount)) : 0
        result["comparison"] = "measured"
    }
}
#endif
