#if !os(watchOS)
import Foundation

public actor LocalCallRoute: RTCCallRoute {
    public let kind: RouteKind = .multipeer
    public nonisolated let capabilities = RouteCapabilities(
        supportsLocalDiscovery: true, supportsOfflineOperation: true,
        supportsReliableApplicationData: true, supportsUnreliableApplicationData: true,
        requiresSignaling: false, supportedAudioCodecs: [.pcm16, .opus, .mpeg4AACELD, .mpeg4AACELDv2],
        backendName: "Local UDP / QUIC control")
    public nonisolated var events: AsyncStream<RouteEvent> { source.stream }
    private let source = EventSource<RouteEvent>(isTransient: { $0.isTransient }, overflowEvent: .stateChanged(.multipeer, .failed))
    private var request: CallStartRequest?
    private var session: Session?

    public init() {}
    deinit { session?.stop() }

    public func networkDiagnostics() async -> RTCRouteNetworkDiagnostics {
        .init(route: kind, statistics: session?.datagrams.statistics ?? .init(), eventDrops: ["route": source.report])
    }

    public func prepare(_ request: CallStartRequest) {
        session?.stop()
        session = nil
        self.request = nil
        source.resetDiagnostics()
        guard request.localPeer.id.isValidRelayID, request.credential != nil else {
            source.yield(.error(kind, .connectionFailed(kind, "Local identity and group credential required")))
            source.yield(.stateChanged(kind, .failed))
            return
        }
        self.request = request
        source.yield(.availabilityChanged(.init(route: kind, isAvailable: true)))
        source.yield(.stateChanged(kind, .standby))
    }

    public func startConnection() {
        guard let request, let credential = request.credential else { return }
        session?.stop()
        let session = Session(peer: request.localPeer.id, credential: credential, source: source)
        self.session = session
        session.start()
    }

    public func stopConnection() {
        session?.stop()
        session = nil
        request = nil
        source.yield(.stateChanged(kind, .disconnected))
    }

    public func sendApplicationData(_ message: ApplicationDataMessage) -> RTCRouteSendResult {
        session?.send(message) ?? .init(transportAccepted: false)
    }
}

// The UDP queue owns membership and delivery for one call generation. Retiring
// the generation there also fences callbacks from an asynchronously closing QUIC link.
private final class Session: @unchecked Sendable {
    private let peer: PeerID
    private let credential: RTCCredential
    private let source: EventSource<RouteEvent>
    private let kind = RouteKind.multipeer
    private var active = true
    private var controlPeers: Set<PeerID> = []
    private var mediaPeers: Set<PeerID> = []
    private var control: LocalControlTransport?
    private(set) lazy var datagrams = LocalDatagramTransport(peerID: peer, credential: credential) { [weak self] peer, bytes in
        guard let self, self.active, self.mediaPeers.contains(peer) else { return }
        self.deliver(.init(namespace: GroupRelay.namespace, payload: bytes, delivery: .unreliable), from: peer)
    }

    init(peer: PeerID, credential: RTCCredential, source: EventSource<RouteEvent>) {
        self.peer = peer
        self.credential = credential
        self.source = source
    }

    func start() {
        datagrams.synchronized {
            datagrams.onFailure = { [weak self] _ in
                guard let self, self.active else { return }
                self.fail("Local UDP listener unavailable")
            }
            do { try datagrams.start() }
            catch { fail("Local UDP listener could not start"); return }
            let control = LocalControlTransport(localID: peer, credential: credential, nonce: datagrams.serviceNonce) { [weak self] event in
                guard let self else { return }
                self.datagrams.synchronized { if self.active { self.handle(event) } }
            }
            self.control = control
            control.start()
        }
    }

    func stop() {
        datagrams.synchronized {
            guard active else { return }
            active = false
            datagrams.stop()
            control?.stop()
        }
    }

    func send(_ message: ApplicationDataMessage) -> RTCRouteSendResult {
        if message.namespace == GroupRelay.namespace, message.delivery == .unreliable {
            return datagrams.synchronized {
                let send = datagrams.send(message.payload, to: Array(mediaPeers))
                return .init(transportAccepted: !send.accepted.isEmpty, verifiedLocalRecipients: send.verified)
            }
        }
        guard let bytes = try? JSONEncoder().encode(message), bytes.count <= LocalControlFraming.maximumMessageBytes else {
            source.yield(.error(kind, .connectionFailed(kind, "Local control message exceeds frame limit")))
            return .init(transportAccepted: false)
        }
        control?.send(bytes)
        return .init()
    }

    private func handle(_ event: LocalControlEvent) {
        switch event {
        case .authenticated(let peer, let nonce):
            if !mediaPeers.contains(peer), mediaPeers.count >= LocalControlTransport.maximumPeers,
               let expired = mediaPeers.subtracting(controlPeers).first {
                mediaPeers.remove(expired)
                datagrams.remove(expired)
            }
            controlPeers.insert(peer)
            mediaPeers.insert(peer)
            datagrams.connect(to: peer, nonce: nonce)
        case .lost(let peer):
            controlPeers.remove(peer)
        case .members:
            let members = mediaPeers.map { CallMemberState(peer: .init(id: $0, displayName: $0.rawValue), route: kind, isConnected: true) }
            source.yield(.membersChanged(kind, members))
            source.yield(.metricsChanged(.init(route: kind, activePeerCount: members.count)))
        case .state(let state):
            source.yield(.stateChanged(kind, state == .disconnected && !mediaPeers.isEmpty ? .authenticated : state))
        case .message(let data, let peer):
            if let message = try? JSONDecoder().decode(ApplicationDataMessage.self, from: data),
               message.namespace != GroupRelay.namespace || message.delivery != .unreliable {
                deliver(message, from: peer)
            }
        case .handshakeRejected:
            source.yield(.error(kind, .handshakeRejected(kind)))
        case .failed(let reason):
            fail(reason)
        }
    }

    private func deliver(_ message: ApplicationDataMessage, from peer: PeerID) {
        source.yield(.receivedApplicationData(kind, .init(peerID: peer, message: message)))
    }

    private func fail(_ reason: String) {
        // Retire both native transports before a queued QUIC event can mark the failed route available.
        stop()
        source.yield(.error(kind, .connectionFailed(kind, reason)))
        source.yield(.stateChanged(kind, .failed))
    }
}
#endif
