import AVFoundation
import AudioCore
import Codec
import CryptoKit
import Foundation
import Logging
import OSLog
import RTC
import SessionManager
import VADGate

extension IntercomViewModel {
    var audioSessionModeProfile: AudioSessionProfile {
        audioSessionProfile.settingsModeProfile
    }

    var isSpeakerOutputEnabled: Bool {
        audioSessionProfile.defaultToSpeaker || selectedOutputPort == .speaker
    }

    var isSessionEchoCancellationEnabled: Bool {
        if let resolvedValue = lastAudioSessionConfigurationReport?.resolvedConfiguration.prefersEchoCancelledInput {
            return resolvedValue
        }
        guard audioSessionModeProfile == .standard else { return false }
        return audioSessionProfile.prefersEchoCancelledInput
    }

    var canToggleSessionEchoCancellation: Bool {
        audioSessionModeProfile == .standard && !isSpeakerOutputEnabled
    }

    func setAudioSessionProfile(_ profile: AudioSessionProfile) {
        applyAudioSessionSettings(
            event: "settings.audio_session.changed",
            metadata: ["profile": "\(profile.rawValue)"]
        ) {
            audioSessionProfile = profile
        }
    }

    func setAudioSessionModeProfile(_ profile: AudioSessionProfile) {
        applyAudioSessionSettings(event: "settings.audio_session.changed", metadata: [
            "profile": "\(audioSessionProfile.rawValue)", "speaker": "\(isSpeakerOutputEnabled)"]) {
            let keepsEchoCancellation = audioSessionProfile.prefersEchoCancelledInput
            let keepsSpeakerOutput = isSpeakerOutputEnabled
            switch profile.settingsModeProfile {
            case .standard:
                audioSessionProfile = keepsEchoCancellation ? .echoCancelledInput : .standard
            case .voiceChat:
                audioSessionProfile = .voiceChat
            case .speakerDefault, .echoCancelledInput:
                audioSessionProfile = .standard
            }
            if keepsSpeakerOutput { selectedOutputPort = .speaker }
        }
    }

    func setSpeakerOutputEnabled(_ enabled: Bool) {
        applyAudioSessionSettings(event: "settings.audio_speaker.changed", metadata: [
            "enabled": "\(enabled)", "profile": "\(audioSessionProfile.rawValue)"]) {
            if audioSessionProfile == .speakerDefault { audioSessionProfile = .standard }
            selectedOutputPort = enabled ? .speaker : .systemDefault
        }
    }

    func setSessionEchoCancellationEnabled(_ enabled: Bool) {
        guard canToggleSessionEchoCancellation else { return }
        applyAudioSessionSettings(event: "settings.echo_cancellation.changed", metadata: [
            "enabled": "\(isSessionEchoCancellationEnabled)", "speaker": "\(isSpeakerOutputEnabled)"]) {
            audioSessionProfile = enabled ? .echoCancelledInput : .standard
        }
    }

    func setInputPort(_ port: AudioPortInfo) {
        applyAudioSessionSettings(event: "settings.audio_device.changed", metadata: [
            "direction": "input", "selection": "\(port.id)"]) {
            selectedInputPort = port
        }
    }

    func setOutputPort(_ port: AudioPortInfo) {
        applyAudioSessionSettings(event: "settings.audio_device.changed", metadata: [
            "direction": "output", "selection": "\(port.id)"]) {
            selectedOutputPort = port
        }
    }

    /// Profile, speaker, echo cancellation and device selection differ only in the wish they
    /// change. Each one is saved, configured on the session and logged the same way, and running
    /// media restarts only when the selected device actually changed. The metadata is read after
    /// the session resolved the wish, so the log carries what was applied.
    private func applyAudioSessionSettings(event: String, metadata: @autoclosure () -> Logging.Logger.Metadata,
                                           _ change: () -> Void) {
        let previousPorts = [selectedInputPort, selectedOutputPort]
        change()
        saveAppSettings()
        guard configureAudioSession() else { return }
        audioErrorMessage = nil
        if [selectedInputPort, selectedOutputPort] != previousPorts { refreshAudioDevicesIfNeeded() }
        logSettingChange(event, metadata())
    }

    private func logSettingChange(_ event: String, _ values: Logging.Logger.Metadata) {
        AppLoggers.settings.info("\(event)", metadata: .event(event, values))
    }

    func toggleMute() {
        setCallMuted(!isMuted, for: currentCallReference)
    }

    func applyLocalMute(_ muted: Bool) {
        guard canControlMicrophone, isMuted != muted else { return }
        isMuted = muted
        applyEffectiveInputMute()
    }

    func applyEffectiveInputMute() {
        let muted = effectiveInputMuted
        audioPipeline.setInputMuted(muted || (!audioCheckOwnsAudioPipeline && !isCallMediaStarted))
        applyCurrentVoiceProcessingConfiguration()
        callSession.setLocalMute(muted)

        withLocalMember { member in
            member.isMuted = muted
            if muted { member.silence() }
        }
        if muted {
            localVoicePeakWindow = VoicePeakWindow()
        }
        broadcastControl(.peerMuteState(isMuted: muted))
        broadcastMetadataKeepalive()
        publishRuntimePackageReports(force: true)
    }

    func setPreferredTransmitCodec(_ codec: AudioCodecIdentifier) {
        guard preferredTransmitCodec != codec else { return }
        preferredTransmitCodec = codec
        applyEncodingSettings(event: "settings.codec.changed", metadata: ["codec": "\(codec.rawValue)"],
            announcesCodec: true)
    }

    var availableAACBitRates: [Int] {
        AppAudioCodecBridge.availableAACBitRates(format: rtcAudioFormatPreset.audioFormat)
    }

    func setAACELDv2BitRate(_ bitRate: Int) {
        let normalized = AppAudioCodecBridge.normalizedAACBitRate(bitRate, format: rtcAudioFormatPreset.audioFormat)
        guard aacELDv2BitRate != normalized else { return }
        aacELDv2BitRate = normalized
        applyEncodingSettings(event: "settings.codec.bitrate_changed", metadata: [
            "codec": "\(AudioCodecIdentifier.mpeg4AACELD.rawValue)", "bitRate": "\(normalized)"])
    }

    var availableOpusBitRates: [Int] {
        AppAudioCodecBridge.availableOpusBitRates(format: rtcAudioFormatPreset.audioFormat)
    }

    func setOpusBitRate(_ bitRate: Int) {
        let normalized = AppAudioCodecBridge.normalizedOpusBitRate(bitRate, format: rtcAudioFormatPreset.audioFormat)
        guard opusBitRate != normalized else { return }
        opusBitRate = normalized
        applyEncodingSettings(event: "settings.codec.bitrate_changed", metadata: [
            "codec": "\(AudioCodecIdentifier.opus.rawValue)", "bitRate": "\(normalized)"])
    }

    func setRTCAudioFormatPreset(_ preset: RTCAudioFormatPreset) {
        guard rtcAudioFormatPreset != preset else { return }
        rtcAudioFormatPreset = preset
        aacELDv2BitRate = AppAudioCodecBridge.normalizedAACBitRate(aacELDv2BitRate, format: preset.audioFormat)
        opusBitRate = AppAudioCodecBridge.normalizedOpusBitRate(opusBitRate, format: preset.audioFormat)
        applyEncodingSettings(event: "settings.rtc_audio_format.changed", metadata: [
            "preset": "\(preset.rawValue)", "sampleRate": "\(Int(preset.audioFormat.sampleRate))"])
    }

    /// UI differences end at normalization. Every encoding setting uses the same
    /// complete snapshot, DSP transition and RTC policy publication, in that order.
    private func applyEncodingSettings(event: String, metadata: Logging.Logger.Metadata, announcesCodec: Bool = false) {
        refreshPackageRuntimeSnapshots()
        updateAudioPipelineCodecSettings()
        setLocalActiveCodec(selectedTransmitCodec)
        saveAppSettings()
        var values = metadata
        if announcesCodec { values["selectedCodec"] = "\(selectedTransmitCodec.rawValue)" }
        logSettingChange(event, values)
        if announcesCodec {
            logCodecFallbackIfNeeded()
            broadcastMetadataKeepalive()
        }
        publishRuntimePackageReports(force: true)
    }

    nonisolated static func normalizedRTCTransportRoutes(_ routes: Set<RTC.RouteKind>) -> Set<RTC.RouteKind> {
        let normalizedRoutes = routes.intersection(supportedRTCTransportRoutes)
        return normalizedRoutes.isEmpty ? defaultEnabledRTCTransportRoutes : normalizedRoutes
    }

    func isRTCTransportRouteEnabled(_ route: RTC.RouteKind) -> Bool {
        enabledRTCTransportRoutes.contains(route)
    }

    func canToggleRTCTransportRoute(_ route: RTC.RouteKind) -> Bool {
        guard Self.supportedRTCTransportRoutes.contains(route) else { return false }
        return enabledRTCTransportRoutes.count > 1 || !enabledRTCTransportRoutes.contains(route)
    }

    func setRTCTransportRoute(_ route: RTC.RouteKind, enabled: Bool) {
        guard canToggleRTCTransportRoute(route) else { return }

        var routes = enabledRTCTransportRoutes
        if enabled {
            routes.insert(route)
        } else {
            routes.remove(route)
        }
        setRTCTransportRoutes(routes)
    }

    func setRTCTransportRoutes(_ routes: Set<RTC.RouteKind>) {
        let normalizedRoutes = Self.normalizedRTCTransportRoutes(routes)
        guard normalizedRoutes != enabledRTCTransportRoutes else { return }
        stopContactInvitationSession()
        if !normalizedRoutes.contains(.multipeer) { stopOrdinaryGroupReplyExchanges() }
        if !normalizedRoutes.contains(.webRTC) { stopInvitationInternetReply() }

        if hasAnyActiveGroupConnection {
            disconnect()
        }

        enabledRTCTransportRoutes = normalizedRoutes
        callSession.setEnabledRoutes(normalizedRoutes)
        refreshNearbyGroupDelivery()
        if groupDeliveryIsForeground { resumeSavedInvitationReplies() }
        saveAppSettings()
        logSettingChange(
            "settings.rtc_routes.changed",
            ["enabledRoutes": "\(normalizedRoutes.map(\.rawValue).sorted().joined(separator: ","))"]
        )
        publishRuntimePackageReports(force: true)
    }

    func setVADSensitivity(_ sensitivity: VoiceActivitySensitivity) {
        vadSensitivity = sensitivity
        audioPipeline.applyVADSensitivity(sensitivity)
        refreshPackageRuntimeSnapshots()
        saveAppSettings()
        logSettingChange("settings.vad.changed", ["preset": "\(sensitivity.rawValue)"])
        publishRuntimePackageReports(force: true)
    }

    func setOverallOutputVolume(_ volume: Float) {
        overallOutputVolume = min(2, max(0, volume))
        updateAudioPipelineOutputSettings()
        publishRuntimePackageReports(force: true)
    }

    func remoteOutputVolume(for peerID: String) -> Float {
        remoteOutputVolumes[peerID] ?? Self.defaultRemoteOutputVolume
    }

    func setRemoteOutputVolume(peerID: String, volume: Float) {
        let normalizedVolume = min(1, max(0, volume))
        if normalizedVolume == Self.defaultRemoteOutputVolume {
            remoteOutputVolumes.removeValue(forKey: peerID)
        } else {
            remoteOutputVolumes[peerID] = normalizedVolume
        }
        updateAudioPipelineOutputSettings()
        logSettingChange(
            "settings.remote_output_volume.changed",
            ["peerID": "\(peerID)", "volume": "\(normalizedVolume)"]
        )
        publishRuntimePackageReports(force: true)
    }

    func setSoundIsolationEnabled(_ enabled: Bool) {
        isSoundIsolationEnabled = enabled
        saveAppSettings()
        logSettingChange("settings.sound_isolation.changed", ["enabled": "\(enabled)"])
        updateAudioPipelineEffectSettings()
    }

    func isRemoteSoundIsolationEnabled(peerID: String) -> Bool {
        remoteSoundIsolationEnabled[peerID] ?? Self.defaultReceiveSoundIsolationEnabled
    }

    func setRemoteSoundIsolationEnabled(peerID: String, enabled: Bool) {
        if enabled == Self.defaultReceiveSoundIsolationEnabled {
            remoteSoundIsolationEnabled.removeValue(forKey: peerID)
        } else {
            remoteSoundIsolationEnabled[peerID] = enabled
        }
        logSettingChange("settings.remote_sound_isolation.changed", ["peerID": "\(peerID)", "enabled": "\(enabled)"])
        updateAudioPipelineEffectSettings()
    }

    func setReceiveMixSoundIsolationEnabled(_ enabled: Bool) {
        receiveMixSoundIsolationEnabled = enabled
        logSettingChange("settings.receive_master_sound_isolation.changed", ["enabled": "\(enabled)"])
        updateAudioPipelineEffectSettings()
    }

    func setDuckOthersEnabled(_ enabled: Bool) {
        isDuckOthersEnabled = enabled
        refreshOtherAudioDuckingState()
        applyCurrentVoiceProcessingConfiguration()
        publishRuntimePackageReports(force: true)
        audioErrorMessage = nil
        logSettingChange("settings.ducking.changed", ["enabled": "\(enabled)"])
    }

    func toggleOutputMute() {
        isOutputMuted.toggle()
        callSession.setOutputMute(isOutputMuted)
        updateAudioPipelineOutputSettings()
        publishRuntimePackageReports(force: true)
    }

    func setCallDisconnectInterval(_ interval: CallDisconnectInterval, usingWatch: Bool = false) {
        if usingWatch { watchCallDisconnectInterval = interval } else { callDisconnectInterval = interval }
        saveAppSettings()
    }

    func resetAllSettings() {
        applyAudioSessionSettings(event: "settings.audio_session.changed", metadata: [
            "profile": "\(Self.defaultAudioSessionProfile.rawValue)", "speaker": "\(isSpeakerOutputEnabled)"]) {
            audioSessionProfile = Self.defaultAudioSessionProfile
            selectedInputPort = .systemDefault
            selectedOutputPort = .systemDefault
        }
        setCallDisconnectInterval(.regularDefault)
        setCallDisconnectInterval(.watchDefault, usingWatch: true)
        setDuckOthersEnabled(Self.defaultDuckOthersEnabled)
        setVADSensitivity(Self.defaultVADSensitivity)
        setSoundIsolationEnabled(Self.defaultSoundIsolationEnabled)
        setPreferredTransmitCodec(Self.defaultTransmitCodec)
        setRTCAudioFormatPreset(Self.defaultRTCAudioFormatPreset)
        setAACELDv2BitRate(Self.defaultAACELDv2BitRate)
        setOpusBitRate(Self.defaultOpusBitRate)
        setRTCTransportRoutes(Self.defaultEnabledRTCTransportRoutes)
        setOverallOutputVolume(Self.defaultOverallOutputVolume)
        remoteOutputVolumes.removeAll()
        receiveMixSoundIsolationEnabled = Self.defaultReceiveSoundIsolationEnabled
        remoteSoundIsolationEnabled.removeAll()
        isOutputMuted = false
        callSession.setOutputMute(false)
        updateAudioPipelineEffectSettings()
        updateAudioPipelineOutputSettings()
        publishRuntimePackageReports(force: true)
        AppLoggers.settings.notice(
            "settings.reset",
            metadata: .event("settings.reset", ["operationID": "\(UUID().uuidString)"])
        )
    }

    func saveAppSettings() {
        guard canStartCalls else { return }
        var settings = AppSettings(
            recentCallDestination: storedRecentCallDestination,
            callDisconnectInterval: callDisconnectInterval,
            watchCallDisconnectInterval: watchCallDisconnectInterval,
            audioSessionProfile: audioSessionProfile,
            vadSensitivity: vadSensitivity,
            transmitSoundIsolationEnabled: isSoundIsolationEnabled,
            preferredTransmitCodec: preferredTransmitCodec,
            rtcAudioFormatPreset: rtcAudioFormatPreset,
            aacELDv2BitRate: aacELDv2BitRate,
            opusBitRate: opusBitRate,
            enabledRTCTransportRoutes: enabledRTCTransportRoutes
        )
        settings.menuBarEnabled = menuBarEnabled
        settings.liveActivityEnabled = liveActivityEnabled
        settings.interfaceMode = interfaceMode
        settings.showsGroupsTab = showsGroupsTab
        appSettingsStore.save(settings)
    }

    private func logCodecFallbackIfNeeded() {
        guard preferredTransmitCodec != selectedTransmitCodec else { return }
        AppLoggers.audio.notice(
            "audio.codec.fallback",
            metadata: .event("audio.codec.fallback", [
                "requestedCodec": "\(preferredTransmitCodec.rawValue)",
                "selectedCodec": "\(selectedTransmitCodec.rawValue)",
                "reason": "unavailable_or_route_unsupported"
            ])
        )
    }
}
