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
    func connectSelectedGroup(source: CallStartSource = .thisDevice) {
        guard canStartCalls else {
            groupErrorMessage = groupStorageNotice ?? "Sign in with Apple to start a call."
            return
        }
        guard let selectedGroup else { return }
        let storedCredential: GroupAccessCredential?
        do { storedCredential = try credential(for: selectedGroup) } catch {
            groupErrorMessage = "Could not read the group key. Try again."; return
        }
        guard let credential = storedCredential else {
            groupErrorMessage = "Group key is missing. Open a valid invite or create a new group."
            return
        }
        if !enabledRTCTransportRoutes.contains(.multipeer), let internetSetupNotice = internetCallSetupNotice {
            groupErrorMessage = internetSetupNotice
            return
        }
        resumeOrdinaryGroupReply(for: selectedGroup)
        if let invitation = contactInvitationSession {
            if invitation.canContinueDuringCall { invitation.stopCallRoute() } else { stopContactInvitationSession() }
        }
        groupErrorMessage = nil
        internetTransportFailure = nil
        cancelAudioCheck()

        switchActiveCallIfNeeded(to: selectedGroup.id, source: source)

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

    private func switchActiveCallIfNeeded(to groupID: UUID, source: CallStartSource) {
        if let activeGroupID,
           activeGroupID != groupID,
           hasAnyActiveGroupConnection {
            disconnect()
        }

        if activeGroupID != groupID || !hasAnyActiveGroupConnection {
            let usesWatchAudio = source == .watchAudio
            let changedInputRoute = isUsingWatchAudio != usesWatchAudio
            isUsingWatchAudio = usesWatchAudio
            activeGroupID = groupID
            resetConnectionRuntimeState()
            if changedInputRoute { applyEffectiveInputMute() }
            bindConnectionEvents()
            let interval = source == .thisDevice ? callDisconnectInterval : watchCallDisconnectInterval
            callDisconnectDeadline = callAccessNow().addingTimeInterval(interval.seconds)
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
                self.abandonAudioStart(resumingDevice: resumingDevice, reason: Self.microphoneAccessRequiredMessage)
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
            guard self.prepareCallAudio(report) else {
                self.abandonAudioStart(resumingDevice: resumingDevice)
                return
            }
            self.finishCallAudioStart(resumingDevice: resumingDevice)
        }
    }

    private func prepareCallAudio(_ report: AudioSessionOperationReport) -> Bool {
        applyAudioSessionActivationReport(report)
            && rebuildAudioPipeline(startsOutputClock: false)
            && applyCurrentVoiceProcessingConfiguration()
            && startInputCapture()
            && startPreparedAudioOutput(configuration: .intercomCall)
    }

    // Failed preparation releases audio. A stopped call that was resuming keeps a reason and the retry action.
    private func abandonAudioStart(resumingDevice: Bool, reason: String? = nil) {
        stopAudioPipeline()
        if resumingDevice {
            reportAudioDeviceRestartFailure(reason: reason)
        } else if let reason {
            audioErrorMessage = reason
        }
    }

    private func finishCallAudioStart(resumingDevice: Bool) {
        inputFrameDelivery?.activate()
        callTicker.start()
        isAudioReady = true
        refreshCallMediaAdmission()
        watchAudioLink?.setSendingAllowed(isUsingWatchAudio)
        if resumingDevice {
            isAudioPausedForDeviceChange = false
            audioRouteNotice = nil
        }
        connectionState = routeConnectionState(isConnected: !connectedPeerIDs.isEmpty)
        markConnectedMembers(peerIDs: connectedPeerIDs)
        callSession.setAudioPolicy(currentCallAudioPolicy())
        refreshOtherAudioDuckingState()
        publishRuntimePackageReports(force: true)
        audioErrorMessage = nil
        AppLoggers.audio.info("audio.media.started", metadata: .event("audio.media.started", [
            "route": "\(routeLabel)", "codec": "\(selectedTransmitCodec.rawValue)"
        ]))
        refreshCallAccess()
        recordEstablishedCall()
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
        guard admitted else {
            if isCallMediaStarted {
                stopCallMedia()
            } else {
                audioPipeline.setInputMuted(true)
            }
            return
        }
        if !isCallMediaStarted {
            audioPipeline.prepareReceivePeers(authenticatedPeerIDs)
            isCallMediaStarted = true
            callSession.startMedia()
        }
        audioPipeline.setInputMuted(effectiveInputMuted)
    }

    private func stopCallMedia() {
        audioPipeline.setInputMuted(true)
        isCallMediaStarted = false
        callSession.stopMedia()
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
        stopCallMedia()
        audioPipeline.stop()
        audioPipeline.onTransmitPacket = nil
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
        callMicrophonePermissionRequest?.task.cancel()
        callMicrophonePermissionRequest = nil
        if contactInvitationSession?.canContinueDuringCall == false { stopContactInvitationSession() }
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
        internetTransportFailure = nil
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
}
