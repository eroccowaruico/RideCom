import Foundation
import Network
import Testing
import RTCTestSupport
@testable import RTC
import RTCNativeWebRTC
@preconcurrency import WebRTC

private func loopbackEngine() -> WebRTCNativeEngine {
    let factory = RTCPeerConnectionFactory(), options = RTCPeerConnectionFactoryOptions()
    options.ignoreLoopbackNetworkAdapter = false
    factory.setOptions(options)
    return WebRTCNativeEngine(iceServers: [], factory: factory)
}

/// Replaces service-side signaling and fan-out only. Every application packet
/// crosses two real UDP/DTLS/SCTP connections using the production engine.
private actor NativeSFUPair {
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
private actor CountedInternetRoute: RTCCallRoute {
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

private actor ContinuityRecord {
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

private func requireContinuity(_ message: String, _ condition: () async -> Bool) async throws {
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

@Suite(.serialized) struct NativeRouteContinuityTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func nativeQUICControlSurvivesMediaBlackholesAndWebRTCRecovers(bothDirections: Bool, blockedAtStart: Bool)
        async throws {
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
        let managers = ids.indices.map { i in RouteManager(routes: [local[i], internet[i]],
            configuration: config, runtimeStatusPolicy: .init(isAutomaticBroadcastEnabled: false)) }
        let records = [ContinuityRecord(), ContinuityRecord()]
        var tasks: [Task<Void, Never>] = []
        for i in ids.indices {
            let callEvents = managers[i].events, localEvents = local[i].events, internetEvents = internet[i].events
            tasks.append(Task { for await event in callEvents { await records[i].record(event) } })
            tasks.append(Task { for await event in localEvents { await records[i].record(event) } })
            tasks.append(Task { for await event in internetEvents { await records[i].record(event) } })
        }
        defer { tasks.forEach { $0.cancel() } }
        let credential = RTCCredential.derived(groupID: UUID().uuidString, secret: "native-route-fixture")
        var proxies: [MediaBlackhole] = []
        do {
            for i in ids.indices {
                await managers[i].prepare(
                    .init(
                        sessionID: "continuity", localPeer: .init(id: ids[i], displayName: "Rider"),
                    credential: credential, configuration: config))
                await managers[i].startConnection()
            }
            for i in ids.indices {
                try await requireContinuity("Actual QUIC and Internet membership") {
                    let localPeers = await records[i].localPeers, internetPeers = await records[i].internetPeers
                    return localPeers == [ids[1-i]] && internetPeers == [ids[1-i]]
                }
            }
            let media = try local.map(mediaTransport)
            try await requireContinuity("Native UDP listeners") { media.allSatisfy { $0.port != nil } }
            for i in ids.indices {
                let proxy = try MediaBlackhole(target: #require(media[1-i].port))
                proxies.append(proxy)
                media[i].connect(to: ids[1-i], nonce: media[1-i].serviceNonce,
                    endpoint: .hostPort(host: .ipv4(.loopback), port: proxy.port))
            }
            try await requireContinuity("Native UDP send acceptance") {
                media[0].isReady(for: ids[1]) && media[1].isReady(for: ids[0])
            }
            for manager in managers { await manager.startMedia() }
            func send(_ marker: UInt32) async {
                var bytes = marker.bigEndian
                var payload = withUnsafeBytes(of: &bytes) { Data($0) }
                payload.append(Data(repeating: 0x71, count: 956))
                for manager in managers {
                    await manager.sendAudioPacket(.init(sequenceNumber: UInt64(marker), codec: .pcm16,
                        format: .init(sampleRate: 24000, channelCount: 1), payload: payload))
                }
            }
            if !blockedAtStart {
                for marker in UInt32(1)...100 {
                    await send(marker)
                    if media[0].hasRecentMediaReceipt(for: ids[1]) && media[1].hasRecentMediaReceipt(for: ids[0]) {
                        break
                    }
                    try await Task.sleep(for: .milliseconds(20))
                }
                #expect(media[0].hasRecentMediaReceipt(for: ids[1]) && media[1].hasRecentMediaReceipt(for: ids[0]))
            }
            proxies[0].setBlocked(true)
            if bothDirections { proxies[1].setBlocked(true) }
            for marker in UInt32(1000)...1099 {
                await send(marker)
                try await Task.sleep(for: .milliseconds(20))
            }
            for record in records {
                try await requireContinuity("Fresh media arrives over the surviving route") {
                    await record.has(1099)
                }
            }
            #expect(media[0].isReady(for: ids[1]) && !media[0].hasRecentMediaReceipt(for: ids[1]))
            if bothDirections { #expect(media[1].isReady(for: ids[0]) && !media[1].hasRecentMediaReceipt(for: ids[0])) }
            #expect(await internet[0].mediaSends > 0)
            let fallbackDispatch = try #require(await managers[0].networkDiagnostics().outboundAudioDispatch)
            #expect(fallbackDispatch.transportAcceptance == [.multipeer: true, .webRTC: true],
                "The network can drop Local packets after the backend has accepted them")
            #expect(
                await server.forwardedMedia > 0,
                "Fallback must cross native DTLS/SCTP, not a manufactured route event")
            let control = ApplicationDataMessage(namespace: "control-proof", payload: Data([1]))
            for route in local { _ = await route.sendApplicationData(control) }
            for record in records {
                try await requireContinuity("QUIC still carries reliable control") {
                    await record.localControl.contains(control)
                }
            }
            #expect(proxies[0].droppedCount > 0)
            if bothDirections { #expect(proxies[1].droppedCount > 0) }
            for proxy in proxies { proxy.setBlocked(false) }
            for marker in UInt32(2000)...2100 {
                await send(marker)
                if media[0].hasRecentMediaReceipt(for: ids[1]) && media[1].hasRecentMediaReceipt(for: ids[0]) { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(media[0].hasRecentMediaReceipt(for: ids[1]) && media[1].hasRecentMediaReceipt(for: ids[0]))
            let before = [await internet[0].mediaSends, await internet[1].mediaSends]
            await send(3000)
            for record in records {
                try await requireContinuity("New media arrives after Local recovery") { await record.has(3000) }
            }
            let after = [await internet[0].mediaSends, await internet[1].mediaSends]
            #expect(after == before, "Proven Local paths suppress unnecessary Internet copies")
            for i in ids.indices {
                let dispatch = try #require(await managers[i].networkDiagnostics().outboundAudioDispatch)
                #expect(dispatch.transportAcceptance == [.multipeer: true])
                #expect(dispatch.internetCoveredByLocal)
                let markers = await records[i].markers
                #expect(
                    Set(markers).count == markers.count,
                    "Multiple native copies are delivered to the receiver only once")
                if !blockedAtStart && (i == 1 || bothDirections) {
                    #expect(!markers.contains(1000), "Lost old speech is not replayed")
                }
                #expect(await records[i].localPeers == [ids[1-i]])
                #expect(await records[i].errors.isEmpty)
                #expect(await internet[i].starts == 1, "Recovery must not restart the group")
            }
            for manager in managers { await manager.stopConnection() }
            let stopped = [await records[0].markers.count, await records[1].markers.count]
            await send(4000)
            try await Task.sleep(for: .milliseconds(100))
            for i in ids.indices {
                #expect(await records[i].markers.count == stopped[i])
                #expect(!media[i].hasRecentMediaReceipt(for: ids[1 - i]))
            }
        } catch {
            for manager in managers { await manager.stopConnection() }
            for proxy in proxies { proxy.stop() }
            await server.stop()
            throw error
        }
        for proxy in proxies { proxy.stop() }
        await server.stop()
    }
}
