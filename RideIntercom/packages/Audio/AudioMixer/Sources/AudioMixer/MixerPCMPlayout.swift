import AudioCore
@preconcurrency import AVFAudio
import Foundation

/// Owns reservations, the playback clock, and learned arrival timing for one source.
final class MixerPCMPlayout {
    typealias PlaybackPosition = MixerPCMSource.PlaybackPosition
    struct Reservation {
        let startSample: AVAudioFramePosition
        let options: AVAudioPlayerNodeBufferOptions
        var anchorLead: MixerPlayoutReservation.AnchorLead?
    }
    private let mixerFormat: AudioFormat
    private let adaptivePlayout: Bool
    private(set) var playoutAnchor: (capturedAt: TimeInterval, sample: AVAudioFramePosition)?
    private var lastCapturedAt: TimeInterval?
    private var lastCapturedEnd: TimeInterval?
    private var lastAudibleEnd: AVAudioFramePosition = 0
    private var recoveringQuietBurst = false
    // Keep the wait earned by repeated bursty arrivals through conversation pauses.
    private var jitterMargin: (frames: AVAudioFramePosition, observedAt: TimeInterval)?
    // Fastest observed transit may rise only as quickly as independent clocks drift.
    private var fastestTransit: (seconds: Double, observedAt: TimeInterval)?
    private var arrivalBatch: ArrivalBatch?
    static let clockDriftAllowance = 0.0002
    static let jitterMarginHold: TimeInterval = 10
    static let jitterMarginReleasePerSecond: TimeInterval = 0.01
    private(set) var scheduledEndSample: AVAudioFramePosition = 0
    private(set) var playbackResetCount = 0
    private(set) var playoutAdjustmentCount = 0
    private(set) var lastPlayoutAdjustment: MixerPlayoutAdjustment?

    init(mixerFormat: AudioFormat, adaptivePlayout: Bool) {
        self.mixerFormat = mixerFormat
        self.adaptivePlayout = adaptivePlayout
    }

    func resetClock() {
        scheduledEndSample = 0
        playoutAnchor = nil
        lastCapturedAt = nil
        lastCapturedEnd = nil
        arrivalBatch = nil
        lastAudibleEnd = 0
        recoveringQuietBurst = false
    }

    func queueReservation(writable: AVAudioFramePosition, limit: TimeInterval?) -> Reservation {
        // The budget limits the wait before a new frame starts. It allows the
        // new frame to extend past the budget while the previous tail plays.
        if let limit, scheduledEndSample - writable >= AVAudioFramePosition(limit * mixerFormat.sampleRate) {
            playbackResetCount += 1
            return Reservation(startSample: writable, options: .interrupts)
        }
        return Reservation(startSample: max(scheduledEndSample, writable), options: [])
    }

    func recordScheduled(_ reservation: Reservation, frameLength: AVAudioFrameCount, audible: Bool) {
        scheduledEndSample = reservation.startSample + AVAudioFramePosition(frameLength)
        if audible { lastAudibleEnd = scheduledEndSample }
    }

    struct ReservationInput {
        let capturedAt: TimeInterval
        let arrivedAt: TimeInterval
        let frameLength: AVAudioFrameCount
        let duration: TimeInterval
        let audible: Bool
        let position: PlaybackPosition
        let nativeLead: AVAudioFramePosition
        let delay: TimeInterval
        let limit: TimeInterval
        let packetizationJitter: TimeInterval
        var startsNewArrivalTiming = false
    }

    /// Update the capture-to-playout mapping using the position already observed for this packet.
    func captureTimeReservation(
        _ input: ReservationInput, observesAnchor: Bool = false
    ) -> Reservation {
        let capturedAt = input.capturedAt
        var options: AVAudioPlayerNodeBufferOptions = []
        // Device handoff and arrival jitter are independent. Taking
        // their maximum silently removes the configured jitter margin.
        // Reserve only the sender's measured capture/codec remainder.
        // This is independent of network jitter; aligned codecs add zero.
        let margin = adaptivePlayout ? retainedJitterMargin(at: capturedAt) : 0
        if input.startsNewArrivalTiming {
            // A codec/capture change can shift the minimum transit even on a
            // calm link. Keep the wait previously earned by real arrivals.
            fastestTransit = nil
            arrivalBatch = nil
        }
        let transit = input.arrivedAt - capturedAt
        let batch = adaptivePlayout ? updateArrivalBatch(capturedAt: capturedAt,
            arrivedAt: input.arrivedAt, packetDuration: input.duration) : (previousDuration: 0, offset: 0)
        if let fastest = fastestTransit,
           transit >= fastest.seconds + (capturedAt - fastest.observedAt) * Self.clockDriftAllowance {
        } else { fastestTransit = (transit, capturedAt) }
        let requestedLead = input.nativeLead + margin
            + AVAudioFramePosition(((input.delay + input.packetizationJitter) * mixerFormat.sampleRate).rounded())
        let boundedLead = min(requestedLead,
            AVAudioFramePosition((input.limit * mixerFormat.sampleRate).rounded(.down)) - 1)
        let delayedStart = input.position.writable + boundedLead
        let establishesAnchor = playoutAnchor == nil
        let anchor = playoutAnchor ?? (capturedAt: capturedAt, sample: delayedStart)
        if playoutAnchor == nil { playoutAnchor = anchor }
        var target = Double(anchor.sample) + (capturedAt - anchor.capturedAt) * mixerFormat.sampleRate
        var adjustment: (reason: MixerPlayoutAdjustment.Reason, previousSample: AVAudioFramePosition?)?
        if adaptivePlayout {
            adjustment = adjustAdaptiveTarget(
                input: input, context: .init(margin: margin, batch: batch, requestedLead: requestedLead,
                    delayedStart: delayedStart), target: &target, options: &options
            )
        }
        let previousResetCount = playbackResetCount
        let startSample = boundedStartSample(
            target: target, input: input, delayedStart: delayedStart, options: &options
        )
        if let adjustment {
            recordAdjustment(.init(reason: adjustment.reason, capturedAt: capturedAt,
                completedSample: input.position.completed, previousSample: adjustment.previousSample,
                scheduledSample: startSample))
        }
        lastCapturedAt = capturedAt
        lastCapturedEnd = capturedAt + input.duration
        var reservation = Reservation(startSample: startSample, options: options)
        if observesAnchor && (establishesAnchor || adjustment != nil || playbackResetCount != previousResetCount) {
            reservation.anchorLead = .init(nativeLeadFrames: input.nativeLead, configuredDelay: input.delay,
                packetizationJitter: input.packetizationJitter, retainedJitterFramesBefore: margin,
                retainedJitterFramesAfter: retainedJitterMargin(at: capturedAt))
        }
        return reservation
    }

    private func recordAdjustment(_ adjustment: MixerPlayoutAdjustment) {
        playoutAdjustmentCount += 1
        lastPlayoutAdjustment = adjustment
    }

    private struct AdaptiveReservationContext {
        let margin: AVAudioFramePosition
        let batch: (previousDuration: TimeInterval, offset: TimeInterval)
        let requestedLead: AVAudioFramePosition
        let delayedStart: AVAudioFramePosition
    }

    private func adjustAdaptiveTarget(
        input: ReservationInput, context: AdaptiveReservationContext, target: inout Double,
        options: inout AVAudioPlayerNodeBufferOptions
    ) -> (reason: MixerPlayoutAdjustment.Reason, previousSample: AVAudioFramePosition?)? {
        let capturedAt = input.capturedAt
        let duration = input.duration
        let audible = input.audible
        let position = input.position
        let rendered = position.writable
        let delay = input.delay
        let limit = input.limit
        let startsNewArrivalTiming = input.startsNewArrivalTiming
        let transit = input.arrivedAt - input.capturedAt
        var adjustment: (reason: MixerPlayoutAdjustment.Reason, previousSample: AVAudioFramePosition?)?
        let contiguous = lastCapturedEnd.map { abs(capturedAt - $0) <= 2 / mixerFormat.sampleRate } ?? false
        // Exact sample adjacency wins over host-time rounding. Each
        // peer retains its own clock; a late arrival never overlaps
        // or trims the preceding or following packet.
        if contiguous {
            target = Double(scheduledEndSample)
        }
        let resumed = lastCapturedEnd.map { capturedAt - $0 > 0.25 } ?? false
        // Only the previous burst's observed duration counts as
        // normal tail growth. A one-off backlog can still shrink.
        let normalTail = min(context.batch.offset, context.batch.previousDuration)
        let recoveryMargin = (max(0.02, duration * 2) + normalTail) * mixerFormat.sampleRate
        if audible || target <= Double(context.delayedStart) { recoveringQuietBurst = false }
        // Replacing silence must use the confirmed player clock,
        // not the future scheduling frontier. A block currently
        // rendering can still contain the end of the last word.
        let canReduceDelay = !audible && lastAudibleEnd <= position.completed
            && (target > Double(context.delayedStart) + recoveryMargin || recoveringQuietBurst)
        // Omitted silence is still part of the capture clock. Do
        // not move a healthy returning syllable merely because the
        // pause was long; reduce only an accumulated excess wait.
        // The player reserves whole samples. A fractional clock
        // residue at the boundary must not shorten a healthy pause.
        let resumeAllowance = (max(delay, duration) * mixerFormat.sampleRate).rounded()
        let resumedWithExcessWait = resumed
            && target.rounded() > Double(context.delayedStart) + resumeAllowance
        // The writable frontier reserves a future native quantum;
        // crossing it does not prove that the target has rendered.
        // This also applies after omitted silence. Rebasing there
        // shifts every following syllable despite timely arrival.
        let expired = target.rounded() < Double(position.completed)
        if expired || resumedWithExcessWait || canReduceDelay {
            let reason: MixerPlayoutAdjustment.Reason
            if expired {
                reason = .pastRenderPosition
            } else if resumedWithExcessWait {
                reason = .excessDelayAfterPause
            } else {
                reason = .excessQueuedSilence
            }
            adjustment = (reason, AVAudioFramePosition(exactly: target.rounded()))
            var start = context.delayedStart
            if expired, !startsNewArrivalTiming, let fastest = fastestTransit,
               // A start-up backlog or local outage longer than the
               // window cannot be absorbed and is not link jitter.
               transit - fastest.seconds < limit {
                start = learnedLateStart(
                    input: input, margin: context.margin, batch: context.batch, requestedLead: context.requestedLead,
                    fastestTransitSeconds: fastest.seconds
                )
            }
            target = Double(max(start, lastAudibleEnd > rendered ? scheduledEndSample : start))
            playoutAnchor = (capturedAt, AVAudioFramePosition(target))
            if canReduceDelay {
                options = .interrupts // only queued silence is replaced
                recoveringQuietBurst = true
            }
        }
        return adjustment
    }

    private func learnedLateStart(
        input: ReservationInput, margin: AVAudioFramePosition,
        batch: (previousDuration: TimeInterval, offset: TimeInterval),
        requestedLead: AVAudioFramePosition, fastestTransitSeconds: TimeInterval
    ) -> AVAudioFramePosition {
        // Learn this packet's whole excess transit, not only
        // the part the current wait failed to cover, plus the
        // packet and one more for the render quantum that
        // must start before its first sample (one packet
        // alone left gaps on the audio E2E).
        let excessTransit = max(0, input.arrivedAt - input.capturedAt - fastestTransitSeconds)
        let elapsedWait = excessTransit * mixerFormat.sampleRate
        let excess = elapsedWait + 2 * Double(input.frameLength)
        // Even after a calm link, a late packet can arrive
        // with all the audio captured while it was held.
        // Leave room for that tail before adding learned wait.
        let window = (input.limit - input.delay - input.packetizationJitter) * mixerFormat.sampleRate
        let remainingBatch = max(0, batch.previousDuration - batch.offset)
        let reserved = max(remainingBatch, excessTransit + input.duration) * mixerFormat.sampleRate
            + Double(input.nativeLead)
        let availableWait = AVAudioFramePosition(max(0, window - reserved).rounded(.down))
        let ceiling = min(AVAudioFramePosition(max(0, window / 2)), availableWait)
        let learned = max(margin, min(AVAudioFramePosition(excess.rounded(.up)), ceiling))
        jitterMargin = (learned, input.capturedAt)
        // The writable frontier already covers the native block.
        // Subtract that part of the second packet's headroom from
        // this reservation only. Keep the learned link wait intact.
        let coveredQuantum = min(
            AVAudioFramePosition(input.frameLength), input.position.writable - input.position.completed
        )
        let waitedFrames = AVAudioFramePosition(elapsedWait.rounded(.down))
        let remainingWait = max(0, learned - waitedFrames - coveredQuantum)
        return input.position.writable + min(requestedLead - margin + min(remainingWait, availableWait),
            AVAudioFramePosition((input.limit * mixerFormat.sampleRate).rounded(.down)) - 1)
    }

    private func boundedStartSample(
        target: Double, input: ReservationInput, delayedStart: AVAudioFramePosition,
        options: inout AVAudioPlayerNodeBufferOptions
    ) -> AVAudioFramePosition {
        // Remote and local clocks have unrelated epochs. Retain only their
        // relative mapping, and rebase after a restart or a discontinuity
        // outside the bounded playout window. Never reserve arbitrary future audio.
        if !target.isFinite || target < Double(input.position.writable) - input.limit * mixerFormat.sampleRate
            || target > Double(input.position.writable) + input.limit * mixerFormat.sampleRate
            || lastCapturedAt.map({ input.capturedAt <= $0 }) == true {
            playoutAnchor = (input.capturedAt, delayedStart)
            if scheduledEndSample > input.position.writable { options = .interrupts }
            playbackResetCount += 1
            return delayedStart
        } else {
            return AVAudioFramePosition(target.rounded())
        }
    }

    /// The learned wait, held for 10 s after the last late arrival and then
    /// released at 10 ms per second of calm sender time.
    private func retainedJitterMargin(at capturedAt: TimeInterval) -> AVAudioFramePosition {
        guard let margin = jitterMargin else { return 0 }
        let calm = max(0, capturedAt - margin.observedAt - Self.jitterMarginHold)
        let release = calm * Self.jitterMarginReleasePerSecond * mixerFormat.sampleRate
        return max(0, margin.frames - AVAudioFramePosition(release.rounded()))
    }

    /// Contiguous audio delivered faster than its sample clock is one burst.
    /// The previous burst estimates the space for a new tail. Within a burst,
    /// the offset measures how much of that tail has already been scheduled.
    private func updateArrivalBatch(
        capturedAt: TimeInterval,
        arrivedAt: TimeInterval,
        packetDuration: TimeInterval
    ) -> (previousDuration: TimeInterval, offset: TimeInterval) {
        if let batch = arrivalBatch, let end = lastCapturedEnd {
            let deliveryGap = arrivedAt - batch.lastArrival
            if abs(capturedAt - end) <= 2 / mixerFormat.sampleRate,
               deliveryGap >= 0 && deliveryGap < packetDuration / 2 {
                arrivalBatch?.lastArrival = arrivedAt
                return (batch.previousDuration, capturedAt - batch.firstCapture)
            }
            let previousDuration = max(0, end - batch.firstCapture)
            arrivalBatch = ArrivalBatch(
                firstCapture: capturedAt, lastArrival: arrivedAt, previousDuration: previousDuration
            )
            return (previousDuration, 0)
        }
        arrivalBatch = ArrivalBatch(firstCapture: capturedAt, lastArrival: arrivedAt, previousDuration: 0)
        return (0, 0)
    }

    private struct ArrivalBatch {
        let firstCapture: TimeInterval
        var lastArrival: TimeInterval
        let previousDuration: TimeInterval
    }

}
