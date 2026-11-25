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

private final class RouteEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [RouteEvent] = []
    var values: [RouteEvent] { lock.withLock { stored } }
    func append(_ event: RouteEvent) { lock.withLock { stored.append(event) } }
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

private final class FakeWebRTCSignalingClient: WebRTCSignalingClient, @unchecked Sendable {
    var events: AsyncStream<WebRTCSignalingEvent> { eventSource.stream }

    private let eventSource = EventSource<WebRTCSignalingEvent>()
    private let onConnect: (@Sendable () async -> Void)?
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
