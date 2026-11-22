import AudioMixer
import Codec
import Foundation
import RTC

extension IntercomViewModel {
    var hasCurrentAccountAccess: Bool {
        !accountSession.deletion.blocksSignIn && accountUserID != nil
            && accountSession.userID == accountUserID && accountSession.accessID == accountAccessID
    }
    var canStartCalls: Bool { hasCurrentAccountAccess && !requiresAccountDataReset }

    var canControlMicrophone: Bool { !isUsingWatchAudio }
    var effectiveInputMuted: Bool { canControlMicrophone && isMuted }

    var groupErrorMessage: String? {
        get { groupCallIssue?.message }
        set { groupCallIssue = newValue.map(GroupCallIssue.notice) }
    }

    var isMicrophoneCaptureRunning: Bool {
        isAudioReady
    }

    var supportsAdvancedMixingOptions: Bool { true }
    var isOtherAudioDuckingActive: Bool { isOtherAudioDuckingActiveInternal }
    var diagnosticsInputLevel: Float {
        if audioCheckPhase == .recording {
            return audioCheckInputLevel
        }
        guard let localMember = selectedGroup?.members.first, !effectiveInputMuted else { return 0 }
        return localMember.voiceLevel
    }
    var diagnosticsInputPeakLevel: Float {
        if audioCheckPhase == .recording {
            return audioCheckInputPeakLevel
        }
        guard let localMember = selectedGroup?.members.first, !effectiveInputMuted else { return 0 }
        return localMember.voicePeakLevel
    }
    var diagnosticsOutputLevel: Float {
        if audioCheckPhase == .playing {
            return audioCheckOutputLevel
        }
        return lastScheduledOutputRMS
    }
    var diagnosticsOutputPeakLevel: Float {
        if audioCheckPhase == .playing {
            return audioCheckOutputPeakLevel
        }
        return lastScheduledOutputPeakRMS
    }
}

extension IntercomViewModel {
    nonisolated static let defaultSoundIsolationEnabled = true
    nonisolated static let defaultReceiveSoundIsolationEnabled = false
    nonisolated static let defaultAudioSessionProfile = AudioSessionProfile.echoCancelledInput
    nonisolated static let defaultDuckOthersEnabled = true
    nonisolated static let defaultVADSensitivity = VoiceActivitySensitivity.standard
    nonisolated static let defaultTransmitCodec: AudioCodecIdentifier = .mpeg4AACELD
    nonisolated static let defaultRTCAudioFormatPreset: RTCAudioFormatPreset = .mono48k
    nonisolated static let defaultAACELDv2BitRate = 48_000
    nonisolated static let defaultOpusBitRate = Codec.OpusOptions().bitRate
    nonisolated static let supportedRTCTransportRoutes = AppRTCTransportRoutePolicy.supportedRoutes
    nonisolated static let defaultEnabledRTCTransportRoutes: Set<RTC.RouteKind> = supportedRTCTransportRoutes
    nonisolated static let defaultOverallOutputVolume: Float = 1
    nonisolated static let defaultRemoteOutputVolume: Float = 1
    nonisolated static let otherAudioDuckingHoldDuration: TimeInterval = 1.0
    nonisolated static let runtimePackageReportPublishInterval: TimeInterval = 0.5
}
