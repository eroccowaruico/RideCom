#if !os(watchOS)
import Foundation
import Network

enum LocalControlEvent: Equatable, Sendable {
    case state(RouteConnectionState)
    /// Everyone who has proved the group key and is connected now.
    case members([PeerID])
    /// A member joined, or returned on a new connection. `nonce` names its UDP audio listener.
    case authenticated(PeerID, nonce: String)
    case lost(PeerID)
    case message(Data, PeerID)
    case failed(String)
    case handshakeRejected
}

/// Browses for a shared group or for offers from known peers. A group member or a node making
/// addressed offers advertises one QUIC listener with a new name and certificate for each start.
final class LocalControlTransport: @unchecked Sendable {
    static let serviceType = "_ride-control._udp"
    static let groupHashKey = "g"
    static let maximumPeers = 7
    static let redialDelay: TimeInterval = 2

    private enum Discovery {
        case shared(RTCCredential)
        case addressed(known: [PeerID: RTCCredential], offered: [PeerID: RTCCredential])
    }

    private struct Destination {
        let endpoint: NWEndpoint
        let authentication: LocalControlLink.Authentication
    }

    private let localID: PeerID
    private let discovery: Discovery
    private let nonce: String
    private let onEvent: @Sendable (LocalControlEvent) -> Void
    private let queue = DispatchQueue(label: "RideIntercom.LocalControlTransport")

    // Everything below is touched on `queue` only.
    private var generation = UUID()
    /// Not a device or person name. It only orders the two ends of a pair: the smaller name dials.
    private var serviceName = ""
    private var identity: LocalControlIdentity?
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var groups: [ObjectIdentifier: NWConnectionGroup] = [:]
    private var dialed: [String: LocalControlLink] = [:]
    private var visible: [String: Destination] = [:]
    private var pending: [ObjectIdentifier: LocalControlLink] = [:]
    private var members: [PeerID: LocalControlLink] = [:]
    private var hadMembers = false

    /// - Parameter nonce: names this end's UDP audio listener; peers receive it in the handshake.
    init(
        localID: PeerID, credential: RTCCredential, nonce: String,
        onEvent: @escaping @Sendable (LocalControlEvent) -> Void
    ) {
        self.localID = localID; self.discovery = .shared(credential); self.nonce = nonce; self.onEvent = onEvent
    }

    init(localID: PeerID, knownPeers: [PeerID: RTCCredential], offeredPeers: Set<PeerID>,
         onEvent: @escaping @Sendable (LocalControlEvent) -> Void) {
        let known = knownPeers.filter { $0.key != localID && $0.key.isValidRelayID }
        self.localID = localID
        self.discovery = .addressed(known: known, offered: known.filter { offeredPeers.contains($0.key) })
        self.nonce = UUID().uuidString
        self.onEvent = onEvent
    }

    func start() {
        queue.async { [self] in
            stopOnQueue()
            let token = UUID()
            generation = token
            serviceName = UUID().uuidString
            onEvent(.state(.connecting))
            do {
                let identity = try LocalControlIdentity.make()
                self.identity = identity
                switch discovery {
                case .shared(let credential):
                    try startListener(
                        identity: identity, advertisement: NWTXTRecord([Self.groupHashKey: credential.groupHash]),
                        authentication: .shared(credential), token: token
                    )
                case .addressed(let known, let offered):
                    guard localID.isValidRelayID, offered.count <= Self.maximumPeers else {
                        onEvent(.failed("Invalid local data offers"))
                        return
                    }
                    guard !known.isEmpty else { return }
                    if !offered.isEmpty {
                        let advertisement = LocalAddressedAdvertisement(
                            name: serviceName, fingerprint: identity.fingerprint, credentials: offered.values
                        )
                        try startListener(identity: identity, advertisement: advertisement.record,
                                          authentication: .accepting(offered), token: token)
                    }
                }

                let parameters = NWParameters()
                parameters.includePeerToPeer = true
                let browser = NWBrowser(
                    for: .bonjourWithTXTRecord(type: Self.serviceType, domain: nil), using: parameters
                )
                browser.browseResultsChangedHandler = { [weak self] results, _ in
                    guard let self, self.generation == token else { return }
                    self.visible = self.destinations(in: results)
                    self.dialVisible(token: token)
                }
                browser.stateUpdateHandler = { [weak self] state in
                    guard let self, self.generation == token, case .failed = state else { return }
                    self.onEvent(.failed("Local control discovery unavailable"))
                }
                browser.start(queue: queue)
                self.browser = browser
            } catch {
                onEvent(.failed("Local control could not start"))
            }
        }
    }

    private func startListener(identity: LocalControlIdentity, advertisement: NWTXTRecord,
                               authentication: LocalControlLink.Authentication, token: UUID) throws {
        let listener = try NWListener(using: LocalControlTLS.parameters(identity: identity), on: .any)
        listener.service = .init(name: serviceName, type: Self.serviceType, domain: nil, txtRecord: advertisement)
        // A QUIC listener hands over the connection as a group; its streams arrive through the group.
        listener.newConnectionGroupHandler = { [weak self] group in
            guard let self, self.generation == token else { group.cancel(); return }
            if case .accepting = authentication, self.groups.count >= 2 * Self.maximumPeers { group.cancel(); return }
            let id = ObjectIdentifier(group)
            self.groups[id] = group
            group.stateUpdateHandler = { [weak self] state in
                guard let self, self.generation == token else { return }
                switch state {
                case .cancelled, .failed: self.groups.removeValue(forKey: id)?.cancel()
                default: break
                }
            }
            group.newConnectionHandler = { [weak self] stream in
                guard let self, self.generation == token else { stream.cancel(); return }
                self.adopt(stream, authentication: authentication, dialedName: nil, token: token)
            }
            group.start(queue: self.queue)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, self.generation == token, case .failed = state else { return }
            self.onEvent(.failed("Local control listener unavailable"))
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() { queue.async { [self] in stopOnQueue() } }

    /// A shared group may broadcast to its connected members. Addressed traffic requires a target.
    func send(_ message: Data) {
        guard case .shared = discovery else { return }
        queue.async { [self] in members.values.forEach { $0.send(message) } }
    }

    func send(_ message: Data, to peer: PeerID) {
        queue.async { [self] in members[peer]?.send(message) }
    }

    private func stopOnQueue() {
        generation = UUID()
        listener?.cancel(); listener = nil
        browser?.cancel(); browser = nil
        let links = Array(pending.values) + Array(members.values)
        pending.removeAll(); members.removeAll(); dialed.removeAll(); visible.removeAll()
        links.forEach { $0.close() }
        groups.values.forEach { $0.cancel() }; groups.removeAll()
        identity = nil
        if hadMembers { hadMembers = false; onEvent(.members([])); onEvent(.state(.disconnected)) }
    }

    private func destinations(in results: Set<NWBrowser.Result>) -> [String: Destination] {
        var found: [String: Destination] = [:]
        for result in results {
            guard case .service(let name, _, _, _) = result.endpoint, name != serviceName,
                  case .bonjour(let record) = result.metadata else { continue }
            let authentication: LocalControlLink.Authentication
            switch discovery {
            case .shared(let credential):
                guard serviceName < name, record[Self.groupHashKey] == credential.groupHash else { continue }
                authentication = .shared(credential)
            case .addressed(let known, let offered):
                guard let advertisement = LocalAddressedAdvertisement(
                    name: name, record: record, maximumOffers: Self.maximumPeers
                ),
                      let (peer, credential) = known.first(where: { advertisement.offers($0.value) }),
                      offered[peer] == nil || serviceName < name
                else { continue }
                authentication = .dialing(credential, peer: peer, fingerprint: advertisement.fingerprint)
            }
            found[name] = Destination(endpoint: result.endpoint, authentication: authentication)
        }
        return found
    }

    /// For mutual offers the smaller service name dials. For a one-way offer the recipient dials.
    private func dialVisible(token: UUID) {
        guard let identity else { return }
        for (name, destination) in visible where dialed[name] == nil {
            if case .addressed = discovery, pending.count >= 2 * Self.maximumPeers { return }
            adopt(NWConnection(to: destination.endpoint, using: LocalControlTLS.parameters(identity: identity)),
                  authentication: destination.authentication, dialedName: name, token: token)
        }
    }

    private func adopt(_ connection: NWConnection, authentication: LocalControlLink.Authentication,
                       dialedName: String?, token: UUID) {
        guard let identity else { connection.cancel(); return }
        if case .addressed = discovery, pending.count >= 2 * Self.maximumPeers { connection.cancel(); return }
        // The link reports on this queue; it is identified by itself, since a name is not an identity.
        let box = LinkBox()
        let link = LocalControlLink(
            connection: connection, identity: identity, authentication: authentication, localID: localID,
            nonce: nonce, queue: queue
        ) { [weak self] event in
            guard let self, self.generation == token, let link = box.link else { return }
            self.handle(event, from: link, dialedName: dialedName, token: token)
        }
        box.link = link
        pending[ObjectIdentifier(link)] = link
        if let dialedName { dialed[dialedName] = link }
        link.start()
    }

    private func handle(
        _ event: LocalControlLink.Event, from link: LocalControlLink, dialedName: String?, token: UUID
    ) {
        switch event {
        case .authenticated(let peer, let nonce):
            pending[ObjectIdentifier(link)] = nil
            let previous = members[peer]
            guard previous != nil || members.count < Self.maximumPeers else { link.close(); return }
            // A member that returns on a new connection has restarted: the new connection replaces the old.
            members[peer] = link
            previous?.close()
            hadMembers = true
            onEvent(.authenticated(peer, nonce: nonce))
            onEvent(.members(Array(members.keys)))
            onEvent(.state(.authenticated))
        case .message(let data):
            guard let peer = members.first(where: { $0.value === link })?.key else { return }
            onEvent(.message(data, peer))
        case .handshakeRejected:
            onEvent(.handshakeRejected)
        case .closed:
            pending[ObjectIdentifier(link)] = nil
            if let dialedName, dialed[dialedName] === link {
                dialed[dialedName] = nil
                // Still advertised: the attempt failed or the connection dropped. Try again shortly.
                queue.asyncAfter(deadline: .now() + Self.redialDelay) { [weak self] in
                    guard let self, self.generation == token else { return }
                    self.dialVisible(token: token)
                }
            }
            guard let peer = members.first(where: { $0.value === link })?.key else { return }
            members[peer] = nil
            onEvent(.lost(peer))
            onEvent(.members(Array(members.keys)))
            onEvent(.state(members.isEmpty ? .disconnected : .authenticated))
        }
    }

    private final class LinkBox: @unchecked Sendable { weak var link: LocalControlLink? }
}
#endif
