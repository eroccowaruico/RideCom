import AVFAudio
import AudioCore
import Foundation
import SessionManager
import RTC
import XCTest
@testable import RideIntercom

@MainActor
final class FixtureKeychain: KeychainSecretStoring {
    private var values: [String: [String: String]] = [:]
    func createSecretIfAbsent(_ value: String, service: String, account: String) -> String {
        if let retained = values[service]?[account] { return retained }
        values[service, default: [:]][account] = value
        return value
    }
    func accounts(service: String) -> [String] { Array(values[service, default: [:]].keys) }
    func saveSecret(_ secret: String, service: String, account: String) {
        values[service, default: [:]][account] = secret
    }
    func secret(service: String, account: String) -> String? { values[service]?[account] }
    func deleteSecret(service: String, account: String) { values[service]?[account] = nil }
}

/// Legacy scenarios coordinate over the same authenticated, encrypted connection.
/// Long outage scenarios can coordinate through their independent fixture worker.
@MainActor
final class AudioE2EBarrier {
    private var received: Set<String> = []
    private let session: any RideIntercom.CallSession
    private let rendezvous: (@MainActor (String, Double) async throws -> Void)?

    init(session: any RideIntercom.CallSession, rendezvous: (@MainActor (String, Double) async throws -> Void)? = nil) {
        self.session = session
        self.rendezvous = rendezvous
        guard rendezvous == nil else { return }
        let original = session.onEvent
        session.onEvent = { [weak self] event in
            original?(event)
            if case .receivedApplicationData(_, let message) = event,
               message.namespace == "test.audio-e2e", let token = String(data: message.payload, encoding: .utf8) {
                self?.received.insert(token)
            }
        }
    }

    func meet(_ phase: String, timeout: Double = 30) async throws {
        if let rendezvous { try await rendezvous(phase, timeout); return }
        for suffix in ["ready", "ack"] {
            let token = phase + ":" + suffix
            let start = ContinuousClock.now
            repeat {
                session.sendApplicationData(.init(namespace: "test.audio-e2e", payload: Data(token.utf8)))
                try await Task.sleep(for: .milliseconds(100))
                if start.duration(to: .now) > .seconds(timeout) {
                    throw NSError(domain: "AudioE2E.Barrier.\(token)", code: 1)
                }
            } while !received.contains(token)
        }
    }

    /// Deliver a small value through the same group control path as the rendezvous.
    func exchange(_ phase: String, value: String) async throws -> String {
        let prefix = phase + ":value:"
        let ack = phase + ":received"
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        repeat {
            session.sendApplicationData(.init(namespace: "test.audio-e2e", payload: Data((prefix + value).utf8)))
            let remote = received.first { $0.hasPrefix(prefix) }
            if remote != nil {
                session.sendApplicationData(.init(namespace: "test.audio-e2e", payload: Data(ack.utf8)))
            }
            try await Task.sleep(for: .milliseconds(100))
            if let remote, received.contains(ack) { return String(remote.dropFirst(prefix.count)) }
        } while ContinuousClock.now < deadline
        throw NSError(domain: "AudioE2E.Barrier." + phase, code: 1)
    }
}

/// Fixture position follows capture time. A missing native interval omits the
/// corresponding source samples; it must not delay all later fixture speech.
struct CaptureTimedFixture {
    let samples: [Float]
    private var origin: Double?
    init(samples: [Float]) { self.samples = samples }
    mutating func render(capturedAt: Double, format: AudioFormat, frameCount: Int) -> [Float] {
        let start = origin ?? capturedAt
        origin = start
        var beginning = (capturedAt - start) * 48000
        if abs(beginning - beginning.rounded()) < 0.0001 { beginning = beginning.rounded() }
        let step = 48000 / format.sampleRate
        var block: [Float] = []
        block.reserveCapacity(frameCount * format.channelCount)
        for frame in 0..<frameCount {
            var position = (beginning + Double(frame) * step).truncatingRemainder(dividingBy: Double(samples.count))
            if position < 0 { position += Double(samples.count) }
            let index = Int(position), fraction = Float(position - Double(Int(position)))
            let value = samples[index] * (1 - fraction) + samples[(index + 1) % samples.count] * fraction
            block.append(contentsOf: repeatElement(value, count: format.channelCount))
        }
        return block
    }
}

/// Test-only microphone boundary. Everything downstream uses the shipping path.
final class SpeechFileInput: AudioInputStreamBackend {
    private enum FrameDelivery { case speech, silence, disabled }

    struct DeliveryTiming: Encodable {
        let capture: Double
        let duration: Double
        let callback: Double
        let handedOff: Double
        let returned: Double
    }

    let samples: [Float]
    private let timingLock = NSLock()
    private var frameDelivery = FrameDelivery.speech
    private var firstCapture: Double?
    private var startupDelivery: [DeliveryTiming]?
    private var captureAges: [Double] = []
    private var captureDurations: [Double] = []
    private var previousCaptureEnd: Double?
    private var clockDiscontinuities: [[String: Double]] = []
    var captureDiscontinuities: [[String: Double]] { timingLock.withLock { clockDiscontinuities } }
    private var processingUpdates: [[String: Double]] = []
    var voiceProcessingTimings: [[String: Double]] { timingLock.withLock { processingUpdates } }
    var captureTiming: [String: Double] { timingLock.withLock {
            [
                "maximumCallbackAge": captureAges.max() ?? 0,
                "meanCallbackAge": captureAges.reduce(0, +) / Double(max(1, captureAges.count)),
         "minimumCompletedSampleAge": zip(captureAges, captureDurations).map { $0 - $1 }.min() ?? 0,
         "maximumFrameDuration": captureDurations.max() ?? 0, "minimumFrameDuration": captureDurations.min() ?? 0]
    } }
    var firstCaptureTime: Double? { timingLock.withLock { firstCapture } }
    var droppedCaptureFrameCount: Int {
        #if os(iOS)
        hardware.droppedCaptureFrameCount
        #else
        0
        #endif
    }
    func setFrameDeliveryEnabled(_ enabled: Bool) {
        timingLock.withLock { frameDelivery = enabled ? .speech : .disabled }
    }

    func setSilentInput(_ silent: Bool) {
        timingLock.withLock { frameDelivery = silent ? .silence : .speech }
    }

    func observeStartupDelivery() {
        timingLock.withLock { startupDelivery = [] }
    }

    func finishStartupDelivery() -> [DeliveryTiming]? {
        timingLock.withLock {
            defer { startupDelivery = nil }
            return startupDelivery
        }
    }

    private func recordCaptureTime(_ time: Double, duration: Double) -> (FrameDelivery, Double?) { timingLock.withLock {
        if firstCapture == nil { firstCapture = time }
        let host = ProcessInfo.processInfo.systemUptime
        if let previousCaptureEnd, abs(time - previousCaptureEnd) > 2 / 48000.0 {
            clockDiscontinuities.append(["host": host, "capture": time, "gap": time - previousCaptureEnd])
        }
        previousCaptureEnd = time + duration
        captureAges.append(host - time); captureDurations.append(duration)
        return (frameDelivery, startupDelivery == nil ? nil : host)
    } }

    private func deliver(_ frame: PCMFrame, callback: Double?, onFrame: (PCMFrame) -> Void) {
        guard let callback else { onFrame(frame); return }
        let handedOff = ProcessInfo.processInfo.systemUptime
        onFrame(frame)
        let returned = ProcessInfo.processInfo.systemUptime
        let duration = Double(frame.frameCount) / frame.format.sampleRate
        timingLock.withLock {
            startupDelivery?.append(.init(capture: frame.capturedAt, duration: duration, callback: callback,
                                          handedOff: handedOff, returned: returned))
        }
    }
    #if os(iOS)
    private let hardware: SystemAudioInputStreamBackend
    #endif
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "audio-e2e.fixture", qos: .userInteractive)

    init(samples: [Float], engine: AVAudioEngine = AVAudioEngine()) {
        self.samples = samples
        #if os(iOS)
        hardware = SystemAudioInputStreamBackend(engine: engine)
        #endif
    }

    init(name: String, engine: AVAudioEngine = AVAudioEngine(), addingIsolationNoise: Bool = false) throws {
        #if os(iOS)
        hardware = SystemAudioInputStreamBackend(engine: engine)
        #endif
        let url = try XCTUnwrap(Bundle(for: AudioE2ETests.self).url(forResource: name, withExtension: "wav"))
        let file = try AVAudioFile(forReading: url)
        let buffer = try XCTUnwrap(
            AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))
        )
        try file.read(into: buffer)
        precondition(file.processingFormat.sampleRate == 48_000 && file.processingFormat.channelCount == 1)
        let channel = try XCTUnwrap(buffer.floatChannelData)[0]
        let input = UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))
        if addingIsolationNoise {
            // Keep the other endpoint and the speech match references clean.
            samples = input.enumerated().map { index, sample in
                let time = Double(index) / 48_000
                return sample + Float(0.030 * sin(2 * .pi * 397 * time) + 0.020 * sin(2 * .pi * 1763 * time))
            }
        } else {
            samples = Array(input)
        }
    }

    func updateVoiceProcessing(_ configuration: AudioInputVoiceProcessingConfiguration) throws {
        #if os(iOS)
        let start = ProcessInfo.processInfo.systemUptime
        defer { timingLock.withLock { processingUpdates.append(["host": start,
            "duration": ProcessInfo.processInfo.systemUptime - start]) } }
        try hardware.updateVoiceProcessing(configuration)
        #else
        // No hardware voice processing at the file boundary; never report it applied.
        throw AudioStreamError.unsupportedOnCurrentPlatform
        #endif
    }

    func startCapture(
        configuration: AudioInputStreamConfiguration, onFrame: @escaping (PCMFrame) -> Void
    ) throws -> AudioFormat {
        try stopCapture()
        timingLock.withLock { firstCapture = nil; previousCaptureEnd = nil }
        #if os(iOS)
        var fixture = CaptureTimedFixture(samples: samples)
        // Exercise the real iOS input engine, route format and capture clock.
        // Discard microphone values immediately; only fixture samples leave here.
        return try hardware.startCapture(configuration: configuration) { [weak self] frame in
            guard let self else { return }
            let (delivery, callback) = recordCaptureTime(frame.capturedAt,
                duration: Double(frame.frameCount) / frame.format.sampleRate)
            guard delivery != .disabled else { return }
            let block = delivery == .silence ? Array(repeating: Float(0), count: frame.samples.count)
                : fixture.render(capturedAt: frame.capturedAt, format: frame.format, frameCount: frame.frameCount)
            deliver(PCMFrame(sequenceNumber: frame.sequenceNumber, format: frame.format,
                             capturedAt: frame.capturedAt, samples: block), callback: callback, onFrame: onFrame)
        }
        #else
        let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        var fixture = CaptureTimedFixture(samples: samples)
        var sequence: UInt64 = 0
        let captureEpoch = ProcessInfo.processInfo.systemUptime
        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10), leeway: .nanoseconds(0))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            // Dispatch may coalesce wakeups. Deliver every completed interval,
            // as the real capture ring does, without slowing the fixture clock.
            let ticks = max(1, self.timer?.data ?? 1)
            for _ in 0..<ticks {
                let captureTime = captureEpoch + Double(sequence) * 0.01
                defer { sequence += 1 }
                let (delivery, callback) = recordCaptureTime(captureTime, duration: 0.01)
                guard delivery != .disabled else { continue }
                let block = delivery == .silence ? Array(repeating: Float(0), count: 480)
                    : fixture.render(capturedAt: captureTime, format: .init(), frameCount: 480)
                deliver(PCMFrame(sequenceNumber: sequence, format: .init(), capturedAt: captureTime, samples: block),
                        callback: callback, onFrame: onFrame)
            }
        }
        self.timer = timer
        timer.resume()
        return AudioFormat(sampleRate: 48_000, channelCount: 1)
        #endif
    }

    func stopCapture() throws {
        timer?.cancel(); timer = nil
        #if os(iOS)
        try hardware.stopCapture()
        #endif
    }
    deinit { timer?.cancel() }
}
