import Foundation
import Network
import RTC
@_spi(Validation) import RTCNativeWebRTC
import XCTest

/// Test composition uses the shipped engine and permits host loopback candidates.
func makeAudioE2EWebRTCEngine(relayOnly: Bool = false, includeLoopback: Bool = true) -> WebRTCNativeEngine {
    WebRTCNativeEngine(iceServers: [], includeLoopback: includeLoopback, relayOnly: relayOnly)
}

/// Loopback-only Worker/SFU fixture. The production HTTP/WebSocket signaling
/// client negotiates two real DTLS/SCTP connections; only the service is replaced.
/// Audio is forwarded opaquely and never decoded or manufactured here.
actor AudioE2EWorker {
    private struct Participant {
        let peer: PeerDescriptor
        let sessionID: String
        let engine: WebRTCNativeEngine
        let task: Task<Void, Never>
        var published = false
    }
    private let listener: NWListener
    private let token: String
    private let room: String
    private let allowedPeers: Set<String>
    private let iceServer: WebRTCIceServer
    private let checksInternetRecovery: Bool
    private let checksCredentialRecovery: Bool
    private var participants: [String: Participant] = [:]
    private var sockets: [String: NWConnection] = [:]
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var forwarded: [String: Int] = [:]
    private var requests: [String: Int] = [:]
    private var continuation: (sessionID: String, expiresAt: Double)?
    private var dropsMedia = false
    private(set) var droppedMediaPackets = 0
    private var waitingParticipantReady = false
    private var pairStages: [String: Set<String>] = [:]
    private var readyForInternetOutage: Set<String> = []
    private var stillObservingInternetOutage: Set<String> = []
    private var holdsInternetSignaling: Bool
    private let leavesICEUnanswered: Bool
    private(set) var pendingICEPeers: Set<String> = []
    private var stopped = false
    private enum Failure: Error { case invalidRequest }
    private typealias HTTP = AudioE2EWorkerHTTP

    var listeningPort: UInt16? { listener.port?.rawValue }

    init(port: UInt16, run: String, room: String, checksInternetRecovery: Bool = false,
         holdsInternetSignaling: Bool = false, leavesICEUnanswered: Bool = false,
         checksCredentialRecovery: Bool = false,
         iceServer: WebRTCIceServer = .init(urls: ["stun:127.0.0.1:9"])) throws {
        let parameters = NWParameters.tcp
        let localPort = try XCTUnwrap(NWEndpoint.Port(rawValue: port))
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: localPort)
        listener = try NWListener(using: parameters)
        token = run; self.room = room
        allowedPeers = Set(["a", "b"].map { "e2e-\($0)-\(run.prefix(8))" })
        self.checksInternetRecovery = checksInternetRecovery
        self.checksCredentialRecovery = checksCredentialRecovery
        self.holdsInternetSignaling = holdsInternetSignaling
        self.leavesICEUnanswered = leavesICEUnanswered
        self.iceServer = iceServer
    }

    func start() async throws {
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error):
                    listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: DispatchQueue(label: "AudioE2E.Worker"))
        }
    }

    func stop() async {
        stopped = true; listener.cancel()
        for connection in connections.values { connection.cancel() }
        connections = [:]; sockets = [:]
        await closeParticipants()
    }

    private func closeParticipants() async {
        let old = participants; participants = [:]
        for participant in old.values { participant.task.cancel(); await participant.engine.close() }
    }

    func measurements() -> [String: Any] { ["forwardedPackets": forwarded, "requests": requests] }

    func setDropsMedia(_ enabled: Bool) { dropsMedia = enabled }

    func enableInternetSignaling() { holdsInternetSignaling = false }

    func markWaitingParticipantReady() { waitingParticipantReady = true }

    func expireCredential(for memberID: String) async throws {
        let participant = try XCTUnwrap(participants[memberID])
        XCTAssertTrue(participant.published)
        continuation = (participant.sessionID, (Date().timeIntervalSince1970 + 86_400) * 1000)
        // Refresh remote membership so the client pulls with its expired credential.
        await publishMembership()
    }

    private func accept(_ connection: NWConnection) async {
        guard !stopped else { connection.cancel(); return }
        connections[ObjectIdentifier(connection)] = connection
        connection.start(queue: DispatchQueue(label: "AudioE2E.Worker.HTTP"))
        do {
            let request = try await HTTP.readRequest(connection)
            let upgraded = try await handle(request, connection: connection)
            if upgraded {
                // Membership is server-driven. Drain client close/control frames;
                // group control and audio use the actual reliable/unreliable SCTP channels.
                while !(try await HTTP.receive(connection)).isEmpty {}
            }
        } catch {
            try? await HTTP.respond(connection, status: 400, body: ["error": "fixture request failed"])
        }
        connection.cancel(); connections[ObjectIdentifier(connection)] = nil
        sockets = sockets.filter { $0.value !== connection }
    }

    private static func wire(_ channels: [WebRTCDataChannel]) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(channels))
    }
    private func lease(_ id: String, answer: WebRTCSessionDescription? = nil) throws -> [String: Any] {
        var result: [String: Any] = ["sessionId": id, "expiresAt": (Date().timeIntervalSince1970 + 120) * 1000,
            "renewAfterSeconds": checksInternetRecovery ? 2 : 20]
        if let answer {
            result["sessionDescription"] = ["type": "answer", "sdp": answer.sdp]
            result["channels"] = try Self.wire([
                .init(id: 2, isPublisher: true), .init(id: 6, isPublisher: true, delivery: .reliable)
            ])
        }
        return result
    }
    private func forward(_ message: ApplicationDataMessage, from id: String) async {
        guard !stopped, participants[id] != nil else { return }
        // Relay audio is unreliable. Reliable group control can still reach the peer.
        if dropsMedia, message.delivery == .unreliable {
            droppedMediaPackets += 1
            return
        }
        for (destination, participant) in participants where destination != id && participant.published {
            await participant.engine.sendApplicationData(message, to: participant.peer.id)
            forwarded[id, default: 0] += 1
        }
    }
    private func publishMembership() async {
        let peers = participants.values.filter(\.published).map { ["id": $0.peer.id.rawValue,
            "displayName": $0.peer.displayName, "sessionId": $0.sessionID] }
        guard let data = try? JSONSerialization.data(withJSONObject: ["type": "peers", "peers": peers]),
              data.count < 65_536 else { return }
        var frame = Data([0x81])
        if data.count < 126 {
            frame.append(UInt8(data.count))
        } else {
            frame.append(contentsOf: [126, UInt8(data.count >> 8), UInt8(data.count & 255)])
        }
        frame.append(data)
        for connection in sockets.values { try? await HTTP.send(connection, bytes: frame) }
    }
}

private extension AudioE2EWorker {
    private func handle(_ request: HTTP.Request, connection: NWConnection) async throws -> Bool {
        guard request.path.hasPrefix("/api/rooms/\(room)/") else { throw Failure.invalidRequest }
        let path = String(request.path.dropFirst("/api/rooms/\(room)/".count))
        let parts = path.split(separator: "/").map(String.init)
        let operation = parts.first == "sessions" ? parts.dropFirst(2).first ?? "delete" : parts.first ?? ""
        let authorization = request.headers["authorization"]
        let replacement = "Bearer \(AudioE2ECredentialRecovery.replacementToken(run: token))"
        if checksCredentialRecovery && isRecoveringSignaling(request, path: path) {
            guard authorization == replacement else {
                if authorization == "Bearer \(AudioE2ECredentialRecovery.rejectedToken(run: token))" {
                    requests["credential-rejected", default: 0] += 1
                }
                try await HTTP.respond(connection, status: 401, body: ["error": "fixture credential rejected"])
                return false
            }
            requests["replacement-" + operation, default: 0] += 1
        }
        guard authorization == "Bearer \(token)" || (checksCredentialRecovery && authorization == replacement)
        else { throw Failure.invalidRequest }
        requests[operation, default: 0] += 1
        switch operation {
        case "test-waiting-participant":
            try await HTTP.respond(connection, body: ["ready": waitingParticipantReady])
        case "test-pair-stage":
            try await handlePairStage(request, connection: connection)
        case "test-internet-outage-ready", "test-internet-outage-observed":
            try await handleInternetOutage(request, operation: operation, connection: connection)
        case "ice", "join":
            try await handleSignaling(request, operation: operation, path: parts, connection: connection)
        default:
            return try await handleSession(request, operation: operation, path: parts, connection: connection)
        }
        return false
    }

    private func isRecoveringSignaling(_ request: HTTP.Request, path: String) -> Bool {
        let recoveringPeer = "e2e-a-\(token.prefix(8))"
        return request.method == "POST" && (path == "ice/" + recoveringPeer
            || (path == "join" && request.body["participantId"] as? String == recoveringPeer))
    }

    private func handlePairStage(_ request: HTTP.Request, connection: NWConnection) async throws {
        guard request.method == "POST", let id = request.body["participantId"] as? String,
              allowedPeers.contains(id), let stage = request.body["stage"] as? String,
              (1...80).contains(stage.count)
        else { throw Failure.invalidRequest }
        pairStages[stage, default: []].insert(id)
        try await HTTP.respond(connection, body: ["ready": pairStages[stage] == allowedPeers])
    }

    private func handleInternetOutage(
        _ request: HTTP.Request, operation: String, connection: NWConnection
    ) async throws {
        guard checksInternetRecovery, let id = request.body["participantId"] as? String,
              allowedPeers.contains(id) else { throw Failure.invalidRequest }
        if operation == "test-internet-outage-ready" {
            if readyForInternetOutage.insert(id).inserted, readyForInternetOutage == allowedPeers {
                stillObservingInternetOutage = allowedPeers
                for socket in sockets.values { socket.cancel() }
                sockets = [:]
                await closeParticipants()
            }
        } else {
            stillObservingInternetOutage.remove(id)
        }
        try await HTTP.respond(connection, body: [:])
    }

    private func handleSignaling(
        _ request: HTTP.Request, operation: String, path: [String], connection: NWConnection
    ) async throws {
        if leavesICEUnanswered, operation == "ice", request.method == "POST" {
            guard let peer = path.dropFirst().first, allowedPeers.contains(peer),
                  pendingICEPeers.insert(peer).inserted else { throw Failure.invalidRequest }
            defer { pendingICEPeers.remove(peer) }
            // Read until the client closes or the fixture stops, without writing an HTTP response.
            while let data = try? await HTTP.receive(connection), !data.isEmpty {}
        } else if holdsInternetSignaling || !stillObservingInternetOutage.isEmpty {
            try await HTTP.respond(connection, status: 503, body: ["error": "fixture unavailable"])
        } else if operation == "ice" {
            var server: [String: Any] = ["urls": iceServer.urls]
            server["username"] = iceServer.username
            server["credential"] = iceServer.credential
            try await HTTP.respond(connection, body: ["iceServers": [server]])
        } else {
            try await join(request, connection: connection)
        }
    }

    private func join(_ request: HTTP.Request, connection: NWConnection) async throws {
        guard let id = request.body["participantId"] as? String, allowedPeers.contains(id),
              let offer = request.body["offer"] as? [String: String], let sdp = offer["sdp"] else {
            throw Failure.invalidRequest
        }
        if let old = participants.removeValue(forKey: id) { old.task.cancel(); await old.engine.close() }
        let displayName = request.body["displayName"] as? String ?? id
        let peer = PeerDescriptor(id: .init(rawValue: id), displayName: displayName)
        let engine = makeAudioE2EWebRTCEngine(), events = engine.events
        let task = Task { [weak self] in
            for await event in events {
                if Task.isCancelled { return }
                if case .receivedApplicationData(let data) = event { await self?.forward(data.message, from: id) }
            }
        }
        let sessionID = UUID().uuidString
        participants[id] = Participant(peer: peer, sessionID: sessionID, engine: engine, task: task)
        await engine.createPeerConnection(for: peer)
        await engine.configureDataChannels([
            .init(id: 2, peerID: peer.id),
            .init(id: 4, isPublisher: true),
            .init(id: 6, peerID: peer.id, delivery: .reliable),
            .init(id: 8, isPublisher: true, delivery: .reliable)
        ], for: peer.id)
        guard let answer = await engine.acceptOffer(.init(kind: .offer, sdp: sdp), from: peer.id) else {
            throw Failure.invalidRequest
        }
        try await HTTP.respond(connection, body: lease(sessionID, answer: answer))
    }

    private func handleSession(
        _ request: HTTP.Request, operation: String, path: [String], connection: NWConnection
    ) async throws -> Bool {
        guard path.count >= 2 else { throw Failure.invalidRequest }
        guard let participant = participants.values.first(where: { $0.sessionID == path[1] }) else {
            try await HTTP.respond(connection, status: 404, body: ["error": "Session not found"])
            return false
        }
        let id = participant.peer.id.rawValue
        switch operation {
        case "publish":
            participants[id]?.published = true
            try await HTTP.respond(connection, body: ["channels": []])
            await publishMembership()
        case "pull":
            if participant.sessionID == continuation?.sessionID {
                requests["expired-credential-pull", default: 0] += 1
                try await HTTP.respond(connection, status: 401, body: ["error": "fixture credential expired"])
                return false
            }
            let others = participants.values.filter { $0.published && $0.peer.id != participant.peer.id }
            let channels = others.flatMap { [WebRTCDataChannel(id: 4, peerID: $0.peer.id),
                .init(id: 8, peerID: $0.peer.id, delivery: .reliable)] }
            try await HTTP.respond(connection, body: ["channels": try Self.wire(channels)])
        case "renew":
            try await HTTP.respond(connection, body: renew(participant))
        case "signal":
            try await HTTP.upgradeToWebSocket(request, connection: connection)
            sockets[id]?.cancel(); sockets[id] = connection
            await publishMembership()
            return true
        case "delete":
            guard request.method == "DELETE" else { throw Failure.invalidRequest }
            participants[id] = nil; sockets.removeValue(forKey: id)?.cancel()
            participant.task.cancel(); await participant.engine.close()
            try await HTTP.respond(connection, body: [:]); await publishMembership()
        default: throw Failure.invalidRequest
        }
        return false
    }

    private func renew(_ participant: Participant) throws -> [String: Any] {
        var body = try lease(participant.sessionID)
        if let continuation, participant.sessionID == continuation.sessionID {
            body["continuationOnly"] = true
            body["expiresAt"] = continuation.expiresAt
            if requests["expired-credential-pull", default: 0] > 0 {
                requests["continued-renewal", default: 0] += 1
            }
        }
        return body
    }
}
