import AudioCore
@preconcurrency import AVFAudio
import Foundation

public final class MixerPCMSource {
	public let id: String
	public let playerNode: AVAudioPlayerNode
	public let faderNode: AVAudioMixerNode
	public let mixerFormat: AudioFormat

	private let recordSchedule: (PCMFrame, AudioProcessingReport?, String?, Bool) -> Void
	private let maximumBufferedDuration: TimeInterval?
	private let captureTimePlayoutDelay: TimeInterval?
	private var playoutAnchor: (capturedAt: TimeInterval, sample: AVAudioFramePosition)?
	private var lastCapturedAt: TimeInterval?
    private var lastCapturedEnd: TimeInterval?
    private var lastAudibleEnd: AVAudioFramePosition = 0
    private var recoveringQuietBurst = false
    // Wi-Fi links hold packets for tens of milliseconds and release them in a
    // burst, again and again. Keep the wait each late arrival proved necessary
    // through conversation pauses; release it only after the link stays calm.
    private var jitterMargin: (frames: AVAudioFramePosition, observedAt: TimeInterval)?
    // Fastest observed transit: local arrival time minus remote capture time.
    // It may rise only as fast as independent device clocks can drift.
    private var fastestTransit: (seconds: Double, observedAt: TimeInterval)?
    private var arrivalBatch: (firstCapture: TimeInterval, lastArrival: TimeInterval, previousDuration: TimeInterval)?
    static let clockDriftAllowance = 0.0002
    static let jitterMarginHold: TimeInterval = 10
    static let jitterMarginReleasePerSecond: TimeInterval = 0.01
    private let adaptivePlayout: Bool
    private let renderClock: MixerRenderClock
    private var normalizer = MixerPCMStreamNormalizer()
    public private(set) var playoutAdjustmentCount = 0
    public private(set) var lastPlayoutAdjustment: MixerPlayoutAdjustment?
	private var startRequested = false
	private var scheduledEndSample: AVAudioFramePosition = 0
	public private(set) var playbackResetCount = 0

	typealias PlaybackPosition = (completed: AVAudioFramePosition, writable: AVAudioFramePosition)

	private var playbackPosition: (
		position: PlaybackPosition, anchorSample: AVAudioFramePosition?, anchorHostTime: TimeInterval?
	) {
		// playerTime also checks that the node is playing.
		return playerNode.lastRenderTime.flatMap { time in
			guard time.isSampleTimeValid || time.isHostTimeValid,
			      let played = playerNode.playerTime(forNodeTime: time), played.isSampleTimeValid else { return nil }
			// Realtime playerTime is the last render quantum, not the current
			// device position. Use its host clock so a healthy boundary does not
			// spuriously cross the bounded capture-time playout window.
			let engine = playerNode.engine
			let usesRealtimeClock = engine?.isInManualRenderingMode == false && engine?.isRunning == true
				&& playerNode.isPlaying && time.isHostTimeValid
			let hostTime = usesRealtimeClock ? AVAudioTime.seconds(forHostTime: time.hostTime) : nil
			let elapsed = hostTime.map { max(0, ProcessInfo.processInfo.systemUptime - $0) } ?? 0
            let quantum = engine?.isInManualRenderingMode == false ? renderClock.frameCount.load(ordering: .relaxed) : 0
			let position = (max(0, played.sampleTime),
				max(0, played.sampleTime + max(AVAudioFramePosition(quantum), AVAudioFramePosition(elapsed * played.sampleRate))))
			return (position, hostTime == nil ? nil : played.sampleTime, hostTime)
		} ?? ((0, 0), nil, nil)
	}
	public var bufferedDuration: TimeInterval {
		Double(max(0, scheduledEndSample - playbackPosition.position.writable)) / mixerFormat.sampleRate
	}

	public var volume: Float {
		get { faderNode.outputVolume }
		set { faderNode.outputVolume = min(1, max(0, newValue)) }
	}

	init(
		id: String,
		playerNode: AVAudioPlayerNode,
		faderNode: AVAudioMixerNode,
		mixerFormat: AudioFormat,
		maximumBufferedDuration: TimeInterval?,
		captureTimePlayoutDelay: TimeInterval?,
        adaptivePlayout: Bool,
        renderClock: MixerRenderClock,
		recordSchedule: @escaping (PCMFrame, AudioProcessingReport?, String?, Bool) -> Void
	) {
		self.id = id
		self.playerNode = playerNode
		self.faderNode = faderNode
		self.mixerFormat = mixerFormat
		self.recordSchedule = recordSchedule
		self.maximumBufferedDuration = maximumBufferedDuration
		self.captureTimePlayoutDelay = captureTimePlayoutDelay
        self.adaptivePlayout = adaptivePlayout
        self.renderClock = renderClock
	}

	@discardableResult
    /// `arrivedAt` is the local monotonic time the packet arrived (uptime
    /// seconds by default). Link jitter is learned from it, never from the
    /// render clock, which also moves for local output events.
	/// `startsNewArrivalTiming` marks the first playable frame after a known
	/// change in sender timing. A frame that produces no PCM does not mark it.
	/// `onReservation` observes successful timestamped scheduling on the caller's thread.
	public func schedule(_ frame: PCMFrame, packetizationJitter: TimeInterval = 0,
                         arrivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
                         startsNewArrivalTiming: Bool = false,
                         onReservation: ((MixerPlayoutReservation) -> Void)? = nil) throws -> AudioProcessingReport {
		do {
            guard packetizationJitter.isFinite, (0...0.06).contains(packetizationJitter) else {
                throw AudioMixerError.pcmSourceScheduleFailed("Invalid packetization timing")
            }
			let normalized = try normalizer.normalize(frame, to: mixerFormat, operation: .normalizeSource)
            guard normalized.frame.frameCount > 0 else {
                recordSchedule(frame, normalized.report, nil, false)
                return normalized.report
            }
			let capturedAt = normalized.frame.capturedAt
			let buffer = try normalized.frame.makePCMBuffer()
			let playback = playbackPosition
			let position = playback.position
            let rendered = position.writable
			var options: AVAudioPlayerNodeBufferOptions = []
			let duration = Double(buffer.frameLength) / mixerFormat.sampleRate
            // Native lossy codecs can leave isolated sub-milliscale samples
            // after a pause. A peak-only -80 dB test mistakes this inaudible
            // tail for speech and keeps an accumulated jitter delay forever.
            let energy = normalized.frame.samples.reduce(Float(0)) { $0 + $1 * $1 }
            let audible = energy >= Float(max(1, normalized.frame.samples.count)) * 0.0001 * 0.0001
                || normalized.frame.samples.contains { abs($0) >= 0.001 }
			if let limit = maximumBufferedDuration {
				guard limit.isFinite, limit > 0, duration <= limit,
					  limit * mixerFormat.sampleRate < Double(Int64.max) / 4 else {
					throw AudioMixerError.pcmSourceScheduleFailed("Frame exceeds live playback budget")
				}
			}
			let startSample: AVAudioFramePosition
			if let delay = captureTimePlayoutDelay, let limit = maximumBufferedDuration {
				guard capturedAt.isFinite else {
					throw AudioMixerError.pcmSourceScheduleFailed("Invalid capture timestamp")
				}
                // playbackPosition already advances past the current native
                // block. Bound the additional command handoff to 2 ms rather
                // than waiting another whole device quantum.
                // A stopped player starts with its prepared first buffer and
                // needs no handoff allowance. Offline rendering needs none.
                let nativeLead = adaptivePlayout && playerNode.isPlaying
                    && playerNode.engine?.isInManualRenderingMode == false
                    ? min(AVAudioFramePosition(renderClock.frameCount.load(ordering: .relaxed)),
                        AVAudioFramePosition((0.002 * mixerFormat.sampleRate).rounded(.up))) : 0
                let reservation = captureTimeReservation(
                    capturedAt: capturedAt, arrivedAt: arrivedAt, frameLength: buffer.frameLength, duration: duration,
                    audible: audible, position: position, nativeLead: nativeLead,
                    delay: delay, limit: limit, packetizationJitter: packetizationJitter,
                    startsNewArrivalTiming: startsNewArrivalTiming)
                startSample = reservation.startSample
                options = reservation.options
			} else {
				// Bound the wait before this frame starts, not its completion.
				// A full capture batch may overlap the previous batch's healthy tail.
				if let limit = maximumBufferedDuration,
				   scheduledEndSample - rendered >= AVAudioFramePosition(limit * mixerFormat.sampleRate) {
					options = .interrupts
					scheduledEndSample = rendered
					playbackResetCount += 1
				}
				startSample = max(scheduledEndSample, rendered)
			}
			scheduledEndSample = startSample + AVAudioFramePosition(buffer.frameLength)
            if audible { lastAudibleEnd = scheduledEndSample }
			// Timestamped sources preserve omitted silence and absorb arrival jitter.
			// Keep capture-time sources explicit even when adjacent: after an
            // interrupt, native implicit adjacency can retain a different clock
            // until the next omitted pause. Ordinary untimed sources use the queue.
			let time = captureTimePlayoutDelay == nil
				? nil : AVAudioTime(sampleTime: startSample, atRate: mixerFormat.sampleRate)
			playerNode.scheduleBuffer(buffer, at: time, options: options)
            if startRequested && !playerNode.isPlaying { try playerNode.playAudio() }
			recordSchedule(frame, normalized.report, nil, true)
			if let onReservation, time != nil {
				onReservation(.init(capturedAt: capturedAt, sampleRate: mixerFormat.sampleRate,
					startSample: startSample, frameCount: Int(buffer.frameLength), completedSample: position.completed,
					writableSample: position.writable, renderAnchorSample: playback.anchorSample,
					renderAnchorHostTime: playback.anchorHostTime))
			}
			return normalized.report
		} catch let failure as AudioProcessingFailure {
			recordSchedule(frame, nil, failure.reason, false)
			throw failure
		} catch {
			recordSchedule(frame, nil, String(describing: error), false)
			throw AudioMixerError.pcmSourceScheduleFailed(String(describing: error))
		}
	}

    /// Update the capture-to-playout mapping using the position already observed for this packet.
    func captureTimeReservation(
        capturedAt: TimeInterval, arrivedAt: TimeInterval, frameLength: AVAudioFrameCount, duration: TimeInterval,
        audible: Bool, position: PlaybackPosition, nativeLead: AVAudioFramePosition,
        delay: TimeInterval, limit: TimeInterval, packetizationJitter: TimeInterval,
        startsNewArrivalTiming: Bool = false
    ) -> (startSample: AVAudioFramePosition, options: AVAudioPlayerNodeBufferOptions) {
        let rendered = position.writable
        var options: AVAudioPlayerNodeBufferOptions = []
        // Device handoff and arrival jitter are independent. Taking
        // their maximum silently removes the configured jitter margin.
        // Reserve only the sender's measured capture/codec remainder.
        // This is independent of network jitter; aligned codecs add zero.
        let margin = adaptivePlayout ? retainedJitterMargin(at: capturedAt) : 0
        if startsNewArrivalTiming {
            // A codec/capture change can shift the minimum transit even on a
            // calm link. Keep the wait previously earned by real arrivals.
            fastestTransit = nil
            arrivalBatch = nil
        }
        let transit = arrivedAt - capturedAt
        let batch = adaptivePlayout ? updateArrivalBatch(capturedAt: capturedAt,
            arrivedAt: arrivedAt, packetDuration: duration) : (previousDuration: 0, offset: 0)
        if let fastest = fastestTransit,
           transit >= fastest.seconds + (capturedAt - fastest.observedAt) * Self.clockDriftAllowance {
        } else { fastestTransit = (transit, capturedAt) }
        let requestedLead = nativeLead + margin
            + AVAudioFramePosition(((delay + packetizationJitter) * mixerFormat.sampleRate).rounded())
        let boundedLead = min(requestedLead, AVAudioFramePosition((limit * mixerFormat.sampleRate).rounded(.down)) - 1)
        let delayedStart = rendered + boundedLead
        if playoutAnchor == nil { playoutAnchor = (capturedAt, delayedStart) }
        let anchor = playoutAnchor!
        var target = Double(anchor.sample) + (capturedAt - anchor.capturedAt) * mixerFormat.sampleRate
        var adjustment: (reason: MixerPlayoutAdjustment.Reason, previousSample: AVAudioFramePosition?)?
        if adaptivePlayout {
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
            let normalTail = min(batch.offset, batch.previousDuration)
            let recoveryMargin = (max(0.02, duration * 2) + normalTail) * mixerFormat.sampleRate
            if audible || target <= Double(delayedStart) { recoveringQuietBurst = false }
            // Replacing silence must use the confirmed player clock,
            // not the future scheduling frontier. A block currently
            // rendering can still contain the end of the last word.
            let canReduceDelay = !audible && lastAudibleEnd <= position.completed
                && (target > Double(delayedStart) + recoveryMargin || recoveringQuietBurst)
            // Omitted silence is still part of the capture clock. Do
            // not move a healthy returning syllable merely because the
            // pause was long; reduce only an accumulated excess wait.
            // The player reserves whole samples. A fractional clock
            // residue at the boundary must not shorten a healthy pause.
            let resumeAllowance = (max(delay, duration) * mixerFormat.sampleRate).rounded()
            let resumedWithExcessWait = resumed
                && target.rounded() > Double(delayedStart) + resumeAllowance
            // The writable frontier reserves a future native quantum;
            // crossing it does not prove that the target has rendered.
            // This also applies after omitted silence. Rebasing there
            // shifts every following syllable despite timely arrival.
            let expired = target.rounded() < Double(position.completed)
            if expired || resumedWithExcessWait || canReduceDelay {
                let reason: MixerPlayoutAdjustment.Reason
                if expired { reason = .pastRenderPosition }
                else if resumedWithExcessWait { reason = .excessDelayAfterPause }
                else { reason = .excessQueuedSilence }
                adjustment = (reason, AVAudioFramePosition(exactly: target.rounded()))
                var start = delayedStart
                if expired, !startsNewArrivalTiming, let fastest = fastestTransit,
                   // A start-up backlog or local outage longer than the
                   // window cannot be absorbed and is not link jitter.
                   transit - fastest.seconds < limit {
                    // Learn this packet's whole excess transit, not only
                    // the part the current wait failed to cover, plus the
                    // packet and one more for the render quantum that
                    // must start before its first sample (one packet
                    // alone left gaps on the audio E2E).
                    let excessTransit = max(0, transit - fastest.seconds)
                    let elapsedWait = excessTransit * mixerFormat.sampleRate
                    let excess = elapsedWait + 2 * Double(frameLength)
                    // Even after a calm link, a late packet can arrive
                    // with all the audio captured while it was held.
                    // Leave room for that tail before adding learned wait.
                    let window = (limit - delay - packetizationJitter) * mixerFormat.sampleRate
                    let remainingBatch = max(0, batch.previousDuration - batch.offset)
                    let reserved = max(remainingBatch, excessTransit + duration) * mixerFormat.sampleRate
                        + Double(nativeLead)
                    let availableWait = AVAudioFramePosition(max(0, window - reserved).rounded(.down))
                    let ceiling = min(AVAudioFramePosition(max(0, window / 2)), availableWait)
                    let learned = max(margin, min(AVAudioFramePosition(excess.rounded(.up)), ceiling))
                    jitterMargin = (learned, capturedAt)
                    // The writable frontier already covers the native block.
                    // Subtract that part of the second packet's headroom from
                    // this reservation only. Keep the learned link wait intact.
                    let coveredQuantum = min(AVAudioFramePosition(frameLength), rendered - position.completed)
                    let remainingWait = max(0, learned - AVAudioFramePosition(elapsedWait.rounded(.down)) - coveredQuantum)
                    start = rendered + min(requestedLead - margin + min(remainingWait, availableWait),
                        AVAudioFramePosition((limit * mixerFormat.sampleRate).rounded(.down)) - 1)
                }
                target = Double(max(start, lastAudibleEnd > rendered ? scheduledEndSample : start))
                playoutAnchor = (capturedAt, AVAudioFramePosition(target))
                if canReduceDelay {
                    options = .interrupts // only queued silence is replaced
                    recoveringQuietBurst = true
                }
            }
        }
        let startSample: AVAudioFramePosition
        // Remote and local clocks have unrelated epochs. Retain only their
        // relative mapping, and rebase after a restart or a discontinuity
        // outside the bounded playout window. Never reserve arbitrary future audio.
        if !target.isFinite || target < Double(rendered) - limit * mixerFormat.sampleRate
            || target > Double(rendered) + limit * mixerFormat.sampleRate
            || lastCapturedAt.map({ capturedAt <= $0 }) == true {
            playoutAnchor = (capturedAt, delayedStart)
            startSample = delayedStart
            if scheduledEndSample > rendered { options = .interrupts }
            playbackResetCount += 1
        } else {
            startSample = AVAudioFramePosition(target.rounded())
        }
        if let adjustment {
            playoutAdjustmentCount += 1
            lastPlayoutAdjustment = MixerPlayoutAdjustment(reason: adjustment.reason, capturedAt: capturedAt,
                completedSample: position.completed, previousSample: adjustment.previousSample, scheduledSample: startSample)
        }
        lastCapturedAt = capturedAt
        lastCapturedEnd = capturedAt + duration
        return (startSample, options)
    }

	/// A rejected native start keeps the request; the next schedule retries it
	/// and reports the failure through the schedule result.
	public func start() {
        startRequested = true
        if adaptivePlayout, captureTimePlayoutDelay != nil, playoutAnchor == nil,
           !playerNode.isPlaying, playerNode.engine?.isInManualRenderingMode == false {
            // One local silent sample establishes the native player clock
            // before speech arrives. No microphone/network data is involved.
            // The first real packet maps its capture epoch onto that clock.
            if let silence = try? PCMFrame(sequenceNumber: 0, format: mixerFormat, capturedAt: 0,
                samples: Array(repeating: 0, count: mixerFormat.channelCount)).makePCMBuffer() {
                playerNode.scheduleBuffer(silence, at: nil)
                try? playerNode.playAudio()
            }
            return
        }
        // A timestamped player starts with its first buffer so sample zero and
        // the capture anchor are established together in offline/fixed playback.
        guard !playerNode.isPlaying,
              captureTimePlayoutDelay == nil ? scheduledEndSample > 0 : playoutAnchor != nil else { return }
		try? playerNode.playAudio()
	}

    func invalidatePlayout() {
        let restart = startRequested
        stop()
        startRequested = restart
    }

	public func stop() {
        startRequested = false
		playerNode.stop()
		scheduledEndSample = 0
		playoutAnchor = nil
		lastCapturedAt = nil
        lastCapturedEnd = nil
        arrivalBatch = nil
        lastAudibleEnd = 0
        recoveringQuietBurst = false
        // The learned wait and fastest arrival describe the peer's link, not
        // this player: an output or input restart keeps them.
        normalizer = MixerPCMStreamNormalizer()
	}

    /// The learned wait, held for 10 s after the last late arrival and then
    /// released at 10 ms per second of calm sender time.
    private func retainedJitterMargin(at capturedAt: TimeInterval) -> AVAudioFramePosition {
        guard let margin = jitterMargin else { return 0 }
        let calm = max(0, capturedAt - margin.observedAt - Self.jitterMarginHold)
        return max(0, margin.frames - AVAudioFramePosition((calm * Self.jitterMarginReleasePerSecond * mixerFormat.sampleRate).rounded()))
    }

    /// Contiguous audio delivered faster than its sample clock is one burst.
    /// The previous burst estimates the space for a new tail. Within a burst,
    /// the offset measures how much of that tail has already been scheduled.
    private func updateArrivalBatch(capturedAt: TimeInterval, arrivedAt: TimeInterval,
                                    packetDuration: TimeInterval) -> (previousDuration: TimeInterval, offset: TimeInterval) {
        if let batch = arrivalBatch, let end = lastCapturedEnd {
            let deliveryGap = arrivedAt - batch.lastArrival
            if abs(capturedAt - end) <= 2 / mixerFormat.sampleRate,
               deliveryGap >= 0 && deliveryGap < packetDuration / 2 {
                arrivalBatch?.lastArrival = arrivedAt
                return (batch.previousDuration, capturedAt - batch.firstCapture)
            }
            let previousDuration = max(0, end - batch.firstCapture)
            arrivalBatch = (capturedAt, arrivedAt, previousDuration)
            return (previousDuration, 0)
        }
        arrivalBatch = (capturedAt, arrivedAt, 0)
        return (0, 0)
    }
}

public final class MixerPCMSink {
	public let id: String
	public let mixerFormat: AudioFormat
	public internal(set) var targetFormat: AudioFormat

	private let onFrame: (PCMFrame, AudioProcessingReport) -> Void
	private let recordEmit: (AudioProcessingReport?, String?) -> Void
	private let packetDuration: TimeInterval?
    private let maximumFrameDuration: TimeInterval?
	private var nextSequenceNumber: UInt64 = 0
	private let streamingNormalizer = MixerPCMStreamNormalizer()
	private var pendingSamples: [Float] = []
	private var pendingCapturedAt: TimeInterval = 0
    private var transition = PCMStreamTransition()

    /// An upstream stream reset discards unsent audio, never flushes it late.
    func resetStream() {
        pendingSamples.removeAll(keepingCapacity: true)
        streamingNormalizer.reset()
        transition.reset()
    }

    func beginTransition(settlingDuration: TimeInterval, holding: Bool = false) {
        transition.begin(settlingDuration: settlingDuration, holding: holding)
    }

	init(
		id: String,
		mixerFormat: AudioFormat,
		targetFormat: AudioFormat,
		packetDuration: TimeInterval?,
        maximumFrameDuration: TimeInterval?,
		onFrame: @escaping (PCMFrame, AudioProcessingReport) -> Void,
		recordEmit: @escaping (AudioProcessingReport?, String?) -> Void
	) {
		self.id = id
		self.mixerFormat = mixerFormat
		self.targetFormat = targetFormat
		self.packetDuration = packetDuration
        self.maximumFrameDuration = maximumFrameDuration
		self.onFrame = onFrame
		self.recordEmit = recordEmit
	}

	@discardableResult
	func receive(_ mixerFrame: PCMFrame) throws -> AudioProcessingReport {
        let mixerFrame = transition.process(mixerFrame)
		guard let duration = packetDuration, !mixerFrame.samples.isEmpty else {
			return try emit(mixerFrame)
		}
		_ = try mixerFrame.validated()
        let rate = mixerFrame.format.sampleRate
        let channels = mixerFrame.format.channelCount
        let count = max(1, Int((rate * duration).rounded(.down))) * channels
        var report: AudioProcessingReport?
        if !pendingSamples.isEmpty {
            let expected = pendingCapturedAt + Double(pendingSamples.count / channels) / rate
            if abs(mixerFrame.capturedAt - expected) > 2 / rate {
                report = try emit(.init(sequenceNumber: nextSequenceNumber, format: mixerFrame.format,
                    capturedAt: pendingCapturedAt, samples: pendingSamples))
                nextSequenceNumber &+= 1
                pendingSamples.removeAll(keepingCapacity: true)
            }
        }
        if pendingSamples.isEmpty { pendingCapturedAt = mixerFrame.capturedAt }
        pendingSamples.append(contentsOf: mixerFrame.samples)
        // Packetize before sample-rate conversion. Rounding each 512-frame
        // quantum independently at 16 kHz adds samples and overlaps the next
        // packet. Exact-duration packets preserve both sample and capture clocks.
        while pendingSamples.count >= count {
            report = try emit(.init(sequenceNumber: nextSequenceNumber, format: mixerFrame.format,
                capturedAt: pendingCapturedAt, samples: Array(pendingSamples.prefix(count))))
            nextSequenceNumber &+= 1
            pendingSamples.removeFirst(count)
            pendingCapturedAt += Double(count / channels) / rate
        }
        return report ?? AudioProcessingReport(operation: .normalizeSink,
            sourceFormat: mixerFrame.format, targetFormat: targetFormat,
            inputSampleCount: mixerFrame.samples.count, outputSampleCount: 0, result: .notRequired)
    }

	private func emit(_ mixerFrame: PCMFrame) throws -> AudioProcessingReport {
		do {
			let normalized = try packetDuration == nil
                ? streamingNormalizer.normalize(mixerFrame, to: targetFormat, operation: .normalizeSink)
                : MixerPCMNormalizer.normalize(mixerFrame, to: targetFormat, operation: .normalizeSink)
            let frame = normalized.frame
            let limit = maximumFrameDuration.map { max(1, Int($0 * targetFormat.sampleRate)) * targetFormat.channelCount }
                ?? max(1, frame.samples.count)
            for start in stride(from: 0, to: frame.samples.count, by: limit) {
                let samples = Array(frame.samples[start..<min(frame.samples.count, start + limit)])
                var report = normalized.report
                report.inputSampleCount = start == 0 ? normalized.report.inputSampleCount : 0
                report.outputSampleCount = samples.count
                recordEmit(report, nil)
                onFrame(.init(sequenceNumber: frame.sequenceNumber, format: targetFormat,
                    capturedAt: frame.capturedAt + Double(start / targetFormat.channelCount) / targetFormat.sampleRate,
                    samples: samples), report)
            }
			return normalized.report
		} catch let failure as AudioProcessingFailure {
			recordEmit(nil, failure.reason)
			throw failure
		} catch {
			recordEmit(nil, String(describing: error))
			throw AudioMixerError.pcmSinkInstallFailed(String(describing: error))
		}
	}
}
