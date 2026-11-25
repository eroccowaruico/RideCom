import Foundation
import Synchronization
import Testing
@testable import RTC

@Suite(.serialized)
struct CloudflareRequestRetryTests {
    private func fetch(retry: Bool = true, method: String = "POST") async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [LostConnectionProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let origin = try #require(URL(string: "https://retry.test"))
        return try await CloudflareRealtimeSignalingClient.fetch(
            .init(workerURL: origin, accessToken: "synthetic-test-token"),
            url: origin.appendingPathComponent(retry ? "sessions/s/pull" : "join"),
            method: method, body: Data("{\"peerIds\":[\"peer\"]}".utf8), session: session,
            retryConnectionLoss: retry)
    }

    @Test func accountConflictGivesActionableAdviceWithoutRetryingOrEchoingServerText() async {
        LostConnectionProtocol.configure(failures: 0, status: 409,
            body: "{\"code\":\"account_in_use\",\"error\":\"private-upstream-message\"}")
        do { _ = try await fetch(); Issue.record("Expected account conflict") } catch {
            let advice = "This account already has an Internet call. End the existing call, then try again. "
                + "If the other device lost its connection, wait for that call to expire."
            #expect(error.localizedDescription == advice)
        }
        #expect(LostConnectionProtocol.requests.count == 1)
    }

    @Test(arguments: ["missing", "unknown", "wrongType", "invalid", "oversized", "wrongStatus"])
    func otherConflictResponsesKeepGenericFailure(scenario: String) async throws {
        let bodies = ["missing": "{}", "unknown": "{\"code\":\"unknown\"}", "wrongType": "{\"code\":5}",
            "invalid": "invalid",
            "oversized": String(repeating: " ", count: 32769) + "{\"code\":\"account_in_use\"}",
                      "wrongStatus": "{\"code\":\"account_in_use\"}"]
        let status = scenario == "wrongStatus" ? 503 : 409
        LostConnectionProtocol.configure(failures: 0, status: status, body: try #require(bodies[scenario]))
        do { _ = try await fetch(); Issue.record("Expected conflict") } catch {
            #expect(error.localizedDescription == "Cloudflare Worker rejected request (HTTP \(status))")
        }
        #expect(LostConnectionProtocol.requests.count == 1)
    }

    @Test func lostPullConnectionRetainsRequestAndSucceedsWithinThreeAttempts() async throws {
        LostConnectionProtocol.configure(failures: 2)
        let data = try await fetch()
        #expect(data == Data("{\"channels\":[]}".utf8))
        let requests = LostConnectionProtocol.requests
        #expect(requests.count == 3)
        #expect(Set(requests.map(\.url)).count == 1)
        #expect(requests.allSatisfy { $0.httpMethod == "POST" })
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-test-token" })
    }

    @Test func persistentConnectionLossStopsAfterThreeAttempts() async {
        LostConnectionProtocol.configure(failures: 100)
        do { _ = try await fetch(); Issue.record("Expected connection loss") } catch {
            #expect((error as? URLError)?.code == .networkConnectionLost)
        }
        #expect(LostConnectionProtocol.requests.count == 3)
    }

    @Test func sessionCreationIsNeverAutomaticallyRepeated() async {
        LostConnectionProtocol.configure(failures: 1)
        do { _ = try await fetch(retry: false); Issue.record("Expected connection loss") } catch {
            #expect((error as? URLError)?.code == .networkConnectionLost)
        }
        #expect(LostConnectionProtocol.requests.count == 1)
    }

    @Test func cancellationAndAuthorizationFailureAreNeverRetried() async {
        LostConnectionProtocol.configure(failures: 1, error: .cancelled)
        do { _ = try await fetch(); Issue.record("Expected cancellation") } catch {
            #expect((error as? URLError)?.code == .cancelled)
        }
        #expect(LostConnectionProtocol.requests.count == 1)
        LostConnectionProtocol.configure(failures: 0, status: 403)
        do { _ = try await fetch(); Issue.record("Expected authorization failure") } catch {}
        #expect(LostConnectionProtocol.requests.count == 1)
    }

    @Test func aCancelledCallerStillMakesOneCleanupRequest() async throws {
        LostConnectionProtocol.configure(failures: 0)
        let cleanup = Task {
            try? await Task.sleep(for: .seconds(2))
            #expect(Task.isCancelled)
            return try await fetch(retry: false, method: "DELETE")
        }
        cleanup.cancel()
        _ = try await cleanup.value
        #expect(LostConnectionProtocol.requests.map(\.httpMethod) == ["DELETE"])
    }

    @Test func incomingDataCannotExtendTheTotalDeadline() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ProgressingResponseProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let origin = try #require(URL(string: "https://progress.test"))
        do {
            _ = try await CloudflareRealtimeSignalingClient.fetch(
                .init(workerURL: origin, accessToken: "synthetic-test-token"),
                url: origin.appendingPathComponent("sessions/s/pull"),
                method: "POST", body: nil, session: session, retryConnectionLoss: true,
                totalTimeout: .milliseconds(240))
            Issue.record("A response that kept transferring past the deadline succeeded")
        } catch {
            #expect((error as? URLError)?.code == .timedOut)
        }
        for _ in 0..<50 where !ProgressingResponseProtocol.wasStopped {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ProgressingResponseProtocol.delivered > 0)
        #expect(ProgressingResponseProtocol.wasStopped)
        #expect(!ProgressingResponseProtocol.didFinish)
    }
}

private final class ProgressingResponseProtocol: URLProtocol, @unchecked Sendable {
    private struct Observation { var delivered = 0; var stopped = false; var finished = false }
    private static let observation = Mutex(Observation())
    private let stream = Mutex<Task<Void, Never>?>(nil)
    static var delivered: Int { observation.withLock { $0.delivered } }
    static var wasStopped: Bool { observation.withLock { $0.stopped } }
    static var didFinish: Bool { observation.withLock { $0.finished } }

    override static func canInit(with request: URLRequest) -> Bool { request.url?.host == "progress.test" }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: nil
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        stream.withLock { task in
            task = Task { @Sendable [weak self] in
                for _ in 0..<32 {
                    do { try await Task.sleep(for: .milliseconds(25)) } catch { return }
                    guard let self, !Task.isCancelled else { return }
                    Self.observation.withLock { $0.delivered += 1 }
                    client?.urlProtocol(self, didLoad: Data(" ".utf8))
                }
                guard let self else { return }
                Self.observation.withLock { $0.finished = true }
                client?.urlProtocolDidFinishLoading(self)
            }
        }
    }
    override func stopLoading() {
        stream.withLock { task in task?.cancel(); task = nil }
        Self.observation.withLock { $0.stopped = true }
    }
}

private final class LostConnectionProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var recorded: [URLRequest] = []
    nonisolated(unsafe) private static var failures = 0
    nonisolated(unsafe) private static var error = URLError.Code.networkConnectionLost
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var body = "{\"channels\":[]}"
    static var requests: [URLRequest] { lock.withLock { recorded } }
    static func configure(
        failures: Int, error: URLError.Code = .networkConnectionLost, status: Int = 200,
        body: String = "{\"channels\":[]}"
    ) {
        lock.withLock {
            recorded = []; self.failures = failures; self.error = error; self.status = status; self.body = body
        }
    }
    override static func canInit(with request: URLRequest) -> Bool { request.url?.host == "retry.test" }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let (fail, error, status, body) = Self.lock.withLock {
            Self.recorded.append(request)
            return (Self.recorded.count <= Self.failures, Self.error, Self.status, Self.body)
        }
        if fail { client?.urlProtocol(self, didFailWithError: URLError(error)); return }
        guard let url = request.url, let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil
        ) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension CloudflareClientTests {
    @Test(arguments: ["https://worker.test", "https://another.test"])
    func renewsTheSameSessionUsingOnlyCredentialsForItsOriginalWorker(origin: String) async throws {
        SFUHTTPStub.reset()
        let configuration = Mutex<CloudflareRealtimeConfiguration?>(nil)
        let client = makeClient { configuration.withLock { $0 } }
        let call = try request()
        await client.connect(call)
        await client.sendOffer(.init(kind: .offer, sdp: "offer"), to: .init(rawValue: "cloudflare-sfu"))
        let worker = try #require(URL(string: origin))
        configuration.withLock { $0 = .init(workerURL: worker, accessToken: "replacement-device-token") }
        let calls = await SFUHTTPStub.waitForRequests { calls in
            calls.contains { $0.url?.path.hasSuffix("/sessions/same-session/renew") == true }
        }
        let renew = try #require(calls.first { $0.url?.path.hasSuffix("/sessions/same-session/renew") == true })
        let token = worker == call.cloudflare.workerURL ? "replacement-device-token" : "device-token"
        #expect(renew.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
        #expect(calls.filter { $0.url?.path.hasSuffix("/join") == true }.count == 1)
        #expect(calls.allSatisfy { $0.url?.host == call.cloudflare.workerURL.host })
        #expect(!calls.contains { $0.httpMethod == "DELETE" })
        await client.disconnect()
        let release = try #require(SFUHTTPStub.requests.last { $0.httpMethod == "DELETE" })
        #expect(release.url?.path.hasSuffix("/sessions/same-session") == true)
        #expect(release.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
    }
}
