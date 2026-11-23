import AVFAudio

extension AudioFormat {
    public func makePlanarFloat32Format() -> AVAudioFormat? {
        guard isValid else { return nil }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channelCount),
            interleaved: false
        )
    }
}

extension PCMFrame {
    /// Copies interleaved samples into channel planes without resampling or mixing.
    public func makePlanarFloat32Buffer() throws -> AVAudioPCMBuffer? {
        _ = try validated()
        guard let nativeFormat = format.makePlanarFloat32Format(),
              let capacity = AVAudioFrameCount(exactly: frameCount),
              let buffer = AVAudioPCMBuffer(pcmFormat: nativeFormat, frameCapacity: capacity),
              let channels = buffer.floatChannelData else { return nil }

        buffer.frameLength = capacity
        let channelCount = format.channelCount
        if channelCount == 1 {
            samples.withUnsafeBufferPointer { input in
                if let base = input.baseAddress {
                    channels[0].update(from: base, count: input.count)
                }
            }
        } else {
            for frameIndex in 0..<frameCount {
                for channelIndex in 0..<channelCount {
                    channels[channelIndex][frameIndex] = samples[frameIndex * channelCount + channelIndex]
                }
            }
        }
        return buffer
    }
}
