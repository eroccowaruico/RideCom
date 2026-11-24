import AudioCore
@preconcurrency import AVFAudio
import Foundation
import XCTest
@testable import AudioMixer

private struct PlaybackProbe {
    let mixer: AudioMixer
    let source: MixerPCMSource
    let received: QuantumFrames

    init(busID: String, sourceID: String) throws {
        mixer = try AudioMixer(audioFormat: .init())
        let bus = try mixer.createBus(busID)
        source = try bus.addPCMSource(id: sourceID, maximumBufferedDuration: 0.12,
                                      captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
        let frames = QuantumFrames()
        received = frames
        _ = try bus.installPCMSink(id: "probe", targetFormat: .init()) { frame, _ in frames.append(frame) }
        let muted = try mixer.createBus("muted")
        muted.volume = 0
        try mixer.route(bus, to: muted)
        try mixer.routeToOutput(muted)
    }
}

// Hardware-clock checks run in XCTest's serial phase, separately from the
// parallel offline graph tests that create and destroy many native Audio Units.
final class RealtimeRenderBoundaryTests: XCTestCase {
    func testPausedAndStoppedPlayersPreserveTheirPlaybackBoundaries() throws {
        let mixer = try AudioMixer(audioFormat: .init())
        let bus = try mixer.createBus("player-lifecycle")
        let source = try bus.addPCMSource(id: "voice", maximumBufferedDuration: 0.12,
            captureTimePlayoutDelay: 0.002, adaptivePlayout: true)
        try mixer.routeToOutput(bus)
        try mixer.engine.enableManualRenderingMode(.offline, format: mixer.format, maximumFrameCount: 480)
        try mixer.start()
        defer { mixer.stop() }
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: mixer.format, frameCapacity: 480))

        func render() throws -> [Float] {
            XCTAssertEqual(try mixer.engine.renderOffline(480, to: output), .success)
            let samples = try XCTUnwrap(output.floatChannelData)[0]
            return Array(UnsafeBufferPointer(start: samples, count: Int(output.frameLength)))
        }

        try source.schedule(.init(sequenceNumber: 0, capturedAt: 100,
            samples: Array(repeating: 0.2, count: 4_800)))
        let queuedBeforePlayback = source.bufferedDuration
        XCTAssertEqual(queuedBeforePlayback, 0.102, accuracy: 1 / 48_000)
        source.start()
        var played = try render()
        played += try render()
        XCTAssertLessThan(source.bufferedDuration, queuedBeforePlayback)

        source.playerNode.pause()
        XCTAssertTrue(try render().allSatisfy { abs($0) < 0.001 })
        XCTAssertEqual(source.bufferedDuration, queuedBeforePlayback, accuracy: 1 / 48_000)
        source.start()
        for _ in 0..<10 { played += try render() }
        XCTAssertEqual(played.filter { abs($0 - 0.2) < 0.001 }.count, 4_800)

        source.stop()
        XCTAssertEqual(source.bufferedDuration, 0)
        XCTAssertTrue(try render().allSatisfy { abs($0) < 0.001 })
        try source.schedule(.init(sequenceNumber: 1, capturedAt: 101,
            samples: Array(repeating: 0.3, count: 480)))
        XCTAssertTrue(try render().allSatisfy { abs($0) < 0.001 })
        source.start()
        let replayed = try render() + render()
        XCTAssertEqual(replayed.filter { abs($0 - 0.3) < 0.001 }.count, 480)
        XCTAssertEqual(replayed.filter { abs($0 - 0.2) < 0.001 }.count, 0)
    }

    func testAdaptivePlayerPreparesItsClockBeforeTheFirstUtterance() async throws {
        let probe = try PlaybackProbe(busID: "ready-clock", sourceID: "voice")
        try probe.mixer.start(); probe.source.start()
        defer { probe.mixer.stop() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(probe.source.playerNode.isPlaying)
        XCTAssertNotNil(probe.source.playerNode.lastRenderTime)
        XCTAssertTrue(probe.received.snapshot.flatMap(\.samples).allSatisfy { $0 == 0 })
        try probe.source.schedule(.init(sequenceNumber: 0, capturedAt: 100,
            samples: Array(repeating: 0.2, count: 480)))
        XCTAssertLessThanOrEqual(probe.source.bufferedDuration, 0.01425,
            "Native handoff beyond the writable frontier must stay within 2 ms, independent of the device quantum")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(probe.received.snapshot.flatMap(\.samples).filter { $0 > 0.1 }.count, 480,
            "Starting the clock early must not place the first capture timestamp in the past")
    }

    func testFirstPacketDoesNotWaitForAnAlreadyRunningDeviceClock() async throws {
        let probe = try PlaybackProbe(busID: "first-packet", sourceID: "voice")
        try probe.mixer.start()
        defer { probe.mixer.stop() }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(probe.received.snapshot.isEmpty, "The native device must already be rendering")
        try probe.source.schedule(.init(sequenceNumber: 0, capturedAt: 100,
            samples: Array(repeating: 0.2, count: 480)))
        XCTAssertEqual(probe.source.bufferedDuration, 0.012, accuracy: 1 / 48000,
            "A stopped player starts with its prepared first buffer; it needs no asynchronous render handoff allowance")
        probe.source.start()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(probe.received.snapshot.flatMap(\.samples).filter { $0 > 0.1 }.count, 480)
    }

    func testLatePacketAndBurstRenderEverySampleOnTheDeviceClock() async throws {
        let probe = try PlaybackProbe(busID: "late-burst", sourceID: "voice")
        try probe.mixer.start(); probe.source.start()
        defer { probe.mixer.stop() }
        try await Task.sleep(for: .milliseconds(100))

        let packets = (0..<4).map { index in Array(repeating: Float(0.2) + Float(index) * 0.1, count: 480) }
        let firstArrival = 50.013
        let burstArrival = firstArrival + 0.075688
        var reservations: [MixerPlayoutReservation] = []
        try probe.source.schedule(.init(sequenceNumber: 0, capturedAt: 100, samples: packets[0]),
            arrivedAt: firstArrival) { reservations.append($0) }
        // Let the original reservation for packet 1 expire before releasing the
        // adjacent packets together. Only the arrival times supplied to the link
        // estimator are injected; the device decides how far it has rendered.
        try await Task.sleep(for: .milliseconds(76))
        for index in 1..<packets.count {
            try probe.source.schedule(.init(sequenceNumber: UInt64(index), capturedAt: 100 + Double(index) / 100,
                samples: packets[index]), arrivedAt: burstArrival) { reservations.append($0) }
        }
        let adjustment = try XCTUnwrap(probe.source.lastPlayoutAdjustment)
        XCTAssertEqual(adjustment.reason, .pastRenderPosition)
        XCTAssertEqual(probe.source.playoutAdjustmentCount, 1)
        XCTAssertEqual(probe.source.playbackResetCount, 0)
        try await Task.sleep(for: .milliseconds(150))
        let rendered = probe.received.snapshot.flatMap(\.samples)
        let heard = rendered.filter { $0 > 0.1 }
        let expected = packets.flatMap { $0 }
        XCTAssertEqual(heard.count, expected.count)
        XCTAssertTrue(zip(heard, expected).allSatisfy { abs($0 - $1) < 0.00001 })

        XCTAssertEqual(reservations.count, packets.count)
        let first = try XCTUnwrap(reservations.first)
        let late = try XCTUnwrap(reservations.dropFirst().first)
        let firstEnd = first.startSample + AVAudioFramePosition(first.frameCount)
        let expired = late.completedSample - firstEnd
        let renderLead = late.writableSample - late.completedSample
        let afterWritable = late.startSample - late.writableSample
        let lastFirstSample = try XCTUnwrap(rendered.lastIndex { abs($0 - packets[0][0]) < 0.00001 })
        let firstLateSample = try XCTUnwrap(rendered.firstIndex { abs($0 - packets[1][0]) < 0.00001 })
        guard lastFirstSample < firstLateSample else {
            return XCTFail("The late packet must render after the first packet")
        }
        let silentSamples = firstLateSample - lastFirstSample - 1
        XCTAssertGreaterThan(expired, 0, "The first packet must end before the completed render position")
        XCTAssertGreaterThanOrEqual(afterWritable, 0)
        XCTAssertEqual(silentSamples, Int(expired + renderLead + afterWritable))
        XCTAssertTrue(rendered[(lastFirstSample + 1)..<firstLateSample].allSatisfy { abs($0) < 0.00001 })
        print("Late burst samples: expired=\(expired), renderLead=\(renderLead), "
            + "afterWritable=\(afterWritable), silent=\(silentSamples)")
    }

}

// Recovery after delayed or omitted packets.
extension RealtimeRenderBoundaryTests {
    func testDelayedQuietBurstDoesNotCutTheReturningFade() async throws {
        let probe = try PlaybackProbe(busID: "delayed-pause", sourceID: "voice")
        try probe.mixer.start(); probe.source.start()
        defer { probe.mixer.stop() }
        let start = ContinuousClock.now
        var expected: [Float] = []
        let hostStart = ProcessInfo.processInfo.systemUptime
        struct Arrival {
            let index: Int
            let lateness: Double
            let buffered: Double
            let adjustments: Int
        }
        var arrivals: [Arrival] = []
        for index in 0..<1000 {
            // A sender pauses for a native settings change, then delivers the
            // accumulated quiet packets. Speech resumes after that quiet burst.
            let position = index % 50
            let delay = position == 10 ? 50 : 0
            try await Task.sleep(until: start + .milliseconds(index * 10 + delay), clock: .continuous)
            let samples: [Float] = (0..<480).map { sample in
                guard position < 10 || (30..<40).contains(position) else { return 0 }
                if position == 0 || position == 30 { return 0.2 * Float(min(sample, 96)) / 96 }
                if position == 9 || position == 39 { return 0.2 * Float(min(479 - sample, 96)) / 96 }
                return 0.2
            }
            expected.append(contentsOf: samples.filter { $0 > 0 })
            try probe.source.schedule(
                .init(sequenceNumber: UInt64(index), capturedAt: 100 + Double(index) * 0.01, samples: samples))
            arrivals.append(
                Arrival(
                    index: index, lateness: ProcessInfo.processInfo.systemUptime - hostStart - Double(index) / 100,
                    buffered: probe.source.bufferedDuration, adjustments: probe.source.playoutAdjustmentCount))
        }
        try await Task.sleep(for: .milliseconds(150))
        let samples = probe.received.snapshot.flatMap(\.samples)
        let voiced = samples.filter { $0 > 0.00001 }
        XCTAssertEqual(voiced.count, expected.count, "Every fade and voiced sample must survive delayed silence")
        XCTAssertTrue(zip(voiced, expected).allSatisfy { abs($0 - $1) < 0.00001 })
        let gaps = zip(samples, samples.dropFirst()).enumerated().filter { abs($0.element.0 - $0.element.1) >= 0.003 }
        if !gaps.isEmpty {
            let firstRender = (probe.received.snapshot.first?.capturedAt ?? 0) - hostStart
            let moments = gaps.prefix(20).map { Double($0.offset) / 48000 + firstRender }
            let nearby = arrivals.filter { arrival in
                moments.contains { abs(Double(arrival.index) / 100 - $0) < 0.1 }
            }
            print("Native pause arrivals near gaps: \(nearby)")
            print("Native pause first render: \(firstRender)")
        }
        XCTAssertTrue(
            gaps.isEmpty,
            "Unexpected render edges: \(gaps.prefix(20).map { ($0.offset, $0.element.0, $0.element.1) })")
        XCTAssertEqual(probe.source.playbackResetCount, 0)
    }

    func testQuietRecoveryKeepsTheCaptureClockAcrossOmittedSilence() async throws {
        let probe = try PlaybackProbe(busID: "pause-clock", sourceID: "voice")
        try probe.mixer.start(); probe.source.start()
        defer { probe.mixer.stop() }
        let start = ContinuousClock.now
        for index in 0..<50 {
            try await Task.sleep(until: start + .milliseconds(index * 10 + (index == 10 ? 50 : 0)), clock: .continuous)
            try probe.source.schedule(.init(sequenceNumber: UInt64(index), capturedAt: 100 + Double(index) / 100,
                samples: Array(repeating: index >= 30 ? 0.2 : 0, count: 480)))
        }
        let adjustmentsBeforePause = probe.source.playoutAdjustmentCount
        XCTAssertGreaterThan(adjustmentsBeforePause, 0, "The preceding stall must exercise recovery")
        let firstSpeech = try XCTUnwrap(probe.received.snapshot.flatMap(\.samples).firstIndex { $0 > 0.1 })
        let onsetInterval = 57_600 // 1.2 seconds on the 48 kHz capture clock.
        // Deliver the next phrase within the learned wait, 40 ms before its
        // target on the actual output clock. A wall-clock deadline can make it
        // arrive early enough to shorten the pause or late enough to expire.
        let resumeAtFrame = firstSpeech + onsetInterval - 1_920
        let deadline = ContinuousClock.now + .seconds(2)
        while probe.received.snapshot.reduce(0, { $0 + $1.frameCount }) < resumeAtFrame {
            guard ContinuousClock.now < deadline else {
                return XCTFail("The native render clock did not reach the resume point")
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        let resumeAt = ContinuousClock.now
        for index in 150..<170 {
            try await Task.sleep(until: resumeAt + .milliseconds((index - 150) * 10), clock: .continuous)
            try probe.source.schedule(.init(sequenceNumber: UInt64(index), capturedAt: 100 + Double(index) / 100,
                samples: Array(repeating: 0.2, count: 480)))
            if index == 150 {
                XCTAssertEqual(probe.source.playoutAdjustmentCount, adjustmentsBeforePause,
                    "The first packet after omitted silence must use the existing clock")
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        let samples = probe.received.snapshot.flatMap(\.samples)
        let onsets = samples.indices.filter { samples[$0] > 0.1 && ($0 == 0 || samples[$0 - 1] <= 0.1) }
        XCTAssertEqual(onsets.count, 2)
        if onsets.count == 2 {
            XCTAssertEqual(onsets[1] - onsets[0], onsetInterval, accuracy: 2,
                "Quiet recovery must not leave implicit and explicit native reservations on different clocks")
        }
        XCTAssertEqual(samples.filter { $0 > 0.1 }.count, 19200)
        XCTAssertEqual(probe.source.playbackResetCount, 0)
    }

    private func makeSoundIsolationEffect() -> AVAudioUnitEffect {
        let effect = AVAudioUnitEffect(audioComponentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Effect, componentSubType: kAudioUnitSubType_AUSoundIsolation,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        effect.withAUAudioUnit {
            $0.parameterTree?.parameter(withAddress: AUParameterAddress(kAUSoundIsolationParam_WetDryMixPercent))?
                .value = 80
        }
        return effect
    }

    func testLiveEffectInsertionKeepsTimestampedRemoteVoiceAudible() async throws {
        let mixer = try AudioMixer(audioFormat: .init())
        let peer = try mixer.createBus("remote")
        let outputBus = try mixer.createBus("master")
        let source = try peer.addPCMSource(id: "voice", maximumBufferedDuration: 0.12,
            captureTimePlayoutDelay: 0.01, adaptivePlayout: true)
        let effect = makeSoundIsolationEffect()
        effect.bypass = true
        try outputBus.addEffect(effect, id: "isolation", bypassed: true)
        let observed = QuantumFrames()
        _ = try outputBus.installPCMSink(id: "actual", targetFormat: .init()) { frame, _ in observed.append(frame) }
        let muted = try mixer.createBus("muted"); muted.volume = 0
        let sibling = try mixer.createBus("unchanged-peer")
        let siblingSource = try sibling.addPCMSource(id: "voice", maximumBufferedDuration: 0.12,
            captureTimePlayoutDelay: 0.01, adaptivePlayout: true)
        let siblingFrames = QuantumFrames()
        _ = try sibling.installPCMSink(id: "actual", targetFormat: .init()) { frame, _ in siblingFrames.append(frame) }
        try mixer.route(sibling, to: muted)
        let stoppedSource = try peer.addPCMSource(id: "stopped")
        try mixer.route(peer, to: outputBus); try mixer.route(outputBus, to: muted); try mixer.routeToOutput(muted)
        try mixer.start(); source.start(); siblingSource.start()
        defer { mixer.stop() }
        let tone = (0..<480).map { Float(0.15 * sin(Double($0) * 2 * .pi * 600 / 48000)) }
        let siblingTone = Array(repeating: Float(0.1), count: 480)
        for stage in 0..<3 {
            if stage > 0 {
                effect.bypass = stage == 2
                try outputBus.setEffectBypassed(id: "isolation", bypassed: stage == 2)
            }
            let start = ContinuousClock.now
            for packet in 0..<60 {
                try await Task.sleep(until: start + .milliseconds(packet * 10), clock: .continuous)
                let sequence = UInt64(stage * 60 + packet)
                let capturedAt = 100 + Double(sequence) * 0.01
                try source.schedule(.init(sequenceNumber: sequence, capturedAt: capturedAt, samples: tone))
                try siblingSource.schedule(
                    .init(sequenceNumber: sequence, capturedAt: capturedAt, samples: siblingTone))
            }
            let steady = Array(observed.snapshot.flatMap(\.samples).suffix(9600))
            XCTAssertEqual(steady.count, 9600)
            XCTAssertGreaterThan(sqrt(steady.reduce(Float(0)) { $0 + $1 * $1 } / Float(steady.count)), 0.01,
                "Stage \(stage): a live bypass change must not silence the already-playing peer")
            XCTAssertFalse(stoppedSource.playerNode.isPlaying, "A graph mutation must not start a stopped source")
            let unchanged = Array(siblingFrames.snapshot.flatMap(\.samples).suffix(9600))
            XCTAssertEqual(unchanged.count, 9600)
            XCTAssertEqual(unchanged.filter { abs($0 - 0.1) > 0.001 }.count, 0,
                "Another peer must retain its player clock and recover after native latency compensation")
            XCTAssertEqual(siblingSource.playbackResetCount, 0)
        }
    }

    func testSpeechAndPauseBoundariesRetainEveryVoicedSample() async throws {
        let probe = try PlaybackProbe(busID: "live-pauses", sourceID: "peer")
        try probe.mixer.start(); probe.source.start()
        defer { probe.mixer.stop() }
        let start = ContinuousClock.now
        var expectedVoiced = 0
        for index in 0..<300 {
            try await Task.sleep(until: start + .milliseconds(index * 10), clock: .continuous)
            let value: Float = (index / 10).isMultiple(of: 2) ? 0 : 0.2
            if value != 0 { expectedVoiced += 480 }
            try probe.source.schedule(.init(sequenceNumber: UInt64(index), capturedAt: 1000 + Double(index) * 0.01,
                samples: Array(repeating: value, count: 480)))
        }
        try await Task.sleep(for: .milliseconds(200))
        let voiced = probe.received.snapshot.flatMap(\.samples).filter { $0 > 0.1 }.count
        XCTAssertEqual(voiced, expectedVoiced, "Neither trim nor repeat samples when speech resumes")
        XCTAssertEqual(probe.source.playbackResetCount, 0)
    }

    func testContiguousPacketsDoNotLoseSamplesAtRenderBoundaries() async throws {
        let probe = try PlaybackProbe(busID: "live", sourceID: "peer")
        try probe.mixer.start(); probe.source.start()
        defer { probe.mixer.stop() }
        let start = ContinuousClock.now
        for index in 0..<200 {
            try await Task.sleep(until: start + .milliseconds(index * 10), clock: .continuous)
            try probe.source.schedule(.init(sequenceNumber: UInt64(index), capturedAt: 1000 + Double(index) * 0.01,
                samples: Array(repeating: 0.2, count: 480)))
        }
        let samples = probe.received.snapshot.flatMap(\.samples)
        // Warm-up is bounded to 100 ms. Every later sample of a sustained voice
        // must survive small scheduling/render-boundary jitter without truncation.
        let steady = Array(samples.dropFirst(4800).dropLast(4800))
        XCTAssertGreaterThan(steady.count, 48_000)
        XCTAssertEqual(steady.filter { abs($0 - 0.2) > 0.001 }.count, 0,
            "Samples disappeared between contiguous packets")
        XCTAssertEqual(probe.source.playbackResetCount, 0)
    }
}
