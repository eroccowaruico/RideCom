import AudioCore
import AVFAudio
import Foundation
import Testing
@testable import AudioMixer

@Test func healthyConversationPauseKeepsItsClockButExcessWaitIsRemoved() throws {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("pause-clock")
    let source = try bus.addPCMSource(id: "peer", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.02, adaptivePlayout: true)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
    try source.schedule(.init(sequenceNumber: 0, capturedAt: 1000, samples: Array(repeating: 0.2, count: 480)))
    for _ in 0..<3 { #expect(try engine.renderOffline(4800, to: output) == .success) }
    try source.schedule(.init(sequenceNumber: 1, capturedAt: 1000.305, samples: Array(repeating: 0.3, count: 480)))
    #expect(source.playoutAdjustmentCount == 0, "A healthy pause must not move the following syllable")
    #expect(bus.snapshot().sources.first?.lastPlayoutAdjustment == nil)
    #expect(abs(source.bufferedDuration - 0.035) < 1 / 48000.0)
    for _ in 0..<30 { #expect(try engine.renderOffline(4800, to: output) == .success) }
    try source.schedule(.init(sequenceNumber: 2, capturedAt: 1003.38, samples: Array(repeating: 0.4, count: 480)))
    #expect(source.playoutAdjustmentCount == 1, "Excess wait must still be removed after a pause")
    let adjustment = try #require(bus.snapshot().sources.first?.lastPlayoutAdjustment)
    #expect(adjustment.reason == .excessDelayAfterPause)
    let previousSample = try #require(adjustment.previousSample)
    #expect(adjustment.scheduledSample < previousSample)
    #expect(source.bufferedDuration <= 0.031)
    #expect(source.playbackResetCount == 0)
}

@Test(arguments: [0, 1])
func omittedSilenceComparesExcessWaitInWholeSamples(extraSamples: Int) throws {
    let rate = 48_000.0
    let quantum = 512
    let captureOrigin = 2_000_000.0
    let mixer = try AudioMixer(audioFormat: .init())
    try mixer.engine.enableManualRenderingMode(.offline, format: mixer.format,
        maximumFrameCount: AVAudioFrameCount(quantum))
    let bus = try mixer.createBus("omitted-silence-boundary")
    let source = try bus.addPCMSource(id: "peer", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: Double(quantum) / rate, adaptivePlayout: true)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }

    let output = try #require(AVAudioPCMBuffer(pcmFormat: mixer.format, frameCapacity: AVAudioFrameCount(quantum)))
    var rendered: [Float] = []
    func renderBlock() throws {
        try #require(mixer.engine.renderOffline(AVAudioFrameCount(quantum), to: output) == .success)
        rendered += UnsafeBufferPointer(start: try #require(output.floatChannelData)[0], count: Int(output.frameLength))
    }

    try source.schedule(.init(sequenceNumber: 0, capturedAt: captureOrigin,
        samples: Array(repeating: 0.2, count: quantum)), arrivedAt: 100.012)
    Thread.sleep(forTimeInterval: 0.002)
    for _ in 0..<50 { try renderBlock() }
    let renderTime = try #require(source.playerNode.lastRenderTime)
    let played = try #require(source.playerNode.playerTime(forNodeTime: renderTime))
    let intendedSample = Int(played.sampleTime) + quantum + extraSamples
    // A remote monotonic clock at this uptime cannot represent the exact
    // sample interval. Make the negligible residue positive at the boundary.
    let returningCaptureTime = (captureOrigin + Double(intendedSample) / rate).nextUp
    let target = (returningCaptureTime - captureOrigin) * rate
    #expect(target > Double(intendedSample))
    #expect(target.rounded() == Double(intendedSample))

    try source.schedule(.init(sequenceNumber: 1, capturedAt: returningCaptureTime,
        samples: Array(repeating: 0.4, count: quantum)), arrivedAt: 100.014 + Double(intendedSample) / rate)
    Thread.sleep(forTimeInterval: 0.002)
    for _ in 0..<4 { try renderBlock() }
    let first = try #require(rendered.firstIndex { abs($0 - 0.2) < 0.00001 })
    let reply = try #require(rendered.firstIndex { abs($0 - 0.4) < 0.00001 })
    #expect(rendered.filter { abs($0 - 0.4) < 0.00001 }.count == quantum)
    #expect(source.playbackResetCount == 0)
    let snapshot = try #require(bus.snapshot().sources.first)
    try checkLegacySnapshot(snapshot, expectedAdjustments: extraSamples)
    if extraSamples == 0 {
        #expect(source.playoutAdjustmentCount == 0)
        #expect(reply - first == intendedSample)
    } else {
        #expect(source.playoutAdjustmentCount == 1)
        #expect(reply - first < intendedSample)
    }
}

@Test(arguments: [0, 21, 33, 50])
func recoveringExcessWaitInSilencePreservesTheSamplesOnBothSides(transitImprovementMilliseconds: Int) throws {
    let mixer = try AudioMixer(audioFormat: .init())
    let bus = try mixer.createBus("recovering-pause")
    let source = try bus.addPCMSource(id: "voice", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
    try mixer.routeToOutput(bus)
    try mixer.engine.enableManualRenderingMode(.offline, format: mixer.format, maximumFrameCount: 48)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    let output = try #require(AVAudioPCMBuffer(pcmFormat: mixer.format, frameCapacity: 48))
    let firstPhrasePackets = 25
    let firstReturningPacket = 70
    let packets = (Array(0..<49) + Array(firstReturningPacket..<95)).map { packet in
        let isVoiced = packet < firstPhrasePackets || packet >= firstReturningPacket
        let samples = (0..<480).map { sample in
            isVoiced ? 0.1 + Float(packet * 480 + sample) * 0.00001 : 0
        }
        let arrival = packet * 10 + 13
        // Transit improves during silence. Packets already in flight are
        // delivered in order as one burst when they catch up to packet 30.
        let oldTransit = transitImprovementMilliseconds
        let arrivalMilliseconds = packet < 31 ? arrival + oldTransit : max(313 + oldTransit, arrival)
        let frame = PCMFrame(sequenceNumber: UInt64(packet), capturedAt: Double(packet) / 100, samples: samples)
        return (arrival: arrivalMilliseconds, frame: frame, isVoiced: isVoiced)
    }
    var next = 0
    var rendered: [Float] = []
    for millisecond in 0..<1100 {
        let firstPending = next
        while next < packets.count, packets[next].arrival <= millisecond {
            let packet = packets[next]
            try source.schedule(packet.frame, arrivedAt: Double(packet.arrival) / 1000)
            next += 1
        }
        if next != firstPending { Thread.sleep(forTimeInterval: 0.002) }
        try #require(mixer.engine.renderOffline(48, to: output) == .success)
        rendered += UnsafeBufferPointer(start: try #require(output.floatChannelData)[0], count: 48)
    }
    let expected = packets.filter { $0.isVoiced }.flatMap { $0.frame.samples }
    let voiced = rendered.filter { $0 > 0.00001 }
    #expect(voiced.count == expected.count)
    #expect(zip(voiced, expected).allSatisfy { abs($0 - $1) < 0.00001 })
    let returningAmplitude = expected[firstPhrasePackets * 480]
    let returningSpeech = try #require(rendered.firstIndex { $0 >= returningAmplitude - 0.00001 })
    let precedingSpeech = try #require(rendered[..<returningSpeech].lastIndex { $0 > 0.00001 })
    let pauseSamples = (450 - transitImprovementMilliseconds) * 48
    #expect(abs(returningSpeech - precedingSpeech - 1 - pauseSamples) <= 1)
    #expect((source.playoutAdjustmentCount > 0) == (transitImprovementMilliseconds > 0))
    #expect(source.playbackResetCount == 0)
}

@Test func captureTimePlayoutPreservesOmittedSilenceAndBurstTiming() throws {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 7680)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("network")
    let source = try bus.addPCMSource(id: "received", maximumBufferedDuration: 0.2, captureTimePlayoutDelay: 0.04)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    // Both packets arrive together. Their capture clock has an arbitrary epoch
    // and an 80 ms pause between them; arrival order alone cannot preserve it.
    var reservations: [MixerPlayoutReservation] = []
    try source.schedule(.init(sequenceNumber: 0, format: .init(), capturedAt: 9000,
                              samples: Array(repeating: 0.2, count: 960)), onReservation: { reservations.append($0) })
    try source.schedule(.init(sequenceNumber: 1, format: .init(), capturedAt: 9000.1,
                              samples: Array(repeating: 0.4, count: 960)), onReservation: { reservations.append($0) })
    Thread.sleep(forTimeInterval: 0.01)
    let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 7680))
    #expect(try engine.renderOffline(7680, to: output) == .success)
    let samples = try #require(output.floatChannelData)[0]
    #expect((0..<1920).allSatisfy { abs(samples[$0]) < 0.001 })
    #expect((1920..<2880).allSatisfy { abs(samples[$0] - 0.2) < 0.001 })
    #expect((2880..<6720).allSatisfy { abs(samples[$0]) < 0.001 })
    #expect((6720..<7680).allSatisfy { abs(samples[$0] - 0.4) < 0.001 })
    #expect(reservations.map(\.capturedAt) == [9000, 9000.1])
    #expect(reservations.map(\.startSample) == [1920, 6720])
    let initialLead = try #require(reservations[0].anchorLead)
    #expect(initialLead.configuredDelay == 0.04)
    #expect(reservations[1].anchorLead == nil)
    #expect(reservations.allSatisfy { $0.frameCount == 960 && $0.sampleRate == 48_000 })
    #expect(reservations.allSatisfy { $0.renderAnchorHostTime == nil && $0.renderAnchorSample == nil })
    #expect(source.playbackResetCount == 0)
}

@Test func captureTimePlayoutRebasesClockJumpsWithinBudget() throws {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("discontinuity")
    let source = try bus.addPCMSource(id: "received", maximumBufferedDuration: 0.2, captureTimePlayoutDelay: 0.04)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    try source.schedule(.init(sequenceNumber: 0, format: .init(), capturedAt: 10,
                              samples: Array(repeating: 0.2, count: 960)))
    try source.schedule(.init(sequenceNumber: 1, format: .init(), capturedAt: 10000,
                              samples: Array(repeating: 0.4, count: 960)))
    #expect(source.bufferedDuration <= 0.06)
    #expect(source.playbackResetCount == 1)
    Thread.sleep(forTimeInterval: 0.01)
    let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
    #expect(try engine.renderOffline(4800, to: output) == .success)
    let samples = try #require(output.floatChannelData)[0]
    #expect((0..<1920).allSatisfy { abs(samples[$0]) < 0.001 })
    #expect((1920..<2880).allSatisfy { abs(samples[$0] - 0.4) < 0.001 })
    #expect((2880..<4800).allSatisfy { abs(samples[$0]) < 0.001 })
    source.stop()
    try source.schedule(.init(sequenceNumber: 0, format: .init(), capturedAt: -10,
                              samples: Array(repeating: 0.3, count: 960)))
    source.start()
    Thread.sleep(forTimeInterval: 0.01)
    #expect(try engine.renderOffline(4800, to: output) == .success)
    #expect((1920..<2880).allSatisfy { abs(samples[$0] - 0.3) < 0.001 })
    #expect(source.playbackResetCount == 1, "stop clears the old capture clock")
}

@Test func captureTimePlayoutRejectsUnboundedConfigurationAndInvalidTimestamp() throws {
    let mixer = AudioMixer()
    let bus = try mixer.createBus("invalid-playout")
    for delay in [Double.nan, .infinity, -0.1, 0.2] {
        #expect(throws: (any Error).self) {
            try bus.addPCMSource(id: "invalid", maximumBufferedDuration: 0.2, captureTimePlayoutDelay: delay)
        }
    }
    #expect(throws: (any Error).self) { try bus.addPCMSource(id: "unbounded", captureTimePlayoutDelay: 0.1) }
    let source = try bus.addPCMSource(id: "valid", maximumBufferedDuration: 0.2, captureTimePlayoutDelay: 0.1)
    #expect(throws: (any Error).self) {
        try source.schedule(.init(sequenceNumber: 0, format: .init(), capturedAt: .nan, samples: [0]))
    }
}

@Test func latePacketDoesNotShiftTheFollowingSpeech() throws {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("late-packet")
    let source = try bus.addPCMSource(id: "received", maximumBufferedDuration: 0.2, captureTimePlayoutDelay: 0.04)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    try source.schedule(
        .init(sequenceNumber: 0, format: .init(), capturedAt: 10, samples: Array(repeating: 0.1, count: 960)))
    Thread.sleep(forTimeInterval: 0.01)
    let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
    #expect(try engine.renderOffline(3360, to: output) == .success) // 70 ms
    // Packet 1 belongs at 60 ms: its first half is already late. Packet 2 must
    // still play at 80 ms, without shifting the entire stream by another delay.
    try source.schedule(.init(sequenceNumber: 1, format: .init(), capturedAt: 10.02,
        samples: Array(repeating: 0.2, count: 480) + Array(repeating: 0.4, count: 480)))
    try source.schedule(
        .init(sequenceNumber: 2, format: .init(), capturedAt: 10.04, samples: Array(repeating: 0.6, count: 960)))
    Thread.sleep(forTimeInterval: 0.01)
    #expect(try engine.renderOffline(1920, to: output) == .success)
    let samples = try #require(output.floatChannelData)[0]
    #expect((0..<480).allSatisfy { abs(samples[$0] - 0.4) < 0.001 })
    #expect((480..<1440).allSatisfy { abs(samples[$0] - 0.6) < 0.001 })
    #expect((1440..<1920).allSatisfy { abs(samples[$0]) < 0.001 })
    #expect(source.playbackResetCount == 0)
}

@Test func expiredPacketDoesNotReplayOrDelayFreshSpeech() throws {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("expired-packet")
    let source = try bus.addPCMSource(id: "received", maximumBufferedDuration: 0.2, captureTimePlayoutDelay: 0.04)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    try source.schedule(
        .init(sequenceNumber: 0, format: .init(), capturedAt: 10, samples: Array(repeating: 0.1, count: 960)))
    Thread.sleep(forTimeInterval: 0.01)
    let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
    #expect(try engine.renderOffline(4800, to: output) == .success)
    try source.schedule(
        .init(sequenceNumber: 1, format: .init(), capturedAt: 10.02, samples: Array(repeating: 0.2, count: 960)))
    try source.schedule(
        .init(sequenceNumber: 2, format: .init(), capturedAt: 10.06, samples: Array(repeating: 0.6, count: 960)))
    Thread.sleep(forTimeInterval: 0.01)
    #expect(try engine.renderOffline(1920, to: output) == .success)
    let samples = try #require(output.floatChannelData)[0]
    #expect((0..<960).allSatisfy { abs(samples[$0] - 0.6) < 0.001 })
    #expect((960..<1920).allSatisfy { abs(samples[$0]) < 0.001 })
    #expect(source.playbackResetCount == 0)
}

@Test func captureClockStartsWhenTheFirstAudioIsScheduled() throws {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("deferred-clock")
    let source = try bus.addPCMSource(id: "input", maximumBufferedDuration: 0.2, captureTimePlayoutDelay: 0.04)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    #expect(!source.playerNode.isPlaying, "Do not establish a player epoch before the first capture timestamp")
    let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
    #expect(try engine.renderOffline(4800, to: output) == .success)
    try source.schedule(.init(sequenceNumber: 0, format: .init(), capturedAt: 100,
        samples: Array(repeating: 0.3, count: 960)))
    #expect(source.playerNode.isPlaying)
    source.start() // Repeated start must not restart the clock.
    Thread.sleep(forTimeInterval: 0.01)
    #expect(try engine.renderOffline(4800, to: output) == .success)
    let channel = try #require(output.floatChannelData)[0]
    #expect((0..<1920).allSatisfy { abs(channel[$0]) < 0.001 })
    #expect((1920..<2880).allSatisfy { abs(channel[$0] - 0.3) < 0.001 })
    #expect(source.playbackResetCount == 0)
    source.stop(); source.start()
    #expect(!source.playerNode.isPlaying, "Restart waits for a new capture clock")
}

@Test func adaptivePlayoutRecoversDuringQuietCodecTailWithoutTrimmingSpeech() throws {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("quiet-recovery")
    let source = try bus.addPCMSource(id: "peer", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
    // A network burst contains a quiet native-codec tail, not absolute zeros.
    var quiet = [Float](repeating: 0.00001, count: 480)
    quiet[0] = 0.0004
    for index in 0..<8 {
        try source.schedule(.init(sequenceNumber: UInt64(index), capturedAt: Double(index) * 0.01, samples: quiet))
    }
    #expect(try engine.renderOffline(480, to: output) == .success)
    try source.schedule(.init(sequenceNumber: 8, capturedAt: 0.08, samples: quiet))
    #expect(source.bufferedDuration <= 0.021, "Only inaudible queued tails may be replaced to recover low latency")
    let latest = try #require(source.lastPlayoutAdjustment)
    #expect(latest.reason == .excessQueuedSilence)
    let previousSample = try #require(latest.previousSample)
    #expect(latest.scheduledSample < previousSample)
    // Real quiet speech must still follow the queued voice, never interrupt it.
    let before = source.playoutAdjustmentCount
    for index in 9..<13 {
        try source.schedule(.init(sequenceNumber: UInt64(index), capturedAt: Double(index) * 0.01,
            samples: Array(repeating: 0.002, count: 480)))
    }
    #expect(source.playoutAdjustmentCount == before)
    #expect(bus.snapshot().sources.first?.lastPlayoutAdjustment == latest)
    #expect(source.bufferedDuration >= 0.04)
    #expect(source.playbackResetCount == 0)
}

@Test func omittedSilenceAtTheExactRenderSampleIsNotExpiredByFloatingPointRounding() throws {
    let mixer = try AudioMixer(audioFormat: .init())
    let bus = try mixer.createBus("exact-pause-boundary")
    let source = try bus.addPCMSource(id: "voice", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
    try mixer.routeToOutput(bus)
    try mixer.engine.enableManualRenderingMode(.offline, format: mixer.format, maximumFrameCount: 14496)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    try source.schedule(.init(sequenceNumber: 0, capturedAt: 100, samples: Array(repeating: 0.1, count: 480)))
    let output = try #require(AVAudioPCMBuffer(pcmFormat: mixer.format, frameCapacity: 14496))
    #expect(try mixer.engine.renderOffline(14496, to: output) == .success)
    // (100.3 - 100) * 48000 is slightly below 14400 in binary floating
    // point. Native scheduling rounds to a sample, so expiry must do so too.
    try source.schedule(.init(sequenceNumber: 1, capturedAt: 100.3, samples: Array(repeating: 0.2, count: 480)))
    #expect(source.playoutAdjustmentCount == 0)
    Thread.sleep(forTimeInterval: 0.01) // Drain the native command queue before advancing the offline clock.
    #expect(try mixer.engine.renderOffline(480, to: output) == .success)
    let channel = try #require(output.floatChannelData)[0]
    #expect((0..<480).allSatisfy { abs(channel[$0] - 0.2) < 0.00001 })
}

private func checkLegacySnapshot(_ snapshot: MixerSourceSnapshot, expectedAdjustments: Int) throws {
    let data = try JSONEncoder().encode(snapshot)
    var fields = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(fields.removeValue(forKey: "playoutAdjustmentCount") as? Int == expectedAdjustments)
    #expect((fields.removeValue(forKey: "lastPlayoutAdjustment") != nil) == (expectedAdjustments > 0))
    let legacy = try JSONSerialization.data(withJSONObject: fields)
    let decoded = try JSONDecoder().decode(MixerSourceSnapshot.self, from: legacy)
    #expect(decoded.playoutAdjustmentCount == nil)
    #expect(decoded.lastPlayoutAdjustment == nil)
    #expect(decoded.id == snapshot.id)
}
