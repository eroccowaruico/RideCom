#if DEBUG && RIDEINTERCOM_VALIDATION && os(iOS)
import AudioCore
import AVFAudio
import Darwin
import Foundation
import RTC
import SessionManager
import Synchronization
import UIKit
#if targetEnvironment(simulator)
import SwiftUI
#endif

/// Persists bounded snapshots on the existing App delivery, without PCM or participant identity.
@MainActor enum BackgroundCallValidationObservation {
    private static var didPauseForResumeFixture = false
    private static let processInstance = UUID().uuidString
    private static var records: [[String: Any]] = []
    private static var lastRecordedAt: [String: TimeInterval] = [:]
    private static var lastDuckingChange: DuckingChange?
    private static var longestDuckingChange: DuckingChange?
    static let isEnabled = isEnabled(environment: ProcessInfo.processInfo.environment,
        storageNamespace: Bundle.main.object(forInfoDictionaryKey: "StorageNamespace") as? String)

    private struct DuckingChange {
        var active: Bool
        var startedAt: TimeInterval
        var duration: TimeInterval
        var fields: [String: Any] { ["active": active, "startedAt": startedAt, "duration": duration] }
    }

    static func measureDuckingChange(to active: Bool, _ apply: () -> Void) {
        guard isEnabled else { apply(); return }
        let startedAt = ProcessInfo.processInfo.systemUptime
        apply()
        let change = DuckingChange(active: active, startedAt: startedAt,
            duration: ProcessInfo.processInfo.systemUptime - startedAt)
        lastDuckingChange = change
        if change.duration > (longestDuckingChange?.duration ?? 0) { longestDuckingChange = change }
    }
    static func isEnabled(environment: [String: String], storageNamespace: String?) -> Bool {
        environment["RIDEINTERCOM_BACKGROUND_OBSERVATION"] == "1"
            && storageNamespace?.hasPrefix("RideIntercom.Validation.") == true
    }
    static func write(_ records: [[String: Any]], to url: URL) throws {
        try JSONSerialization.data(withJSONObject: records, options: [.sortedKeys])
            .write(to: url, options: CallStorageProtection.writingOptions)
    }
    #if targetEnvironment(simulator)
    static let waitingAssertionsEnabled = isEnabled
        && ProcessInfo.processInfo.environment["RIDEINTERCOM_BACKGROUND_WAITING_ASSERTIONS"] == "1"

    static func waitingMeasurements() -> BackgroundWaitingMeasurements {
        BackgroundWaitingMeasurements(records: records,
            muted: ProcessInfo.processInfo.environment["RIDEINTERCOM_BACKGROUND_MUTED"] == "1")
    }
    #endif
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
        guard isEnabled else { return }
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
        let environment = ProcessInfo.processInfo.environment
        records.append(snapshot(model, frame: frame, output: output, now: now, environment: environment))
        if records.count > 256 { records.removeFirst(records.count - 256) }
        let layout = environment["RIDEINTERCOM_INTERFACE_FIXTURE"] == "advanced" ? "advanced" : "standard"
        let suffix = observationSuffix(environment)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("background-call-\(layout)-\(suffix).json")
        try? write(records, to: url)
    }

    private static func snapshot(
        _ model: IntercomViewModel, frame: PCMFrame?, output: Bool, now: TimeInterval,
        environment: [String: String]
    ) -> [String: Any] {
        #if targetEnvironment(simulator)
        let platform = "simulator"
        #else
        let platform = "device"
        #endif
        let testRunner = NSClassFromString("XCTestCase") != nil || NSClassFromString("XCTest.XCTestCase") != nil
            || ["XCTestConfigurationFilePath", "XCTestBundlePath", "XCTestSessionIdentifier"]
                .contains { environment[$0] != nil }
        let usesNativeOutput = model.audioPipeline.rendersToHardware
        let lastAudibleOutputAt = usesNativeOutput ? model.lastAudibleReceivedAudioAt : nil
        let network = model.networkDiagnostics
        let localRoute = network?.routes.first { $0.route == .multipeer }
        let decode = model.audioPipeline.receiveDecodeCounts
        return ["uptime": now, "background": UIApplication.shared.applicationState == .background,
            "recordedAt": Date().timeIntervalSince1970, "processInstance": processInstance,
            "processID": Int(ProcessInfo.processInfo.processIdentifier), "platform": platform,
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
            "localMediaObservationAt": (localRoute == nil ? nil : network?.generatedAt) as Any? ?? NSNull(),
            "localReceivedDatagrams": localRoute?.statistics.receivedMediaDatagrams as Any? ?? NSNull(),
            "localRouteEventDrops": localRoute?.eventDrops["route"]
                .map { $0.overflow + $0.expired } as Any? ?? NSNull(),
            "sessionEventDrops": network.map { $0.eventDrops.overflow + $0.eventDrops.expired } as Any? ?? NSNull(),
            "decodedPCMPackets": decode.pcmPackets, "decodeFailures": decode.failures,
            "usesNativeOutput": usesNativeOutput,
            "nativeOutput": (usesNativeOutput ? model.audioPipeline.backgroundOutputProbe?.fields : nil)
                as Any? ?? NSNull(),
            "lastAudibleOutputAt": lastAudibleOutputAt as Any? ?? NSNull(),
            "lastNativeAudibleOutputAt": model.audioPipeline.lastNativeAudibleOutputAt as Any? ?? NSNull(),
            "lastDuckingChange": lastDuckingChange?.fields as Any? ?? NSNull(),
            "longestDuckingChange": longestDuckingChange?.fields as Any? ?? NSNull(),
            "deadline": model.callDisconnectDeadline?.timeIntervalSince1970 as Any? ?? NSNull()]
    }

    private static func observationSuffix(_ environment: [String: String]) -> String {
        #if targetEnvironment(simulator)
        if environment["RIDEINTERCOM_BACKGROUND_RESUME"] == "1" { return "resumed" }
        #endif
        if environment["RIDEINTERCOM_BACKGROUND_FIRST_PERMISSION"] == "1" { return "first-permission" }
        return environment["RIDEINTERCOM_BACKGROUND_MUTED"] == "1" ? "muted" : "open"
    }
}

#if targetEnvironment(simulator)
/// Returns the background measurements through an existing control only for the isolated UI test.
struct BackgroundWaitingObservationValue: ViewModifier {
    @State private var measurementValue = ""

    func body(content: Content) -> some View {
        if BackgroundCallValidationObservation.waitingAssertionsEnabled {
            let foreground = NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)
            content.accessibilityValue(Text(verbatim: measurementValue))
                .onReceive(foreground) { _ in
                    let report = BackgroundCallValidationObservation.waitingMeasurements()
                    guard let encoded = try? JSONEncoder().encode(report),
                          let value = String(bytes: encoded, encoding: .utf8) else { return }
                    measurementValue = value
                }
        } else {
            content
        }
    }
}

nonisolated struct BackgroundWaitingMeasurements: Encodable {
    let sampleCount: Int
    let span: TimeInterval
    let largestSampleGap: TimeInterval?
    let validSimulatorContext: Bool
    let sameCall: Bool
    let sameDeadline: Bool
    let deadlineUnexpired: Bool
    let audioRunningWithExpectedMute: Bool
    let waitingWithoutRemoteAudio: Bool
    let silentNativeOutput: Bool

    init(records: [[String: Any]], muted: Bool) {
        // With no remote source, unmuted audio needs native capture but not silent output taps.
        let callback = muted ? "outputCallback" : "inputCallback"
        let samples = records.filter { $0["background"] as? Bool == true && $0[callback] as? Bool == true }
        sampleCount = samples.count
        let timestamps = samples.compactMap { $0["uptime"] as? TimeInterval }
        let gaps = zip(timestamps, timestamps.dropFirst()).map { earlier, later in later - earlier }
        if timestamps.count == samples.count, let start = timestamps.first, let end = timestamps.last,
           gaps.allSatisfy({ $0.isFinite && $0 > 0 }) {
            span = end - start
            largestSampleGap = gaps.max()
        } else {
            span = 0
            largestSampleGap = nil
        }
        validSimulatorContext = Self.hasOneValue(in: records, for: "processInstance", ofType: String.self)
            && records.allSatisfy(Self.hasSimulatorContext)
        sameCall = Self.hasOneValue(in: samples, for: "connectionInstance", ofType: String.self)
        sameDeadline = Self.hasOneValue(in: samples, for: "deadline", ofType: TimeInterval.self)
        deadlineUnexpired = !samples.isEmpty && samples.allSatisfy {
            guard let observedAt = $0["recordedAt"] as? TimeInterval,
                  let deadline = $0["deadline"] as? TimeInterval else { return false }
            return observedAt < deadline
        }
        audioRunningWithExpectedMute = !samples.isEmpty && samples.allSatisfy {
            $0["audioReady"] as? Bool == true
                && $0["inputRunning"] as? Bool == true && $0["outputRunning"] as? Bool == true
                && $0["mediaStarted"] as? Bool == false && $0["authenticatedPeers"] as? Int == 0
                && $0["muted"] as? Bool == muted && $0["microphonePermission"] as? String == "granted"
        }
        waitingWithoutRemoteAudio = !samples.isEmpty && samples.allSatisfy {
            $0["usesNativeOutput"] as? Bool == true && $0["receivedVoicePackets"] as? Int == 0
                && $0["availableRoutes"] is [String] && $0["lastAudibleOutputAt"] is NSNull
        }
        silentNativeOutput = !muted || Self.hasSilentNativeOutput(in: samples)
    }

    private static func hasOneValue<T: Equatable>(
        in records: [[String: Any]], for key: String, ofType type: T.Type
    ) -> Bool {
        guard let value = records.first?[key] as? T else { return false }
        return records.allSatisfy { $0[key] as? T == value }
    }

    private static func hasSimulatorContext(_ record: [String: Any]) -> Bool {
        let permissions = ["undetermined", "denied", "granted", "unknown"]
        return record["platform"] as? String == "simulator"
            && record["processID"] is Int && record["recordedAt"] is TimeInterval
            && record["protectedDataAvailable"] is Bool && record["testRunnerPresent"] is Bool
            && permissions.contains(record["microphonePermission"] as? String ?? "")
            && (record["debuggerAttached"] is NSNull || record["debuggerAttached"] is Bool)
    }

    private static func hasSilentNativeOutput(in samples: [[String: Any]]) -> Bool {
        let output = samples.compactMap { $0["nativeOutput"] as? [String: Any] }
        guard output.count == samples.count,
              let firstCount = output.first?["callbackCount"] as? Int,
              let lastCount = output.last?["callbackCount"] as? Int else { return false }
        return firstCount > 0 && lastCount > firstCount && output.allSatisfy {
            $0["audibleDuration"] as? TimeInterval == 0
        }
    }
}
#endif

/// The mixer's capture worker delivers frames here after leaving the render
/// thread and before enqueueing them for MainActor. Retain only counters.
nonisolated final class BackgroundCallOutputProbe: Sendable {
    private let instance = UUID().uuidString
    private let metrics = Mutex(Metrics())

    private struct Metrics {
        var callbackCount = 0
        var audibleDuration: TimeInterval = 0
        var lastRenderEnd: TimeInterval?
        var maxRenderGap: TimeInterval = 0
        var lastWorkerAt: TimeInterval?
        var maxWorkerGap: TimeInterval = 0
    }

    func record(_ frame: PCMFrame, workerUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        let duration = Double(frame.frameCount) / frame.format.sampleRate
        let audible = AudioLevelMeter.rmsLevel(samples: frame.samples) > AudioLevelMeter.audibleOutputThreshold
        metrics.withLock { value in
            value.callbackCount += 1
            if audible { value.audibleDuration += duration }
            if let previousEnd = value.lastRenderEnd {
                value.maxRenderGap = max(value.maxRenderGap, frame.capturedAt - previousEnd)
            }
            if let previousWorkerAt = value.lastWorkerAt {
                value.maxWorkerGap = max(value.maxWorkerGap, workerUptime - previousWorkerAt)
            }
            value.lastRenderEnd = frame.capturedAt + duration
            value.lastWorkerAt = workerUptime
        }
    }

    var fields: [String: Any] {
        let value = metrics.withLock { $0 }
        return ["instance": instance, "callbackCount": value.callbackCount, "audibleDuration": value.audibleDuration,
            "lastRenderEnd": value.lastRenderEnd as Any? ?? NSNull(), "maxRenderGap": value.maxRenderGap,
            "lastWorkerAt": value.lastWorkerAt as Any? ?? NSNull(), "maxWorkerGap": value.maxWorkerGap]
    }
}
#endif
