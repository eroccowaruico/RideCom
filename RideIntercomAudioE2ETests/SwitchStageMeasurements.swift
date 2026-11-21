import Foundation
import XCTest

/// Probe indices at the same operation. The three clocks have independent sample counts.
struct SwitchProbeIndices {
    let output: Int
    let decoded: Int
    let mixed: Int
}

struct SwitchStageWindow {
    let name: String
    let time: Double
    let duration: Double
    let start: SwitchProbeIndices
    let end: SwitchProbeIndices
}

struct SwitchRecordings {
    let final: RenderedAudioProbe.Recording
    let decoded: RenderedAudioProbe.Recording
    let mixed: RenderedAudioProbe.Recording

    var invalidUpstreamProbes: [String] {
        [("decoded", decoded), ("mixed", mixed)].compactMap { name, recording in
            let valid = !recording.samples.isEmpty && (1000...192000).contains(recording.rate) && recording.invalid == 0
            return valid ? nil : name
        }
    }
}

struct SwitchStageMeasurements {
    private(set) var rows: [[String: Any]] = []
    private(set) var unmetStages: [String] = []
    private(set) var unavailable = false
    private var audibleStages = 0

    mutating func record(window: SwitchStageWindow, audio: SwitchRecordings, acceptance: Bool) {
        let name = window.name, start = window.start, end = window.end, final = audio.final
        var row: [String: Any] = [
            "stage": name, "startSample": start.output, "endSample": end.output,
            "changeHostTime": window.time, "changeDurationSeconds": window.duration
        ]
        defer { rows.append(row) }
        let count = end.output - start.output
        guard final.rate.isFinite, (1000...192000).contains(final.rate), acceptance || final.invalid == 0,
              start.output >= 0, end.output <= final.samples.count,
              count >= (acceptance ? Int(final.rate / 1000) : Int(ceil(final.rate * 0.4))) else {
            row["observation"] = "invalid-recording-or-insufficient-steady-window"
            XCTFail("\(name): invalid recording or insufficient samples after the 300 ms settling interval")
            unavailable = true
            return
        }
        let all = Array(final.samples[start.output..<end.output])
        let steady = Array(all.dropFirst(Int(final.rate * 0.3)))
        let tone = ToneIntegrity.measure(samples: steady, rate: final.rate, frequencies: [600])
        let step = zip(all, all.dropFirst()).map { abs($0 - $1) }.max() ?? 1
        let silence = Self.silence(in: all, rate: final.rate)
        let stepPassed = step < 0.04
        let silencePassed = silence.longest <= 120
        row["steady"] = tone.dictionary
        row["maximumSampleStep"] = step
        row["maximumSilenceMilliseconds"] = silence.longest
        if acceptance {
            XCTAssertTrue(tone.passed, "\(name): \(tone.dictionary)")
            XCTAssertLessThan(step, 0.04, "No click across \(name)")
            XCTAssertLessThanOrEqual(silence.longest, 120, "\(name): reconfiguration silence exceeds the limit")
            return
        }
        row["stepPassed"] = stepPassed
        row["silencePassed"] = silencePassed
        row["observation"] = observeSignal(heardAudio: silence.heardAudio, window: window, audio: audio)
        if !tone.passed || !stepPassed || !silencePassed { unmetStages.append(name) }
    }

    private mutating func observeSignal(
        heardAudio: Bool, window: SwitchStageWindow, audio: SwitchRecordings
    ) -> String {
        if heardAudio {
            audibleStages += 1
            return "measured"
        }
        if Self.hasSignal(audio.decoded.samples, start: window.start.decoded, end: window.end.decoded)
            || Self.hasSignal(audio.mixed.samples, start: window.start.mixed, end: window.end.mixed) {
            return "upstream-signal-without-final-audio"
        }
        unavailable = true
        XCTFail("\(window.name): neither the upstream probes nor the final output contained sound")
        return "no-observed-signal"
    }

    mutating func finishLimitObservation(invalidUpstreamProbes: [String] = []) {
        if audibleStages == 0 {
            unavailable = true
            XCTFail("The final output never produced an audible reference interval")
        }
        if !invalidUpstreamProbes.isEmpty {
            unavailable = true
            XCTFail("Missing or invalid upstream probe recordings: \(invalidUpstreamProbes)")
        }
    }

    private static func hasSignal(_ samples: [Float], start: Int, end: Int) -> Bool {
        guard start >= 0, end > start, end <= samples.count else { return false }
        return samples[start..<end].contains { abs($0) >= 0.0001 }
    }

    private static func silence(in samples: [Float], rate: Double) -> (longest: Int, heardAudio: Bool) {
        let width = Int(rate / 1000)
        var current = 0, longest = 0
        var heardAudio = false
        for offset in stride(from: 0, through: samples.count - width, by: width) {
            let rms = sqrt(samples[offset..<(offset + width)].reduce(Float(0)) { $0 + $1 * $1 } / Float(width))
            if rms >= 0.0001 { heardAudio = true }
            current = rms < 0.0001 ? current + 1 : 0
            longest = max(longest, current)
        }
        return (longest, heardAudio)
    }
}
