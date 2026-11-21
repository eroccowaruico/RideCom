import AudioCore
import Foundation
import Logging
import SessionManager

extension IntercomViewModel {
    func resetAudioDebugCounters() {
        sentVoicePacketCount = 0
        transmitPacketCounterBaseline = audioPipeline.inputObservation.sentPackets
        receivedVoicePacketCount = 0
        lastScheduledOutputRMS = 0
        lastScheduledOutputPeakRMS = 0
        nativeRenderedOutputBatchCount = 0
        scheduledOutputBatchCount = 0
        lastPlaybackScheduledAt = nil
        lastReceivedAudioAt = nil
        lastAudibleReceivedAudioAt = nil
        droppedAudioPacketCount = 0
        jitterQueuedFrameCount = 0
        playbackOutputPeakWindow = VoicePeakWindow()
    }

    func refreshOtherAudioDuckingState(now: TimeInterval = Date().timeIntervalSince1970) {
        setOtherAudioDuckingActive(shouldApplyOtherAudioDucking(now: now))
    }

    func shouldApplyOtherAudioDucking(now: TimeInterval) -> Bool {
        guard isDuckOthersEnabled,
              isAudioReady,
              audioCheckPhase == .idle,
              !isOutputMuted,
              masterOutputVolume > 0 else { return false }
        return hasRecentReceivedAudio(now: now)
    }

    func hasRecentReceivedAudio(now: TimeInterval) -> Bool {
        let lastAudibleOutputAt = audioPipeline.rendersToHardware
            ? audioPipeline.lastNativeAudibleOutputAt : lastAudibleReceivedAudioAt
        guard let lastAudibleOutputAt else { return false }
        return now - lastAudibleOutputAt <= Self.otherAudioDuckingHoldDuration
    }

    func setOtherAudioDuckingActive(_ isActive: Bool) {
        guard isOtherAudioDuckingActiveInternal != isActive else { return }
        isOtherAudioDuckingActiveInternal = isActive
        #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS)
        BackgroundCallValidationObservation.measureDuckingChange(to: isActive) {
            _ = applyCurrentVoiceProcessingConfiguration()
        }
        #else
        applyCurrentVoiceProcessingConfiguration()
        #endif
    }

    func refreshNativeOutputObservation(now: TimeInterval) {
        guard isAudioReady, audioCheckPhase == .idle, audioPipeline.rendersToHardware else { return }
        let observation = audioPipeline.takeNativeOutputObservation()
        let fresh =
            audioPipeline.lastNativeRenderAt.map { now - $0 <= AppAudioPipeline.nativeOutputObservationLifetime }
            ?? false
        if isOutputMuted || masterOutputVolume <= 0 || !fresh {
            lastScheduledOutputRMS = 0
            lastScheduledOutputPeakRMS = 0
        } else if let observation {
            lastScheduledOutputRMS = observation.rms
            lastScheduledOutputPeakRMS = observation.peakRMS
            lastAudibleReceivedAudioAt = observation.lastAudibleAt
            nativeRenderedOutputBatchCount += observation.frameCount
        }
        #if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS)
        if observation != nil { BackgroundCallValidationObservation.observe(self, output: true) }
        #endif
    }

    func scheduleOutputFrame(frame: PCMFrame, receivedAt: TimeInterval) {
        guard !isOutputMuted, masterOutputVolume > 0 else {
            lastScheduledOutputRMS = 0
            lastScheduledOutputPeakRMS = playbackOutputPeakWindow.record(0)
            return
        }

        let level = AudioLevelMeter.rmsLevel(samples: frame.samples)
        lastScheduledOutputRMS = level
        lastScheduledOutputPeakRMS = playbackOutputPeakWindow.record(level)
        let report = audioOutputRenderer.schedule(frame)
        lastOutputStreamOperationReport = report
        if !report.result.isContinuable {
            audioErrorMessage = "Audio output failed"
            AppLoggers.audio.warning(
                "audio.output.schedule_failed",
                metadata: .event("audio.output.schedule_failed", [
                    "errorType": "\(report.result)",
                    "isRecoverable": "true"
                ])
            )
        }
        guard case .applied = report.result else { return }
        scheduledOutputBatchCount += 1
        lastPlaybackScheduledAt = receivedAt
        if level > AudioLevelMeter.audibleOutputThreshold {
            lastAudibleReceivedAudioAt = receivedAt
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
