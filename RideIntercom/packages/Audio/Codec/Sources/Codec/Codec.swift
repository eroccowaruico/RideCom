import AudioCore
@preconcurrency import AVFAudio
import Foundation

public enum CodecSupport {
    public static func availableEncodingBitRates(codec: CodecIdentifier, format: AudioFormat) -> [Int] {
        guard codec != .pcm16, let input = AudioConverterBridge.makePCMFormat(format),
              let output = AudioConverterBridge.makeCompressedFormat(codec: codec, format: format, bitRate: nil),
              let converter = AVAudioConverter(from: input, to: output) else { return [] }
        return Array(Set((converter.applicableEncodeBitRates ?? []).map(\.intValue).filter { $0 > 0 })).sorted()
    }

    public static func isEncodingAvailable(for configuration: CodecEncodingConfiguration) -> Bool {
        guard configuration.format.isValid else { return false }
        switch configuration.codec {
        case .pcm16:
            return true
        case .mpeg4AACELD, .mpeg4AACELDv2, .opus:
            guard let pcmFormat = AudioConverterBridge.makePCMFormat(configuration.format),
                  let compressedFormat = AudioConverterBridge.makeCompressedFormat(
                    codec: configuration.codec,
                    format: configuration.format,
                    bitRate: configuration.activeBitRate
                  ) else {
                return false
            }
            guard AVAudioConverter(from: pcmFormat, to: compressedFormat) != nil else { return false }
            // Constructing a converter does not prove that this format/bit rate
            // can encode. In particular, ELD v2 can instantiate for mono and
            // then fail every conversion with kAudioCodecBadDataError.
            return (try? AudioConverterBridge.encode(samples: probeSamples(configuration.format),
                codec: configuration.codec, format: configuration.format,
                bitRate: configuration.activeBitRate)) != nil
        }
    }

    private static func probeSamples(_ format: AudioFormat) -> [Float] {
        let frames = max(1, Int(format.sampleRate * 0.02))
        return (0..<(frames * format.channelCount)).map { index in
            Float(sin(Double(index / format.channelCount) * 2 * .pi * 440 / format.sampleRate) * 0.25)
        }
    }

    static func isRoundTripAvailable(for configuration: CodecEncodingConfiguration) -> Bool {
        guard configuration.format.isValid else { return false }
        if configuration.codec == .pcm16 { return true }
        let input = probeSamples(configuration.format)
        do {
            let payload = try AudioConverterBridge.encode(samples: input, codec: configuration.codec,
                format: configuration.format, bitRate: configuration.activeBitRate)
            let output = try AudioConverterBridge.decode(
                payload: payload, codec: configuration.codec, format: configuration.format)
            return output.count == input.count && output.allSatisfy { $0.isFinite }
                && output.contains { abs($0) > 0.01 }
        } catch {
            return false
        }
    }

    public static func isDecodingAvailable(
        for codec: CodecIdentifier,
        format: AudioFormat = AudioFormat()
    ) -> Bool {
        guard format.isValid else { return false }
        switch codec {
        case .pcm16:
            return true
        case .mpeg4AACELD, .mpeg4AACELDv2, .opus:
            guard let pcmFormat = AudioConverterBridge.makePCMFormat(format),
                let compressedFormat = AudioConverterBridge.makeCompressedFormat(
                    codec: codec, format: format, bitRate: nil)
            else {
                return false
            }
            return AVAudioConverter(from: compressedFormat, to: pcmFormat) != nil
        }
    }
}

public struct CodecRuntimeReport: Codable, Equatable, Sendable {
    public var requestedConfiguration: CodecEncodingConfiguration
    public var activeConfiguration: CodecEncodingConfiguration
    public var availableCodecs: [CodecIdentifier]
    public var selectedCodec: CodecIdentifier
    public var isFallback: Bool

    public init(
        requestedConfiguration: CodecEncodingConfiguration,
        activeConfiguration: CodecEncodingConfiguration,
        availableCodecs: [CodecIdentifier],
        selectedCodec: CodecIdentifier,
        isFallback: Bool
    ) {
        self.requestedConfiguration = requestedConfiguration
        self.activeConfiguration = activeConfiguration
        self.availableCodecs = availableCodecs
        self.selectedCodec = selectedCodec
        self.isFallback = isFallback
    }

    public static func resolving(
        _ requestedConfiguration: CodecEncodingConfiguration,
        fallbackCodec: CodecIdentifier = .pcm16
    ) -> CodecRuntimeReport {
        let availableCodecs = CodecIdentifier.allCases.filter {
            let configuration = CodecEncodingConfiguration(
                codec: $0,
                format: requestedConfiguration.format,
                aacELDv2Options: requestedConfiguration.aacELDv2Options,
                opusOptions: requestedConfiguration.opusOptions
            )
            return CodecSupport.isRoundTripAvailable(for: configuration)
        }

        let selectedCodec: CodecIdentifier
        if availableCodecs.contains(requestedConfiguration.codec) {
            selectedCodec = requestedConfiguration.codec
        } else if availableCodecs.contains(fallbackCodec) {
            selectedCodec = fallbackCodec
        } else {
            selectedCodec = .pcm16
        }

        let activeConfiguration = CodecEncodingConfiguration(
            codec: selectedCodec,
            format: requestedConfiguration.format,
            aacELDv2Options: requestedConfiguration.aacELDv2Options,
            opusOptions: requestedConfiguration.opusOptions
        )

        return CodecRuntimeReport(
            requestedConfiguration: requestedConfiguration,
            activeConfiguration: activeConfiguration,
            availableCodecs: availableCodecs,
            selectedCodec: selectedCodec,
            isFallback: selectedCodec != requestedConfiguration.codec
        )
    }
}

public final class CodecEncoder {
    public private(set) var configuration: CodecEncodingConfiguration

    public init(configuration: CodecEncodingConfiguration = CodecEncodingConfiguration()) {
        self.configuration = configuration
    }

    public func apply(_ configuration: CodecEncodingConfiguration) {
        self.configuration = configuration
    }

    public func encode(_ frame: PCMFrame) throws -> EncodedCodecFrame {
        try validate(frame)

        let payload: Data
        switch configuration.codec {
        case .pcm16:
            payload = PCM16Codec.encode(frame.samples)
        case .mpeg4AACELD, .mpeg4AACELDv2, .opus:
            payload = try AudioConverterBridge.encode(
                samples: frame.samples,
                codec: configuration.codec,
                format: frame.format,
                bitRate: configuration.activeBitRate
            )
        }

        return EncodedCodecFrame(
            sequenceNumber: frame.sequenceNumber,
            codec: configuration.codec,
            format: frame.format,
            capturedAt: frame.capturedAt,
            sampleCount: frame.samples.count,
            bitRate: configuration.activeBitRate,
            payload: payload
        )
    }

    private func validate(_ frame: PCMFrame) throws {
        if frame.format != configuration.format {
            throw CodecError.formatMismatch(expected: configuration.format, actual: frame.format)
        }
        do {
            _ = try frame.validated()
        } catch {
            throw CodecError.invalidSampleCount(
                sampleCount: frame.samples.count,
                channelCount: frame.format.channelCount
            )
        }
    }
}

public final class CodecDecoder {
    /// Bounds untrusted compressed allocation to one second of the supported PCM range.
    public static let maximumDecodedFrameCount = 96_000
    public static let maximumPayloadBytes = 1_048_576
    public init() {}

    public func decode(_ frame: EncodedCodecFrame) throws -> PCMFrame {
        guard frame.format.isValid else { throw CodecError.invalidFormat(frame.format) }
        guard frame.payload.count <= Self.maximumPayloadBytes, frame.capturedAt.isFinite,
              frame.sampleCount >= 0,
              frame.sampleCount <= Self.maximumDecodedFrameCount * frame.format.channelCount else {
            throw CodecError.malformedPayload(frame.codec)
        }
        let samples: [Float]
        switch frame.codec {
        case .pcm16:
            samples = try PCM16Codec.decode(frame.payload)
        case .mpeg4AACELD, .mpeg4AACELDv2, .opus:
            samples = try AudioConverterBridge.decode(payload: frame.payload, codec: frame.codec, format: frame.format)
        }

        let decoded = PCMFrame(
            sequenceNumber: frame.sequenceNumber,
            format: frame.format,
            capturedAt: frame.capturedAt,
            samples: samples
        )
        do {
            _ = try decoded.validated()
        } catch {
            throw CodecError.invalidSampleCount(
                sampleCount: decoded.samples.count,
                channelCount: decoded.format.channelCount
            )
        }
        return decoded
    }
}

public enum PCM16Codec {
    public static func encode(_ samples: [Float]) -> Data {
        var data = Data()
        data.reserveCapacity(samples.count * MemoryLayout<Int16>.size)

        for sample in samples {
            let clamped = sample.isFinite ? min(1, max(-1, sample)) : 0
            let scale: Float = clamped < 0 ? 32_768 : 32_767
            let rounded = Int((clamped * scale).rounded(.toNearestOrAwayFromZero))
            let bounded = min(Int(Int16.max), max(Int(Int16.min), rounded))
            let encoded = Int16(bounded).littleEndian
            data.append(UInt8(truncatingIfNeeded: encoded))
            data.append(UInt8(truncatingIfNeeded: encoded >> 8))
        }

        return data
    }

    public static func decode(_ data: Data) throws -> [Float] {
        guard data.count.isMultiple(of: MemoryLayout<Int16>.size) else {
            throw CodecError.invalidByteCount
        }

        return stride(from: 0, to: data.count, by: MemoryLayout<Int16>.size).map { offset in
            let low = UInt16(data[data.startIndex + offset])
            let high = UInt16(data[data.startIndex + offset + 1]) << 8
            let rawValue = Int16(littleEndian: Int16(bitPattern: low | high))
            if rawValue == Int16.min {
                return -1
            }
            if rawValue < 0 {
                return Float(rawValue) / 32_768
            }
            return Float(rawValue) / Float(Int16.max)
        }
    }
}
