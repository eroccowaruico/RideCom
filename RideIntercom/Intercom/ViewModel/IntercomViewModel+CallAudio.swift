import AVFAudio
import AudioCore
import Foundation
import Logging
import SessionManager

extension IntercomViewModel {
    func bindAudioEvents(finiteRecordingDuration: TimeInterval? = nil) {
        audioGeneration = UUID()
        let generation = audioGeneration
        inputFrameDelivery?.finish()
        let delivery = AudioFrameDelivery(
            initiallyActive: false, coalescesObservations: finiteRecordingDuration == nil,
            finiteRecordingDuration: finiteRecordingDuration
        ) { [weak self] frame in
            guard let self, self.audioGeneration == generation else { return }
            self.handleMicrophoneFrame(frame)
        }
        inputFrameDelivery = delivery
        let pipeline = audioPipeline
        let recording = audioCheckRecording
        pipeline.setInputMuted(effectiveInputMuted || (recording == nil && !isCallMediaStarted))
        audioInputCapture.setRuntimeEventHandler { [weak self] event in
            if case .inputFrame(let frame) = event {
                guard delivery.isActive else { return }
                guard let accepted = recording == nil ? frame : recording?.acceptInput(frame) else { return }
                pipeline.processMicrophoneFrame(accepted, shouldProcess: { delivery.isActive })
                delivery.yield(accepted)
                return
            }
            DispatchQueue.main.async {
                guard let self, self.audioGeneration == generation else { return }
                self.handleAudioStreamRuntimeEvent(event)
            }
        }
        if let recording {
            audioPipeline.onTransmitPacket = { recording.receive($0) }
        } else {
            audioPipeline.onTransmitPacket = callSession.audioPacketSink
        }
        bindCallAudioOutput(generation: generation, finiteRecordingDuration: finiteRecordingDuration)
    }

    private func bindCallAudioOutput(generation: UUID, finiteRecordingDuration: TimeInterval?) {
        if finiteRecordingDuration == nil, audioPipeline.usesHardwareClock, audioOutputRenderer.rendersToHardware {
            audioPipeline.onOutputFrame = nil
            return
        }
        audioPipeline.onOutputFrame = { [weak self] frame in
            guard let self, self.audioGeneration == generation else { return }
            if self.audioCheckPhase == .playing {
                #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS) && targetEnvironment(simulator)
                if self.audioPipeline.rendersToHardware { self.audioCheckObservation?.appendOutput(frame) }
                #endif
                if !self.audioPipeline.rendersToHardware {
                    self.lastOutputStreamOperationReport = self.audioOutputRenderer.schedule(frame)
                }
                return
            }
            guard self.isAudioReady, !self.audioPipeline.rendersToHardware else { return }
            self.scheduleOutputFrame(frame: frame, receivedAt: Date().timeIntervalSince1970)
            #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS)
            BackgroundCallValidationObservation.observe(self, output: true)
            #endif
        }
    }

    func applyAudioSessionActivationReport(_ report: AudioSessionOperationReport) -> Bool {
        guard report.result != .ignored(.superseded) else { return false }
        lastAudioSessionActivationReport = report
        guard report.result.isContinuable else {
            reportAudioSessionFailure("Audio session activation failed", operation: "setActive")
            return false
        }
        return true
    }

    func configureAudioSession() -> Bool {
        do {
            let report = try audioSessionManager.configure(makeAudioSessionConfiguration())
            lastAudioSessionConfigurationReport = report
            if let snapshot = report.snapshot {
                applyAudioSessionSnapshot(snapshot)
            }
            guard report.operations.allSatisfy(\.result.isContinuable) else {
                reportAudioSessionFailure("Audio session configuration failed", operation: "configure")
                return false
            }
            publishRuntimePackageReports(force: true)
            return true
        } catch {
            reportAudioSessionFailure("Audio session configuration failed", operation: "configure", error: error)
            return false
        }
    }

    private func reportAudioSessionFailure(_ message: String, operation: String, error: (any Error)? = nil) {
        audioErrorMessage = message
        publishRuntimePackageReports(force: true)
        var values: Logger.Metadata = ["operation": "\(operation)", "isRecoverable": "true"]
        if let error { values["errorType"] = "\(type(of: error))" }
        AppLoggers.audio.error("audio.session.failed", metadata: .event("audio.session.failed", values))
    }

    func makeAudioSessionConfiguration() -> SessionManager.AudioSessionConfiguration {
        .intercom(
            profile: audioSessionProfile,
            prefersSpeakerOutput: selectedOutputPort == .speaker,
            preferredInput: selectedInputPort.sessionManagerInputSelection,
            preferredOutput: selectedOutputPort.sessionManagerOutputSelection
        )
    }

    func startInputCapture() -> Bool {
        let report = audioInputCapture.start()
        lastInputStreamOperationReport = report
        guard report.result.isContinuable else {
            audioErrorMessage = "Microphone capture failed"
            return false
        }
        return true
    }

    func startPreparedAudioOutput(configuration: SessionManager.AudioOutputStreamConfiguration? = nil) -> Bool {
        guard startOutputRenderer(configuration: configuration) else { return false }
        do { try audioPipeline.startPreparedOutput(); return true } catch {
            audioErrorMessage = "Audio output failed"; return false
        }
    }

    func startOutputRenderer(configuration: SessionManager.AudioOutputStreamConfiguration? = nil) -> Bool {
        let report = audioOutputRenderer.start(configuration: configuration ?? .intercom)
        lastOutputStreamOperationReport = report
        guard report.result.isContinuable else {
            audioErrorMessage = "Audio output failed"
            return false
        }
        return true
    }

    func currentVoiceProcessingConfiguration() -> SessionManager.AudioInputVoiceProcessingConfiguration {
        SessionManager.AudioInputVoiceProcessingConfiguration(
            soundIsolationEnabled: false,
            // Keep the I/O mode fixed while the ducking feature is enabled.
            // Incoming speech changes the ducking level, not RemoteIO/VoiceIO.
            // A local recording checks the transmitted effects, not other apps'
            // volume. Avoid switching its prepared graph to VoiceProcessingIO.
            otherAudioDuckingEnabled: isDuckOthersEnabled && !audioCheckOwnsAudioPipeline,
            duckingLevel: isOtherAudioDuckingActiveInternal ? .medium : .minimum,
            // Finite checks keep the capture clock while the transmitter owns mute.
            inputMuted: !audioCheckOwnsAudioPipeline && effectiveInputMuted
        )
    }

    @discardableResult
    func applyCurrentVoiceProcessingConfiguration() -> Bool {
        // Watch owns input hardware. Do not open the iPhone input node for
        // ducking or mute changes while its microphone is not the source.
        if isUsingWatchAudio { return true }
        let requested = currentVoiceProcessingConfiguration()
        let changesClock = isAudioReady
            && audioInputCapture.configuration.voiceProcessing.voiceProcessingEnabled
                != requested.voiceProcessingEnabled
        let update = { self.audioInputCapture.updateVoiceProcessing(requested) }
        let report = changesClock ? audioPipeline.reconfigureInput(update) : update()
        lastVoiceProcessingOperationReport = report
        if case .ignored(let reason) = report.result {
            AppLoggers.audio.debug(
                "audio.input.voice_processing_ignored",
                metadata: .event("audio.input.voice_processing_ignored", [
                    "reason": "\(reason)"
                ])
            )
        }
        guard report.result.isContinuable else {
            audioErrorMessage = "Audio input processing update failed"
            AppLoggers.audio.warning(
                "audio.input.voice_processing_failed",
                metadata: .event("audio.input.voice_processing_failed", [
                    "errorType": "\(report.result)",
                    "isRecoverable": "true"
                ])
            )
            return false
        }
        return true
    }
}

private extension SessionManager.AudioSessionOperationResult {
    var isContinuable: Bool {
        switch self {
        case .applied, .ignored(.unsupportedOnCurrentPlatform), .ignored(.unsupportedSelection),
            .ignored(.unavailableDevice):
            true
        case .ignored(.superseded), .failed:
            false
        }
    }
}

private extension SessionManager.AudioStreamOperationResult {
    var isContinuable: Bool {
        switch self {
        case .applied, .ignored:
            true
        case .failed:
            false
        }
    }
}

/// Media can start with a denied microphone and send silence, so the denial is logged at media start.
enum MicrophonePermissionLog {
    static func denied(_ permission: AVAudioApplication.recordPermission) -> Logger.Metadata? {
        guard permission == .denied else { return nil }
        return .event("app.permission.microphone.denied", ["permission": "denied"])
    }
}
