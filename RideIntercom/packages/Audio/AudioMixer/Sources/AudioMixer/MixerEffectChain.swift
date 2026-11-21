import AudioCore
@preconcurrency import AVFAudio
import Foundation

/// Owns the ordered effect graph and its metadata for a bus.
final class MixerEffectChain {
    private let id: String
    private unowned let engine: AVAudioEngine
    private let format: AVAudioFormat
    private let inputMixer: AVAudioMixerNode
    private let faderMixer: AVAudioMixerNode
    private let prepareForGraphChange: () -> Void
    private var effectNodeIDs: Set<ObjectIdentifier> = []
    private var bypassedEffectNodeIDs: Set<ObjectIdentifier> = []
    private var effectMetadataByNodeID: [ObjectIdentifier: MixerEffectMetadata] = [:]
    private var nextEffectSequence = 0
    private(set) var effects: [AVAudioNode] = []

    init(id: String, engine: AVAudioEngine, format: AVAudioFormat, inputMixer: AVAudioMixerNode,
         faderMixer: AVAudioMixerNode, prepareForGraphChange: @escaping () -> Void) {
        self.id = id
        self.engine = engine
        self.format = format
        self.inputMixer = inputMixer
        self.faderMixer = faderMixer
        self.prepareForGraphChange = prepareForGraphChange
    }

    func contains(_ nodeID: ObjectIdentifier) -> Bool { effectNodeIDs.contains(nodeID) }
    var activeEffects: [AVAudioNode] { effects.filter { !bypassedEffectNodeIDs.contains(ObjectIdentifier($0)) } }

    func snapshots() -> [MixerEffectSnapshot] {
        effects.enumerated().map { index, effect in
            let typeName = String(describing: type(of: effect))
            let metadata = effectMetadataByNodeID[ObjectIdentifier(effect)]
            return MixerEffectSnapshot(id: metadata?.id ?? typeName, typeName: typeName, index: index,
                state: metadata?.state ?? .unknown, parameters: metadata?.parameters ?? [])
        }
    }

    private func isEngineInternalNode(_ node: AVAudioNode) -> Bool {
        node is AVAudioInputNode || node is AVAudioOutputNode || node === engine.mainMixerNode
    }

	func addEffect(
		_ node: AVAudioNode,
		id effectID: String? = nil,
		bypassed: Bool = false,
		state: MixerEffectState = .unknown,
		parameters: [MixerEffectParameterSnapshot] = []
	) throws {
		let nodeID = ObjectIdentifier(node)
		guard !effectNodeIDs.contains(nodeID) else {
			throw AudioMixerError.invalidRoute(id)
		}
		guard !isEngineInternalNode(node) else {
			throw AudioMixerError.incompatibleEffectNode
		}
		guard node.numberOfOutputs > 0 else {
			throw AudioMixerError.incompatibleEffectNode
		}

		if let auNode = node as? AVAudioUnit, !(node is AVAudioUnitEffect),
		   let nodeFmt = auNode.withAUAudioUnit({ $0.outputBusses.count > 0 ? $0.outputBusses[0].format : nil }) {
			if nodeFmt.sampleRate > 0,
			   nodeFmt.sampleRate != format.sampleRate || nodeFmt.channelCount != format.channelCount {
				throw AudioMixerError.incompatibleEffectNode
			}
		}

		let resolvedID = try resolveMixerNodeID(
			effectID,
			generatedPrefix: "effect",
			existingIDs: Set(effectMetadataByNodeID.values.map(\.id)),
			nextSequence: &nextEffectSequence
		)

		engine.attach(node)
		effects.append(node)
		effectNodeIDs.insert(nodeID)
		if bypassed { bypassedEffectNodeIDs.insert(nodeID) }
		effectMetadataByNodeID[nodeID] = MixerEffectMetadata(
			id: resolvedID,
			state: state,
			parameters: parameters
		)
		try rebuildChain()
	}

	/// Route around disabled effects. An Audio Unit's own bypass can retain
	/// its algorithmic latency and make the engine delay the remaining paths.
	func setEffectBypassed(id effectID: String, bypassed: Bool) throws {
		guard let nodeID = effectMetadataByNodeID.first(where: { $0.value.id == effectID })?.key else {
			throw AudioMixerError.unknownEffect(effectID)
		}
		guard bypassedEffectNodeIDs.contains(nodeID) != bypassed else { return }
		if bypassed { bypassedEffectNodeIDs.insert(nodeID) } else { bypassedEffectNodeIDs.remove(nodeID) }
		try rebuildChain()
	}

    /// Prepare a requested enable while the effect is still disconnected.
    /// Native model allocation can be slow; it need not interrupt the current
    /// audio path. The graph owner must serialize this with topology changes.
    func prepareEffect(id effectID: String) throws {
        guard let nodeID = effectMetadataByNodeID.first(where: { $0.value.id == effectID })?.key else {
            throw AudioMixerError.unknownEffect(effectID)
        }
        guard bypassedEffectNodeIDs.contains(nodeID),
              let node = effects.first(where: { ObjectIdentifier($0) == nodeID }) as? AVAudioUnit else { return }
        try node.withAUAudioUnit { unit throws in
            guard !unit.renderResourcesAllocated else { return }
            for index in 0..<unit.inputBusses.count { try unit.inputBusses[index].setFormat(format) }
            for index in 0..<unit.outputBusses.count { try unit.outputBusses[index].setFormat(format) }
            try unit.allocateRenderResources()
        }
    }

	func updateEffectSnapshot(
		id effectID: String,
		state: MixerEffectState? = nil,
		parameters: [MixerEffectParameterSnapshot]? = nil
	) throws {
		guard !effectID.isEmpty else {
			throw AudioMixerError.invalidNodeID(effectID)
		}
		guard let entry = effectMetadataByNodeID.first(where: { $0.value.id == effectID }) else {
			throw AudioMixerError.unknownEffect(effectID)
		}

		var metadata = entry.value
		if let state {
			metadata.state = state
		}
		if let parameters {
			metadata.parameters = parameters
		}
		effectMetadataByNodeID[entry.key] = metadata
	}

	func removeEffect(at index: Int) throws {
		guard effects.indices.contains(index) else {
			throw AudioMixerError.invalidEffectIndex(index)
		}

		let removed = effects.remove(at: index)
		effectNodeIDs.remove(ObjectIdentifier(removed))
		bypassedEffectNodeIDs.remove(ObjectIdentifier(removed))
		effectMetadataByNodeID.removeValue(forKey: ObjectIdentifier(removed))
		engine.disconnectNodeOutput(removed)
		engine.disconnectNodeInput(removed)
		engine.detach(removed)
		try rebuildChain()
	}

	func rebuildChain() throws {
        if engine.isRunning { prepareForGraphChange() }

		engine.disconnectNodeOutput(inputMixer)
		for effect in effects {
			engine.disconnectNodeOutput(effect)
		}

		var previous: AVAudioNode = inputMixer
		for effect in effects where !bypassedEffectNodeIDs.contains(ObjectIdentifier(effect)) {
			try engine.connectNode(previous, to: effect, format: format)
			previous = effect
		}

		try engine.connectNode(previous, to: faderMixer, format: format)
	}

}

private struct MixerEffectMetadata {
    var id: String
    var state: MixerEffectState
    var parameters: [MixerEffectParameterSnapshot]
}

	func resolveMixerNodeID(
		_ proposedID: String?,
		generatedPrefix: String,
		existingIDs: Set<String>,
		nextSequence: inout Int
	) throws -> String {
		if let proposedID {
			guard !proposedID.isEmpty else {
				throw AudioMixerError.invalidNodeID(proposedID)
			}
			guard !existingIDs.contains(proposedID) else {
				throw AudioMixerError.duplicateNodeID(proposedID)
			}
			return proposedID
		}

		var generatedID: String
		repeat {
			generatedID = "\(generatedPrefix)-\(nextSequence)"
			nextSequence += 1
		} while existingIDs.contains(generatedID)
		return generatedID
	}
