import Foundation
import Network
import Testing
import RTCTestSupport
@testable import RTC
import RTCNativeWebRTC

/// Replaces service-side signaling and fan-out only. Every application packet
/// crosses two real UDP/DTLS/SCTP connections using the production engine.
actor NativeSFUPair {
    private struct Participant {
        let source: EventSource<WebRTCSignalingEvent>
        var engine: WebRTCNativeEngine?
        var task: Task<Void, Never>?
        var published = false
    }
    private var participants: [PeerID: Participant] = [:]
    private(set) var forwardedMedia = 0
    func connect(_ peer: PeerID, source: EventSource<WebRTCSignalingEvent>) {
        participants[peer] = .init(source: source)
        source.yield(.connected)
    }
    func offer(_ offer: WebRTCSessionDescription, from peer: PeerID) async {
        guard let source = participants[peer]?.source else { return }
        let engine = loopbackEngine(), events = engine.events
        participants[peer]?.engine = engine
        participants[peer]?.task = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                if case .receivedApplicationData(let data) = event { await self?.forward(data.message, from: peer) }
            }
        }
        await engine.createPeerConnection(for: .init(id: peer, displayName: "Fixture"))
        await engine.configureDataChannels([
            .init(id: 2, peerID: peer), .init(id: 4, isPublisher: true),
            .init(id: 6, peerID: peer, delivery: .reliable), .init(id: 8, isPublisher: true, delivery: .reliable)
        ], for: peer)
        guard let answer = await engine.acceptOffer(offer, from: peer) else {
            source.yield(.failed("Fixture could not answer native SDP")); return
        }
        source.yield(
            .dataChannels([.init(id: 2, isPublisher: true), .init(id: 6, isPublisher: true, delivery: .reliable)]))
        source.yield(.answer(answer, from: .init(rawValue: "cloudflare-sfu")))
    }
    func publish(_ peer: PeerID) {
        guard participants[peer] != nil, participants[peer]?.published == false else { return }
        participants[peer]?.published = true
        for (id, participant) in participants where participant.published {
            let others = participants.keys.filter { $0 != id && participants[$0]?.published == true }
            participant.source.yield(.dataChannels([
                .init(id: 2, isPublisher: true), .init(id: 6, isPublisher: true, delivery: .reliable)
                    ]
                        + others.flatMap {
                            [WebRTCDataChannel(id: 4, peerID: $0), .init(id: 8, peerID: $0, delivery: .reliable)]
                        }))
            participant.source.yield(.members(others.map { .init(id: $0, displayName: "Fixture") }))
        }
    }
    private func forward(_ message: ApplicationDataMessage, from peer: PeerID) async {
        if message.delivery == .unreliable { forwardedMedia += 1 }
        for (id, participant) in participants where id != peer && participant.published {
            await participant.engine?.sendApplicationData(message, to: id)
        }
    }
    func disconnect(_ peer: PeerID) async {
        guard let participant = participants.removeValue(forKey: peer) else { return }
        participant.task?.cancel()
        await participant.engine?.close()
    }
    func stop() async { for peer in Array(participants.keys) { await disconnect(peer) } }
}

private actor PairSignaling: WebRTCSignalingClient {
    nonisolated private let source = EventSource<WebRTCSignalingEvent>()
    nonisolated var events: AsyncStream<WebRTCSignalingEvent> { source.stream }
    private let server: NativeSFUPair
    private var peer: PeerID?
    init(_ server: NativeSFUPair) { self.server = server }
    func connect(_ request: WebRTCSignalingConnectRequest) async {
        peer = request.call.localPeer.id
        await server.connect(request.call.localPeer.id, source: source)
    }
    func disconnect() async { if let peer { await server.disconnect(peer) }; peer = nil }
    func startPublishing() async { if let peer { await server.publish(peer) } }
    func sendOffer(_ offer: WebRTCSessionDescription, to peerID: PeerID) async {
        if let peer { await server.offer(offer, from: peer) }
    }
    func sendApplicationData(_ message: ApplicationDataMessage, to peerID: PeerID?) async {
        // Group control and audio must use the actual data channels.
        Issue.record("Application data unexpectedly used the signaling fixture")
    }
}

/// Counts selection decisions without manufacturing delivery or recipients.
actor CountedInternetRoute: RTCCallRoute {
    nonisolated let kind = RouteKind.webRTC
    nonisolated let capabilities: RouteCapabilities
    nonisolated var events: AsyncStream<RouteEvent> { backend.events }
    nonisolated private let backend: any RTCCallRoute
    private(set) var mediaSends = 0
    private(set) var starts = 0
    init(_ backend: any RTCCallRoute) {
        self.backend = backend; capabilities = backend.capabilities
    }
    func prepare(_ request: CallStartRequest) async { await backend.prepare(request) }
    func startConnection() async { starts += 1; await backend.startConnection() }
    func stopConnection() async { await backend.stopConnection() }
    func sendApplicationData(_ message: ApplicationDataMessage) async -> RTCRouteSendResult {
        if message.delivery == .unreliable { mediaSends += 1 }
        return await backend.sendApplicationData(message)
    }
    func networkDiagnostics() async -> RTCRouteNetworkDiagnostics { await backend.networkDiagnostics() }
}

actor ContinuityRecord {
    var audio: [ReceivedAudioPacket] = []
    var localControl: [ApplicationDataMessage] = []
    var localPeers: Set<PeerID> = []
    var internetPeers: Set<PeerID> = []
    var errors: [CallSessionError] = []
    func record(_ event: CallSessionEvent) {
        if case .receivedAudioPacket(let packet) = event { audio.append(packet) }
        if case .error(let error) = event { errors.append(error) }
    }
    func record(_ event: RouteEvent) {
        if case .membersChanged(let kind, let members) = event {
            if kind == .multipeer {
                localPeers = Set(members.map(\.peer.id))
            } else {
                internetPeers = Set(members.map(\.peer.id))
            }
        }
        if case .receivedApplicationData(.multipeer, let data) = event, data.message.namespace == "control-proof" {
            localControl.append(data.message)
        }
    }
    func has(_ marker: UInt32) -> Bool { audio.contains { Self.marker($0.packet.payload) == marker } }
    var markers: [UInt32] { audio.map { Self.marker($0.packet.payload) } }
    private static func marker(_ data: Data) -> UInt32 {
        data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }
}

func requireContinuity(_ message: String, _ condition: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(10))
    while ContinuousClock.now < deadline {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(await condition(), Comment(rawValue: message))
}

/// Owned routes are quiescent with respect to prepare/start/stop here. Their
/// private session/transport references are stable; mutable UDP state is read
/// only through its synchronized API. Production gains no fault-injection hook.
private func mediaTransport(_ route: LocalCallRoute) throws -> LocalDatagramTransport {
    func unwrap(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        return mirror.displayStyle == .optional ? mirror.children.first?.value : value
    }
    let stored = try #require(Mirror(reflecting: route).children.first { $0.label == "session" }?.value)
    let session = try #require(unwrap(stored))
    let media = try #require(
        Mirror(reflecting: session).children.first { $0.label?.hasSuffix("datagrams") == true }?.value)
    return try #require(unwrap(media) as? LocalDatagramTransport)
}

struct NativeContinuityPair {
    let server: NativeSFUPair
    let ids: [PeerID]
    let local: [LocalCallRoute]
    let internet: [CountedInternetRoute]
    let managers: [RouteManager]
    let records = [ContinuityRecord(), ContinuityRecord()]
    private let configuration: CallRouteConfiguration

    init() {
        let server = NativeSFUPair()
        let ids = [PeerID(rawValue: "native-a"), PeerID(rawValue: "native-b")]
        let local = [LocalCallRoute(), LocalCallRoute()]
        let internet = ids.map { _ in
            CountedInternetRoute(WebRTCInternetRoute(cloudflareConfiguration: .init(
                workerURL: URL(string: "https://fixture.invalid")!, accessToken: "fixture"),
                signalingClient: PairSignaling(server), engine: loopbackEngine()))
        }
        let config = CallRouteConfiguration(
            enabledRoutes: [.multipeer, .webRTC], preferredRoute: .multipeer, fallbackDelay: 0)
        self.server = server
        self.ids = ids
        self.local = local
        self.internet = internet
        configuration = config
        managers = ids.indices.map { index in
            RouteManager(
                routes: [local[index], internet[index]],
                configuration: config,
                runtimeStatusPolicy: .init(isAutomaticBroadcastEnabled: false)
            )
        }
    }

    func recordEvents() -> [Task<Void, Never>] {
        var tasks: [Task<Void, Never>] = []
        for index in ids.indices {
            let callEvents = managers[index].events
            let localEvents = local[index].events
            let internetEvents = internet[index].events
            let record = records[index]
            tasks.append(Task { for await event in callEvents { await record.record(event) } })
            tasks.append(Task { for await event in localEvents { await record.record(event) } })
            tasks.append(Task { for await event in internetEvents { await record.record(event) } })
        }
        return tasks
    }

    func connect(credential: RTCCredential) async throws {
        for index in ids.indices {
            await managers[index].prepare(
                .init(
                    sessionID: "continuity",
                    localPeer: .init(id: ids[index], displayName: "Rider"),
                    credential: credential,
                    configuration: configuration
                )
            )
            await managers[index].startConnection()
        }
        for index in ids.indices {
            try await requireContinuity("Actual QUIC and Internet membership") {
                let localPeers = await records[index].localPeers, internetPeers = await records[index].internetPeers
                return localPeers == [ids[1 - index]] && internetPeers == [ids[1 - index]]
            }
        }
    }

    func startMedia(proxies: inout [MediaBlackhole]) async throws -> [LocalDatagramTransport] {
        let media = try local.map(mediaTransport)
        try await requireContinuity("Native UDP listeners") { media.allSatisfy { $0.port != nil } }
        for index in ids.indices {
            let proxy = try MediaBlackhole(target: #require(media[1 - index].port))
            proxies.append(proxy)
            media[index].connect(
                to: ids[1 - index],
                nonce: media[1 - index].serviceNonce,
                endpoint: .hostPort(host: .ipv4(.loopback), port: proxy.port)
            )
        }
        try await requireContinuity("Native UDP send acceptance") {
            media[0].isReady(for: ids[1]) && media[1].isReady(for: ids[0])
        }
        for manager in managers { await manager.startMedia() }
        return media
    }

    func sendAudio(_ marker: UInt32) async {
        var bytes = marker.bigEndian
        var payload = withUnsafeBytes(of: &bytes) { Data($0) }
        payload.append(Data(repeating: 0x71, count: 956))
        for manager in managers {
            await manager.sendAudioPacket(.init(sequenceNumber: UInt64(marker), codec: .pcm16,
                format: .init(sampleRate: 24000, channelCount: 1), payload: payload))
        }
    }
}
