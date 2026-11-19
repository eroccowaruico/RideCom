import AudioCore
import AudioMixer
import RTC
import Foundation

/// Pure projection of one captured input; owns no live state.
struct ReceivePipelinePresentation {
    let input: DiagnosticsInput
    let receivePeerStates: [String: PipelineStepState]

    init(input: DiagnosticsInput) {
        self.input = input
        let peerBusPrefix = "rx-peer-"
        var states: [String: PipelineStepState] = [:]
        if input.isAudioReady {
            for route in input.audioMixerSnapshot.routes
                where route.destinationBusID == "rx-master" && route.sourceBusID.hasPrefix(peerBusPrefix) {
                let peerID = String(route.sourceBusID.dropFirst(peerBusPrefix.count))
                let bus = input.mixerBusSnapshot(id: route.sourceBusID)
                let scheduled = bus?.sources.contains { $0.scheduledFrameCount > 0 } ?? false
                states[peerID] = scheduled ? .passing : .waiting
            }
        }
        receivePeerStates = states
    }

    private var receivePeerBusCount: Int { receivePeerStates.count }
    private var hasScheduledPeerAudio: Bool { receivePeerStates.values.contains(.passing) }

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

    var rtcReceiveStep: PipelineStep {
        guard input.isAudioReady else {
            return PipelineStep(
                id: "rtc-receive",
                package: "RTC",
                title: "RTC RX",
                detail: "Media Idle",
                icon: "dot.radiowaves.left.and.right",
                state: .idle,
                accessibilityIdentifier: "receive-pipeline-rtc-step"
            )
        }
        guard input.selectedGroupConnectionState == .localConnected || input.selectedGroupConnectionState == .internetConnected else {
            return PipelineStep(
                id: "rtc-receive",
                package: "RTC",
                title: "RTC RX",
                detail: "Control Waiting",
                icon: "dot.radiowaves.left.and.right",
                state: .waiting,
                accessibilityIdentifier: "receive-pipeline-rtc-step"
            )
        }
        let received = input.receivedVoicePacketCount
        let dropped = input.droppedAudioPacketCount
        let peers = "\(input.routeLabel) / C \(input.connectedPeerCount) / A \(input.authenticatedPeerCount)"
        let media = received > 0 || dropped > 0 ? " / RX \(received)" : ""
        let failures = dropped > 0 ? " / DROP \(dropped)" : ""
        return PipelineStep(
            id: "rtc-receive",
            package: "RTC",
            title: "RTC RX",
            detail: peers + media + failures,
            icon: "dot.radiowaves.left.and.right",
            state: received > 0 ? .passing : .waiting,
            accessibilityIdentifier: "receive-pipeline-rtc-step"
        )
    }

    var codecDecodeStep: PipelineStep {
        guard input.isAudioReady else {
            return PipelineStep(
                id: "codec-decode",
                package: "Codec",
                title: "Decode",
                detail: "Not available",
                icon: "cpu",
                state: .idle,
                accessibilityIdentifier: "receive-pipeline-codec-step"
            )
        }
        let counts = input.receiveDecodeCounts
        let hasPCM = counts.pcmPackets > 0
        let pcm = hasPCM || counts.failures > 0 ? "PCM \(counts.pcmPackets)" : "No PCM observed"
        let failures = counts.failures > 0 ? " / Decode errors \(counts.failures)" : ""
        return PipelineStep(
            id: "codec-decode",
            package: "Codec",
            title: "Decode",
            detail: pcm + failures,
            icon: hasPCM ? "cpu.fill" : "cpu",
            state: hasPCM ? .passing : .waiting,
            accessibilityIdentifier: "receive-pipeline-codec-step"
        )
    }

    var peerBusStep: PipelineStep {
        guard input.isAudioReady else {
            return PipelineStep(
                id: "peer-bus",
                package: "AudioMixer",
                title: "Peer Buses",
                detail: "Not available",
                icon: "person.2.wave.2",
                state: .idle,
                accessibilityIdentifier: "receive-pipeline-peer-bus-step"
            )
        }
        return PipelineStep(
            id: "peer-bus",
            package: "AudioMixer",
            title: "Peer Buses",
            detail: "\(receivePeerBusCount) peer buses",
            icon: "person.2.wave.2",
            state: hasScheduledPeerAudio ? .passing : .waiting,
            accessibilityIdentifier: "receive-pipeline-peer-bus-step"
        )
    }

    var receiveMixStep: PipelineStep {
        guard input.isAudioReady else {
            return PipelineStep(
                id: "receive-mix",
                package: "AudioMixer",
                title: "Mix Down",
                detail: "Not available",
                icon: "arrow.triangle.merge",
                state: .idle,
                accessibilityIdentifier: "receive-pipeline-mix-step"
            )
        }
        let routeLabel = receivePeerBusCount == 1 ? "route" : "routes"
        return PipelineStep(
            id: "receive-mix",
            package: "AudioMixer",
            title: "Mix Down",
            detail: "\(receivePeerBusCount) \(routeLabel) → rx-master",
            icon: "arrow.triangle.merge",
            state: hasScheduledPeerAudio ? .passing : .waiting,
            accessibilityIdentifier: "receive-pipeline-mix-step"
        )
    }

    var masterBusStep: PipelineStep {
        guard input.isAudioReady else {
            return PipelineStep(
                id: "master-bus",
                package: "AudioMixer",
                title: "RX Master",
                detail: "Not available",
                icon: "waveform.path.ecg",
                state: .idle,
                accessibilityIdentifier: "receive-pipeline-master-bus-step"
            )
        }
        let bus = input.mixerBusSnapshot(id: "rx-master")
        return PipelineStep(
            id: "master-bus",
            package: "AudioMixer",
            title: "RX Master",
            detail: bus.map { "\(receivePeerBusCount) in / \($0.effectCount) FX / OUT \(Int($0.volume * 100))%" }
                ?? "\(receivePeerBusCount) in / OUT \(Int(input.masterOutputVolume * 100))%",
            icon: "waveform.path.ecg",
            state: hasScheduledPeerAudio ? .passing : .waiting,
            accessibilityIdentifier: "receive-pipeline-master-bus-step"
        )
    }

    var masterEffectChainStep: PipelineStep {
        guard input.isAudioReady else {
            return PipelineStep(
                id: "master-effects",
                package: "AudioMixer",
                title: "Master FX",
                detail: "Not available",
                icon: "wand.and.sparkles",
                state: .idle,
                accessibilityIdentifier: "receive-pipeline-master-effects-step"
            )
        }
        return PipelineStep(
            id: "master-effects",
            package: "AudioMixer",
            title: "Master FX",
            detail: input.receiveMasterEffectChainSnapshot.summary,
            icon: "wand.and.sparkles",
            state: aggregateState(masterEffectStages.map(\.state)),
            accessibilityIdentifier: "receive-pipeline-master-effects-step"
        )
    }

    var outputStep: PipelineStep {
        if input.isOutputMuted || input.masterOutputVolume == 0 {
            return PipelineStep(
                id: "output",
                package: "SessionManager",
                title: "Output",
                detail: input.isOutputMuted ? "Muted" : "Volume 0%",
                icon: "speaker.slash.fill",
                state: input.isOutputMuted ? .muted : .waiting,
                accessibilityIdentifier: "receive-pipeline-output-step"
            )
        }
        guard input.isAudioReady else {
            return PipelineStep(
                id: "output",
                package: "SessionManager",
                title: "Output",
                detail: "Not available",
                icon: "speaker",
                state: .idle,
                accessibilityIdentifier: "receive-pipeline-output-step"
            )
        }
        var state = PipelineStepState.waiting
        let detail: String
        if input.usesNativeOutput {
            if let timestamp = input.lastNativeAudibleOutputAt {
                let age = max(0, input.capturedAt - timestamp)
                state = age <= 2 ? .passing : .waiting
                detail = "Last audible PCM · \(Int(age))s ago"
            } else {
                detail = "No audible PCM observed"
            }
        } else if let timestamp = input.lastPlaybackScheduledAt {
            let age = max(0, input.capturedAt - timestamp)
            detail = "Playback scheduled · \(Int(age))s ago / Render not measured"
        } else {
            detail = "No playback scheduled / Render not measured"
        }
        return PipelineStep(
            id: "output",
            package: "SessionManager",
            title: "Output",
            detail: detail,
            icon: "speaker.wave.2.fill",
            state: state,
            accessibilityIdentifier: "receive-pipeline-output-step"
        )
    }

    var masterEffectStages: [EffectChainStage] {
        input.receiveMasterEffectChainSnapshot.stages.map(EffectChainStage.init(snapshot:))
    }

    var receiveMasterMix: ReceiveMasterMixSnapshot {
        ReceiveMasterMixSnapshot(
            sourceBusCount: receivePeerBusCount,
            receivedFrameCount: input.receivedVoicePacketCount,
            outputLevel: input.diagnosticsOutputLevel,
            outputPeakLevel: input.diagnosticsOutputPeakLevel,
            masterVolume: input.masterOutputVolume,
            effectSummary: input.receiveMasterEffectChainSnapshot.compactSummary,
            isMuted: input.isOutputMuted,
            state: masterBusStep.state
        )
    }

    private func aggregateState(_ states: [PipelineStepState]) -> PipelineStepState {
        if states.contains(.blocked) { return .blocked }
        if states.contains(.waiting) { return .waiting }
        if states.contains(.passing) { return .passing }
        return .idle
    }
}
