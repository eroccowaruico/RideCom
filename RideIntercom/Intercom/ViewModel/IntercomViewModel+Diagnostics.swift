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

    var diagnosticsAppliedRows: [DiagnosticsAppliedRow] {
        let group = selectedGroupSummary
        return [
            DiagnosticsAppliedRow(
                id: "call",
                title: "Call",
                summary: "CALL \(connectionLabel)",
                detail: group
            ),
            DiagnosticsAppliedRow(
                id: "invite",
                title: "Invite",
                summary: inviteSummary,
                detail: group
            )
        ]
    }

    var connectedPeerCount: Int {
        connectedPeerIDs.count
    }

    var authenticatedPeerCount: Int {
        authenticatedPeerIDs.count
    }


}

struct DiagnosticsAppliedRow: Identifiable {
    let id: String
    let title: String
    let summary: String
    let detail: String
}
