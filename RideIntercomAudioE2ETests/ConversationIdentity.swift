import Foundation
import XCTest

/// Each short reply is checked at the ONE whole-recording alignment. A good
/// long sentence cannot compensate for a missing or repeated acknowledgement.
struct ConversationIdentity: Codable, Sendable {
    struct Reply: Codable, Sendable {
        let text: String
        let outputSeconds: Double
        let correlation: Float
    }
    let replies: [Reply]
    var passed: Bool {
        Set(replies.map(\.text)) == ["うん", "ふん"] && replies.allSatisfy { $0.correlation >= 0.65 }
    }

    private struct Manifest: Decodable {
        let fixtures: [Fixture]
    }

    private struct Fixture: Decodable {
        let name: String
        let utterances: [Utterance]
    }

    private struct Utterance: Decodable {
        let text: String
        let startSeconds: Double
        let endSeconds: Double
    }

    static func measure(fixture: String, reference: [Float], output: [Float], outputRate: Double,
                        referenceOffset: Double) throws -> Self {
        let bundle = Bundle(for: AudioE2ETests.self)
        let url = try XCTUnwrap(bundle.url(forResource: "conversation-manifest", withExtension: "json"))
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        let utterances = try XCTUnwrap(manifest.fixtures.first { $0.name == fixture }).utterances
        let period = Double(reference.count) / 48000
        let duration = Double(output.count) / outputRate
        var replies: [Reply] = []
        for utterance in utterances where ["うん", "ふん"].contains(utterance.text) {
            let start = utterance.startSeconds - 0.04, end = utterance.endSeconds + 0.04
            let referenceRange = Int(start * 48000)..<Int(end * 48000)
            let expected = RenderedAudioProbe.features(Array(reference[referenceRange]), rate: 48000)
            for cycle in -1...Int(ceil(duration / period) + 2) {
                let time = start - referenceOffset + Double(cycle) * period
                guard time >= 0, time + end - start <= duration else { continue }
                let outputRange = Int(time * outputRate)..<Int((time + end - start) * outputRate)
                let actual = RenderedAudioProbe.features(Array(output[outputRange]), rate: outputRate)
                var dot: Float = 0, referencePower: Float = 0, outputPower: Float = 0
                for (left, right) in zip(expected, actual) {
                    for (referenceValue, outputValue) in zip(left, right) {
                        dot += referenceValue * outputValue
                        referencePower += referenceValue * referenceValue
                        outputPower += outputValue * outputValue
                    }
                }
                replies.append(.init(text: utterance.text, outputSeconds: time + 0.04,
                    correlation: referencePower * outputPower > 1e-8 ? dot / sqrt(referencePower * outputPower) : 0))
            }
        }
        return Self(replies: replies)
    }
}

extension AudioE2ETests {
    func testConversationOracleRejectsMissingAcknowledgements() throws {
        let reference = try SpeechFileInput(name: "conversation-ja").samples
        let clean = try ConversationIdentity.measure(fixture: "conversation-ja", reference: reference,
            output: reference, outputRate: 48000, referenceOffset: 0)
        XCTAssertTrue(clean.passed)
        for range in [6.744958333333333..<6.9925625, 8.9925625..<9.26125] {
            var broken = reference
            for index in Int(range.lowerBound * 48000)..<Int(range.upperBound * 48000) { broken[index] = 0 }
            XCTAssertFalse(try ConversationIdentity.measure(fixture: "conversation-ja", reference: reference,
                output: broken, outputRate: 48000, referenceOffset: 0).passed)
        }
    }
}
