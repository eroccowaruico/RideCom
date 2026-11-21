import AudioCore
import AVFAudio
import Synchronization

/// The last native render block is already committed, even when its host
/// timestamp is still in the future. Schedule beyond its end, not its start.
final class MixerRenderClock: Sendable {
    let frameCount = Atomic<Int>(0)
}

/// Apple's unity EQ supplies a post-render callback at the engine quantum.
/// AVAudioNode taps batch about 100 ms even when bufferSize is much smaller.
final class RenderCaptureNode {
    let node = AVAudioUnitEQ(numberOfBands: 0)
    private let state: RenderState
    var droppedFrameCount: Int { state.capture.load()?.droppedFrameCount ?? 0 }

    init(format: AudioFormat, renderClock: MixerRenderClock) throws {
        state = RenderState(format: format, renderClock: renderClock)
        let context = Unmanaged.passUnretained(state).toOpaque()
        let status = node.withAudioUnit { AudioUnitAddRenderNotify($0, Self.receive, context) }
        guard status == noErr else {
            throw AudioMixerError.pcmSinkInstallFailed("Render notification failed: \(status)")
        }
    }

    func beginTransition(settlingDuration: TimeInterval, holding: Bool = false) {
        state.begin(settlingDuration: settlingDuration, holding: holding)
    }

    func captureAudio(onFrame: @escaping (PCMFrame) -> Void) {
        state.captureAudio(onFrame: onFrame)
    }

    deinit {
        state.capture.load()?.finish()
        let context = Unmanaged.passUnretained(state).toOpaque()
        _ = node.withAudioUnit { AudioUnitRemoveRenderNotify($0, Self.receive, context) }
    }

    private static let receive: AURenderCallback = { context, flags, time, _, count, data in
        if flags.pointee.contains(.unitRenderAction_PostRender),
           !flags.pointee.contains(.unitRenderAction_PostRenderError), let data {
            let state = Unmanaged<RenderState>.fromOpaque(context).takeUnretainedValue()
            state.process(count: Int(count), data: data, flags: flags)
            state.publish(timestamp: time.pointee, frameCount: count, data: UnsafePointer(data))
        }
        return noErr
    }
}

/// All sample state belongs to the render thread. The serial graph owner only
/// posts an atomic request. Memory is allocated once, never in the callback.
private final class RenderState {
    let capture = AtomicLazyReference<AudioRenderCapture>()
    private let renderClock: MixerRenderClock
    private let format: AudioFormat
    private let rate: Double
    private let fadeFrames: Int
    private let channels: Int
    private let last: UnsafeMutablePointer<Float>
    private let beginning: UnsafeMutablePointer<Float>
    private let requestedFrames = Atomic<Int>(-1)
    private var elapsed = 0
    private var settling = 0
    private var transitioning = false
    private var hasResumed = false
    private var holding = false

    init(format: AudioFormat, renderClock: MixerRenderClock) {
        self.renderClock = renderClock
        self.format = format
        rate = format.sampleRate
        channels = format.channelCount
        fadeFrames = max(1, Int((rate * 0.002).rounded()))
        last = .allocate(capacity: channels); last.initialize(repeating: 0, count: channels)
        beginning = .allocate(capacity: channels); beginning.initialize(repeating: 0, count: channels)
    }
    deinit { last.deallocate(); beginning.deallocate() }

    func captureAudio(onFrame: @escaping (PCMFrame) -> Void) {
        guard capture.load() == nil else { return }
        _ = capture.storeIfNil(AudioRenderCapture(format: format, onFrame: onFrame))
    }

    func publish(timestamp: AudioTimeStamp, frameCount: UInt32, data: UnsafePointer<AudioBufferList>) {
        guard let capture = capture.load() else { return }
        renderClock.frameCount.store(Int(frameCount), ordering: .relaxed)
        capture.receive(timestamp: timestamp, frameCount: frameCount, data: data)
    }

    func begin(settlingDuration: TimeInterval, holding: Bool = false) {
        let duration = settlingDuration.isFinite ? min(1, max(0.002, settlingDuration)) : 0.002
        requestedFrames.store(holding ? -2 : max(fadeFrames, Int((rate * duration).rounded())), ordering: .releasing)
    }

    func process(
        count: Int, data: UnsafeMutablePointer<AudioBufferList>, flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>
    ) {
        let buffers = UnsafeMutableAudioBufferListPointer(data)
        // AudioCore accepts mono and stereo. Keep the two pointers on the render stack.
        guard count > 0, buffers.count == channels, channels <= 2 else { return }
        withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<Float>.self, capacity: 2) { samples in
            for channel in 0..<channels {
                let buffer = buffers[channel]
                guard buffer.mDataByteSize >= count * MemoryLayout<Float>.size, let data = buffer.mData else { return }
                samples.initializeElement(at: channel, to: data.assumingMemoryBound(to: Float.self))
            }
            applyTransition(count: count, samples: samples, flags: flags)
        }
    }

    private func applyTransition(
        count: Int, samples: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>,
        flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>
    ) {
        startRequestedTransition()
        if transitioning {
            renderTransition(count: count, samples: samples)
            // A fade of the previous sample can produce output even if the
            // upstream effect marked its newly rendered block as silent.
            flags.pointee.remove(.unitRenderAction_OutputIsSilence)
        }
        for channel in 0..<channels {
            last[channel] = samples[channel][count - 1]
        }
    }

    private func startRequestedTransition() {
        let requested = requestedFrames.exchange(-1, ordering: .acquiring)
        if requested != -1 {
            for channel in 0..<channels { beginning[channel] = last[channel] }
            holding = requested == -2
            settling = max(fadeFrames, requested); elapsed = 0; transitioning = true; hasResumed = false
        }
    }

    private func renderTransition(count: Int, samples: UnsafeMutableBufferPointer<UnsafeMutablePointer<Float>>) {
        for index in 0..<count {
            if holding, elapsed >= fadeFrames {
                for channel in 0..<channels {
                    samples[channel][index] = 0
                }
                continue
            }
            if elapsed >= settling, !hasResumed {
                let audible = (0..<channels).contains {
                    samples[$0][index] != 0
                }
                if !audible { continue }
                hasResumed = true
                elapsed = settling
            }
            if elapsed >= settling + fadeFrames { transitioning = false; break }
            for channel in 0..<channels {
                let output = samples[channel]
                if elapsed < fadeFrames {
                    output[index] = beginning[channel] * Float(1 - Double(elapsed) / Double(fadeFrames))
                } else if elapsed < settling {
                    output[index] = 0
                } else {
                    output[index] *= Float(Double(elapsed - settling) / Double(fadeFrames))
                }
            }
            elapsed += 1
        }

    }
}
