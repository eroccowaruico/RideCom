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
}
#endif
