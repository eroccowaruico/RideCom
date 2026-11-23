import AudioCore
@preconcurrency import AVFAudio
import Foundation

enum MixerPCMNormalizer {
	static func normalize(
		_ frame: PCMFrame,
		to targetFormat: AudioFormat,
		operation: AudioProcessingOperation
	) throws -> (frame: PCMFrame, report: AudioProcessingReport) {
		guard targetFormat.isValid else {
            throw AudioProcessingFailure(
                operation: operation, sourceFormat: frame.format, targetFormat: targetFormat,
                reason: "invalid target format")
		}
		do {
			_ = try frame.validated()
		} catch let failure as AudioProcessingFailure {
			throw AudioProcessingFailure(
				operation: operation,
				sourceFormat: failure.sourceFormat,
				targetFormat: targetFormat,
				reason: failure.reason
			)
		}

		let normalized: PCMFrame
		if frame.format == targetFormat {
			normalized = frame
		} else {
			let samples = frame.samples.isEmpty ? [] : normalizedSamples(frame, to: targetFormat)
			normalized = PCMFrame(sequenceNumber: frame.sequenceNumber, format: targetFormat,
								  capturedAt: frame.capturedAt, samples: samples)
		}
		return (normalized, AudioProcessingReport(
			operation: operation, sourceFormat: frame.format, targetFormat: targetFormat,
			inputSampleCount: frame.samples.count, outputSampleCount: normalized.samples.count,
			result: frame.format == targetFormat ? .notRequired : .applied
		))
	}

	private static func normalizedSamples(_ frame: PCMFrame, to targetFormat: AudioFormat) -> [Float] {
		let channelConverted = convertChannels(
			frame.samples,
			sourceChannelCount: frame.format.channelCount,
			targetChannelCount: targetFormat.channelCount
		)
		let sourceFrameCount = frame.samples.count / frame.format.channelCount
		return resample(
			channelConverted,
			sourceFrameCount: sourceFrameCount,
			sourceSampleRate: frame.format.sampleRate,
			targetSampleRate: targetFormat.sampleRate,
			channelCount: targetFormat.channelCount
		)
	}

	static func convertChannels(
		_ samples: [Float],
		sourceChannelCount: Int,
		targetChannelCount: Int
	) -> [Float] {
		guard sourceChannelCount != targetChannelCount else {
			return samples
		}
		let sourceFrameCount = samples.count / sourceChannelCount
		var converted: [Float] = []
		converted.reserveCapacity(sourceFrameCount * targetChannelCount)

		for frameIndex in 0..<sourceFrameCount {
			let sourceOffset = frameIndex * sourceChannelCount
			if targetChannelCount == 1 {
				var sum: Double = 0
				for channelIndex in 0..<sourceChannelCount {
					sum += Double(samples[sourceOffset + channelIndex])
				}
				converted.append(Float(sum / Double(sourceChannelCount)))
			} else {
				for channelIndex in 0..<targetChannelCount {
					let sourceChannel = min(channelIndex, sourceChannelCount - 1)
					converted.append(samples[sourceOffset + sourceChannel])
				}
			}
		}
		return converted
	}

	private static func resample(
		_ samples: [Float],
		sourceFrameCount: Int,
		sourceSampleRate: Double,
		targetSampleRate: Double,
		channelCount: Int
	) -> [Float] {
		guard sourceSampleRate != targetSampleRate else {
			return samples
		}
		let targetFrameCount = max(
			1,
			Int((Double(sourceFrameCount) * targetSampleRate / sourceSampleRate).rounded())
		)
		var resampled: [Float] = []
		resampled.reserveCapacity(targetFrameCount * channelCount)

		for targetFrameIndex in 0..<targetFrameCount {
			let sourcePosition = Double(targetFrameIndex) * sourceSampleRate / targetSampleRate
			let lowerFrameIndex = min(sourceFrameCount - 1, Int(sourcePosition.rounded(.down)))
			let upperFrameIndex = min(sourceFrameCount - 1, lowerFrameIndex + 1)
			let fraction = Float(sourcePosition - Double(lowerFrameIndex))

			for channelIndex in 0..<channelCount {
				let lower = samples[lowerFrameIndex * channelCount + channelIndex]
				let upper = samples[upperFrameIndex * channelCount + channelIndex]
				resampled.append(Float(Double(lower) * (1 - Double(fraction)) + Double(upper) * Double(fraction)))
			}
		}
		return resampled
	}
}

extension AudioFormat {
	init(avAudioFormat: AVAudioFormat) {
		self.init(
			sampleRate: avAudioFormat.sampleRate,
			channelCount: Int(avAudioFormat.channelCount)
		)
	}
}

extension PCMFrame {
	init?(
		buffer: AVAudioPCMBuffer,
		sequenceNumber: UInt64,
		capturedAt: TimeInterval
	) {
		guard let channelData = buffer.floatChannelData else { return nil }
		let format = AudioFormat(avAudioFormat: buffer.format)
		let frameLength = Int(buffer.frameLength)
		let samples: [Float]
        if format.channelCount == 1 || buffer.format.isInterleaved {
            samples = Array(UnsafeBufferPointer(start: channelData[0], count: frameLength * format.channelCount))
        } else {
            var interleaved: [Float] = []
            interleaved.reserveCapacity(frameLength * format.channelCount)
            for frameIndex in 0..<frameLength {
                for channelIndex in 0..<format.channelCount {
                    interleaved.append(channelData[channelIndex][frameIndex])
                }
            }
            samples = interleaved
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
			throw AudioMixerError.formatCreationFailed(format)
		}
		return buffer
	}
}
