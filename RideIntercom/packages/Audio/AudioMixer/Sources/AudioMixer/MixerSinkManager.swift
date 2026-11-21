import AudioCore
@preconcurrency import AVFAudio
import Foundation

/// Owns sink delivery, capture and metadata; the bus supplies its shared recursive lock.
final class MixerSinkManager {
    private unowned let engine: AVAudioEngine
    private let format: AVAudioFormat
    private let audioFormat: AudioFormat
    private let faderMixer: AVAudioMixerNode
    private let renderClock: MixerRenderClock
    private let metadataLock: NSRecursiveLock
    private var sinkOrder: [String] = []
    private var sinksByID: [String: MixerPCMSink] = [:]
    private var sinkMetadataByID: [String: MixerSinkMetadata] = [:]
    private var nextSinkSequence = 0
    private var renderCapture: RenderCaptureNode?

    init(engine: AVAudioEngine, format: AVAudioFormat, audioFormat: AudioFormat,
         faderMixer: AVAudioMixerNode, renderClock: MixerRenderClock, metadataLock: NSRecursiveLock) {
        self.engine = engine
        self.format = format
        self.audioFormat = audioFormat
        self.faderMixer = faderMixer
        self.renderClock = renderClock
        self.metadataLock = metadataLock
    }

    var outputNode: AVAudioNode { renderCapture?.node ?? faderMixer }
    var droppedCaptureFrameCount: Int { renderCapture?.droppedFrameCount ?? 0 }

    func detach() {
        if let capture = renderCapture {
            engine.disconnectNodeInput(capture.node)
            engine.disconnectNodeOutput(capture.node)
            engine.detach(capture.node)
        }
        renderCapture = nil
    }

    // The bus holds metadataLock while resetting the complete processing graph.
    func resetStreams() { sinksByID.values.forEach { $0.resetStream() } }

	@discardableResult
	func installPCMSink(
		id sinkID: String,
		targetFormat: AudioFormat,
		bufferFrameCount: UInt32 = 128,
		packetDuration: TimeInterval? = nil,
		maximumFrameDuration: TimeInterval? = nil,
		captureRenderedAudio: Bool = true,
		onFrame: @escaping (PCMFrame, AudioProcessingReport) -> Void
	) throws -> MixerPCMSink {
		guard targetFormat.isValid, bufferFrameCount > 0 else {
			throw AudioMixerError.pcmSinkInstallFailed("Invalid sink format or buffer size")
		}
        if [packetDuration, maximumFrameDuration].compactMap({ $0 }).contains(where: {
            !$0.isFinite || $0 <= 0 || $0 > 1
        }) {
			throw AudioMixerError.pcmSinkInstallFailed("Invalid maximum frame duration")
		}
		metadataLock.lock()
		defer { metadataLock.unlock() }
		let resolvedID = try resolveMixerNodeID(
			sinkID,
			generatedPrefix: "pcm-sink",
			existingIDs: Set(sinkMetadataByID.keys),
			nextSequence: &nextSinkSequence
		)
		let sink = MixerPCMSink(
			id: resolvedID,
			mixerFormat: audioFormat,
			targetFormat: targetFormat,
			packetDuration: packetDuration,
            maximumFrameDuration: maximumFrameDuration,
			onFrame: onFrame,
			recordEmit: { [weak self] report, failure in
				self?.recordPCMSinkEmit(id: resolvedID, report: report, failure: failure)
			}
		)
		sinksByID[resolvedID] = sink
		sinkOrder.append(resolvedID)
		sinkMetadataByID[resolvedID] = MixerSinkMetadata(
			id: resolvedID,
			mixerFormat: audioFormat,
			targetFormat: targetFormat
		)
		if captureRenderedAudio {
			try installRenderCaptureIfNeeded().captureAudio { [weak self] frame in
				try? self?.deliverToSinks(frame)
			}
		}
		return sink
	}

    /// A graph change discards the settling interval instead of playing it late.
    /// Only explicitly requested transitions modify samples; normal sinks do not.
    func beginSinkTransition(settlingDuration: TimeInterval, holding: Bool = false) {
        metadataLock.withLock {
            if let renderCapture {
                // Hardware output and every observer must see the same fade.
                renderCapture.beginTransition(settlingDuration: settlingDuration, holding: holding)
            } else {
                sinksByID.values.forEach { $0.beginTransition(settlingDuration: settlingDuration, holding: holding) }
            }
        }
    }

    /// Install the output fade while assembling the bus. A bus without a PCM
    /// sink applies the fade inline without capturing or delivering audio.
    func prepareOutputTransition() throws {
        _ = try metadataLock.withLock { try installRenderCaptureIfNeeded() }
    }

    func updatePCMSinkFormat(id: String, targetFormat: AudioFormat) throws {
        guard targetFormat.isValid else { throw AudioMixerError.formatCreationFailed(targetFormat) }
        metadataLock.lock()
        defer { metadataLock.unlock() }
        guard let sink = sinksByID[id] else { throw AudioMixerError.pcmSinkInstallFailed("Unknown sink") }
        sink.targetFormat = targetFormat
        sinkMetadataByID[id]?.targetFormat = targetFormat
    }

	func snapshots() -> [MixerSinkSnapshot] {
		return sinkOrder.enumerated().compactMap { index, id in
			sinkMetadataByID[id].map {
				MixerSinkSnapshot(
					id: $0.id,
					index: index,
					mixerFormat: $0.mixerFormat,
					targetFormat: $0.targetFormat,
					emittedFrameCount: $0.emittedFrameCount,
					normalizationReport: $0.normalizationReport,
					lastFailure: $0.lastFailure
				)
			}
		}
	}

	func deliverToSinks(_ frame: PCMFrame) throws {
		metadataLock.lock()
        defer { metadataLock.unlock() }
        let sinks = sinkOrder.compactMap { sinksByID[$0] }
		for sink in sinks {
			_ = try sink.receive(frame)
		}
	}

	private func installRenderCaptureIfNeeded() throws -> RenderCaptureNode {
        if let renderCapture { return renderCapture }
        let capture = try RenderCaptureNode(format: audioFormat, renderClock: renderClock)
        let connections = engine.outputConnectionPoints(for: faderMixer, outputBus: 0)
        engine.attach(capture.node)
        do {
            try engine.connectNode(faderMixer, to: capture.node, format: format)
            if !connections.isEmpty {
                try engine.connectNode(capture.node, to: connections, fromBus: 0, format: format)
            }
        } catch {
            engine.disconnectNodeInput(capture.node)
            engine.detach(capture.node)
            if !connections.isEmpty { try? engine.connectNode(faderMixer, to: connections, fromBus: 0, format: format) }
            throw error
        }
        renderCapture = capture
        return capture
    }

	private func recordPCMSinkEmit(id: String, report: AudioProcessingReport?, failure: String?) {
		metadataLock.lock()
		defer { metadataLock.unlock() }
		guard var metadata = sinkMetadataByID[id] else { return }
		metadata.normalizationReport = report
		metadata.lastFailure = failure
		if failure == nil {
			metadata.emittedFrameCount += 1
		}
		sinkMetadataByID[id] = metadata
	}

}

private struct MixerSinkMetadata {
	var id: String
	var mixerFormat: AudioFormat
	var targetFormat: AudioFormat
	var emittedFrameCount = 0
	var normalizationReport: AudioProcessingReport?
	var lastFailure: String?
}
