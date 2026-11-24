import Foundation
import Synchronization
import Testing
@testable import RTC

@Suite(.enabled(if: ProcessInfo.processInfo.environment["RIDEINTERCOM_PAIR_URL"] != nil))
struct WorkerPairTests {
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
        try await eventually { alice.blockedMessages.contains { $0.contains("Set Up Internet Calling") } }
        #expect(alice.failures.isEmpty)
        await alice.join(request("alice")); await bob.join(request("bob"))
        try await eventually { alice.members == ["bob"] && bob.members == ["alice"] }
        try await eventually { !alice.channelIDs(from: "bob").isEmpty && !bob.channelIDs(from: "alice").isEmpty }
        #expect(alice.answers == 1 && alice.failures.isEmpty)
        #expect(alice.peerNames == ["bob"] && bob.peerNames == ["alice"])
        var aliceRelay = GroupRelay(request: request("alice").call)
        var bobRelay = GroupRelay(request: request("bob").call)
        let presence = try aliceRelay.make(.presence, now: 0)
        #expect(presence.range(of: Data("PrivateName-alice".utf8)) == nil)
        await alice.client.sendApplicationData(.init(namespace: GroupRelay.namespace, payload: presence), to: nil)
        try await eventually { bob.groupPresence != nil }
        let received = try #require(bob.groupPresence)
        #expect(
            bobRelay.receive(received, from: .init(rawValue: "alice"), now: 0)?.peer.displayName
                == "PrivateName-alice")
        let originalAnswers = alice.answers
        await alice.client.sendApplicationData(.init(namespace: "pair", payload: Data("a-to-b".utf8)), to: nil)
        await bob.client.sendApplicationData(.init(namespace: "pair", payload: Data("b-to-a".utf8)), to: nil)
        try await eventually { alice.messages.contains("b-to-a") && bob.messages.contains("a-to-b") }
        // Cross two lease boundaries without replacing the published SFU connection.
        try await Task.sleep(for: .seconds(6))
        #expect(alice.answers == originalAnswers)
        #expect(alice.failures.isEmpty && bob.failures.isEmpty, "After renewal: A=\(alice.failures), B=\(bob.failures)")
        try await verifyRejoin(alice: alice, bob: bob, request: request("bob"))
        await alice.client.disconnect(); await bob.client.disconnect()
        aliceListener.cancel(); bobListener.cancel()
        #expect(alice.failures.isEmpty && bob.failures.isEmpty, "After rejoin: A=\(alice.failures), B=\(bob.failures)")
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
    var blockedMessages: [String] {
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

private func eventually(_ predicate: () -> Bool) async throws {
    for _ in 0..<200 {
        if predicate() { return }
        try await Task.sleep(for: .milliseconds(25))
    }
    #expect(predicate(), "Pair condition did not become true within five seconds")
}
