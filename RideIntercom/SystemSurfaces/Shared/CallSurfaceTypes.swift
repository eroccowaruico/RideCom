import CallControl
import Foundation

nonisolated enum CallSurfaceKind: String {
    case selectedWidget = "RideIntercom.SelectedCall"
    case destinationControl = "RideIntercom.DestinationCall"
}

nonisolated enum StandardCallStatus: String, Codable, Hashable, Sendable {
    case chooseDestination, ready, connecting, inCall, audioPaused, audioUnavailable
    var message: String {
        switch self {
        case .chooseDestination: "Choose someone or a group to call."
        case .ready: "Ready to connect"
        case .connecting: "Connecting — waiting for others"
        case .inCall: "In a call"
        case .audioPaused: "Audio paused — check your audio device"
        case .audioUnavailable: "Audio unavailable — check your settings"
        }
    }
    /// The state alone, for one line; `detail` puts the reason on the next line.
    var title: String {
        switch self {
        case .chooseDestination, .ready: "Ready to connect"
        case .connecting: "Connecting"
        case .inCall: "In a call"
        case .audioPaused: "Audio paused"
        case .audioUnavailable: "Audio unavailable"
        }
    }
    var detail: String? {
        switch self {
        case .connecting: "Waiting for others"
        case .audioPaused: "Check your audio device"
        case .audioUnavailable: "Check your settings"
        case .chooseDestination, .ready, .inCall: nil
        }
    }
}

nonisolated struct CallLivePresentation: Codable, Equatable, Sendable {
    let reference: CallSurfaceReference
    var status: StandardCallStatus
    var isMuted: Bool
    var canControlMicrophone: Bool = true
}

#if os(iOS)
import ActivityKit
nonisolated struct RideCallActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable {
        var status: StandardCallStatus
        var isMuted: Bool
        var canControlMicrophone: Bool = true
    }
    let reference: CallSurfaceReference
}
#endif
