import AudioCore
import AudioMixer
import Codec
import Foundation
import XCTest
@testable import RideIntercom

private struct NativeCodecSetting {
    let codec: CodecIdentifier
    let rate: Double
    let bitRate: Int
}

extension AudioE2ETests {
    /// Isolate native codec quality from VAD, Audio Units, scheduling and RTC.
    @MainActor
    func testNativeCodecsPreserveWholeSpeech() throws {
        var rows: [[String: Any]] = []
        for fixture in ["speech-ja", "speech", "conversation-ja", "conversation-reply-ja"] {
            let reference = try SpeechFileInput(name: fixture).samples
            for setting in nativeCodecSettings() {
                try measureNativeCodec(setting, fixture: fixture, reference: reference, rows: &rows)
            }
        }
        let measurement: [String: Any] = ["scenario": "native-codecs", "role": "pipeline", "transport": "none",
            "cases": rows, "continuityPassed": rows.allSatisfy { $0["passed"] as? Bool == true }]
        try addAudioE2EJSONAttachment(measurement, name: "native-codecs-measurement")
    }

    @MainActor
    private func nativeCodecSettings() -> [NativeCodecSetting] {
        var settings: [NativeCodecSetting] = []
        for rate in [16000.0, 24000, 48000] {
            let format = AudioFormat(sampleRate: rate, channelCount: 1)
            settings.append(.init(codec: .pcm16, rate: rate, bitRate: 32000))
            for bitRate in [48000, 64000, 128000] {
                settings.append(.init(codec: .opus, rate: rate, bitRate: bitRate))
            }
            for bitRate in AppAudioCodecBridge.availableAACBitRates(format: format) {
                settings.append(.init(codec: .mpeg4AACELD, rate: rate, bitRate: bitRate))
            }
        }
        return settings
    }

    @MainActor
    private func measureNativeCodec(
        _ setting: NativeCodecSetting, fixture: String, reference: [Float], rows: inout [[String: Any]]
    ) throws {
        let format = AudioFormat(sampleRate: setting.rate, channelCount: 1)
        let encoder = try StreamingCodecEncoder(configuration: .init(
            codec: setting.codec, format: format,
            aacELDv2Options: .init(bitRate: setting.bitRate), opusOptions: .init(bitRate: setting.bitRate)
        ))
        let decoder = StreamingCodecDecoder()
        let probe = RenderedAudioProbe()
        var failures: [String] = []
        let processor = try AudioFrameProcessor(format: .init(), outputFormat: format) { input, _ in
            do {
                if let packet = try encoder.encode(input) { probe.append(try decoder.decode(packet)) }
            } catch {
                failures.append(String(describing: error))
            }
        }
        try processor.start()
        defer { processor.stop() }
        for offset in stride(from: 0, to: reference.count, by: 480) {
            let samples = Array(reference[offset..<min(reference.count, offset + 480)])
            let input = PCMFrame(
                sequenceNumber: UInt64(offset / 480), capturedAt: Double(offset) / 48000, samples: samples
            )
            try processor.process(input)
        }
        XCTAssertTrue(failures.isEmpty)
        let output = probe.snapshot()
        let match = SpeechContinuity.measure(
            reference: reference, referenceRate: 48000, output: output.samples, outputRate: output.rate
        )
        let name = "native-\(fixture)-\(setting.codec.rawValue)-\(Int(setting.rate))-\(setting.bitRate)"
        print("CODEC_SPEECH", name, match.alignmentCorrelation, match.matchedWindowRatio, match.missingActiveRatio)
        rows.append(["case": name, "matchedWindowRatio": match.matchedWindowRatio,
            "missingActiveRatio": match.missingActiveRatio, "passed": match.passed && match.missingActiveRatio == 0])
        try attachNativeCodecRecordings(name: name, match: match, probe: probe, output: output)
        XCTAssertTrue(match.passed, name)
        XCTAssertEqual(match.missingActiveRatio, 0, name)
        if fixture.hasPrefix("conversation") {
            let replies = try ConversationIdentity.measure(fixture: fixture, reference: reference,
                output: output.samples, outputRate: output.rate, referenceOffset: match.referenceOffsetSeconds)
            XCTAssertTrue(replies.passed, "\(name): \(replies)")
        }
    }

    private func attachNativeCodecRecordings(
        name: String, match: SpeechContinuity, probe: RenderedAudioProbe, output: RenderedAudioProbe.Recording
    ) throws {
        let data = XCTAttachment(data: try JSONEncoder().encode(match), uniformTypeIdentifier: "public.json")
        data.name = name + "-continuity"
        data.lifetime = .keepAlways
        add(data)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".wav")
        try probe.writeWAV(to: url, rendered: output)
        let audio = XCTAttachment(contentsOfFile: url)
        audio.name = name
        audio.lifetime = .keepAlways
        add(audio)
        try? FileManager.default.removeItem(at: url)
    }
}
