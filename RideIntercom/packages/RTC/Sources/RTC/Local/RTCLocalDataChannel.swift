#if !os(watchOS)
import Foundation

/// A reliable, authenticated local exchange without starting a call or an audio route.
public final class RTCLocalDataChannel: Sendable {
    public enum Event: Equatable, Sendable {
        case members([PeerID])
        case message(Data, from: PeerID)
        case failed(String)
    }

    private let transport: LocalControlTransport

    /// Events arrive in order on the transport's serial queue. Only peers
    /// using this channel with the same credential can join.
    public init(localID: PeerID, credential: RTCCredential, onEvent: @escaping @Sendable (Event) -> Void) {
        // Scope both discovery and authentication to data, so even a caller
        // with the same credential cannot be mistaken for a call participant.
        let dataCredential = RTCCredential.derived(
            groupID: "ride-local-data-v1:" + credential.groupHash,
            secret: credential.sharedSecret.base64EncodedString()
        )
        transport = LocalControlTransport(localID: localID, credential: dataCredential, nonce: UUID().uuidString) { event in
            switch event {
            case .members(let peers): onEvent(.members(peers))
            case .message(let data, let peer): onEvent(.message(data, from: peer))
            case .failed(let reason): onEvent(.failed(reason))
            case .state, .authenticated, .lost, .handshakeRejected: break
            }
        }
    }

    deinit { transport.stop() }

    /// Starts discovery and listening. A new start replaces the previous one.
    public func start() { transport.start() }

    /// Closes the advertisement, discovery and links. A later start is allowed.
    public func stop() { transport.stop() }

    /// Sends to the currently authenticated members, without queuing for absent
    /// peers. Payloads over 65,536 bytes are ignored. Delivery confirmation
    /// and retry belong to the caller's message protocol.
    public func send(_ data: Data) { transport.send(data) }
}
#endif
