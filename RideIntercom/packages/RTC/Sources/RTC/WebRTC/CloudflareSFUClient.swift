import Foundation

/// The SFU secret never enters this client. All media mutations are authorized by the Worker.
public actor CloudflareRealtimeSignalingClient: WebRTCSignalingClient, AuthenticatedInternetPeerObserving {
    public nonisolated var events: AsyncStream<WebRTCSignalingEvent> { source.stream }
    private nonisolated let source = EventSource<WebRTCSignalingEvent>(
        overflowEvent: .failed("Control event queue overflow"))
    private let session: URLSession
    private let currentConfiguration: @Sendable () -> CloudflareRealtimeConfiguration?
    private var request: WebRTCSignalingConnectRequest?
    private var sessionID: String?
    private var iceLeaseID: String?
    private var generation = UUID()
    private var socket: URLSessionWebSocketTask?
    private var socketTask: Task<Void, Never>?
    private var renewalTask: Task<Void, Never>?
    private var renewalWait: Task<Void, Never>?
    private var needsEarlyRenewal = false
    private var currentLease: Lease?
    private var establishmentPeers: Set<PeerID> = []
    private var callContinuationDeadline: ContinuousClock.Instant?
    private(set) var establishedAt: Double?
    private var peers: [PeerDescriptor] = []
    private var localChannels: [WebRTCDataChannel] = []
    private var publishing = false
    private static let sfuID = PeerID(rawValue: "cloudflare-sfu")

    public init(
        session: URLSession = .shared,
        currentConfiguration: @escaping @Sendable () -> CloudflareRealtimeConfiguration? = { nil }
    ) {
        self.session = session
        self.currentConfiguration = currentConfiguration
    }
    public func connect(_ request: WebRTCSignalingConnectRequest) async {
        guard !Task.isCancelled else { return }
        let operation = UUID()
        await disconnect(generation: operation)
        guard generation == operation, !Task.isCancelled else { return }
        guard request.cloudflare.isValid, request.call.credential != nil else {
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
        } catch { await fail(error, generation: generation, step: String(localized: "ICE preparation")) }
    }
    public func disconnect() async { await disconnect(generation: UUID()) }
    private func disconnect(generation: UUID) async {
        self.generation = generation; socketTask?.cancel(); renewalTask?.cancel()
        socketTask = nil; renewalTask = nil; socket?.cancel(with: .normalClosure, reason: nil); socket = nil
        renewalWait = nil; needsEarlyRenewal = false
        let oldID = sessionID, oldIceLeaseID = iceLeaseID
        let oldRequest = request.map { oldID == nil ? $0 : $0.replacingWorkerCredential(currentConfiguration()) }
        sessionID = nil; iceLeaseID = nil; request = nil; peers = []; currentLease = nil
        establishmentPeers = []; establishedAt = nil; callContinuationDeadline = nil
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
            currentLease = lease
            startRenewing(request, generation: generation)
        } catch { await fail(error, generation: generation, step: String(localized: "Call join")) }
    }

    public func startPublishing() async {
        guard !publishing, let request, let sessionID else { return }
        publishing = true
        let generation = generation
        do {
            let response = try await http(
                request.replacingWorkerCredential(currentConfiguration()),
                path: "sessions/\(sessionID)/publish", body: [:])
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
                request.replacingWorkerCredential(currentConfiguration()),
                path: "sessions/\(id)/pull", body: ["peerIds": peers.map { $0.id.rawValue }])
            guard self.generation == generation else { return false }
            let result = try JSONDecoder().decode(Pull.self, from: response)
            source.yield(.dataChannels(localChannels + result.channels))
            return true
        } catch Failure.peerSnapshotChanged {
            // Reopen signaling to fetch current peers without replacing the SFU session.
            throw Failure.peerSnapshotChanged
        } catch Failure.deviceCredentialRejected {
            throw Failure.deviceCredentialRejected
        } catch {
            await fail(error, generation: generation)
            return false
        }
    }
    private func renew(_ request: WebRTCSignalingConnectRequest, lease: Lease, generation: UUID) async -> Bool {
        var delay = 1.0
        while self.generation == generation, !Task.isCancelled {
            do {
                guard let next = try await requestRenewal(request, id: lease.sessionId, generation: generation),
                      self.generation == generation, !Task.isCancelled else { return false }
                acceptRenewal(next)
                return true
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return false }
                let continuation = lease.continuationRemaining(through: callContinuationDeadline)
                if let continuation, continuation <= 0 {
                    await fail(Failure.deviceCredentialRejected, generation: generation)
                    return false
                }
                let remaining = continuation ?? lease.expiresAt / 1000 - Date().timeIntervalSince1970
                let retryable = switch error {
                case Failure.servicePaused: true
                case Failure.http(let code): (500..<600).contains(code)
                default: error is URLError
                }
                guard retryable, remaining > delay else { await fail(error, generation: generation); return false }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(10, delay * 2)
            }
        }
        return false
    }

    private func requestRenewal(
        _ request: WebRTCSignalingConnectRequest, id: String, generation: UUID
    ) async throws -> Lease? {
        guard self.generation == generation, sessionID == id, !Task.isCancelled else { return nil }
        let remaining = currentLease?.continuationRemaining(through: callContinuationDeadline) ?? .infinity
        guard remaining > 0 else { throw Failure.deviceCredentialRejected }
        let candidates = currentLease?.continuationOnly == true ? [] : establishmentPeers
        needsEarlyRenewal = false
        let data = try await http(
            request.replacingWorkerCredential(currentConfiguration()),
            path: "sessions/\(id)/renew", body: [:], totalTimeout: .seconds(min(25, remaining)),
            establishmentPeers: candidates)
        guard self.generation == generation, sessionID == id, !Task.isCancelled else { return nil }
        guard (currentLease?.continuationRemaining(through: callContinuationDeadline) ?? .infinity) > 0 else {
            throw Failure.deviceCredentialRejected
        }
        let lease = try JSONDecoder().decode(Lease.self, from: data)
        guard lease.sessionId == id else { throw Failure.invalidResponse }
        guard (lease.continuationRemaining(through: callContinuationDeadline) ?? .infinity) > 0 else {
            throw Failure.deviceCredentialRejected
        }
        return lease
    }

    private func continuationRetryDelay(
        _ request: WebRTCSignalingConnectRequest, id: String, generation: UUID
    ) async -> Double? {
        guard self.generation == generation, !Task.isCancelled else { return nil }
        let previous = renewalTask
        previous?.cancel()
        await previous?.value
        guard let lease = try? await requestRenewal(request, id: id, generation: generation),
              self.generation == generation, !Task.isCancelled,
              let remaining = lease.continuationRemaining(through: callContinuationDeadline), remaining > 0
        else { return nil }
        acceptRenewal(lease)
        startRenewing(request, generation: generation)
        return lease.nextRenewalDelay(through: callContinuationDeadline)
    }

    private func acceptRenewal(_ lease: Lease) {
        currentLease = lease
        if establishedAt == nil, let confirmed = lease.establishedAt {
            establishedAt = confirmed
            establishmentPeers = []
            needsEarlyRenewal = false
        }
        if lease.continuationOnly == true { needsEarlyRenewal = false }
        if let servers = lease.iceServers { source.yield(.iceServers(servers)) }
    }

    private func fail(_ error: Error, generation: UUID, step: String? = nil) async {
        guard self.generation == generation else { return }
        let message = (error as? Failure)?.description ?? "Cloudflare connection failed"
        switch (step, error) {
        case (_, Failure.deviceCredentialRejected):
            source.yield(.blocked(.deviceCredentialRejected))
        case (_, Failure.accountInUse):
            source.yield(.blocked(.manualRecovery(message)))
        case (_, Failure.servicePaused): source.yield(.failed(message))
        case (let step?, Failure.http(let code)): source.yield(.failed("\(step) · HTTP \(code)"))
        default: source.yield(.failed(step.map { "\($0) · \(message)" } ?? message))
        }
        await disconnect()
    }
}

private extension CloudflareRealtimeSignalingClient {
    func startRenewing(_ request: WebRTCSignalingConnectRequest, generation: UUID) {
        renewalTask = Task { [weak self] in
            while !Task.isCancelled, let lease = await self?.currentLease {
                await self?.waitForRenewal(lease, generation: generation)
                guard !Task.isCancelled, await self?.renew(request, lease: lease, generation: generation) == true
                else { return }
            }
        }
    }

    func waitForRenewal(_ lease: Lease, generation: UUID) async {
        guard self.generation == generation, !Task.isCancelled, !needsEarlyRenewal else { return }
        // An authenticated peer can end the wait without interrupting a renewal already in flight.
        let delay = lease.nextRenewalDelay(through: callContinuationDeadline)
        let wait = Task { _ = try? await Task.sleep(for: .seconds(delay)) }
        renewalWait = wait
        await withTaskCancellationHandler {
            await wait.value
        } onCancel: {
            wait.cancel()
        }
        if self.generation == generation { renewalWait = nil }
    }

    struct WirePeer: Decodable { let id: String; let sessionId: String }
    struct WireEvent: Decodable {
        let type: String; let peers: [WirePeer]?; let from: String?; let namespace: String?; let payload: String?
    }

    func startSocket(_ request: WebRTCSignalingConnectRequest, id: String, generation: UUID) {
        socketTask = Task { [weak self] in
            var retry = 1
            while !Task.isCancelled {
                guard let self else { return }
                do { try await self.receiveSocket(request, id: id, generation: generation); return } catch {
                    guard !Task.isCancelled else { return }
                    if case Failure.deviceCredentialRejected = error {
                        guard let delay = await self.continuationRetryDelay(request, id: id, generation: generation)
                        else {
                            if !Task.isCancelled { await self.fail(error, generation: generation) }
                            return
                        }
                        // Only the Worker can confirm that the current media lease remains authorized.
                        try? await Task.sleep(for: .seconds(delay))
                        continue
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
                establishmentPeers.formIntersection(peers.map(\.id))
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
    func socketUpgrade(_ request: WebRTCSignalingConnectRequest, id: String) throws -> URLRequest {
        let endpoint = try endpoint(request, path: "sessions/\(id)/signal")
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else {
            throw Failure.invalidConfiguration
        }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        guard let url = components.url else { throw Failure.invalidConfiguration }
        var upgrade = URLRequest(url: url)
        let credential = request.replacingWorkerCredential(currentConfiguration()).cloudflare.accessToken
        upgrade.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        return upgrade
    }
}

extension CloudflareRealtimeSignalingClient {
    func observeAuthenticatedInternetPeer(
        _ peer: PeerID, callID: String, continuationDeadline: ContinuousClock.Instant
    ) {
        guard !Task.isCancelled, request?.call.sessionID == callID, sessionID != nil,
              peers.contains(where: { $0.id == peer })
        else { return }
        if callContinuationDeadline == nil {
            callContinuationDeadline = continuationDeadline
            if currentLease?.continuationOnly == true { renewalWait?.cancel() }
        }
        guard establishedAt == nil, currentLease?.continuationOnly != true else { return }
        guard establishmentPeers.insert(peer).inserted else { return }
        needsEarlyRenewal = true
        renewalWait?.cancel()
    }

    private func endpoint(_ request: WebRTCSignalingConnectRequest, path: String) throws -> URL {
        guard let credential = request.call.credential else { throw Failure.invalidConfiguration }
        return request.cloudflare.workerURL.appendingPathComponent("api/rooms/\(credential.groupHash)/\(path)")
    }
    private func http(
        _ connect: WebRTCSignalingConnectRequest, path: String, method: String = "POST",
        body: [String: Any]? = nil, totalTimeout: Duration = .seconds(25), establishmentPeers: Set<PeerID> = []
    ) async throws -> Data {
        try await Self.fetch(
            connect.cloudflare, url: try endpoint(connect, path: path), method: method,
            body: try body.map { try JSONSerialization.data(withJSONObject: $0) }, session: session,
            retryConnectionLoss: path.hasSuffix("/pull"), totalTimeout: totalTimeout,
            establishmentPeers: establishmentPeers)
    }
}
