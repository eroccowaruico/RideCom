import AudioCore
import CoreAudioTypes
import Foundation

public enum CodecError: Error, Equatable, Sendable {
    case invalidSampleCount(sampleCount: Int, channelCount: Int)
    case invalidByteCount
    case invalidFormat(AudioFormat)
    case formatMismatch(expected: AudioFormat, actual: AudioFormat)
    case unsupportedCodec(CodecIdentifier)
    case encoderUnavailable(CodecIdentifier)
    case decoderUnavailable(CodecIdentifier)
    case audioFormatCreationFailed(CodecIdentifier)
    case conversionFailed(CodecIdentifier, String)
    case malformedPayload(CodecIdentifier)
}

public enum CodecIdentifier: String, Codable, CaseIterable, Equatable, Sendable {
    case pcm16
    case mpeg4AACELD
    case mpeg4AACELDv2
    case opus

    public var displayName: String {
        switch self {
        case .pcm16:
            "PCM 16-bit"
        case .mpeg4AACELD:
            "MPEG-4 AAC-ELD"
        case .mpeg4AACELDv2:
            "MPEG-4 AAC-ELD v2"
        case .opus:
            "Opus"
        }
    }

    public var audioFormatID: AudioFormatID {
        switch self {
        case .pcm16:
            kAudioFormatLinearPCM
        case .mpeg4AACELD:
            kAudioFormatMPEG4AAC_ELD
        case .mpeg4AACELDv2:
            kAudioFormatMPEG4AAC_ELD_V2
        case .opus:
            kAudioFormatOpus
        }
    }
}

public struct AACELDv2Options: Codable, Equatable, Sendable {
    public static let allowedBitRateRange: ClosedRange<Int> = 12_000...128_000

    public var bitRate: Int

    public init(bitRate: Int = 32_000) {
        self.bitRate = Self.clamp(bitRate, Self.allowedBitRateRange)
    }

    private static func clamp(_ value: Int, _ range: ClosedRange<Int>) -> Int {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

public struct OpusOptions: Codable, Equatable, Sendable {
    // Product-supported range, not the native encoder's technical minimum.
    // 24/32 kbps permit manually chosen quality loss; 48 kbps remains the
    // default and the reference for the existing waveform-fidelity tests.
    public static let allowedBitRateRange: ClosedRange<Int> = 24_000...128_000

    public var bitRate: Int {
        didSet { bitRate = min(max(bitRate, Self.allowedBitRateRange.lowerBound), Self.allowedBitRateRange.upperBound) }
    }

    public init(bitRate: Int = 48_000) {
        self.bitRate = min(max(bitRate, Self.allowedBitRateRange.lowerBound), Self.allowedBitRateRange.upperBound)
    }

    private enum CodingKeys: String, CodingKey { case bitRate }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(bitRate: try values.decode(Int.self, forKey: .bitRate))
    }
}

public struct CodecEncodingConfiguration: Codable, Equatable, Sendable {
    public var codec: CodecIdentifier
    public var format: AudioFormat
    public var aacELDv2Options: AACELDv2Options
    public var opusOptions: OpusOptions

    public init(
        codec: CodecIdentifier = .pcm16,
        format: AudioFormat = AudioFormat(),
        aacELDv2Options: AACELDv2Options = AACELDv2Options(),
        opusOptions: OpusOptions = OpusOptions()
    ) {
        self.codec = codec
        self.format = format
        self.aacELDv2Options = aacELDv2Options
        self.opusOptions = opusOptions
    }

    public var activeBitRate: Int? {
        switch codec {
        case .pcm16:
            nil
        case .mpeg4AACELD, .mpeg4AACELDv2:
            aacELDv2Options.bitRate
        case .opus:
            opusOptions.bitRate
        }
    }
}

public struct EncodedCodecFrame: Codable, Equatable, Sendable {
    public var sequenceNumber: UInt64
    public var codec: CodecIdentifier
    public var format: AudioFormat
    public var capturedAt: TimeInterval
    public var sampleCount: Int
    public var bitRate: Int?
    public var payload: Data

    public init(
        sequenceNumber: UInt64,
        codec: CodecIdentifier,
        format: AudioFormat,
        capturedAt: TimeInterval,
        sampleCount: Int,
        bitRate: Int? = nil,
        payload: Data
    ) {
        self.sequenceNumber = sequenceNumber
        self.codec = codec
        self.format = format
        self.capturedAt = capturedAt
        self.sampleCount = max(0, sampleCount)
        self.bitRate = bitRate.map { max(0, $0) }
        self.payload = payload
    }

    public var metadata: EncodedAudioMetadata {
        EncodedAudioMetadata(
            sequenceNumber: sequenceNumber,
            codec: codec.rawValue,
            format: format,
            capturedAt: capturedAt,
            sampleCount: sampleCount,
            bitRate: bitRate
        )
    }
}

struct CompressedPayloadEnvelope: Codable, Equatable, Sendable {
    // Foundation retains parsing/validation. Compact keys remove repeated field
    // names without a bespoke binary parser or a reliable side-channel dictionary.
    private enum CodingKeys: String, CodingKey {
        case streamID = "i", codec = "c", sourceSampleCount = "s", sourceFrameCount = "f"
        case maximumPacketSize = "m", packetCount = "n", packetDescriptions = "p"
        case magicCookie = "k", primingFrameCount = "r", data = "d"
        case packetizationJitterFrames = "j"
    }
    struct PacketDescription: Codable, Equatable, Sendable {
        var startOffset: Int64
        var variableFramesInPacket: UInt32
        var dataByteSize: UInt32

        init(_ description: AudioStreamPacketDescription) {
            self.startOffset = description.mStartOffset
            self.variableFramesInPacket = description.mVariableFramesInPacket
            self.dataByteSize = description.mDataByteSize
        }

        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            startOffset = try values.decode(Int64.self)
            variableFramesInPacket = try values.decode(UInt32.self)
            dataByteSize = try values.decode(UInt32.self)
            guard values.isAtEnd else {
                throw DecodingError.dataCorruptedError(in: values, debugDescription: "Invalid packet description")
            }
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.unkeyedContainer()
            try values.encode(startOffset)
            try values.encode(variableFramesInPacket)
            try values.encode(dataByteSize)
        }

        var audioStreamPacketDescription: AudioStreamPacketDescription {
            AudioStreamPacketDescription(
                mStartOffset: startOffset,
                mVariableFramesInPacket: variableFramesInPacket,
                mDataByteSize: dataByteSize
            )
        }
    }

    var streamID: UUID?
    var codec: CodecIdentifier
    var sourceSampleCount: Int
    var sourceFrameCount: UInt32
    var maximumPacketSize: Int
    var packetCount: UInt32
    var packetDescriptions: [PacketDescription]
    var magicCookie: Data?
    var primingFrameCount: UInt32
    var packetizationJitterFrames: UInt32?
    var data: Data

    static func empty(codec: CodecIdentifier) -> CompressedPayloadEnvelope {
        CompressedPayloadEnvelope(
            codec: codec,
            sourceSampleCount: 0,
            sourceFrameCount: 0,
            maximumPacketSize: 1,
            packetCount: 0,
            packetDescriptions: [],
            primingFrameCount: 0,
            data: Data()
        )
    }

    func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    static func decode(_ data: Data, expectedCodec: CodecIdentifier) throws -> CompressedPayloadEnvelope {
        do {
            let envelope = try JSONDecoder().decode(CompressedPayloadEnvelope.self, from: data)
            guard envelope.codec == expectedCodec else {
                throw CodecError.malformedPayload(expectedCodec)
            }
            guard
                envelope.packetDescriptions.isEmpty
                    || envelope.packetDescriptions.count == Int(envelope.packetCount)
            else {
                throw CodecError.malformedPayload(expectedCodec)
            }
            // Validate every size before AVAudioCompressedBuffer allocation and memcpy.
            let count = Int(envelope.packetCount)
            guard envelope.sourceFrameCount <= CodecDecoder.maximumDecodedFrameCount,
                  (envelope.packetizationJitterFrames ?? 0) <= (expectedCodec == .mpeg4AACELDv2 ? 1024 : 480),
                  envelope.primingFrameCount <= 8_192,
                  (envelope.magicCookie?.count ?? 0) <= 16_384,
                  envelope.sourceSampleCount >= 0,
                  envelope.maximumPacketSize > 0,
                  envelope.maximumPacketSize <= CodecDecoder.maximumPayloadBytes,
                  count <= CodecDecoder.maximumPayloadBytes / envelope.maximumPacketSize,
                  envelope.data.count <= count * envelope.maximumPacketSize else {
                throw CodecError.malformedPayload(expectedCodec)
            }
            if envelope.data.isEmpty {
                guard count == 0, envelope.sourceFrameCount == 0, envelope.sourceSampleCount == 0,
                      envelope.packetDescriptions.isEmpty else { throw CodecError.malformedPayload(expectedCodec) }
            } else {
                guard count > 0, envelope.sourceFrameCount > 0 else { throw CodecError.malformedPayload(expectedCodec) }
                for packet in envelope.packetDescriptions {
                    guard packet.startOffset >= 0, packet.startOffset <= envelope.data.count,
                          packet.dataByteSize > 0,
                          packet.dataByteSize <= envelope.maximumPacketSize,
                          Int(packet.dataByteSize) <= envelope.data.count - Int(packet.startOffset),
                          packet.variableFramesInPacket <= CodecDecoder.maximumDecodedFrameCount else {
                        throw CodecError.malformedPayload(expectedCodec)
                    }
                }
            }
            return envelope
        } catch let error as CodecError {
            throw error
        } catch {
            throw CodecError.malformedPayload(expectedCodec)
        }
    }
}
