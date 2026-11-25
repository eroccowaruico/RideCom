import Foundation

public enum RouteEvent: Equatable, Sendable {
    var isTransient: Bool {
        switch self {
        case .metricsChanged: return true
        case .receivedApplicationData(_, let received): return received.message.delivery == .unreliable
        default: return false
        }
    }

    case stateChanged(RouteKind, RouteConnectionState)
    case availabilityChanged(RouteAvailability)
    case membersChanged(RouteKind, [CallMemberState])
    case receivedApplicationData(RouteKind, ReceivedApplicationData)
    case metricsChanged(RouteMetrics)
    case error(RouteKind, CallSessionError)
    /// Stops retries until the blocking condition has been addressed.
    case connectionBlocked(RouteKind, ConnectionBlockReason)
    /// The old attempt was cleaned up and a replacement credential is ready.
    case deviceCredentialUpdated(RouteKind)
}

public struct RTCRouteSendResult: Sendable {
    /// Whether this backend accepted the send. Nil means acceptance was unavailable.
    public var transportAccepted: Bool?
    /// Peers eligible to suppress an alternate copy. Local requires acceptance
    /// and a recent authenticated receipt; this does not acknowledge this packet.
    public var verifiedLocalRecipients: Set<PeerID>

    public init(transportAccepted: Bool? = nil, verifiedLocalRecipients: Set<PeerID> = []) {
        self.transportAccepted = transportAccepted
        self.verifiedLocalRecipients = verifiedLocalRecipients
    }
}

public protocol RTCCallRoute: AnyObject, Sendable {
    var kind: RouteKind { get }
    var capabilities: RouteCapabilities { get }
    var events: AsyncStream<RouteEvent> { get }

    func networkDiagnostics() async -> RTCRouteNetworkDiagnostics
    func prepare(_ request: CallStartRequest) async
    func startConnection() async
    func stopConnection() async
    @discardableResult
    func sendApplicationData(_ message: ApplicationDataMessage) async -> RTCRouteSendResult
}

protocol DeviceCredentialRecoveringRoute: RTCCallRoute {
    func requestCredentialRecovery() async
}

protocol AuthenticatedInternetPeerObserving: AnyObject, Sendable {
    func observeAuthenticatedInternetPeer(_ peer: PeerID, callID: String) async
}

public extension RTCCallRoute {
    /// Routes without a metrics backend explicitly report unavailability.
    func networkDiagnostics() async -> RTCRouteNetworkDiagnostics { .init(route: kind) }
}
