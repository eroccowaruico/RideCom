import AudioCore
import AVFAudio
import Foundation
import Testing
@testable import AudioMixer

@Test func latePacketLearnsOnlyTheWaitAfterTheSendQueueWhenPreparationGrows() throws {
    struct Expectation {
        let age: TimeInterval?
        let learned: ClosedRange<Int>
        let start: ClosedRange<Int64>
    }
    let cases = [Expectation(age: nil, learned: 1_440...1_440, start: 2_464...2_465),
        .init(age: 0.121, learned: 1_440...1_440, start: 2_464...2_465),
        .init(age: 0.014, learned: 1_440...1_440, start: 2_464...2_465),
        .init(age: 0.019, learned: 1_200...1_201, start: 2_224...2_226),
        .init(age: 0.024, learned: 0...0, start: 1_984...1_984)]
    for test in cases {
        let playout = MixerPCMPlayout(mixerFormat: .init(), adaptivePlayout: true)
        let first = playout.captureTimeReservation(.init(capturedAt: 0, arrivedAt: 0.015,
            frameLength: 480, duration: 0.01, audible: true, position: (0, 512), nativeLead: 96,
            delay: 0.002, limit: 0.12, packetizationJitter: 0, captureToSendQueue: 0.014))
        playout.recordScheduled(first, frameLength: 480, audible: true)
        let late = playout.captureTimeReservation(.init(capturedAt: 0.01, arrivedAt: 0.035,
            frameLength: 480, duration: 0.01, audible: true, position: (1280, 1792), nativeLead: 96,
            delay: 0.002, limit: 0.12, packetizationJitter: 0, captureToSendQueue: test.age), observesAnchor: true)
        let lead = try #require(late.anchorLead)
        #expect(playout.lastPlayoutAdjustment?.reason == .pastRenderPosition)
        #expect(test.start.contains(late.startSample))
        #expect(test.learned.contains(Int(lead.retainedJitterFramesAfter)), "Send queue age: \(test.age as Any)")
    }
}

@Test func adaptivePlayoutRetainsLatePacketsAndReleasesTheLearnedWaitAfterCalm() throws {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 4800)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("adaptive")
    let source = try bus.addPCMSource(id: "peer", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.02, adaptivePlayout: true)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4800))
    try source.schedule(
        .init(sequenceNumber: 0, capturedAt: 1000, samples: Array(repeating: 0.2, count: 960)), arrivedAt: 50)
    Thread.sleep(forTimeInterval: 0.01)
    #expect(try engine.renderOffline(2400, to: output) == .success) // 50 ms
    let channel = try #require(output.floatChannelData)[0]
    #expect((0..<960).allSatisfy { abs(channel[$0]) < 0.001 })
    #expect((960..<1920).allSatisfy { abs(channel[$0] - 0.2) < 0.001 })
    // A late packet must retain its whole 20 ms rather than lose its end.
    try source.schedule(
        .init(sequenceNumber: 1, capturedAt: 1000.02, samples: Array(repeating: 0.4, count: 960)), arrivedAt: 50.05
    )
    Thread.sleep(forTimeInterval: 0.01)
    var late: [Float] = []
    for _ in 0..<2 {
        #expect(try engine.renderOffline(2400, to: output) == .success)
        late += UnsafeBufferPointer(start: try #require(output.floatChannelData)[0], count: 2400)
    }
    #expect(late.filter { abs($0 - 0.4) < 0.001 }.count == 960)
    #expect(source.playoutAdjustmentCount == 1)
    let adjustment = try #require(bus.snapshot().sources.first?.lastPlayoutAdjustment)
    #expect(adjustment.reason == .pastRenderPosition)
    #expect(adjustment.capturedAt == 1000.02)
    let previousSample = try #require(adjustment.previousSample)
    #expect(previousSample < adjustment.completedSample)
    #expect(adjustment.scheduledSample >= adjustment.completedSample)
    // The link has proven it can hold a packet: a reply after a short pause
    // keeps that wait instead of losing its first syllables again.
    for index in 0..<30 { #expect(try engine.renderOffline(4800, to: output) == .success, "silence \(index)") }
    try source.schedule(
        .init(sequenceNumber: 2, capturedAt: 1003.15, samples: Array(repeating: 0.3, count: 960)), arrivedAt: 53.15
    )
    #expect(source.bufferedDuration > 0.041, "The learned wait survives a 3 s pause")
    // After the link stays calm, the wait is released for a low-delay reply.
    for _ in 0..<10 { #expect(try engine.renderOffline(4800, to: output) == .success) }
    for index in 0..<130 { #expect(try engine.renderOffline(4800, to: output) == .success, "calm \(index)") }
    for _ in 0..<60 { #expect(try engine.renderOffline(4800, to: output) == .success) }
    try source.schedule(
        .init(sequenceNumber: 3, capturedAt: 1023.15, samples: Array(repeating: 0.3, count: 960)), arrivedAt: 73.15
    )
    #expect(source.bufferedDuration <= 0.041)
    #expect(source.playbackResetCount == 0, "Natural conversation pauses are not corrupt clocks")
}

@Test(arguments: [false, true])
func newSenderTimingPreservesOnlyPreviouslyLearnedLinkJitter(priorJitter: Bool) throws {
    let mixer = try AudioMixer(audioFormat: .init())
    let bus = try mixer.createBus("sender-timing")
    let source = try bus.addPCMSource(id: "voice", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
    _ = source.captureTimeReservation(.init(capturedAt: 0, arrivedAt: 0.015625, frameLength: 480,
        duration: 0.01, audible: true, position: (0, 0), nativeLead: 0,
        delay: 0.002, limit: 0.12, packetizationJitter: 0))
    if priorJitter {
        _ = source.captureTimeReservation(.init(capturedAt: 0.03125, arrivedAt: 0.0625, frameLength: 480,
            duration: 0.01, audible: true, position: (1800, 1800), nativeLead: 0,
            delay: 0.002, limit: 0.12, packetizationJitter: 0))
    }

    // A new 30 ms packet cadence can put the first packet past its old target.
    let first = source.captureTimeReservation(.init(capturedAt: 0.1, arrivedAt: 0.14, frameLength: 1440,
        duration: 0.03, audible: true, position: (7200, 7200), nativeLead: 0,
        delay: 0.002, limit: 0.12, packetizationJitter: 0, startsNewArrivalTiming: true))
    #expect(first.startSample == 7200 + 96 + (priorJitter ? 1710 : 0))
    #expect(source.lastPlayoutAdjustment?.reason == .pastRenderPosition)
    #expect(source.playbackResetCount == 0)

    // A later packet 25 ms behind the new baseline still trains the link wait.
    _ = source.captureTimeReservation(.init(capturedAt: 0.14, arrivedAt: 0.205, frameLength: 1440,
        duration: 0.03, audible: true, position: (12000, 12000), nativeLead: 0,
        delay: 0.002, limit: 0.12, packetizationJitter: 0))
    source.stop()
    let afterOutputRestart = source.captureTimeReservation(.init(capturedAt: 0.18, arrivedAt: 0.22, frameLength: 1440,
        duration: 0.03, audible: true, position: (0, 0), nativeLead: 0,
        delay: 0.002, limit: 0.12, packetizationJitter: 0))
    #expect(afterOutputRestart.startSample == 96 + 2832)
}

/// Peer-to-peer and infrastructure Wi-Fi hold packets for tens of milliseconds
/// and release them in a burst, repeatedly. Replays the arrival schedule against
/// the 10 ms render clock and returns the gaps (silent runs shorter than a pause)
/// inside rendered speech, with the rendered time at which each gap ended.
private func renderedSpeechGaps(utterances: Int, stallEvery: Double, stall: Double,
                                pause: Double = 0.4, utterance: Double = 1.5,
                                window: TimeInterval = 0.3) throws -> [(samples: Int, endedAt: Double)] {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 480)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("radio")
    let source = try bus.addPCMSource(id: "peer", maximumBufferedDuration: window,
        captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    // Speech packets, then 100 ms of exact silence before the sender suppresses it.
    var packets: [(capturedAt: Double, speech: Bool)] = []
    var clock = 0.0
    for _ in 0..<utterances {
        for _ in 0..<Int((utterance / 0.01).rounded()) { packets.append((clock, true)); clock += 0.01 }
        for _ in 0..<10 { packets.append((clock, false)); clock += 0.01 }
        clock += pause - 0.1
    }
    func arrival(_ capturedAt: Double) -> Double {
        let sent = capturedAt + 0.01 + 0.003
        let phase = sent.truncatingRemainder(dividingBy: stallEvery)
        return phase < stall ? sent - phase + stall : sent
    }
    let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
    var rendered: [Float] = []
    var next = 0, now = 0.0, scheduled = false
    while now < clock + 0.3 {
        while next < packets.count, arrival(packets[next].capturedAt) <= now {
            let packet = packets[next]
            try source.schedule(.init(sequenceNumber: UInt64(next), capturedAt: 1000 + packet.capturedAt,
                samples: Array(repeating: packet.speech ? 0.3 : 0, count: 480)), arrivedAt: now)
            next += 1
            scheduled = true
        }
        // The player applies schedules asynchronously, as in the tests above.
        if scheduled { Thread.sleep(forTimeInterval: 0.002); scheduled = false }
        #expect(try engine.renderOffline(480, to: output) == .success)
        rendered += UnsafeBufferPointer(start: try #require(output.floatChannelData)[0], count: 480)
        now += 0.01
    }
    var gaps: [(samples: Int, endedAt: Double)] = [], run = 0, heard = false
    for (index, sample) in rendered.enumerated() {
        if abs(sample) > 0.1 {
            if heard && run > 0 && run < 9600 { gaps.append((run, Double(index) / 48000)) }
            run = 0; heard = true
        } else if heard { run += 1 }
    }
    return gaps
}

@Test func recurringRadioStallsAreLearnedOnceAndSurviveConversationPauses() throws {
    let gaps = try renderedSpeechGaps(utterances: 4, stallEvery: 0.5, stall: 0.06)
    // A reactive wait can only learn a stall by meeting it. Learning belongs to
    // the first utterance; every reply after a pause must keep what was learned.
    #expect(gaps.allSatisfy { $0.endedAt < 1.5 + 0.2 },
            "Gaps after a conversation pause (samples, rendered s): \(gaps)")
    #expect(gaps.count <= 2)
}

@Test func steadyLinkNeedsNoLearnedWait() throws {
    let gaps = try renderedSpeechGaps(utterances: 4, stallEvery: 0.5, stall: 0)
    #expect(gaps.isEmpty, "A link without jitter keeps every utterance contiguous: \(gaps)")
}

@Test(arguments: [false, true])
func regularHundredMillisecondBurstsKeepTheirTailInsideTheCallWindow(withPauses: Bool) throws {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 48)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("burst-receive")
    let source = try bus.addPCMSource(id: "peer", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48))
    let speech = Array(repeating: Float(0.25), count: 480)
    let silence = Array(repeating: Float(0), count: 480)
    var batch = 0
    var recorded: [Float] = []
    let arrival = [0, 7, 1, 4]
    for millisecond in 0..<3200 {
        if millisecond == (batch + 1) * 100 + arrival[batch % arrival.count] {
            for offset in 0..<10 {
                let packet = batch * 10 + offset
                let audible = !withPauses || (batch % 2 == 1 && offset >= 7)
                try source.schedule(.init(sequenceNumber: UInt64(packet), capturedAt: Double(packet) / 100,
                    samples: audible ? speech : silence),
                    arrivedAt: Double(millisecond) / 1000)
            }
            batch += 1
            // Allow the player to consume scheduled commands before advancing
            // the offline device clock, as in the other scheduling tests.
            Thread.sleep(forTimeInterval: 0.002)
        }
        try #require(try engine.renderOffline(48, to: output) == .success)
        if millisecond >= 1200 {
            let samples = try #require(output.floatChannelData)[0]
            recorded.append(contentsOf: UnsafeBufferPointer(start: samples, count: 48))
        }
    }
    let firstVoice = try #require(recorded.firstIndex { $0 > 0.2 })
    #expect(firstVoice < 9_600)
    let lossSamples = recorded.indices.dropFirst(firstVoice).filter { index in
        let audible = !withPauses || (index - firstVoice) % 9_600 < 1_440
        return abs(recorded[index] - (audible ? 0.25 : 0)) > 0.001
    }.count
    #expect(lossSamples == 0, "A learned wait must not cut off the rest of a steady 100 ms burst")
    #expect(source.playbackResetCount == 0)
}

@Test func localRenderJumpWithCalmArrivalsLearnsNoLinkWait() throws {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 9600)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("local-jump")
    let source = try bus.addPCMSource(id: "peer", maximumBufferedDuration: 0.3,
        captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 9600))
    for index in 0..<40 {
        // Every packet arrives 13 ms after capture: the link is calm.
        try source.schedule(.init(sequenceNumber: UInt64(index), capturedAt: 1000 + Double(index) * 0.01,
            samples: Array(repeating: 0.3, count: 480)), arrivedAt: 50 + Double(index) * 0.01 + 0.013)
        Thread.sleep(forTimeInterval: 0.002)
        // An output restart makes the local clock jump 100 ms once.
        #expect(try engine.renderOffline(index == 20 ? 5280 : 480, to: output) == .success)
    }
    #expect(source.playoutAdjustmentCount >= 1, "The local jump expires queued speech")
    #expect(source.bufferedDuration <= 0.035, "A local render event is not link jitter: \(source.bufferedDuration)")
}

@Test func backlogBeyondThePlayoutWindowIsNotLearnedAsJitter() throws {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 480)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("backlog")
    let source = try bus.addPCMSource(id: "peer", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
    // Ten calm packets, then 500 ms without arrivals (a start-up backlog or a
    // local outage), then the twenty held packets at once.
    var local = 0.0
    func schedule(_ index: Int, arrived: Double) throws {
        try source.schedule(.init(sequenceNumber: UInt64(index), capturedAt: 1000 + Double(index) * 0.01,
            samples: Array(repeating: 0.3, count: 480)), arrivedAt: 50 + arrived)
    }
    for index in 0..<10 {
        try schedule(index, arrived: local + 0.013)
        Thread.sleep(forTimeInterval: 0.002)
        #expect(try engine.renderOffline(480, to: output) == .success); local += 0.01
    }
    for _ in 0..<50 { #expect(try engine.renderOffline(480, to: output) == .success); local += 0.01 }
    for index in 10..<30 { try schedule(index, arrived: local) }
    Thread.sleep(forTimeInterval: 0.002)
    #expect(try engine.renderOffline(480, to: output) == .success); local += 0.01
    // The sender pauses: quiet packets may release the queued backlog, but only
    // down to whatever wait was learned.
    for index in 30..<80 {
        try source.schedule(.init(sequenceNumber: UInt64(index), capturedAt: 1000 + Double(index) * 0.01,
            samples: Array(repeating: 0, count: 480)), arrivedAt: 50 + local)
        Thread.sleep(forTimeInterval: 0.002)
        #expect(try engine.renderOffline(480, to: output) == .success); local += 0.01
    }
    #expect(
        source.bufferedDuration <= 0.035,
        "A delay the window cannot absorb is not link jitter: \(source.bufferedDuration)")
}

@Test func localOutputRestartKeepsTheLearnedLinkWait() throws {
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 480)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("restart")
    let source = try bus.addPCMSource(id: "peer", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }
    let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
    func packet(_ index: Int, arrived: Double) throws {
        try source.schedule(.init(sequenceNumber: UInt64(index), capturedAt: 1000 + Double(index) * 0.01,
            samples: Array(repeating: 0.3, count: 480)), arrivedAt: 50 + arrived)
        Thread.sleep(forTimeInterval: 0.002)
        #expect(try engine.renderOffline(480, to: output) == .success)
    }
    for index in 0..<10 { try packet(index, arrived: Double(index) * 0.01 + 0.013) }
    // One packet held 40 ms longer: the link has jitter.
    #expect(try engine.renderOffline(480, to: output) == .success)
    #expect(try engine.renderOffline(480, to: output) == .success)
    #expect(try engine.renderOffline(480, to: output) == .success)
    try packet(10, arrived: 0.1 + 0.053)
    // An output route change restarts the local player, not the link.
    source.stop(); source.start()
    try packet(11, arrived: 0.11 + 0.093)
    #expect(source.bufferedDuration >= 0.059, "The new playback anchor keeps the learned 59 ms margin")
}

@Test(arguments: [14, 24, 60])
func releasingAnUnexpectedBurstPreservesItsQueuedSpeech(extraDelay: Int) throws {
    let rate = 48_000
    let packetCount = 80
    let delayedIndex = 40
    let framesPerPacket = 480
    let framesPerStep: AVAudioFrameCount = 48
    let speech = (0..<packetCount).map { Float(0.25) + Float($0) / 400 }
    let engine = AVAudioEngine()
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: Double(rate), channels: 1))
    try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: framesPerStep)
    let mixer = try AudioMixer(engine: engine, audioFormat: .init())
    let bus = try mixer.createBus("controlled-arrival")
    let source = try bus.addPCMSource(id: "peer", maximumBufferedDuration: 0.12,
        captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
    try mixer.routeToOutput(bus)
    try mixer.start(); source.start()
    defer { mixer.stop() }

    let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: framesPerStep))
    var rendered: [Float] = []
    var next = 0
    var maximumBufferedDuration = 0.0
    for now in 0..<1100 {
        let previous = next
        while next < packetCount {
            let sent = (next + 1) * 10
            let release = (delayedIndex + 1) * 10 + extraDelay
            let arrival = next < delayedIndex ? sent : max(release, sent)
            guard arrival <= now else { break }
            try source.schedule(.init(sequenceNumber: UInt64(next), capturedAt: Double(next) / 100,
                samples: Array(repeating: speech[next], count: framesPerPacket)), arrivedAt: Double(arrival) / 1000)
            maximumBufferedDuration = max(maximumBufferedDuration, source.bufferedDuration)
            next += 1
        }
        if next > previous { Thread.sleep(forTimeInterval: 0.002) }
        try #require(engine.renderOffline(framesPerStep, to: output) == .success)
        rendered += UnsafeBufferPointer(start: try #require(output.floatChannelData)[0], count: Int(framesPerStep))
    }
    // The missed deadline can insert silence, but the newly queued burst
    // must play each packet once and need not reset to stay inside the window.
    let renderedSpeech = rendered.filter { $0 > 0.1 }
    let expected = speech.flatMap { Array(repeating: $0, count: framesPerPacket) }
    let first = try #require(rendered.firstIndex { $0 > 0.1 })
    let last = try #require(rendered.lastIndex { $0 > 0.1 })
    let silence = last - first + 1 - renderedSpeech.count
    // The observed delay has already elapsed. In this 10 ms packet fixture,
    // allow two packets of headroom and the 2 ms initial scheduling allowance.
    #expect(silence <= (extraDelay + 22) * Int(framesPerStep))
    #expect(renderedSpeech.count == expected.count)
    #expect(zip(renderedSpeech, expected).allSatisfy { abs($0 - $1) < 0.00001 })
    #expect(maximumBufferedDuration <= 0.13) // Start within 120 ms, plus one 10 ms packet.
    #expect(source.playbackResetCount == 0)
}
