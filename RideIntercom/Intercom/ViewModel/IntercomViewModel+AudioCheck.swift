import AudioCore
import AudioDevice
import AVFAudio
import Foundation
import SessionManager

extension IntercomViewModel {
    var canPrepareAudioCheck: Bool {
        canStartCalls && !hasAnyActiveGroupConnection && !isAudioReady && audioStartTask == nil
    }
    var canStartAudioCheck: Bool {
        canPrepareAudioCheck && !audioCheckPhase.isInProgress && !isUsingWatchAudio
            && audioInputCapture === nativeAudioInputCapture && audioOutputRenderer === nativeAudioOutputRenderer
    }

    @discardableResult
    func startAudioCheck(recordDuration: Duration = .seconds(5), playbackDuration: Duration = .seconds(5), watchSessionID: UUID? = nil) -> Bool {
        let preparedWatch = watchSessionID != nil && watchSessionID == audioCheckWatchSessionID
            && audioCheckPhase == .preparing && watchAudioLink?.sessionID == watchSessionID
        guard canPrepareAudioCheck, (watchSessionID == nil ? canStartAudioCheck : preparedWatch) else { return false }

        if !preparedWatch { cancelAudioCheck() }
        #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS) && targetEnvironment(simulator)
        if watchSessionID == nil && ProcessInfo.processInfo.environment["RIDEINTERCOM_LOCAL_TESTING"] == "1" {
            audioCheckObservation = AudioCheckValidationObservation(generation: audioCheckGeneration)
        }
        #endif
        audioCheckWatchSessionID = watchSessionID
        audioCheckRecordDuration = recordDuration
        audioCheckPlaybackDuration = playbackDuration
        audioCheckRecordedFrameCount = 0; audioCheckRecordedNonzeroSamples = 0
        audioCheckRecording = AudioCheckRecording(format: rtcAudioFormatPreset.audioFormat)
        bindAudioEvents(finiteRecordingDuration: 5)
        let generation = audioCheckGeneration, audio = audioGeneration
        resetAudioCheckMeters()
        audioCheckRecordedFrames = []
        audioCheckPhase = .preparing
        audioCheckStatusMessage = "Preparing microphone and speaker"
        audioCheckOwnsAudioPipeline = true
        guard configureAudioSession() else {
            failAudioCheck(audioErrorMessage ?? "Audio setup failed")
            return false
        }
        audioCheckTask = Task { [weak self] in
            guard let self, !Task.isCancelled, self.audioCheckGeneration == generation,
                  self.audioGeneration == audio else { return }
            let authorized = watchSessionID != nil ? true : await self.requestMicrophoneAccess()
            guard !Task.isCancelled, self.audioCheckGeneration == generation,
                  self.audioGeneration == audio else { return }
            guard authorized else {
                self.failAudioCheck(Self.microphoneAccessRequiredMessage)
                return
            }
            let activation = self.audioSessionManager.requestActive(true)
            let report = await activation.value
            guard !Task.isCancelled, self.audioCheckGeneration == generation else { return }
            guard self.audioGeneration == audio, self.canPrepareAudioCheck, self.audioCheckPhase == .preparing else {
                self.cancelAudioCheck(); return
            }
            guard report.result != .ignored(.superseded) else { self.cancelAudioCheck(); return }
            guard self.applyAudioSessionActivationReport(report), self.prepareAudioCheckPipeline(),
                  self.applyCurrentVoiceProcessingConfiguration(), self.startInputCapture(), self.startPreparedAudioOutput() else {
                self.failAudioCheck(self.audioErrorMessage ?? "Audio setup failed")
                return
            }
            // Native stream setup may resolve the selected Auto route after
            // activation. Freeze the actual route before accepting samples.
            if let actual = try? self.audioSessionManager.snapshot() { self.applyAudioSessionSnapshot(actual) }
            self.audioCheckPhase = .recording
            self.audioCheckStatusMessage = watchSessionID == nil ? "Recording microphone for 5 seconds" : "Recording Watch microphone for 5 seconds"
            self.inputFrameDelivery?.activate()
            // Count captured samples rather than completing a short recording when
            // activation or delivery takes part of the wall-clock interval.
            try? await Task.sleep(for: recordDuration + .seconds(1))
            guard !Task.isCancelled, self.audioCheckGeneration == generation else { return }
            guard self.audioCheckPhase == .recording else { return }
            self.failAudioCheck("Incomplete microphone recording")
        }
        return true
    }

    func processAudioCheckInput(level: Float, frame: PCMFrame) {
        guard audioCheckPhase == .recording, frame.frameCount > 0,
              (try? frame.validated()) != nil else { return }

        if audioCheckRecordedFrameCount == 0 {
            audioCheckTask?.cancel()
            let generation = audioCheckGeneration
            let timeout = audioCheckRecordDuration + .seconds(1)
            audioCheckTask = Task { [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                guard let self, !Task.isCancelled, self.audioCheckGeneration == generation,
                      self.audioCheckPhase == .recording else { return }
                self.failAudioCheck("Incomplete microphone recording")
            }
        }
        let clampedLevel = min(1, max(0, level))
        audioCheckInputLevel = clampedLevel
        audioCheckInputPeakLevel = audioCheckInputPeakWindow.record(clampedLevel)
        audioCheckRecordedFrames.append(frame)
        audioCheckRecordedFrameCount += frame.frameCount
        if audioCheckRecordedFrameCount == Int(frame.format.sampleRate * 5) {
            finishAudioCheckRecording(playbackDuration: audioCheckPlaybackDuration)
        }
    }

    func finishAudioCheckRecording(playbackDuration: Duration) {
        guard audioCheckPhase == .recording else { return }

        inputFrameDelivery?.finish()
        let recordedFrames: [PCMFrame]
        do {
            try audioPipeline.finishMicrophone()
            guard audioPipeline.transmitEncodingFailureCount == audioCheckTransmitFailureBaseline else {
                throw AppAudioPipelineError.transmitFailed
            }
            recordedFrames = try audioCheckRecording?.recordedFrames() ?? []
        } catch {
            failAudioCheck("Audio recording processing failed")
            return
        }
        audioCheckRecordedFrames = recordedFrames
        #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS) && targetEnvironment(simulator)
        audioCheckObservation?.setInput(recordedFrames)
        #endif
        audioCheckRecordedFrameCount = recordedFrames.reduce(0) { $0 + $1.frameCount }
        audioCheckRecordedNonzeroSamples = recordedFrames.reduce(0) { $0 + $1.samples.filter { abs($0) > 0.00001 }.count }
        guard !recordedFrames.isEmpty else {
            failAudioCheck("No microphone samples captured")
            return
        }

        if audioCheckWatchSessionID != nil {
            // Reuse preparing for the control handoff: nonzero recordedFrames
            // distinguishes recorded audio from initial device preparation.
            audioCheckPhase = .preparing
            audioCheckStatusMessage = "Waiting for Watch playback"
            let generation = audioCheckGeneration
            audioCheckTask?.cancel()
            audioCheckTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(5)) } catch { return }
                guard let self, audioCheckGeneration == generation, audioCheckPhase == .preparing else { return }
                failAudioCheck("Watch playback did not start")
            }
            return
        }
        beginAudioCheckPlayback(recordedFrames, playbackDuration: playbackDuration)
    }

    @discardableResult
    func playWatchAudioCheck(sessionID: UUID) -> Bool {
        guard audioCheckWatchSessionID == sessionID, watchAudioLink?.sessionID == sessionID,
              audioCheckPhase == .preparing, !audioCheckRecordedFrames.isEmpty,
              canPrepareAudioCheck else { return false }
        beginAudioCheckPlayback(audioCheckRecordedFrames, playbackDuration: .seconds(5))
        return audioCheckPhase == .playing
    }

    private func beginAudioCheckPlayback(_ recordedFrames: [PCMFrame], playbackDuration: Duration) {
        audioCheckRecordedFrames.removeAll()
        let outputLevel = AudioLevelMeter.rmsLevel(samples: recordedFrames.flatMap(\.samples))
        audioCheckOutputLevel = min(1, max(0, outputLevel))
        audioCheckOutputPeakLevel = audioCheckOutputPeakWindow.record(audioCheckOutputLevel)
        audioCheckPhase = .playing
        audioCheckStatusMessage = audioCheckWatchSessionID == nil ? "Playing recorded audio for 5 seconds" : "Playing recorded audio on Watch"
        do {
            audioPipeline.setHardwareOutputEnabled(audioCheckWatchSessionID == nil)
            watchAudioLink?.setSendingAllowed(audioCheckWatchSessionID != nil)
            audioPipeline.beginFinitePlayback()
            for frame in recordedFrames { try audioPipeline.processPlaybackFrame(frame) }
        } catch {
            failAudioCheck("Audio playback failed")
            return
        }
        let generation = audioCheckGeneration

        audioCheckTask?.cancel()
        audioCheckTask = Task { [weak self] in
            try? await Task.sleep(for: playbackDuration)
            guard let self, !Task.isCancelled, self.audioCheckGeneration == generation else { return }
            let drain = self.audioCheckWatchSessionID == nil ? self.audioPipeline.audioCheckDrainDuration : 0
            guard drain.isFinite, drain <= 1 else {
                self.failAudioCheck("Audio playback failed")
                return
            }
            try? await Task.sleep(for: .seconds(max(0, drain)))
            guard !Task.isCancelled, self.audioCheckGeneration == generation else { return }
            self.completeAudioCheckPlayback()
        }
    }

    private func prepareAudioCheckPipeline() -> Bool {
        do {
            var configuration = currentAudioPipelineConfiguration()
            configuration.receiveMasterSoundIsolationEnabled = false
            configuration.peerSoundIsolationEnabled = [:]
            configuration.receiveMaximumBufferedDuration = 5
            configuration.finitePlaybackDuration = 6
            audioPipeline.setHardwareOutputEnabled(audioOutputRenderer.rendersToHardware)
            try audioPipeline.rebuild(configuration: configuration, peerIDs: ["audio-check"], startsOutputClock: false)
            audioCheckTransmitFailureBaseline = audioPipeline.transmitEncodingFailureCount
            audioCheckRecording?.setProcessingLatency(audioPipeline.transmitProcessingLatency)
            return true
        } catch { return false }
    }

    /// Every failed check ends the same way: the phase, one sentence, and the pipeline it owned.
    private func failAudioCheck(_ message: String) {
        audioCheckPhase = .failed
        audioCheckStatusMessage = message
        stopAudioCheckOwnedPipeline()
    }

    func completeAudioCheckPlayback() {
        guard audioCheckPhase == .playing else { return }

        audioCheckPhase = .completed
        audioCheckStatusMessage = "Audio check complete"
        audioCheckOutputLevel = 0
        stopAudioCheckOwnedPipeline()
    }

    func cancelAudioCheck() {
        audioCheckGeneration = UUID()
        audioCheckTask?.cancel()
        audioCheckTask = nil
        stopAudioCheckOwnedPipeline()
        audioCheckRecordedFrames.removeAll()
        audioCheckWatchSessionID = nil
        audioCheckPhase = .idle
        audioCheckStatusMessage = "Audio check idle"
        resetAudioCheckMeters()
    }

    func stopAudioCheckOwnedPipeline() {
        guard audioCheckOwnsAudioPipeline else { return }

        audioGeneration = UUID()
        #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS) && targetEnvironment(simulator)
        let observationInputDrops = inputFrameDelivery?.droppedFrameCount ?? 0
        #endif
        inputFrameDelivery?.finish()
        inputFrameDelivery = nil
        #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS) && targetEnvironment(simulator)
        let observationDrops = audioPipeline.droppedRenderFrameCount
        #endif
        audioPipeline.stop()
        audioPipeline.onTransmitPacket = callSession.audioPacketSink
        audioCheckRecording = nil
        #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS) && targetEnvironment(simulator)
        let inputStop = audioInputCapture.stop()
        let outputStop = audioOutputRenderer.stop()
        #else
        _ = audioInputCapture.stop()
        _ = audioOutputRenderer.stop()
        #endif
        _ = audioSessionManager.requestActive(false)
        audioCheckOwnsAudioPipeline = false
        if audioCheckWatchSessionID != nil, isUsingWatchAudio {
            stopWatchAudioLink()
            audioInputCapture = nativeAudioInputCapture
            audioOutputRenderer = nativeAudioOutputRenderer
            isUsingWatchAudio = false
            audioPipeline.setHardwareOutputEnabled(true)
            applyEffectiveInputMute()
        }
        #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS) && targetEnvironment(simulator)
        if let observation = audioCheckObservation {
            let phase = audioCheckPhase.isInProgress ? "Cancelled" : audioCheckPhase.rawValue
            let record = observation.record(phase: phase, drops: observationDrops, inputDrops: observationInputDrops,
                inputStopped: !inputStop.snapshot.isRunning, outputStopped: !outputStop.snapshot.isRunning,
                nativeBackends: audioInputCapture === nativeAudioInputCapture && audioOutputRenderer === nativeAudioOutputRenderer,
                watchRoute: isUsingWatchAudio, engineRunning: audioOutputRenderer.renderingEngine?.isRunning)
            audioCheckObservationRecords.append(record)
            if let data = try? JSONSerialization.data(withJSONObject: audioCheckObservationRecords, options: [.sortedKeys]) {
                try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("phone-audio-check-observation.json"), options: .atomic)
            }
            audioCheckObservation = nil
        }
        #endif
    }

    func resetAudioCheckMeters() {
        audioCheckInputLevel = 0
        audioCheckInputPeakLevel = 0
        audioCheckOutputLevel = 0
        audioCheckOutputPeakLevel = 0
        audioCheckInputPeakWindow = VoicePeakWindow()
        audioCheckOutputPeakWindow = VoicePeakWindow()
    }
}
