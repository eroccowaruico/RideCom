import Foundation
import Synchronization
import Testing
@testable import RTC

@Test func webRTCRouteWithoutConfigurationReportsUnavailableWithoutGlobalError() async {
    let route = WebRTCInternetRoute(engine: FakeWebRTCEngine())
    var iterator = route.events.makeAsyncIterator()

    await route.prepare(makeRequest())
    await route.startConnection()

    var observedAvailability: RouteAvailability?
    var observedError: CallSessionError?
    for _ in 0..<5 {
        guard let event = await iterator.next() else { break }
        switch event {
        case .availabilityChanged(let availability) where availability.isAvailable == false:
            observedAvailability = availability
        case .error(_, let error):
            observedError = error
        default:
            break
        }
        if observedAvailability != nil {
            break
        }
    }

    #expect(observedAvailability?.route == .webRTC)
    #expect(observedAvailability?.reason == "WebRTC route configuration is unavailable")
    #expect(observedError == nil)
}

@Test func webRTCRouteUsesOneSFUConnectionForAllMembers() async throws {
    let signaling = FakeWebRTCSignalingClient(), engine = FakeWebRTCEngine()
    let route = WebRTCInternetRoute(
        cloudflareConfiguration: try makeCloudflareConfiguration(), signalingClient: signaling, engine: engine)
    await route.prepare(makeRequest()); await route.startConnection()
    try? await Task.sleep(for: .milliseconds(30))
    signaling.yield(
        .members([
            PeerDescriptor(id: PeerID(rawValue: "a"), displayName: "A"),
            PeerDescriptor(id: PeerID(rawValue: "b"), displayName: "B")
        ]))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(engine.createdPeerIDs == [PeerID(rawValue: "cloudflare-sfu")])
    #expect(signaling.sentOffers.count == 1)
    await route.stopConnection()
}

@Test func webRTCStopCanRunWithoutWaitingForIcePreparation() async throws {
    let (started, didStart) = AsyncStream<Void>.makeStream()
    let (held, release) = AsyncStream<Void>.makeStream()
    let (stopRequested, requestStop) = AsyncStream<Void>.makeStream()
    let cancelled = Mutex(false)
    let signaling = FakeWebRTCSignalingClient(onConnect: {
        await withTaskCancellationHandler {
            didStart.yield()
            for await _ in held { break }
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    })
    let engine = FakeWebRTCEngine()
    let route = WebRTCInternetRoute(
        cloudflareConfiguration: try makeCloudflareConfiguration(), signalingClient: signaling, engine: engine)
    let stopped = Mutex(false)
    await route.prepare(makeRequest())
    let commands = Task {
        await route.startConnection()
        for await _ in stopRequested { break }
        await route.stopConnection()
        stopped.withLock { $0 = true }
    }
    defer { release.finish(); requestStop.finish(); commands.cancel() }
    for await _ in started { break }
    requestStop.yield()
    let deadline = ContinuousClock.now.advanced(by: .seconds(1))
    while !stopped.withLock({ $0 }), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(stopped.withLock { $0 })
    #expect(cancelled.withLock { $0 })
    release.finish()
    await commands.value
    #expect(engine.createdPeerIDs.isEmpty)
    #expect(engine.closeCount == 1)
    #expect(signaling.disconnectCount == 1)
}

@Test(arguments: [ConnectionBlockReason.deviceCredentialRejected, .manualRecovery("End the existing call")])
func webRTCBlockReasonStopsMediaAndReachesTheRoute(reason: ConnectionBlockReason) async throws {
    let signaling = FakeWebRTCSignalingClient(), engine = FakeWebRTCEngine()
    let route = WebRTCInternetRoute(
        cloudflareConfiguration: try makeCloudflareConfiguration(), signalingClient: signaling, engine: engine)
    let recorder = RouteEventRecorder(), events = route.events
    let listener = Task { for await event in events { recorder.append(event) } }
    defer { listener.cancel() }
    await route.prepare(makeRequest()); await route.startConnection()
    signaling.yield(.blocked(reason))
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !recorder.values.contains(.stateChanged(.webRTC, .failed)), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(recorder.values.contains(.connectionBlocked(.webRTC, reason)))
    #expect(recorder.values.contains(.stateChanged(.webRTC, .failed)))
    #expect(engine.closeCount > 0)
    #expect(signaling.disconnectCount > 0)
    await route.stopConnection()
}

@Test func webRTCRouteStopsAfterFailureAndRejectsLateSignaling() async throws {
    let signaling = FakeWebRTCSignalingClient(), engine = FakeWebRTCEngine()
    let route = WebRTCInternetRoute(
        cloudflareConfiguration: try makeCloudflareConfiguration(), signalingClient: signaling, engine: engine)
    await route.prepare(makeRequest()); await route.startConnection()
    try? await Task.sleep(for: .milliseconds(30))
    signaling.yield(.failed("Monthly budget reached"))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(engine.closeCount > 0)
    let count = engine.acceptedAnswers.count
    signaling.yield(.answer(.init(kind: .answer, sdp: "late"), from: .init(rawValue: "cloudflare-sfu")))
    try? await Task.sleep(for: .milliseconds(30))
    #expect(engine.acceptedAnswers.count == count)
}

@Test(arguments: [false, true])
func replacingRejectedCredentialRestartsOnlyInternetInTheSameSession(localAvailable: Bool) async throws {
    let initial = try makeCloudflareConfiguration()
    let next = CloudflareRealtimeConfiguration(workerURL: initial.workerURL, accessToken: "fixture-replacement")
    let source = Mutex(initial)
    let signaling = FakeWebRTCSignalingClient()
    let route = WebRTCInternetRoute(cloudflareConfigurationProvider: { _ in source.withLock { $0 } },
                                    signalingClient: signaling, engine: FakeWebRTCEngine())
    let local = FakeRoute(kind: .multipeer)
    let configuration = CallRouteConfiguration(enabledRoutes: localAvailable ? [.webRTC, .multipeer] : [.webRTC],
        preferredRoute: .webRTC, selectionMode: localAvailable ? .automaticFallbackAndRestore : .singleRoute,
        fallbackDelay: 0)
    let manager = RouteManager(routes: [route, local], configuration: configuration)
    let session: any CallSession = manager
    await session.prepare(makeRequest(configuration: configuration))
    let generation = await manager.generation
    await session.startConnection()
    await session.startMedia()
    if localAvailable { local.yield(.stateChanged(.multipeer, .mediaReady)) }
    for _ in 0..<100 where signaling.configurations.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    try #require(signaling.configurations == [initial])
    signaling.yield(.blocked(.deviceCredentialRejected))
    for _ in 0..<100 where await manager.blocked[.webRTC] == nil { try await Task.sleep(for: .milliseconds(10)) }
    try #require(await manager.blocked[.webRTC] == .deviceCredentialRejected)
    await session.retryInternetRouteAfterCredentialChange()
    #expect(signaling.configurations == [initial])
    #expect(await manager.blocked[.webRTC] == .deviceCredentialRejected)
    let other = try #require(URL(string: "https://other.test"))
    source.withLock { $0 = .init(workerURL: other, accessToken: next.accessToken) }
    await session.retryInternetRouteAfterCredentialChange()
    #expect(signaling.configurations == [initial])
    #expect(await manager.blocked[.webRTC] == .deviceCredentialRejected)
    source.withLock { $0 = next }
    await session.retryInternetRouteAfterCredentialChange()
    await session.retryInternetRouteAfterCredentialChange()
    for _ in 0..<100 where signaling.configurations.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(signaling.configurations == [initial, next])
    #expect(await manager.blocked[.webRTC] == nil)
    #expect(await manager.generation == generation)
    #expect(await manager.isMediaStarted)
    if localAvailable {
        #expect(await manager.availableRoutes.contains(.multipeer))
        #expect(local.prepareCount == 1 && local.startConnectionCount == 1)
    }
    await session.stopConnection()
    await session.retryInternetRouteAfterCredentialChange()
    #expect(signaling.configurations == [initial, next])
}

@Test func onlyAuthenticatedDirectInternetPresenceIsReportedToTheSignalingClient() async throws {
    let signaling = FakeWebRTCSignalingClient()
    let route = WebRTCInternetRoute(cloudflareConfiguration: try makeCloudflareConfiguration(),
                                    signalingClient: signaling, engine: FakeWebRTCEngine())
    let configuration = CallRouteConfiguration(enabledRoutes: [.webRTC], preferredRoute: .webRTC,
                                               selectionMode: .singleRoute)
    let manager = RouteManager(routes: [route], configuration: configuration)
    let request = makeRequest(configuration: configuration)
    await manager.prepare(request)
    await manager.startConnection()
    for _ in 0..<100 where signaling.configurations.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    try #require(!signaling.configurations.isEmpty)
    var remote = request
    let peer = PeerDescriptor(id: .init(rawValue: "remote"), displayName: "Remote")
    let forwarder = PeerDescriptor(id: .init(rawValue: "forwarder"), displayName: "Forwarder")
    remote.localPeer = peer
    signaling.yield(.members([peer, forwarder]))
    let peerIDs = Set([peer.id, forwarder.id])
    for _ in 0..<100 where await manager.routeMembers[.webRTC] != peerIDs {
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(await manager.routeMembers[.webRTC] == peerIDs)
    #expect(signaling.authenticatedInternetPeers.isEmpty)

    var wrongGroup = remote
    wrongGroup.credential = .derived(groupID: "other-group", secret: "different-key")
    var forwardingRequest = request
    forwardingRequest.localPeer = forwarder
    var forwarding = GroupRelay(request: forwardingRequest)
    var rejected = GroupRelay(request: wrongGroup), accepted = GroupRelay(request: remote)
    let reception = forwarding.receive(try accepted.make(.presence, now: 0), from: peer.id, now: 0)
    let forwarded = try #require(reception?.forward)
    for (sender, presence) in [(peer.id, try rejected.make(.presence, now: 0)), (forwarder.id, forwarded),
                               (peer.id, try accepted.make(.presence, now: 0))] {
        signaling.yield(.receivedApplicationData(.init(
            peerID: sender, message: .init(namespace: GroupRelay.namespace, payload: presence))))
    }
    for _ in 0..<100 where signaling.authenticatedInternetPeers.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(signaling.authenticatedInternetPeers == [peer.id])
    await manager.stopConnection()
}

@Test func webRTCConnectionReadinessRequiresICEAndRejectsEventsAfterStop() async throws {
    let signaling = FakeWebRTCSignalingClient(), engine = FakeWebRTCEngine()
    let route = WebRTCInternetRoute(
        cloudflareConfiguration: try makeCloudflareConfiguration(), signalingClient: signaling, engine: engine)
    let recorder = RouteEventRecorder()
    let events = route.events
    let task = Task { for await event in events { recorder.append(event) } }
    await route.prepare(makeRequest()); await route.startConnection()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(!recorder.values.contains(.stateChanged(.webRTC, .connected)))
    engine.yield(.connectionStateChanged(.connected))
    try? await Task.sleep(for: .milliseconds(50))
    #expect(recorder.values.contains(.stateChanged(.webRTC, .connected)))
    await route.stopConnection()
    let count = recorder.values.count
    signaling.yield(
        .receivedApplicationData(
            .init(peerID: .init(rawValue: "outsider"), message: .init(namespace: "test", payload: Data()))))
    try? await Task.sleep(for: .milliseconds(50))
    #expect(
        !recorder.values.dropFirst(count).contains {
            if case .receivedApplicationData = $0 { return true }; return false
        })
    task.cancel()
}

@Test func webRTCReceivesTheContinuationDeadlineOfTheEarlierNearbyCall() async throws {
    let signaling = FakeWebRTCSignalingClient()
    let internet = WebRTCInternetRoute(cloudflareConfiguration: try makeCloudflareConfiguration(),
                                       signalingClient: signaling, engine: FakeWebRTCEngine())
    let nearby = FakeRoute(kind: .multipeer)
    let configuration = CallRouteConfiguration(enabledRoutes: [.multipeer, .webRTC], preferredRoute: .multipeer,
                                               selectionMode: .automaticFallbackAndRestore, fallbackDelay: 0)
    let manager = RouteManager(routes: [nearby, internet], configuration: configuration)
    let call = makeRequest(configuration: configuration)
    await manager.prepare(call)
    await manager.startConnection()
    var remoteCall = call
    let peer = PeerDescriptor(id: .init(rawValue: "rider"), displayName: "Rider")
    remoteCall.localPeer = peer
    var remote = GroupRelay(request: remoteCall)
    let earliestDeadline = ContinuousClock.now.advanced(by: .seconds(86400))
    nearby.yield(.membersChanged(.multipeer, [.init(peer: peer, route: .multipeer, isConnected: true)]))
    let nearbyPresence = try remote.make(.presence, now: 0)
    nearby.yield(.receivedApplicationData(.multipeer, .init(
        peerID: peer.id, message: .init(namespace: GroupRelay.namespace, payload: nearbyPresence))))
    for _ in 0..<100 where await manager.relay?.continuationDeadline == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    let deadline = try #require(await manager.relay?.continuationDeadline)
    #expect(deadline >= earliestDeadline)
    #expect(deadline <= ContinuousClock.now.advanced(by: .seconds(86400)))
    for _ in 0..<100 where signaling.configurations.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    try #require(!signaling.configurations.isEmpty)
    signaling.yield(.members([peer]))
    let internetPresence = try remote.make(.presence, now: 1)
    signaling.yield(.receivedApplicationData(.init(
        peerID: peer.id, message: .init(namespace: GroupRelay.namespace, payload: internetPresence))))
    for _ in 0..<100 where signaling.continuationDeadline == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(signaling.authenticatedInternetPeers == [peer.id])
    #expect(signaling.continuationDeadline == deadline)
    let replacement = try #require(await manager.stopConnection(preservingContinuationIn: call))
    await manager.prepare(replacement)
    #expect(await manager.relay?.continuationDeadline == deadline)
    var unrelated = call
    unrelated.sessionID = "another-call"
    let unrelatedReplacement = try #require(await manager.stopConnection(preservingContinuationIn: unrelated))
    #expect(unrelatedReplacement.continuationDeadline == nil)
    await manager.prepare(call)
    #expect(await manager.relay?.continuationDeadline == nil)
    await manager.stopConnection()
}

@Test func webRTCNegotiationFailureClosesSignalingAndAllowsRetry() async throws {
    let signaling = FakeWebRTCSignalingClient(), engine = FakeWebRTCEngine()
    engine.rejectAnswer = true
    let route = WebRTCInternetRoute(
        cloudflareConfiguration: try makeCloudflareConfiguration(), signalingClient: signaling, engine: engine)
    await route.prepare(makeRequest()); await route.startConnection()
    signaling.yield(.answer(.init(kind: .answer, sdp: "invalid"), from: .init(rawValue: "cloudflare-sfu")))
    try? await Task.sleep(for: .milliseconds(80))
    #expect(signaling.disconnectCount > 0)
    #expect(engine.closeCount > 0)
    engine.rejectAnswer = false
    await route.startConnection()
    try? await Task.sleep(for: .milliseconds(50))
    #expect(engine.prepareCount >= 2)
    await route.stopConnection()
}

private final class FakeWebRTCEngine: NativeWebRTCEngine, @unchecked Sendable {
    override var isAvailable: Bool { true }
    override var events: AsyncStream<WebRTCEngineEvent> { eventSource.stream }

    private let eventSource = EventSource<WebRTCEngineEvent>()
    private(set) var createdPeerIDs: [PeerID] = []
    private(set) var closeCount = 0
    var rejectAnswer = false
    private(set) var prepareCount = 0
    override func prepareTransport() async { prepareCount += 1 }
    override func close() async { closeCount += 1 }
    private(set) var acceptedAnswers: [(WebRTCSessionDescription, PeerID)] = []

    override func createPeerConnection(for peer: PeerDescriptor) async {
        createdPeerIDs.append(peer.id)
    }

    override func makeOffer(for peerID: PeerID) async -> WebRTCSessionDescription? {
        WebRTCSessionDescription(kind: .offer, sdp: "offer-\(peerID.rawValue)")
    }

    override func acceptAnswer(_ answer: WebRTCSessionDescription, from peerID: PeerID) async -> Bool {
        acceptedAnswers.append((answer, peerID))
        return !rejectAnswer
    }

    func yield(_ event: WebRTCEngineEvent) {
        eventSource.yield(event)
    }
}

private final class FakeWebRTCSignalingClient:
    WebRTCSignalingClient, AuthenticatedInternetPeerObserving, @unchecked Sendable {
    var events: AsyncStream<WebRTCSignalingEvent> { eventSource.stream }

    private let eventSource = EventSource<WebRTCSignalingEvent>()
    private let onConnect: (@Sendable () async -> Void)?
    private let observedConfigurations = Mutex<[CloudflareRealtimeConfiguration]>([])
    var configurations: [CloudflareRealtimeConfiguration] { observedConfigurations.withLock { $0 } }
    private let authenticatedPeers = Mutex<[(id: PeerID, deadline: ContinuousClock.Instant)]>([])
    var authenticatedInternetPeers: [PeerID] { authenticatedPeers.withLock { $0.map(\.id) } }
    var continuationDeadline: ContinuousClock.Instant? { authenticatedPeers.withLock { $0.first?.deadline } }
    func observeAuthenticatedInternetPeer(
        _ peer: PeerID, callID: String, continuationDeadline: ContinuousClock.Instant
    ) {
        authenticatedPeers.withLock { $0.append((peer, continuationDeadline)) }
    }
    private(set) var disconnectCount = 0
    private(set) var sentOffers: [(WebRTCSessionDescription, PeerID)] = []
    private(set) var sentApplicationData: [(ApplicationDataMessage, PeerID?)] = []

    init(onConnect: (@Sendable () async -> Void)? = nil) {
        self.onConnect = onConnect
    }

    func yield(_ event: WebRTCSignalingEvent) {
        eventSource.yield(event)
    }

    func connect(_ request: WebRTCSignalingConnectRequest) async {
        observedConfigurations.withLock { $0.append(request.cloudflare) }
        await onConnect?()
        guard !Task.isCancelled else { return }
        eventSource.yield(.connected)
    }

    func startPublishing() async {}
    func disconnect() async {
        disconnectCount += 1
        eventSource.yield(.disconnected)
    }

    func sendOffer(_ offer: WebRTCSessionDescription, to peerID: PeerID) async {
        sentOffers.append((offer, peerID))
    }

    func sendApplicationData(_ message: ApplicationDataMessage, to peerID: PeerID?) async {
        sentApplicationData.append((message, peerID))
    }
}

private func makeCloudflareConfiguration() throws -> CloudflareRealtimeConfiguration {
    CloudflareRealtimeConfiguration(
        workerURL: try #require(URL(string: "https://realtime.cloudflare.test")),
        accessToken: "test-token"
    )
}
