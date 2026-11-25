import Foundation
import Testing
@testable import RTC

@Test func codecIdentifiersAreTransportMetadataOnly() {
    #expect(RTCAudioCodecIdentifier.pcm16.rawValue == "pcm16")
    #expect(RTCAudioCodecIdentifier.mpeg4AACELDv2.rawValue == "mpeg4AACELDv2")
    #expect(RTCAudioCodecIdentifier.opus.rawValue == "opus")
}

@Test func routeManagerFiltersOptedOutRoutes() async {
    let multipeer = FakeRoute(kind: .multipeer)
    let webRTC = FakeRoute(kind: .webRTC)

    let configuration = CallRouteConfiguration(
        enabledRoutes: [.multipeer],
        preferredRoute: .multipeer,
        selectionMode: .singleRoute
    )

    let manager = RouteManager(routes: [multipeer, webRTC], configuration: configuration)

    await manager.prepare(makeRequest(configuration: configuration))
    await manager.startConnection()
    await manager.sendApplicationData(ApplicationDataMessage(namespace: "test", payload: Data([9])))

    #expect(multipeer.prepareCount == 1)
    #expect(multipeer.startConnectionCount == 1)
    #expect(relayMessages(multipeer.sentApplicationData).filter { $0.namespace == "test" }.count == 1)
    #expect(webRTC.prepareCount == 0)
    #expect(webRTC.startConnectionCount == 0)
    #expect(webRTC.sentApplicationData.isEmpty)
}

@Test func callSessionFactoryBuildsRoutesFromEnabledConfiguration() {
    let configuration = CallSessionFactoryConfiguration(
        routeConfiguration: CallRouteConfiguration(
            enabledRoutes: [.multipeer, .webRTC],
            preferredRoute: .multipeer
        )
    )

    let routeKinds = Set(CallSessionFactory.makeRoutes(configuration).map(\.kind))

    #if !os(watchOS)
    #expect(routeKinds == [.multipeer, .webRTC])
    #else
    #expect(routeKinds == [.webRTC])
    #endif
}

@Test func routeManagerAutomaticallyFallsBackToWebRTC() async {
    let multipeer = FakeRoute(kind: .multipeer)
    let webRTC = FakeRoute(kind: .webRTC)

    let configuration = CallRouteConfiguration(
        enabledRoutes: [.multipeer, .webRTC],
        preferredRoute: .multipeer,
        selectionMode: .automaticFallback,
        fallbackDelay: 0.01
    )

    let manager = RouteManager(routes: [multipeer, webRTC], configuration: configuration)

    await manager.prepare(makeRequest(configuration: configuration))
    await manager.startConnection()
    try? await Task.sleep(nanoseconds: 50_000_000)

    #expect(multipeer.startConnectionCount == 1)
    #expect(webRTC.startConnectionCount >= 1)
}

@Test func routeManagerEncapsulatesAudioOnlyOnStartedRoutes() async {
    let multipeer = FakeRoute(kind: .multipeer)
    let webRTC = FakeRoute(kind: .webRTC)

    let configuration = CallRouteConfiguration(enabledRoutes: [.multipeer, .webRTC], preferredRoute: .multipeer)
    let manager = RouteManager(routes: [multipeer, webRTC], configuration: configuration)

    await manager.prepare(makeRequest(configuration: configuration))
    await manager.startConnection()
    await manager.startMedia()
    await manager.sendAudioPacket(makePacket(sequenceNumber: 1))

    #expect(relayBodies(multipeer.sentApplicationData).contains { if case .audio = $0 { true } else { false } })
    #expect(webRTC.sentApplicationData.isEmpty)
}

private actor ReceivedPackets {
    var sequences: [UInt64] = []
    func record(_ event: CallSessionEvent) {
        if case .receivedAudioPacket(let packet) = event { sequences.append(packet.packet.sequenceNumber) }
    }
}

@Test func liveAudioPolicyUpdatePreservesTransportAndAcceptsNewCodec() async throws {
    let route = FakeRoute(kind: .multipeer)
    let configuration = CallRouteConfiguration(
        enabledRoutes: [.multipeer], preferredRoute: .multipeer, selectionMode: .singleRoute)
    let manager = RouteManager(routes: [route], configuration: configuration)
    let request = makeRequest(configuration: configuration)
    await manager.prepare(request); await manager.startConnection(); await manager.startMedia()
    let recorded = ReceivedPackets()
    let events = manager.events // Register before an immediately deliverable audio packet can arrive.
    let listener = Task { for await event in events { await recorded.record(event) } }
    defer { listener.cancel() }
    var remote = request
    remote.localPeer = .init(id: .init(rawValue: "remote"), displayName: "Remote")
    var relay = GroupRelay(request: remote)
    route.yield(.membersChanged(.multipeer, [.init(peer: remote.localPeer, route: .multipeer, isConnected: true)]))
    let changed = RTCAudioPolicy(preferredSendFormat: .init(sampleRate: 24_000), preferredCodecs: [.opus, .pcm16])
    await manager.updateAudioPolicy(changed)
    for body in [RelayBody.presence, .audio(makePacket(sequenceNumber: 77, codec: .opus))] {
        route.yield(.receivedApplicationData(.multipeer, .init(peerID: remote.localPeer.id,
            message: .init(namespace: GroupRelay.namespace, payload: try relay.make(body, now: 0)))))
    }
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while await recorded.sequences.isEmpty, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    // The relay owns sequence ordering independently of the encoder counter.
    #expect(await recorded.sequences == [0])
    #expect(route.prepareCount == 1)
    #expect(route.startConnectionCount == 1)
    await manager.stopConnection()
}

@Test(arguments: [RouteKind.multipeer, .webRTC])
func routeRetryWaitsOnceAndLetsTheNextAttemptFinish(kind: RouteKind) async throws {
    let route = FakeRoute(kind: kind)
    let configuration = CallRouteConfiguration(enabledRoutes: [kind], preferredRoute: kind, selectionMode: .singleRoute)
    let manager = RouteManager(routes: [route], configuration: configuration)
    await manager.prepare(makeRequest(configuration: configuration))
    await manager.startConnection()
    route.yield(.stateChanged(kind, .failed))
    route.yield(.stateChanged(kind, .disconnected))
    // Both events came from the same attempt, so the first two-second delay still applies.
    let deadline = ContinuousClock.now.advanced(by: .seconds(3))
    while route.startConnectionCount < 2 && ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    #expect(route.startConnectionCount == 2)
    #expect(route.prepareCount == 2)
    // An in-flight attempt must survive the previous two-second retry interval.
    try await Task.sleep(for: .milliseconds(2300))
    #expect(route.prepareCount == 2)
    #expect(route.startConnectionCount == 2)
    await manager.stopConnection()
}

private actor RecoveryDuringRetry {
    private weak var manager: RouteManager?
    private weak var local: FakeRoute?
    private weak var internet: FakeRoute?

    func attach(_ manager: RouteManager, local: FakeRoute, internet: FakeRoute) {
        self.manager = manager
        self.local = local
        self.internet = internet
    }

    func recoverOtherRoute(whilePreparing kind: RouteKind) async {
        guard let manager, let other = kind == .multipeer ? internet : local else { return }
        other.yield(.stateChanged(other.kind, .connected))
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while await manager.retries[other.kind] != nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(await manager.retries[other.kind] == nil)
    }
}

@Test func retryDoesNotRestartTheOtherRouteAfterItRecovers() async throws {
    let recovery = RecoveryDuringRetry()
    let local = FakeRoute(kind: .multipeer, onRetryPrepare: recovery.recoverOtherRoute)
    let internet = FakeRoute(kind: .webRTC, onRetryPrepare: recovery.recoverOtherRoute)
    let kinds: Set<RouteKind> = [.multipeer, .webRTC]
    let configuration = CallRouteConfiguration(
        enabledRoutes: kinds, preferredRoute: .multipeer, selectionMode: .automaticFallback, fallbackDelay: 0
    )
    let manager = RouteManager(routes: [local, internet], configuration: configuration)
    await recovery.attach(manager, local: local, internet: internet)
    await manager.prepare(makeRequest(configuration: configuration))
    await manager.startConnection()
    let fallbackDeadline = ContinuousClock.now.advanced(by: .seconds(1))
    while await manager.started != kinds, ContinuousClock.now < fallbackDeadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(await manager.started == kinds)
    local.yield(.stateChanged(.multipeer, .failed))
    internet.yield(.stateChanged(.webRTC, .failed))
    let pendingDeadline = ContinuousClock.now.advanced(by: .seconds(1))
    while await manager.retries.count < 2, ContinuousClock.now < pendingDeadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    let retries = await manager.retries
    try #require(Set(retries.keys) == kinds)
    let retryDeadline = try #require(retries.values.map(\.deadline).max())
    await manager.retryDueRoutes(at: retryDeadline)

    #expect(local.prepareCount + internet.prepareCount == 3)
    #expect(local.startConnectionCount + internet.startConnectionCount == 3)
    let states = await manager.routeStates.values
    #expect(states.filter { $0 == .connected }.count == 1)
    await manager.stopConnection()
}

@Test func routeManagerReceivesAfterReconnectAndRejectsStoppedEvents() async throws {
    let route = FakeRoute(kind: .multipeer)
    let configuration = CallRouteConfiguration(
        enabledRoutes: [.multipeer], preferredRoute: .multipeer, selectionMode: .singleRoute)
    let manager = RouteManager(routes: [route], configuration: configuration)
    let recorded = ReceivedPackets()
    let events = manager.events
    let listener = Task { for await event in events { await recorded.record(event) } }
    defer { listener.cancel() }
    for sequence in 1...2 {
        var request = makeRequest(configuration: configuration)
        request.sessionID = "session-\(sequence)"
        await manager.prepare(request)
        await manager.startConnection()
        await manager.startMedia()
        var remoteRequest = request
        remoteRequest.localPeer = .init(id: .init(rawValue: "remote"), displayName: "Remote")
        var relay = GroupRelay(request: remoteRequest)
        route.yield(
            .membersChanged(
                .multipeer, [.init(peer: remoteRequest.localPeer, route: .multipeer, isConnected: true)]))
        for body in [RelayBody.presence, .audio(makePacket(sequenceNumber: UInt64(sequence)))] {
            let payload = try relay.make(body, now: 0)
            route.yield(
                .receivedApplicationData(
                    .multipeer,
                    .init(
                        peerID: remoteRequest.localPeer.id,
                        message: .init(namespace: GroupRelay.namespace, payload: payload))))
        }
        for _ in 0..<100 {
            if await recorded.sequences.count == sequence { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await recorded.sequences.count == sequence)
        await manager.stopConnection()
        route.yield(
            .receivedApplicationData(
                .multipeer,
                ReceivedApplicationData(
                    peerID: PeerID(rawValue: "remote"),
                    message: ApplicationDataMessage(namespace: "late", payload: Data([1])))))
        try await Task.sleep(for: .milliseconds(20))
        #expect(await recorded.sequences.count == sequence)
    }
    #expect(await recorded.sequences == [0, 0])
}

@Test func idleConnectionHasNoAudioPollingTimer() async throws {
    let route = FakeRoute(kind: .multipeer)
    let configuration = CallRouteConfiguration(enabledRoutes: [.multipeer], preferredRoute: .multipeer)
    let manager = RouteManager(routes: [route], configuration: configuration,
        runtimeStatusPolicy: .init(isAutomaticBroadcastEnabled: false))
    await manager.prepare(
        .init(
            sessionID: "idle", localPeer: .init(id: .init(rawValue: "me"), displayName: "me"),
            configuration: configuration))
    await manager.startConnection()
    let deadline = try #require(await manager.maintenanceDeadline)
    #expect(
        deadline - ProcessInfo.processInfo.systemUptime > 1.8,
        "Idle maintenance must sleep for presence, not poll at 50 Hz")
    try await Task.sleep(for: .milliseconds(100))
    #expect(await manager.maintenanceDeadline == deadline)
    await manager.stopConnection()
    #expect(await manager.maintenanceDeadline == nil)
}

@Test func controlConnectivityAloneCannotSuppressInternetAudio() async {
    let local = FakeRoute(kind: .multipeer), internet = FakeRoute(kind: .webRTC)
    let configuration = CallRouteConfiguration(enabledRoutes: [.multipeer, .webRTC],
        preferredRoute: .multipeer, selectionMode: .automaticFallback, fallbackDelay: 0)
    let manager = RouteManager(routes: [local, internet], configuration: configuration)
    await manager.prepare(makeRequest(configuration: configuration))
    await manager.startConnection()
    try? await Task.sleep(for: .milliseconds(20))
    let peer = PeerDescriptor(id: PeerID(rawValue: "neighbor"), displayName: "Neighbor")
    for route in [local, internet] {
        route.yield(.membersChanged(route.kind, [.init(peer: peer, route: route.kind, isConnected: true)]))
        route.yield(.stateChanged(route.kind, .mediaReady))
    }
    try? await Task.sleep(for: .milliseconds(20))
    await manager.startMedia()
    await manager.sendAudioPacket(makePacket(sequenceNumber: 0))
    for route in [local, internet] {
        #expect(relayBodies(route.sentApplicationData).contains { if case .audio = $0 { true } else { false } },
            "A connected Local link may be slower or lose media; the faster Internet copy must remain available")
    }
    await manager.stopConnection()
}

@Test func nearbyAudioAvoidsInternetCopiesAndFallsBackWithoutWaiting() async throws {
    let local = FakeRoute(kind: .multipeer), internet = FakeRoute(kind: .webRTC)
    let config = CallRouteConfiguration(enabledRoutes: [.multipeer, .webRTC],
        preferredRoute: .multipeer, fallbackDelay: 0)
    let manager = RouteManager(
        routes: [local, internet], runtimeStatusPolicy: .init(isAutomaticBroadcastEnabled: false))
    await manager.prepare(makeRequest(configuration: config))
    await manager.startConnection()
    try await Task.sleep(for: .milliseconds(20))
    let nearby = (1...7).map { PeerDescriptor(id: .init(rawValue: "near-\($0)"), displayName: "Neighbor") }
    let members = nearby.map { CallMemberState(peer: $0, route: .multipeer, isConnected: true) }
    for route in [local, internet] {
        route.yield(.membersChanged(route.kind, members))
        route.yield(.stateChanged(route.kind, .mediaReady))
    }
    try await Task.sleep(for: .milliseconds(20))
    await manager.startMedia()
    local.immediateRecipients = Set(nearby.map(\.id))
    func audioCount(_ route: FakeRoute) -> Int { route.sentApplicationData.filter { $0.delivery == .unreliable }.count }
    // Eight participants have Internet, but all seven destinations accept UDP locally.
    await manager.sendAudioPacket(makePacket(sequenceNumber: 0))
    #expect(audioCount(local) == 1)
    #expect(audioCount(internet) == 0, "Healthy nearby speech must not pay for an Internet copy")
    // One missing UDP endpoint must not make the other six wait or queue old speech.
    local.immediateRecipients.remove(nearby[0].id)
    await manager.sendAudioPacket(makePacket(sequenceNumber: 1))
    #expect(audioCount(local) == 2)
    #expect(audioCount(internet) == 1)
    local.immediateRecipients.insert(nearby[0].id)
    await manager.sendAudioPacket(makePacket(sequenceNumber: 2))
    #expect(audioCount(internet) == 1, "Resume Local preference on the very next packet")
    // A distant participant still needs the SFU; never disconnect them for a nearby peer.
    let distant = CallMemberState(
        peer: .init(id: .init(rawValue: "far"), displayName: "Distant"), route: .webRTC, isConnected: true)
    internet.yield(.membersChanged(.webRTC, Array(members.dropLast()) + [distant]))
    try await Task.sleep(for: .milliseconds(20))
    await manager.sendAudioPacket(makePacket(sequenceNumber: 3))
    #expect(audioCount(internet) == 2)
    #expect(local.sentApplicationData.contains { $0.delivery == .reliable })
    #expect(internet.sentApplicationData.contains { $0.delivery == .reliable })
    await manager.stopConnection()
}
