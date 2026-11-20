import AVFAudio
import AudioCore
import Codec
import Foundation
import Synchronization
import RTC
import SessionManager
import XCTest
@testable import RideIntercom

private struct ReceiveSwitchTrace: Encodable {
    struct Switch: Encodable {
        let start: TimeInterval
        let end: TimeInterval
        let enabled: Bool
    }

    let switches: [Switch]
    let renderClock: [RenderedAudioProbe.RenderClockBlock]
    let rate: Double
    let baseline: [Double]
}

extension AudioE2ETests {
    @MainActor
    func testReceiveIsolationKeepsItsEffectWhenEnabledAgain() async throws {
        try await activateAudioSessionForTest(configuration: .init(prefersEchoCancelledInput: true))
        let engine = AVAudioEngine(), native = RenderedAudioProbe(recordsRenderClock: true)
        let output = SystemAudioOutputStreamBackend(engine: engine)
        try engine.mainMixerNode.installAudioTap(onBus: 0, bufferSize: 1024, format: nil) { native.append($0, time: $1) }
        let pipeline = AppAudioPipeline(makeEngine: { engine }, usesHardwareClock: true)
        defer { pipeline.stop(); engine.mainMixerNode.removeTap(onBus: 0); try? output.stopRendering() }
        let hardware = try output.startRendering(configuration: .intercomCall)
        try pipeline.rebuild(configuration: .init(outputHardwareFormat: hardware,
            transmitSoundIsolationEnabled: false, receiveMaximumBufferedDuration: 0.12, receivePlayoutDelay: 0.002),
            peerIDs: ["one", "two"])

        let frequencies = [600.0, 1100.0]
        let fixtures = zip(["one", "two"], frequencies).map { peer, frequency in
            let samples = (0..<480).map { Float(0.12 * sin(Double($0) * 2 * .pi * frequency / 48_000)) }
            return (PeerID(rawValue: peer), PCM16Codec.encode(samples))
        }
        let format = RTCAudioFormat(sampleRate: 48_000, channelCount: 1)
        let queue = DispatchQueue(label: "receive-isolation-fixture", qos: .userInitiated)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let sequence = Mutex<UInt64>(0), failures = Mutex<[String]>([])
        let rejected = Mutex<[(start: TimeInterval, end: TimeInterval)]>([])
        let start = DispatchTime.now() + .milliseconds(30)
        let captureOrigin = Double(start.uptimeNanoseconds) / 1e9
        timer.setEventHandler {
            let index = sequence.withLock { value in
                defer { value += 1 }
                return value
            }
            for (peer, payload) in fixtures {
                let packet = RTCAudioPacket(sequenceNumber: index, codec: .pcm16, format: format,
                    capturedAt: captureOrigin + Double(index) / 100, sampleCount: 480, payload: payload)
                let arrival = ProcessInfo.processInfo.systemUptime
                do { _ = try pipeline.processReceivedAudioPacket(.init(peerID: peer, packet: packet)) }
                catch AppAudioPipelineError.notConfigured {
                    rejected.withLock { $0.append((arrival, ProcessInfo.processInfo.systemUptime)) }
                }
                catch { failures.withLock { $0.append(String(describing: error)) } }
            }
        }
        timer.schedule(deadline: start, repeating: .milliseconds(10), leeway: .microseconds(100))
        timer.activate()
        defer { timer.cancel(); queue.sync {} }

        func steadyTones() async throws -> [Double] {
            try await Task.sleep(for: .milliseconds(650))
            let start = native.sampleCount
            try await Task.sleep(for: .milliseconds(400))
            let recording = native.snapshot()
            XCTAssertEqual(recording.invalid, 0)
            let measured = ToneIntegrity.measure(samples: Array(recording.samples.dropFirst(start)),
                rate: recording.rate, frequencies: frequencies)
            XCTAssertTrue(measured.passed, "\(measured.dictionary)")
            return try XCTUnwrap(measured.amplitudes.count == frequencies.count ? measured.amplitudes : nil)
        }
        let baseline = try await steadyTones()
        var masterChanges: [ClosedRange<TimeInterval>] = []
        var peerChanges: [ReceiveSwitchTrace.Switch] = []
        func updateIsolation(peerOnly: Bool, enabled: Bool) throws {
            let start = ProcessInfo.processInfo.systemUptime
            try pipeline.updateSoundIsolation(transmit: false, receiveMaster: enabled && !peerOnly,
                peers: enabled && peerOnly ? ["one": true] : [:])
            let end = ProcessInfo.processInfo.systemUptime
            if peerOnly { peerChanges.append(.init(start: start, end: end, enabled: enabled)) }
            else { masterChanges.append(start...end) }
        }
        for peerOnly in [false, true] {
            try updateIsolation(peerOnly: peerOnly, enabled: true)
            let first = try await steadyTones()
            try updateIsolation(peerOnly: peerOnly, enabled: false)
            let bypassed = try await steadyTones()
            try updateIsolation(peerOnly: peerOnly, enabled: true)
            let enabledAgain = try await steadyTones()
            for index in frequencies.indices {
                let expected = baseline[index] * (peerOnly && index == 1 ? 1 : 0.5)
                XCTAssertEqual(first[index], expected, accuracy: 0.002, "First enable, peerOnly=\(peerOnly)")
                XCTAssertEqual(bypassed[index], baseline[index], accuracy: 0.002, "Bypass, peerOnly=\(peerOnly)")
                XCTAssertEqual(enabledAgain[index], first[index], accuracy: 0.002, "Enable again, peerOnly=\(peerOnly)")
            }
            try updateIsolation(peerOnly: peerOnly, enabled: false)
            _ = try await steadyTones()
        }
        for _ in 0..<8 {
            for enabled in [true, false] {
                try updateIsolation(peerOnly: true, enabled: enabled)
                try await Task.sleep(for: .milliseconds(450))
            }
        }
        let renderClock = try XCTUnwrap(native.stopRecordingRenderClock())
        let rendered = native.snapshot()
        XCTAssertEqual(rendered.invalid, 0)
        let width = Int(rendered.rate * 0.01)
        XCTAssertGreaterThan(width, 0)
        func sampleIndex(at hostTime: Double) -> Int? {
            guard let block = renderClock.last(where: { $0.hostTime <= hostTime }) else { return nil }
            let offset = Int((hostTime - block.hostTime) * rendered.rate)
            return offset <= block.frameCount ? block.startSample + offset : nil
        }
        for change in peerChanges {
            let start = try XCTUnwrap(sampleIndex(at: change.start - 0.02))
            let end = try XCTUnwrap(sampleIndex(at: change.start + 0.25))
            let samples = rendered.samples[start..<end]
            let step = zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 1
            XCTAssertLessThan(step, 0.04, "Peer isolation switch, enabled=\(change.enabled)")
            // Both tones have whole cycles in 10 ms. Measure the unchanged
            // peer independently of the switched voice in the same output.
            let amplitudes = stride(from: start, through: end - width, by: max(1, width / 2)).map { offset in
                ToneIntegrity.measure(samples: Array(rendered.samples[offset..<offset + width]),
                    rate: rendered.rate, frequencies: [frequencies[1]]).amplitudes.first ?? 0
            }
            XCTAssertGreaterThan(try XCTUnwrap(amplitudes.min()), baseline[1] * 0.7,
                "Other peer during isolation switch, enabled=\(change.enabled)")
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("receive-switches.wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try native.writeWAV(to: url, rendered: rendered)
        let audio = XCTAttachment(contentsOfFile: url)
        audio.name = "receive-switches"; audio.lifetime = .keepAlways; add(audio)
        let trace = ReceiveSwitchTrace(switches: peerChanges, renderClock: renderClock, rate: rendered.rate, baseline: baseline)
        let attachment = XCTAttachment(data: try JSONEncoder().encode(trace), uniformTypeIdentifier: "public.json")
        attachment.name = "receive-switches-trace"; attachment.lifetime = .keepAlways; add(attachment)
        for attempt in rejected.withLock({ $0 }) {
            XCTAssertTrue(masterChanges.contains { $0.overlaps(attempt.start...attempt.end) },
                "A peer effect change cannot reject received audio: \(attempt)")
        }
        XCTAssertTrue(failures.withLock { $0.isEmpty })
        XCTAssertEqual(pipeline.droppedRenderFrameCount, 0)
        XCTAssertEqual(output.playbackResetCount ?? 0, 0)
    }

    @MainActor
    func testInputModeChangesRestoreTheSharedReceiveClock() async throws {
        try await activateAudioSessionForTest(configuration: .init(prefersEchoCancelledInput: true))
        let engine = AVAudioEngine(), probe = RenderedAudioProbe()
        let input = SpeechFileInput(samples: (0..<48000).map { Float(0.15 * sin(Double($0) * 2 * .pi * 600 / 48000)) }, engine: engine)
        let processing = AudioInputVoiceProcessingConfiguration(soundIsolationEnabled: false, otherAudioDuckingEnabled: true)
        try input.updateVoiceProcessing(processing)
        let capture = AudioInputStreamCapture(configuration: .intercom(voiceProcessing: processing), backend: input)
        let output = SystemAudioOutputStreamBackend(engine: engine)
        try engine.mainMixerNode.installAudioTap(onBus: 0, bufferSize: 1024, format: nil) { probe.append($0, time: $1) }
        let pipeline = AppAudioPipeline(makeEngine: { engine }, usesHardwareClock: true)
        let failures = Mutex<[String]>([])
        defer {
            capture.stop(); pipeline.stop()
            pipeline.onTransmitPacket = nil
            engine.mainMixerNode.removeTap(onBus: 0); try? output.stopRendering()
        }
        pipeline.onTransmitPacket = { [weak pipeline] packet in
            guard let pipeline else { return }
            do { _ = try pipeline.processReceivedAudioPacket(.init(peerID: .init(rawValue: "peer"), packet: packet)) }
            catch { failures.withLock { $0.append(String(describing: error)) } }
        }
        XCTAssertEqual(capture.start().result, .applied)
        let hardware = try output.startRendering(configuration: .intercomCall)
        try pipeline.rebuild(configuration: .init(outputHardwareFormat: hardware, preferredCodec: .pcm16,
            transmitSoundIsolationEnabled: false, receiveMaximumBufferedDuration: 0.12, receivePlayoutDelay: 0.002), peerIDs: ["peer"])
        capture.setRuntimeEventHandler { event in
            guard case .inputFrame(let frame) = event else { return }
            do { try pipeline.processCapturedFrame(frame) }
            catch { failures.withLock { $0.append(String(describing: error)) } }
        }
        try await Task.sleep(for: .seconds(1))
        var rows: [[String: Any]] = []
        for enabled in [false, true, false, true] {
            let start = ProcessInfo.processInfo.systemUptime
            let report = pipeline.reconfigureInput {
                capture.updateVoiceProcessing(.init(soundIsolationEnabled: false, otherAudioDuckingEnabled: enabled))
            }
            let duration = ProcessInfo.processInfo.systemUptime - start
            XCTAssertEqual(report.result, .applied)
            XCTAssertLessThan(duration, 0.5, "Native I/O reconfiguration is bounded; never wait for queued speech")
            try await Task.sleep(for: .milliseconds(300))
            probe.reset()
            try await Task.sleep(for: .seconds(1))
            let recorded = probe.snapshot()
            let tone = ToneIntegrity.measure(samples: recorded.samples, rate: recorded.rate, frequencies: [600])
            XCTAssertTrue(tone.passed, "Shared input/output mode \(enabled): \(tone.dictionary)")
            rows.append(["voiceProcessing": enabled, "changeDurationSeconds": duration, "steady": tone.dictionary])
        }
        XCTAssertTrue(failures.withLock { $0.isEmpty })
        let data = try JSONSerialization.data(withJSONObject: ["scenario": "input-mode-recovery", "role": "pipeline",
            "transport": "none", "stages": rows])
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "input-mode-recovery-measurement"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor
    func testLiveSettingsKeepBoundedSilenceAndContinuousSteadyAudio() async throws {
        try await activateAudioSessionForTest(configuration: .init(prefersEchoCancelledInput: true))
        let probe = RenderedAudioProbe(), engine = AVAudioEngine()
        let decodedProbe = RenderedAudioProbe(), mixedProbe = RenderedAudioProbe()
        let input = SpeechFileInput(samples: (0..<48000).map { Float(0.15 * sin(Double($0) * 2 * .pi * 600 / 48000)) }, engine: engine)
        try input.updateVoiceProcessing(.init(soundIsolationEnabled: false, otherAudioDuckingEnabled: true))
        let output = SystemAudioOutputStreamBackend(engine: engine)
        try engine.mainMixerNode.installAudioTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, time in probe.append(buffer, time: time) }
        let pipeline = AppAudioPipeline(makeEngine: { engine }, usesHardwareClock: true)
        let failureStore = Mutex<[String]>([])
        let rejectedReceives = Mutex<[(start: Double, end: Double)]>([])
        let delivery = AudioFrameDelivery(initiallyActive: false) { _ in }
        defer {
            try? input.stopCapture(); delivery.finish(); pipeline.stop()
            pipeline.onTransmitPacket = nil
            engine.mainMixerNode.removeTap(onBus: 0); try? output.stopRendering()
        }
        pipeline.onTransmitPacket = { [weak pipeline] packet in
            guard let pipeline else { return }
            let start = ProcessInfo.processInfo.systemUptime
            do { decodedProbe.append(try pipeline.processReceivedAudioPacket(.init(peerID: .init(rawValue: "peer"), packet: packet))) }
            catch AppAudioPipelineError.notConfigured {
                rejectedReceives.withLock { $0.append((start, ProcessInfo.processInfo.systemUptime)) }
            }
            catch { failureStore.withLock { $0.append(String(describing: error)) } }
        }
        pipeline.onOutputFrame = { mixedProbe.append($0) }
        _ = try input.startCapture(configuration: .intercom(voiceProcessing: .init())) { frame in
            guard delivery.isActive else { return }
            do { try pipeline.processCapturedFrame(frame) }
            catch { failureStore.withLock { $0.append(String(describing: error)) } }
            delivery.yield(frame)
        }
        let hardware = try output.startRendering(configuration: .intercomCall)
        try pipeline.rebuild(configuration: .init(outputHardwareFormat: hardware, preferredCodec: .pcm16,
            transmitSoundIsolationEnabled: false, maximumBufferedDuration: 0.2,
            receiveMaximumBufferedDuration: 0.12, receivePlayoutDelay: 0.002), peerIDs: ["peer"])
        delivery.activate()
        try await Task.sleep(for: .seconds(1))
        probe.reset(); decodedProbe.reset(); mixedProbe.reset()
        let stages = ["PCM", "isolation-on", "Opus", "AAC-48k", "AAC-16k", "AAC-24k", "AAC-48k-high", "isolation-off",
                      "receive-master-on", "receive-master-off", "receive-peer-on", "receive-peer-off",
                      "isolation-on-again", "isolation-off-again"]
        var boundaries: [Int] = []
        var changeHostTimes: [Double] = [], changeDurations: [Double] = []
        for (index, _) in stages.enumerated() {
            boundaries.append(probe.sampleCount)
            let changeStart = ProcessInfo.processInfo.systemUptime
            changeHostTimes.append(changeStart)
            switch index {
            case 1: try pipeline.updateSoundIsolation(transmit: true, receiveMaster: false, peers: [:])
            case 2: try pipeline.updateEncoding(preferred: .opus, format: .init(), aacELDv2BitRate: 64000, opusBitRate: 48000)
            case 3: try pipeline.updateEncoding(preferred: .mpeg4AACELD, format: .init(), aacELDv2BitRate: 64000, opusBitRate: 48000)
            case 4:
                try pipeline.updateEncoding(preferred: .mpeg4AACELD, format: .init(sampleRate: 16000, channelCount: 1), aacELDv2BitRate: 48000, opusBitRate: 48000)
            case 5:
                try pipeline.updateEncoding(preferred: .mpeg4AACELD, format: .init(sampleRate: 24000, channelCount: 1), aacELDv2BitRate: 32000, opusBitRate: 48000)
            case 6:
                try pipeline.updateEncoding(preferred: .mpeg4AACELD, format: .init(), aacELDv2BitRate: 64000, opusBitRate: 48000)
            case 7: try pipeline.updateSoundIsolation(transmit: false, receiveMaster: false, peers: [:])
            case 8: try pipeline.updateSoundIsolation(transmit: false, receiveMaster: true, peers: [:])
            case 9: try pipeline.updateSoundIsolation(transmit: false, receiveMaster: false, peers: [:])
            case 10: try pipeline.updateSoundIsolation(transmit: false, receiveMaster: false, peers: ["peer": true])
            case 11: try pipeline.updateSoundIsolation(transmit: false, receiveMaster: false, peers: [:])
            case 12: try pipeline.updateSoundIsolation(transmit: true, receiveMaster: false, peers: [:])
            case 13: try pipeline.updateSoundIsolation(transmit: false, receiveMaster: false, peers: [:])
            default: break
            }
            changeDurations.append(ProcessInfo.processInfo.systemUptime - changeStart)
            try await Task.sleep(for: .seconds(2))
        }
        let failures = failureStore.withLock { $0 }
        let rejected = rejectedReceives.withLock { $0 }
        let recorded = probe.snapshot()
        let drops = input.droppedCaptureFrameCount + delivery.droppedFrameCount + pipeline.droppedRenderFrameCount
        let resets = output.playbackResetCount ?? 0
        let encodingFailures = pipeline.transmitEncodingFailureCount
        try input.stopCapture(); delivery.finish(); pipeline.stop(); try output.stopRendering()
        boundaries.append(recorded.samples.count)
        var rows: [[String: Any]] = []
        for (index, name) in stages.enumerated() {
            let start = boundaries[index], end = boundaries[index + 1]
            let stableStart = min(end, start + Int(recorded.rate * 0.3))
            let stable = Array(recorded.samples[stableStart..<end])
            let tone = ToneIntegrity.measure(samples: stable, rate: recorded.rate, frequencies: [600])
            let all = Array(recorded.samples[start..<end])
            let step = zip(all, all.dropFirst()).map { abs($0 - $1) }.max() ?? 1
            let width = Int(recorded.rate / 1000)
            var silence = 0, maximumSilence = 0
            for offset in stride(from: 0, through: max(0, all.count - width), by: width) {
                let rms = sqrt(all[offset..<(offset + width)].reduce(Float(0)) { $0 + $1 * $1 } / Float(width))
                silence = rms < 0.0001 ? silence + 1 : 0
                maximumSilence = max(maximumSilence, silence)
            }
            rows.append(["stage": name, "startSample": start, "endSample": end,
                "changeHostTime": changeHostTimes[index], "changeDurationSeconds": changeDurations[index],
                "steady": tone.dictionary, "maximumSampleStep": step, "maximumSilenceMilliseconds": maximumSilence])
            XCTAssertTrue(tone.passed, "\(name): \(tone.dictionary)")
            XCTAssertLessThan(step, 0.04, "No click across \(name)")
            XCTAssertLessThanOrEqual(maximumSilence, 120, "Only a bounded native reconfiguration interval may be silent")
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
        // A master effect change invalidates all receive reservations. No
        // packet can be rejected during a peer effect change or while settling.
        for attempt in rejected {
            XCTAssertTrue(stages.indices.contains { index in
                stages[index].hasPrefix("receive-master-")
                    && attempt.start <= changeHostTimes[index] + changeDurations[index]
                    && attempt.end >= changeHostTimes[index]
            }, "Unexpected receive rejection outside a master effect change: \(attempt)")
        }
        XCTAssertEqual(drops, 0); XCTAssertEqual(resets, 0); XCTAssertEqual(encodingFailures, 0)
        let measurement: [String: Any] = ["scenario": "live-settings", "role": "pipeline", "transport": "none",
            "stages": rows, "firstOutputHostTime": probe.firstOutputTime ?? 0,
            "captureTiming": input.captureTiming, "captureDiscontinuities": input.captureDiscontinuities,
            "droppedFrames": drops, "outputResets": resets, "processingFailures": failures,
            "receiveRejections": rejected.map { ["start": $0.start, "end": $0.end] }]
        let attachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: measurement), uniformTypeIdentifier: "public.json")
        attachment.name = "live-settings-measurement"; attachment.lifetime = .keepAlways; add(attachment)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("live-settings.wav")
        try probe.writeWAV(to: url, rendered: recorded)
        let audio = XCTAttachment(contentsOfFile: url); audio.name = "live-settings"; audio.lifetime = .keepAlways; add(audio)
        try? FileManager.default.removeItem(at: url)
        for (name, stage) in [("decoded", decodedProbe), ("mixed", mixedProbe)] {
            let stageURL = FileManager.default.temporaryDirectory.appendingPathComponent("live-settings-\(name).wav")
            try stage.writeWAV(to: stageURL, rendered: stage.snapshot())
            let attachment = XCTAttachment(contentsOfFile: stageURL)
            attachment.name = "live-settings-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
            try? FileManager.default.removeItem(at: stageURL)
        }
    }
}
