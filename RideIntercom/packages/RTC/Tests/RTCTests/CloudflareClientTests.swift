import Foundation
import Synchronization
import Testing
@testable import RTC

@Suite(.serialized)
struct CloudflareClientTests {
    private func makeClient() -> CloudflareRealtimeSignalingClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SFUHTTPStub.self]
        return CloudflareRealtimeSignalingClient(session: URLSession(configuration: config))
    }
    private func request(url: String = "https://worker.test") throws -> WebRTCSignalingConnectRequest {
        .init(call: .init(sessionID: "group", localPeer: .init(id: .init(rawValue: "device"), displayName: "Device"),
                         credential: .derived(groupID: "group", secret: "invitation-secret")),
            cloudflare: .init(workerURL: try #require(URL(string: url)), accessToken: "device-token"))
    }
    @Test(arguments: ["ice", "join"], [401, 409])
    func credentialRejectionAndAccountConflictHaveDifferentBlockReasons(stage: String, status: Int) async throws {
        SFUHTTPStub.reset(rejectedStage: stage, rejectedStatus: status)
        let client = makeClient()
        var events = client.events.makeAsyncIterator()
        await client.connect(try request())
        if stage == "join" {
            guard case .iceServers = await events.next() else { Issue.record("Expected ICE"); return }
            #expect(await events.next() == .connected)
            await client.sendOffer(.init(kind: .offer, sdp: "offer"), to: .init(rawValue: "cloudflare-sfu"))
        }
        switch (status, await events.next()) {
        case (401, .blocked(.deviceCredentialRejected)):
            break
        case (409, .blocked(.manualRecovery(let message))):
            #expect(message.contains("End the existing call"))
            #expect(!message.contains("private-upstream-message"))
        default:
            Issue.record("Expected the block reason for the response")
        }
        let calls = SFUHTTPStub.requests
        #expect(calls.filter { $0.httpMethod == "POST" }.count == (stage == "ice" ? 1 : 2))
        #expect(calls.last?.httpMethod == "DELETE")
        #expect(calls.last?.url?.path.hasSuffix("/ice/device") == true)
        #expect(!calls.contains { $0.url?.path.contains("/sessions/") == true })
        await client.disconnect()
    }

    @Test(arguments: ["ice", "join"], ["call_service_paused", "other"])
    func servicePauseIsDistinguishedWithoutDisablingRecovery(stage: String, code: String) async throws {
        SFUHTTPStub.reset(rejectedStage: stage, rejectedStatus: 503, rejectedCode: code)
        let client = makeClient()
        var events = client.events.makeAsyncIterator()
        await client.connect(try request())
        if stage == "join" {
            guard case .iceServers = await events.next() else { Issue.record("Expected ICE"); return }
            #expect(await events.next() == .connected)
            await client.sendOffer(.init(kind: .offer, sdp: "offer"), to: .init(rawValue: "cloudflare-sfu"))
        }
        guard case .failed(let message) = await events.next() else {
            Issue.record("Expected a recoverable connection failure"); return
        }
        switch (code, stage) {
        case ("call_service_paused", _):
            #expect(message == String(localized: "Internet calling is paused."))
        case (_, "ice"):
            #expect(message == "\(String(localized: "ICE preparation")) · HTTP 503")
        default:
            #expect(message == "\(String(localized: "Call join")) · HTTP 503")
        }
        #expect(!message.contains("private-upstream-message"))
        #expect(SFUHTTPStub.requests.last?.httpMethod == "DELETE")
        await client.disconnect()
    }

    @Test func joinDoesNotSendTheLocalDisplayName() async throws {
        SFUHTTPStub.reset()
        let client = makeClient()
        await client.connect(try request())
        await client.sendOffer(.init(kind: .offer, sdp: "audio-offer"), to: .init(rawValue: "cloudflare-sfu"))
        let join = try #require(SFUHTTPStub.requests.first { $0.url?.path.hasSuffix("/join") == true })
        let data = try #require(join.httpBody)
        let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(body["participantId"] as? String == "device")
        #expect(body["displayName"] == nil)
        let text = try #require(String(bytes: data, encoding: .utf8))
        #expect(!text.contains("Device"))
        await client.disconnect()
    }

    @Test func releasesTheJoinedSessionWhenTheAnswerIsMissing() async throws {
        SFUHTTPStub.reset(missingAnswer: true)
        let client = makeClient()
        await client.connect(try request())
        await client.sendOffer(.init(kind: .offer, sdp: "offer"), to: .init(rawValue: "cloudflare-sfu"))
        await client.disconnect()

        let releases = SFUHTTPStub.requests.filter { $0.httpMethod == "DELETE" }
        #expect(releases.count == 1)
        #expect(releases.first?.url?.path.hasSuffix("/sessions/same-session") == true)
    }

    @Test func iceCredentialsArriveBeforeOfferAndAreCleanedUpWithoutSession() async throws {
        SFUHTTPStub.reset()
        let client = makeClient()
        var events = client.events.makeAsyncIterator()
        await client.connect(try request())
        guard case .iceServers(let servers) = await events.next() else {
            Issue.record("Expected ICE before connect"); return
        }
        #expect(servers.first?.urls == ["stun:stun.cloudflare.com:3478"])
        #expect(await events.next() == .connected)
        await client.disconnect()
        #expect(SFUHTTPStub.requests.first?.url?.path.hasSuffix("/ice/device") == true)
        #expect(SFUHTTPStub.requests.last?.httpMethod == "DELETE")
        #expect(SFUHTTPStub.requests.last?.url?.path.hasSuffix("/ice/device") == true)
    }

    @Test func renewsSameSFUSessionAndClosesOnQuotaWithoutExposingCloudflareSecret() async throws {
        SFUHTTPStub.reset()
        let client = makeClient(), request = try request()
        let events = client.events
        let failed = Mutex(false)
        let observer = Task {
            for await event in events {
                if case .failed = event {
                    failed.withLock { $0 = true }
                    return
                }
            }
        }
        defer { observer.cancel() }
        await client.connect(request)
        await client.sendOffer(.init(kind: .offer, sdp: "audio-offer"), to: .init(rawValue: "cloudflare-sfu"))
        let calls = await SFUHTTPStub.waitForRequests { calls in
            failed.withLock { $0 } && calls.contains {
                $0.httpMethod == "DELETE" && $0.url?.path.hasSuffix("/sessions/same-session") == true
            }
        }
        #expect(calls.filter { $0.url?.path.hasSuffix("/join") == true }.count == 1)
        #expect(calls.filter { $0.url?.path.hasSuffix("/renew") == true }.count == 2)
        #expect(
            calls.contains {
                $0.httpMethod == "DELETE" && $0.url?.path.hasSuffix("/sessions/same-session") == true
            })
        #expect(calls.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer device-token" })
        let groupHash = try #require(request.call.credential).groupHash
        #expect(calls.allSatisfy { $0.url?.path.contains(groupHash) == true })
        #expect(failed.withLock { $0 })
        await client.disconnect()
    }
    @Test(arguments: [false, true])
    func temporaryRenewalFailureKeepsTheExistingSessionAndRetries(paused: Bool) async throws {
        SFUHTTPStub.reset(transient: true, rejectedStage: paused ? "firstRenewal" : nil,
                          rejectedStatus: 503, rejectedCode: "call_service_paused")
        let client = makeClient()
        await client.connect(try request())
        await client.sendOffer(.init(kind: .offer, sdp: "audio-offer"), to: .init(rawValue: "cloudflare-sfu"))
        // A third renewal proves the recovered session entered its next renewal cycle.
        let calls = await SFUHTTPStub.waitForRequests { calls in
            calls.filter { $0.url?.path.hasSuffix("/renew") == true }.count >= 3
        }
        #expect(calls.filter { $0.url?.path.hasSuffix("/join") == true }.count == 1)
        #expect(calls.filter { $0.url?.path.hasSuffix("/renew") == true }.count >= 3)
        #expect(!calls.contains { $0.httpMethod == "DELETE" })
        await client.disconnect()
    }

    @Test func cancelledReconnectCannotIssueCredentialsAfterOldCleanupFinishes() async throws {
        SFUHTTPStub.reset(delayFirstDelete: true)
        let client = makeClient()
        await client.connect(try request())
        await client.sendOffer(.init(kind: .offer, sdp: "first"), to: .init(rawValue: "cloudflare-sfu"))
        let next = try request()
        let reconnect = Task { await client.connect(next) }
        for _ in 0..<100 {
            if SFUHTTPStub.requests.contains(where: { $0.httpMethod == "DELETE" }) { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        await client.disconnect()
        await reconnect.value
        #expect(
            SFUHTTPStub.requests.filter { $0.httpMethod == "POST" && $0.url?.path.contains("/ice/") == true }.count
                == 1)
    }

    @Test func cancelledConnectCannotReplaceAnActiveSession() async throws {
        SFUHTTPStub.reset()
        let client = makeClient(), request = try request()
        await client.connect(request)
        await client.sendOffer(.init(kind: .offer, sdp: "first"), to: .init(rawValue: "cloudflare-sfu"))

        let (waiting, release) = AsyncStream<Void>.makeStream()
        let cancelled = Task {
            for await _ in waiting { break }
            await client.connect(request)
        }
        cancelled.cancel()
        release.finish()
        await cancelled.value

        let calls = SFUHTTPStub.requests
        #expect(!calls.contains { $0.httpMethod == "DELETE" })
        #expect(calls.filter { $0.httpMethod == "POST" && $0.url?.path.contains("/ice/") == true }.count == 1)
        #expect(calls.filter { $0.url?.path.hasSuffix("/join") == true }.count == 1)
        await client.disconnect()
    }

    @Test func delayedOldDisconnectCannotClearTheNewConnection() async throws {
        SFUHTTPStub.reset(delayFirstDelete: true)
        let client = makeClient()
        await client.connect(try request())
        await client.sendOffer(.init(kind: .offer, sdp: "first"), to: .init(rawValue: "cloudflare-sfu"))
        let stopping = Task { await client.disconnect() }
        for _ in 0..<100 {
            if SFUHTTPStub.requests.contains(where: { $0.httpMethod == "DELETE" }) { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        await client.connect(try request())
        await client.sendOffer(.init(kind: .offer, sdp: "second"), to: .init(rawValue: "cloudflare-sfu"))
        await stopping.value
        await client.sendOffer(.init(kind: .offer, sdp: "duplicate"), to: .init(rawValue: "cloudflare-sfu"))
        #expect(SFUHTTPStub.requests.filter { $0.url?.path.hasSuffix("/join") == true }.count == 2)
        await client.disconnect()
        #expect(
            SFUHTTPStub.requests.contains {
                $0.httpMethod == "DELETE" && $0.url?.path.hasSuffix("/sessions/session-2") == true
            })
    }

    @Test func serviceCheckValidatesConfigurationAndDoesNotCreateMedia() async throws {
        SFUHTTPStub.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SFUHTTPStub.self]
        let session = URLSession(configuration: config)
        let status = try await CloudflareRealtimeSignalingClient.checkService(request().cloudflare, session: session)
        #expect(status.monthlyParticipantSeconds == 1000000)
        #expect(status.activeSessions == 0)
        #expect(SFUHTTPStub.requests.map { $0.url?.path } == ["/api/status"])
        do {
            _ = try await CloudflareRealtimeSignalingClient.checkService(
                request(url: "http://public.example").cloudflare, session: session)
            Issue.record("Insecure public endpoint accepted")
        } catch { }
        #expect(SFUHTTPStub.requests.count == 1)
        SFUHTTPStub.reset(rejectedStage: "status", rejectedStatus: 503, rejectedCode: "call_service_paused")
        do {
            _ = try await CloudflareRealtimeSignalingClient.checkService(request().cloudflare, session: session)
            Issue.record("Paused service reported as ready")
        } catch {
            #expect(error.localizedDescription == String(localized: "Internet calling is paused."))
        }
        #expect(SFUHTTPStub.requests.map { $0.url?.path } == ["/api/status"])
    }

    @Test func rejectsInsecurePublicEndpointBeforeMakingRequests() async throws {
        SFUHTTPStub.reset()
        let client = makeClient(); var events = client.events.makeAsyncIterator()
        await client.connect(try request(url: "http://public.example"))
        guard case .failed = await events.next() else { Issue.record("Expected configuration rejection"); return }
        #expect(SFUHTTPStub.requests.isEmpty)
    }
}
private final class SFUHTTPStub: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func waitForRequests(_ ready: ([URLRequest]) -> Bool) async -> [URLRequest] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var calls = requests
        while !ready(calls), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
            calls = requests
        }
        return calls
    }
    nonisolated(unsafe) private static var transient = false
    nonisolated(unsafe) private static var delayFirstDelete = false
    nonisolated(unsafe) private static var rejectedStage: String?
    nonisolated(unsafe) private static var rejectedStatus = 409
    nonisolated(unsafe) private static var rejectedCode = "account_in_use"
    nonisolated(unsafe) private static var missingAnswer = false
    static func reset(
        transient: Bool = false, delayFirstDelete: Bool = false,
        rejectedStage: String? = nil, rejectedStatus: Int = 409, rejectedCode: String = "account_in_use",
        missingAnswer: Bool = false
    ) {
        lock.withLock {
            recorded = []; self.transient = transient; self.delayFirstDelete = delayFirstDelete
            self.rejectedStage = rejectedStage
            self.rejectedStatus = rejectedStatus
            self.rejectedCode = rejectedCode
            self.missingAnswer = missingAnswer
        }
    }
    override static func canInit(with request: URLRequest) -> Bool { request.url?.scheme == "https" }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let captured = requestWithBody()
        guard let url = request.url else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let path = url.path
        let renewals = Self.lock.withLock {
            Self.recorded.append(captured)
            return Self.recorded.filter { $0.url?.path.hasSuffix("/renew") == true }.count
        }
        let transient = Self.lock.withLock { Self.transient }
        let renewing = path.hasSuffix("/renew")
        let rejected = Self.lock.withLock {
            (request.httpMethod == "GET" && Self.rejectedStage == "status" && path == "/api/status")
                || (request.httpMethod == "POST" && (Self.rejectedStage == "ice" && path.contains("/ice/")
                    || Self.rejectedStage == "join" && path.hasSuffix("/join")
                    || Self.rejectedStage == "firstRenewal" && renewing && renewals == 1))
        }
        let status =
            rejected
            ? Self.lock.withLock { Self.rejectedStatus }
            : renewing ? (transient ? (renewals == 1 ? 503 : 200) : (renewals >= 2 ? 429 : 200)) : 200
        guard let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"]
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let sessionID = Self.lock.withLock {
            Self.delayFirstDelete
                ? "session-\(Self.recorded.filter { $0.url?.path.hasSuffix("/join") == true }.count)" : "same-session"
        }
        let responseData = data(path: path, sessionID: sessionID, rejected: rejected)
        let delayed = Self.lock.withLock {
            Self.delayFirstDelete && request.httpMethod == "DELETE"
                && Self.recorded.filter { $0.httpMethod == "DELETE" }.count == 1
        }
        let finish: @Sendable () -> Void = { [self] in
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseData); client?.urlProtocolDidFinishLoading(self)
        }
        if delayed { DispatchQueue.global().asyncAfter(deadline: .now() + 0.5, execute: finish) } else { finish() }
    }
    private func requestWithBody() -> URLRequest {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var bytes = Data(), buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                bytes.append(contentsOf: buffer.prefix(count))
            }
            captured.httpBody = bytes
        }
        return captured
    }

    private func data(path: String, sessionID: String, rejected: Bool) -> Data {
        let missingAnswer = Self.lock.withLock { Self.missingAnswer }
        let answer = missingAnswer ? "" : ",\"sessionDescription\":{\"type\":\"answer\",\"sdp\":\"answer\"}"
        let sessionJSON = "{\"sessionId\":\"\(sessionID)\",\"expiresAt\":9999999999999,"
            + "\"renewAfterSeconds\":1\(answer)}"
        var data = Data(sessionJSON.utf8)
        if path.contains("/ice/") {
            data = Data("{\"iceServers\":[{\"urls\":[\"stun:stun.cloudflare.com:3478\"]}]}".utf8)
        }
        if path == "/api/status" {
            let limitsJSON = "{\"month\":\"2026-10\",\"reservedParticipantSeconds\":0,"
                + "\"monthlyParticipantSeconds\":1000000,\"activeSessions\":0}"
            data = Data(limitsJSON.utf8)
        }
        if rejected {
            let code = Self.lock.withLock { Self.rejectedCode }
            data = Data("{\"code\":\"\(code)\",\"error\":\"private-upstream-message\"}".utf8)
        }
        return data
    }

    override func stopLoading() {}
}
