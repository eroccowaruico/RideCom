import Foundation

/// The SFU secret never enters this client. All media mutations are authorized by the Worker.
public actor CloudflareRealtimeSignalingClient: WebRTCSignalingClient {
    public nonisolated var events: AsyncStream<WebRTCSignalingEvent> { source.stream }
    private nonisolated let source = EventSource<WebRTCSignalingEvent>(
        overflowEvent: .failed("Control event queue overflow"))
    private let session: URLSession
    private var request: WebRTCSignalingConnectRequest?
    private var sessionID: String?
    private var iceLeaseID: String?
    private var generation = UUID()
    private var socket: URLSessionWebSocketTask?
    private var socketTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var peers: [PeerDescriptor] = []
    private var localChannels: [WebRTCDataChannel] = []
    private var publishing = false
    private static let sfuID = PeerID(rawValue: "cloudflare-sfu")

    public init(session: URLSession = .shared) { self.session = session }
    public func connect(_ request: WebRTCSignalingConnectRequest) async {
        let operation = UUID()
        await disconnect(generation: operation)
        guard generation == operation else { return }
        guard Self.valid(request.cloudflare), request.call.credential != nil else {
            source.yield(.failed("A secure Worker URL, device token and group invitation are required")); return
        }
        self.request = request
        let generation = generation
        let attempt = generation.uuidString
        iceLeaseID = attempt
        do {
            let data = try await http(
                request, path: "ice/\(request.call.localPeer.id.rawValue)", body: ["leaseID": attempt])
            let ice = try JSONDecoder().decode(IceConfiguration.self, from: data)
            guard self.generation == generation else {
                await releaseLease(request, iceLeaseID: attempt)
                return
            }
            source.yield(.iceServers(ice.iceServers))
            source.yield(.connected)
        } catch { await fail(error, generation: generation) }
    }
    public func disconnect() async { await disconnect(generation: UUID()) }
    private func disconnect(generation: UUID) async {
        self.generation = generation; socketTask?.cancel(); renewalTask?.cancel()
        socketTask = nil; renewalTask = nil; socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        let oldID = sessionID, oldRequest = request, oldIceLeaseID = iceLeaseID
        sessionID = nil; iceLeaseID = nil; request = nil; peers = []
        localChannels = []; publishing = false
        // Clear owned state before suspending. An old DELETE must never clear a new call.
        if let oldRequest {
            await releaseLease(oldRequest, sessionID: oldID, iceLeaseID: oldIceLeaseID)
        }
    }

    private func releaseLease(
        _ request: WebRTCSignalingConnectRequest, sessionID: String? = nil, iceLeaseID: String? = nil
    ) async {
        let path = sessionID.map { "sessions/\($0)" } ?? "ice/\(request.call.localPeer.id.rawValue)"
        _ = try? await http(
            request, path: path, method: "DELETE", body: sessionID == nil ? ["leaseID": iceLeaseID ?? ""] : nil)
    }

    public func sendOffer(_ offer: WebRTCSessionDescription, to peerID: PeerID) async {
        guard peerID == Self.sfuID, let request, sessionID == nil else { return }
        let generation = generation
        do {
            let response = try await http(
                request, path: "join",
                body: [
                    "participantId": request.call.localPeer.id.rawValue,
                "iceLeaseID": iceLeaseID ?? "", "offer": ["type": "offer", "sdp": offer.sdp]])
            let lease = try JSONDecoder().decode(Lease.self, from: response)
            guard self.generation == generation else {
                await releaseLease(request, sessionID: lease.sessionId)
                return
            }
            // The Worker has already allocated a session, even if it cannot be used.
            sessionID = lease.sessionId
            guard let description = lease.sessionDescription, description.type == "answer" else {
                throw Failure.invalidResponse
            }
            localChannels = lease.channels ?? []
            source.yield(.dataChannels(localChannels))
            source.yield(.answer(.init(kind: .answer, sdp: description.sdp), from: Self.sfuID))
            renewalTask = Task { [weak self] in
                var current = lease
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(max(1, current.renewAfterSeconds)))
                    guard !Task.isCancelled, let self else { return }
                    guard let next = await self.renew(request, lease: current, generation: generation) else { return }
                    current = next
                }
            }
        } catch { await fail(error, generation: generation) }
    }
    public func startPublishing() async {
        guard !publishing, let request, let sessionID else { return }
        publishing = true
        let generation = generation
        do {
            let response = try await http(request, path: "sessions/\(sessionID)/publish", body: [:])
            guard self.generation == generation else { return }
            let result = try JSONDecoder().decode(Pull.self, from: response)
            localChannels += result.channels
            source.yield(.dataChannels(localChannels))
            startSocket(request, id: sessionID, generation: generation)
        } catch { await fail(error, generation: generation) }
    }
    public func sendApplicationData(_ message: ApplicationDataMessage, to peerID: PeerID?) async {
        guard peerID == nil, let socket else { return }
        let generation = generation
        do {
            let data = try JSONSerialization.data(withJSONObject: [
                "type": "appData", "namespace": message.namespace,
                "payload": message.payload.base64EncodedString()
            ])
            guard data.count <= 32768, let text = String(bytes: data, encoding: .utf8) else { return }
            try await socket.send(.string(text))
        } catch {
            guard self.generation == generation, self.socket === socket else { return }
            // Control snapshots are refreshed periodically; an unavailable socket
            // must not tear down healthy media. The receive loop reconnects it.
            self.socket = nil
            socket.cancel(with: .goingAway, reason: nil)
        }
    }
    private func subscribe(
        _ request: WebRTCSignalingConnectRequest, id: String, generation: UUID
    ) async throws -> Bool {
        // The receive loop serializes pulls. The Worker owns subscription reconciliation.
        do {
            let response = try await http(
                request, path: "sessions/\(id)/pull", body: ["peerIds": peers.map { $0.id.rawValue }])
            guard self.generation == generation else { return false }
            let result = try JSONDecoder().decode(Pull.self, from: response)
            source.yield(.dataChannels(localChannels + result.channels))
            return true
        } catch Failure.peerSnapshotChanged {
            // Reopen signaling to fetch current peers without replacing the SFU session.
            throw Failure.peerSnapshotChanged
        } catch {
            await fail(error, generation: generation)
            return false
        }
    }
    private func renew(_ request: WebRTCSignalingConnectRequest, lease: Lease, generation: UUID) async -> Lease? {
        var delay = 1.0
        while self.generation == generation, !Task.isCancelled {
            do {
                let data = try await http(request, path: "sessions/\(lease.sessionId)/renew", body: [:])
                guard self.generation == generation else { return nil }
                let next = try JSONDecoder().decode(Lease.self, from: data)
                guard next.sessionId == lease.sessionId else { throw Failure.invalidResponse }
                if let servers = next.iceServers { source.yield(.iceServers(servers)) }
                return next
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return nil }
                let remaining = lease.expiresAt / 1000 - Date().timeIntervalSince1970
                let retryable = switch error {
                case Failure.servicePaused: true
                case Failure.http(let code): (500..<600).contains(code)
                default: error is URLError
                }
                guard retryable, remaining > delay else { await fail(error, generation: generation); return nil }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(10, delay * 2)
            }
        }
        return nil
    }
    private func fail(_ error: Error, generation: UUID) async {
        guard self.generation == generation else { return }
        let message = (error as? Failure)?.description ?? "Cloudflare connection failed"
        switch error {
        case Failure.accountInUse, Failure.http(401):
            source.yield(.blocked(message))
        default:
            source.yield(.failed(message))
        }
        await disconnect()
    }
    private struct Rejection: Decodable { let code: String }
    private struct IceConfiguration: Decodable { let iceServers: [WebRTCIceServer] }
    private struct Description: Decodable { let type: String; let sdp: String }
    private struct Lease: Decodable {
        let sessionId: String; let expiresAt: Double; let renewAfterSeconds: Double
        let sessionDescription: Description?; let channels: [WebRTCDataChannel]?
        let iceServers: [WebRTCIceServer]?
    }
    private struct Pull: Decodable { let channels: [WebRTCDataChannel] }
    private struct WirePeer: Decodable { let id: String; let sessionId: String }
    private struct WireEvent: Decodable {
        let type: String; let peers: [WirePeer]?; let from: String?; let namespace: String?; let payload: String?
    }
    private enum Failure: Error, LocalizedError {
        case invalidConfiguration, invalidResponse, accountInUse, peerSnapshotChanged, servicePaused, http(Int)
        var errorDescription: String? { description }
        var description: String {
            switch self {
            case .invalidConfiguration: "A secure Worker URL and device token are required"
            case .invalidResponse: "Invalid Cloudflare response"
            case .accountInUse:
                "This account already has an Internet call. End the existing call, then try again. "
                    + "If the other device lost its connection, wait for that call to expire."
            case .peerSnapshotChanged: "Cloudflare peer snapshot changed"
            case .servicePaused: String(localized: "Internet calling is paused.")
            case .http(401): String(localized: "In Settings, choose Set Up Internet Calling, then try again.")
            case .http(let code): "Cloudflare Worker rejected request (HTTP \(code))"
            }
        }
    }
}

private extension CloudflareRealtimeSignalingClient {
    func startSocket(_ request: WebRTCSignalingConnectRequest, id: String, generation: UUID) {
        socketTask = Task { [weak self] in
            var retry = 1
            while !Task.isCancelled {
                guard let self else { return }
                do { try await self.receiveSocket(request, id: id, generation: generation); return } catch {
                    guard !Task.isCancelled else { return }
                    if case Failure.http(401) = error {
                        await self.fail(error, generation: generation)
                        return
                    }
                    // Signaling can reconnect without replacing SFU media. Lease renewal still bounds lifetime.
                    try? await Task.sleep(for: .seconds(retry)); retry = min(10, retry * 2)
                }
            }
        }
    }
    func receiveSocket(_ request: WebRTCSignalingConnectRequest, id: String, generation: UUID) async throws {
        guard self.generation == generation else { return }
        let socket = session.webSocketTask(with: try socketUpgrade(request, id: id))
        socket.maximumMessageSize = 65536
        self.socket = socket; socket.resume()
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            if self.socket === socket { self.socket = nil }
        }
        while !Task.isCancelled {
            let message = try await receiveMessage(from: socket)
            guard self.generation == generation else { return }
            let data: Data
            switch message {
            case .data(let bytes): data = bytes
            case .string(let text): data = Data(text.utf8)
            @unknown default: continue
            }
            let event = try JSONDecoder().decode(WireEvent.self, from: data)
            if event.type == "peers", let remote = event.peers {
                // Signaling supplies routing identities only. Human-readable names
                // travel inside the authenticated, encrypted group presence.
                peers = remote.filter { $0.id != request.call.localPeer.id.rawValue }.map {
                    .init(id: .init(rawValue: $0.id), displayName: $0.id)
                }
                source.yield(.members(peers))
                guard try await subscribe(request, id: id, generation: generation) else { return }
            } else if event.type == "appData", let sender = event.from,
                peers.contains(where: { $0.id.rawValue == sender }),
                let namespace = event.namespace, let encoded = event.payload,
                let payload = Data(base64Encoded: encoded) {
                source.yield(
                    .receivedApplicationData(
                        .init(
                            peerID: .init(rawValue: sender), message: .init(namespace: namespace, payload: payload)
                        )))
            }
        }
    }
    func receiveMessage(from socket: URLSessionWebSocketTask) async throws -> URLSessionWebSocketTask.Message {
        do { return try await socket.receive() } catch {
            guard let response = socket.response as? HTTPURLResponse, let url = socket.originalRequest?.url,
                  response.statusCode == 401, response.url == url else { throw error }
            throw Failure.http(401)
        }
    }
    func socketUpgrade(_ request: WebRTCSignalingConnectRequest, id: String) throws -> URLRequest {
        let endpoint = try endpoint(request, path: "sessions/\(id)/signal")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw Failure.invalidConfiguration
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        guard let url = components.url else { throw Failure.invalidConfiguration }
        var upgrade = URLRequest(url: url)
        upgrade.setValue("Bearer \(request.cloudflare.accessToken)", forHTTPHeaderField: "Authorization")
        return upgrade
    }
}

extension CloudflareRealtimeSignalingClient {
    /// Checks device authorization and quota configuration without creating SFU media.
    public static func checkService(
        _ configuration: CloudflareRealtimeConfiguration, session: URLSession = .shared
    ) async throws -> CloudflareServiceStatus {
        guard valid(configuration) else { throw Failure.invalidConfiguration }
        let data = try await fetch(
            configuration, url: configuration.workerURL.appendingPathComponent("api/status"), method: "GET",
            body: nil, session: session)
        return try JSONDecoder().decode(CloudflareServiceStatus.self, from: data)
    }
    private static func valid(_ configuration: CloudflareRealtimeConfiguration) -> Bool {
        let url = configuration.workerURL
        return (url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1"].contains(url.host ?? "")))
            && url.host != nil && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
            && (url.path.isEmpty || url.path == "/") && !configuration.accessToken.isEmpty
    }

    private func endpoint(_ request: WebRTCSignalingConnectRequest, path: String) throws -> URL {
        guard let credential = request.call.credential else { throw Failure.invalidConfiguration }
        return request.cloudflare.workerURL.appendingPathComponent("api/rooms/\(credential.groupHash)/\(path)")
    }
    private func http(
        _ connect: WebRTCSignalingConnectRequest, path: String, method: String = "POST", body: [String: Any]? = nil
    ) async throws -> Data {
        try await Self.fetch(
            connect.cloudflare, url: try endpoint(connect, path: path), method: method,
            body: try body.map { try JSONSerialization.data(withJSONObject: $0) }, session: session,
            retryConnectionLoss: path.hasSuffix("/pull"))
    }
    static func fetch(
        _ configuration: CloudflareRealtimeConfiguration, url: URL, method: String, body: Data?,
        session: URLSession, retryConnectionLoss: Bool = false, totalTimeout: Duration = .seconds(25)
    ) async throws -> Data {
        var request = URLRequest(url: url); request.httpMethod = method
        request.setValue("Bearer \(configuration.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
                default: throw Failure.http(response.statusCode)
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
