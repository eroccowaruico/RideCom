import AudioCore
import CoreAudioTypes
import CoreMedia
@preconcurrency import AVFAudio
import Foundation

enum AudioConverterBridge {
    static func encode(samples: [Float], codec: CodecIdentifier, format: AudioFormat, bitRate: Int?) throws -> Data {
        guard codec != .pcm16 else { return PCM16Codec.encode(samples) }
        guard !samples.isEmpty else {
            return try CompressedPayloadEnvelope.empty(codec: codec).encoded()
        }

        let frameCount = try avAudioFrameCount(forSampleCount: samples.count, format: format)
        guard let pcmFormat = makePCMFormat(format) else {
            throw CodecError.invalidFormat(format)
        }
        guard let compressedFormat = makeCompressedFormat(codec: codec, format: format, bitRate: bitRate) else {
            throw CodecError.audioFormatCreationFailed(codec)
        }
        let key = AudioConverterPool.Key(encoding: true, codec: codec, format: format, bitRate: bitRate, cookie: nil)
        guard let converter = AudioConverterPool.shared.take(key: key, make: {
            AVAudioConverter(from: pcmFormat, to: compressedFormat)
        }) else { throw CodecError.encoderUnavailable(codec) }
        defer { AudioConverterPool.shared.put(converter, key: key) }

        if let bitRate { converter.bitRate = bitRate }
        guard converter.maximumOutputPacketSize > 0 else { throw CodecError.encoderUnavailable(codec) }
        let inputBuffer = try makePCMBuffer(
            samples: samples, format: format, avFormat: pcmFormat, frameCount: frameCount)
        // The supported codecs use packets of at least 2.5 ms. Include flush
        // packets without allocating one maximum-size packet per PCM sample.
        let packetCapacity = AVAudioPacketCount(ceil(Double(frameCount) / max(1, format.sampleRate * 0.0025))) + 4
        let outputBuffer = AVAudioCompressedBuffer(
            format: compressedFormat,
            packetCapacity: packetCapacity,
            maximumPacketSize: max(1, converter.maximumOutputPacketSize)
        )

        let inputProvider = AudioBufferProvider(inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { requested, inputStatus in
            inputProvider.provide(requested, inputStatus)
        }

        guard status != .error else {
            throw CodecError.conversionFailed(
                codec, conversionError?.localizedDescription ?? "Unknown AudioConverter encode error")
        }

        guard outputBuffer.packetCount > 0, outputBuffer.byteLength > 0 else {
            throw CodecError.conversionFailed(codec, "Encoder returned no audio for a nonempty PCM frame")
        }
        return try CompressedPayloadEnvelope(
            codec: codec,
            sourceSampleCount: samples.count,
            sourceFrameCount: UInt32(frameCount),
            maximumPacketSize: max(1, converter.maximumOutputPacketSize),
            packetCount: outputBuffer.packetCount,
            packetDescriptions: packetDescriptions(from: outputBuffer),
            magicCookie: converter.magicCookie,
            primingFrameCount: converter.primeInfo.leadingFrames,
            data: Data(bytes: outputBuffer.data, count: Int(outputBuffer.byteLength))
        ).encoded()
    }

    static func decode(payload: Data, codec: CodecIdentifier, format: AudioFormat) throws -> [Float] {
        guard codec != .pcm16 else { return try PCM16Codec.decode(payload) }
        guard !payload.isEmpty else { return [] }

        let envelope = try CompressedPayloadEnvelope.decode(payload, expectedCodec: codec)
        guard envelope.sourceSampleCount == Int(envelope.sourceFrameCount) * format.channelCount else {
            throw CodecError.malformedPayload(codec)
        }
        guard !envelope.data.isEmpty else { return [] }
        guard let pcmFormat = makePCMFormat(format) else {
            throw CodecError.invalidFormat(format)
        }
        guard let compressedFormat = makeDecodeFormat(codec: codec, format: format, cookie: envelope.magicCookie) else {
            throw CodecError.audioFormatCreationFailed(codec)
        }
        compressedFormat.magicCookie = envelope.magicCookie
        let key = AudioConverterPool.Key(
            encoding: false, codec: codec, format: format, bitRate: nil, cookie: envelope.magicCookie)
        guard let converter = AudioConverterPool.shared.take(key: key, make: {
            let native = AVAudioConverter(from: compressedFormat, to: pcmFormat)
            native?.magicCookie = envelope.magicCookie
            return native
        }) else { throw CodecError.decoderUnavailable(codec) }
        defer { AudioConverterPool.shared.put(converter, key: key) }

        // Preserve decoder delay explicitly; the packet envelope carries the
        // encoder priming samples that are removed once below.
        converter.primeMethod = .none
        // AAC decoders need the encoder's actual stream configuration.

        let inputBuffer = compressedInput(envelope, format: compressedFormat)
        guard let outputBuffer = AVAudioPCMBuffer(
            pcmFormat: pcmFormat,
            frameCapacity: max(1, envelope.sourceFrameCount + envelope.primingFrameCount)
        ) else {
            throw CodecError.audioFormatCreationFailed(codec)
        }

        let inputProvider = AudioBufferProvider(inputBuffer)
        var conversionError: NSError?
        let status = converter.convert(to: outputBuffer, error: &conversionError) { requested, inputStatus in
            inputProvider.provide(requested, inputStatus)
        }

        guard status != .error else {
            throw CodecError.conversionFailed(
                codec, conversionError?.localizedDescription ?? "Unknown AudioConverter decode error")
        }

        let primingSamples = Int(envelope.primingFrameCount) * format.channelCount
        let decoded = try samples(from: outputBuffer, format: format,
            sampleLimit: envelope.sourceSampleCount + primingSamples)
        guard decoded.count >= envelope.sourceSampleCount + primingSamples else {
            throw CodecError.conversionFailed(
                codec, "Decoder returned fewer samples than the source and priming frames")
        }
        return Array(decoded.dropFirst(primingSamples).prefix(envelope.sourceSampleCount))
    }

    static func compressedInput(_ envelope: CompressedPayloadEnvelope, format: AVAudioFormat)
        -> AVAudioCompressedBuffer {
        let inputBuffer = AVAudioCompressedBuffer(
            format: format,
            packetCapacity: max(1, envelope.packetCount),
            maximumPacketSize: max(1, envelope.maximumPacketSize)
        )
        inputBuffer.byteLength = UInt32(envelope.data.count)
        inputBuffer.packetCount = envelope.packetCount
        envelope.data.withUnsafeBytes { source in
            if let baseAddress = source.baseAddress {
                inputBuffer.data.copyMemory(from: baseAddress, byteCount: envelope.data.count)
            }
        }
        if let destinationDescriptions = inputBuffer.packetDescriptions {
            for (index, description) in envelope.packetDescriptions.enumerated() {
                destinationDescriptions[index] = description.audioStreamPacketDescription
            }
        }
        return inputBuffer
    }

    static func makeDecodeFormat(codec: CodecIdentifier, format: AudioFormat, cookie: Data?) -> AVAudioFormat? {
        guard let initial = makeCompressedFormat(codec: codec, format: format, bitRate: nil) else { return nil }
        guard codec == .mpeg4AACELD || codec == .mpeg4AACELDv2 else { return initial }
        guard let cookie, !cookie.isEmpty else { return nil }
        var description = withExtendedLifetime(initial) { initial.streamDescription.pointee }
        var result: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes {
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &description, layoutSize: 0, layout: nil,
                magicCookieSize: cookie.count, magicCookie: $0.baseAddress, extensions: nil,
                formatDescriptionOut: &result)
        }
        guard status == noErr, let result else { return nil }
        // CoreMedia interprets the native cookie on every supported OS. The
        // basic description alone can still contain zero/default packet frames;
        // the format list preserves AAC's 480/512 frames and ELDv2 core format.
        return withExtendedLifetime(result) {
            guard let compatible = CMAudioFormatDescriptionGetMostCompatibleFormat(result) else { return nil }
            var native = compatible.pointee.mASBD
            // CoreMedia may preserve the caller's incomplete ASBD for an
            // unrecognized cookie. Do not silently decode with that fallback.
            guard native.mFramesPerPacket > 0, native.mSampleRate.isFinite,
                  native.mSampleRate > 0, native.mChannelsPerFrame > 0 else { return nil }
            return AVAudioFormat(streamDescription: &native)
        }
    }

    static func makePCMFormat(_ format: AudioFormat) -> AVAudioFormat? {
        guard format.isValid else { return nil }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            channels: AVAudioChannelCount(format.channelCount),
            interleaved: false
        )
    }

    static func makeCompressedFormat(codec: CodecIdentifier, format: AudioFormat, bitRate: Int?) -> AVAudioFormat? {
        guard format.isValid else { return nil }
        guard codec != .pcm16 else { return makePCMFormat(format) }

        var settings: [String: Any] = [
            AVFormatIDKey: codec.audioFormatID,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount
        ]

        if let bitRate {
            settings[AVEncoderBitRateKey] = bitRate
        }

        return AVAudioFormat(settings: settings)
    }

    private static func avAudioFrameCount(forSampleCount sampleCount: Int, format: AudioFormat) throws
        -> AVAudioFrameCount {
        guard sampleCount.isMultiple(of: format.channelCount) else {
            throw CodecError.invalidSampleCount(sampleCount: sampleCount, channelCount: format.channelCount)
        }
        return AVAudioFrameCount(sampleCount / format.channelCount)
    }

    static func makePCMBuffer(
        samples: [Float],
        format: AudioFormat,
        avFormat: AVAudioFormat,
        frameCount: AVAudioFrameCount
    ) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: avFormat, frameCapacity: frameCount),
              let channels = buffer.floatChannelData else {
            throw CodecError.audioFormatCreationFailed(.pcm16)
        }

        buffer.frameLength = frameCount
        if format.channelCount == 1 {
            samples.withUnsafeBufferPointer { input in
                if let base = input.baseAddress { channels[0].update(from: base, count: Int(frameCount)) }
            }
        } else {
            for frameIndex in 0..<Int(frameCount) {
                for channelIndex in 0..<format.channelCount {
                    channels[channelIndex][frameIndex] = samples[frameIndex * format.channelCount + channelIndex]
                }
            }
        }

        return buffer
    }

    static func samples(from buffer: AVAudioPCMBuffer, format: AudioFormat, sampleLimit: Int) throws -> [Float] {
        guard let channels = buffer.floatChannelData else {
            throw CodecError.audioFormatCreationFailed(.pcm16)
        }

        let frameLength = Int(buffer.frameLength)
        if format.channelCount == 1 {
            return Array(UnsafeBufferPointer(start: channels[0], count: min(frameLength, sampleLimit)))
        }
        var samples: [Float] = []
        samples.reserveCapacity(frameLength * format.channelCount)
        for frameIndex in 0..<frameLength {
            for channelIndex in 0..<format.channelCount {
                samples.append(channels[channelIndex][frameIndex])
            }
        }

        if samples.count > sampleLimit {
            samples.removeLast(samples.count - sampleLimit)
        }
        return samples
    }

    static func packetDescriptions(from buffer: AVAudioCompressedBuffer) -> [CompressedPayloadEnvelope
        .PacketDescription] {
        guard let packetDescriptions = buffer.packetDescriptions else { return [] }
        return (0..<Int(buffer.packetCount)).map { index in
            CompressedPayloadEnvelope.PacketDescription(packetDescriptions[index])
        }
    }
}

final class AudioBufferProvider: @unchecked Sendable {
    private let buffer: AVAudioBuffer
    private var offset: UInt32 = 0
    private let exhausted: AVAudioConverterInputStatus
    init(_ buffer: AVAudioBuffer, exhausted: AVAudioConverterInputStatus = .endOfStream) {
        self.buffer = buffer; self.exhausted = exhausted
    }

    func provide(_ requested: UInt32, _ status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        if let pcm = buffer as? AVAudioPCMBuffer {
            guard offset < pcm.frameLength else { status.pointee = exhausted; return nil }
            let count = min(requested, pcm.frameLength - offset)
            guard let part = AVAudioPCMBuffer(pcmFormat: pcm.format, frameCapacity: count),
                  let input = pcm.floatChannelData, let output = part.floatChannelData else {
                status.pointee = exhausted; return nil
            }
            part.frameLength = count
            for channel in 0..<Int(pcm.format.channelCount) {
                output[channel].update(from: input[channel].advanced(by: Int(offset)), count: Int(count))
            }
            offset += count
            status.pointee = .haveData
            return part
        }
        guard let compressed = buffer as? AVAudioCompressedBuffer, offset < compressed.packetCount,
              let descriptions = compressed.packetDescriptions else {
            status.pointee = exhausted; return nil
        }
        let count = min(requested, compressed.packetCount - offset)
        let part = AVAudioCompressedBuffer(format: compressed.format, packetCapacity: count,
            maximumPacketSize: compressed.maximumPacketSize)
        var bytes = 0
        for index in 0..<Int(count) {
            var description = descriptions[Int(offset) + index]
            part.data.advanced(by: bytes).copyMemory(from: compressed.data.advanced(by: Int(description.mStartOffset)),
                byteCount: Int(description.mDataByteSize))
            description.mStartOffset = Int64(bytes)
            part.packetDescriptions?[index] = description
            bytes += Int(description.mDataByteSize)
        }
        part.packetCount = count
        part.byteLength = UInt32(bytes)
        offset += count
        status.pointee = .haveData
        return part
    }
}
