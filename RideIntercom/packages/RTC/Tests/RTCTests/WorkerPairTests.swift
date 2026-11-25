import Foundation
import Synchronization
import Testing
@testable import RTC

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["RIDEINTERCOM_PAIR_URL"] != nil))
struct WorkerPairTests {
    @Test(.timeLimit(.minutes(1))) func signaling401BlocksRecoveryAndReleasesTheJoinedSession() async throws {
        let request = try rejectedSignalRequest()
        let endpoint = PairEndpoint()
        let listener = endpoint.listen()
        defer { listener.cancel() }
        await endpoint.join(request)
        try await eventually { !endpoint.blockedReasons.isEmpty }
        #expect(endpoint.answers == 1)
        #expect(endpoint.failures.isEmpty)
        #expect(endpoint.blockedReasons == [.deviceCredentialRejected])
        try await eventually(attempts: 40) {
            try await CloudflareRealtimeSignalingClient.checkService(request.cloudflare).activeSessions == 0
        }
        await endpoint.client.disconnect()
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func control401KeepsTheSessionWhenRenewalConfirmsContinuation(rejectsPull: Bool) async throws {
        var request = try rejectedSignalRequest()
        if rejectsPull {
            request.call.credential = .derived(groupID: UUID().uuidString, secret: "synthetic-continuation")
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScopedRenewalResponse.self]
        ScopedRenewalResponse.reset(rejectsPull: rejectsPull)
        let endpoint = PairEndpoint(session: URLSession(configuration: configuration))
        let listener = endpoint.listen()
        defer { listener.cancel() }
        await endpoint.join(request)
        try await eventually { ScopedRenewalResponse.responseCount >= 2 }
        if rejectsPull { try await eventually { ScopedRenewalResponse.pullCount >= 2 } }
        #expect(endpoint.answers == 1)
        #expect(endpoint.failures.isEmpty && endpoint.blockedReasons.isEmpty)
        #expect(try await CloudflareRealtimeSignalingClient.checkService(request.cloudflare).activeSessions == 1)
        await endpoint.client.disconnect()
        try await eventually(attempts: 40) {
            try await CloudflareRealtimeSignalingClient.checkService(request.cloudflare).activeSessions == 0
        }
    }

    @Test(.timeLimit(.minutes(1))) func scopedContinuationStopsAtItsDeadline() async throws {
        let request = try rejectedSignalRequest()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ScopedRenewalResponse.self]
        ScopedRenewalResponse.reset(rejectsPull: false, endsBeforeRenewalInterval: true)
        let endpoint = PairEndpoint(session: URLSession(configuration: configuration))
        let listener = endpoint.listen()
        defer { listener.cancel() }
        await endpoint.join(request)
        try await eventually { ScopedRenewalResponse.responseCount == 1 }
        let expiresAt = try #require(ScopedRenewalResponse.lastExpiry)
        #expect(endpoint.blockedReasons.isEmpty)
        #expect(try await CloudflareRealtimeSignalingClient.checkService(request.cloudflare).activeSessions == 1)
        try await eventually { endpoint.blockedReasons == [.deviceCredentialRejected] }
        #expect(Date().timeIntervalSince1970 + 0.05 >= expiresAt)
        #expect(ScopedRenewalResponse.responseCount == 1)
        try await eventually(attempts: 40) {
            try await CloudflareRealtimeSignalingClient.checkService(request.cloudflare).activeSessions == 0
        }
        await endpoint.client.disconnect()
    }

    @Test(.timeLimit(.minutes(1))) func workerExpiryKeepsExistingSubscriptionsWhenAnotherPeerJoins() async throws {
        let env = ProcessInfo.processInfo.environment
        let address = try #require(env["RIDEINTERCOM_PAIR_EXPIRY_URL"])
        let url = try #require(URL(string: address))
        let room = RTCCredential.derived(groupID: UUID().uuidString, secret: "synthetic-expiry-pair")
        func request(_ id: String) throws -> WebRTCSignalingConnectRequest {
            let token = try #require(env["RIDEINTERCOM_PAIR_" + id.uppercased()])
            return .init(call: .init(sessionID: "expiry", localPeer: .init(id: .init(rawValue: id), displayName: id),
                                     credential: room),
                         cloudflare: .init(workerURL: url, accessToken: token))
        }
        let expiringRequest = try request("expiring")
        let stayingRequest = try request("staying")
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PairExpiryRequests.self]
        let expiring = PairEndpoint(session: URLSession(configuration: configuration))
        let staying = PairEndpoint(), arriving = PairEndpoint()
        let listeners = [expiring, staying, arriving].map { $0.listen() }
        defer { listeners.forEach { $0.cancel() } }
        await expiring.join(expiringRequest)
        await staying.join(stayingRequest)
        try await eventually {
            !expiring.channelIDs(from: "staying").isEmpty && !staying.channelIDs(from: "expiring").isEmpty
        }
        let subscribedChannels = expiring.channelIDs(from: "staying")
        let nearbyDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        // The fixed Worker clock has one second of ordinary authorization left.
        // Its next scheduled renewal would be in five minutes.
        let establishedAt = try await confirmEstablishment(
            alice: staying, aliceCall: stayingRequest.call, bob: expiring, bobCall: expiringRequest.call,
            continuationDeadline: nearbyDeadline)
        try await expireTestCredential(expiringRequest.cloudflare)
        PairExpiryRequests.arm()
        await arriving.join(try request("arriving"))
        try await eventually {
            PairExpiryRequests.didContinueAfterPullRejection && !staying.channelIDs(from: "arriving").isEmpty
        }
        #expect(expiring.answers == 1 && expiring.failures.isEmpty && expiring.blockedReasons.isEmpty)
        #expect(expiring.channelIDs(from: "staying") == subscribedChannels)
        #expect(await expiring.client.establishedAt == establishedAt)
        #expect(expiring.channelIDs(from: "arriving").isEmpty)
        #expect(try await CloudflareRealtimeSignalingClient.checkService(stayingRequest.cloudflare).activeSessions == 3)
        try await eventually { expiring.blockedReasons == [.deviceCredentialRejected] }
        #expect(ContinuousClock.now >= nearbyDeadline)
        try await eventually {
            try await CloudflareRealtimeSignalingClient.checkService(stayingRequest.cloudflare).activeSessions == 2
        }
        for endpoint in [expiring, staying, arriving] { await endpoint.client.disconnect() }
        #expect(try await CloudflareRealtimeSignalingClient.checkService(stayingRequest.cloudflare).activeSessions == 0)
    }

    private func expireTestCredential(_ configuration: CloudflareRealtimeConfiguration) async throws {
        let signal = try #require(ProcessInfo.processInfo.environment["RIDEINTERCOM_PAIR_CLOCK_SIGNAL"])
        try Data().write(to: URL(fileURLWithPath: signal))
        try await eventually {
            do {
                _ = try await CloudflareRealtimeSignalingClient.checkService(configuration)
                return false
            } catch CloudflareRealtimeSignalingClient.Failure.deviceCredentialRejected {
                return true
            }
        }
    }

    private func rejectedSignalRequest() throws -> WebRTCSignalingConnectRequest {
        let env = ProcessInfo.processInfo.environment
        let address = try #require(env["RIDEINTERCOM_PAIR_URL"])
        let url = try #require(URL(string: address))
        let groupHash = try #require(env["RIDEINTERCOM_PAIR_REJECTED_SIGNAL_ROOM"])
        let configuration = CloudflareRealtimeConfiguration(
            workerURL: url, accessToken: try #require(env["RIDEINTERCOM_PAIR_TOKEN_A"]))
        return WebRTCSignalingConnectRequest(
            call: .init(sessionID: "signal-rejection",
                        localPeer: .init(id: .init(rawValue: "alice"), displayName: "Alice"),
                        credential: .init(groupHash: groupHash, sharedSecret: Data(repeating: 1, count: 32))),
            cloudflare: configuration)
    }

    @Test(.timeLimit(.minutes(1))) func authenticatedPairRenewsExchangesAndRejoins() async throws {
        let env = ProcessInfo.processInfo.environment
        let address = try #require(env["RIDEINTERCOM_PAIR_URL"])
        let url = try #require(URL(string: address))
        let aliceToken = try #require(env["RIDEINTERCOM_PAIR_TOKEN_A"])
        let bobToken = try #require(env["RIDEINTERCOM_PAIR_TOKEN_B"])
        let aliceConfiguration = URLSessionConfiguration.ephemeral
        aliceConfiguration.protocolClasses = [StalePeerSnapshotResponse.self]
        let alice = PairEndpoint(session: URLSession(configuration: aliceConfiguration)), bob = PairEndpoint()
        let credential = RTCCredential.derived(groupID: UUID().uuidString, secret: "synthetic-pair")
        func request(_ id: String) -> WebRTCSignalingConnectRequest {
            .init(
                call: .init(
                    sessionID: "pair", localPeer: .init(id: .init(rawValue: id), displayName: "PrivateName-\(id)"),
                    credential: credential),
                  cloudflare: .init(workerURL: url, accessToken: id == "alice" ? aliceToken : bobToken))
        }
        let aliceListener = alice.listen(), bobListener = bob.listen()
        var rejected = request("alice")
        rejected.cloudflare.accessToken = "unregistered-device-credential"
        await alice.client.connect(rejected)
        try await eventually { alice.blockedReasons.contains(.deviceCredentialRejected) }
        #expect(alice.failures.isEmpty)
        await alice.join(request("alice")); await bob.join(request("bob"))
        try await eventually { alice.members == ["bob"] && bob.members == ["alice"] }
        try await eventually { !alice.channelIDs(from: "bob").isEmpty && !bob.channelIDs(from: "alice").isEmpty }
        #expect(alice.answers == 1 && alice.failures.isEmpty)
        #expect(alice.peerNames == ["bob"] && bob.peerNames == ["alice"])
        let establishedAt = try await confirmEstablishment(
            alice: alice, aliceCall: request("alice").call, bob: bob, bobCall: request("bob").call)
        let originalAnswers = alice.answers
        await alice.client.sendApplicationData(.init(namespace: "pair", payload: Data("a-to-b".utf8)), to: nil)
        await bob.client.sendApplicationData(.init(namespace: "pair", payload: Data("b-to-a".utf8)), to: nil)
        try await eventually { alice.messages.contains("b-to-a") && bob.messages.contains("a-to-b") }
        // Cross two lease boundaries without replacing the published SFU connection.
        try await Task.sleep(for: .seconds(6))
        #expect(await bob.client.establishedAt == establishedAt)
        #expect(alice.answers == originalAnswers)
        #expect(alice.failures.isEmpty && bob.failures.isEmpty, "After renewal: A=\(alice.failures), B=\(bob.failures)")
        try await verifyRejoin(alice: alice, bob: bob, request: request("bob"))
        await alice.client.disconnect(); await bob.client.disconnect()
        aliceListener.cancel(); bobListener.cancel()
        #expect(alice.failures.isEmpty && bob.failures.isEmpty, "After rejoin: A=\(alice.failures), B=\(bob.failures)")
    }

    private func confirmEstablishment(
        alice: PairEndpoint, aliceCall: CallStartRequest, bob: PairEndpoint, bobCall: CallStartRequest,
        continuationDeadline: ContinuousClock.Instant = .now.advanced(by: .seconds(86400))
    ) async throws -> Double {
        var aliceRelay = GroupRelay(request: aliceCall), bobRelay = GroupRelay(request: bobCall)
        let presence = try aliceRelay.make(.presence, now: 0)
        #expect(presence.range(of: Data(aliceCall.localPeer.displayName.utf8)) == nil)
        await alice.client.sendApplicationData(.init(namespace: GroupRelay.namespace, payload: presence), to: nil)
        try await eventually { bob.groupPresence != nil }
        let received = try #require(bob.groupPresence)
        let reception = bobRelay.receive(received, from: aliceCall.localPeer.id, now: 0)
        let confirmed = try #require(reception)
        #expect(confirmed.peer.displayName == aliceCall.localPeer.displayName)
        #expect(await bob.client.establishedAt == nil)
        await bob.client.observeAuthenticatedInternetPeer(
            confirmed.peer.id, callID: bobCall.sessionID, continuationDeadline: continuationDeadline)
        try await eventually { await bob.client.establishedAt != nil }
        return try #require(await bob.client.establishedAt)
    }

    private func verifyRejoin(
        alice: PairEndpoint, bob: PairEndpoint, request: WebRTCSignalingConnectRequest
    ) async throws {
        let originalAnswers = alice.answers
        let originalChannels = alice.channelIDs(from: "bob")
        StalePeerSnapshotResponse.arm()
        await bob.client.disconnect()
        try await eventually { alice.members.isEmpty }
        await bob.join(request)
        try await eventually { alice.members == ["bob"] && bob.members == ["alice"] && bob.answers == 2 }
        try await eventually {
            let current = alice.channelIDs(from: "bob")
            return StalePeerSnapshotResponse.didReject && !current.isEmpty && current != originalChannels
        }
        #expect(alice.answers == originalAnswers)
        // No new offer for the listener: server reused its existing receiving mid.
        await bob.client.sendApplicationData(.init(namespace: "pair", payload: Data("after-rejoin".utf8)), to: nil)
        try await eventually { alice.messages.contains("after-rejoin") }
    }
}

private final class PairEndpoint: @unchecked Sendable {
    let client: CloudflareRealtimeSignalingClient
    private let lock = NSLock()
    private var recorded: [WebRTCSignalingEvent] = []
    private var values: [WebRTCSignalingEvent] { lock.withLock { recorded } }
    var members: Set<String> {
        for event in values.reversed() { if case .members(let peers) = event { return Set(peers.map(\.id.rawValue)) } }
        return []
    }
    var peerNames: Set<String> {
        for event in values.reversed() { if case .members(let peers) = event { return Set(peers.map(\.displayName)) } }
        return []
    }
    var groupPresence: Data? {
        for event in values.reversed() {
            if case .receivedApplicationData(let data) = event, data.message.namespace == GroupRelay.namespace {
                return data.message.payload
            }
        }
        return nil
    }
    var answers: Int { values.filter { if case .answer = $0 { return true }; return false }.count }
    func channelIDs(from peerID: String) -> Set<Int32> {
        for event in values.reversed() {
            if case .dataChannels(let channels) = event {
                return Set(channels.filter { !$0.isPublisher && $0.peerID?.rawValue == peerID }.map(\.id))
            }
        }
        return []
    }
    var failures: [String] { values.compactMap { if case .failed(let reason) = $0 { return reason }; return nil } }
    var blockedReasons: [ConnectionBlockReason] {
        values.compactMap { if case .blocked(let reason) = $0 { return reason }; return nil }
    }
    var messages: [String] {
        values.compactMap { event in
            guard case .receivedApplicationData(let data) = event else { return nil }
            return String(bytes: data.message.payload, encoding: .utf8)
        }
    }
    static let sdp = "v=0\r\nm=application 9 UDP/DTLS/SCTP webrtc-datachannel\r\na=mid:0\r\na=sctp-port:5000\r\n"
    init(session: URLSession = .shared) { client = CloudflareRealtimeSignalingClient(session: session) }
    func listen() -> Task<Void, Never> {
        let events = client.events
        return Task {
            for await event in events {
                lock.withLock { recorded.append(event) }
            }
        }
    }
    func join(_ request: WebRTCSignalingConnectRequest) async {
        await client.connect(request)
        await client.sendOffer(.init(kind: .offer, sdp: Self.sdp), to: .init(rawValue: "cloudflare-sfu"))
        await client.startPublishing()
    }
}

private final class StalePeerSnapshotResponse: URLProtocol, @unchecked Sendable {
    private enum State { case idle, armed, rejected }
    private static let state = Mutex(State.idle)
    static var didReject: Bool { state.withLock { $0 == .rejected } }
    static func arm() { state.withLock { $0 = .armed } }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.path.hasSuffix("/pull") == true && state.withLock { $0 == .armed }
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 403,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.state.withLock { $0 = .rejected }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"code":"peer_snapshot_changed"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class ScopedRenewalResponse: URLProtocol, @unchecked Sendable {
    private struct State {
        var rejectsPull = false
        var endsBeforeRenewalInterval = false
        var pullCount = 0
        var responseCount = 0
        var lastExpiry: Double?
    }
    private static let state = Mutex(State())
    static var responseCount: Int { state.withLock { $0.responseCount } }
    static var pullCount: Int { state.withLock { $0.pullCount } }
    static var lastExpiry: Double? { state.withLock { $0.lastExpiry } }
    static func reset(rejectsPull: Bool, endsBeforeRenewalInterval: Bool = false) {
        state.withLock { $0 = State(rejectsPull: rejectsPull, endsBeforeRenewalInterval: endsBeforeRenewalInterval) }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        guard request.httpMethod == "POST" else { return false }
        let action = request.url?.lastPathComponent
        return action == "renew" || (action == "pull" && state.withLock { $0.rejectsPull })
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let rejectsPull = request.url?.lastPathComponent == "pull"
        let endsBeforeRenewalInterval = Self.state.withLock { $0.endsBeforeRenewalInterval }
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: rejectsPull ? 401 : 200,
            httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let expiresAt = Date().addingTimeInterval(endsBeforeRenewalInterval ? 2 : 4).timeIntervalSince1970
        let body: [String: Any] = rejectsPull ? [:] : [
            "sessionId": url.deletingLastPathComponent().lastPathComponent,
            "expiresAt": expiresAt * 1000,
            "renewAfterSeconds": endsBeforeRenewalInterval ? 30 : 1,
            "continuationOnly": true
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        Self.state.withLock {
            if rejectsPull {
                $0.pullCount += 1
            } else {
                $0.responseCount += 1
                $0.lastExpiry = expiresAt
            }
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private func eventually(attempts: Int = 200, _ predicate: () async throws -> Bool) async throws {
    for _ in 0..<attempts {
        if try await predicate() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(try await predicate(), "Pair condition did not become true within its observation window")
}
