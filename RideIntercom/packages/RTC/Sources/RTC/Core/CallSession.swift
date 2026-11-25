import Foundation

public struct CallStartRequest: Equatable, Sendable {
    public var sessionID: String
    public var localPeer: PeerDescriptor
    public var expectedPeers: [PeerDescriptor]
    public var credential: RTCCredential?
    public var configuration: CallRouteConfiguration
    public var audioPolicy: RTCAudioPolicy
    /// The original deadline carried in memory when rebuilding a call's routes.
    public var continuationDeadline: ContinuousClock.Instant?

    public init(
        sessionID: String,
        localPeer: PeerDescriptor,
        expectedPeers: [PeerDescriptor] = [],
        credential: RTCCredential? = nil,
        configuration: CallRouteConfiguration = CallRouteConfiguration(),
        audioPolicy: RTCAudioPolicy = RTCAudioPolicy()
    ) {
        self.sessionID = sessionID
        self.localPeer = localPeer
        self.expectedPeers = expectedPeers
        self.credential = credential
        self.configuration = configuration.normalized()
        self.audioPolicy = audioPolicy
    }
}

public protocol CallSession: AnyObject {
    var events: AsyncStream<CallSessionEvent> { get }

    func prepare(_ request: CallStartRequest) async
    func startConnection() async
    /// Reopens a credential-blocked Internet route when its provider has a replacement credential.
    func retryInternetRouteAfterCredentialChange() async
    func stopConnection() async
    func stopConnection(preservingContinuationIn replacement: CallStartRequest?) async -> CallStartRequest?
    func startMedia() async
    func stopMedia() async
    func sendAudioPacket(_ packet: RTCAudioPacket) async
    /// Reads the last local audio offer without requesting a report or sending any traffic.
    func lastOutboundAudioDispatch() async -> RTCOutboundAudioDispatch?
    func sendApplicationData(_ message: ApplicationDataMessage) async
    /// Changes packet policy without restarting transports or group authentication.
    func updateAudioPolicy(_ policy: RTCAudioPolicy) async
    func updateRuntimePackageReports(_ reports: [RTCRuntimePackageReport]) async
    func setLocalMute(_ muted: Bool) async
    func setOutputMute(_ muted: Bool) async
}

public extension CallSession {
    func retryInternetRouteAfterCredentialChange() async {}

    func stopConnection(preservingContinuationIn replacement: CallStartRequest?) async -> CallStartRequest? {
        await stopConnection()
        return replacement
    }

    func lastOutboundAudioDispatch() async -> RTCOutboundAudioDispatch? { nil }

    func updateRuntimePackageReports(_ reports: [RTCRuntimePackageReport]) async {
        _ = reports
    }
}
