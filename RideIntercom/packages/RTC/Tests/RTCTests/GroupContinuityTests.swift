import Foundation
import Testing
@testable import RTC

extension RealtimeTransportTests {
    @Suite struct GroupContinuityTests {}
}

extension RealtimeTransportTests.GroupContinuityTests {
    @Test(.timeLimit(.minutes(1)))
    func fourRidersRelayAlongALineAndRejoinAfterTheMiddleRiderReturns() async throws {
        let ids = ["a", "b", "c", "d"].map { PeerID(rawValue: $0) }
        let network = ContinuityVirtualNetwork(internetAvailable: false, localLine: ids)
        let configuration = CallRouteConfiguration(enabledRoutes: [.multipeer], preferredRoute: .multipeer)
        let credential = RTCCredential.derived(groupID: "line", secret: "fixture")
        let riders = ids.map {
            ContinuityRider(id: $0, routeKinds: [RouteKind.multipeer], network: network,
                            initialConfiguration: configuration)
        }
        let listeners = riders.map { $0.listen() }
        defer { listeners.forEach { $0.cancel() } }
        for rider in riders {
            await rider.start(sessionID: "line", displayName: rider.id.rawValue,
                              credential: credential, configuration: configuration)
        }
        let managers = riders.map(\.manager)
        let records = riders.map(\.record)

        try await assertAllDirections(riders: riders, offset: 0)
        #expect(await managers[3].networkDiagnostics().peers.contains { $0.peerID == ids[0] && $0.path == ids })
        #expect(await network.audioSendCount(for: ids[0], kind: .multipeer) == 1,
                "The first rider only sends their own audio")
        #expect(await network.audioSendCount(for: ids[3], kind: .multipeer) == 1,
                "The last rider only sends their own audio")
        await network.fail(ids[1], kind: .multipeer)
        #expect(await network.reachablePeers(ids[0], kind: .multipeer).isEmpty)
        await riders[0].sendAudio(marker: 21)
        await riders[2].sendAudio(marker: 22)
        try await eventually { await records[3].audio.contains { $0.packet.payload.first == 22 } }
        await network.restore(ids[1], kind: .multipeer)
        try await eventually("The middle rider retries the Local route", timeout: .seconds(15)) {
            await network.isJoined(ids[1], kind: .multipeer)
        }
        try await assertAllDirections(riders: riders, offset: 30)
        for receiver in ids.indices {
            let markers = await records[receiver].audio.compactMap { $0.packet.payload.first }
            #expect(!markers.contains(21))
            for sender in ids.indices where sender != receiver {
                #expect(markers.filter { $0 == UInt8(sender) }.count == 1)
                #expect(markers.filter { $0 == UInt8(30 + sender) }.count == 1)
            }
            await managers[receiver].stopConnection()
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func localGatewayOnlyUsesInternetWhenAnUnreachedPeerCanReceive() async throws {
        let network = ContinuityVirtualNetwork()
        let local = CallRouteConfiguration(enabledRoutes: [.multipeer], preferredRoute: .multipeer)
        let mixed = CallRouteConfiguration(enabledRoutes: [.multipeer, .webRTC],
                                          preferredRoute: .multipeer, fallbackDelay: 0)
        let internet = CallRouteConfiguration(enabledRoutes: [.webRTC], preferredRoute: .webRTC)
        let speaker = ContinuityRider(id: .init(rawValue: "speaker"), routeKinds: [.multipeer], network: network)
        let gateway = ContinuityRider(id: .init(rawValue: "gateway"),
                                      routeKinds: [.multipeer, .webRTC], network: network)
        let listener = ContinuityRider(id: .init(rawValue: "listener"), routeKinds: [.webRTC], network: network)
        let session = "local-gateway"
        let credential = RTCCredential.derived(groupID: session, secret: "fixture")
        let recorders = [gateway.listen(), listener.listen()]
        defer { recorders.forEach { $0.cancel() } }

        try await withConnectionCleanup([speaker, gateway, listener]) {
            await speaker.start(sessionID: session, displayName: "Speaker",
                                credential: credential, configuration: local)
            await gateway.start(sessionID: session, displayName: "Gateway",
                                credential: credential, configuration: mixed)
            // The SFU lists the speaker before their presence advertises Internet readiness.
            await network.join(speaker.id, kind: .webRTC, source: EventSource<RouteEvent>())
            try await eventually("Gateway connects on both routes") {
                let members = await gateway.manager.routeMembers
                let ready = await gateway.manager.routeStates[.webRTC] == .mediaReady
                return ready && members[.webRTC] == [speaker.id] && members[.multipeer] == [speaker.id]
            }

            await speaker.sendAudio(marker: 1)
            try await eventually("First frame reaches gateway over Local") {
                await gateway.record.audio.contains { $0.peerID == speaker.id && $0.packet.payload.first == 1 }
            }

            await listener.start(sessionID: session, displayName: "Listener",
                                 credential: credential, configuration: internet)
            try await eventually("Listener sees the speaker's forwarded presence") {
                let members = await gateway.manager.routeMembers
                let speakerIsKnown = await listener.record.members.contains { $0.peer.id == speaker.id }
                return members[.webRTC] == [speaker.id, listener.id] && speakerIsKnown
            }
            await speaker.sendAudio(marker: 2)
            try await eventually("The second frame crosses through the gateway to the listener") {
                await listener.record.audio.contains { $0.peerID == speaker.id && $0.packet.payload.first == 2 }
            }
            let internetSends = await network.audioSendCount(for: gateway.id, kind: .webRTC)
            #expect(internetSends == 1,
                    "Only the frame with a new Internet recipient is forwarded")
        }
    }

    private func assertAllDirections(riders: [ContinuityRider], offset: Int) async throws {
        let ids = riders.map(\.id)
        let records = riders.map(\.record)
        try await waitForMembershipCount(3, in: records)
        for index in ids.indices { await riders[index].sendAudio(marker: UInt8(offset + index)) }
        for sender in ids.indices {
            let marker = UInt8(offset + sender)
            for receiver in ids.indices where receiver != sender {
                try await eventually {
                    await records[receiver].audio.filter {
                        $0.peerID == ids[sender] && $0.packet.payload.first == marker
                    }.count == 1
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: ContinuityCredentialTopology.allCases)
    func aNewCredentialSeparatesRetainedRidersFromThePreviousCall(topology: ContinuityCredentialTopology) async throws {
        let ids = ["speaker", "remaining", "removed"].map { PeerID(rawValue: $0) }
        let kinds = topology.routes
        let network = ContinuityVirtualNetwork(localLine: topology == .localRelay ? ids : [])
        let configurations = kinds.map { routes in
            CallRouteConfiguration(enabledRoutes: routes,
                preferredRoute: routes.contains(.multipeer) ? .multipeer : .webRTC, fallbackDelay: 0)
        }
        let sessionID = "credential-\(topology.rawValue)"
        let original = RTCCredential.derived(groupID: sessionID, secret: "before-removal")
        let replacement = RTCCredential.derived(groupID: sessionID, secret: "after-removal")
        let riders = ids.indices.map { index in
            ContinuityRider(id: ids[index], routeKinds: kinds[index], network: network,
                            initialConfiguration: configurations[index])
        }
        let listeners = riders.map { $0.listen() }
        defer { listeners.forEach { $0.cancel() } }
        let records = riders.map(\.record)
        func start(_ index: Int, credential: RTCCredential) async {
            await riders[index].start(sessionID: sessionID, displayName: "Rider",
                                      credential: credential, configuration: configurations[index])
        }
        func markers(on index: Int) async -> Set<UInt8> {
            Set(await records[index].audio.compactMap { $0.packet.payload.first })
        }

        try await withConnectionCleanup(riders) {
            for index in ids.indices { await start(index, credential: original) }
            try await waitForMembershipCount(2, in: records)
            await riders[0].sendAudio(marker: 1)
            try await eventually { await markers(on: 1).contains(1) }
            try await eventually { await markers(on: 2).contains(1) }

            // All three still share transport paths. Only two know the new credential.
            await start(0, credential: replacement)
            await start(1, credential: replacement)
            try await eventually { await records[0].members.map(\.peer.id) == [ids[1]] }
            try await eventually { await records[1].members.map(\.peer.id) == [ids[0]] }
            let removedRoute: RouteKind = kinds[2].contains(.multipeer) ? .multipeer : .webRTC
            #expect(await network.reachablePeers(ids[2], kind: removedRoute).contains(ids[1]))

            await riders[2].sendAudio(marker: 2)
            await riders[0].sendAudio(marker: 3)
            await riders[1].sendAudio(marker: 4)
            try await eventually { await markers(on: 1).contains(3) }
            try await eventually { await markers(on: 0).contains(4) }
            #expect(await markers(on: 2) == [1])
            #expect(await !markers(on: 0).contains(2))
            #expect(await !markers(on: 1).contains(2))
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func eightLocalPeersTalkWhileInternetIsUnavailable() async throws {
        let network = ContinuityVirtualNetwork(internetAvailable: false)
        let ids = (0..<8).map { PeerID(rawValue: "offline-\($0)") }
        let kinds: [RouteKind] = [.multipeer, .webRTC]
        let configuration = CallRouteConfiguration(
            enabledRoutes: Set(kinds), preferredRoute: .multipeer, fallbackDelay: 0
        )
        let credential = RTCCredential.derived(groupID: "offline", secret: "fixture")
        var riders: [ContinuityRider] = []
        var listeners: [Task<Void, Never>] = []
        for id in ids {
            let rider = ContinuityRider(id: id, routeKinds: kinds, network: network)
            listeners.append(rider.listen())
            riders.append(rider)
            await rider.start(sessionID: "offline", displayName: "Rider",
                              credential: credential, configuration: configuration)
        }
        defer { listeners.forEach { $0.cancel() } }
        let records = riders.map(\.record)
        try await waitForMembershipCount(7, in: records)
        for (index, rider) in riders.enumerated() {
            await rider.manager.sendAudioPacket(.init(
                sequenceNumber: 0,
                codec: .pcm16,
                payload: Data(repeating: UInt8(index), count: 960)
            ))
        }
        try await eventually("All eight peers receive their first seven frames") {
            for record in records where await record.audio.count != 7 { return false }
            return true
        }
        for (index, rider) in riders.enumerated() {
            let received = await rider.record.audio
            let diagnostics = await rider.manager.networkDiagnostics()
            let local = await network.eventDrops(for: rider.id, kind: .multipeer)
            #expect(local.expired == 0 && local.overflow == 0, "Receiver \(index): Local route mailbox \(local)")
            #expect(diagnostics.eventDrops.expired == 0, "Healthy local audio must not expire in the consumer mailbox")
            #expect(diagnostics.eventDrops.overflow == 0)
            let expectedMarkers = Set(ids.indices.filter { $0 != index }.map(UInt8.init))
            #expect(Set(received.compactMap { $0.packet.payload.first }) == expectedMarkers,
                    "Receiver \(index) saw \(received.count) packets")
        }
        #expect(await network.routes[.webRTC] == nil)
        for rider in riders { await rider.manager.stopConnection() }
    }

    @Test(.timeLimit(.minutes(1)))
    func outboundAudioDiagnosticsFollowLocalCoverageAndInternetFallback() async throws {
        let network = ContinuityVirtualNetwork()
        let ids = ["speaker", "nearby", "remote"].map(PeerID.init(rawValue:))
        let kinds: [RouteKind] = [.multipeer, .webRTC]
        let config = CallRouteConfiguration(enabledRoutes: Set(kinds), preferredRoute: .multipeer, fallbackDelay: 0)
        let credential = RTCCredential.derived(groupID: "outbound", secret: "fixture")
        let riders = ids.map { ContinuityRider(id: $0, routeKinds: kinds, network: network) }
        let listeners = riders.map { $0.listen() }
        defer { listeners.forEach { $0.cancel() } }
        for rider in riders {
            await rider.start(sessionID: "outbound", displayName: rider.id.rawValue,
                              credential: credential, configuration: config)
        }
        for id in ids { try await eventually { await network.isJoined(id, kind: .webRTC) } }
        let records = riders.map(\.record)
        try await waitForMembershipCount(2, in: records)
        let speaker = riders[0].manager
        func sendToBothListeners(_ marker: UInt8) async throws {
            await riders[0].sendAudio(marker: marker)
            for record in records.dropFirst() {
                try await eventually { await record.audio.contains { $0.packet.payload.first == marker } }
            }
        }

        #expect(await speaker.networkDiagnostics().outboundAudioDispatch == nil)
        try await sendToBothListeners(1)
        let local = try #require(await speaker.networkDiagnostics().outboundAudioDispatch)
        #expect(local.offeredRoutes == [.multipeer])
        #expect(local.internetCoveredByLocal)
        #expect(local.transportAcceptance == [.multipeer: true])
        #expect(await riders[1].manager.networkDiagnostics().peers.contains { $0.peerID == ids[0] })
        #expect(await riders[1].manager.networkDiagnostics().outboundAudioDispatch == nil)

        await network.moveLocalPeer(ids[2], to: "other-network")
        try await sendToBothListeners(2)
        let mixed = try #require(await speaker.networkDiagnostics().outboundAudioDispatch)
        #expect(mixed.offeredRoutes == [.multipeer, .webRTC])
        #expect(!mixed.internetCoveredByLocal)
        #expect(mixed.observedAt >= local.observedAt)
        #expect(mixed.transportAcceptance == [.multipeer: true, .webRTC: true])

        await network.moveLocalPeer(ids[1], to: "other-network")
        try await sendToBothListeners(3)
        let internet = try #require(await speaker.networkDiagnostics().outboundAudioDispatch)
        #expect(internet.offeredRoutes == [.multipeer, .webRTC])
        #expect(internet.transportAcceptance == [.multipeer: false, .webRTC: true])
        let encoded = try JSONEncoder().encode(internet)
        #expect(try JSONDecoder().decode(RTCOutboundAudioDispatch.self, from: encoded) == internet)
        for rider in riders { await rider.manager.stopConnection() }
        #expect(await speaker.networkDiagnostics().outboundAudioDispatch == nil)
    }

    func waitForMembershipCount(_ count: Int, in records: [ContinuityCallRecorder]) async throws {
        for record in records { try await eventually { await record.memberCount == count } }
    }

    func eventually(
        _ description: String = "Group continuity condition timed out",
        timeout: Duration = .seconds(6),
        _ predicate: () async -> Bool
    ) async throws {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(await predicate(), Comment(rawValue: description))
    }
}

enum ContinuityCredentialTopology: String, CaseIterable, Sendable {
    case localDirect, localRelay, internet, mixed

    var routes: [Set<RouteKind>] {
        switch self {
        case .localDirect, .localRelay: [[.multipeer], [.multipeer], [.multipeer]]
        case .internet: [[.webRTC], [.webRTC], [.webRTC]]
        case .mixed: [[.multipeer], [.multipeer, .webRTC], [.webRTC]]
        }
    }
}

private func withConnectionCleanup(_ riders: [ContinuityRider], _ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch {
        for rider in riders { await rider.manager.stopConnection() }
        throw error
    }
    for rider in riders { await rider.manager.stopConnection() }
}
