import CryptoKit
import Foundation
import Network

/// Audio-device-only duplex flow. One serial queue owns listener, active flow,
/// handshake and cipher history. Group datagrams have a separate transport.
final class AudioDeviceDuplexFlow: @unchecked Sendable {
    private let queue = DispatchQueue(label: "rtc.audio-device.duplex", qos: .userInteractive)
    private let key = DispatchSpecificKey<Bool>()
    private let role: RTCAudioDeviceRole
    private let prefix: String
    private var cipher: AudioDeviceCipher?
    private let onReceive: @Sendable (RTCAudioPacket) -> Void
    private let onEndpointChange: @Sendable (RTCAudioDeviceEndpoint?) -> Void
    private let onAvailability: @Sendable (Bool) -> Void
    private let onFailure: @Sendable (String) -> Void
    private var listener: NWListener?
    private var generation = UUID()
    private(set) var outgoing: NWConnection?
    private(set) var active: NWConnection?
    private var candidates: [UUID: NWConnection] = [:]
    private var inFlight = 0
    private var sent: UInt64 = 0, received: UInt64 = 0
    private var stopped = false
    private var dialEndpoint: NWEndpoint?
    private var retryGeneration = UUID()
    private var retryCount = 0
    private var recoveryAttempts = 0
    private var recoveryScheduled = false
    private(set) var endpoint: RTCAudioDeviceEndpoint?
    private(set) var ready = false
    private(set) var lastReceivedAt: TimeInterval?

    init(sessionID: UUID, key: Data, role: RTCAudioDeviceRole,
         onReceive: @escaping @Sendable (RTCAudioPacket) -> Void,
         onEndpointChange: @escaping @Sendable (RTCAudioDeviceEndpoint?) -> Void,
         onAvailability: @escaping @Sendable (Bool) -> Void,
         onFailure: @escaping @Sendable (String) -> Void) throws {
        self.role = role
        prefix = Self.digest(sessionID.uuidString, length: 12)
        cipher = try AudioDeviceCipher(sessionID: sessionID, key: key, role: role)
        self.onReceive = onReceive; self.onEndpointChange = onEndpointChange
        self.onAvailability = onAvailability; self.onFailure = onFailure
        queue.setSpecific(key: self.key, value: true)
    }
    func synchronized<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: key) == true { return try body() }
        return try queue.sync(execute: body)
    }
    private static func digest(_ value: String, length: Int) -> String {
        String(SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined().prefix(length))
    }
    private func baseName(_ role: RTCAudioDeviceRole) -> String {
        prefix + "-" + Self.digest(role.rawValue, length: 20)
    }
    private func valid(_ endpoint: RTCAudioDeviceEndpoint) -> Bool {
        let prefix = baseName(role.opposite) + "-"
        return endpoint.type == LocalDatagramTransport.serviceType && endpoint.domain == "local."
            && endpoint.name.hasPrefix(prefix) && endpoint.name.utf8.count == prefix.utf8.count + 12
            && endpoint.name.dropFirst(prefix.count).allSatisfy(\.isHexDigit)
    }
    func start() throws {
        try synchronized {
            guard !stopped else { throw RTCAudioDeviceLinkError.stopped }
            guard listener == nil else { return }
            let listener = try NWListener(using: LocalDatagramTransport.parameters())
            let token = generation
            listener.service = .init(name: baseName(role) + "-" + Self.digest(UUID().uuidString, length: 12),
                                     type: LocalDatagramTransport.serviceType)
            listener.serviceRegistrationUpdateHandler = { [weak self] change in
                guard let self, self.generation == token, !self.stopped else { return }
                switch change {
                case .add(let value):
                    if case .service(let name, let type, let domain, _) = value {
                        self.endpoint = .init(name: name, type: type, domain: domain)
                        self.onEndpointChange(self.endpoint)
                    }
                case .remove: self.endpoint = nil; self.onEndpointChange(nil)
                @unknown default: break
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                guard let self, self.generation == token, !self.stopped else { return }
                if case .failed(let error) = state { self.onFailure("Local UDP listener unavailable: \(error)") }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self, self.generation == token, !self.stopped, self.candidates.count < 8 else {
                    connection.cancel(); return
                }
                self.acceptIncoming(connection, token: token)
            }
            self.listener = listener
            listener.start(queue: queue)
        }
    }
    func connect(to endpoint: RTCAudioDeviceEndpoint) -> Bool {
        synchronized {
            guard !stopped, valid(endpoint) else { return false }
            let target: NWEndpoint = .service(
                name: endpoint.name, type: endpoint.type, domain: endpoint.domain, interface: nil)
            if role == .controller, active != nil, active !== outgoing { return true }
            dialEndpoint = target
            if outgoing == nil { dial(target) }
            return true
        }
    }
    private func dial(_ endpoint: NWEndpoint) {
        guard !stopped else { return }
        recoveryScheduled = false
        retryGeneration = UUID()
        let connection = NWConnection(to: endpoint, using: LocalDatagramTransport.parameters())
        outgoing = connection
        let token = generation
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.generation == token, self.outgoing === connection else { return }
            switch state {
            case .ready:
                self.retryCount = 0
                self.retryGeneration = UUID()
                self.sendHello(connection, token: token, retryToken: self.retryGeneration)
                self.receive(connection, id: nil, token: token)
            case .failed, .cancelled:
                self.remove(connection, id: nil)
                self.recover(token: token)
            default: break
            }
        }
        connection.betterPathUpdateHandler = { [weak self, weak connection] better in
            guard better, let self, let connection, self.generation == token, self.outgoing === connection else {
                return
            }
            self.replaceOutgoing(connection, token: token)
        }
        connection.viabilityUpdateHandler = { [weak self, weak connection] viable in
            guard !viable, let self, let connection, self.generation == token, self.outgoing === connection else {
                return
            }
            if self.active === connection { self.setReady(false) }
            self.replaceOutgoing(connection, token: token)
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
            guard let self, let connection, self.generation == token, !self.stopped,
                  self.outgoing === connection, self.active !== connection else { return }
            self.remove(connection, id: nil)
            if self.active == nil {
                self.onFailure("Audio device connection timed out")
            } else {
                self.dialEndpoint = nil
            }
        }
    }
    private func replaceOutgoing(_ connection: NWConnection, token: UUID) {
        guard generation == token, outgoing === connection, let endpoint = dialEndpoint else { return }
        // The authenticated old flow remains usable until the replacement has
        // authenticated; stale callbacks cannot own the new outgoing slot.
        outgoing = nil
        retryGeneration = UUID()
        if active !== connection { connection.cancel() }
        dial(endpoint)
    }
    private func recover(token: UUID) {
        guard generation == token, !stopped, !recoveryScheduled, let endpoint = dialEndpoint else { return }
        guard recoveryAttempts < 5 else {
            if active == nil { onFailure("Audio device recovery exhausted") } else { dialEndpoint = nil }
            return
        }
        recoveryAttempts += 1
        recoveryScheduled = true
        let recoveryToken = retryGeneration
        queue.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.generation == token, self.retryGeneration == recoveryToken, !self.stopped else {
                return
            }
            self.recoveryScheduled = false
            guard self.outgoing == nil else { return }
            self.dial(endpoint)
        }
    }
    private func sendHello(_ connection: NWConnection, token: UUID, retryToken: UUID) {
        guard generation == token, retryGeneration == retryToken, outgoing === connection, active !== connection
        else { return }
        guard retryCount < 10 else {
            remove(connection, id: nil)
            if active == nil { onFailure("Audio device handshake timed out") } else { dialEndpoint = nil }
            return
        }
        guard let bytes = try? cipher?.sealControl(.hello) else { return }
        retryCount += 1
        connection.send(content: bytes, completion: .contentProcessed { _ in })
        queue.asyncAfter(deadline: .now() + 0.4) { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.sendHello(connection, token: token, retryToken: retryToken)
        }
    }
    private func setReady(_ value: Bool) {
        guard ready != value else { return }
        ready = value; onAvailability(value)
    }
    private func remove(_ connection: NWConnection, id: UUID?) {
        if let id { candidates[id] = nil }
        if outgoing === connection { outgoing = nil; retryGeneration = UUID() }
        if active === connection { active = nil; inFlight = 0; setReady(false) }
        connection.cancel()
    }
    func send(_ packet: RTCAudioPacket) -> Bool {
        let requested = ProcessInfo.processInfo.systemUptime
        return synchronized {
            guard !stopped, ready, let connection = active,
                  ProcessInfo.processInfo.systemUptime - requested < 0.1,
                  let bytes = try? cipher?.seal(packet), inFlight + bytes.count <= 65_536 else { return false }
            inFlight += bytes.count
            let token = generation
            connection.send(content: bytes, completion: .contentProcessed { [weak self, weak connection] error in
                guard let self, let connection, self.generation == token, self.active === connection else { return }
                self.inFlight = max(0, self.inFlight - bytes.count)
                    if error != nil {
                        self.remove(connection, id: self.candidates.first { $0.value === connection }?.key)
                        self.recover(token: token)
                    }
            })
            sent += 1
            return true
        }
    }
    var statistics: RTCNetworkStatistics {
        synchronized {
            var result = RTCNetworkStatistics(
                bufferedBytes: UInt64(inFlight),
                unavailableReason: "UDP media has no acknowledgement-based RTT or loss estimate")
            result.sentMediaDatagrams = sent; result.receivedMediaDatagrams = received
            return result
        }
    }
    func stop() {
        synchronized {
            guard !stopped else { return }
            stopped = true; generation = UUID(); retryGeneration = UUID(); cipher = nil
            listener?.cancel(); listener = nil; outgoing?.cancel(); outgoing = nil
            active?.cancel()
            for connection in candidates.values { connection.cancel() }
            candidates.removeAll(); active = nil; endpoint = nil; dialEndpoint = nil
            lastReceivedAt = nil; inFlight = 0; sent = 0; received = 0; setReady(false)
        }
    }
}

private extension AudioDeviceDuplexFlow {
    func acceptIncoming(_ connection: NWConnection, token: UUID) {
        let id = UUID()
        candidates[id] = connection
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection, self.generation == token else { return }
            if case .failed = state { self.remove(connection, id: id) }
            if case .cancelled = state { self.remove(connection, id: id) }
        }
        connection.start(queue: self.queue)
        self.receive(connection, id: id, token: token)
        self.queue.asyncAfter(deadline: .now() + 5) { [weak self, weak connection] in
            guard let self, let connection, self.generation == token,
                  self.candidates[id] === connection, self.active !== connection else { return }
            self.candidates[id] = nil; connection.cancel()
        }
    }

    func receive(_ connection: NWConnection, id: UUID?, token: UUID) {
        connection.receiveMessage { [weak self, weak connection] bytes, _, _, error in
            guard let self, let connection, self.generation == token, !self.stopped,
                  self.outgoing === connection || self.active === connection
                    || (id.flatMap { self.candidates[$0] } === connection) else { return }
            if let bytes, let message = self.cipher?.openMessage(bytes, accepting: {
                self.accepts($0, from: connection, candidateID: id)
            }) {
                self.handle(message, from: connection, candidateID: id)
            }
            guard !self.stopped, self.generation == token else { return }
            if error == nil {
                self.receive(connection, id: id, token: token)
            } else {
                self.remove(connection, id: id); if id == nil { self.recover(token: token) }
            }
        }
    }

    func accepts(_ message: AudioDeviceCipher.Message, from connection: NWConnection, candidateID: UUID?) -> Bool {
        switch message {
        case .hello:
            return candidateID != nil && !(role == .device && dialEndpoint != nil && active !== connection)
        case .ack:
            return outgoing === connection && !(role == .controller && active != nil && active !== connection)
        case .audio:
            return active === connection && ready
        }
    }

    func handle(_ message: AudioDeviceCipher.Message, from connection: NWConnection, candidateID: UUID?) {
        switch message {
        case .hello:
            guard candidateID != nil else { return }
            if role == .controller, let losing = outgoing, losing !== connection {
                outgoing = nil; dialEndpoint = nil; retryGeneration = UUID()
                recoveryScheduled = false; losing.cancel()
            }
            if active !== connection {
                active?.cancel(); active = connection; inFlight = 0
            }
            if let ack = try? cipher?.sealControl(.ack) {
                connection.send(content: ack, completion: .contentProcessed { _ in })
            }
            setReady(true)
        case .ack:
            guard outgoing === connection else { return }
            if active !== connection { active?.cancel(); inFlight = 0 }
            active = connection; recoveryAttempts = 0; setReady(true)
        case .audio(let packet):
            guard active === connection || (outgoing === connection && ready) else { return }
            received += 1; lastReceivedAt = ProcessInfo.processInfo.systemUptime
            onReceive(packet)
        }
    }
}
