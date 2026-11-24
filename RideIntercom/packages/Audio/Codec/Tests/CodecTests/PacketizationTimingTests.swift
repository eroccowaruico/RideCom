import AudioCore
import Foundation
import Testing
@testable import Codec

@Test func packetizationTimingReservesOnlyTheCaptureCodecRemainder() {
    for (native, quantum, expected) in [(480, 320, 160), (480, 960, 0), (240, 960, 0), (480, 480, 0), (480, 256, 224)] {
        var timing = CodecPacketizationTiming(nativeFrames: native)
        timing.observe(quantumFrames: quantum)
        #expect(timing.jitterFrames == expected)
    }
}

@Test func aac16kCarriesItsTenMillisecondPacketizationVariationWithoutChangingAudio() throws {
    let format = AudioFormat(sampleRate: 16000, channelCount: 1)
    let encoder = try StreamingCodecEncoder(configuration: .init(codec: .mpeg4AACELD, format: format))
    let decoder = StreamingCodecDecoder()
    var packets = 0
    for index in 0..<20 {
        let frame = PCMFrame(sequenceNumber: UInt64(index), format: format, capturedAt: Double(index) * 0.02,
            samples: Array(repeating: 0.1, count: 320))
        if let packet = try encoder.encode(frame) {
            _ = try decoder.decode(packet)
            #expect(abs(decoder.packetizationJitterDuration - 0.01) < 1e-9)
            packets += 1
        }
    }
    #expect(packets > 10)
}

@Test func alignedCodecTimingAddsNoPayloadFieldAndRejectsOversizedTiming() throws {
    let encoder = try StreamingCodecEncoder(configuration: .init(codec: .mpeg4AACELD))
    let decoder = StreamingCodecDecoder()
    var checked = false
    for index in 0..<8 {
        guard var packet = try encoder.encode(.init(sequenceNumber: UInt64(index), capturedAt: Double(index) * 0.01,
            samples: Array(repeating: 0.1, count: 480))) else { continue }
        var envelope = try CompressedPayloadEnvelope.decode(packet.payload, expectedCodec: .mpeg4AACELD)
        #expect(envelope.packetizationJitterFrames == nil)
        let object = try #require(JSONSerialization.jsonObject(with: packet.payload) as? [String: Any])
        #expect(object["j"] == nil, "Aligned packetization must not add recurring wire cost")
        _ = try decoder.decode(packet)
        #expect(decoder.packetizationJitterDuration == 0)
        envelope.packetizationJitterFrames = 481
        packet.payload = try envelope.encoded()
        #expect(throws: CodecError.self) { try decoder.decode(packet) }
        checked = true
        break
    }
    #expect(checked)
}

@Test func aacDiscontinuityDropsTimingFromAnAbandonedPartialFrame() throws {
    let encoder = try StreamingCodecEncoder(configuration: .init(codec: .mpeg4AACELD))
    let decoder = StreamingCodecDecoder()
    let partial = try encoder.encode(.init(sequenceNumber: 0, capturedAt: 0,
        samples: Array(repeating: 0.1, count: 320)))
    #expect((partial?.sampleCount ?? 0) == 0, "The partial PCM has not produced playable audio")

    var packets = 0
    for index in 0..<8 {
        guard let packet = try encoder.encode(.init(sequenceNumber: UInt64(index + 1),
            capturedAt: 5 + Double(index) * 0.01, samples: Array(repeating: 0.1, count: 480))) else { continue }
        let envelope = try CompressedPayloadEnvelope.decode(packet.payload, expectedCodec: .mpeg4AACELD)
        #expect(envelope.packetizationJitterFrames == nil)
        _ = try decoder.decode(packet)
        #expect(decoder.packetizationJitterDuration == 0)
        packets += 1
    }
    #expect(packets > 5)
}
