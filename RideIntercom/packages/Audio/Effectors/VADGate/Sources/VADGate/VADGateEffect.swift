import AudioToolbox
@preconcurrency import AVFAudio

public enum VADGateError: Error, Equatable, Sendable {
	case instantiationFailed(String)
}

public final class VADGateEffect {
	private let auNode: AVAudioUnit

	public private(set) var configuration: VADGateConfiguration

	public var node: AVAudioNode { auNode }
	public var avAudioUnit: AVAudioUnit { auNode }
	public let vadGate: VADGate

	private static let componentDescription = AudioComponentDescription(
		componentType: kAudioUnitType_Effect,
		componentSubType: 0x76_61_64_67, // 'vadg'
		componentManufacturer: 0x52_64_49_63, // 'RdIc'
		componentFlags: 0,
		componentFlagsMask: 0
	)

	private static let registration: Void = {
		AUAudioUnit.registerSubclass(AudioUnit.self, as: componentDescription, name: "VADGate", version: 1)
	}()

	public static func make(configuration: VADGateConfiguration = VADGateConfiguration()) async throws -> VADGateEffect {
		_ = registration
		return try VADGateEffect(
			auNode: await withCheckedThrowingContinuation { continuation in
				AVAudioUnit.instantiate(with: componentDescription) { avAudioUnit, error in
					if let avAudioUnit {
						continuation.resume(returning: avAudioUnit)
					} else {
						continuation.resume(throwing: VADGateError.instantiationFailed(error?.localizedDescription ?? ""))
					}
				}
			},
			configuration: configuration
		)
	}

	init(auNode: AVAudioUnit, configuration: VADGateConfiguration) throws {
		guard let gate = auNode.withAUAudioUnit({ ($0 as? AudioUnit)?.vadGate }) else {
			throw VADGateError.instantiationFailed("Unexpected audio unit for VADGate")
		}
		self.vadGate = gate
		self.auNode = auNode
		self.configuration = configuration
		apply(configuration)
	}

	public func apply(_ configuration: VADGateConfiguration) {
		vadGate.apply(configuration: configuration)
		self.configuration = configuration
	}

	public var runtimeSnapshot: VADGateRuntimeSnapshot {
		vadGate.runtimeSnapshot
	}

	private final class AudioUnit: AUAudioUnit {
		let vadGate = VADGate()
		private let inputBus: AUAudioUnitBus
		private let outputBus: AUAudioUnitBus
		private lazy var configuredInputs = AUAudioUnitBusArray(audioUnit: self, busType: .input, busses: [inputBus])
		private lazy var configuredOutputs = AUAudioUnitBusArray(audioUnit: self, busType: .output, busses: [outputBus])

        override init(
            componentDescription: AudioComponentDescription, options: AudioComponentInstantiationOptions = []
        ) throws {
			guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
			                                 channels: 2, interleaved: false) else {
				throw VADGateError.instantiationFailed("Unsupported VADGate bus format")
			}
			inputBus = try AUAudioUnitBus(format: format)
			outputBus = try AUAudioUnitBus(format: format)
			try super.init(componentDescription: componentDescription, options: options)
			// The arrays require self. Finish initialization before exposing them to the graph.
			_ = configuredInputs
			_ = configuredOutputs
		}

		override var inputBusses: AUAudioUnitBusArray { configuredInputs }
		override var outputBusses: AUAudioUnitBusArray { configuredOutputs }
		override var canProcessInPlace: Bool { true }

		override var internalRenderBlock: AUInternalRenderBlock {
			let vad = vadGate
			return { _, timestamp, frameCount, _, outputData, _, pullInputBlock in
				guard let pullInputBlock else { return kAudioUnitErr_NoConnection }
				var flags: AudioUnitRenderActionFlags = []
				let status = pullInputBlock(&flags, timestamp, frameCount, 0, outputData)
				guard status == noErr else { return status }

				let buffers = UnsafeMutableAudioBufferListPointer(outputData)
				let frames = Int(frameCount)
				var sumOfSquares: Float = 0, count = 0
				for buffer in buffers {
					guard let data = buffer.mData else { continue }
                    let samples = UnsafeBufferPointer<Float>(
                        start: data.assumingMemoryBound(to: Float.self),
                        count: min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size))
					for sample in samples { sumOfSquares += sample * sample }
					count += samples.count
				}
				let rms = count > 0 ? (sumOfSquares / Float(count)).squareRoot() : 0
				let gain = vad.process(rmsDBFS: 20 * log10(max(rms, 0.000_001)), duration: Double(frameCount) / 48_000.0).gain
				for buffer in buffers {
					guard let data = buffer.mData else { continue }
                    let samples = UnsafeMutableBufferPointer<Float>(
                        start: data.assumingMemoryBound(to: Float.self),
                        count: min(frames, Int(buffer.mDataByteSize) / MemoryLayout<Float>.size))
					for index in samples.indices { samples[index] *= gain }
				}
				return noErr
			}
		}
	}
}
