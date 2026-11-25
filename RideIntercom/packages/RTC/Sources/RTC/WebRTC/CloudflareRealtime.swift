import Foundation

public struct CloudflareServiceStatus: Decodable, Equatable, Sendable {
    public let month: String
    public let reservedParticipantSeconds: Int
    public let monthlyParticipantSeconds: Int
    public let activeSessions: Int
}

public struct CloudflareRealtimeConfiguration: Equatable, Sendable {
    public var workerURL: URL
    public var accessToken: String
    public init(workerURL: URL, accessToken: String) {
        self.workerURL = workerURL
        self.accessToken = accessToken
    }

    var isValid: Bool {
        let url = workerURL
        return (url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host ?? "")))
            && url.host != nil && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
            && (url.path.isEmpty || url.path == "/") && !accessToken.isEmpty
    }
}

public struct WebRTCIceServer: Codable, Equatable, Sendable {
    public var urls: [String]
    public var username: String?
    public var credential: String?

    public init(urls: [String], username: String? = nil, credential: String? = nil) {
        self.urls = urls
        self.username = username
        self.credential = credential
    }
}

public struct WebRTCSessionDescription: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case offer
        case answer
    }

    public var kind: Kind
    public var sdp: String

    public init(kind: Kind, sdp: String) {
        self.kind = kind
        self.sdp = sdp
    }
}

public struct WebRTCSignalingConnectRequest: Equatable, Sendable {
    public var call: CallStartRequest
    public var cloudflare: CloudflareRealtimeConfiguration

    public init(call: CallStartRequest, cloudflare: CloudflareRealtimeConfiguration) {
        self.call = call
        self.cloudflare = cloudflare
    }
}
extension WebRTCSignalingConnectRequest {
    func replacingWorkerCredential(_ configuration: CloudflareRealtimeConfiguration?) -> Self {
        guard let configuration, configuration.workerURL == cloudflare.workerURL,
              !configuration.accessToken.isEmpty else { return self }
        return .init(call: call, cloudflare: configuration)
    }
}

public enum WebRTCSignalingEvent: Equatable, Sendable {
    case connected
    case iceServers([WebRTCIceServer])
    case dataChannels([WebRTCDataChannel])
    case members([PeerDescriptor])
    case disconnected
    case answer(WebRTCSessionDescription, from: PeerID)
    case receivedApplicationData(ReceivedApplicationData)
    case failed(String)
    /// The same attempt must not be retried until the cause has been resolved.
    case blocked(ConnectionBlockReason)
}

public protocol WebRTCSignalingClient: AnyObject, Sendable {
    var events: AsyncStream<WebRTCSignalingEvent> { get }

    func connect(_ request: WebRTCSignalingConnectRequest) async
    func disconnect() async
    func startPublishing() async
    func sendOffer(_ offer: WebRTCSessionDescription, to peerID: PeerID) async
    func sendApplicationData(_ message: ApplicationDataMessage, to peerID: PeerID?) async
}

public struct WebRTCDataChannel: Codable, Equatable, Sendable {
    public var id: Int32
    public var peerID: PeerID?
    public var isPublisher: Bool
    public var delivery: ApplicationDataDelivery
    public init(
        id: Int32, peerID: PeerID? = nil, isPublisher: Bool = false,
        delivery: ApplicationDataDelivery = .unreliable
    ) {
        self.id = id; self.peerID = peerID; self.isPublisher = isPublisher; self.delivery = delivery
    }
}
