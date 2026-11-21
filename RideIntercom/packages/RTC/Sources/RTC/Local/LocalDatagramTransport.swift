import CryptoKit
import Foundation
import Network

/// Connectionless media alongside reliable Local discovery/control. The payload
/// remains the authenticated, encrypted GroupRelay envelope; UDP adds no retry,
/// stream ordering, batching or backlog while an endpoint is unavailable.
final class LocalDatagramTransport: @unchecked Sendable {
    static let serviceType = "_ride-audio._udp"
    private let queue = DispatchQueue(label: "rtc.local.datagrams", qos: .userInteractive)
    private let queueKey = DispatchSpecificKey<Bool>()
    struct SendResult {
        var accepted: Set<PeerID> = []
        var verified: Set<PeerID> = []
    }
    private struct MediaPath {
        let authenticator: LocalMediaReceiptAuthenticator
        var window = LocalMediaReceiptWindow()
    }
    private var paths: [ObjectIdentifier: MediaPath] = [:]
    private var peerNonces: [PeerID: String] = [:]
    private let credential: RTCCredential
    private let peerID: PeerID
    private let prefix: String
    private let onReceive: @Sendable (PeerID, Data) -> Void
    var onAvailabilityChange: (@Sendable () -> Void)?
    var onServiceChange: (@Sendable (NWEndpoint?) -> Void)?
    var onFailure: (@Sendable (String) -> Void)?
    private var listener: NWListener?
    private var generation = UUID()
    private var outgoing: [String: NWConnection] = [:]
    private var replacements: [String: NWConnection] = [:]
    private var retryAfter: [String: ConnectionRetry] = [:]
    private var ready: Set<String> = []
    private let incoming = LocalDatagramReceiver()
    private var endpoints: [String: NWEndpoint] = [:]
    private var sent: UInt64 = 0
    private var received: UInt64 = 0
    private var inFlight: [String: Int] = [:]
    private var peerServiceNames: [PeerID: String] = [:]

    init(peerID: PeerID, credential: RTCCredential, onReceive: @escaping @Sendable (PeerID, Data) -> Void) {
        self.peerID = peerID
        self.credential = credential
        prefix = Self.digest(credential.groupHash, length: 12)
        self.onReceive = onReceive
        queue.setSpecific(key: queueKey, value: true)
    }

    // Native callbacks run on this queue. Reentrant send/stop must not sync
    // onto the same queue; pair cipher state uses this owner as well.
    func synchronized<T>(_ operation: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) == true { return try operation() }
        return try queue.sync(execute: operation)
    }

    func serviceName(for peer: PeerID) -> String {
        prefix + "-" + Self.digest(peer.rawValue, length: 20)
    }
    private static func digest(_ value: String, length: Int) -> String {
        String(SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(length))
    }
    private func advertisedName(for peer: PeerID, nonce: String) -> String {
        serviceName(for: peer) + "-" + Self.digest(nonce, length: 12)
    }
    var serviceNonce: String { synchronized { generation.uuidString } }
    var port: NWEndpoint.Port? { synchronized { listener?.port.flatMap { $0.rawValue == 0 ? nil : $0 } } }
    func isReady(for peer: PeerID) -> Bool { synchronized { ready.contains(serviceName(for: peer)) } }
    func hasRecentMediaReceipt(for peer: PeerID) -> Bool {
        synchronized { hasRecentReceipt(serviceName(for: peer)) }
    }
    private func hasRecentReceipt(_ name: String) -> Bool {
        guard ready.contains(name), let connection = outgoing[name], case .ready = connection.state else {
            return false
        }
        return paths[ObjectIdentifier(connection)]?.window.isRecent(at: ProcessInfo.processInfo.systemUptime) == true
    }

    var statistics: RTCNetworkStatistics {
        synchronized {
            let recentReceipts = outgoing.keys.filter { hasRecentReceipt($0) }.count
            let unavailableReason = "Sampled media receipts do not provide per-packet RTT or network loss estimates; "
                + "registered endpoints: \(endpoints.count), recent media receipts: \(recentReceipts)"
            var result = RTCNetworkStatistics(bufferedBytes: UInt64(inFlight.values.reduce(0, +)),
                unavailableReason: unavailableReason)
            result.sentMediaDatagrams = sent; result.receivedMediaDatagrams = received
            return result
        }
    }

    func start() throws {
        try synchronized {
            stopOnQueue()
            let token = generation
            let parameters = Self.parameters()
            let listener = try NWListener(using: parameters)
            listener.service = .init(name: advertisedName(for: peerID, nonce: token.uuidString), type: Self.serviceType)
            listener.serviceRegistrationUpdateHandler = { [weak self] change in
                guard let self, self.generation == token else { return }
                switch change {
                case .add(let endpoint): self.onServiceChange?(endpoint)
                case .remove: self.onServiceChange?(nil)
                @unknown default: break
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, self.generation == token else { return }
                if case .failed(let error) = state { self.onFailure?("Local UDP listener unavailable: \(error)") }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.generation == token else { connection.cancel(); return }
                self.incoming.accept(connection, on: self.queue) { [weak self] sender, data in
                    self?.makeReceipt(to: sender, data: data, generation: token)
                } onReceive: { [weak self] sender, payload in
                    guard let self else { return }
                    self.received += 1
                    self.onReceive(sender, payload)
                }
            }
            self.listener = listener
            listener.start(queue: queue)
        }
    }

    /// QUIC control owns discovery and authentication. Resolve only that known
    /// peer's service; a second continuous P2P browser costs power and is redundant.
    func connect(to peer: PeerID, nonce: String) {
        guard peer != peerID, peer.isValidRelayID, (1...128).contains(nonce.utf8.count) else { return }
        let name = serviceName(for: peer)
        synchronized {
            guard listener != nil, endpoints[name] != nil || endpoints.count < 7 else { return }
            let previousNonce = peerNonces[peer]
            if let previousNonce, previousNonce != nonce { removeOutgoing(name) }
            // Authentication authorizes a fresh resolution, not media delivery.
            // Ordinary audio never clears a failed connection's backoff.
            retryAfter[name] = nil
            peerNonces[peer] = nonce
            // An explicit test address belongs to this authenticated listener
            // generation. Its proxy keeps one client address for return traffic.
            if previousNonce == nonce, let current = endpoints[name], case .hostPort = current {
                connectOnQueue(peer: peer, nonce: nonce, endpoint: current)
                return
            }
            // A new authenticated control session may belong to a restarted
            // peer with a new UDP port. The signed nonce selects a fresh service
            // name, so stale Bonjour port caches cannot redirect new speech.
            // OS ready can persist without delivery. Resolve afresh; retain a
            // proven flow until its replacement receives new live media.
            connectOnQueue(peer: peer, nonce: nonce,
                endpoint: .service(
                    name: advertisedName(for: peer, nonce: nonce), type: Self.serviceType, domain: "local.",
                    interface: nil),
                replacing: outgoing[name] != nil)
        }
    }

    func remove(_ peer: PeerID) {
        synchronized {
            let name = serviceName(for: peer)
            removeOutgoing(name)
            endpoints[name] = nil
            peerServiceNames[peer] = nil
            peerNonces[peer] = nil
        }
    }

    func connect(to peer: PeerID, nonce: String, endpoint: NWEndpoint) {
        guard peer != peerID, peer.isValidRelayID, (1...128).contains(nonce.utf8.count) else { return }
        synchronized {
            guard listener != nil, endpoints[serviceName(for: peer)] != nil || endpoints.count < 7 else { return }
            if let previous = peerNonces[peer], previous != nonce { removeOutgoing(serviceName(for: peer)) }
            peerNonces[peer] = nonce
            connectOnQueue(peer: peer, nonce: nonce, endpoint: endpoint)
        }
    }
    private func connectOnQueue(peer: PeerID, nonce: String, endpoint: NWEndpoint, replacing: Bool = false) {
        let serviceName = serviceName(for: peer)
        guard peerNonces[peer] == nonce, listener != nil, endpoints[serviceName] != nil || endpoints.count < 7
        else { return }
        if let current = endpoints[serviceName], current != endpoint { removeOutgoing(serviceName) }
        endpoints[serviceName] = endpoint
        guard replacements[serviceName] == nil,
              outgoing[serviceName] == nil || replacing,
              outgoing[serviceName] != nil || outgoing.count < 7,
              ProcessInfo.processInfo.systemUptime >= (retryAfter[serviceName]?.deadline ?? 0) else { return }
        let connection = NWConnection(to: endpoint, using: Self.parameters())
        if replacing { replacements[serviceName] = connection } else { outgoing[serviceName] = connection }
        paths[ObjectIdentifier(connection)] = .init(authenticator: .init(credential: credential,
            sender: peerID, receiver: peer, senderNonce: generation.uuidString, receiverNonce: nonce))
        let token = generation
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            self.updateState(state, connection: connection, serviceName: serviceName, generation: token)
        }
        connection.betterPathUpdateHandler = { [weak self, weak connection] better in
            guard better, let self, let connection, self.generation == token,
                  self.outgoing[serviceName] === connection else { return }
            // UDP does not migrate automatically. Keep a proven old flow until
            // its replacement receives live media; never hold or replay audio.
            self.connectOnQueue(peer: peer, nonce: nonce, endpoint: endpoint, replacing: true)
        }
        connection.viabilityUpdateHandler = { [weak self, weak connection] viable in
            guard let self, let connection, self.generation == token,
                  self.outgoing[serviceName] === connection else { return }
            defer { self.onAvailabilityChange?() }
            if viable {
                self.markReady(connection, name: serviceName)
            } else {
                self.invalidateReceipt(connection, name: serviceName)
                self.connectOnQueue(peer: peer, nonce: nonce, endpoint: endpoint, replacing: true)
            }
        }
        connection.start(queue: queue)
        receiveReceipt(connection, name: serviceName, generation: token)
    }

    private func makeReceipt(to sender: PeerID, data: Data, generation token: UUID) -> Data? {
        guard let senderNonce = peerNonces[sender] else { return nil }
        let authenticator = LocalMediaReceiptAuthenticator(credential: credential, sender: sender, receiver: peerID,
            senderNonce: senderNonce, receiverNonce: token.uuidString)
        return authenticator.make(digest: Data(SHA256.hash(data: data)))
    }

    private func removeOutgoing(_ name: String) {
        ready.remove(name); inFlight[name] = nil
        if let connection = outgoing.removeValue(forKey: name) {
            paths[ObjectIdentifier(connection)] = nil; connection.cancel()
        }
        if let connection = replacements.removeValue(forKey: name) {
            paths[ObjectIdentifier(connection)] = nil; connection.cancel()
        }
        retryAfter[name] = nil
    }

    func stop() { synchronized { stopOnQueue() } }
    private func stopOnQueue() {
        generation = UUID()
        listener?.cancel(); listener = nil
        for connection in outgoing.values { connection.cancel() }
        for connection in replacements.values { connection.cancel() }
        incoming.stop()
        outgoing.removeAll(); ready.removeAll(); inFlight.removeAll(); endpoints.removeAll()
        replacements.removeAll(); retryAfter.removeAll(); peerServiceNames.removeAll(); peerNonces.removeAll()
        paths.removeAll()
        sent = 0; received = 0
        onAvailabilityChange?()
    }
}

extension LocalDatagramTransport {
    private func markReady(_ connection: NWConnection, name: String) {
        if case .ready = connection.state { ready.insert(name) }
    }

    private func invalidateReceipt(_ connection: NWConnection, name: String) {
        ready.remove(name)
        paths[ObjectIdentifier(connection)]?.window = .init()
    }

    private func updateState(
        _ state: NWConnection.State, connection: NWConnection, serviceName: String, generation token: UUID
    ) {
        guard generation == token,
            outgoing[serviceName] === connection || replacements[serviceName] === connection
        else { return }
        defer { onAvailabilityChange?() }
        switch state {
        case .ready:
            if replacements[serviceName] === connection, !hasRecentReceipt(serviceName) {
                promote(connection, name: serviceName)
            }
            retryAfter[serviceName] = nil
            if outgoing[serviceName] === connection { ready.insert(serviceName) }
        case .failed, .cancelled:
            paths[ObjectIdentifier(connection)] = nil
            if replacements[serviceName] === connection {
                replacements[serviceName] = nil
            } else {
                ready.remove(serviceName); inFlight[serviceName] = nil
                outgoing[serviceName] = nil
            }
            connection.cancel()
            retryAfter[serviceName] = ConnectionRetry(after: retryAfter[serviceName],
                at: ProcessInfo.processInfo.systemUptime, policy: .connectionRecovery)
        default:
            if outgoing[serviceName] === connection { invalidateReceipt(connection, name: serviceName) }
        }
    }

    /// Audio is sent immediately, even without proof. Only verified recipients
    /// can suppress an available Internet copy; a receipt never retransmits audio.
    func send(_ data: Data, to peers: [PeerID]) -> SendResult {
        guard data.count <= 60_000, !data.isEmpty, peerID.isValidRelayID else { return .init() }
        let bytes = Data([UInt8(peerID.rawValue.utf8.count)]) + Data(peerID.rawValue.utf8) + data
        return synchronized {
            var result = SendResult()
            let now = ProcessInfo.processInfo.systemUptime
            var digest: Data?
            var candidate: (bytes: Data, digest: Data)?
            for peer in peers {
                let name = prepareToSend(to: peer)
                if ready.contains(name), let connection = outgoing[name] {
                    let packetDigest = digest ?? Data(SHA256.hash(data: bytes))
                    digest = packetDigest
                    if send(bytes, digest: packetDigest, connection: connection, name: name, at: now) {
                        result.accepted.insert(peer)
                        if paths[ObjectIdentifier(connection)]?.window.isRecent(at: now) == true {
                            result.verified.insert(peer)
                        }
                    }
                }
                if let replacement = replacements[name], case .ready = replacement.state,
                    now - (paths[ObjectIdentifier(replacement)]?.window.lastSentAt ?? now)
                        >= LocalMediaReceiptWindow.interval {
                    if candidate == nil {
                        let warmup = LocalMediaFraming.candidate(bytes)
                        candidate = (warmup, Data(SHA256.hash(data: warmup)))
                    }
                    if let candidate,
                        send(
                            candidate.bytes, digest: candidate.digest, connection: replacement, name: name, at: now
                        ) {
                        result.accepted.insert(peer)
                    }
                }
            }
            return result
        }
    }

    private func prepareToSend(to peer: PeerID) -> String {
        let name = peerServiceNames[peer] ?? serviceName(for: peer)
        if peerServiceNames[peer] == nil {
            if peerServiceNames.count >= 7 { peerServiceNames.removeAll(keepingCapacity: true) }
            peerServiceNames[peer] = name
        }
        if let endpoint = endpoints[name], let nonce = peerNonces[peer] {
            if outgoing[name] == nil {
                connectOnQueue(peer: peer, nonce: nonce, endpoint: endpoint)
            } else if !ready.contains(name), case .ready = outgoing[name]?.state {
                connectOnQueue(peer: peer, nonce: nonce, endpoint: endpoint, replacing: true)
            }
        }
        return name
    }

    private func send(_ bytes: Data, digest: Data, connection: NWConnection, name: String, at now: TimeInterval)
        -> Bool {
        // The native state may change before its queued callback updates ready.
        // Sending while waiting would let Network.framework retain old speech.
        guard case .ready = connection.state,
            inFlight[name, default: 0] + bytes.count <= 65_536, paths[ObjectIdentifier(connection)] != nil
        else { return false }
        paths[ObjectIdentifier(connection)]?.window.record(digest: digest, at: now)
        inFlight[name, default: 0] += bytes.count
        let token = generation
        connection.send(content: bytes, completion: .contentProcessed { [weak self] error in
            guard let self, self.generation == token,
                  self.outgoing[name] === connection || self.replacements[name] === connection else { return }
            self.inFlight[name] = max(0, self.inFlight[name, default: 0] - bytes.count)
            if error != nil {
                let retry = ConnectionRetry(
                    after: self.retryAfter[name], at: ProcessInfo.processInfo.systemUptime, policy: .connectionRecovery
                )
                if self.replacements[name] === connection {
                    self.replacements[name] = nil; self.paths[ObjectIdentifier(connection)] = nil; connection.cancel()
                } else { self.removeOutgoing(name) }
                self.retryAfter[name] = retry
                self.onAvailabilityChange?()
            }
        })
        sent += 1
        return true
    }

    private func promote(_ connection: NWConnection, name: String) {
        guard case .ready = connection.state else { return }
        replacements[name] = nil
        let old = outgoing.updateValue(connection, forKey: name)
        inFlight[name] = nil
        if let old { paths[ObjectIdentifier(old)] = nil; old.cancel() }
        ready.insert(name)
    }

    private func receiveReceipt(_ connection: NWConnection, name: String, generation token: UUID) {
        connection.receiveMessage { [weak self, weak connection] bytes, _, _, error in
            guard let self, let connection, self.generation == token,
                  self.outgoing[name] === connection || self.replacements[name] === connection else { return }
            let id = ObjectIdentifier(connection)
            if case .ready = connection.state,
               let bytes, let digest = self.paths[id]?.authenticator.decode(bytes),
               self.paths[id]?.window.accept(digest: digest, at: ProcessInfo.processInfo.systemUptime) == true {
                if self.replacements[name] === connection { self.promote(connection, name: name) }
                self.onAvailabilityChange?()
            }
            if error == nil { self.receiveReceipt(connection, name: name, generation: token) }
        }
    }
}
