import Foundation
@testable import RTC

struct ContinuityRider {
    let id: PeerID
    let manager: RouteManager
    let record = ContinuityCallRecorder()

    init(
        id: PeerID,
        routeKinds: some Sequence<RouteKind>,
        network: ContinuityVirtualNetwork,
        initialConfiguration: CallRouteConfiguration = .init()
    ) {
        self.id = id
        manager = RouteManager(
            routes: routeKinds.map { ContinuityVirtualRoute(peer: id, kind: $0, network: network) },
            configuration: initialConfiguration,
            runtimeStatusPolicy: .init(isAutomaticBroadcastEnabled: false)
        )
    }

    func listen() -> Task<Void, Never> {
        let events = manager.events
        return Task {
            for await event in events { await record.record(event) }
        }
    }

    func start(
        sessionID: String,
        displayName: String,
        credential: RTCCredential,
        configuration: CallRouteConfiguration,
        audioPolicy: RTCAudioPolicy = .init()
    ) async {
        await manager.prepare(.init(
            sessionID: sessionID,
            localPeer: .init(id: id, displayName: displayName),
            credential: credential,
            configuration: configuration,
            audioPolicy: audioPolicy
        ))
        await manager.startConnection()
        await manager.startMedia()
    }

    func sendAudio(marker: UInt8) async {
        await manager.sendAudioPacket(.init(
            sequenceNumber: UInt64(marker),
            codec: .pcm16,
            payload: Data(repeating: marker, count: 960)
        ))
    }
}

actor ContinuityCallRecorder {
    var members: [CallMemberState] = []
    var memberCount: Int { members.count }
    var audio: [ReceivedAudioPacket] = []
    var states: [CallConnectionState] = []

    func record(_ event: CallSessionEvent) {
        if case .stateChanged(let state) = event { states.append(state) }
        if case .membersChanged(let members) = event { self.members = members }
        if case .receivedAudioPacket(let packet) = event { audio.append(packet) }
    }
}

actor ContinuityVirtualNetwork {
    var routes: [RouteKind: [PeerID: EventSource<RouteEvent>]] = [:]
    let internetAvailable: Bool
    private var unavailable: [RouteKind: Set<PeerID>] = [:]
    private var attempts: [RouteKind: [PeerID: Int]] = [:]
    private var audioSends: [RouteKind: [PeerID: Int]] = [:]
    private var localNetworks: [PeerID: String] = [:]
    private let localLine: [PeerID]

    init(internetAvailable: Bool = true, localLine: [PeerID] = []) {
        self.internetAvailable = internetAvailable
        self.localLine = localLine
    }

    func join(_ peer: PeerID, kind: RouteKind, source: EventSource<RouteEvent>) {
        attempts[kind, default: [:]][peer, default: 0] += 1
        if (kind == .webRTC && !internetAvailable) || unavailable[kind, default: []].contains(peer) {
            source.yield(.stateChanged(kind, .failed))
            return
        }
        routes[kind, default: [:]][peer] = source
        publish(kind)
    }

    func leave(_ peer: PeerID, kind: RouteKind) {
        routes[kind]?[peer] = nil
        publish(kind)
    }

    func fail(_ peer: PeerID, kind: RouteKind) {
        unavailable[kind, default: []].insert(peer)
        let source = routes[kind]?[peer]
        leave(peer, kind: kind)
        source?.yield(.membersChanged(kind, []))
        source?.yield(.stateChanged(kind, .failed))
    }

    func restore(_ peer: PeerID, kind: RouteKind) { unavailable[kind]?.remove(peer) }
    func moveLocalPeer(_ peer: PeerID, to network: String) {
        localNetworks[peer] = network
        publish(.multipeer)
    }

    func isJoined(_ peer: PeerID, kind: RouteKind) -> Bool { routes[kind]?[peer] != nil }
    func attemptCount(_ peer: PeerID, kind: RouteKind) -> Int { attempts[kind]?[peer] ?? 0 }
    func eventDrops(for peer: PeerID, kind: RouteKind) -> RTCEventDropReport {
        routes[kind]?[peer]?.report ?? .init()
    }

    func audioSendCount(for peer: PeerID, kind: RouteKind) -> Int { audioSends[kind]?[peer] ?? 0 }
    func reachablePeers(_ peer: PeerID, kind: RouteKind) -> Set<PeerID> {
        guard routes[kind]?[peer] != nil else { return [] }
        return Set(routes[kind, default: [:]].keys.filter { other in
            if kind == .multipeer, !localLine.isEmpty {
                guard let peerIndex = localLine.firstIndex(of: peer),
                      let otherIndex = localLine.firstIndex(of: other) else { return false }
                return abs(peerIndex - otherIndex) == 1
            }
            return other != peer && (
                kind != .multipeer || localNetworks[other, default: "nearby"] == localNetworks[peer, default: "nearby"]
            )
        })
    }

    func send(_ peer: PeerID, kind: RouteKind, message: ApplicationDataMessage) {
        if message.delivery == .unreliable { audioSends[kind, default: [:]][peer, default: 0] += 1 }
        for other in reachablePeers(peer, kind: kind) {
            routes[kind]?[other]?.yield(.receivedApplicationData(kind, .init(peerID: peer, message: message)))
        }
    }

    func publish(_ kind: RouteKind) {
        for (peer, source) in routes[kind, default: [:]] {
            let members = reachablePeers(peer, kind: kind).map {
                CallMemberState(peer: .init(id: $0, displayName: $0.rawValue), route: kind, isConnected: true)
            }
            source.yield(.membersChanged(kind, members))
            source.yield(.stateChanged(kind, kind == .webRTC ? .mediaReady : .authenticated))
        }
    }
}

private actor ContinuityVirtualRoute: RTCCallRoute {
    let peer: PeerID
    let kind: RouteKind
    let network: ContinuityVirtualNetwork
    nonisolated let source = EventSource<RouteEvent>()
    nonisolated var events: AsyncStream<RouteEvent> { source.stream }
    let capabilities = RouteCapabilities(
        supportsLocalDiscovery: true,
        supportsOfflineOperation: true,
        supportsReliableApplicationData: true,
        supportsUnreliableApplicationData: true,
        requiresSignaling: false,
        supportedAudioCodecs: [.pcm16]
    )

    init(peer: PeerID, kind: RouteKind, network: ContinuityVirtualNetwork) {
        self.peer = peer
        self.kind = kind
        self.network = network
    }
    func prepare(_ request: CallStartRequest) async {}
    func startConnection() async { await network.join(peer, kind: kind, source: source) }
    func stopConnection() async { await network.leave(peer, kind: kind) }
    func sendApplicationData(_ message: ApplicationDataMessage) async -> RTCRouteSendResult {
        await network.send(peer, kind: kind, message: message)
        let recipients = await network.reachablePeers(peer, kind: kind)
        return .init(
            transportAccepted: !recipients.isEmpty,
            verifiedLocalRecipients: kind == .multipeer ? recipients : []
        )
    }
}
