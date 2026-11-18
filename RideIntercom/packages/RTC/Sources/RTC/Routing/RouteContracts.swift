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
    /// Prevent automatic retries for this route until the next prepare.
    case connectionBlocked(RouteKind, String)
}

public protocol RTCCallRoute: AnyObject, Sendable {
    var kind: RouteKind { get }
    var capabilities: RouteCapabilities { get }
    var events: AsyncStream<RouteEvent> { get }

    func networkDiagnostics() async -> RTCRouteNetworkDiagnostics
    func prepare(_ request: CallStartRequest) async
    func startConnection() async
    func stopConnection() async
    /// Direct peers eligible to suppress an alternate media copy for this send.
    /// Local requires immediate acceptance and recent authenticated media receipt;
    /// this is not an acknowledgement of the current frame. Return an empty set
    /// when the backend cannot establish individual recipients.
    @discardableResult
    func sendApplicationData(_ message: ApplicationDataMessage) async -> Set<PeerID>
}

public extension RTCCallRoute {
    /// Routes without a metrics backend explicitly report unavailability.
    func networkDiagnostics() async -> RTCRouteNetworkDiagnostics { .init(route: kind) }
}
