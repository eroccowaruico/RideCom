import AudioCore
@preconcurrency import AVFAudio
import Foundation

public final class MixerPCMSink {
	public let id: String
	public let mixerFormat: AudioFormat
	public internal(set) var targetFormat: AudioFormat

	private let onFrame: (PCMFrame, AudioProcessingReport) -> Void
	private let recordEmit: (AudioProcessingReport?, String?) -> Void
	private let packetDuration: TimeInterval?
    private let maximumFrameDuration: TimeInterval?
	private var nextSequenceNumber: UInt64 = 0
	private let streamingNormalizer = MixerPCMStreamNormalizer()
	private var pendingSamples: [Float] = []
	private var pendingCapturedAt: TimeInterval = 0
    private var transition = PCMStreamTransition()

    /// An upstream stream reset discards unsent audio, never flushes it late.
    func resetStream() {
        pendingSamples.removeAll(keepingCapacity: true)
        streamingNormalizer.reset()
        transition.reset()
    }

    func beginTransition(settlingDuration: TimeInterval, holding: Bool = false) {
        transition.begin(settlingDuration: settlingDuration, holding: holding)
    }

	init(
		id: String,
		mixerFormat: AudioFormat,
		targetFormat: AudioFormat,
		packetDuration: TimeInterval?,
		maximumFrameDuration: TimeInterval?,
		onFrame: @escaping (PCMFrame, AudioProcessingReport) -> Void,
		recordEmit: @escaping (AudioProcessingReport?, String?) -> Void
	) {
		self.id = id
		self.mixerFormat = mixerFormat
		self.targetFormat = targetFormat
		self.packetDuration = packetDuration
        self.maximumFrameDuration = maximumFrameDuration
		self.onFrame = onFrame
		self.recordEmit = recordEmit
	}

	@discardableResult
	func receive(_ mixerFrame: PCMFrame) throws -> AudioProcessingReport {
        let mixerFrame = transition.process(mixerFrame)
		guard let duration = packetDuration, !mixerFrame.samples.isEmpty else {
			return try emit(mixerFrame)
		}
		_ = try mixerFrame.validated()
        let rate = mixerFrame.format.sampleRate
        let channels = mixerFrame.format.channelCount
        let count = max(1, Int((rate * duration).rounded(.down))) * channels
        var report: AudioProcessingReport?
        if !pendingSamples.isEmpty {
            let expected = pendingCapturedAt + Double(pendingSamples.count / channels) / rate
            if abs(mixerFrame.capturedAt - expected) > 2 / rate {
                report = try emit(.init(sequenceNumber: nextSequenceNumber, format: mixerFrame.format,
                    capturedAt: pendingCapturedAt, samples: pendingSamples))
                nextSequenceNumber &+= 1
                pendingSamples.removeAll(keepingCapacity: true)
            }
        }
        if pendingSamples.isEmpty { pendingCapturedAt = mixerFrame.capturedAt }
        pendingSamples.append(contentsOf: mixerFrame.samples)
        // Packetize before sample-rate conversion. Rounding each 512-frame
        // quantum independently at 16 kHz adds samples and overlaps the next
        // packet. Exact-duration packets preserve both sample and capture clocks.
        while pendingSamples.count >= count {
            report = try emit(.init(sequenceNumber: nextSequenceNumber, format: mixerFrame.format,
                capturedAt: pendingCapturedAt, samples: Array(pendingSamples.prefix(count))))
            nextSequenceNumber &+= 1
            pendingSamples.removeFirst(count)
            pendingCapturedAt += Double(count / channels) / rate
        }
        return report ?? AudioProcessingReport(operation: .normalizeSink,
            sourceFormat: mixerFrame.format, targetFormat: targetFormat,
            inputSampleCount: mixerFrame.samples.count, outputSampleCount: 0, result: .notRequired)
    }

	private func emit(_ mixerFrame: PCMFrame) throws -> AudioProcessingReport {
		do {
			let normalized = try packetDuration == nil
                ? streamingNormalizer.normalize(mixerFrame, to: targetFormat, operation: .normalizeSink)
                : MixerPCMNormalizer.normalize(mixerFrame, to: targetFormat, operation: .normalizeSink)
            let frame = normalized.frame
            let limit = maximumFrameDuration.map {
                max(1, Int($0 * targetFormat.sampleRate)) * targetFormat.channelCount
            }
                ?? max(1, frame.samples.count)
            for start in stride(from: 0, to: frame.samples.count, by: limit) {
                let samples = Array(frame.samples[start..<min(frame.samples.count, start + limit)])
                var report = normalized.report
                report.inputSampleCount = start == 0 ? normalized.report.inputSampleCount : 0
                report.outputSampleCount = samples.count
                recordEmit(report, nil)
                onFrame(.init(sequenceNumber: frame.sequenceNumber, format: targetFormat,
                    capturedAt: frame.capturedAt + Double(start / targetFormat.channelCount) / targetFormat.sampleRate,
                    samples: samples), report)
            }
			return normalized.report
		} catch let failure as AudioProcessingFailure {
			recordEmit(nil, failure.reason)
			throw failure
		} catch {
			recordEmit(nil, String(describing: error))
			throw AudioMixerError.pcmSinkInstallFailed(String(describing: error))
		}
	}
}
