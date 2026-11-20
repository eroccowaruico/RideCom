import AVFoundation
import Codec
import CryptoKit
import Foundation
import Logging
import OSLog
import RTC
import SessionManager
import SoundIsolation
import VADGate

extension IntercomViewModel {
    var isInternetOnlyCall: Bool {
        if !availableCallRoutes.isEmpty { return availableCallRoutes == [.webRTC] }
        return enabledRTCTransportRoutes == [.webRTC]
    }

    var connectionLabel: String {
        if hasPresentedAuthenticatedConnection && !isCallMediaStarted {
            return "\(connectionState.label) / Audio Idle"
        }
        return connectionState.label
    }

    var selectedGroupConnectionState: CallConnectionState {
        presentedConnectionState
    }

    var callPresenceLabel: String {
        if selectedGroup?.id == activeGroupID, isAudioPausedForDeviceChange {
            return hasPresentedAuthenticatedConnection ? "Connected / Audio Paused" : String(localized: "Audio paused")
        }
        let connectionState = presentedConnectionState
        let localNetworkStatus = presentedLocalNetworkStatus
        if connectionState == .idle, localNetworkStatus != .idle {
            return "Waiting for Riders"
        }
        if hasPresentedAuthenticatedConnection && !isCallMediaStarted {
            return "Connected / Audio Idle"
        }
        return connectionState.label
    }

    var canDisconnectCall: Bool {
        guard selectedGroup?.id == activeGroupID else { return false }
        return connectionState != .idle || isAudioReady || !authenticatedPeerIDs.isEmpty || localNetworkStatus != .idle
    }

    var routeLabel: String {
        if selectedGroup?.id == activeGroupID, !availableCallRoutes.isEmpty {
            let path = availableCallRoutes.contains(.multipeer)
                ? (availableCallRoutes.contains(.webRTC) ? "Local + Internet / Relay" : "Local / Relay available")
                : "Internet"
            return isAudioPausedForDeviceChange ? "\(path) / Audio Paused" : path
        }
        if hasPresentedAuthenticatedConnection && !isCallMediaStarted {
            switch presentedConnectionState {
            case .localConnected, .localConnecting:
                return "Local / Control Only"
            case .internetConnected, .internetConnecting:
                return "Internet / Control Only"
            case .idle, .reconnectingOffline:
                return "Offline"
            }
        }
        return switch presentedConnectionState {
        case .localConnected, .localConnecting:
            TransportRoute.local.rawValue
        case .internetConnected, .internetConnecting:
            TransportRoute.internet.rawValue
        case .idle, .reconnectingOffline:
            "Offline"
        }
    }

    var supportsSoundIsolation: Bool {
        VoiceIsolationSupport.isAvailable
    }

    var selectedTransmitCodec: AudioCodecIdentifier {
        AudioCodecIdentifier(rawValue: codecRuntimeReport.selectedCodec.rawValue)
    }

    private var selectedGroupSummary: String {
        guard let selectedGroup else { return "GROUP -- / MEMBERS 0" }
        return "GROUP \(selectedGroup.id.uuidString.prefix(8)) / MEMBERS \(selectedGroup.members.count)"
    }

    private var inviteSummary: String {
        groupErrorMessage ?? inviteStatusMessage ?? (canShareSelectedGroup ? "INVITE READY" : "INVITE NONE")
    }

    var diagnosticsOverviewRows: [DiagnosticsOverviewRow] {
        [
            DiagnosticsOverviewRow(
                id: "media",
                title: "Audio Path",
                icon: "waveform",
                summary: "Shared packet audio",
                detail: "SessionManager → Mixer / effects → Codec → Local / Internet relay",
                severity: .neutral,
                accessibilityIdentifier: "audioPathSummary"
            ),
            DiagnosticsOverviewRow(
                id: "call",
                title: "Call",
                icon: "checklist",
                summary: "CALL \(connectionLabel)",
                detail: selectedGroupSummary,
                severity: canDisconnectCall ? .ok : .neutral,
                accessibilityIdentifier: "realDeviceCallDebugSummaryLabel"
            ),
            DiagnosticsOverviewRow(
                id: "network",
                title: "Network Quality",
                icon: "clock.arrow.circlepath",
                summary: networkQualitySummary,
                detail: networkQualityDetail,
                severity: networkQualitySeverity,
                accessibilityIdentifier: "receptionDebugSummaryLabel"
            ),
            DiagnosticsOverviewRow(
                id: "invite",
                title: "Invite",
                icon: "square.and.arrow.up",
                summary: inviteSummary,
                detail: selectedGroupSummary,
                severity: canShareSelectedGroup ? .ok : .neutral,
                accessibilityIdentifier: "inviteDebugSummaryLabel"
            )
        ]
    }

    private var networkQualitySummary: String {
        guard let lastRouteMetrics else {
            return "NETWORK WAITING"
        }
        let rtt = lastRouteMetrics.rtt.map { String(format: "RTT %.0fms", $0 * 1_000) } ?? "RTT --"
        let loss = lastRouteMetrics.packetLoss.map { String(format: "LOSS %.1f%%", $0 * 100) } ?? "LOSS --"
        return "\(rtt) / \(loss)"
    }

    private var networkQualityDetail: String {
        if let internetFailureDetail { return "Internet: \(internetFailureDetail)" }
        guard let lastRouteMetrics else {
            return "No route metrics yet"
        }
        return lastRouteMetrics.jitter.map { String(format: "JITTER %.0fms", $0 * 1_000) } ?? "JITTER --"
    }

    private var networkQualitySeverity: DiagnosticsSeverity {
        if internetFailureDetail != nil { return .warning }
        guard let lastRouteMetrics, lastRouteMetrics.rtt != nil || lastRouteMetrics.packetLoss != nil || lastRouteMetrics.jitter != nil else { return .neutral }
        if (lastRouteMetrics.packetLoss ?? 0) > 0.05 {
            return .warning
        }
        return .ok
    }

    var connectedPeerCount: Int {
        connectedPeerIDs.count
    }

    var authenticatedPeerCount: Int {
        authenticatedPeerIDs.count
    }


}

struct DiagnosticsOverviewRow: Equatable, Identifiable {
    let id: String
    let title: String
    let icon: String
    let summary: String
    let detail: String
    let severity: DiagnosticsSeverity
    let accessibilityIdentifier: String
}

enum DiagnosticsSeverity: Equatable {
    case neutral
    case ok
    case warning
    case error
}
