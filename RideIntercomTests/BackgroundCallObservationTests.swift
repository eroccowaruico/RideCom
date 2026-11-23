#if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS)
import AudioCore
import Foundation
import Testing
@testable import RideIntercom

@MainActor struct BackgroundCallObservationTests {
    @Test(arguments: [nil, "RideIntercom", "other", "RideIntercom.Validation.Xcode"] as [String?])
    func observationRequiresExplicitOptInAndIsolatedStorage(namespace: String?) {
        #expect(!BackgroundCallValidationObservation.isEnabled(environment: [:], storageNamespace: namespace))
        #expect(BackgroundCallValidationObservation.isEnabled(
            environment: ["RIDEINTERCOM_BACKGROUND_OBSERVATION": "1"], storageNamespace: namespace)
            == (namespace?.hasPrefix("RideIntercom.Validation.") == true))
    }

    @Test func atomicReplacementKeepsValidRecords() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("background-observation-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("[]".utf8).write(to: url, options: .completeFileProtection)
        for tick in 1...2 {
            try BackgroundCallValidationObservation.write([["uptime": tick, "background": true]], to: url)
            let rows = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
            #expect(rows.count == 1 && rows.first?["uptime"] as? Int == tick)
            #if !targetEnvironment(simulator)
            // Simulator does not expose iOS Data Protection through file attributes.
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let protection = (attributes[.protectionKey] as? FileProtectionType)?.rawValue
                ?? (attributes[.protectionKey] as? String)
            #expect(protection == FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
            #endif
        }
    }

    @Test func nativeOutputProbeDistinguishesRenderedGapFromWorkerDelay() throws {
        let format = AudioFormat(sampleRate: 48_000, channelCount: 1)
        let probe = BackgroundCallOutputProbe()
        for (sequence, renderTime, workerTime, level) in [
            (UInt64(0), 4.0, 10.0, Float(0)),
            (1, 4.02, 11.0, 0.1),
            (2, 4.52, 11.02, 0.1)
        ] {
            probe.record(PCMFrame(sequenceNumber: sequence, format: format, capturedAt: renderTime,
                samples: Array(repeating: level, count: 960)), workerUptime: workerTime)
        }
        let fields = probe.fields
        #expect(fields["callbackCount"] as? Int == 3)
        #expect(abs(try #require(fields["audibleDuration"] as? Double) - 0.04) < 0.000001)
        #expect(abs(try #require(fields["maxRenderGap"] as? Double) - 0.48) < 0.000001)
        #expect(fields["maxWorkerGap"] as? Double == 1)
        #expect(fields["lastWorkerAt"] as? Double == 11.02)
    }

    #if targetEnvironment(simulator)
    @Test(arguments: [false, true])
    func waitingMeasurementsCountOnlyBackgroundCallbacks(muted: Bool) {
        var records = waitingRecords(muted: muted)
        records[0]["background"] = false
        records[1][muted ? "outputCallback" : "inputCallback"] = false
        let result = BackgroundWaitingMeasurements(records: records, muted: muted)
        #expect(result.sampleCount == 28)
        #expect(result.span == 27)
        #expect(result.largestSampleGap == 1)
        #expect(result.validSimulatorContext && result.sameCall && result.sameDeadline)
        #expect(result.deadlineUnexpired)
        #expect(result.audioRunningWithExpectedMute && result.waitingWithoutRemoteAudio && result.silentNativeOutput)
    }

    @Test func missingOrChangedContextIsDetected() {
        var records = waitingRecords(muted: false)
        records[29].removeValue(forKey: "microphonePermission")
        records[29]["connectionInstance"] = "second-call"
        records[29]["deadline"] = 61.0
        let result = BackgroundWaitingMeasurements(records: records, muted: false)
        #expect(!result.validSimulatorContext)
        #expect(!result.audioRunningWithExpectedMute)
        #expect(!result.sameCall)
        #expect(!result.sameDeadline)
    }

    @Test func missingDeadlineInEverySampleIsDetected() {
        let records = waitingRecords(muted: false).map { record in
            record.filter { $0.key != "deadline" }
        }
        let result = BackgroundWaitingMeasurements(records: records, muted: false)
        #expect(!result.sameDeadline)
        #expect(!result.deadlineUnexpired)
    }

    @Test func aLongGapIsVisibleEvenWhenCallbackCountAndSpanAreEnough() {
        var records = waitingRecords(muted: false)
        for index in 15..<records.count {
            records[index]["uptime"] = Double(index + 4)
        }
        let result = BackgroundWaitingMeasurements(records: records, muted: false)
        #expect(result.sampleCount == 30 && result.span == 33)
        #expect(result.largestSampleGap == 5)
    }

    @Test func theSameDeadlineCanExpireBeforeTheLastSample() {
        let records = waitingRecords(muted: true).map { record in
            record.merging(["deadline": 29.0]) { _, replacement in replacement }
        }
        let result = BackgroundWaitingMeasurements(records: records, muted: true)
        #expect(result.sameDeadline)
        #expect(!result.deadlineUnexpired)
    }

    @Test(arguments: [false, true])
    func mutedAudioRequiresAdvancingSilentNativeOutput(audible: Bool) {
        var records = waitingRecords(muted: true)
        records[29]["nativeOutput"] = ["callbackCount": audible ? 30 : 1, "audibleDuration": audible ? 0.1 : 0.0]
        records[29]["receivedVoicePackets"] = 1
        records[29]["authenticatedPeers"] = 1
        let result = BackgroundWaitingMeasurements(records: records, muted: true)
        #expect(!result.silentNativeOutput)
        #expect(!result.waitingWithoutRemoteAudio)
        #expect(!result.audioRunningWithExpectedMute)
    }

    private func waitingRecords(muted: Bool) -> [[String: Any]] {
        (0..<30).map { second in [
            "background": true, "inputCallback": !muted, "outputCallback": muted, "uptime": Double(second),
            "deadline": 60.0, "processInstance": "fixture-process", "processID": 1, "platform": "simulator",
            "recordedAt": Double(second), "protectedDataAvailable": true, "testRunnerPresent": true,
            "microphonePermission": "granted", "debuggerAttached": NSNull(), "connectionInstance": "fixture-call",
            "usesNativeOutput": true, "receivedVoicePackets": 0, "availableRoutes": [String](),
            "lastAudibleOutputAt": NSNull(), "audioReady": true, "inputRunning": true, "outputRunning": true,
            "mediaStarted": false, "authenticatedPeers": 0, "muted": muted,
            "nativeOutput": ["callbackCount": second + 1, "audibleDuration": 0.0]
        ] }
    }
    #endif
}
#endif
