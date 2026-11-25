import Foundation

extension CloudflareRealtimeSignalingClient {
    struct IceConfiguration: Decodable { let iceServers: [WebRTCIceServer] }
    struct Description: Decodable { let type: String; let sdp: String }
    struct Pull: Decodable { let channels: [WebRTCDataChannel] }
    struct Lease: Decodable {
        let sessionId: String; let expiresAt: Double; let renewAfterSeconds: Double
        let sessionDescription: Description?; let channels: [WebRTCDataChannel]?
        let iceServers: [WebRTCIceServer]?
        let continuationOnly: Bool?
        let establishedAt: Double?

        func continuationRemaining(through callDeadline: ContinuousClock.Instant?) -> Double? {
            guard continuationOnly == true else { return nil }
            let server = expiresAt / 1000 - Date().timeIntervalSince1970
            guard let callDeadline else { return server }
            return min(server, ContinuousClock.now.duration(to: callDeadline) / .seconds(1))
        }
        func nextRenewalDelay(through callDeadline: ContinuousClock.Instant?) -> Double {
            min(max(1, renewAfterSeconds), max(0, continuationRemaining(through: callDeadline) ?? .infinity))
        }
    }

    /// Checks device authorization and quota configuration without creating SFU media.
    public static func checkService(
        _ configuration: CloudflareRealtimeConfiguration, session: URLSession = .shared
    ) async throws -> CloudflareServiceStatus {
        guard configuration.isValid else { throw Failure.invalidConfiguration }
        let data = try await fetch(
            configuration, url: configuration.workerURL.appendingPathComponent("api/status"), method: "GET",
            body: nil, session: session)
        return try JSONDecoder().decode(CloudflareServiceStatus.self, from: data)
    }

    private struct Rejection: Decodable { let code: String }

    func receiveMessage(from socket: URLSessionWebSocketTask) async throws -> URLSessionWebSocketTask.Message {
        do { return try await socket.receive() } catch {
            guard let response = socket.response as? HTTPURLResponse, let url = socket.originalRequest?.url,
                  response.url == url else { throw error }
            let rejection = Failure(httpStatus: response.statusCode)
            guard case .deviceCredentialRejected = rejection else { throw error }
            throw rejection
        }
    }

    static func fetch(
        _ configuration: CloudflareRealtimeConfiguration, url: URL, method: String, body: Data?,
        session: URLSession, retryConnectionLoss: Bool = false, totalTimeout: Duration = .seconds(25),
        establishmentPeers: Set<PeerID> = []
    ) async throws -> Data {
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue("Bearer \(configuration.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !establishmentPeers.isEmpty {
            let peerIDs = establishmentPeers.map(\.rawValue).sorted().joined(separator: ",")
            request.setValue(peerIDs, forHTTPHeaderField: "X-Established-Peer")
        }
        request.httpBody = body
        let operation: @Sendable () async throws -> Data = { [request] in
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: totalTimeout)
            return try await withThrowingTaskGroup(of: Data.self) { group in
                group.addTask {
                    try await fetchAttempts(
                        request, session: session, deadline: deadline, retryConnectionLoss: retryConnectionLoss)
                }
                group.addTask {
                    try await clock.sleep(until: deadline)
                    throw URLError(.timedOut)
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw URLError(.cancelled) }
                return result
            }
        }
        // Session teardown still sends its one bounded request after the call task is cancelled.
        if method == "DELETE" { return try await Task(operation: operation).value }
        return try await operation()
    }

    private static func fetchAttempts(
        _ initialRequest: URLRequest, session: URLSession, deadline: ContinuousClock.Instant,
        retryConnectionLoss: Bool
    ) async throws -> Data {
        var request = initialRequest
        var retries = 0
        while true {
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw URLError(.timedOut) }
            let components = remaining.components
            request.timeoutInterval = Double(components.seconds) + Double(components.attoseconds) / 1e18
            do {
                let (data, response) = try await session.data(for: request, delegate: NoRedirects())
                guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
                guard let response = response as? HTTPURLResponse,
                      response.url?.host == request.url?.host, response.url?.scheme == request.url?.scheme else {
                    throw Failure.invalidResponse
                }
                if (200..<300).contains(response.statusCode) { return data }
                let code = data.count <= 32768 ? (try? JSONDecoder().decode(Rejection.self, from: data))?.code : nil
                switch (response.statusCode, code) {
                case (409, "account_in_use"): throw Failure.accountInUse
                case (403, "peer_snapshot_changed") where request.url?.path.hasSuffix("/pull") == true:
                    throw Failure.peerSnapshotChanged
                case (503, "call_service_paused"): throw Failure.servicePaused
                default: throw Failure(httpStatus: response.statusCode)
                }
            } catch let error as URLError
                where retryConnectionLoss && error.code == .networkConnectionLost && retries < 2 {
                // Pull reconciles the requested subscriptions idempotently. A lost
                // keep-alive connection must not destroy otherwise healthy media.
                // Never repeat session creation, authorization failures or cancellation,
                // and retain the original request's total deadline across retries.
                retries += 1
                try await Task.sleep(for: .milliseconds(retries * 100))
            }
        }
    }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
