import AudioCore
import AudioMixer
import RTC
import Codec
import VADGate
import SoundIsolation
import Foundation

/// Pure projection of one captured input; owns no live state.
struct ReceivePipelinePresentation {
    private static let peerBusPrefix = "rx-peer-"
    let input: DiagnosticsInput
    let receivePeerStates: [String: PipelineStepState]

    init(input: DiagnosticsInput) {
        self.input = input
        var states: [String: PipelineStepState] = [:]
        if input.isAudioReady {
            for route in input.audioMixerSnapshot.routes
                where route.destinationBusID == "rx-master" && route.sourceBusID.hasPrefix(Self.peerBusPrefix) {
                let peerID = String(route.sourceBusID.dropFirst(Self.peerBusPrefix.count))
                let bus = input.mixerBusSnapshot(id: route.sourceBusID)
                let lastScheduledAt = bus?.sources.compactMap(\.lastScheduledAt).max()
                states[peerID] = Self.observation(lastScheduledAt, now: input.capturedAt).state
            }
        }
        receivePeerStates = states
    }

    func playoutDetail(for peerID: String) -> String {
        guard receivePeerStates[peerID] != nil,
              let bus = input.mixerBusSnapshot(id: Self.peerBusPrefix + peerID),
              let source = bus.sources.first(where: { $0.bufferedDuration != nil }),
              let duration = source.bufferedDuration else { return "Playout: Not measured" }
        let queued = String(format: "%.0f ms", duration * 1_000)
        let adjustments = source.playoutAdjustmentCount.map(String.init) ?? "Not measured"
        return "Playout: \(queued) queued / Adjustments: \(adjustments) / Resets: \(source.playbackResetCount)"
    }

    private var receivePeerBusCount: Int { receivePeerStates.count }
    private var mixState: PipelineStepState { receivePeerStates.values.contains(.passing) ? .passing : .waiting }

    private var outputBusDetail: String {
        let bus = input.mixerBusSnapshot(id: "rx-master")
        return bus.map { "\(receivePeerBusCount) in / \($0.effectCount) FX / OUT \(Int($0.volume * 100))%" }
            ?? "\(receivePeerBusCount) in / OUT \(Int(input.outputVolume * 100))%"
    }

    private func receiveMixerStep(id: String, title: String, icon: String,
                                  detail: @autoclosure () -> String, state: @autoclosure () -> PipelineStepState,
                                  accessibilityIdentifier: String) -> PipelineStep {
        PipelineStep(
            id: id, package: "AudioMixer", title: title, detail: input.isAudioReady ? detail() : "Not available",
            icon: icon, state: input.isAudioReady ? state() : .idle, accessibilityIdentifier: accessibilityIdentifier
        )
    }

    var receiveParticipants: [GroupMember] {
        let members = Array(input.selectedGroup?.members.dropFirst() ?? [])
        let knownIDs = Set(members.map(\.id))
        let authenticated = Set(input.authenticatedPeerIDs)
        let extraIDs = authenticated.union(receivePeerStates.keys).subtracting(knownIDs).sorted()
        return members + extraIDs.map { id in
            GroupMember(id: id, displayName: id,
                authenticationState: authenticated.contains(id) ? .authenticated : .open,
                connectionState: authenticated.contains(id) ? .connected : .offline)
        }
    }

    struct PeerDetail {
        let status: RTCRuntimeStatus?
        let codec: CodecRuntimeReport?
        let vad: VADGateRuntimeSnapshot?
        let isolation: VoiceIsolationRuntimeSnapshot?
        let paths: String
        let effectSummary: String
        let volume: Float
        let age: Int?
        let isStale: Bool
    }

    func peerDetail(for peerID: String) -> PeerDetail {
        let status = input.receivePeerRuntimeStatuses[peerID]
        let paths = input.receiveNetworkDiagnostics?.peers.filter { $0.peerID.rawValue == peerID } ?? []
        let age = status.map { max(0, input.capturedAt - $0.generatedAt) }
        return PeerDetail(
            status: status,
            codec: status?.packageReports.first { $0.package == "Codec" }
                .flatMap { try? $0.decodeJSON(CodecRuntimeReport.self) },
            vad: status?.packageReports.first { $0.package == "VADGate" }
                .flatMap { try? $0.decodeJSON(VADGateRuntimeSnapshot.self) },
            isolation: status?.packageReports.first { $0.package == "SoundIsolation" && $0.kind == "transmitRuntimeSnapshot" }
                .flatMap { try? $0.decodeJSON(VoiceIsolationRuntimeSnapshot.self) },
            paths: paths.isEmpty ? "Path not measured" : paths.map {
                $0.route == .webRTC ? "Internet" : ($0.path.count > 2 ? "Local relayed" : "Local direct")
            }.joined(separator: ", "),
            effectSummary: input.receivePeerEffectChainSnapshot(peerID: peerID).summary,
            volume: input.receivePeerVolumes[peerID] ?? IntercomViewModel.defaultRemoteOutputVolume,
            age: age.map(Int.init), isStale: (age ?? 0) > 15
        )
    }

    var rtcReceiveStep: PipelineStep {
        let value: (detail: String, state: PipelineStepState)
        if !input.isAudioReady {
            value = ("Media Idle", .idle)
        } else if input.selectedGroupConnectionState != .localConnected && input.selectedGroupConnectionState != .internetConnected {
            value = ("Control Waiting", .waiting)
        } else {
            let received = input.receivedVoicePacketCount
            let dropped = input.droppedAudioPacketCount
            let peers = "\(input.routeLabel) / C \(input.connectedPeerCount) / A \(input.authenticatedPeerCount)"
            let receipt = observation(input.lastReceivedAudioAt)
            let lastReceipt = receipt.elapsed.map { " / Last receipt · \($0)" } ?? " / Receipt time not measured"
            let media = received > 0 || dropped > 0 ? " / RX \(received)" : ""
            let failures = dropped > 0 ? " / DROP \(dropped)" : ""
            value = (peers + media + lastReceipt + failures, receipt.state)
        }
        return PipelineStep(
            id: "rtc-receive", package: "RTC", title: "RTC RX", detail: value.detail,
            icon: "dot.radiowaves.left.and.right", state: value.state,
            accessibilityIdentifier: "receive-pipeline-rtc-step"
        )
    }

    var codecDecodeStep: PipelineStep {
        let counts = input.receiveDecodeCounts
        let hasPCM = input.isAudioReady && counts.pcmPackets > 0
        let value: (detail: String, state: PipelineStepState)
        if input.isAudioReady {
            let pcm = hasPCM || counts.failures > 0 ? "PCM \(counts.pcmPackets)" : "No PCM observed"
            let decoded = observation(counts.lastPCMAt)
            let lastPCM = decoded.elapsed.map { " / Last PCM · \($0)" } ?? ""
            let failures = counts.failures > 0 ? " / Decode errors \(counts.failures)" : ""
            let failure = observation(counts.lastFailureAt)
            let lastError = failure.elapsed.map { " / Last error · \($0)" } ?? ""
            let blocked = decoded.state == .waiting && failure.state == .passing
            value = (pcm + lastPCM + failures + lastError, blocked ? .blocked : decoded.state)
        } else {
            value = ("Not available", .idle)
        }
        return PipelineStep(
            id: "codec-decode", package: "Codec", title: "Decode", detail: value.detail,
            icon: hasPCM ? "cpu.fill" : "cpu", state: value.state,
            accessibilityIdentifier: "receive-pipeline-codec-step"
        )
    }

    var peerBusStep: PipelineStep {
        receiveMixerStep(id: "peer-bus", title: "Peer Buses", icon: "person.2.wave.2",
            detail: "\(receivePeerBusCount) peer buses", state: mixState,
            accessibilityIdentifier: "receive-pipeline-peer-bus-step")
    }

    var receiveMixStep: PipelineStep {
        let routeLabel = receivePeerBusCount == 1 ? "route" : "routes"
        return receiveMixerStep(id: "receive-mix", title: "Mix Down", icon: "arrow.triangle.merge",
            detail: "\(receivePeerBusCount) \(routeLabel) → rx-master", state: mixState,
            accessibilityIdentifier: "receive-pipeline-mix-step")
    }

    var outputBusStep: PipelineStep {
        receiveMixerStep(id: "master-bus", title: "RX Master", icon: "waveform.path.ecg",
            detail: outputBusDetail, state: mixState, accessibilityIdentifier: "receive-pipeline-master-bus-step")
    }

    var outputEffectChainStep: PipelineStep {
        receiveMixerStep(id: "master-effects", title: "Master FX", icon: "wand.and.sparkles",
            detail: input.receiveOutputEffectChainSnapshot.summary, state: aggregateState(outputEffectStages.map(\.state)),
            accessibilityIdentifier: "receive-pipeline-master-effects-step")
    }

    var outputStep: PipelineStep {
        let value: (detail: String, icon: String, state: PipelineStepState)
        if input.isOutputMuted {
            value = ("Muted", "speaker.slash.fill", .muted)
        } else if input.outputVolume == 0 {
            value = ("Volume 0%", "speaker.slash.fill", .waiting)
        } else if !input.isAudioReady {
            value = ("Not available", "speaker", .idle)
        } else if input.usesNativeOutput {
            let lifetime = AppAudioPipeline.nativeOutputObservationLifetime
            let output = observation(input.lastNativeAudibleOutputAt, maximumAge: lifetime)
            let audible = output.elapsed.map { "Last audible PCM · \($0)" } ?? "No audible PCM observed"
            let rendered = observation(input.lastNativeRenderAt, maximumAge: lifetime)
            let render = rendered.elapsed.map { " / Last render · \($0)" } ?? ""
            value = (audible + render, "speaker.wave.2.fill", output.state)
        } else if let elapsed = observation(input.lastPlaybackScheduledAt).elapsed {
            value = ("Playback scheduled · \(elapsed) / Render not measured", "speaker.wave.2.fill", .waiting)
        } else {
            value = ("No playback scheduled / Render not measured", "speaker.wave.2.fill", .waiting)
        }
        return PipelineStep(
            id: "output", package: "SessionManager", title: "Output", detail: value.detail,
            icon: value.icon, state: value.state, accessibilityIdentifier: "receive-pipeline-output-step"
        )
    }

    var outputEffectStages: [EffectChainStage] {
        input.receiveOutputEffectChainSnapshot.stages.map(EffectChainStage.init(snapshot:))
    }

    var receiveOutputMix: ReceiveOutputMixSnapshot {
        ReceiveOutputMixSnapshot(
            sourceBusCount: receivePeerBusCount,
            receivedFrameCount: input.receivedVoicePacketCount,
            outputLevel: input.diagnosticsOutputLevel,
            outputPeakLevel: input.diagnosticsOutputPeakLevel,
            outputVolume: input.outputVolume,
            effectSummary: input.receiveOutputEffectChainSnapshot.compactSummary,
            isMuted: input.isOutputMuted,
            state: outputBusStep.state
        )
    }

    private func observation(_ timestamp: TimeInterval?, maximumAge: TimeInterval = 2) -> (state: PipelineStepState, elapsed: String?) {
        Self.observation(timestamp, now: input.capturedAt, maximumAge: maximumAge)
    }

    private static func observation(_ timestamp: TimeInterval?, now: TimeInterval,
                                    maximumAge: TimeInterval = 2) -> (state: PipelineStepState, elapsed: String?) {
        guard let timestamp else { return (.waiting, nil) }
        let age = max(0, now - timestamp)
        return (age <= maximumAge ? .passing : .waiting, "\(Int(age))s ago")
    }

    private func aggregateState(_ states: [PipelineStepState]) -> PipelineStepState {
        if states.contains(.blocked) { return .blocked }
        if states.contains(.waiting) { return .waiting }
        if states.contains(.passing) { return .passing }
        return .idle
    }
}
