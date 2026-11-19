#if !os(watchOS)
import Foundation
import Synchronization
import Testing
@testable import RTC

private final class LocalEnd: Sendable {
    let route = LocalCallRoute()
    let id: PeerID
    private final class Record: Sendable { let log = Mutex<[RouteEvent]>([]) }
    private let record = Record()
    private let listener: Task<Void, Never>

    init(_ name: String) {
        id = .init(rawValue: name)
        let stream = route.events, record = record
        listener = Task {
            for await event in stream { record.log.withLock { $0.append(event) } }
        }
    }
    deinit { listener.cancel() }

    func start(_ credential: RTCCredential?) async {
        await route.prepare(.init(sessionID: "local", localPeer: .init(id: id, displayName: "Rider"), credential: credential))
        await route.startConnection()
    }
    var events: [RouteEvent] { record.log.withLock { $0 } }
    func received(_ message: ApplicationDataMessage, from peer: LocalEnd) -> Int {
        events.filter { $0 == .receivedApplicationData(.multipeer, .init(peerID: peer.id, message: message)) }.count
    }
    func knows(_ peer: LocalEnd) -> Bool {
        events.reversed().compactMap { event -> [CallMemberState]? in
            if case .membersChanged(_, let members) = event { return members }
            return nil
        }.first?.contains { $0.peer.id == peer.id } == true
    }
}

private func waitForLocal(_ predicate: () async -> Bool) async throws {
    let deadline = ContinuousClock.now.advanced(by: .seconds(12))
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    try #require(await predicate())
}

extension RealtimeTransportTests {
    @Test func localTransportCapabilitiesDoNotFreezeTheInitialCodecPreference() {
        let routes = CallSessionFactory.makeRoutes(.init(
            routeConfiguration: .init(enabledRoutes: [.multipeer]), audioPolicy: .init(preferredCodecs: [.pcm16])))
        #expect(routes.first is LocalCallRoute)
        #expect(Set(routes.first?.capabilities.supportedAudioCodecs ?? []) == [.pcm16, .opus, .mpeg4AACELD, .mpeg4AACELDv2])
    }

    @Test func invalidLocalConfigurationFailsBeforeDiscovery() async throws {
        for (name, credential) in [("", Optional(groupCredential())), (String(repeating: "a", count: 81), groupCredential()), ("local", nil)] {
            let end = LocalEnd(name)
            await end.start(credential)
            try await waitForLocal { end.events.contains(.stateChanged(.multipeer, .failed)) }
            #expect(end.events.contains { if case .error(_, .connectionFailed) = $0 { return true }; return false })
            await end.route.stopConnection()
        }
    }

    @Test func udpListenerFailureRetiresTheSessionBeforeQueuedControlState() async throws {
        let end = LocalEnd("listener-failure")
        await end.start(groupCredential())
        let (media, controlEvent) = try await localFailureCallbacks(end.route)
        try await waitForLocal { media.port != nil }

        try media.synchronized {
            let listenerFailed = try #require(media.onFailure)
            listenerFailed("UDP listener failed")
        }
        // This callback was already dispatched on the independent QUIC queue.
        controlEvent(.state(.authenticated))
        #expect(media.port == nil)
        await end.route.stopConnection()
        try await waitForLocal { end.events.last == .stateChanged(.multipeer, .disconnected) }
        let events = end.events
        let failed = try #require(events.firstIndex(of: .stateChanged(.multipeer, .failed)))
        #expect(!events[failed...].contains(.stateChanged(.multipeer, .authenticated)))
    }

    private func localFailureCallbacks(_ route: isolated LocalCallRoute) throws
        -> (LocalDatagramTransport, @Sendable (LocalControlEvent) -> Void) {
        let session = try #require(Mirror(reflecting: route).descendant("session", 0))
        let fields = Mirror(reflecting: session)
        let mediaStorage = try #require(fields.children.first { $0.label?.hasSuffix("datagrams") == true })
        let media = try #require(Mirror(reflecting: mediaStorage.value).descendant(0) as? LocalDatagramTransport)
        let control = try #require(fields.descendant("control", 0) as? LocalControlTransport)
        let event = try #require(Mirror(reflecting: control).descendant("onEvent") as? (@Sendable (LocalControlEvent) -> Void))
        return (media, event)
    }

    @Test func simultaneousDiscoveryOfLongIdentifiersDeliversControlExactlyOnce() async throws {
        let a = LocalEnd(String(repeating: "あ", count: 23)), b = LocalEnd(String(repeating: "b", count: 70))
        let group = groupCredential()
        async let startA: Void = a.start(group)
        async let startB: Void = b.start(group)
        _ = await (startA, startB)
        try await waitForLocal { a.knows(b) && b.knows(a) }
        for delivery in [ApplicationDataDelivery.reliable, .unreliable] {
            let message = ApplicationDataMessage(namespace: "control", payload: Data([1]), delivery: delivery)
            _ = await a.route.sendApplicationData(message)
            _ = await b.route.sendApplicationData(message)
            try await waitForLocal { a.received(message, from: b) > 0 && b.received(message, from: a) > 0 }
            #expect(a.received(message, from: b) == 1 && b.received(message, from: a) == 1)
        }
        await a.route.stopConnection()
        await b.route.stopConnection()
    }

    @Test func wrongKeyReportsRejectedHandshakeAndCannotSendControlOrAudio() async throws {
        let group = groupCredential(), a = LocalEnd("a"), b = LocalEnd("b")
        await a.start(group)
        await b.start(.init(groupHash: group.groupHash, sharedSecret: Data(repeating: 7, count: 32)))
        try await waitForLocal { (a.events + b.events).contains(.error(.multipeer, .handshakeRejected(.multipeer))) }
        for delivery in [ApplicationDataDelivery.reliable, .unreliable] {
            let message = ApplicationDataMessage(namespace: GroupRelay.namespace, payload: Data([2]), delivery: delivery)
            #expect(await b.route.sendApplicationData(message).isEmpty)
            #expect(a.received(message, from: b) == 0)
        }
        #expect(!a.knows(b) && !b.knows(a))
        await a.route.stopConnection()
        await b.route.stopConnection()
    }

    @Test func localAudioSendDoesNotWaitForMainActor() async {
        let route = LocalCallRoute()
        await MainActor.run {
            let completed = DispatchSemaphore(value: 0)
            Task.detached {
                let message = ApplicationDataMessage(namespace: GroupRelay.namespace, payload: Data([1]), delivery: .unreliable)
                _ = await route.sendApplicationData(message)
                completed.signal()
            }
            #expect(completed.wait(timeout: .now() + .milliseconds(100)) == .success)
        }
    }

    @Test func authenticatedAudioArrivesOverUDPWhileMainActorIsOccupied() async throws {
        let group = groupCredential(), a = LocalEnd(String(repeating: "a", count: 80)), b = LocalEnd("b")
        await a.start(group)
        await b.start(group)
        try await waitForLocal { a.knows(b) && b.knows(a) }
        let audio = ApplicationDataMessage(namespace: GroupRelay.namespace, payload: Data([11]), delivery: .unreliable)
        try await waitForLocal { await a.route.sendApplicationData(audio).contains(b.id) }
        try await waitForLocal { b.received(audio, from: a) > 0 }
        let fresh = ApplicationDataMessage(namespace: GroupRelay.namespace, payload: Data([12]), delivery: .unreliable)
        await MainActor.run {
            let completed = DispatchSemaphore(value: 0)
            Task.detached {
                _ = await a.route.sendApplicationData(fresh)
                try? await waitForLocal { b.received(fresh, from: a) == 1 }
                completed.signal()
            }
            #expect(completed.wait(timeout: .now() + .milliseconds(250)) == .success)
        }
        #expect((await b.route.networkDiagnostics().statistics.receivedMediaDatagrams ?? 0) > 0)
        await b.route.stopConnection()
        #expect(await b.route.sendApplicationData(audio).isEmpty)
        await a.route.stopConnection()
    }

    @Test func preparingAnotherGroupRejectsThePreviousGeneration() async throws {
        let group = groupCredential(), a = LocalEnd("a"), b = LocalEnd("b"), c = LocalEnd("c")
        await a.start(group)
        await b.start(group)
        try await waitForLocal { a.knows(b) && b.knows(a) }
        let next = groupCredential()
        await a.start(next)
        await c.start(next)
        try await waitForLocal { a.knows(c) && c.knows(a) }
        let message = ApplicationDataMessage(namespace: "operation", payload: Data([3]))
        _ = await b.route.sendApplicationData(message)
        _ = await c.route.sendApplicationData(message)
        try await waitForLocal { a.received(message, from: c) == 1 }
        #expect(!a.knows(b) && a.received(message, from: b) == 0)
        for end in [a, b, c] { await end.route.stopConnection() }
    }

    @Test func disconnectedPeerMustAuthenticateAgainAndOtherPeersKeepTalking() async throws {
        let group = groupCredential(), a = LocalEnd("a"), b = LocalEnd("b"), c = LocalEnd("c")
        for end in [a, b, c] { await end.start(group) }
        try await waitForLocal { a.knows(b) && a.knows(c) && b.knows(a) && c.knows(a) }
        await b.route.stopConnection()
        await b.start(.init(groupHash: group.groupHash, sharedSecret: Data(repeating: 55, count: 32)))
        try await waitForLocal { (a.events + b.events).contains(.error(.multipeer, .handshakeRejected(.multipeer))) }
        let message = ApplicationDataMessage(namespace: "control", payload: Data([4]))
        _ = await b.route.sendApplicationData(message)
        _ = await c.route.sendApplicationData(message)
        try await waitForLocal { a.received(message, from: c) == 1 }
        #expect(a.received(message, from: b) == 0)
        await b.start(group)
        try await waitForLocal { b.knows(a) && b.events.filter { $0 == .stateChanged(.multipeer, .authenticated) }.count > 1 }
        try await waitForLocal {
            _ = await b.route.sendApplicationData(message)
            return a.received(message, from: b) > 0
        }
        for end in [a, b, c] { await end.route.stopConnection() }
    }

    @Test func losingOnlyQUICPreservesTheAuthenticatedUDPEndpointUntilStop() async throws {
        let local = LocalEnd("local"), peer = PeerID(rawValue: "remote"), group = groupCredential()
        let media = LocalDatagramTransport(peerID: peer, credential: group) { _, _ in }
        try media.start()
        defer { media.stop() }
        let control = LocalControlTransport(localID: peer, credential: group, nonce: media.serviceNonce) { event in
            if case .authenticated(let id, let nonce) = event { media.connect(to: id, nonce: nonce) }
        }
        control.start()
        defer { control.stop() }
        await local.start(group)
        try await waitForLocal { media.isReady(for: local.id) }
        func sendAndObserve(_ value: UInt8) async throws {
            let payload = Data([value])
            let message = ApplicationDataMessage(namespace: GroupRelay.namespace, payload: payload, delivery: .unreliable)
            let expected = RouteEvent.receivedApplicationData(.multipeer, .init(peerID: peer, message: message))
            try await waitForLocal {
                _ = media.send(payload, to: [local.id])
                return local.events.contains(expected)
            }
        }
        let misplacedAudio = ApplicationDataMessage(namespace: GroupRelay.namespace, payload: Data([9]), delivery: .unreliable)
        let nextControl = ApplicationDataMessage(namespace: "operation", payload: Data([10]))
        control.send(try JSONEncoder().encode(misplacedAudio))
        control.send(try JSONEncoder().encode(nextControl))
        try await waitForLocal {
            local.events.contains(.receivedApplicationData(.multipeer, .init(peerID: peer, message: nextControl)))
        }
        #expect(!local.events.contains(.receivedApplicationData(.multipeer, .init(peerID: peer, message: misplacedAudio))))
        try await sendAndObserve(1)
        control.stop()
        // The same peer name returns with a different key. Even after the old
        // control link is closed, a refused handshake cannot replace its UDP nonce.
        let invalid = LocalControlTransport(localID: peer,
            credential: .init(groupHash: group.groupHash, sharedSecret: Data(repeating: 3, count: 32)),
            nonce: "untrusted") { _ in }
        invalid.start()
        defer { invalid.stop() }
        try await waitForLocal { local.events.contains(.error(.multipeer, .handshakeRejected(.multipeer))) }
        try await sendAndObserve(2)
        await local.route.stopConnection()
        #expect(await local.route.sendApplicationData(.init(namespace: GroupRelay.namespace,
            payload: Data([3]), delivery: .unreliable)).isEmpty)
    }

    private func groupCredential() -> RTCCredential {
        .derived(groupID: UUID().uuidString, secret: "local-route-fixture")
    }
}
#endif
