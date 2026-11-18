#if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS) && targetEnvironment(simulator)
import AudioCore
import Foundation
import SessionManager
import UIKit

/// Opt-in native callback evidence, bounded and without PCM or participant identity.
/// Runs on the existing UI observation delivery, never on the realtime capture worker.
@MainActor enum BackgroundCallValidationObservation {
    private static var records: [[String: Any]] = []
    private static var lastRecordedAt: [String: TimeInterval] = [:]
    static func observe(_ model: IntercomViewModel, frame: PCMFrame? = nil, output: Bool = false) {
        guard ProcessInfo.processInfo.environment["RIDEINTERCOM_BACKGROUND_OBSERVATION"] == "1" else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let source = output ? "output" : (frame == nil ? "stop" : "input")
        guard source == "stop" || now - (lastRecordedAt[source] ?? 0) >= 1 else { return }
        lastRecordedAt[source] = now
        records.append(["uptime": now, "background": UIApplication.shared.applicationState == .background,
            "inputCallback": frame != nil, "outputCallback": output, "audioReady": model.isAudioReady,
            "muted": model.effectiveInputMuted,
            "mediaStarted": model.isCallMediaStarted,
            "inputRunning": model.lastInputStreamOperationReport?.snapshot.isRunning == true,
            "outputRunning": model.lastOutputStreamOperationReport?.snapshot.isRunning == true,
            "authenticatedPeers": model.authenticatedPeerIDs.count,
            "deadline": model.callDisconnectDeadline?.timeIntervalSince1970 as Any? ?? NSNull()])
        if records.count > 256 { records.removeFirst(records.count - 256) }
        let layout = ProcessInfo.processInfo.environment["RIDEINTERCOM_INTERFACE_FIXTURE"] == "advanced" ? "advanced" : "standard"
        let suffix = ProcessInfo.processInfo.environment["RIDEINTERCOM_BACKGROUND_MUTED"] == "1" ? "-muted" : "-open"
        if let data = try? JSONSerialization.data(withJSONObject: records, options: [.sortedKeys]) {
            try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("background-call-" + layout + suffix + ".json"), options: .atomic)
        }
    }
}
#endif
