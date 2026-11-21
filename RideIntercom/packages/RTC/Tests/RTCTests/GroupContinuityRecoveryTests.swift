import Foundation
import Testing
@testable import RTC

extension RealtimeTransportTests.GroupContinuityTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func independentNetworkFailuresRecoverInEitherOrder(internetOnlyPeerFirst: Bool) async throws {
        let network = ContinuityVirtualNetwork()
        let ids = ["nearby", "gateway-a", "remote", "gateway-b"].map { PeerID(rawValue: $0) }
        let kinds: [Set<RouteKind>] = [[.multipeer], [.multipeer, .webRTC], [.webRTC], [.multipeer, .webRTC]]
        let credential = RTCCredential.derived(groupID: "changing-networks", secret: "fixture")
        var riders: [ContinuityRider] = []
        var listeners: [Task<Void, Never>] = []
        for (id, routes) in zip(ids, kinds) {
            let configuration = CallRouteConfiguration(
                enabledRoutes: routes, preferredRoute: routes.contains(.multipeer) ? .multipeer : .webRTC,
                fallbackDelay: 0
            )
            let rider = ContinuityRider(id: id, routeKinds: routes, network: network,
                                       initialConfiguration: configuration)
            listeners.append(rider.listen())
            riders.append(rider)
            await rider.start(sessionID: "changing-networks", displayName: "Rider",
                              credential: credential, configuration: configuration)
        }
        defer { listeners.forEach { $0.cancel() } }
        try await verifyIndependentNetworkRecovery(
            riders: riders, network: network, internetOnlyPeerFirst: internetOnlyPeerFirst
        )
        for rider in riders { await rider.manager.stopConnection() }
    }

    private func verifyIndependentNetworkRecovery(
        riders: [ContinuityRider],
        network: ContinuityVirtualNetwork,
        internetOnlyPeerFirst: Bool
    ) async throws {
        let ids = riders.map(\.id)
        let records = riders.map(\.record)
        try await waitForMembershipCount(3, in: records)
        let originalMembers = await records[0].members
        func send(_ sender: Int, marker: UInt8, to recipients: [Int]) async throws {
            await riders[sender].sendAudio(marker: marker)
            for recipient in recipients {
                try await eventually("Fresh audio marker \(marker) from \(sender) to \(recipient)") {
                    await records[recipient].audio.contains {
                        $0.peerID == ids[sender] && $0.packet.payload.first == marker
                    }
                }
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
        try await eventually("Second recovered Internet route", timeout: .seconds(12)) {
            await network.isJoined(ids[second], kind: .webRTC)
        }
        try await send(0, marker: 5, to: [1, 2, 3])
        try await send(2, marker: 6, to: [0, 1, 3])

        // This Local route comes back on a network with no nearby participant.
        // Internet continues carrying the call; discovery is not connectivity.
        await network.restore(ids[3], kind: .multipeer)
        try await eventually("Late Local route after repeated failures", timeout: .seconds(20)) {
            await network.isJoined(ids[3], kind: .multipeer)
        }
        #expect(await network.reachablePeers(ids[3], kind: .multipeer).isEmpty)
        try await send(3, marker: 7, to: [0, 1, 2])
        await verifyMembershipContinuity(in: records, originalMembers: originalMembers)
        await verifyRouteRetries([
            (ids[1], .webRTC), (ids[2], .webRTC), (ids[3], .multipeer)
        ], on: network)
    }

    private func verifyMembershipContinuity(
        in records: [ContinuityCallRecorder],
        originalMembers: [CallMemberState]
    ) async {
        for member in originalMembers {
            let recoveredMember = await records[0].members.first { $0.peer.id == member.peer.id }
            #expect(recoveredMember?.membershipID == member.membershipID)
        }
        for record in records {
            #expect(await !record.audio.contains { $0.packet.payload.first == 250 })
            #expect(await !record.states.contains(.disconnected))
        }
    }

    private func verifyRouteRetries(
        _ routes: [(PeerID, RouteKind)], on network: ContinuityVirtualNetwork
    ) async {
        for (peer, kind) in routes {
            #expect(await network.attemptCount(peer, kind: kind) >= 2,
                    "Existing route retry must reconnect without another App start")
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func localOnlyMemberKeepsTalkingAcrossMixedRoutesAndGatewayDeparture(
        requiresAdmission: Bool
    ) async throws {
        let network = ContinuityVirtualNetwork()
        let ids = ["a", "b", "c", "d"].map(PeerID.init(rawValue:))
        let kinds: [Set<RouteKind>] = [[.multipeer], [.multipeer, .webRTC], [.webRTC], [.multipeer, .webRTC]]
        let credential = RTCCredential.derived(groupID: "group", secret: "secret")
        let audioPolicy = RTCAudioPolicy(peerPolicy: requiresAdmission ? .admittedMemberships([:]) : .groupMembers)
        let configurations = kinds.map { routes in
            CallRouteConfiguration(
                enabledRoutes: routes, preferredRoute: routes.contains(.multipeer) ? .multipeer : .webRTC,
                fallbackDelay: 0
            )
        }
        func start(_ rider: ContinuityRider, configuration: CallRouteConfiguration) async {
            await rider.start(sessionID: "group", displayName: rider.id.rawValue,
                              credential: credential, configuration: configuration, audioPolicy: audioPolicy)
        }
        var riders: [ContinuityRider] = []
        var listeners: [Task<Void, Never>] = []
        for index in ids.indices {
            let rider = ContinuityRider(id: ids[index], routeKinds: kinds[index], network: network,
                                       initialConfiguration: configurations[index])
            listeners.append(rider.listen())
            riders.append(rider)
            await start(rider, configuration: configurations[index])
        }
        defer { listeners.forEach { $0.cancel() } }
        let replacement = riders[3]
        try await verifyGatewayReplacement(riders: riders, requiresAdmission: requiresAdmission) {
            await start(replacement, configuration: configurations[3])
        }
    }

    private func verifyGatewayReplacement(
        riders: [ContinuityRider],
        requiresAdmission: Bool,
        restartGateway: () async -> Void
    ) async throws {
        let ids = riders.map(\.id)
        let managers = riders.map(\.manager)
        let records = riders.map(\.record)
        try await waitForMembershipCount(3, in: records)
        let cMembership = try #require(await records[0].members.first { $0.peer.id == ids[2] }?.membershipID)
        let aMembership = try #require(await records[2].members.first { $0.peer.id == ids[0] }?.membershipID)
        if requiresAdmission {
            // Only A and C play each other; both unapproved gateways still relay.
            await managers[0].updateAudioPolicy(.init(peerPolicy: .admittedMemberships([ids[2]: cMembership])))
            await managers[2].updateAudioPolicy(.init(peerPolicy: .admittedMemberships([ids[0]: aMembership])))
        }
        await managers[0].sendAudioPacket(gatewayAudio(1))
        await managers[2].sendAudioPacket(gatewayAudio(2))
        try await eventually {
            await records[2].audio.contains { $0.peerID == ids[0] && $0.packet.payload.first == 1 }
        }
        try await eventually {
            await records[0].audio.contains { $0.peerID == ids[2] && $0.packet.payload.first == 2 }
        }
        let observed = await managers[0].networkDiagnostics()
        #expect(observed.peers.contains { $0.peerID == ids[2] && $0.path.count == 3 && $0.route == .multipeer })
        // Muting/stopping the gateway's own audio does not stop forwarding others.
        await managers[1].setLocalMute(true)
        await managers[1].stopMedia()
        await managers[3].stopConnection()
        await managers[0].sendAudioPacket(gatewayAudio(3))
        try await eventually { await records[2].audio.contains(where: { $0.packet.payload.first == 3 }) }
        // Join a replacement gateway, then remove B without reconnecting A or C.
        await restartGateway()
        try await eventually { await records[3].memberCount == 3 }
        await managers[1].stopConnection()
        await managers[0].sendAudioPacket(gatewayAudio(4))
        try await eventually { await records[2].audio.contains(where: { $0.packet.payload.first == 4 }) }
        try await eventually {
            let paths = await managers[2].networkDiagnostics().peers
            return paths.contains { $0.peerID == ids[0] && $0.path == [ids[0], ids[3], ids[2]] }
        }
        #expect(await records[0].members.first { $0.peer.id == ids[2] }?.membershipID == cMembership)
        #expect(await records[2].members.first { $0.peer.id == ids[0] }?.membershipID == aMembership)
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

private func gatewayAudio(_ marker: UInt8) -> RTCAudioPacket {
    .init(
        sequenceNumber: 1,
        codec: .pcm16,
        format: .init(sampleRate: 16000, channelCount: 1),
        payload: Data(repeating: marker, count: 640)
    )
}
