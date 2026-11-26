import AVFAudio
import Foundation
import Logging
import SessionManager

extension IntercomViewModel {
    static var microphoneAccessRequiredMessage: String {
        String(localized: "Microphone access is required. Allow it in Settings.")
    }

    var audioCheckInputPortName: String {
        audioCheckPhase == .recording || audioCheckPhase == .playing
            ? audioSessionSnapshot.currentInput.name : selectedInputPort.name
    }
    var audioCheckOutputPortName: String {
        audioCheckPhase == .recording || audioCheckPhase == .playing
            ? audioSessionSnapshot.currentOutput.name : selectedOutputPort.name
    }

    var availableInputPorts: [AudioPortInfo] {
        availablePorts(from: audioSessionSnapshot.availableInputs)
    }

    var availableOutputPorts: [AudioPortInfo] {
        availablePorts(from: audioSessionSnapshot.availableOutputs)
    }

    func handleAudioSessionRuntimeEvent(_ event: SessionManager.AudioSessionRuntimeEvent) {
        switch event {
        case .configuration(let report):
            lastAudioSessionConfigurationReport = report
            if let snapshot = report.snapshot, audioCheckPhase != .recording, audioCheckPhase != .playing {
                // Once recording starts, only route notifications may advance
                // its baseline; a configuration report must not hide a switch.
                let current = audioCheckPhase.isInProgress
                    ? (try? audioSessionManager.snapshot()) ?? snapshot : snapshot
                applyAudioSessionSnapshot(current)
            }
        case .snapshotChanged(let change):
            applyAudioSessionRouteChange(change)
        case .operation(let report):
            guard report.result != .ignored(.superseded) else { return }
            lastAudioSessionActivationReport = report
        }
    }

    private func applyAudioSessionRouteChange(_ change: AudioSessionSnapshotChange) {
        let previous = audioSessionSnapshot
        switch change.reason {
        case .interruptionBegan, .mediaServicesReset:
            applyAudioSessionSnapshot(change.snapshot)
            pauseAudioForSessionChange(
                callNotice: "Audio was interrupted. Your microphone and playback are paused. "
                    + "Resume audio when you are ready.",
                checkNotice: "Audio Check was interrupted. Run Audio Check again.")
            return
        case .interruptionEnded:
            applyAudioSessionSnapshot(change.snapshot)
            // OS permission to resume is not a user's request to transmit.
            return
        default: break
        }
        let snapshot = change.snapshot
        if audioCheckPhase.isInProgress, let actual = try? audioSessionManager.snapshot(),
           !actual.hasSameActiveDevices(as: snapshot) {
            // Delivery may be delayed past stop and the next check. Do not
            // apply an old route or advance the current check's baseline.
            return
        }
        applyAudioSessionSnapshot(snapshot)
        reconcileAudioDevices(after: previous, reason: change.reason)
        AppLoggers.audio.notice(
            "audio.session.route_changed",
            metadata: .event("audio.session.route_changed")
        )
    }

    func reconcileAudioDevices(after previous: AudioSessionSnapshot,
                               reason: AudioSessionSnapshotChangeReason? = nil,
                               selectionChanged: Bool = false) {
        let snapshot = audioSessionSnapshot
        let lostInput = previous.availableInputs.contains { $0.id == previous.currentInput.id }
            && !snapshot.availableInputs.contains { $0.id == previous.currentInput.id }
        let lostOutput = previous.availableOutputs.contains { $0.id == previous.currentOutput.id }
            && !snapshot.availableOutputs.contains { $0.id == previous.currentOutput.id }
        let lostDevice = reason == .routeChanged(.oldDeviceUnavailable)
            || reason == .routeChanged(.noSuitableRouteForCategory) || lostInput || lostOutput
        if lostDevice {
            pauseAudioForSessionChange(
                callNotice: "Audio device disconnected. Your microphone and playback are paused; "
                    + "the group connection and relay continue. Check your audio device, then resume.",
                checkNotice: "Audio device disconnected. Choose a device and run Audio Check again.")
        } else if selectionChanged || !previous.hasSameActiveDevices(as: snapshot) {
            let preparingOwnRoute = audioCheckPhase == .preparing
                && (reason == .routeChanged(.categoryChanged) || reason == .routeChanged(.routeConfigurationChanged))
            // Configuration/activation resolves Auto into actual ports.
            // User/default-port switches and lost-device events still stop.
            if !preparingOwnRoute { refreshAudioDevicesIfNeeded() }
        }
    }

    private func pauseAudioForSessionChange(callNotice: String, checkNotice: String) {
        if audioCheckPhase.isInProgress {
            cancelAudioCheck()
            audioCheckStatusMessage = checkNotice
        }
        // A peer authenticating later must not bypass an interruption that
        // occurred while this call was still waiting for its first rider.
        if hasAnyActiveGroupConnection || isAudioReady || audioStartTask != nil {
            stopAudioPipeline()
            isAudioPausedForDeviceChange = true
            audioRouteNotice = callNotice
        }
    }

    func applyAudioSessionSnapshot(_ snapshot: SessionManager.AudioSessionSnapshot) {
        audioSessionSnapshot = snapshot
        selectedInputPort = availableSelection(for: selectedInputPort, in: availableInputPorts)
        selectedOutputPort = availableSelection(for: selectedOutputPort, in: availableOutputPorts)
    }

    #if os(iOS)
    func recoverStoppedNativeCallAudio() {
        guard activeGroupID != nil, isAudioReady, audioCheckPhase == .idle,
              !isAudioPausedForDeviceChange, !isUsingWatchAudio,
              audioOutputRenderer === nativeAudioOutputRenderer,
              nativeAudioOutputRenderer.renderingEngine?.isRunning == false,
              let current = try? audioSessionManager.snapshot(), current.isActive,
              current.hasSameActiveDevices(as: audioSessionSnapshot) else { return }
        refreshAudioDevicesIfNeeded()
    }
    #endif

    func refreshAudioDevicesIfNeeded() {
        if audioCheckPhase.isInProgress {
            cancelAudioCheck()
            audioCheckStatusMessage = "Audio device changed. Run Audio Check again."
        }
        guard isAudioReady || audioStartTask != nil else { return }
        stopAudioPipeline()
        startAudioPipelineIfNeeded(resumingDevice: true)
    }

    var canResumeAudioOnThisDevice: Bool { !isUsingWatchAudio || watchAudioLink != nil }

    var audioPauseError: String? {
        isAudioPausedForDeviceChange && audioRouteNotice == nil ? audioErrorMessage : nil
    }

    func resumeAudioAfterDeviceChange() {
        guard canResumeAudioOnThisDevice, isAudioPausedForDeviceChange, activeGroupID != nil else { return }
        startAudioPipelineIfNeeded(resumingDevice: true)
    }

    func reportAudioDeviceRestartFailure(reason: String? = nil) {
        guard hasAnyActiveGroupConnection, callDisconnectDeadline != nil else { return }
        isAudioPausedForDeviceChange = true
        if let reason {
            audioErrorMessage = reason
            audioRouteNotice = nil
        } else {
            audioRouteNotice = "Audio could not restart on the selected device. "
                + "The group connection and relay continue. Check your device, then resume."
        }
    }

    private func availablePorts(from devices: [AudioSessionDevice]) -> [AudioPortInfo] {
        var seen: Set<AudioPortInfo> = []
        let ports = devices.map(AudioPortInfo.init(device:)).filter { seen.insert($0).inserted }
        return ports.isEmpty ? [.systemDefault] : ports
    }

    private func availableSelection(for port: AudioPortInfo, in ports: [AudioPortInfo]) -> AudioPortInfo {
        return ports.first { $0.id == port.id } ?? .systemDefault
    }
}

private extension AudioSessionSnapshot {
    func hasSameActiveDevices(as other: Self) -> Bool {
        currentInput.id == other.currentInput.id && currentOutput.id == other.currentOutput.id
    }
}
