import AVFAudio
import AudioCore
import Codec
import Foundation
import Synchronization
import RTC
import SessionManager
import XCTest
@testable import RideIntercom

extension AudioE2ETests {
    @MainActor
    func testInputModeChangesRestoreTheSharedReceiveClock() async throws {
        try await activateAudioSessionForTest(configuration: .init(prefersEchoCancelledInput: true))
        let engine = AVAudioEngine(), probe = RenderedAudioProbe()
        let input = makeSettingsInput(engine: engine)
        let processing = AudioInputVoiceProcessingConfiguration(
            soundIsolationEnabled: false, otherAudioDuckingEnabled: true
        )
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
            do {
                _ = try pipeline.processReceivedAudioPacket(.init(peerID: .init(rawValue: "peer"), packet: packet))
            } catch { failures.withLock { $0.append(String(describing: error)) } }
        }
        XCTAssertEqual(capture.start().result, .applied)
        let hardware = try output.startRendering(configuration: .intercomCall)
        try pipeline.rebuild(configuration: .init(
            outputHardwareFormat: hardware, preferredCodec: .pcm16, transmitSoundIsolationEnabled: false,
            receiveMaximumBufferedDuration: 0.12, receivePlayoutDelay: 0.002
        ), peerIDs: ["peer"])
        capture.setRuntimeEventHandler { event in
            guard case .inputFrame(let frame) = event else { return }
            do { try pipeline.processCapturedFrame(frame) } catch {
                failures.withLock { $0.append(String(describing: error)) }
            }
        }
        try await Task.sleep(for: .seconds(1))
        let rows = try await measureVoiceProcessingChanges(pipeline: pipeline, capture: capture, probe: probe)
        XCTAssertTrue(failures.withLock { $0.isEmpty })
        try addAudioE2EJSONAttachment(["scenario": "input-mode-recovery", "role": "pipeline",
            "transport": "none", "stages": rows], name: "input-mode-recovery-measurement")
    }

    @MainActor
    private func measureVoiceProcessingChanges(
        pipeline: AppAudioPipeline, capture: AudioInputStreamCapture, probe: RenderedAudioProbe
    ) async throws -> [[String: Any]] {
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
        return rows
    }

    @MainActor
    func testLiveSettingsKeepBoundedSilenceAndContinuousSteadyAudio() async throws {
        try await measureLiveSettings(intervalMilliseconds: 2000, acceptance: true)
    }

    @MainActor
    func testMeasureLiveSettingsSwitchLimits() async throws {
        for interval in [2000, 1000, 500] {
            try await measureLiveSettings(intervalMilliseconds: interval, acceptance: false)
        }
    }

    @MainActor
    private func measureLiveSettings(intervalMilliseconds: Int, acceptance: Bool) async throws {
        let scenario = acceptance ? "live-settings" : "switch-limits-\(intervalMilliseconds)ms"
        try await activateAudioSessionForTest(configuration: .init(prefersEchoCancelledInput: true))
        let capture = try LiveSettingsAudioCapture()
        defer { capture.tearDown() }
        try capture.start()
        let result = try await capture.record(intervalMilliseconds: intervalMilliseconds, acceptance: acceptance)
        try reportLiveSettings(result, capture: capture, scenario: scenario,
                               intervalMilliseconds: intervalMilliseconds, acceptance: acceptance)
    }

    @MainActor
    private func reportLiveSettings(
        _ result: LiveSettingsAudioResult, capture: LiveSettingsAudioCapture, scenario: String,
        intervalMilliseconds: Int, acceptance: Bool
    ) throws {
        let recordings = result.recordings
        var stagesMeasured = SwitchStageMeasurements()
        for window in result.windows {
            stagesMeasured.record(window: window, audio: recordings, acceptance: acceptance)
        }
        let failures = result.failures
        let rejected = result.rejected
        let drops = result.drops
        let resets = result.resets
        let encodingFailures = result.encodingFailures
        // A master effect change can invalidate a reservation only during the change.
        let unexpectedRejections = rejected.filter { attempt in
            !result.windows.contains { window in
                window.name.hasPrefix("receive-master-")
                    && attempt.start <= window.time + window.duration
                    && attempt.end >= window.time
            }
        }
        if acceptance {
            XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
            XCTAssertTrue(unexpectedRejections.isEmpty, "Unexpected receive rejection outside a master effect change")
            XCTAssertEqual(drops, 0); XCTAssertEqual(resets, 0); XCTAssertEqual(encodingFailures, 0)
        }
        var measurement: [String: Any] = ["scenario": scenario, "role": "pipeline", "transport": "none",
            "stages": stagesMeasured.rows, "firstOutputHostTime": capture.probes.native.firstOutputTime ?? 0,
            "captureTiming": capture.input.captureTiming,
            "captureDiscontinuities": capture.input.captureDiscontinuities,
            "droppedFrames": drops, "outputResets": resets, "processingFailures": failures,
            "receiveRejections": rejected.map { ["start": $0.start, "end": $0.end] }]
        if !acceptance {
            measurement["intervalMilliseconds"] = intervalMilliseconds
            let invalidUpstreamProbes = recordings.invalidUpstreamProbes
            stagesMeasured.finishLimitObservation(invalidUpstreamProbes: invalidUpstreamProbes)
            measurement["invalidUpstreamProbes"] = invalidUpstreamProbes
            measurement["unmetStages"] = stagesMeasured.unmetStages
            measurement["unexpectedRejections"] = unexpectedRejections.count
            measurement["encodingFailures"] = encodingFailures
            let met = stagesMeasured.unmetStages.isEmpty && unexpectedRejections.isEmpty && failures.isEmpty
                && drops == 0 && resets == 0 && encodingFailures == 0
            measurement["qualityObservation"] = stagesMeasured.unavailable ? "unavailable" : (met ? "met" : "unmet")
        }
        try addAudioE2EJSONAttachment(measurement, name: "\(scenario)-measurement")
        try attachLiveSettingsRecordings(recordings, probes: capture.probes, scenario: scenario)
    }

    private func attachLiveSettingsRecordings(
        _ recordings: SwitchRecordings, probes: LiveSettingsProbes, scenario: String
    ) throws {
        let recorded = recordings.final
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(scenario).wav")
        guard !recorded.samples.isEmpty, recorded.rate.isFinite, (1000...192000).contains(recorded.rate) else { return }
        try probes.native.writeWAV(to: url, rendered: recorded)
        let audio = XCTAttachment(contentsOfFile: url); audio.name = scenario; audio.lifetime = .keepAlways; add(audio)
        try? FileManager.default.removeItem(at: url)
        for (name, stage, stageRecording) in [
            ("decoded", probes.decoded, recordings.decoded), ("mixed", probes.mixed, recordings.mixed)
        ] {
            let stageURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(scenario)-\(name).wav")
            guard !stageRecording.samples.isEmpty, (1000...192000).contains(stageRecording.rate) else {
                XCTFail("Missing \(name) audio")
                continue
            }
            try stage.writeWAV(to: stageURL, rendered: stageRecording)
            let attachment = XCTAttachment(contentsOfFile: stageURL)
            attachment.name = "\(scenario)-\(name)"; attachment.lifetime = .keepAlways; add(attachment)
            try? FileManager.default.removeItem(at: stageURL)
        }
    }
}
