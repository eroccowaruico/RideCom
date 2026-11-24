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
    private let playout: MixerPCMPlayout
    private let adaptivePlayout: Bool
    private let renderClock: MixerRenderClock
    private var normalizer = MixerPCMStreamNormalizer()
    public var playoutAdjustmentCount: Int { playout.playoutAdjustmentCount }
    public var lastPlayoutAdjustment: MixerPlayoutAdjustment? { playout.lastPlayoutAdjustment }
	private var startRequested = false
	public var playbackResetCount: Int { playout.playbackResetCount }

	typealias PlaybackPosition = (completed: AVAudioFramePosition, writable: AVAudioFramePosition)

	private var playbackPosition: PlaybackClockReading {
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
			let advance = max(AVAudioFramePosition(quantum), AVAudioFramePosition(elapsed * played.sampleRate))
			let position = (completed: max(0, played.sampleTime), writable: max(0, played.sampleTime + advance))
			return PlaybackClockReading(
				position: position,
				anchorSample: hostTime == nil ? nil : played.sampleTime,
				anchorHostTime: hostTime
			)
		} ?? PlaybackClockReading(position: (0, 0), anchorSample: nil, anchorHostTime: nil)
	}
	public var bufferedDuration: TimeInterval {
		Double(max(0, playout.scheduledEndSample - playbackPosition.position.writable)) / mixerFormat.sampleRate
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
        self.playout = MixerPCMPlayout(mixerFormat: mixerFormat, adaptivePlayout: adaptivePlayout)
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
	public func schedule(
		_ frame: PCMFrame,
		packetizationJitter: TimeInterval = 0,
		arrivedAt: TimeInterval = ProcessInfo.processInfo.systemUptime,
		startsNewArrivalTiming: Bool = false,
		onReservation: ((MixerPlayoutReservation) -> Void)? = nil
	) throws -> AudioProcessingReport {
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
			let duration = Double(buffer.frameLength) / mixerFormat.sampleRate
            // Native lossy codecs can leave isolated sub-milliscale samples
            // after a pause. A peak-only -80 dB test mistakes this inaudible
            // tail for speech and keeps an accumulated jitter delay forever.
            let energy = normalized.frame.samples.reduce(Float(0)) { $0 + $1 * $1 }
            let audible = energy >= Float(max(1, normalized.frame.samples.count)) * 0.0001 * 0.0001
                || normalized.frame.samples.contains { abs($0) >= 0.001 }
			try validatePlaybackBudget(for: duration)
            let reservation = try reservePlayback(.init(
                capturedAt: capturedAt, arrivedAt: arrivedAt, frameLength: buffer.frameLength,
                duration: duration, audible: audible, position: position, packetizationJitter: packetizationJitter,
                startsNewArrivalTiming: startsNewArrivalTiming
            ), observesAnchor: onReservation != nil)
            let startSample = reservation.startSample
            let options = reservation.options
			playout.scheduledEndSample = startSample + AVAudioFramePosition(buffer.frameLength)
            if audible { playout.lastAudibleEnd = playout.scheduledEndSample }
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
					renderAnchorHostTime: playback.anchorHostTime, anchorLead: reservation.anchorLead))
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

    private struct PlaybackPacket {
        let capturedAt: TimeInterval
        let arrivedAt: TimeInterval
        let frameLength: AVAudioFrameCount
        let duration: TimeInterval
        let audible: Bool
        let position: PlaybackPosition
        let packetizationJitter: TimeInterval
        let startsNewArrivalTiming: Bool
    }

    private func reservePlayback(
        _ packet: PlaybackPacket, observesAnchor: Bool
    ) throws -> MixerPCMPlayout.Reservation {
        let capturedAt = packet.capturedAt
        let arrivedAt = packet.arrivedAt
        let duration = packet.duration
        let audible = packet.audible
        let position = packet.position
        let packetizationJitter = packet.packetizationJitter
        let startsNewArrivalTiming = packet.startsNewArrivalTiming
        let rendered = position.writable
        var options: AVAudioPlayerNodeBufferOptions = []
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
            return captureTimeReservation(.init(
                capturedAt: capturedAt, arrivedAt: arrivedAt, frameLength: packet.frameLength, duration: duration,
                audible: audible, position: position, nativeLead: nativeLead,
                delay: delay, limit: limit, packetizationJitter: packetizationJitter,
                startsNewArrivalTiming: startsNewArrivalTiming), observesAnchor: observesAnchor)
        } else {
            // Bound the wait before this frame starts, not its completion.
            // A full capture batch may overlap the previous batch's healthy tail.
            if let limit = maximumBufferedDuration,
               playout.scheduledEndSample - rendered >= AVAudioFramePosition(limit * mixerFormat.sampleRate) {
                options = .interrupts
                playout.scheduledEndSample = rendered
                playout.playbackResetCount += 1
            }
            return .init(startSample: max(playout.scheduledEndSample, rendered), options: options)
        }
    }

	private func validatePlaybackBudget(for duration: TimeInterval) throws {
		guard let limit = maximumBufferedDuration else { return }
		guard limit.isFinite, limit > 0, duration <= limit,
			  limit * mixerFormat.sampleRate < Double(Int64.max) / 4 else {
			throw AudioMixerError.pcmSourceScheduleFailed("Frame exceeds live playback budget")
		}
	}

    func captureTimeReservation(
        _ input: MixerPCMPlayout.ReservationInput, observesAnchor: Bool = false
    ) -> MixerPCMPlayout.Reservation {
        playout.captureTimeReservation(input, observesAnchor: observesAnchor)
    }

	/// A rejected native start keeps the request; the next schedule retries it
	/// and reports the failure through the schedule result.
	public func start() {
        startRequested = true
        if adaptivePlayout, captureTimePlayoutDelay != nil, playout.playoutAnchor == nil,
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
              captureTimePlayoutDelay == nil ? playout.scheduledEndSample > 0 : playout.playoutAnchor != nil
        else { return }
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
        playout.resetClock()
        // The learned wait and fastest arrival describe the peer's link, not
        // this player: an output or input restart keeps them.
        normalizer = MixerPCMStreamNormalizer()
	}

    private struct PlaybackClockReading {
        let position: PlaybackPosition
        let anchorSample: AVAudioFramePosition?
        let anchorHostTime: TimeInterval?
    }
}
