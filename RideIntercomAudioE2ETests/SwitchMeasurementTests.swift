import Foundation
import XCTest

final class SwitchMeasurementTests: XCTestCase {
    func testMaximumSilenceIncludes120Milliseconds() throws {
        let rate = 16_000
        for gap in [119, 120, 121] {
            let samples: [Float] = (0..<rate).map { index in
                if index < gap * (rate / 1_000) { return 0 }
                return Float(0.04 * sin(2 * Double.pi * 600 * Double(index) / Double(rate)))
            }
            let recording: RenderedAudioProbe.Recording = (samples, Double(rate), 0)
            let audio = SwitchRecordings(final: recording, decoded: recording, mixed: recording)
            let window = SwitchStageWindow(
                name: "tone", time: 0, duration: 0,
                start: SwitchProbeIndices(output: 0, decoded: 0, mixed: 0),
                end: SwitchProbeIndices(output: rate, decoded: rate, mixed: rate)
            )
            var measurements = SwitchStageMeasurements()
            measurements.record(window: window, audio: audio, acceptance: false)
            let row = try XCTUnwrap(measurements.rows.first)
            XCTAssertEqual(row["maximumSilenceMilliseconds"] as? Int, gap)
            XCTAssertEqual(row["silencePassed"] as? Bool, gap <= 120)
            XCTAssertEqual(measurements.unmetStages, gap <= 120 ? [] : ["tone"])
            XCTAssertFalse(measurements.unavailable)
        }
    }
}
