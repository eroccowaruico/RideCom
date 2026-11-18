#if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS)
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
}
#endif
