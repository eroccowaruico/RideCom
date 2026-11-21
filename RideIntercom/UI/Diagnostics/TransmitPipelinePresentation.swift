import AudioCore
import AudioMixer
import Foundation
import RTC
import SessionManager
import VADGate

/// Pure projection of one captured input; owns no live state.
struct TransmitPipelinePresentation {
    let input: DiagnosticsInput

    var voiceActivityAnalysis: VADGateAnalysis? {
        guard input.isAudioReady, !input.isMuted else { return nil }
        return input.vadGateRuntimeSnapshot.lastAnalysis
    }

    var encodedAudioPacketCount: Int? {
        input.isAudioReady ? input.encodedAudioPacketCount : nil
    }

    var flowSteps: [PipelineStep] {
        [sessionStep, inputStreamStep, vadStep, mixerBusStep, codecStep, rtcStep]
    }

    var sessionStep: PipelineStep {
        if input.audioErrorMessage != nil {
            return PipelineStep(
                id: "session",
                package: "SessionManager",
                title: "Session",
                detail: "Error",
                icon: "waveform.badge.exclamationmark",
                state: .blocked,
                accessibilityIdentifier: "pipeline-session-step"
            )
        }
        if input.audioSessionSnapshot.isActive {
            return PipelineStep(
                id: "session",
                package: "SessionManager",
                title: "Session",
                detail: input.audioSessionProfile.label,
                icon: "waveform",
                state: .passing,
                accessibilityIdentifier: "pipeline-session-step"
            )
        }
        if input.lastAudioSessionConfigurationReport != nil {
            return PipelineStep(
                id: "session",
                package: "SessionManager",
                title: "Session",
                detail: "Configured",
                icon: "waveform",
                state: .waiting,
                accessibilityIdentifier: "pipeline-session-step"
            )
        }
        return PipelineStep(
            id: "session",
            package: "SessionManager",
            title: "Session",
            detail: "Not available",
            icon: "waveform",
            state: .idle,
            accessibilityIdentifier: "pipeline-session-step"
        )
    }

    var inputStreamStep: PipelineStep {
        if input.isMuted {
            return PipelineStep(
                id: "input",
                package: "SessionManager",
                title: "Input",
                detail: inputStreamDetail("Muted"),
                icon: "mic.slash.fill",
                state: .muted,
                accessibilityIdentifier: "pipeline-input-step"
            )
        }
        guard input.isAudioReady else {
            return PipelineStep(
                id: "input",
                package: "SessionManager",
                title: "Input",
                detail: "Not available",
                icon: "mic",
                state: .idle,
                accessibilityIdentifier: "pipeline-input-step"
            )
        }
        let snapshot = input.lastInputStreamOperationReport?.snapshot
            ?? input.lastVoiceProcessingOperationReport?.snapshot
        let isRunning = snapshot?.isRunning ?? input.isMicrophoneCaptureRunning
        return PipelineStep(
            id: "input",
            package: "SessionManager",
            title: "Input",
            detail: inputStreamDetail(isRunning ? "Run" : "Starting"),
            icon: isRunning ? "mic.fill" : "mic",
            state: isRunning ? .passing : .waiting,
            accessibilityIdentifier: "pipeline-input-step"
        )
    }

    var vadStep: PipelineStep {
        let analysis = voiceActivityAnalysis
        let state: PipelineStepState
        if !input.isAudioReady || input.isMuted {
            state = .idle
        } else {
            state = analysis?.state == .speech ? .passing : .waiting
        }
        let value = analysis?.state.rawValue.capitalized ?? "Not measured"
        return PipelineStep(
            id: "vad", package: "VADGate", title: "VAD", detail: "\(value) / \(input.vadSensitivity.label)",
            icon: "waveform", state: state, accessibilityIdentifier: "pipeline-vad-step"
        )
    }

    var mixerBusStep: PipelineStep {
        guard input.isAudioReady else {
            return PipelineStep(
                id: "mixer",
                package: "AudioMixer",
                title: "TX Bus",
                detail: "Not available",
                icon: "slider.horizontal.3",
                state: .idle,
                accessibilityIdentifier: "pipeline-mixer-step"
            )
        }
        let bus = input.mixerBusSnapshot(id: "tx-bus")
        let waitingOnEffect = effectChainState == .waiting
        var detail = bus.map { "\($0.sourceCount) in / \($0.effectCount) FX" } ?? "Snapshot waiting"
        if waitingOnEffect {
            detail = effectChainPipelineDetail
        } else if let isolation = input.transmitEffectChainSnapshot.stages.first(
            where: { $0.id == "sound-isolation" }
        ) {
            detail += " · \(isolation.name) \(isolation.state.rawValue)"
        }
        return PipelineStep(
            id: "mixer",
            package: "AudioMixer",
            title: "TX Bus",
            detail: detail,
            icon: "slider.horizontal.3",
            state: bus != nil && !waitingOnEffect ? .passing : .waiting,
            accessibilityIdentifier: "pipeline-mixer-step"
        )
    }

    var mixerEffectChainStep: PipelineStep {
        guard input.isAudioReady else {
            return PipelineStep(
                id: "effect-chain",
                package: "AudioMixer",
                title: "FX Chain",
                detail: "Not available",
                icon: "wand.and.sparkles",
                state: .idle,
                accessibilityIdentifier: "pipeline-effects-step"
            )
        }
        let state = effectChainState
        return PipelineStep(
            id: "effect-chain",
            package: "AudioMixer",
            title: "FX Chain",
            detail: effectChainPipelineDetail,
            icon: "wand.and.sparkles",
            state: state,
            accessibilityIdentifier: "pipeline-effects-step"
        )
    }

    var codecStep: PipelineStep {
        guard input.isAudioReady else {
            return PipelineStep(
                id: "codec",
                package: "Codec",
                title: "Codec",
                detail: "Not available",
                icon: "cpu",
                state: .idle,
                accessibilityIdentifier: "pipeline-codec-step"
            )
        }
        let isFallback = input.preferredTransmitCodec != input.selectedTransmitCodec
        return PipelineStep(
            id: "codec",
            package: "Codec",
            title: "Codec",
            detail: isFallback ? "\(codecPipelineDetail) / Fallback" : codecPipelineDetail,
            icon: isFallback ? "cpu" : "cpu.fill",
            state: isFallback ? .waiting : codecState,
            accessibilityIdentifier: "pipeline-codec-step"
        )
    }

    var rtcStep: PipelineStep {
        if input.selectedGroupConnectionState == .localConnected
            || input.selectedGroupConnectionState == .internetConnected {
            return PipelineStep(
                id: "rtc",
                package: "RTC",
                title: "RTC",
                detail: "\(input.routeLabel) / Control Connected",
                icon: "dot.radiowaves.left.and.right",
                state: .passing,
                accessibilityIdentifier: "pipeline-rtc-step"
            )
        }
        guard input.isAudioReady else {
            return PipelineStep(
                id: "rtc",
                package: "RTC",
                title: "RTC",
                detail: "Media Idle",
                icon: "dot.radiowaves.left.and.right",
                state: .idle,
                accessibilityIdentifier: "pipeline-rtc-step"
            )
        }
        return PipelineStep(
            id: "rtc",
            package: "RTC",
            title: "RTC",
            detail: "Control Waiting",
            icon: "dot.radiowaves.left.and.right",
            state: .waiting,
            accessibilityIdentifier: "pipeline-rtc-step"
        )
    }

}

extension TransmitPipelinePresentation {
    var effectChainState: PipelineStepState {
        aggregateState(transmitEffectStages.map(\.state))
    }

    func outboundRoutes(now: TimeInterval) -> (summary: String, branches: [PipelineStep]) {
        let report = input.networkDiagnostics
        let dispatch = report?.outboundAudioDispatch
        let age = dispatch.map { max(0, now - $0.observedAt) }
        let summary = age.map { "Last audio dispatch · \(Int($0))s ago" } ?? "Last audio dispatch"
        let telemetryLifetime: TimeInterval = 15
        let reportIsFresh = report.map { now - $0.generatedAt <= telemetryLifetime } ?? false
        let branches = RouteKind.allCases.map { route in
            let isInternet = route == .webRTC
            let status: (state: PipelineStepState, label: String)
            if let dispatch, let age {
                if age > telemetryLifetime || !reportIsFresh {
                    status = (.idle, "Last dispatch is stale")
                } else if dispatch.offeredRoutes.contains(route) {
                    switch dispatch.transportAcceptance?[route] {
                    case .some(true): status = (.passing, "Accepted by transport")
                    case .some(false): status = (.waiting, "Not accepted by transport")
                    case .none: status = (.waiting, "Acceptance not measured")
                    }
                } else if isInternet && dispatch.internetCoveredByLocal {
                    status = (.idle, "Covered by Local")
                } else {
                    status = (.idle, "Not used for last packet")
                }
            } else {
                status = (.idle, "No audio dispatch observed")
            }
            let queuedBytes = reportIsFresh
                ? report?.routes.first(where: { $0.route == route })?.statistics.bufferedBytes
                : nil
            let queue = queuedBytes.map { "\($0) B" } ?? "Not measured"
            return PipelineStep(
                id: route.rawValue,
                package: "RTC",
                title: isInternet ? "Internet" : "Local",
                detail: isInternet ? "\(status.label) / Send queue: \(queue)" : status.label,
                icon: "arrow.turn.down.right",
                state: status.state,
                accessibilityIdentifier: "pipeline-rtc-route-\(route.rawValue)"
            )
        }
        return (summary, branches)
    }

    var codecState: PipelineStepState {
        input.isVoiceActive && input.encodedAudioPacketCount > 0 ? .passing : .waiting
    }

    var transmitEffectStages: [EffectChainStage] {
        input.transmitEffectChainSnapshot.stages.map(EffectChainStage.init(snapshot:))
    }

    var effectChainPipelineDetail: String {
        input.transmitEffectChainSnapshot.summary
    }

    private func inputStreamDetail(_ prefix: String) -> String {
        let snapshot = input.lastInputStreamOperationReport?.snapshot
            ?? input.lastVoiceProcessingOperationReport?.snapshot
        guard let snapshot else { return prefix }
        return "\(prefix) / \(streamFormatSummary(snapshot.actualHardwareFormat)) / F \(snapshot.processedFrameCount)"
    }

    private func streamFormatSummary(_ format: AudioFormat) -> String {
        "\(Int(format.sampleRate / 1_000))k/\(format.channelCount)ch"
    }

    var codecPipelineDetail: String {
        let requested = codecShortLabel(input.preferredTransmitCodec)
        let selected = codecShortLabel(input.selectedTransmitCodec)
        if requested == selected { return selected }
        return "\(requested) -> \(selected)"
    }

    private func codecShortLabel(_ codec: AudioCodecIdentifier) -> String {
        if codec == .pcm16 { return "PCM" }
        if codec == .mpeg4AACELD || codec == .mpeg4AACELDv2 { return "AAC" }
        if codec == .opus { return "Opus" }
        return codec.rawValue
    }

    private func aggregateState(_ states: [PipelineStepState]) -> PipelineStepState {
        if states.contains(.blocked) { return .blocked }
        if states.contains(.waiting) { return .waiting }
        if states.contains(.passing) { return .passing }
        return .idle
    }
}
