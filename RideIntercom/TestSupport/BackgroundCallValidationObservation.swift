#if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS)
import AudioCore
import AVFAudio
import Darwin
import Foundation
import RTC
import SessionManager
import UIKit

/// Opt-in native callback evidence, bounded and without PCM or participant identity.
/// Runs on the existing UI observation delivery, never on the realtime capture worker.
@MainActor enum BackgroundCallValidationObservation {
    private static var didPauseForResumeFixture = false
    private static let processInstance = UUID().uuidString
    private static var records: [[String: Any]] = []
    private static var lastRecordedAt: [String: TimeInterval] = [:]
    static func isEnabled(environment: [String: String], storageNamespace: String?) -> Bool {
        environment["RIDEINTERCOM_BACKGROUND_OBSERVATION"] == "1"
            && storageNamespace?.hasPrefix("RideIntercom.Validation.") == true
    }
    static func write(_ records: [[String: Any]], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
            .write(to: url, options: CallStorageProtection.writingOptions)
    }
    /// Debug-only observation of this process; failure stays unknown, never "not attached".
    private static func debuggerAttached() -> Bool? {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return nil }
        return (info.kp_proc.p_flag & P_TRACED) != 0
    }
    private static var microphonePermission: String {
        switch AVAudioApplication.shared.recordPermission {
        case .undetermined: "undetermined"
        case .denied: "denied"
        case .granted: "granted"
        @unknown default: "unknown"
        }
    }
    static func observe(_ model: IntercomViewModel, frame: PCMFrame? = nil, output: Bool = false) {
        guard isEnabled(environment: ProcessInfo.processInfo.environment,
            storageNamespace: Bundle.main.object(forInfoDictionaryKey: "StorageNamespace") as? String) else { return }
        #if targetEnvironment(simulator)
        if frame != nil, !didPauseForResumeFixture,
           ProcessInfo.processInfo.environment["RIDEINTERCOM_BACKGROUND_RESUME"] == "1" {
            didPauseForResumeFixture = true
            Task { @MainActor [weak model] in
                guard let model, model.isAudioReady, model.callDisconnectDeadline != nil,
                      model.authenticatedPeerIDs.isEmpty else { return }
                model.handleAudioSessionRuntimeEvent(.snapshotChanged(.init(
                    reason: .interruptionBegan, snapshot: model.audioSessionSnapshot)))
            }
        }
        #endif
        let now = ProcessInfo.processInfo.systemUptime
        let source = output ? "output" : (frame == nil ? "stop" : "input")
        guard source == "stop" || now - (lastRecordedAt[source] ?? 0) >= 1 else { return }
        lastRecordedAt[source] = now
        #if targetEnvironment(simulator)
        let platform = "simulator"
        #else
        let platform = "device"
        #endif
        let environment = ProcessInfo.processInfo.environment
        let testRunner = NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil
            || ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"].contains { environment[$0] != nil }
        let usesNativeOutput = model.audioPipeline.rendersToHardware
        let lastAudibleOutputAt = usesNativeOutput ? model.lastAudibleReceivedAudioAt : nil
        records.append(["uptime": now, "background": UIApplication.shared.applicationState == .background,
            "recordedAt": Date().timeIntervalSince1970, "processInstance": processInstance,
            "processID": ProcessInfo.processInfo.processIdentifier, "platform": platform,
            "build": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            "protectedDataAvailable": UIApplication.shared.isProtectedDataAvailable,
            "microphonePermission": microphonePermission,
            "debuggerAttached": debuggerAttached() as Any? ?? NSNull(), "testRunnerPresent": testRunner,
            "inputCallback": frame != nil, "outputCallback": output, "audioReady": model.isAudioReady,
            "muted": model.effectiveInputMuted,
            "mediaStarted": model.isCallMediaStarted,
            "inputRunning": model.lastInputStreamOperationReport?.snapshot.isRunning == true,
            "outputRunning": model.lastOutputStreamOperationReport?.snapshot.isRunning == true,
            "authenticatedPeers": model.authenticatedPeerIDs.count,
            "connectionInstance": model.connectionGeneration.uuidString,
            "availableRoutes": model.availableCallRoutes.map(\.rawValue).sorted(),
            "receivedVoicePackets": model.receivedVoicePacketCount,
            "usesNativeOutput": usesNativeOutput,
            "lastAudibleOutputAt": lastAudibleOutputAt as Any? ?? NSNull(),
            "deadline": model.callDisconnectDeadline?.timeIntervalSince1970 as Any? ?? NSNull()])
        if records.count > 256 { records.removeFirst(records.count - 256) }
        let layout = ProcessInfo.processInfo.environment["RIDEINTERCOM_INTERFACE_FIXTURE"] == "advanced" ? "advanced" : "standard"
        #if targetEnvironment(simulator)
        let resuming = environment["RIDEINTERCOM_BACKGROUND_RESUME"] == "1"
        #else
        let resuming = false
        #endif
        let suffix = resuming ? "-resumed"
            : environment["RIDEINTERCOM_BACKGROUND_FIRST_PERMISSION"] == "1" ? "-first-permission"
            : (ProcessInfo.processInfo.environment["RIDEINTERCOM_BACKGROUND_MUTED"] == "1" ? "-muted" : "-open")
        try? write(records, to: FileManager.default.temporaryDirectory.appendingPathComponent("background-call-" + layout + suffix + ".json"))
    }
}
#endif
