import Foundation
import RTC

#if canImport(WebRTC)
import WebRTC

public final class WebRTCNativeEngine: NativeWebRTCEngine, @unchecked Sendable {
    public override var isAvailable: Bool { factory != nil }

    private let factory: ModularWebRTCFactory?
    private let relayOnly: Bool
    // Native callbacks may run while the caller waits on an SDK operation.
    // They use the state lock only, and SDK operations never hold that lock.
    private let mutations = NSLock()
    private let state = NSLock()
    private let stateEvents = DispatchQueue(label: "RideCom.WebRTC.state")
    private var iceServers: [WebRTCIceServer]
    private var peerConnections: [PeerID: ModularWebRTCPeer] = [:]
    private var channels: [PeerID: [Int32: ModularWebRTCChannel]] = [:]
    private var channelOrigins: [ObjectIdentifier: PeerID] = [:]
    private var publishers: [PeerID: [ApplicationDataDelivery: Int32]] = [:]

    public override convenience init() {
        self.init(iceServers: [.init(urls: ["stun:stun.cloudflare.com:3478"])])
    }

    public convenience init(iceServers: [WebRTCIceServer]) {
        self.init(iceServers: iceServers, includeLoopback: false)
    }

    @_spi(Validation)
    public init(iceServers: [WebRTCIceServer], includeLoopback: Bool, relayOnly: Bool = false) {
        factory = ModularWebRTCFactory(includeLoopback: includeLoopback)
        self.iceServers = Self.udpIceServers(iceServers)
        self.relayOnly = relayOnly
        super.init()
    }

    private static func udpIceServers(_ servers: [WebRTCIceServer]) -> [WebRTCIceServer] {
        servers.compactMap { server in
            let urls = server.urls.filter { url in
                let value = url.lowercased()
                guard value.hasPrefix("stun:") || value.hasPrefix("turn:") else { return false }
                let parts = value.split(separator: "?", maxSplits: 1)
                return parts.count == 1 || parts[1] == "transport=udp"
            }
            return urls.isEmpty ? nil : .init(urls: urls, username: server.username, credential: server.credential)
        }
    }

    public override func createPeerConnection(for peer: PeerDescriptor) async {
        mutations.withLock {
            guard
                state.withLock({ peerConnections[peer.id] == nil }),
                let connection = factory?.makePeer(relayOnly: relayOnly)
            else { return }
            guard iceServers.isEmpty || connection.setIceServers(iceServers) else {
                connection.close()
                return
            }

            // Reserve the initial negotiated channel so the offer contains SCTP.
            let bootstrap = connection.makeChannel(label: "server-events", id: 0, delivery: .reliable)
            state.withLock {
                peerConnections[peer.id] = connection
                if let bootstrap { channels[peer.id] = [0: bootstrap] }
            }
            observeIce(connection, peerID: peer.id)
        }
    }

    public override func configureIceServers(_ servers: [WebRTCIceServer]) async -> Bool {
        let eligible = Self.udpIceServers(servers)
        guard !eligible.isEmpty else { return false }
        return mutations.withLock {
            iceServers = eligible
            let connections = state.withLock { Array(peerConnections.values) }
            return connections.allSatisfy { $0.setIceServers(eligible) }
        }
    }

    public override func networkStatistics(for peerID: PeerID) async -> RTCNetworkStatistics {
        guard let connection = state.withLock({ peerConnections[peerID] }) else { return .init() }
        let icePath = await connection.icePath()
        let currentChannels = state.withLock { channels[peerID].map { Array($0.values) } }
        let bytes = currentChannels?.reduce(UInt64(0)) { $0 + $1.bufferedBytes }
        return state.withLock {
            guard peerConnections[peerID] === connection else { return .init() }
            return RTCNetworkStatistics(
                roundTripTime: icePath.roundTripTime, bufferedBytes: bytes,
                unavailableReason: "SCTP DataChannel packet loss is not exposed; RTT is ICE transport RTT"
            )
        }
    }

    @_spi(Validation)
    public func usesUDPRelay() async -> Bool {
        guard let connection = state.withLock({
            peerConnections.count == 1 ? peerConnections.values.first : nil
        }) else { return false }
        let icePath = await connection.icePath()
        return state.withLock {
            icePath.usesUDPRelay && peerConnections.count == 1 && peerConnections.values.first === connection
        }
    }

    public override func makeOffer(for peerID: PeerID) async -> WebRTCSessionDescription? {
        guard
            let connection = state.withLock({ peerConnections[peerID] }),
            let sdp = await connection.makeLocalDescription(),
            state.withLock({ peerConnections[peerID] === connection })
        else { return nil }
        return .init(kind: .offer, sdp: sdp)
    }

    public override func acceptOffer(_ offer: WebRTCSessionDescription, from peerID: PeerID) async
        -> WebRTCSessionDescription? {
        guard
            let connection = state.withLock({ peerConnections[peerID] }),
            await connection.setRemoteDescription(offer.sdp, kind: RideComRTCDescriptionOffer),
            let sdp = await connection.makeLocalDescription(),
            state.withLock({ peerConnections[peerID] === connection })
        else { return nil }
        return .init(kind: .answer, sdp: sdp)
    }

    public override func acceptAnswer(_ answer: WebRTCSessionDescription, from peerID: PeerID) async -> Bool {
        guard let connection = state.withLock({ peerConnections[peerID] }) else { return false }
        return await connection.setRemoteDescription(answer.sdp, kind: RideComRTCDescriptionAnswer)
            && state.withLock { peerConnections[peerID] === connection }
    }

    public override func configureDataChannels(_ allocations: [WebRTCDataChannel], for peerID: PeerID) async {
        mutations.withLock {
            guard let connection = state.withLock({ peerConnections[peerID] }) else { return }
            let wanted = Set(allocations.map(\.id))
            let obsolete = state.withLock {
                let removed = channels[peerID, default: [:]].filter { !wanted.contains($0.key) }.map(\.value)
                for channel in removed {
                    channelOrigins[ObjectIdentifier(channel)] = nil
                    channels[peerID]?[channel.id] = nil
                }
                publishers[peerID] = nil
                return removed
            }
            for channel in obsolete { channel.close() }
            for allocation in allocations {
                installChannel(allocation, peerID: peerID, connection: connection)
            }
        }
    }

    private func installChannel(
        _ allocation: WebRTCDataChannel, peerID: PeerID, connection: ModularWebRTCPeer
    ) {
        let existing = state.withLock { channels[peerID]?[allocation.id] }
        if let existing, existing.delivery != allocation.delivery {
            emit(.connectionStateChanged(.failed))
            return
        }
        guard let channel = existing ?? connection.makeChannel(
            label: "rideintercom", id: allocation.id, delivery: allocation.delivery
        ) else { return }

        state.withLock {
            channels[peerID, default: [:]][allocation.id] = channel
            if allocation.isPublisher {
                publishers[peerID, default: [:]][allocation.delivery] = allocation.id
            }
            channelOrigins[ObjectIdentifier(channel)] = allocation.peerID
        }
        observeChannel(channel, peerID: peerID)
    }

    @discardableResult
    public override func sendApplicationData(_ message: ApplicationDataMessage, to peerID: PeerID) async -> Bool? {
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        guard let data = try? encoder.encode(message), data.count <= 49_152 else { return false }
        let channel = state.withLock { publishers[peerID]?[message.delivery].flatMap { channels[peerID]?[$0] } }
        return channel?.send(data) ?? false
    }

    public override func closePeerConnection(peerID: PeerID) async {
        mutations.withLock {
            let removed = state.withLock { () -> (ModularWebRTCPeer?, [ModularWebRTCChannel]) in
                let old = Array(channels.removeValue(forKey: peerID)?.values ?? [:].values)
                for channel in old { channelOrigins[ObjectIdentifier(channel)] = nil }
                publishers[peerID] = nil
                return (peerConnections.removeValue(forKey: peerID), old)
            }
            for channel in removed.1 { channel.close() }
            removed.0?.close()
        }
    }

    public override func close() async {
        let peers = state.withLock { Array(peerConnections.keys) }
        for peerID in peers { await closePeerConnection(peerID: peerID) }
    }

    private func observeIce(_ connection: ModularWebRTCPeer, peerID: PeerID) {
        connection.observeIce { [weak self, weak connection] value in
            self?.stateEvents.async { [weak self, weak connection] in
                guard let self, let connection else { return }
                state.withLock {
                    guard peerConnections[peerID] === connection else { return }
                    emit(.connectionStateChanged(value.routeState))
                }
            }
        }
    }

    private func observeChannel(_ channel: ModularWebRTCChannel, peerID: PeerID) {
        channel.observe(
            changed: { [weak self, weak channel] in
                self?.stateEvents.async { [weak self, weak channel] in
                    guard let self, let channel, channel.isOpen else { return }
                    state.withLock {
                        guard publishers[peerID]?[.unreliable] == channel.id,
                              channels[peerID]?[channel.id] === channel else { return }
                        emit(.connectionStateChanged(.mediaReady))
                    }
                }
            },
            received: { [weak self, weak channel] packet in
                guard let self, let channel,
                      let message = try? PropertyListDecoder().decode(ApplicationDataMessage.self, from: packet)
                else { return }
                state.withLock {
                    guard let origin = channelOrigins[ObjectIdentifier(channel)] else { return }
                    emit(.receivedApplicationData(.init(peerID: origin, message: message)))
                }
            }
        )
    }
}

private extension RideComRTCIceState {
    var routeState: RouteConnectionState {
        switch self {
        case RideComRTCIceConnecting: .connecting
        case RideComRTCIceConnected: .connected
        case RideComRTCIceDisconnected: .disconnected
        default: .failed
        }
    }
}
#else
public final class WebRTCNativeEngine: NativeWebRTCEngine, @unchecked Sendable {
    public override var isAvailable: Bool { false }

    public override init() {
        super.init()
    }
}
#endif
