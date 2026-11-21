import XCTest
import Accelerate
import Foundation

/// A fixed-time comparison of the entire recording, after the E2E warm-up.
/// The reference repeats, but alignment is chosen ONCE for the whole output.
/// Per-window reordering or time warping would conceal missing/repeated speech.
struct SpeechContinuity: Codable, Sendable {
    let alignmentCorrelation: Float
    let referenceOffsetSeconds: Double
    let matchedWindowRatio: Double
    let missingActiveRatio: Double
    let longestMissingSeconds: Double
    let activeSeconds: Double
    let windows: [Window]
    let missingIntervals: [MissingInterval]

    struct Window: Codable, Sendable {
        let outputSeconds: Double
        let correlation: Float
    }

    /// Half-open interval in seconds relative to the observed stage's first sample.
    struct MissingInterval: Codable, Sendable {
        let startSeconds: Double
        let endSeconds: Double
    }

    var passed: Bool {
        alignmentCorrelation >= 0.65 && activeSeconds >= 2 && !windows.isEmpty
            && matchedWindowRatio >= 0.98 && missingActiveRatio <= 0.01 && longestMissingSeconds <= 0.06
    }

    static func measure(reference: [Float], referenceRate: Double, output: [Float], outputRate: Double) -> Self {
        let empty = Self(alignmentCorrelation: 0, referenceOffsetSeconds: 0, matchedWindowRatio: 0,
                         missingActiveRatio: 1, longestMissingSeconds: 0, activeSeconds: 0, windows: [], missingIntervals: [])
        guard !reference.isEmpty, !output.isEmpty, referenceRate > 0, outputRate > 0,
              reference.allSatisfy(\.isFinite), output.allSatisfy(\.isFinite) else { return empty }
        let count = Int((Double(output.count) / outputRate + Double(reference.count) / referenceRate + 0.1) * referenceRate)
        let repeated = (0..<count).map { reference[$0 % reference.count] }
        let ref = RenderedAudioProbe.features(repeated, rate: referenceRate)
        let out = RenderedAudioProbe.features(output, rate: outputRate)
        guard out.count >= 20, ref.count >= out.count else { return empty }
        let candidates = min(ref.count - out.count + 1, Int(Double(reference.count) / referenceRate * 100) + 1)
        var correlations = [Float](repeating: 0, count: candidates)
        for band in 0..<16 {
            var products = correlations.map { _ in Float(0) }
            vDSP_conv(ref.map { $0[band] }, 1, out.map { $0[band] }, 1,
                      &products, 1, vDSP_Length(candidates), vDSP_Length(out.count))
            for i in products.indices { correlations[i] += products[i] }
        }
        var energy = [Float](repeating: 0, count: ref.count + 1)
        for i in ref.indices { energy[i + 1] = energy[i] + ref[i].reduce(0) { $0 + $1 * $1 } }
        let outputEnergy = out.reduce(Float(0)) { $0 + $1.reduce(0) { $0 + $1 * $1 } }
        var offset = 0, best: Float = 0
        for i in correlations.indices {
            let denominator = sqrt(max(0, (energy[i + out.count] - energy[i]) * outputEnergy))
            let score = denominator > 0.01 ? correlations[i] / denominator : 0
            if score > best { offset = i; best = score }
        }

        // 10 ms RMS bins distinguish reference pauses from newly missing speech.
        func rms(_ samples: [Float], rate: Double, binsPerSecond: Double = 100) -> [Float] {
            let count = Int(Double(samples.count) * binsPerSecond / rate)
            return (0..<count).map { index in
                // Each boundary belongs to the original clock. Truncating a
                // 44.1-sample millisecond to 44 every time drifts 45 ms in 20 s.
                let start = Int(Double(index) * rate / binsPerSecond)
                let end = min(samples.count, max(start + 1, Int(Double(index + 1) * rate / binsPerSecond)))
                return sqrt(samples[start..<end].reduce(0) { $0 + $1 * $1 } / Float(end - start))
            }
        }
        // Refine the ONE global offset using a 1 ms energy envelope. A native
        // codec's fractional 10 ms delay must not mislabel the edge of a short
        // syllable as missing. No local alignment or time warping is introduced.
        let fineReference = rms(repeated, rate: referenceRate, binsPerSecond: 1000)
        let fineOutput = rms(output, rate: outputRate, binsPerSecond: 1000)
        let outputPower = fineOutput.reduce(Float(0)) { $0 + $1 * $1 }
        var fineOffset = offset * 10, fineScore: Float = -1
        for candidate in max(0, offset * 10 - 15)...(offset * 10 + 15) {
            guard candidate + fineOutput.count <= fineReference.count else { continue }
            var dot: Float = 0, power: Float = 0
            for i in fineOutput.indices {
                let value = fineReference[candidate + i]
                dot += value * fineOutput[i]; power += value * value
            }
            let score = dot / max(1e-12, sqrt(power * outputPower))
            if score > fineScore { fineScore = score; fineOffset = candidate }
        }
        let referenceRMS = rms(Array(repeated.dropFirst(Int(Double(fineOffset) * referenceRate / 1000))), rate: referenceRate)
        let outputRMS = rms(output, rate: outputRate)
        let length = min(out.count, outputRMS.count, referenceRMS.count)
        let activeThreshold = (referenceRMS.max() ?? 0) * 0.08
        let active = (0..<length).map { referenceRMS[$0] > activeThreshold }
        let gains = (0..<length).compactMap { i -> Float? in
            active[i] && outputRMS[i] > 0.00001 ? outputRMS[i] / referenceRMS[i] : nil
        }.sorted()
        let gain = gains.isEmpty ? 1 : gains[gains.count / 2]
        var activeCount = 0
        var missingBins: [Range<Int>] = []
        for i in 0..<length where active[i] {
            activeCount += 1
            guard outputRMS[i] < referenceRMS[i] * gain * 0.1 else { continue }
            if let previous = missingBins.last, previous.upperBound == i {
                missingBins[missingBins.count - 1] = previous.lowerBound..<(i + 1)
            } else {
                missingBins.append(i..<(i + 1))
            }
        }
        let missingCount = missingBins.reduce(0) { $0 + $1.count }
        let longest = missingBins.map(\.count).max() ?? 0

        var windows: [Window] = []
        for start in stride(from: 0, through: length - 20, by: 10) {
            guard active[start..<(start + 20)].filter({ $0 }).count >= 5 else { continue }
            // At most 30 ms of local jitter; never search elsewhere in the utterance.
            var score: Float = 0
            for delta in -3...3 {
                let r = offset + start + delta
                guard r >= 0, r + 20 <= ref.count else { continue }
                var dot: Float = 0, a: Float = 0, b: Float = 0
                for frame in 0..<20 {
                    for band in 0..<16 {
                        let x = ref[r + frame][band], y = out[start + frame][band]
                        dot += x * y; a += x * x; b += y * y
                    }
                }
                if a * b > 0.0001 { score = max(score, dot / sqrt(a * b)) }
            }
            windows.append(.init(outputSeconds: Double(start) / 100, correlation: score))
        }
        return Self(alignmentCorrelation: best, referenceOffsetSeconds: Double(fineOffset) / 1000,
                    matchedWindowRatio: windows.isEmpty ? 0 : Double(windows.filter { $0.correlation >= 0.65 }.count) / Double(windows.count),
                    missingActiveRatio: activeCount == 0 ? 1 : Double(missingCount) / Double(activeCount),
                    longestMissingSeconds: Double(longest) / 100, activeSeconds: Double(activeCount) / 100, windows: windows,
                    missingIntervals: missingBins.map {
                        MissingInterval(startSeconds: Double($0.lowerBound) / 100, endSeconds: Double($0.upperBound) / 100)
                    })
    }
}

extension AudioE2ETests {
    func testContinuityRejectsGapsRepeatsAndMissingSpeech() throws {
        let speech = try SpeechFileInput(name: "speech").samples
        let other = try SpeechFileInput(name: "reply").samples
        let clean = (0..<960_000).map { speech[($0 + 12_345) % speech.count] * 0.3 }
        func measure(_ output: [Float]) -> SpeechContinuity {
            SpeechContinuity.measure(reference: speech, referenceRate: 48_000, output: output, outputRate: 48_000)
        }
        let cleanResult = measure(clean)
        XCTAssertTrue(cleanResult.passed, "Fixed delay and gain must preserve speech")
        XCTAssertTrue(cleanResult.missingIntervals.isEmpty)
        let resampled = (0..<Int(Double(clean.count - 1) * 44_100 / 48_000)).map { index -> Float in
            let position = Double(index) * 48_000 / 44_100
            let lower = Int(position), fraction = Float(position - Double(lower))
            return clean[lower] * (1 - fraction) + clean[lower + 1] * fraction
        }
        let fractionalRate = SpeechContinuity.measure(reference: speech, referenceRate: 48_000,
            output: resampled, outputRate: 44_100)
        XCTAssertTrue(fractionalRate.passed)
        XCTAssertEqual(fractionalRate.missingActiveRatio, 0)
        XCTAssertEqual(fractionalRate.referenceOffsetSeconds, 12_345.0 / 48_000, accuracy: 0.002,
            "44.1 samples per millisecond must not accumulate a truncated-bin clock error")
        let filtered = clean.reduce(into: [Float]()) { values, sample in
            values.append(0.8 * (values.last ?? 0) + 0.2 * sample)
        }.map { tanh($0 * 8) }
        XCTAssertTrue(measure(filtered).passed, "Coloration alone is not a dropout")
        var gaps = clean
        for index in gaps.indices where index % 24_000 < 4_800 { gaps[index] = 0 }
        let gapResult = measure(gaps)
        XCTAssertFalse(gapResult.passed, "Repeated 100 ms losses must fail")
        XCTAssertGreaterThan(gapResult.missingActiveRatio, 0.05)
        let durations = gapResult.missingIntervals.map { $0.endSeconds - $0.startSeconds }
        XCTAssertEqual(durations.reduce(0, +), gapResult.activeSeconds * gapResult.missingActiveRatio, accuracy: 0.001)
        XCTAssertEqual(durations.max() ?? 0, gapResult.longestMissingSeconds, accuracy: 0.001)
        var missing = clean
        missing.replaceSubrange(240_000..<264_000, with: repeatElement(0, count: 24_000))
        let missingResult = measure(missing)
        XCTAssertFalse(missingResult.passed, "One missing half-second must fail")
        XCTAssertFalse(missingResult.missingIntervals.isEmpty)
        XCTAssertTrue(missingResult.missingIntervals.allSatisfy { $0.startSeconds >= 5 && $0.endSeconds <= 5.5 })
        var repeated = clean
        repeated.replaceSubrange(240_000..<288_000, with: clean[192_000..<240_000])
        XCTAssertFalse(measure(repeated).passed, "Repeated speech must fail even without silence")
        var reordered = clean
        reordered.replaceSubrange(240_000..<480_000, with: clean[480_000..<720_000])
        reordered.replaceSubrange(480_000..<720_000, with: clean[240_000..<480_000])
        XCTAssertFalse(measure(reordered).passed, "Out-of-order speech must fail")
        XCTAssertFalse(measure(Array(repeating: 0, count: clean.count)).passed)
        XCTAssertFalse(measure((0..<clean.count).map { other[$0 % other.count] }).passed)
    }

    func testSpeechMatcherRejectsSilenceAndWrongSpeaker() throws {
        let speech = try SpeechFileInput(name: "speech").samples
        let other = try SpeechFileInput(name: "reply").samples
        let delayed = Array(repeating: Float(0), count: 12_345) + speech.map { $0 * 0.2 }
        XCTAssertGreaterThan(RenderedAudioProbe.speechMatch(reference: speech, referenceRate: 48_000,
            output: delayed, outputRate: 48_000), 0.95)
        XCTAssertEqual(RenderedAudioProbe.speechMatch(reference: speech, referenceRate: 48_000,
            output: Array(repeating: 0, count: speech.count), outputRate: 48_000), 0)
        XCTAssertLessThan(RenderedAudioProbe.speechMatch(reference: speech, referenceRate: 48_000,
            output: other, outputRate: 48_000), 0.4)
        let filtered = speech.reduce(into: [Float]()) { values, sample in
            values.append(0.8 * (values.last ?? 0) + 0.2 * sample)
        }
        XCTAssertGreaterThan(RenderedAudioProbe.speechMatch(reference: speech, referenceRate: 48_000,
            output: filtered.map { tanh($0 * 8) }, outputRate: 48_000), 0.8)
        var state: UInt64 = 1
        let noise = speech.map { _ -> Float in
            state = state &* 6_364_136_223_846_793_005 &+ 1
            return Float(state >> 32) / Float(UInt32.max) - 0.5
        }
        XCTAssertLessThan(RenderedAudioProbe.speechMatch(reference: speech, referenceRate: 48_000,
            output: noise, outputRate: 48_000), 0.4)
    }

}
