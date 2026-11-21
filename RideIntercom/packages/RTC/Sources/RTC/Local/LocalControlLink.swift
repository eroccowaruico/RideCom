#if !os(watchOS)
import CryptoKit
import Foundation
import Network
import Security

/// One control connection to one peer: a QUIC stream that carries the handshake first and framed
/// messages after it. Nothing a peer sends is delivered before its handshake has been verified against
/// the certificates of this very connection.
final class LocalControlLink: @unchecked Sendable {
    enum Event: Equatable, Sendable {
        /// The peer proved the group key on this connection. `nonce` names its UDP audio listener.
        case authenticated(PeerID, nonce: String)
        case message(Data)
        case handshakeRejected
        /// Sent once, whatever ended the link: the peer, the network, a refused handshake, `close()`.
        case closed
    }

    enum Authentication: Sendable {
        case shared(RTCCredential)
        case dialing(RTCCredential, peer: PeerID, fingerprint: Data)
        case accepting([PeerID: RTCCredential])

        func credential(for peer: PeerID, fingerprint: Data) -> RTCCredential? {
            switch self {
            case .shared(let credential): credential
            case .dialing(let credential, let expected, let advertised):
                expected == peer && advertised == fingerprint ? credential : nil
            case .accepting(let offered): offered[peer]
            }
        }
    }

    static let handshakeTimeout: TimeInterval = 10

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let authentication: Authentication
    private let localID: PeerID
    private let nonce: String
    private let localFingerprint: Data
    private let onEvent: @Sendable (Event) -> Void
    // Touched on `queue` only.
    private var framing = LocalControlFraming()
    private var isAuthenticated = false
    private var isClosed = false
    private var hasStarted = false

    init(connection: NWConnection, identity: LocalControlIdentity, authentication: Authentication, localID: PeerID,
         nonce: String, queue: DispatchQueue, onEvent: @escaping @Sendable (Event) -> Void) {
        self.connection = connection; self.queue = queue; self.authentication = authentication
        self.localID = localID; self.nonce = nonce; self.localFingerprint = identity.fingerprint; self.onEvent = onEvent
    }

    func start() {
        queue.async { [self] in
            guard !hasStarted, !isClosed else { return }
            hasStarted = true
            connection.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready: self.beginHandshake()
                case .failed, .cancelled: self.finish()
                default: break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + Self.handshakeTimeout) { [weak self] in
                guard let self, !self.isAuthenticated else { return }
                self.finish()
            }
            receive()
        }
    }

    /// Dropped before the peer is authenticated and after the link has closed.
    func send(_ message: Data) {
        queue.async { [self] in
            guard isAuthenticated, !isClosed, let frame = try? LocalControlFraming.frame(message) else { return }
            connection.send(content: frame, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.finish() }
            })
        }
    }

    func close() { queue.async { [self] in finish() } }

    private func beginHandshake() {
        guard !isClosed, let fingerprint = Self.peerFingerprint(of: connection) else { finish(); return }
        switch authentication {
        case .shared(let credential):
            sendHandshake(credential: credential, peer: fingerprint)
        case .dialing(let credential, _, let expected):
            guard fingerprint == expected else { finish(); return }
            sendHandshake(credential: credential, peer: fingerprint)
        case .accepting:
            break // Wait for the dialer to prove it is one of the intended recipients.
        }
    }

    private func sendHandshake(credential: RTCCredential, peer: Data) {
        let handshake = LocalControlHandshake.make(credential: credential, senderID: localID, nonce: nonce,
                                                   senderFingerprint: localFingerprint, receiverFingerprint: peer)
        guard let payload = try? JSONEncoder().encode(handshake),
              let frame = try? LocalControlFraming.frame(payload)
        else { finish(); return }
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.finish() }
        })
    }

    private func receive() {
        connection.receive(
            minimumIncompleteLength: 1, maximumLength: 65_536
        ) { [weak self] data, _, isComplete, error in
            guard let self, !self.isClosed else { return }
            if let data, !data.isEmpty {
                guard let messages = try? self.framing.receive(data) else { self.finish(); return }
                for message in messages {
                    guard self.accept(message) else {
                        self.onEvent(.handshakeRejected)
                        self.finish()
                        return
                    }
                }
            }
            if isComplete || error != nil { self.finish(); return }
            self.receive()
        }
    }

    private func accept(_ message: Data) -> Bool {
        guard !isAuthenticated else { onEvent(.message(message)); return true }
        guard let peer = Self.peerFingerprint(of: connection),
              let handshake = try? JSONDecoder().decode(LocalControlHandshake.self, from: message),
              let credential = authentication.credential(for: handshake.senderID, fingerprint: peer),
              handshake.verify(
                  credential: credential, localID: localID, senderFingerprint: peer,
                  receiverFingerprint: localFingerprint)
        else { return false }
        if case .accepting = authentication { sendHandshake(credential: credential, peer: peer) }
        guard !isClosed else { return false }
        isAuthenticated = true
        onEvent(.authenticated(handshake.senderID, nonce: handshake.nonce))
        return true
    }

    private func finish() {
        guard !isClosed else { return }
        isClosed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onEvent(.closed)
    }

    /// The certificate the peer presented on this connection, as TLS saw it.
    static func peerFingerprint(of connection: NWConnection) -> Data? {
        guard let metadata = connection.metadata(definition: NWProtocolQUIC.definition) as? NWProtocolQUIC.Metadata
        else { return nil }
        var leaf: Data?
        _ = sec_protocol_metadata_access_peer_certificate_chain(metadata.securityProtocolMetadata) { certificate in
            if leaf == nil {
                leaf = SecCertificateCopyData(sec_certificate_copy_ref(certificate).takeRetainedValue()) as Data
            }
        }
        return leaf.map { Data(SHA256.hash(data: $0)) }
    }
}
#endif
