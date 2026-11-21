#if !os(watchOS)
import Foundation

/// A reliable, authenticated local exchange without starting a call or an audio route.
public final class RTCLocalDataChannel: Sendable {
    public enum Event: Equatable, Sendable {
        case members([PeerID])
        case message(Data, from: PeerID)
        case failed(String)
    }

    /// One advertisement and one listener can serve this many distinct recipients.
    public static let maximumOfferedPeers = LocalControlTransport.maximumPeers

    private let transport: LocalControlTransport

    /// Events arrive in order on the transport's serial queue. Only peers
    /// using this channel with the same credential can join.
    public init(localID: PeerID, credential: RTCCredential, onEvent: @escaping @Sendable (Event) -> Void) {
        transport = LocalControlTransport(localID: localID, credential: Self.dataCredential(credential),
                                          nonce: UUID().uuidString, onEvent: Self.events(onEvent))
    }

    /// Look for offers addressed to this device using the keys of known peers.
    /// Offer a connection to selected peers with the same listener. An empty offer starts only a browser.
    public init(localID: PeerID, knownPeers: [PeerID: RTCCredential], offeredPeers: Set<PeerID> = [],
                onEvent: @escaping @Sendable (Event) -> Void) {
        transport = LocalControlTransport(localID: localID, knownPeers: knownPeers.mapValues(Self.dataCredential),
                                          offeredPeers: offeredPeers, onEvent: Self.events(onEvent))
    }

    private static func dataCredential(_ credential: RTCCredential) -> RTCCredential {
        // Separate both discovery and authentication from call control.
        RTCCredential.derived(groupID: "ride-local-data-v1:" + credential.groupHash,
                              secret: credential.sharedSecret.base64EncodedString())
    }

    private static func events(
        _ onEvent: @escaping @Sendable (Event) -> Void
    ) -> @Sendable (LocalControlEvent) -> Void {
        { event in
            switch event {
            case .members(let peers): onEvent(.members(peers))
            case .message(let data, let peer): onEvent(.message(data, from: peer))
            case .failed(let reason): onEvent(.failed(reason))
            case .state, .authenticated, .lost, .handshakeRejected: break
            }
        }
    }

    deinit { transport.stop() }

    /// Starts discovery and any listener needed for this channel. A new start replaces the previous one.
    public func start() { transport.start() }

    /// Closes the advertisement, discovery and links. A later start is allowed.
    public func stop() { transport.stop() }

    /// Broadcasts on a shared-credential channel to authenticated members. Addressed channels ignore this operation.
    /// Payloads over 65,536 bytes are ignored. The caller owns delivery confirmation and retry.
    public func send(_ data: Data) { transport.send(data) }

    /// Sends up to 65,536 bytes to this peer, if authenticated and still connected.
    public func send(_ data: Data, to peer: PeerID) { transport.send(data, to: peer) }
}
#endif
