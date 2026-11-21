import AVFAudio
import AudioCore
import AudioMixer
import Codec
import DynamicsProcessor
import PeakLimiter
import SoundIsolation
import Foundation
import RTC
import Synchronization
import VADGate

nonisolated struct AppAudioPipelineConfiguration: Equatable, Sendable {
    /// Receive playout for calls: a 2 ms start on a calm link. The window also
    /// rebuilds audio queued before the output clock runs, so it stays 120 ms;
    /// AudioMixer learns Wi-Fi jitter up to half of it.
    static let callReceivePlayoutDelay: TimeInterval = 0.002
    static let callReceiveMaximumBufferedDuration: TimeInterval = 0.12
    var mixerFormat: AudioFormat
    var rtcSendFormat: AudioFormat
    var outputHardwareFormat: AudioFormat
    var preferredCodec: AudioCodecIdentifier
    var aacELDv2BitRate: Int
    var opusBitRate: Int
    var masterOutputVolume: Float
    var isOutputMuted: Bool
    var peerOutputVolumes: [String: Float]
    var transmitSoundIsolationEnabled: Bool
    var receiveMasterSoundIsolationEnabled: Bool
    var peerSoundIsolationEnabled: [String: Bool]
    var maximumBufferedDuration: TimeInterval?
    var receiveMaximumBufferedDuration: TimeInterval?
    var receivePlayoutDelay: TimeInterval?
    var finitePlaybackDuration: TimeInterval?

    init(
        mixerFormat: AudioFormat = .intercomMixer,
        rtcSendFormat: AudioFormat = .intercomPacketAudio,
        outputHardwareFormat: AudioFormat = .intercomHardwarePreferred,
        preferredCodec: AudioCodecIdentifier = .pcm16,
        aacELDv2BitRate: Int = 48_000,
        opusBitRate: Int = Codec.OpusOptions().bitRate,
        masterOutputVolume: Float = 1,
        isOutputMuted: Bool = false,
        peerOutputVolumes: [String: Float] = [:],
        transmitSoundIsolationEnabled: Bool = true,
        receiveMasterSoundIsolationEnabled: Bool = false,
        peerSoundIsolationEnabled: [String: Bool] = [:],
        maximumBufferedDuration: TimeInterval? = nil,
        receiveMaximumBufferedDuration: TimeInterval? = nil,
        receivePlayoutDelay: TimeInterval? = nil,
        finitePlaybackDuration: TimeInterval? = nil
    ) {
        self.mixerFormat = mixerFormat
        self.rtcSendFormat = rtcSendFormat
        self.outputHardwareFormat = outputHardwareFormat
        self.preferredCodec = preferredCodec
        self.aacELDv2BitRate = Codec.AACELDv2Options(bitRate: aacELDv2BitRate).bitRate
        self.opusBitRate = Codec.OpusOptions(bitRate: opusBitRate).bitRate
        self.masterOutputVolume = min(2, max(0, masterOutputVolume))
        self.isOutputMuted = isOutputMuted
        self.peerOutputVolumes = peerOutputVolumes.mapValues { min(1, max(0, $0)) }
        self.transmitSoundIsolationEnabled = transmitSoundIsolationEnabled
        self.receiveMasterSoundIsolationEnabled = receiveMasterSoundIsolationEnabled
        self.peerSoundIsolationEnabled = peerSoundIsolationEnabled
        self.maximumBufferedDuration = maximumBufferedDuration
        self.receiveMaximumBufferedDuration = receiveMaximumBufferedDuration
        self.receivePlayoutDelay = receivePlayoutDelay
        self.finitePlaybackDuration = finitePlaybackDuration
    }

    @MainActor var codecOptions: AppAudioCodecOptions {
        AppAudioCodecOptions(aacELDv2BitRate: aacELDv2BitRate, opusBitRate: opusBitRate)
    }

    @MainActor var audioPolicy: RTC.RTCAudioPolicy {
        AppAudioCodecBridge.makeRTCAudioPolicy(
            preferred: preferredCodec,
            format: rtcSendFormat,
            options: codecOptions
        )
    }

    @MainActor var codecRuntimeReport: CodecRuntimeReport {
        AppAudioCodecBridge.runtimeReport(
            for: preferredCodec,
            format: rtcSendFormat,
            options: codecOptions
        )
    }
}

enum AppAudioPipelineError: Error, Equatable {
    case notConfigured
    case invalidFormat
    case transmitFailed
}

final class AppAudioPipeline {
    nonisolated static let nativeOutputObservationLifetime: TimeInterval = 2

    var onTransmitPacket: (@Sendable (RTC.RTCAudioPacket) -> Void)? {
        get { transmitter.onPacket }
        set { transmitter.onPacket = newValue }
    }
    var onOutputFrame: ((PCMFrame) -> Void)? {
        didSet { requestsOutputFrames.store(onOutputFrame != nil, ordering: .releasing) }
    }

    private let makeEngine: () -> AVAudioEngine
    let usesHardwareClock: Bool
    private nonisolated let requestsOutputFrames = Atomic<Bool>(false)
    var rendersToHardware: Bool { usesHardwareClock && hardwareOutputEnabled }
    private var generation = UUID()
    private var hardwareOutputEnabled = true
    private var frameDeliveries: [AudioFrameDelivery] = []
    private var nativeOutputActivity: NativeOutputActivity?
    var lastNativeRenderAt: TimeInterval? {
        rendersToHardware ? nativeOutputActivity?.lastRenderAt : nil
    }
    var lastNativeAudibleOutputAt: TimeInterval? {
        rendersToHardware ? nativeOutputActivity?.lastAudibleAt : nil
    }
    func takeNativeOutputObservation() -> NativeOutputObservation? {
        rendersToHardware ? nativeOutputActivity?.takeObservation() : nil
    }
    #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS)
    private(set) var backgroundOutputProbe: BackgroundCallOutputProbe?
    #endif

    init(makeEngine: @escaping () -> AVAudioEngine = { AVAudioEngine() }, usesHardwareClock: Bool = false) {
        self.makeEngine = makeEngine
        self.usesHardwareClock = usesHardwareClock
    }

    private var configuration = AppAudioPipelineConfiguration()
    private nonisolated let receiver = AppAudioReceiver()
    private nonisolated let transmitter = AppAudioTransmitter()
    var transmitProcessingLatency: TimeInterval { transmitter.processingLatency }
    func finishMicrophone() throws { try transmitter.finishMicrophone() }
    func startPreparedOutput() throws { try receiver.start() }
    func beginFinitePlayback() { frameDeliveries.forEach { $0.activate() } }
    var audioCheckDrainDuration: TimeInterval { receiver.playbackDrainDuration(peer: "audio-check") }
    var transmitEncodingFailureCount: Int { transmitter.failureCount }
    var inputObservation: AudioInputObservation { transmitter.inputObservation }
    var vadRuntimeSnapshot: VADGateRuntimeSnapshot { transmitter.vadSnapshot }
    func setTransmissionController(_ controller: AudioTransmissionController) { transmitter.setController(controller) }
    func applyVADSensitivity(_ sensitivity: VoiceActivitySensitivity) { transmitter.applyVADSensitivity(sensitivity) }
    func setInputMuted(_ muted: Bool) { transmitter.setMuted(muted) }
    func setHardwareOutputEnabled(_ enabled: Bool) {
        hardwareOutputEnabled = enabled
        receiver.setHardwareOutputEnabled(enabled && usesHardwareClock)
    }
    nonisolated func processMicrophoneFrame(_ frame: PCMFrame, level: Float? = nil, shouldProcess: @Sendable () -> Bool = { true }) {
        transmitter.processMicrophone(frame, level: level, shouldProcess: shouldProcess)
    }

    var isolationRuntimeSnapshots: [String: VoiceIsolationRuntimeSnapshot] {
        var result = receiver.isolationSnapshots
        result["tx-bus"] = transmitter.isolationSnapshot
        return result
    }
    var dynamicsRuntimeSnapshot: DynamicsProcessorRuntimeSnapshot? { transmitter.dynamicsSnapshot }
    var transmitLimiterRuntimeSnapshot: PeakLimiterRuntimeSnapshot? { transmitter.limiterSnapshot }
    var outputLimiterRuntimeSnapshot: PeakLimiterRuntimeSnapshot? { receiver.limiterSnapshot }

    var snapshot: AudioMixerSnapshot {
        var result = receiver.snapshot
        if let transmit = transmitter.snapshot {
            result.busIDs += transmit.busIDs
            result.buses += transmit.buses
            result.routes += transmit.routes
            result.graph.nodes += transmit.graph.nodes.map { node in
                var node = node; node.id = "transmit." + node.id; return node
            }
            result.graph.edges += transmit.graph.edges.map { edge in
                var edge = edge; edge.id = "transmit." + edge.id
                edge.sourceNodeID = "transmit." + edge.sourceNodeID
                edge.destinationNodeID = "transmit." + edge.destinationNodeID
                return edge
            }
        }
        return result
    }

    var codecRuntimeReport: CodecRuntimeReport {
        configuration.codecRuntimeReport
    }

    var audioPolicy: RTC.RTCAudioPolicy {
        configuration.audioPolicy
    }

    func rebuild(configuration: AppAudioPipelineConfiguration, peerIDs: [String], startsOutputClock: Bool = true) throws {
        stop()
        var completed = false
        defer { if !completed { stop() } }
        guard configuration.mixerFormat.sampleRate > 0, configuration.mixerFormat.channelCount > 0 else {
            throw AppAudioPipelineError.invalidFormat
        }
        let generation = self.generation
        self.configuration = configuration

        let engine = makeEngine()
        // Configure the graph before starting its device clock. Ordinary codec,
        // gain and effect updates do not rebuild or stop this engine.
        engine.stop()
        try transmitter.rebuild(configuration: configuration, encoding: configuration.codecRuntimeReport.activeConfiguration)

        let outputDelivery = AudioFrameDelivery(initiallyActive: configuration.finitePlaybackDuration == nil,
                                                finiteRecordingDuration: configuration.finitePlaybackDuration) { [weak self] frame in
            guard let self, self.generation == generation else { return }
            self.publishOutput(frame)
        }
        frameDeliveries.append(outputDelivery)
        let activity = rendersToHardware && configuration.finitePlaybackDuration == nil ? NativeOutputActivity() : nil
        nativeOutputActivity = activity
        #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS)
        let probe = rendersToHardware && BackgroundCallValidationObservation.isEnabled ? BackgroundCallOutputProbe() : nil
        backgroundOutputProbe = probe
        #endif
        try receiver.rebuild(engine: engine, configuration: configuration, peers: peerIDs,
            rendersToHardware: rendersToHardware, startsClock: startsOutputClock) { [weak self] frame in
            activity?.record(frame)
            #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS)
            probe?.record(frame)
            #endif
            if self?.requestsOutputFrames.load(ordering: .acquiring) == true {
                outputDelivery.yield(frame)
            }
        }
        completed = true
    }

    func stop() {
        generation = UUID()
        frameDeliveries.forEach { $0.finish() }
        frameDeliveries.removeAll()
        nativeOutputActivity = nil
        #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS)
        backgroundOutputProbe = nil
        #endif
        receiver.stop()
        transmitter.stop()
    }

    /// Codec, rate and bitrates form one replaceable setting. Never expose an
    /// intermediate format to capture or publish a configuration rejected by DSP.
    func updateEncoding(preferred: AudioCodecIdentifier, format: AudioFormat,
                        aacELDv2BitRate: Int, opusBitRate: Int) throws {
        guard format.isValid else { throw AppAudioPipelineError.invalidFormat }
        var updated = configuration
        updated.preferredCodec = preferred
        updated.rtcSendFormat = format
        updated.aacELDv2BitRate = aacELDv2BitRate
        updated.opusBitRate = opusBitRate
        try transmitter.updateEncoding(updated.codecRuntimeReport.activeConfiguration)
        configuration = updated
    }

    var droppedRenderFrameCount: Int {
        receiver.droppedRenderFrameCount
            + frameDeliveries.reduce(0) { $0 + $1.droppedFrameCount }
    }

    func updateOutput(masterVolume: Float, isMuted: Bool, peerOutputVolumes: [String: Float]) {
        configuration.masterOutputVolume = min(2, max(0, masterVolume))
        configuration.isOutputMuted = isMuted
        configuration.peerOutputVolumes = peerOutputVolumes.mapValues { min(1, max(0, $0)) }
        receiver.updateOutput(masterVolume: masterVolume, isMuted: isMuted, peers: peerOutputVolumes)
    }

    func reconfigureInput<Result>(_ change: () -> Result) -> Result {
        receiver.reconfigureInput(change)
    }

    nonisolated func processCapturedFrame(_ frame: PCMFrame) throws { try transmitter.process(frame) }

    @discardableResult
    nonisolated func processReceivedAudioPacket(_ received: RTC.ReceivedAudioPacket,
        onPlayout: ((ReceivePlayoutDiagnostics) -> Void)? = nil) throws -> PCMFrame {
        try receiver.receive(received, onPlayout: onPlayout)
    }

    func processPlaybackFrame(_ frame: PCMFrame) throws { try receiver.play(frame) }
    func stopReceivePeer(_ peerID: String) throws { try receiver.removePeer(peerID) }
    nonisolated var receiveDecodeCounts: ReceiveDecodeCounts { receiver.decodeSnapshot }
    nonisolated func receivePlayoutDiagnostics(peerID: String) -> ReceivePlayoutDiagnostics? {
        receiver.playoutDiagnostics(peer: peerID)
    }

    func updateSoundIsolation(transmit: Bool, receiveMaster: Bool, peers: [String: Bool]) throws {
        configuration.transmitSoundIsolationEnabled = transmit
        configuration.receiveMasterSoundIsolationEnabled = receiveMaster
        configuration.peerSoundIsolationEnabled = peers
        try transmitter.updateIsolation(enabled: transmit)
        try receiver.updateIsolation(master: receiveMaster, peers: peers)
    }

    // Preserve quiet syllables when the send and receive classifiers are stacked.
    nonisolated static let transmitIsolationConfiguration = VoiceIsolationConfiguration(mix: 0.5)

    // Keep the mix across bypass so a reconnect uses the same dry signal.
    nonisolated static let receiveIsolationConfiguration = VoiceIsolationConfiguration(mix: 0.5)

    nonisolated static func makeIsolation(on bus: MixerBus, enabled: Bool,
        configuration: VoiceIsolationConfiguration) throws -> VoiceIsolationEffect? {
        guard VoiceIsolationSupport.isAvailable else { return nil }
        let effect = try VoiceIsolationEffect.make(configuration: configuration)
        effect.avAudioUnitEffect.bypass = !enabled
        try bus.addEffect(effect.node, id: "sound-isolation", bypassed: !enabled, state: enabled ? .active : .bypassed,
            parameters: Self.effectParameters(package: "SoundIsolation", label: "Isolation", detail: effect.configuration.soundType.rawValue))
        return effect
    }

    /// Settings and diagnostics change together for TX, each peer and RX master.
    /// Their owners retain preparation, locking and measured settling duration:
    /// TX is synchronous DSP; RX also has native render and playout reservations.
    nonisolated static func setIsolationEnabled(_ effect: VoiceIsolationEffect, on bus: MixerBus, enabled: Bool) throws {
        effect.avAudioUnitEffect.bypass = !enabled
        try bus.setEffectBypassed(id: "sound-isolation", bypassed: !enabled)
        try bus.updateEffectSnapshot(id: "sound-isolation", state: enabled ? .active : .bypassed)
    }

    nonisolated static func installLimiter(on bus: MixerBus) throws -> PeakLimiterEffect {
        let effect = try PeakLimiterEffect.make(configuration: .init(attackTime: 0.001))
        try bus.addEffect(effect.node, id: "peak-limiter", state: .active,
            parameters: Self.effectParameters(package: "PeakLimiter", label: "Limiter", detail: "Pre-gain \(effect.configuration.preGain) dB"))
        return effect
    }

    nonisolated static func effectParameters(package: String, label: String, detail: String) -> [MixerEffectParameterSnapshot] {
        [.init(id: "package", value: package), .init(id: "name", value: label),
         .init(id: "shortLabel", value: label), .init(id: "detail", value: detail)]
    }

    private func publishOutput(_ frame: PCMFrame) {
        // Silent render frames carry time too. Omitting them lets each phrase
        // restart at a different player boundary and shifts speech after pauses.
        onOutputFrame?(frame)
    }

}

nonisolated struct NativeOutputObservation: Sendable {
    let frameCount: Int
    let rms: Float
    let peakRMS: Float
    let lastAudibleAt: TimeInterval?
}

/// The existing call tick reads this bounded state without enqueueing PCM.
private nonisolated final class NativeOutputActivity: Sendable {
    private let renderTimestampBits = Atomic<UInt64>(0)
    private let audibleTimestampBits = Atomic<UInt64>(0)
    private let meter = Mutex(Meter())

    private struct Meter {
        var pendingFrames = 0
        var rms: Float = 0
        var peakRMS: Float = 0
        var peakWindow = VoicePeakWindow()
    }

    var lastRenderAt: TimeInterval? {
        let bits = renderTimestampBits.load(ordering: .relaxed)
        return bits == 0 ? nil : TimeInterval(bitPattern: bits)
    }

    var lastAudibleAt: TimeInterval? {
        let bits = audibleTimestampBits.load(ordering: .relaxed)
        return bits == 0 ? nil : TimeInterval(bitPattern: bits)
    }

    func record(_ frame: PCMFrame) {
        let now = Date().timeIntervalSince1970
        let level = AudioLevelMeter.rmsLevel(samples: frame.samples)
        meter.withLock {
            if let lastRenderAt, now - lastRenderAt > AppAudioPipeline.nativeOutputObservationLifetime {
                $0.peakWindow = VoicePeakWindow()
            }
            $0.pendingFrames += 1
            $0.rms = level
            $0.peakRMS = $0.peakWindow.record(level)
            renderTimestampBits.store(now.bitPattern, ordering: .relaxed)
            if level > AudioLevelMeter.audibleOutputThreshold {
                audibleTimestampBits.store(now.bitPattern, ordering: .relaxed)
            }
        }
    }

    func takeObservation() -> NativeOutputObservation? {
        meter.withLock {
            guard $0.pendingFrames > 0 else { return nil }
            let observation = NativeOutputObservation(frameCount: $0.pendingFrames,
                rms: $0.rms, peakRMS: $0.peakRMS, lastAudibleAt: lastAudibleAt)
            $0.pendingFrames = 0
            return observation
        }
    }
}
