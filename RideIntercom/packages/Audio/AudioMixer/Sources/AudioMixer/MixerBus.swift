import AudioCore
@preconcurrency import AVFAudio
import Foundation

public final class MixerBus {
	public let id: String
	public let inputMixer: AVAudioMixerNode
	public let faderMixer: AVAudioMixerNode

	private unowned let engine: AVAudioEngine
	private let format: AVAudioFormat
	private let audioFormat: AudioFormat
    private let effectChain: MixerEffectChain
    private let renderClock: MixerRenderClock
	private var sourceNodeIDs: Set<ObjectIdentifier> = []
	private var sourceNodeOrder: [ObjectIdentifier] = []
	private var sourceMetadataByNodeID: [ObjectIdentifier: MixerSourceMetadata] = [:]
	private var pcmSourceByNodeID: [ObjectIdentifier: MixerPCMSource] = [:]
	private let metadataLock = NSRecursiveLock()
	private var nextSourceSequence = 0
    private let sinkManager: MixerSinkManager

	public var effects: [AVAudioNode] { effectChain.effects }

	internal func detach() {
		stopPCMSources()
        sinkManager.detach()
		let sourceFaders = Set(pcmSourceByNodeID.values.map { ObjectIdentifier($0.faderNode) })
		let owned = engine.attachedNodes.filter { node in
			let nodeID = ObjectIdentifier(node)
			return sourceNodeIDs.contains(nodeID) || sourceFaders.contains(nodeID) || effectChain.contains(nodeID)
				|| node === inputMixer || node === faderMixer
		}
		for node in owned { engine.disconnectNodeInput(node); engine.disconnectNodeOutput(node); engine.detach(node) }
	}

	public var volume: Float {
		get { faderMixer.outputVolume }
		set { faderMixer.outputVolume = newValue }
	}

	public var outputNode: AVAudioNode { sinkManager.outputNode }

	init(
		id: String,
		engine: AVAudioEngine,
		format: AVAudioFormat,
		audioFormat: AudioFormat,
		renderClock: MixerRenderClock,
		prepareForGraphChange: @escaping () -> Void
	) {
		self.id = id
		self.engine = engine
		self.format = format
		self.audioFormat = audioFormat
        self.renderClock = renderClock
		self.inputMixer = AVAudioMixerNode()
		self.faderMixer = AVAudioMixerNode()
        self.effectChain = MixerEffectChain(id: id, engine: engine, format: format, inputMixer: inputMixer,
            faderMixer: faderMixer, prepareForGraphChange: prepareForGraphChange)
        self.sinkManager = MixerSinkManager(engine: engine, format: format, audioFormat: audioFormat,
            faderMixer: faderMixer, renderClock: renderClock, metadataLock: metadataLock)
	}

	public func addSource(_ node: AVAudioNode, id sourceID: String? = nil) throws {
		let nodeID = ObjectIdentifier(node)
		guard !sourceNodeIDs.contains(nodeID) else {
			throw AudioMixerError.invalidRoute(id)
		}
		guard !isEngineInternalNode(node) else {
			throw AudioMixerError.incompatibleEffectNode
		}
		let resolvedID = try resolveMixerNodeID(
			sourceID,
			generatedPrefix: "source",
			existingIDs: Set(sourceMetadataByNodeID.values.map(\.id)),
			nextSequence: &nextSourceSequence
		)

		engine.attach(node)
		let inputBus = inputMixer.nextAvailableInputBus
		do {
			try engine.connectNode(node, to: inputMixer, fromBus: 0, toBus: inputBus, format: format)
		} catch {
			engine.detach(node)
			throw error
		}
		sourceNodeIDs.insert(nodeID)
		sourceNodeOrder.append(nodeID)
		sourceMetadataByNodeID[nodeID] = MixerSourceMetadata(
			id: resolvedID,
			typeName: String(describing: type(of: node)),
			inputBusIndex: Int(inputBus)
		)
	}

	@discardableResult
	public func addPCMSource(
		id sourceID: String, maximumBufferedDuration: TimeInterval? = nil,
		captureTimePlayoutDelay: TimeInterval? = nil, adaptivePlayout: Bool = false
	) throws -> MixerPCMSource {
		if let delay = captureTimePlayoutDelay {
			guard delay.isFinite, delay >= 0, let limit = maximumBufferedDuration,
				  limit.isFinite, limit > delay, limit * audioFormat.sampleRate < Double(Int64.max) / 4 else {
				throw AudioMixerError.pcmSourceScheduleFailed(
					"Capture-time playout requires a finite delay below the playback budget"
				)
			}
		}
		let player = AVAudioPlayerNode()
		let fader = AVAudioMixerNode()
		let nodeID = ObjectIdentifier(player)
		let resolvedID = try resolveMixerNodeID(
			sourceID,
			generatedPrefix: "pcm-source",
			existingIDs: Set(sourceMetadataByNodeID.values.map(\.id)),
			nextSequence: &nextSourceSequence
		)

		let inputBus = try connectPCMSource(player: player, fader: fader)
		sourceNodeIDs.insert(nodeID)
		sourceNodeOrder.append(nodeID)
		sourceMetadataByNodeID[nodeID] = MixerSourceMetadata(
			id: resolvedID,
			typeName: "MixerPCMSource",
			inputBusIndex: Int(inputBus),
			mixerFormat: audioFormat
		)
		let source = MixerPCMSource(
			id: resolvedID,
			playerNode: player,
			faderNode: fader,
			mixerFormat: audioFormat,
			maximumBufferedDuration: maximumBufferedDuration,
			captureTimePlayoutDelay: captureTimePlayoutDelay,
			adaptivePlayout: adaptivePlayout,
            renderClock: renderClock,
			recordSchedule: { [weak self, weak player] frame, report, failure, didSchedule in
				guard let player else { return }
				self?.recordPCMSourceSchedule(
					nodeID: ObjectIdentifier(player),
					frame: frame,
					report: report,
					failure: failure,
					didSchedule: didSchedule
				)
			}
		)
		pcmSourceByNodeID[nodeID] = source
		return source
	}

	private func connectPCMSource(player: AVAudioPlayerNode, fader: AVAudioMixerNode) throws -> AVAudioNodeBus {
		engine.attach(player)
		engine.attach(fader)
		let inputBus = inputMixer.nextAvailableInputBus
		do {
			try engine.connectNode(player, to: fader, format: format)
			try engine.connectNode(fader, to: inputMixer, fromBus: 0, toBus: inputBus, format: format)
		} catch {
			engine.detach(player)
			engine.detach(fader)
			throw error
		}
		return inputBus
	}

    @discardableResult
    public func installPCMSink(
        id sinkID: String, targetFormat: AudioFormat, bufferFrameCount: UInt32 = 128,
        packetDuration: TimeInterval? = nil, maximumFrameDuration: TimeInterval? = nil,
        captureRenderedAudio: Bool = true, onFrame: @escaping (PCMFrame, AudioProcessingReport) -> Void
    ) throws -> MixerPCMSink {
        try sinkManager.installPCMSink(id: sinkID, targetFormat: targetFormat, bufferFrameCount: bufferFrameCount,
            packetDuration: packetDuration, maximumFrameDuration: maximumFrameDuration,
            captureRenderedAudio: captureRenderedAudio, onFrame: onFrame)
    }

    /// A graph change discards the settling interval instead of playing it late.
    public func beginSinkTransition(settlingDuration: TimeInterval, holding: Bool = false) {
        sinkManager.beginSinkTransition(settlingDuration: settlingDuration, holding: holding)
    }

    /// Install the output fade while assembling the bus, even without a recording sink.
    public func prepareOutputTransition() throws { try sinkManager.prepareOutputTransition() }

    public func updatePCMSinkFormat(id: String, targetFormat: AudioFormat) throws {
        try sinkManager.updatePCMSinkFormat(id: id, targetFormat: targetFormat)
    }

    func deliverToSinks(_ frame: PCMFrame) throws { try sinkManager.deliverToSinks(frame) }

	func stopPCMSources() { pcmSourceByNodeID.values.forEach { $0.stop() } }

    public var droppedCaptureFrameCount: Int { sinkManager.droppedCaptureFrameCount }
    public var processingLatency: TimeInterval {
        metadataLock.withLock {
            effectChain.activeEffects.reduce(0) { $0 + $1.latency }
        }
    }

    /// Tail from active native effects only; bypassed nodes are disconnected.
    public var processingTailTime: TimeInterval {
        metadataLock.withLock {
            effectChain.activeEffects.reduce(0) {
                $0 + (($1 as? AVAudioUnit)?.withAUAudioUnit { $0.tailTime } ?? 0)
            }
        }
    }

	public func snapshot() -> MixerBusSnapshot {
		metadataLock.lock()
		defer { metadataLock.unlock() }
		let sourceSnapshots = makeSourceSnapshots(sourceNodeOrder: sourceNodeOrder,
            sourceMetadataByNodeID: sourceMetadataByNodeID, pcmSourceByNodeID: pcmSourceByNodeID)
		let sinkSnapshots = sinkManager.snapshots()
		return MixerBusSnapshot(
			id: id,
			volume: volume,
			sourceCount: sourceSnapshots.count,
			effectCount: effects.count,
			sinkCount: sinkSnapshots.count,
			sources: sourceSnapshots,
			sinks: sinkSnapshots,
			effectChain: effectChain.snapshots()
		)
	}

    public func addEffect(
        _ node: AVAudioNode, id effectID: String? = nil, bypassed: Bool = false,
        state: MixerEffectState = .unknown, parameters: [MixerEffectParameterSnapshot] = []
    ) throws {
        try effectChain.addEffect(node, id: effectID, bypassed: bypassed, state: state, parameters: parameters)
    }

    /// Route around disabled effects so their native latency does not delay other paths.
    public func setEffectBypassed(id effectID: String, bypassed: Bool) throws {
        try effectChain.setEffectBypassed(id: effectID, bypassed: bypassed)
    }

    /// Prepare a disconnected effect without interrupting the current audio path.
    /// The graph owner must serialize this with topology changes.
    public func prepareEffect(id effectID: String) throws { try effectChain.prepareEffect(id: effectID) }

    public func updateEffectSnapshot(
        id effectID: String, state: MixerEffectState? = nil, parameters: [MixerEffectParameterSnapshot]? = nil
    ) throws { try effectChain.updateEffectSnapshot(id: effectID, state: state, parameters: parameters) }

    public func removeEffect(at index: Int) throws { try effectChain.removeEffect(at: index) }

    /// Reset the caller-driven processor's owned state without reconnecting
    /// the graph, reallocating units or restarting the native sample clock.
    func resetProcessingState() {
        metadataLock.withLock {
            inputMixer.reset()
            for effect in effects { effect.reset() }
            faderMixer.reset()
            sinkManager.resetStreams()
        }
    }

    func resetPCMSourceClocks() {
        for source in pcmSourceByNodeID.values { source.invalidatePlayout() }
    }

	func rebuildChain() throws { try effectChain.rebuildChain() }

	private func isEngineInternalNode(_ node: AVAudioNode) -> Bool {
        // Fetching inputNode/outputNode initializes device I/O, even when the
        // caller is only building a software graph for offline processing.
		node is AVAudioInputNode || node is AVAudioOutputNode || node === engine.mainMixerNode
	}

	private func recordPCMSourceSchedule(
		nodeID: ObjectIdentifier,
		frame: PCMFrame,
		report: AudioProcessingReport?,
		failure: String?,
		didSchedule: Bool
	) {
		metadataLock.lock()
		defer { metadataLock.unlock() }
		guard var metadata = sourceMetadataByNodeID[nodeID] else { return }
		metadata.originalFormat = frame.format
		metadata.normalizationReport = report
		metadata.lastFailure = failure
		if failure == nil {
			metadata.scheduledFrameCount += 1
		}
		if didSchedule {
			metadata.lastScheduledAt = Date().timeIntervalSince1970
		}
		sourceMetadataByNodeID[nodeID] = metadata
	}

}
