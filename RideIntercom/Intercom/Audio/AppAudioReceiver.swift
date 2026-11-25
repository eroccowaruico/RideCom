import AVFAudio
import AudioCore
import AudioMixer
import Codec
import Foundation
import PeakLimiter
import RTC
import SoundIsolation
import Synchronization

/// The receive graph has one serial owner independent of UI/control. The lock
/// covers native graph changes as well as packet decoding/scheduling; no await,
/// UI callback or network operation occurs while holding it.
nonisolated final class AppAudioReceiver: @unchecked Sendable {
    private struct PacketEncoding: Equatable {
        let codec: RTCAudioCodecIdentifier
        let format: RTCAudioFormat
        let bitRate: Int?
    }

    private final class PeerPlayback {
        lazy var decoder = StreamingCodecDecoder()
        var source: MixerPCMSource?
        var scheduledEncoding: PacketEncoding?
        var lastPCM: CodecOutputObservation?
    }

    private enum IsolationTarget: Hashable {
        case mix
        case peer(String)

        var busID: String {
            switch self {
            case .mix: "rx-master"
            case .peer(let id): "rx-peer-\(id)"
            }
        }

        func isEnabled(mix: Bool, peers: [String: Bool]) -> Bool {
            switch self {
            case .mix: mix
            case .peer(let id): peers[id] ?? false
            }
        }
    }

    private struct IsolationChange {
        let target: IsolationTarget
        let effect: VoiceIsolationEffect
        let enabled: Bool
    }

    private let lock = NSRecursiveLock()
    private let graphGeneration = Atomic<UInt64>(0)
    private var mixer: AudioMixer?
    private var configuration = AppAudioPipelineConfiguration()
    private var mixBus: MixerBus?
    private var peerPlayback: [String: PeerPlayback] = [:]
    private var effects: [IsolationTarget: VoiceIsolationEffect] = [:]
    private var limiter: PeakLimiterEffect?
    private var decodeCounts = ReceiveDecodeCounts()

    func rebuild(engine: AVAudioEngine, configuration: AppAudioPipelineConfiguration, peers: [String],
                 rendersToHardware: Bool, startsClock: Bool = true, onOutput: @escaping (PCMFrame) -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        stopGraph()
        graphGeneration.wrappingAdd(1, ordering: .releasing)
        defer { graphGeneration.wrappingAdd(1, ordering: .releasing) }
        self.configuration = configuration
        // Use the device clock within the configured DSP rate budget. Avoid a
        // second fractional converter on 44.1 kHz outputs, without doubling
        // every receive effect's work for a 96 kHz external device.
        let receiveFormat = AudioFormat(
            sampleRate: min(configuration.outputHardwareFormat.sampleRate, configuration.mixerFormat.sampleRate),
            channelCount: configuration.mixerFormat.channelCount
        )
        let mixer = try AudioMixer(engine: engine, audioFormat: receiveFormat)
        self.mixer = mixer
        let mixBus = try mixer.createBus(IsolationTarget.mix.busID)
        self.mixBus = mixBus
        mixBus.volume = configuration.isOutputMuted ? 0 : configuration.overallOutputVolume
        try installIsolation(for: .mix, on: mixBus)
        let output = try mixer.createBus("rx-output")
        limiter = try AppAudioPipeline.installLimiter(on: output)
        try mixer.route(mixBus, to: output)
        // Hardware playback follows the graph directly. Batch only its meter
        // observer, avoiding one MainActor delivery per native render quantum.
        // The fallback output consumes these frames, so it must never wait.
        _ = try output.installPCMSink(id: "speaker-output", targetFormat: configuration.outputHardwareFormat,
            packetDuration: rendersToHardware ? 0.02 : nil,
            maximumFrameDuration: 0.02) { frame, _ in onOutput(frame) }
        let device = try mixer.createBus("engine-output")
        device.volume = rendersToHardware ? 1 : 0
        try mixer.route(output, to: device)
        try mixer.routeToOutput(device)
        for peer in peers { _ = try source(for: peer) }
        if startsClock { try startGraph() }
    }

    func start() throws {
        try lock.withLock { try startGraph() }
    }

    private func startGraph() throws {
        guard let mixer else { throw AppAudioPipelineError.notConfigured }
        try mixer.start()
        for playback in peerPlayback.values { playback.source?.start() }
    }

    func setHardwareOutputEnabled(_ enabled: Bool) {
        lock.withLock { mixer?.bus("engine-output")?.volume = enabled ? 1 : 0 }
    }

    func stop() {
        lock.withLock { stopGraph() }
    }

    private func stopGraph() {
        // Revoke receivers already waiting for this lock, even if stop is
        // immediately followed by rebuild and their Task was not cancelled.
        graphGeneration.wrappingAdd(2, ordering: .releasing)
        mixer?.stop()
        if let mixer { for id in mixer.busIDs { try? mixer.removeBus(id) } }
        mixer = nil; mixBus = nil; limiter = nil
        peerPlayback.removeAll(); effects.removeAll()
        decodeCounts = .init()
    }

    func receive(_ received: RTC.ReceivedAudioPacket,
                 onPlayout: ((ReceivePlayoutDiagnostics) -> Void)? = nil) throws -> PCMFrame {
        let generation = graphGeneration.load(ordering: .acquiring)
        guard generation.isMultiple(of: 2) else { throw AppAudioPipelineError.notConfigured }
        var observation: ReceivePlayoutDiagnostics?
        // Jitter learning uses arrival at the App, before the graph lock and decoder.
        let arrivedAt = ProcessInfo.processInfo.systemUptime
        var timing = onPlayout.map { _ in ReceiveProcessingTiming(lockRequestedAt: arrivedAt) }
        lock.lock()
        timing?.lockAcquiredAt = ProcessInfo.processInfo.systemUptime
        defer {
            lock.unlock()
            if let observation { onPlayout?(observation) }
        }
        // Cancellation is checked after acquiring the graph, so an old RTC
        // consumer waiting behind stop/rebuild cannot enter the new call.
        guard !Task.isCancelled, mixer != nil,
              generation == graphGeneration.load(ordering: .acquiring) else {
            throw AppAudioPipelineError.notConfigured
        }
        let id = received.peerID.rawValue
        let playback = playback(for: id)
        let previousAdjustmentCount = onPlayout == nil ? nil : (playback.source?.playoutAdjustmentCount ?? 0)
        let decoder = playback.decoder
        let packet = received.packet
        let frame = try decode(packet, using: decoder)
        timing?.decodedAt = ProcessInfo.processInfo.systemUptime
        var reservation: MixerPlayoutReservation?
        if !frame.samples.isEmpty {
            let decoded = CodecOutputObservation(codec: packet.codec, observedAt: Date().timeIntervalSince1970)
            decodeCounts.pcmPackets += 1
            decodeCounts.lastPCM = decoded
            playback.lastPCM = decoded
            let observeReservation: ((MixerPlayoutReservation) -> Void)? = onPlayout.map { _ in { reservation = $0 } }
            let encoding = PacketEncoding(codec: packet.codec, format: packet.format, bitRate: packet.bitRate)
            let changedEncoding = playback.scheduledEncoding.map { $0 != encoding } ?? false
            let sendQueueAge = packet.capturedAt == frame.capturedAt ? packet.captureToSendQueue : nil
            if try scheduleInGraph(frame, peer: id, packetizationJitter: decoder.packetizationJitterDuration,
                                   arrivedAt: arrivedAt, startsNewArrivalTiming: changedEncoding,
                                   captureToSendQueue: sendQueueAge,
                                   onReservation: observeReservation) {
                // Empty decoder priming and sub-sample conversion don't start a new timing baseline.
                playback.scheduledEncoding = encoding
            }
            timing?.reservedAt = ProcessInfo.processInfo.systemUptime
        }
        if let previousAdjustmentCount, let source = playback.source {
            observation = .init(source: source, previousAdjustmentCount: previousAdjustmentCount,
                                processingTiming: timing, reservation: reservation)
        }
        return frame
    }

    private func decode(_ packet: RTCAudioPacket, using decoder: StreamingCodecDecoder) throws -> PCMFrame {
        do { return try AppAudioCodecBridge.decode(packet, using: decoder) } catch {
            decodeCounts.failures += 1
            decodeCounts.lastFailureAt = Date().timeIntervalSince1970
            throw error
        }
    }

    func play(_ frame: PCMFrame, peer: String = "audio-check", packetizationJitter: TimeInterval = 0) throws {
        _ = try lock.withLock { try scheduleInGraph(frame, peer: peer, packetizationJitter: packetizationJitter) }
    }

    // Both receive and Audio Check hold the graph lock before scheduling.
    private func scheduleInGraph(_ frame: PCMFrame, peer: String, packetizationJitter: TimeInterval,
                                 arrivedAt: TimeInterval? = nil,
                                 startsNewArrivalTiming: Bool = false,
                                 captureToSendQueue: TimeInterval? = nil,
                                 onReservation: ((MixerPlayoutReservation) -> Void)? = nil) throws -> Bool {
        let source = try source(for: peer)
        let report = try source.schedule(frame, packetizationJitter: packetizationJitter,
                                         arrivedAt: arrivedAt ?? ProcessInfo.processInfo.systemUptime,
                                         startsNewArrivalTiming: startsNewArrivalTiming,
                                         captureToSendQueue: captureToSendQueue, onReservation: onReservation)
        return report.outputSampleCount > 0
    }

    func preparePeer(_ peer: String) { lock.withLock { _ = try? source(for: peer) } }
    func removePeer(_ peer: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard peerPlayback.removeValue(forKey: peer)?.source != nil else { return }
        let target = IsolationTarget.peer(peer)
        try mixer?.removeBus(target.busID)
        effects.removeValue(forKey: target)
    }

    func playbackDrainDuration(peer: String) -> TimeInterval {
        lock.withLock {
            guard let source = peerPlayback[peer]?.source else { return 0 }
            // Include downstream effects/device latency and two 20 ms meter
            // packets so stopping cannot discard the final rendered samples.
            return source.bufferedDuration + source.playerNode.outputPresentationLatency + 0.04
        }
    }

    func updateOutput(overallVolume: Float, isMuted: Bool, peers: [String: Float]) {
        lock.lock(); defer { lock.unlock() }
        configuration.overallOutputVolume = min(2, max(0, overallVolume))
        configuration.isOutputMuted = isMuted
        configuration.peerOutputVolumes = peers.mapValues { min(1, max(0, $0)) }
        mixBus?.volume = isMuted ? 0 : configuration.overallOutputVolume
        for (id, playback) in peerPlayback { playback.source?.volume = configuration.peerOutputVolumes[id] ?? 1 }
    }

    /// Input and output share an engine. Reopening native I/O invalidates the
    /// players' reservations even when their isPlaying flag remains true.
    func reconfigureInput<Result>(_ change: () -> Result) -> Result {
        lock.lock(); defer { lock.unlock() }
        graphGeneration.wrappingAdd(1, ordering: .releasing)
        defer { graphGeneration.wrappingAdd(1, ordering: .releasing) }
        let output = mixer?.bus("rx-output")
        return withOutputProtection(
            output,
            settlingDuration: { output?.processingLatency ?? 0 },
            perform: {
                let result = change()
                for playback in peerPlayback.values {
                    guard let source = playback.source else { continue }
                    source.stop(); source.start()
                }
                return result
            }
        )
    }

    private func playback(for peer: String) -> PeerPlayback {
        if let playback = peerPlayback[peer] { return playback }
        let playback = PeerPlayback()
        peerPlayback[peer] = playback
        return playback
    }

    private func source(for peer: String) throws -> MixerPCMSource {
        if let source = peerPlayback[peer]?.source { return source }
        guard let mixer, let mixBus else { throw AppAudioPipelineError.notConfigured }
        let target = IsolationTarget.peer(peer)
        let bus = try mixer.createBus(target.busID)
        defer {
            if peerPlayback[peer]?.source == nil {
                effects.removeValue(forKey: target)
                try? mixer.removeBus(target.busID)
            }
        }
        try installIsolation(for: target, on: bus)
        if effects[target] != nil {
            try bus.prepareOutputTransition()
        }
        let source = try bus.addPCMSource(id: "rtc-audio-\(peer)",
            maximumBufferedDuration: configuration.receiveMaximumBufferedDuration
                ?? configuration.maximumBufferedDuration,
            captureTimePlayoutDelay: configuration.receivePlayoutDelay,
            adaptivePlayout: configuration.receivePlayoutDelay != nil)
        source.volume = configuration.peerOutputVolumes[peer] ?? 1
        try mixer.route(bus, to: mixBus)
        playback(for: peer).source = source
        if mixer.engine.isRunning { source.start() }
        return source
    }

    private func installIsolation(for target: IsolationTarget, on bus: MixerBus) throws {
        let enabled = target.isEnabled(mix: configuration.receiveMixSoundIsolationEnabled,
                                       peers: configuration.peerSoundIsolationEnabled)
        if let effect = try AppAudioPipeline.makeIsolation(on: bus, enabled: enabled,
            configuration: AppAudioPipeline.receiveIsolationConfiguration) {
            effects[target] = effect
        }
    }

    deinit { mixer?.stop() }
}

extension AppAudioReceiver {
    /// Protect only the output whose native receive connections change.
    nonisolated func updateIsolation(forMix enabled: Bool, peers: [String: Bool]) throws {
        // Allocate existing disconnected effects while the old graph plays.
        // Settings and lifecycle serialize changes to these effects. Reception
        // can add a peer, so select the affected buses again under the lock.
        let preparation = lock.withLock {
            isolationChanges(mix: enabled, peers: peers).compactMap { change in
                change.enabled ? mixer?.bus(change.target.busID) : nil
            }
        }
        for bus in preparation { try bus.prepareEffect(id: "sound-isolation") }
        lock.lock(); defer { lock.unlock() }
        configuration.receiveMixSoundIsolationEnabled = enabled
        configuration.peerSoundIsolationEnabled = peers
        let changes = isolationChanges(mix: enabled, peers: peers)
        // Only a change to the receive mix invalidates all player reservations. The
        // lock already serializes a peer's reconnection with packet scheduling.
        let changesMix = changes.contains { $0.target == .mix }
        let output = changesMix ? mixer?.bus("rx-output") : nil
        let playoutDelay = configuration.receivePlayoutDelay ?? 0
        if changesMix { graphGeneration.wrappingAdd(1, ordering: .releasing) }
        defer {
            if changesMix { graphGeneration.wrappingAdd(1, ordering: .releasing) }
        }
        let previousLatency = changes.filter { !$0.enabled }.map { $0.effect.node.latency }.max() ?? 0
        try withOutputProtection(
            output,
            settlingDuration: {
                let nextLatency = changes.filter { $0.enabled }.map { $0.effect.node.latency }.max() ?? 0
                return max(previousLatency, nextLatency) + (output?.processingLatency ?? 0) + playoutDelay
            },
            perform: {
                for change in changes {
                    guard let bus = mixer?.bus(change.target.busID) else { throw AppAudioPipelineError.notConfigured }
                    let previousLatency = change.enabled ? 0 : change.effect.node.latency
                    try withOutputProtection(
                        changesMix ? nil : bus,
                        settlingDuration: {
                            let nextLatency = change.enabled ? change.effect.node.latency : 0
                            return max(previousLatency, nextLatency) + playoutDelay
                        },
                        perform: {
                            try AppAudioPipeline.setIsolationEnabled(change.effect, on: bus, enabled: change.enabled)
                        }
                    )
                }
            }
        )
    }

    /// Hold this output through the native change and always release it, using
    /// the settling time observed after the change. Callers choose the scope.
    private nonisolated func withOutputProtection<Result>(
        _ bus: MixerBus?,
        settlingDuration: () -> TimeInterval,
        perform change: () throws -> Result
    ) rethrows -> Result {
        guard let bus else { return try change() }
        bus.beginSinkTransition(settlingDuration: 0, holding: true)
        defer { bus.beginSinkTransition(settlingDuration: settlingDuration()) }
        return try change()
    }

    private nonisolated func isolationChanges(mix: Bool, peers: [String: Bool]) -> [IsolationChange] {
        effects.compactMap { target, effect in
            let enabled = target.isEnabled(mix: mix, peers: peers)
            return effect.avAudioUnitEffect.bypass == enabled
                ? IsolationChange(target: target, effect: effect, enabled: enabled) : nil
        }
    }
}

extension AppAudioReceiver {
    var snapshot: AudioMixerSnapshot {
        lock.withLock { mixer?.snapshot() ?? .init(busIDs: [], buses: [], routes: [], outputBusID: nil) }
    }
    var isolationSnapshots: [String: VoiceIsolationRuntimeSnapshot] {
        lock.withLock { Dictionary(uniqueKeysWithValues: effects.map { ($0.key.busID, $0.value.runtimeSnapshot) }) }
    }
    var limiterSnapshot: PeakLimiterRuntimeSnapshot? { lock.withLock { limiter?.runtimeSnapshot } }
    var droppedRenderFrameCount: Int {
        lock.withLock { (mixer?.busIDs ?? []).reduce(0) { $0 + (mixer?.bus($1)?.droppedCaptureFrameCount ?? 0) } }
    }

    var decodeSnapshot: ReceiveDecodeCounts { lock.withLock { decodeCounts } }
    var decodeDiagnostics: ReceiveDecodeDiagnostics {
        lock.withLock {
            .init(counts: decodeCounts, peerPCM: peerPlayback.compactMapValues(\.lastPCM))
        }
    }

    func playoutDiagnostics(peer: String) -> ReceivePlayoutDiagnostics? {
        lock.withLock {
            guard let source = peerPlayback[peer]?.source else { return nil }
            return .init(source: source)
        }
    }
}
