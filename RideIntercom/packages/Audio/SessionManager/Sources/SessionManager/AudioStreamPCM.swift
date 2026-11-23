import AudioCore
import Foundation

#if canImport(AVFAudio)
@preconcurrency import AVFAudio
#endif

#if canImport(AVFAudio)
extension PCMFrame {
    init?(
        buffer: AVAudioPCMBuffer,
        sequenceNumber: UInt64,
        capturedAt: TimeInterval
    ) {
        guard buffer.format.sampleRate.isFinite, (8000...96000).contains(buffer.format.sampleRate),
              (1...2).contains(buffer.format.channelCount), capturedAt.isFinite,
              let channelData = buffer.floatChannelData else { return nil }
        let format = AudioFormat(avAudioFormat: buffer.format)
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else {
            self.init(sequenceNumber: sequenceNumber, format: format, capturedAt: capturedAt, samples: [])
            return
        }

        let channelCount = Int(buffer.format.channelCount)
        var samples: [Float] = []
        samples.reserveCapacity(frameLength * channelCount)
        for frameIndex in 0..<frameLength {
            for channelIndex in 0..<channelCount {
                samples.append(buffer.format.isInterleaved
                    ? channelData[0][frameIndex * channelCount + channelIndex]
                    : channelData[channelIndex][frameIndex])
            }
        }
        self.init(
            sequenceNumber: sequenceNumber,
            format: format,
            capturedAt: capturedAt,
            samples: samples
        )
    }

    func makePCMBuffer() throws -> AVAudioPCMBuffer {
        guard let buffer = try makePlanarFloat32Buffer() else {
            throw AudioStreamError.invalidFrame("failed to create PCM buffer")
        }
        return buffer
    }
}

extension AudioFormat {
    init(avAudioFormat: AVAudioFormat, fallback: AudioFormat = AudioFormat()) {
        let sampleRate = avAudioFormat.sampleRate
        let channelCount = Int(avAudioFormat.channelCount)
        if sampleRate > 0, channelCount > 0 {
            self.init(sampleRate: sampleRate, channelCount: channelCount)
        } else {
            self = fallback
        }
    }
}
#endif
