import Foundation
import Testing
@testable import RTC

extension RealtimeTransportTests {
@Suite struct GroupContinuityTests {
    @Test(.timeLimit(.minutes(1)))
    func fourRidersRelayAlongALineAndRejoinAfterTheMiddleRiderReturns() async throws {
        let ids = ["a", "b", "c", "d"].map { PeerID(rawValue: $0) }
        let network = VirtualNetwork(internetAvailable: false, localLine: ids)
        let configuration = CallRouteConfiguration(enabledRoutes: [.multipeer], preferredRoute: .multipeer)
        let credential = RTCCredential.derived(groupID: "line", secret: "fixture")
        let managers = ids.map { id in
            RouteManager(routes: [VirtualRoute(peer: id, kind: .multipeer, network: network)],
                configuration: configuration, runtimeStatusPolicy: .init(isAutomaticBroadcastEnabled: false))
        }
        let records = ids.map { _ in CallRecorder() }
        let listeners = managers.indices.map { i in
            let events = managers[i].events
            return Task { for await event in events { await records[i].record(event) } }
        }
        defer { listeners.forEach { $0.cancel() } }
        for i in ids.indices {
            await managers[i].prepare(.init(sessionID: "line", localPeer: .init(id: ids[i], displayName: ids[i].rawValue),
                credential: credential, configuration: configuration))
            await managers[i].startConnection()
            await managers[i].startMedia()
        }
        func send(_ i: Int, _ marker: UInt8) async {
            await managers[i].sendAudioPacket(.init(sequenceNumber: UInt64(marker), codec: .pcm16,
                payload: Data(repeating: marker, count: 960)))
        }
        func assertAllDirections(_ offset: Int) async throws {
            for record in records { try await eventually { await record.memberCount == 3 } }
            for i in ids.indices { await send(i, UInt8(offset + i)) }
            for i in ids.indices {
                for j in ids.indices where j != i {
                    try await eventually {
                        await records[j].audio.filter { $0.peerID == ids[i] && $0.packet.payload.first == UInt8(offset + i) }.count == 1
                    }
                }
            }
        }

        try await assertAllDirections(0)
        #expect(await managers[3].networkDiagnostics().peers.contains { $0.peerID == ids[0] && $0.path == ids })
        #expect(await network.localAudioSendCount(for: ids[0]) == 1, "The first rider only sends their own audio")
        #expect(await network.localAudioSendCount(for: ids[3]) == 1, "The last rider only sends their own audio")
        await network.fail(ids[1], kind: .multipeer)
        #expect(await network.reachablePeers(ids[0], kind: .multipeer).isEmpty)
        await send(0, 21)
        await send(2, 22)
        try await eventually { await records[3].audio.contains { $0.packet.payload.first == 22 } }
        await network.restore(ids[1], kind: .multipeer)
        try await eventually("The middle rider retries the Local route", timeout: .seconds(15)) {
            await network.isJoined(ids[1], kind: .multipeer)
        }
        try await assertAllDirections(30)
        for i in ids.indices {
            let markers = await records[i].audio.compactMap { $0.packet.payload.first }
            #expect(!markers.contains(21))
            for j in ids.indices where j != i {
                #expect(markers.filter { $0 == UInt8(j) }.count == 1)
                #expect(markers.filter { $0 == UInt8(30 + j) }.count == 1)
            }
            await managers[i].stopConnection()
        }
    }

    enum CredentialTopology: String, CaseIterable, Sendable {
        case localDirect, localRelay, internet, mixed

        var routes: [Set<RouteKind>] {
            switch self {
            case .localDirect, .localRelay: [[.multipeer], [.multipeer], [.multipeer]]
            case .internet: [[.webRTC], [.webRTC], [.webRTC]]
            case .mixed: [[.multipeer], [.multipeer, .webRTC], [.webRTC]]
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: CredentialTopology.allCases)
    func aNewCredentialSeparatesRetainedRidersFromThePreviousCall(topology: CredentialTopology) async throws {
        let ids = ["speaker", "remaining", "removed"].map { PeerID(rawValue: $0) }
        let kinds = topology.routes
        let network = VirtualNetwork(localLine: topology == .localRelay ? ids : [])
        let configurations = kinds.map { routes in
            CallRouteConfiguration(enabledRoutes: routes,
                preferredRoute: routes.contains(.multipeer) ? .multipeer : .webRTC, fallbackDelay: 0)
        }
        let sessionID = "credential-\(topology.rawValue)"
        let original = RTCCredential.derived(groupID: sessionID, secret: "before-removal")
        let replacement = RTCCredential.derived(groupID: sessionID, secret: "after-removal")
        let managers = ids.indices.map { i in
            RouteManager(routes: kinds[i].map { VirtualRoute(peer: ids[i], kind: $0, network: network) },
                configuration: configurations[i], runtimeStatusPolicy: .init(isAutomaticBroadcastEnabled: false))
        }
        let records = ids.map { _ in CallRecorder() }
        let listeners = managers.indices.map { i in
            let events = managers[i].events
            return Task { for await event in events { await records[i].record(event) } }
        }
        defer { listeners.forEach { $0.cancel() } }
        func start(_ index: Int, credential: RTCCredential) async {
            await managers[index].prepare(.init(sessionID: sessionID, localPeer: .init(id: ids[index], displayName: "Rider"),
                credential: credential, configuration: configurations[index]))
            await managers[index].startConnection()
            await managers[index].startMedia()
        }
        func send(_ index: Int, marker: UInt8) async {
            await managers[index].sendAudioPacket(.init(sequenceNumber: UInt64(marker), codec: .pcm16,
                payload: Data(repeating: marker, count: 960)))
        }
        func markers(on index: Int) async -> Set<UInt8> {
            Set(await records[index].audio.compactMap { $0.packet.payload.first })
        }
        func stop() async {
            for manager in managers { await manager.stopConnection() }
        }

        do {
            for index in ids.indices { await start(index, credential: original) }
            for record in records { try await eventually { await record.memberCount == 2 } }
            await send(0, marker: 1)
            try await eventually { await markers(on: 1).contains(1) }
            try await eventually { await markers(on: 2).contains(1) }

            // All three still share transport paths. Only two know the new credential.
            await start(0, credential: replacement)
            await start(1, credential: replacement)
            try await eventually { await records[0].members.map(\.peer.id) == [ids[1]] }
            try await eventually { await records[1].members.map(\.peer.id) == [ids[0]] }
            let removedRoute: RouteKind = kinds[2].contains(.multipeer) ? .multipeer : .webRTC
            #expect(await network.reachablePeers(ids[2], kind: removedRoute).contains(ids[1]))

            await send(2, marker: 2)
            await send(0, marker: 3); await send(1, marker: 4)
            try await eventually { await markers(on: 1).contains(3) }
            try await eventually { await markers(on: 0).contains(4) }
            #expect(await markers(on: 2) == [1])
            #expect(await !markers(on: 0).contains(2))
            #expect(await !markers(on: 1).contains(2))
            await stop()
        } catch {
            await stop()
            throw error
        }
    }

    @Test(.timeLimit(.minutes(1))) func eightLocalPeersTalkWhileInternetIsUnavailable() async throws {
        let network = VirtualNetwork(internetAvailable: false)
        var managers: [RouteManager] = [], records: [CallRecorder] = [], tasks: [Task<Void, Never>] = []
        for i in 0..<8 {
            let id = PeerID(rawValue: "offline-\(i)")
            let config = CallRouteConfiguration(enabledRoutes: [.multipeer, .webRTC], preferredRoute: .multipeer, fallbackDelay: 0)
            let manager = RouteManager(routes: [RouteKind.multipeer, .webRTC].map { VirtualRoute(peer: id, kind: $0, network: network) },
                runtimeStatusPolicy: .init(isAutomaticBroadcastEnabled: false))
            let record = CallRecorder(), events = manager.events
            tasks.append(Task { for await event in events { await record.record(event) } })
            managers.append(manager); records.append(record)
            await manager.prepare(.init(sessionID: "offline", localPeer: .init(id: id, displayName: "Rider"),
                credential: .derived(groupID: "offline", secret: "fixture"), configuration: config))
            await manager.startConnection(); await manager.startMedia()
        }
        defer { tasks.forEach { $0.cancel() } }
        for record in records { try await eventually { await record.memberCount == 7 } }
        for i in managers.indices {
            await managers[i].sendAudioPacket(.init(sequenceNumber: 0, codec: .pcm16, payload: Data(repeating: UInt8(i), count: 960)))
        }
        for i in records.indices {
            try await eventually { await records[i].audio.count == 7 }
            let received = await records[i].audio
            let diagnostics = await managers[i].networkDiagnostics()
            #expect(diagnostics.eventDrops.expired == 0, "Healthy local audio must not expire in the consumer mailbox")
            #expect(diagnostics.eventDrops.overflow == 0)
            #expect(Set(received.compactMap { $0.packet.payload.first }) == Set((0..<8).filter { $0 != i }.map(UInt8.init)))
        }
        #expect(await network.routes[.webRTC] == nil)
        for manager in managers { await manager.stopConnection() }
    }

    @Test(.timeLimit(.minutes(1))) func outboundAudioDiagnosticsFollowLocalCoverageAndInternetFallback() async throws {
        let network = VirtualNetwork()
        let ids = ["speaker", "nearby", "remote"].map(PeerID.init(rawValue:))
        let kinds: [RouteKind] = [.multipeer, .webRTC]
        let config = CallRouteConfiguration(enabledRoutes: Set(kinds), preferredRoute: .multipeer, fallbackDelay: 0)
        let managers = ids.map { id in
            RouteManager(routes: kinds.map { VirtualRoute(peer: id, kind: $0, network: network) },
                runtimeStatusPolicy: .init(isAutomaticBroadcastEnabled: false))
        }
        let records = ids.map { _ in CallRecorder() }
        let listeners = managers.indices.map { i in
            let events = managers[i].events
            return Task { for await event in events { await records[i].record(event) } }
        }
        defer { listeners.forEach { $0.cancel() } }
        for i in ids.indices {
            await managers[i].prepare(.init(sessionID: "outbound", localPeer: .init(id: ids[i], displayName: ids[i].rawValue),
                credential: .derived(groupID: "outbound", secret: "fixture"), configuration: config))
            await managers[i].startConnection()
            await managers[i].startMedia()
        }
        for id in ids { try await eventually { await network.isJoined(id, kind: .webRTC) } }
        for record in records { try await eventually { await record.memberCount == 2 } }
        let speaker = managers[0]
        func send(_ marker: UInt8) async {
            await speaker.sendAudioPacket(.init(sequenceNumber: UInt64(marker), codec: .pcm16,
                payload: Data(repeating: marker, count: 960)))
        }

        #expect(await speaker.networkDiagnostics().outboundAudioDispatch == nil)
        await send(1)
        for record in records.dropFirst() {
            try await eventually { await record.audio.contains { $0.packet.payload.first == 1 } }
        }
        let local = try #require(await speaker.networkDiagnostics().outboundAudioDispatch)
        #expect(local.offeredRoutes == [.multipeer])
        #expect(local.internetCoveredByLocal)
        #expect(local.transportAcceptance == [.multipeer: true])
        #expect(await managers[1].networkDiagnostics().peers.contains { $0.peerID == ids[0] })
        #expect(await managers[1].networkDiagnostics().outboundAudioDispatch == nil)

        await network.moveLocalPeer(ids[2], to: "other-network")
        await send(2)
        for record in records.dropFirst() {
            try await eventually { await record.audio.contains { $0.packet.payload.first == 2 } }
        }
        let mixed = try #require(await speaker.networkDiagnostics().outboundAudioDispatch)
        #expect(mixed.offeredRoutes == [.multipeer, .webRTC])
        #expect(!mixed.internetCoveredByLocal)
        #expect(mixed.observedAt >= local.observedAt)
        #expect(mixed.transportAcceptance == [.multipeer: true, .webRTC: true])

        await network.moveLocalPeer(ids[1], to: "other-network")
        await send(3)
        for record in records.dropFirst() {
            try await eventually { await record.audio.contains { $0.packet.payload.first == 3 } }
        }
        let internet = try #require(await speaker.networkDiagnostics().outboundAudioDispatch)
        #expect(internet.offeredRoutes == [.multipeer, .webRTC])
        #expect(internet.transportAcceptance == [.multipeer: false, .webRTC: true])
        let encoded = try JSONEncoder().encode(internet)
        #expect(try JSONDecoder().decode(RTCOutboundAudioDispatch.self, from: encoded) == internet)
        for manager in managers { await manager.stopConnection() }
        #expect(await speaker.networkDiagnostics().outboundAudioDispatch == nil)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func independentNetworkFailuresRecoverInEitherOrder(internetOnlyPeerFirst: Bool) async throws {
        let network = VirtualNetwork()
        let ids = ["nearby", "gateway-a", "remote", "gateway-b"].map { PeerID(rawValue: $0) }
        let kinds: [Set<RouteKind>] = [[.multipeer], [.multipeer, .webRTC], [.webRTC], [.multipeer, .webRTC]]
        var managers: [RouteManager] = [], records: [CallRecorder] = [], listeners: [Task<Void, Never>] = []
        for i in ids.indices {
            let configuration = CallRouteConfiguration(enabledRoutes: kinds[i],
                preferredRoute: kinds[i].contains(.multipeer) ? .multipeer : .webRTC, fallbackDelay: 0)
            let manager = RouteManager(routes: kinds[i].map { VirtualRoute(peer: ids[i], kind: $0, network: network) },
                configuration: configuration, runtimeStatusPolicy: .init(isAutomaticBroadcastEnabled: false))
            let record = CallRecorder(), events = manager.events
            listeners.append(Task { for await event in events { await record.record(event) } })
            managers.append(manager); records.append(record)
            await manager.prepare(.init(sessionID: "changing-networks", localPeer: .init(id: ids[i], displayName: "Rider"),
                credential: .derived(groupID: "changing-networks", secret: "fixture"), configuration: configuration))
            await manager.startConnection(); await manager.startMedia()
        }
        defer { listeners.forEach { $0.cancel() } }
        for record in records { try await eventually { await record.memberCount == 3 } }
        let originalMemberships = await records[0].members.map { ($0.peer.id, $0.membershipID) }
        func send(_ index: Int, marker: UInt8, to recipients: [Int]) async throws {
            await managers[index].sendAudioPacket(.init(sequenceNumber: UInt64(marker), codec: .pcm16,
                payload: Data(repeating: marker, count: 960)))
            for recipient in recipients {
                try await eventually("Fresh audio marker \(marker) from \(index) to \(recipient)") { await records[recipient].audio.contains { $0.peerID == ids[index] && $0.packet.payload.first == marker } }
            }
        }
        try await send(0, marker: 1, to: [1, 2, 3])
        // Separate endpoints lose different transports at the same time. Their
        // surviving Local / Internet routes must not be stopped as a group.
        await network.fail(ids[1], kind: .webRTC)
        await network.fail(ids[2], kind: .webRTC)
        await network.fail(ids[3], kind: .multipeer)
        await network.moveLocalPeer(ids[3], to: "another-network")
        try await send(0, marker: 2, to: [1])
        try await send(2, marker: 250, to: []) // Offline audio must never replay.

        let first = internetOnlyPeerFirst ? 2 : 1
        let second = internetOnlyPeerFirst ? 1 : 2
        await network.restore(ids[first], kind: .webRTC)
        try await eventually("First recovered Internet route") { await network.isJoined(ids[first], kind: .webRTC) }
        if internetOnlyPeerFirst {
            try await send(2, marker: 3, to: [3])
            try await send(0, marker: 4, to: [1])
        } else {
            try await send(0, marker: 3, to: [1, 3])
        }
        await network.restore(ids[second], kind: .webRTC)
        try await eventually("Second recovered Internet route", timeout: .seconds(12)) { await network.isJoined(ids[second], kind: .webRTC) }
        try await send(0, marker: 5, to: [1, 2, 3])
        try await send(2, marker: 6, to: [0, 1, 3])

        // This Local route comes back on a network with no nearby participant.
        // Internet continues carrying the call; discovery is not connectivity.
        await network.restore(ids[3], kind: .multipeer)
        try await eventually("Late Local route after repeated failures", timeout: .seconds(20)) { await network.isJoined(ids[3], kind: .multipeer) }
        #expect(await network.reachablePeers(ids[3], kind: .multipeer).isEmpty)
        try await send(3, marker: 7, to: [0, 1, 2])
        for (peer, membership) in originalMemberships {
            #expect(await records[0].members.first { $0.peer.id == peer }?.membershipID == membership)
        }
        for record in records {
            #expect(await !record.audio.contains { $0.packet.payload.first == 250 })
            #expect(await !record.states.contains(.disconnected))
        }
        for (peer, kind) in [(ids[1], RouteKind.webRTC), (ids[2], .webRTC), (ids[3], .multipeer)] {
            #expect(await network.attemptCount(peer, kind: kind) >= 2, "Existing route retry must reconnect without another App start")
        }
        for manager in managers { await manager.stopConnection() }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true]) func localOnlyMemberKeepsTalkingAcrossMixedRoutesAndGatewayDeparture(requiresAdmission: Bool) async throws {
        let network = VirtualNetwork()
        let ids = ["a", "b", "c", "d"]
        let kinds: [Set<RouteKind>] = [[.multipeer], [.multipeer, .webRTC], [.webRTC], [.multipeer, .webRTC]]
        var managers: [RouteManager] = [], records: [CallRecorder] = [], listeners: [Task<Void, Never>] = []
        for (i, id) in ids.enumerated() {
            let routes = kinds[i].map { VirtualRoute(peer: .init(rawValue: id), kind: $0, network: network) }
            let config = CallRouteConfiguration(enabledRoutes: kinds[i], preferredRoute: kinds[i].contains(.multipeer) ? .multipeer : .webRTC, fallbackDelay: 0)
            let manager = RouteManager(routes: routes, configuration: config, runtimeStatusPolicy: .init(isAutomaticBroadcastEnabled: false))
            let record = CallRecorder(), events = manager.events
            listeners.append(Task { for await event in events { await record.record(event) } })
            managers.append(manager); records.append(record)
            await manager.prepare(.init(sessionID: "group", localPeer: .init(id: .init(rawValue: id), displayName: id), credential: .derived(groupID: "group", secret: "secret"), configuration: config,
                audioPolicy: .init(peerPolicy: requiresAdmission ? .admittedMemberships([:]) : .groupMembers)))
            await manager.startConnection(); await manager.startMedia()
        }
        defer { listeners.forEach { $0.cancel() } }
        for record in records { try await eventually { await record.memberCount == 3 } }
        let cMembership = try #require(await records[0].members.first { $0.peer.id.rawValue == "c" }?.membershipID)
        let aMembership = try #require(await records[2].members.first { $0.peer.id.rawValue == "a" }?.membershipID)
        if requiresAdmission {
            // Only A and C play each other; both unapproved gateways still relay.
            await managers[0].updateAudioPolicy(.init(peerPolicy: .admittedMemberships([.init(rawValue: "c"): cMembership])))
            await managers[2].updateAudioPolicy(.init(peerPolicy: .admittedMemberships([.init(rawValue: "a"): aMembership])))
        }
        func audio(_ marker: UInt8) -> RTCAudioPacket { .init(sequenceNumber: 1, codec: .pcm16, format: .init(sampleRate: 16000, channelCount: 1), payload: Data(repeating: marker, count: 640)) }
        await managers[0].sendAudioPacket(audio(1)); await managers[2].sendAudioPacket(audio(2))
        try await eventually { await records[2].audio.contains(where: { $0.peerID.rawValue == "a" && $0.packet.payload.first == 1 }) }
        try await eventually { await records[0].audio.contains(where: { $0.peerID.rawValue == "c" && $0.packet.payload.first == 2 }) }
        let observed = await managers[0].networkDiagnostics()
        #expect(observed.peers.contains { $0.peerID.rawValue == "c" && $0.path.count == 3 && $0.route == .multipeer })
        // Muting/stopping the gateway's own audio does not stop forwarding others.
        await managers[1].setLocalMute(true); await managers[1].stopMedia()
        await managers[3].stopConnection()
        await managers[0].sendAudioPacket(audio(3))
        try await eventually { await records[2].audio.contains(where: { $0.packet.payload.first == 3 }) }
        // Join a replacement gateway, then remove B without reconnecting A or C.
        let dconfig = CallRouteConfiguration(enabledRoutes: kinds[3], preferredRoute: .multipeer, fallbackDelay: 0)
        await managers[3].prepare(.init(sessionID: "group", localPeer: .init(id: .init(rawValue: "d"), displayName: "d"), credential: .derived(groupID: "group", secret: "secret"), configuration: dconfig,
            audioPolicy: .init(peerPolicy: requiresAdmission ? .admittedMemberships([:]) : .groupMembers)))
        await managers[3].startConnection(); await managers[3].startMedia()
        try await eventually { await records[3].memberCount == 3 }
        await managers[1].stopConnection()
        await managers[0].sendAudioPacket(audio(4))
        try await eventually { await records[2].audio.contains(where: { $0.packet.payload.first == 4 }) }
        try await eventually {
            let paths = await managers[2].networkDiagnostics().peers
            return paths.contains { $0.peerID.rawValue == "a" && $0.path.map(\.rawValue) == ["a", "d", "c"] }
        }
        #expect(await records[0].members.first { $0.peer.id.rawValue == "c" }?.membershipID == cMembership)
        #expect(await records[2].members.first { $0.peer.id.rawValue == "a" }?.membershipID == aMembership)
        if requiresAdmission {
            #expect(await records[1].audio.isEmpty)
            #expect(await records[3].audio.isEmpty)
        }
        #expect(await records[2].audio.filter { $0.packet.payload.first == 1 }.count == 1)
        for manager in managers {
            await manager.stopConnection()
            #expect(await manager.networkDiagnostics().peers.isEmpty)
        }
    }
}

}

private actor CallRecorder {
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
private actor VirtualNetwork {
    var routes: [RouteKind: [PeerID: EventSource<RouteEvent>]] = [:]
    let internetAvailable: Bool
    private var unavailable: [RouteKind: Set<PeerID>] = [:]
    private var attempts: [RouteKind: [PeerID: Int]] = [:]
    private var localAudioSends: [PeerID: Int] = [:]
    private var localNetworks: [PeerID: String] = [:]
    private let localLine: [PeerID]
    init(internetAvailable: Bool = true, localLine: [PeerID] = []) {
        self.internetAvailable = internetAvailable
        self.localLine = localLine
    }
    func join(_ peer: PeerID, kind: RouteKind, source: EventSource<RouteEvent>) {
        attempts[kind, default: [:]][peer, default: 0] += 1
        if (kind == .webRTC && !internetAvailable) || unavailable[kind, default: []].contains(peer) {
            source.yield(.stateChanged(kind, .failed)); return
        }
        routes[kind, default: [:]][peer] = source
        publish(kind)
    }
    func leave(_ peer: PeerID, kind: RouteKind) { routes[kind]?[peer] = nil; publish(kind) }
    func fail(_ peer: PeerID, kind: RouteKind) {
        unavailable[kind, default: []].insert(peer)
        let source = routes[kind]?[peer]
        leave(peer, kind: kind)
        source?.yield(.membersChanged(kind, []))
        source?.yield(.stateChanged(kind, .failed))
    }
    func restore(_ peer: PeerID, kind: RouteKind) { unavailable[kind]?.remove(peer) }
    func moveLocalPeer(_ peer: PeerID, to network: String) { localNetworks[peer] = network; publish(.multipeer) }
    func isJoined(_ peer: PeerID, kind: RouteKind) -> Bool { routes[kind]?[peer] != nil }
    func attemptCount(_ peer: PeerID, kind: RouteKind) -> Int { attempts[kind]?[peer] ?? 0 }
    func localAudioSendCount(for peer: PeerID) -> Int { localAudioSends[peer, default: 0] }
    func reachablePeers(_ peer: PeerID, kind: RouteKind) -> Set<PeerID> {
        guard routes[kind]?[peer] != nil else { return [] }
        return Set(routes[kind, default: [:]].keys.filter { other in
            if kind == .multipeer, !localLine.isEmpty {
                guard let i = localLine.firstIndex(of: peer), let j = localLine.firstIndex(of: other) else { return false }
                return abs(i - j) == 1
            }
            return other != peer && (kind != .multipeer || localNetworks[other, default: "nearby"] == localNetworks[peer, default: "nearby"])
        })
    }
    func send(_ peer: PeerID, kind: RouteKind, message: ApplicationDataMessage) {
        if kind == .multipeer && message.delivery == .unreliable { localAudioSends[peer, default: 0] += 1 }
        for other in reachablePeers(peer, kind: kind) {
            routes[kind]?[other]?.yield(.receivedApplicationData(kind, .init(peerID: peer, message: message)))
        }
    }
    func publish(_ kind: RouteKind) {
        for (peer, source) in routes[kind, default: [:]] {
            let members = reachablePeers(peer, kind: kind).map { CallMemberState(peer: .init(id: $0, displayName: $0.rawValue), route: kind, isConnected: true) }
            source.yield(.membersChanged(kind, members)); source.yield(.stateChanged(kind, kind == .webRTC ? .mediaReady : .authenticated))
        }
    }
}
private actor VirtualRoute: RTCCallRoute {
    let peer: PeerID
    let kind: RouteKind
    let network: VirtualNetwork
    nonisolated let source = EventSource<RouteEvent>()
    nonisolated var events: AsyncStream<RouteEvent> { source.stream }
    let capabilities = RouteCapabilities(supportsLocalDiscovery: true, supportsOfflineOperation: true, supportsReliableApplicationData: true, supportsUnreliableApplicationData: true, requiresSignaling: false, supportedAudioCodecs: [.pcm16])
    init(peer: PeerID, kind: RouteKind, network: VirtualNetwork) { self.peer = peer; self.kind = kind; self.network = network }
    func prepare(_ request: CallStartRequest) async {}
    func startConnection() async { await network.join(peer, kind: kind, source: source) }
    func stopConnection() async { await network.leave(peer, kind: kind) }
    func sendApplicationData(_ message: ApplicationDataMessage) async -> RTCRouteSendResult {
        await network.send(peer, kind: kind, message: message)
        let recipients = await network.reachablePeers(peer, kind: kind)
        return .init(transportAccepted: !recipients.isEmpty, verifiedLocalRecipients: kind == .multipeer ? recipients : [])
    }
}
private func eventually(_ description: String = "Group continuity condition timed out", timeout: Duration = .seconds(6),
                        _ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(await predicate(), Comment(rawValue: description))
}
