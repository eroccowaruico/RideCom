import AudioCore
import AudioMixer
import AVFAudio
import Codec
import Foundation
import RTC
import SoundIsolation
import Synchronization
import Testing
import VADGate
@testable import RideIntercom

extension AppTests {
@MainActor
struct RealtimeConversationTests {
    @Test func callReceiveWindowBoundsStartupAndLearnsWiFiJitter() {
        let window = AppAudioPipelineConfiguration.callReceiveMaximumBufferedDuration
        let start = AppAudioPipelineConfiguration.callReceivePlayoutDelay
        // Audio queued before the output clock runs is rebuilt beyond the
        // window: a wider window keeps that start-up delay for the whole call.
        #expect(window <= 0.12)
        // AudioMixer learns up to half of the window minus the start wait.
        #expect((window - start) / 2 >= 0.05, "Learns at least 50 ms of extra Wi-Fi transit")
        #expect(start <= 0.002, "A calm link keeps the low-delay start")
    }

    @Test func receiverForwardsCodecCadenceWithoutCodecSpecificPlaybackBranches() throws {
        let engine = AVAudioEngine()
        let native = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: native, maximumFrameCount: 4800)
        let receiver = AppAudioReceiver()
        try receiver.rebuild(engine: engine, configuration: .init(transmitSoundIsolationEnabled: false,
            receiveMaximumBufferedDuration: 0.12, receivePlayoutDelay: 0.002), peers: ["cadence"],
            rendersToHardware: false, onOutput: { _ in })
        defer { receiver.stop() }
        let format = AudioFormat(sampleRate: 16000, channelCount: 1)
        let encoder = try StreamingCodecEncoder(configuration: .init(codec: .mpeg4AACELD, format: format))
        for index in 0..<8 {
            guard let encoded = try encoder.encode(.init(sequenceNumber: UInt64(index), format: format,
                capturedAt: Double(index) * 0.02, samples: Array(repeating: 0.1, count: 320))) else { continue }
            let frame = try receiver.receive(.init(peerID: .init(rawValue: "cadence"), packet: .init(
                            sequenceNumber: encoded.sequenceNumber, codec: .mpeg4AACELD,
                            format: .init(sampleRate: 16000, channelCount: 1),
                capturedAt: encoded.capturedAt, sampleCount: encoded.sampleCount, payload: encoded.payload)))
            if !frame.samples.isEmpty {
                let state = try #require(receiver.playoutDiagnostics(peer: "cadence"))
                let margin = state.bufferedDuration - Double(frame.frameCount) / 16000
                #expect(abs(margin - 0.012) < 3 / 48000.0)
                #expect(state.adjustments == 0 && state.resets == 0)
                return
            }
        }
        Issue.record("AAC never produced a decoded frame")
    }

    @Test func receiveWaitingBehindStopCannotEnterTheRebuiltGraph() throws {
        let receiver = AppAudioReceiver()
        let driver = OfflineAudioDriver()
        let config = AppAudioPipelineConfiguration(transmitSoundIsolationEnabled: false)
        try receiver.rebuild(engine: driver.makeEngine(), configuration: config, peers: [],
            rendersToHardware: false, onOutput: { _ in })
        defer { receiver.stop() }
        // Hold the real owner lock to reproduce an already-arrived packet
        // waiting behind a lifecycle change, without adding production hooks.
            let lock = try #require(
                Mirror(reflecting: receiver).children.first { $0.label == "lock" }?.value as? NSRecursiveLock)
        let packet = try AppTestSupport.receivedAudioPacket(peerID: "old-call",
            frame: .init(sequenceNumber: 0, samples: Array(repeating: 0.1, count: 480)), codec: .pcm16)
        let entered = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
        let rejected = Mutex(false)
        lock.lock()
        var held = true
        defer { if held { lock.unlock() } }
        DispatchQueue.global(qos: .userInteractive).async {
            entered.signal()
                do { _ = try receiver.receive(packet) } catch AppAudioPipelineError.notConfigured {
                    rejected.withLock { $0 = true }
                } catch {}
            completed.signal()
        }
        #expect(entered.wait(timeout: .now() + 1) == .success)
        #expect(completed.wait(timeout: .now() + .milliseconds(30)) == .timedOut)
        receiver.stop()
        try receiver.rebuild(engine: driver.makeEngine(), configuration: config, peers: [],
            rendersToHardware: false, onOutput: { _ in })
        lock.unlock(); held = false
        #expect(completed.wait(timeout: .now() + 1) == .success)
        #expect(rejected.withLock { $0 })
        #expect(!receiver.snapshot.busIDs.contains("rx-peer-old-call"))
    }

    @Test(arguments: [false, true])
    func receiveLearnsLinkDelayWithoutLearningTimeSpentWaitingForTheGraph(lateArrival: Bool) throws {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
        let receiver = AppAudioReceiver()
        try receiver.rebuild(engine: engine, configuration: .init(transmitSoundIsolationEnabled: false,
            receiveMaximumBufferedDuration: 0.12, receivePlayoutDelay: 0.002), peers: ["peer"],
            rendersToHardware: false, onOutput: { _ in })
        defer { receiver.stop() }
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        func packet(_ number: UInt64, at capture: TimeInterval) throws -> RTC.ReceivedAudioPacket {
            try AppTestSupport.receivedAudioPacket(peerID: "peer",
                frame: .init(sequenceNumber: number, capturedAt: capture, samples: Array(repeating: 0.2, count: 480)),
                codec: .pcm16)
        }
        _ = try receiver.receive(packet(0, at: ProcessInfo.processInfo.systemUptime))
        #expect(try engine.renderOffline(4800, to: output) == .success)
        let capture = ProcessInfo.processInfo.systemUptime + 0.01
        let delayed = try packet(1, at: capture)
        while ProcessInfo.processInfo.systemUptime < capture { Thread.sleep(forTimeInterval: 0.001) }
        if lateArrival {
            Thread.sleep(forTimeInterval: 0.06)
            _ = try receiver.receive(delayed)
        } else {
            // The packet has already reached the App while the graph owner is busy.
                let lock = try #require(
                    Mirror(reflecting: receiver).children.first { $0.label == "lock" }?.value as? NSRecursiveLock)
            let started = DispatchSemaphore(value: 0), completed = DispatchSemaphore(value: 0)
            let decoded = Mutex(false)
            lock.lock()
            DispatchQueue.global(qos: .userInteractive).async {
                started.signal()
                decoded.withLock { $0 = (try? receiver.receive(delayed)) != nil }
                completed.signal()
            }
            let entered = started.wait(timeout: .now() + 1)
            let waited = completed.wait(timeout: .now() + .milliseconds(60))
            lock.unlock()
            #expect(entered == .success && waited == .timedOut)
            #expect(completed.wait(timeout: .now() + 1) == .success)
            #expect(decoded.withLock { $0 })
        }
        #expect(receiver.playoutDiagnostics(peer: "peer")?.adjustments == 1)
        // Drain the rebooked voice so the next reservation shows only the retained allowance.
        #expect(try engine.renderOffline(4800, to: output) == .success)
        _ = try receiver.receive(packet(2, at: capture + 1))
        let buffered = try #require(receiver.playoutDiagnostics(peer: "peer")?.bufferedDuration)
        if lateArrival {
            #expect(buffered >= 0.05)
        } else {
            #expect(buffered <= 0.035)
        }
    }

    @Test func receiverReportsTheAdjustmentOnlyForThePacketThatMoved() throws {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
        let receiver = AppAudioReceiver()
        try receiver.rebuild(engine: engine, configuration: .init(transmitSoundIsolationEnabled: false,
            receiveMaximumBufferedDuration: 0.12, receivePlayoutDelay: 0.02), peers: ["peer"],
            rendersToHardware: false, onOutput: { _ in })
        defer { receiver.stop() }
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
        let start = ProcessInfo.processInfo.systemUptime
        var observed: [ReceivePlayoutDiagnostics] = []
        func receive(_ sequence: UInt64) throws {
            let frame = PCMFrame(sequenceNumber: sequence, capturedAt: start + Double(sequence) * 0.02,
                samples: Array(repeating: 0.2, count: 960))
            let received = try AppTestSupport.receivedAudioPacket(peerID: "peer", frame: frame, codec: .pcm16)
            _ = try receiver.receive(received, onPlayout: { observed.append($0) })
        }
        try receive(0)
        #expect(try engine.renderOffline(2400, to: output) == .success)
        try receive(1)
        try receive(2)
        #expect(observed.map(\.adjustments) == [0, 1, 1])
        #expect(observed.map { $0.adjustment?.reason } == [nil, .pastRenderPosition, nil])
        #expect(observed[1].adjustment?.capturedAt == start + 0.02)
        for packet in observed {
            let timing = try #require(packet.processingTiming)
            let acquired = try #require(timing.lockAcquiredAt)
            let decoded = try #require(timing.decodedAt)
            let reserved = try #require(timing.reservedAt)
            #expect(start <= timing.lockRequestedAt)
            #expect(timing.lockRequestedAt <= acquired)
            #expect(acquired <= decoded)
            #expect(decoded <= reserved)
        }
        #expect(receiver.playoutDiagnostics(peer: "peer")?.processingTiming == nil)
    }

    @Test func preparedReceiverQueuesSpeechUntilGraphStart() throws {
        let engine = AVAudioEngine()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 2400)
        let receiver = AppAudioReceiver()
        try receiver.rebuild(engine: engine, configuration: .init(transmitSoundIsolationEnabled: false,
            receiveMaximumBufferedDuration: 0.12, receivePlayoutDelay: 0.002), peers: ["peer"],
            rendersToHardware: true, startsClock: false, onOutput: { _ in })
        defer { receiver.stop() }

        let frame = PCMFrame(sequenceNumber: 0, capturedAt: 0, samples: Array(repeating: 0.2, count: 960))
        let packet = try AppTestSupport.receivedAudioPacket(peerID: "peer", frame: frame, codec: .pcm16)
        _ = try receiver.receive(packet)
        let player = try #require(engine.attachedNodes.compactMap { $0 as? AVAudioPlayerNode }.first)
        #expect(!player.isPlaying)
        #expect(!engine.isRunning)
        #expect(receiver.playoutDiagnostics(peer: "peer")?.bufferedDuration == 0.022)

        try receiver.start()
        #expect(player.isPlaying)
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 2400))
        #expect(try engine.renderOffline(2400, to: output) == .success)
            let samples = UnsafeBufferPointer(
                start: try #require(output.floatChannelData)[0], count: Int(output.frameLength))
        #expect(samples.contains { abs($0) > 0.1 })
    }

    @Test func codecChangesFinishTheOldFadeAndCoalesceOnlySettings() throws {
        let transmitter = AppAudioTransmitter()
            let configuration = AppAudioPipelineConfiguration(
                preferredCodec: .mpeg4AACELD, transmitSoundIsolationEnabled: false)
        let packets = Mutex<[RTCAudioPacket]>([])
        transmitter.onPacket = { packet in packets.withLock { $0.append(packet) } }
            try transmitter.rebuild(
                configuration: configuration, encoding: configuration.codecRuntimeReport.activeConfiguration)
        defer { transmitter.stop() }
        for index in 0..<130 {
            if index == 100 {
                    try transmitter.updateEncoding(
                        .init(codec: .mpeg4AACELD, format: .init(sampleRate: 16000, channelCount: 1)))
                    try transmitter.updateEncoding(
                        .init(codec: .mpeg4AACELD, format: .init(sampleRate: 24000, channelCount: 1)))
            }
            try transmitter.process(.init(sequenceNumber: UInt64(index), capturedAt: Double(index) / 100,
                samples: (0..<480).map { Float(0.15 * sin(Double(index * 480 + $0) * 2 * .pi * 600 / 48000)) }))
        }
        let sent = packets.withLock { $0 }
        #expect(!sent.contains { $0.format.sampleRate == 16000 }, "Only the replaceable setting may coalesce")
        let firstNew = try #require(sent.firstIndex { $0.format.sampleRate == 24000 })
        #expect(firstNew > 0)
        #expect(sent[firstNew].capturedAt < 1.09)
        #expect(zip(sent, sent.dropFirst()).allSatisfy { $1.sequenceNumber == $0.sequenceNumber + 1 })
        let decoder = StreamingCodecDecoder()
        var oldLast: PCMFrame?
        for packet in sent.prefix(firstNew) { oldLast = try AppAudioCodecBridge.decode(packet, using: decoder) }
        #expect(try #require(oldLast).samples.suffix(96).allSatisfy { abs($0) < 0.002 },
            "The already-sent old codec must finish its fade before the new codec fills its first packet")
        #expect(transmitter.failureCount == 0)
    }

    @Test(arguments: [RTCAudioCodecIdentifier.pcm16, .opus, .mpeg4AACELD])
    func silentTransmitterStopsPacketsAndRestartsForBriefReplies(codec: RTCAudioCodecIdentifier) throws {
        let transmitter = AppAudioTransmitter()
        let configuration = AppAudioPipelineConfiguration(preferredCodec: codec, transmitSoundIsolationEnabled: false)
        let packets = Mutex<[RTCAudioPacket]>([])
        transmitter.onPacket = { packet in packets.withLock { $0.append(packet) } }
            try transmitter.rebuild(
                configuration: configuration, encoding: configuration.codecRuntimeReport.activeConfiguration)
        defer { transmitter.stop() }
        for index in 0..<400 {
            let samples = (0..<480).map { sample in
                (200..<210).contains(index) ? Float(0.03 * sin(Double(sample) * 2 * .pi * 500 / 48000)) : 0
            }
                transmitter.processMicrophone(
                    .init(sequenceNumber: UInt64(index), capturedAt: Double(index) / 100, samples: samples))
        }
        let sent = packets.withLock { $0 }
        #expect(!sent.isEmpty)
        #expect(sent.count < 120, "Silence must avoid encoding and sending, including the VAD release period")
        #expect(sent.filter { (0.3..<1.9).contains($0.capturedAt) || (3..<4).contains($0.capturedAt) }.isEmpty)
        let onset = try #require(sent.first { $0.capturedAt >= 1.9 })
        #expect(onset.capturedAt < 2.03, "A 100 ms acknowledgement must resume immediately")
        #expect(transmitter.failureCount == 0)
    }

}
}
