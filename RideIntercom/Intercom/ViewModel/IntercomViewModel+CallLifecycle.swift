import AVFAudio
import AudioDevice
import AudioCore
import Foundation
import Logging
import RTC
import SessionManager

extension IntercomViewModel {
    func connectLocal() {
        guard let groupID = selectedGroup?.id else { return }
        startCall(to: .group(groupID), accountAccessID: accountAccessID)
    }

    /// Internal lifecycle after the destination and account have been resolved.
    func connectSelectedGroup(usingWatch: Bool = false) {
        guard canStartCalls else {
            groupErrorMessage = groupStorageNotice ?? "Sign in with Apple to start a call."
            return
        }
        guard let selectedGroup else { return }
        let storedCredential: GroupAccessCredential?
        do { storedCredential = try credential(for: selectedGroup) }
        catch { groupErrorMessage = "Could not read the group key. Try again."; return }
        guard let credential = storedCredential else {
            groupErrorMessage = "Group key is missing. Open a valid invite or create a new group."
            return
        }
        stopContactInvitationSession()
        groupErrorMessage = nil
        connectivityNotice = nil
        internetFailureDetail = nil
        cancelAudioCheck()

        if let activeGroupID,
           activeGroupID != selectedGroup.id,
           hasAnyActiveGroupConnection {
            disconnect()
        }

        if activeGroupID != selectedGroup.id || !hasAnyActiveGroupConnection {
            let changedInputRoute = isUsingWatchAudio != usingWatch
            isUsingWatchAudio = usingWatch
            activeGroupID = selectedGroup.id
            resetConnectionRuntimeState()
            if changedInputRoute { applyEffectiveInputMute() }
            bindConnectionEvents()
            let interval = usingWatch ? watchCallDisconnectInterval : callDisconnectInterval
            callDisconnectDeadline = callAccessNow().addingTimeInterval(interval.seconds)
        }

        connectionState = routeConnectionState(isConnected: !connectedPeerIDs.isEmpty)
        markMembers(connectedPeerIDs.isEmpty ? .connecting : .connected)
        let shouldStartOrPromoteLocalConnection =
            authenticatedPeerIDs.isEmpty &&
            connectedPeerIDs.isEmpty &&
            localNetworkStatus != .connected

        // Prepare the explicitly requested call before waiting for discovery or admission.
        startAudioPipelineIfNeeded()
        if shouldStartOrPromoteLocalConnection {
            var group = selectedGroup
            group.accessSecret = credential.secret
            callSession.setAudioPolicy(currentCallAudioPolicy())
            publishRuntimePackageReports(force: true)
            callTicker.start()
            callSession.connect(group: group)
        }
        if !authenticatedPeerIDs.isEmpty {
            startActiveCallAfterAuthenticatedPeer()
        }
    }

    func startActiveCallAfterAuthenticatedPeer() {
        if enforceCallAccess { refreshCallAccess(); return }
        startAudioPipelineIfNeeded()
        refreshCallMediaAdmission()
    }

    func startAudioPipelineIfNeeded(resumingDevice: Bool = false) {
        guard callStillRequestsAudio(),
              !isUsingWatchAudio || watchAudioLink != nil,
              !isAudioPausedForDeviceChange || resumingDevice,
              !isAudioReady, audioStartTask == nil else { return }

        cancelAudioCheck()
        bindAudioEvents()
        guard configureAudioSession() else {
            if resumingDevice { reportAudioDeviceRestartFailure() }
            return
        }
        // Failed preparation releases audio. A stopped call that was resuming keeps a reason and the retry action.
        let abandonStart = { [weak self] (reason: String?) in
            guard let self else { return }
            self.stopAudioPipeline()
            if resumingDevice { self.reportAudioDeviceRestartFailure(reason: reason) }
            else if let reason { self.audioErrorMessage = reason }
        }
        let generation = audioGeneration, connection = connectionGeneration
        audioStartTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.audioGeneration == generation,
                  self.connectionGeneration == connection else { return }
            let authorized = self.isUsingWatchAudio ? true : await self.requestMicrophoneAccess()
            // Permission may complete after end, sign-out, or a different call.
            // Register activation only while this same call still requests it.
            guard !Task.isCancelled, self.audioGeneration == generation,
                  self.connectionGeneration == connection, self.callStillRequestsAudio() else { return }
            guard authorized else {
                abandonStart(Self.microphoneAccessRequiredMessage)
                return
            }
            let activation = self.audioSessionManager.requestActive(true)
            let report = await activation.value
            guard !Task.isCancelled, self.audioGeneration == generation,
                  self.connectionGeneration == connection else { return }
            self.audioStartTask = nil
            // The explicit call may have ended while the session activated.
            guard self.callStillRequestsAudio() else {
                self.stopAudioPipeline()
                return
            }
            guard report.result != .ignored(.superseded) else { return }
            guard self.applyAudioSessionActivationReport(report) else { abandonStart(nil); return }
            guard self.rebuildAudioPipeline(startsOutputClock: false),
                  self.applyCurrentVoiceProcessingConfiguration(), self.startInputCapture(),
                  self.startPreparedAudioOutput(configuration: .intercomCall) else { abandonStart(nil); return }
            self.inputFrameDelivery?.activate()
            self.callTicker.start()
            self.isAudioReady = true
            self.refreshCallMediaAdmission()
            self.watchAudioLink?.setSendingAllowed(self.isUsingWatchAudio)
            if resumingDevice {
                self.isAudioPausedForDeviceChange = false
                self.audioRouteNotice = nil
            }
            self.connectionState = self.routeConnectionState(isConnected: !self.connectedPeerIDs.isEmpty)
            self.markConnectedMembers(peerIDs: self.connectedPeerIDs)
            self.callSession.setAudioPolicy(self.currentCallAudioPolicy())
            self.refreshOtherAudioDuckingState()
            self.publishRuntimePackageReports(force: true)
            self.audioErrorMessage = nil
            AppLoggers.audio.info("audio.media.started", metadata: .event("audio.media.started", [
                "route": "\(self.routeLabel)", "codec": "\(self.selectedTransmitCodec.rawValue)"
            ]))
            self.refreshCallAccess()
            self.recordEstablishedCall()
        }
    }

    /// A call says the same two things on any route; only the word names the route in use.
    func routeConnectionState(isConnected: Bool) -> CallConnectionState {
        if isInternetOnlyCall { return isConnected ? .internetConnected : .internetConnecting }
        return isConnected ? .localConnected : .localConnecting
    }

    /// Native audio belongs to the explicit call, including waiting and recoverable loss.
    /// Peer authentication and commercial access independently gate network media.
    private func callStillRequestsAudio() -> Bool {
        !disconnectIfTimerExpired(now: callAccessNow().timeIntervalSince1970)
            && callDisconnectDeadline != nil && canStartCalls
    }

    func refreshCallMediaAdmission() {
        let admitted = isAudioReady && callDisconnectDeadline != nil && canStartCalls
            && canPrepareCallMedia && !authenticatedPeerIDs.isEmpty
        // Close the pipeline before revoking media, and open it only after transport admission.
        if !admitted { audioPipeline.setInputMuted(true) }
        if admitted != isCallMediaStarted {
            isCallMediaStarted = admitted
            if admitted { callSession.startMedia() }
            else { callSession.stopMedia() }
        }
        audioPipeline.setInputMuted(effectiveInputMuted || !admitted)
    }

    func stopAudioPipeline() {
        audioGeneration = UUID()
        audioStartTask?.cancel()
        audioStartTask = nil
        inputFrameDelivery?.finish()
        inputFrameDelivery = nil
        clearLocalInputObservation()
        watchAudioLink?.setSendingAllowed(false)
        let wasAudioReady = isAudioReady
        setOtherAudioDuckingActive(false)
        isCallMediaStarted = false
        audioPipeline.setInputMuted(true)
        callSession.stopMedia()
        audioPipeline.stop()
        lastPlaybackScheduledAt = nil
        lastReceivedAudioAt = nil
        _ = audioInputCapture.stop()
        _ = audioOutputRenderer.stop()
        if callDisconnectDeadline == nil && (!enforceCallAccess || activeGroupID == nil) { callTicker.stop() }
        audioSessionManager.requestActive(false)
        isAudioReady = false
        #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS)
        BackgroundCallValidationObservation.observe(self)
        #endif
        publishRuntimePackageReports(force: true)
        if wasAudioReady {
            AppLoggers.audio.info(
                "audio.media.stopped",
                metadata: .event("audio.media.stopped", [
                    "route": "\(routeLabel)"
                ])
            )
        }
    }

    /// Uses the existing call ticker; reconnection and microphone changes never extend this deadline.
    @discardableResult
    func disconnectIfTimerExpired(now: TimeInterval) -> Bool {
        guard let deadline = callDisconnectDeadline, now >= deadline.timeIntervalSince1970 else { return false }
        disconnect()
        groupErrorMessage = "The call ended because its automatic disconnection timer expired."
        return true
    }

    func disconnect() {
        stopContactInvitationSession()
        stopWatchAudioLink()
        callDisconnectDeadline = nil
        callTicker.stop()
        // The access state ends before media stops, so the last report to peers carries no access.
        callAccessState = CallAccessState()
        lastCallAccessSaveAttempt = nil
        let disconnectingGroupID = activeGroupID
        connectionGeneration = UUID()
        callSession.onEvent = nil
        cancelAudioCheck()
        stopAudioPipeline()
        let wasUsingWatchAudio = isUsingWatchAudio
        isUsingWatchAudio = false
        audioInputCapture = nativeAudioInputCapture
        audioOutputRenderer = nativeAudioOutputRenderer
        if wasUsingWatchAudio { applyEffectiveInputMute() }
        callSession.disconnect()
        availableCallRoutes = []
        connectivityNotice = nil
        internetFailureDetail = nil
        audioRouteNotice = nil
        isAudioPausedForDeviceChange = false
        resetConnectionRuntimeState()
        activeGroupID = disconnectingGroupID
        markMembers(.offline)
        activeGroupID = nil
        audioPipeline.applyVADSensitivity(vadSensitivity)
        networkDiagnostics = nil
        lastRouteMetrics = nil
        publishRuntimePackageReports(force: true)
    }

    func bindConnectionEvents() {
        connectionGeneration = UUID()
        let generation = connectionGeneration
        callSession.processReceivedAudio = { [pipeline = audioPipeline] received in
            do {
                let frame = try pipeline.processReceivedAudioPacket(received)
                return .processed(level: (try? AudioSignalMeter.measure(frame).rms) ?? 0)
            } catch {
                return .failure(error)
            }
        }
        callSession.onEvent = { [weak self] event in
            guard let self, self.connectionGeneration == generation else { return }
            self.handleTransportEvent(event)
        }
    }

    func bindAudioEvents(finiteRecordingDuration: TimeInterval? = nil) {
        audioGeneration = UUID()
        let generation = audioGeneration
        inputFrameDelivery?.finish()
        let delivery = AudioFrameDelivery(initiallyActive: false, coalescesObservations: finiteRecordingDuration == nil,
                                          finiteRecordingDuration: finiteRecordingDuration) { [weak self] frame in
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
        if let recording { audioPipeline.onTransmitPacket = { recording.receive($0) } }
        else { audioPipeline.onTransmitPacket = callSession.audioPacketSink }
        if finiteRecordingDuration == nil, pipeline.usesHardwareClock, audioOutputRenderer.rendersToHardware {
            pipeline.onOutputFrame = nil
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
        do { try audioPipeline.startPreparedOutput(); return true }
        catch { audioErrorMessage = "Audio output failed"; return false }
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
            && audioInputCapture.configuration.voiceProcessing.voiceProcessingEnabled != requested.voiceProcessingEnabled
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
        case .applied, .ignored(.unsupportedOnCurrentPlatform), .ignored(.unsupportedSelection), .ignored(.unavailableDevice):
            true
        case .ignored(.superseded), .failed(_):
            false
        }
    }
}

private extension SessionManager.AudioStreamOperationResult {
    var isContinuable: Bool {
        switch self {
        case .applied, .ignored(_):
            true
        case .failed(_):
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
