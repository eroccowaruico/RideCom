import Foundation

/// Keeps usable links alive. Automatic routing adds a second path; it never
/// disconnects one group of members merely because another path became ready.
public actor RouteManager: CallSession {
    nonisolated public var events: AsyncStream<CallSessionEvent> { eventSource.stream }
    private let eventSource = EventSource<CallSessionEvent>(
        isTransient: { $0.isTransient }, overflowEvent: .stateChanged(.failed))
    let routes: [RouteKind: RTCCallRoute]
    private(set) var configuration: CallRouteConfiguration
    let runtimeStatusPolicy: RTCRuntimeStatusPolicy
    private(set) var generation = UUID()
    private(set) var request: CallStartRequest?
    private var routeTasks: [Task<Void, Never>] = []
    private var timer: Task<Void, Never>?
    private(set) var maintenanceDeadline: TimeInterval?
    private var isConnectionStarted = false
    private var fallbackTask: Task<Void, Never>?
    private(set) var routeStates: [RouteKind: RouteConnectionState] = [:]
    private(set) var routeAvailabilities: [RouteKind: RouteAvailability] = [:]
    private(set) var routeMembers: [RouteKind: Set<PeerID>] = [:]
    private(set) var started: Set<RouteKind> = []
    private var blocked: Set<RouteKind> = []
    private(set) var retries: [RouteKind: ConnectionRetry] = [:]
    private(set) var activeRoute: RouteKind?
    private(set) var availableRoutes: Set<RouteKind> = []
    private(set) var connectionState: CallConnectionState = .idle
    private(set) var isMediaStarted = false
    private(set) var localMute = false
    private(set) var outputMute = false
    private(set) var relay: GroupRelay?
    private var receiveBuffer = PacketAudioReceiveBuffer()
    private var memberSnapshot: [CallMemberState] = []
    private(set) var observedPaths: [PeerID: RTCObservedPeerPath] = [:]
    private(set) var outboundAudioDispatch: RTCOutboundAudioDispatch?
    private var memberRoutes: [PeerID: RouteKind] = [:]
    private var lastPresence: TimeInterval = 0
    private var lastRuntimeStatus: TimeInterval = 0
    var eventDropReport: RTCEventDropReport { eventSource.report }
    private(set) var runtimePackageReports: [RTCRuntimePackageReport] = []

    public init(routes: [RTCCallRoute], configuration: CallRouteConfiguration = .init(),
                runtimeStatusPolicy: RTCRuntimeStatusPolicy = .init()) {
        self.routes = Dictionary(routes.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        self.configuration = configuration.normalized()
        self.runtimeStatusPolicy = runtimeStatusPolicy
    }
    deinit { routeTasks.forEach { $0.cancel() }; timer?.cancel(); fallbackTask?.cancel() }

    public func prepare(_ request: CallStartRequest) async {
        if self.request != nil { await stopConnection() }
        generation = UUID()
        let token = generation
        self.request = request
        configuration = request.configuration.normalized()
        relay = GroupRelay(request: request)
        observedPaths = [:]; lastPresence = 0; lastRuntimeStatus = 0; eventSource.resetDiagnostics()
        outboundAudioDispatch = nil
        receiveBuffer.reset(); memberSnapshot = []; memberRoutes = [:]; routeMembers = [:]
        routeStates = [:]; routeAvailabilities = [:]; started = []; retries = [:]; blocked = []
        availableRoutes = []; activeRoute = nil; isMediaStarted = false
        emitState(.preparing)
        let enabled = configuration.enabledRoutes.compactMap { routes[$0] }
        guard !enabled.isEmpty else { emit(.error(.noEnabledRoute)); emitState(.failed); return }
        routeTasks = enabled.map { route in
            let events = route.events
            return Task { [weak self] in
                for await event in events {
                    guard !Task.isCancelled else { return }
                    await self?.handle(event, generation: token)
                }
            }
        }
        for route in enabled {
            await route.prepare(request)
            guard generation == token else { return }
        }
        emitRouteSnapshot()
    }
    public func startConnection() async {
        guard request != nil, !isConnectionStarted else { return }
        isConnectionStarted = true
        let token = generation
        emitState(.connecting)
        await start(configuration.preferredRoute)
        guard generation == token else { return }
        if configuration.selectionMode != .singleRoute {
            let delay = max(0, configuration.fallbackDelay)
            fallbackTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                await self?.startRemaining(generation: token)
            }
        }
        lastPresence = ProcessInfo.processInfo.systemUptime
        lastRuntimeStatus = lastPresence
        await broadcast(.presence)
        await sendRuntimeStatus(reason: .connectionStarted)
        if generation == token { scheduleMaintenance() }
    }
    private func start(_ kind: RouteKind) async {
        guard configuration.enabledRoutes.contains(kind), let route = routes[kind], !started.contains(kind),
            !blocked.contains(kind)
        else { return }
        started.insert(kind); routeStates[kind] = .connecting
        await route.startConnection()
    }
    private func startRemaining(generation token: UUID) async {
        guard generation == token, request != nil else { return }
        for kind in configuration.enabledRoutes.sorted(by: { $0.rawValue < $1.rawValue }) {
            await start(kind)
            guard generation == token else { return }
        }
    }
    public func stopConnection() async {
        await broadcast(.leave)
        generation = UUID()
        let token = generation
        timer?.cancel(); timer = nil; maintenanceDeadline = nil; fallbackTask?.cancel(); fallbackTask = nil
        isConnectionStarted = false
        routeTasks.forEach { $0.cancel() }; routeTasks = []
        observedPaths = [:]; lastPresence = 0; lastRuntimeStatus = 0; eventSource.resetDiagnostics()
        outboundAudioDispatch = nil
        request = nil; relay = nil; started = []; retries = [:]; blocked = []; availableRoutes = []
        activeRoute = nil; isMediaStarted = false; receiveBuffer.reset()
        memberSnapshot = []; memberRoutes = [:]; routeMembers = [:]
        for route in routes.values {
            await route.stopConnection()
            guard generation == token else { return }
        }
        emit(.membersChanged([])); emitRouteSnapshot(); emitState(.disconnected)
    }
    public func startMedia() async {
        guard request != nil else { return }
        isMediaStarted = true
        await sendRuntimeStatus(reason: .mediaStarted)
        updateState()
    }
    public func stopMedia() async {
        isMediaStarted = false; receiveBuffer.reset()
        // Relay remains active while this device changes its microphone/output.
        await sendRuntimeStatus(reason: .mediaStopped)
        updateState()
    }
    public func sendAudioPacket(_ packet: RTCAudioPacket) async {
        guard isMediaStarted, !localMute, packet.payload.count <= 8192 else { return }
        if case .admittedMemberships(let admitted) = request?.audioPolicy.peerPolicy {
            let now = ProcessInfo.processInfo.systemUptime
            guard admitted.contains(where: { relay?.membershipID(for: $0.key, now: now) == $0.value }) else { return }
        }
        await broadcast(.audio(packet), recordsOutboundAudio: true)
    }
    public func sendApplicationData(_ message: ApplicationDataMessage) async {
        guard message.namespace != GroupRelay.namespace, message.payload.count <= 12000 else { return }
        await broadcast(.application(message))
    }
    public func setLocalMute(_ muted: Bool) async {
        localMute = muted
        await sendRuntimeStatus(reason: .localControlsChanged)
    }
    public func setOutputMute(_ muted: Bool) async {
        outputMute = muted
        await sendRuntimeStatus(reason: .localControlsChanged)
    }
    public func updateRuntimePackageReports(_ reports: [RTCRuntimePackageReport]) async {
        runtimePackageReports = reports.sorted { ($0.package, $0.kind) < ($1.package, $1.kind) }
        // Local meters may refresh much faster than network diagnostics. Keep
        // only the latest snapshot for the next periodic/status event. Explicit
        // event-only users (no periodic interval) still publish on this call.
        if runtimeStatusPolicy.periodicInterval == nil { await sendRuntimeStatus(reason: .packageReportsChanged) }
    }
    public func updateAudioPolicy(_ policy: RTCAudioPolicy) async {
        guard request != nil else { return }
        request?.audioPolicy = policy
        relay?.updateAudioPolicy(policy)
        let now = ProcessInfo.processInfo.systemUptime
        for member in memberSnapshot where !allowsAudio(from: member.peer.id, now: now) {
            receiveBuffer.removePeer(member.peer.id)
        }
        await sendRuntimeStatus(reason: .localControlsChanged)
    }
    private func broadcast(_ body: RelayBody, recordsOutboundAudio: Bool = false) async {
        guard let data = try? relay?.make(body, now: ProcessInfo.processInfo.systemUptime), data.count <= 32768
        else { return }
        await forward(data, body: body, recordsOutboundAudio: recordsOutboundAudio)
    }
    private func forward(_ data: Data, body: RelayBody, excluding: RouteKind? = nil, path: [PeerID] = [],
                         recordsOutboundAudio: Bool = false) async {
        let token = generation
        let message = ApplicationDataMessage(namespace: GroupRelay.namespace, payload: data, delivery: body.delivery)
        var localRecipients: Set<PeerID> = []
        var offeredRoutes: [RouteKind] = []
        var transportAcceptance: [RouteKind: Bool] = [:]
        var internetCoveredByLocal = false
        // Local always gets the first immediate attempt. A control connection
        // alone is insufficient: Local must report recent media receipt as well
        // as immediate acceptance on the flow that actually sends this frame.
        for kind in [RouteKind.multipeer, .webRTC] where started.contains(kind) && kind != excluding {
            guard !blocked.contains(kind), let route = routes[kind] else { continue }
            if case .audio = body, kind == .multipeer, !path.isEmpty,
               routeMembers[kind, default: []].isSubset(of: path) { continue }
            if case .audio = body, kind == .webRTC,
               let internetPeers = routeMembers[kind], !internetPeers.isEmpty {
                if internetPeers.isSubset(of: path) { continue }
                if internetPeers.isSubset(of: localRecipients) {
                    internetCoveredByLocal = true
                    continue
                }
            }
            let send = await route.sendApplicationData(message)
            guard generation == token else { return }
            if recordsOutboundAudio {
                offeredRoutes.append(kind)
                transportAcceptance[kind] = send.transportAccepted
            }
            if kind == .multipeer { localRecipients = send.verifiedLocalRecipients }
        }
        if recordsOutboundAudio, !offeredRoutes.isEmpty {
            outboundAudioDispatch = .init(offeredRoutes: offeredRoutes, internetCoveredByLocal: internetCoveredByLocal,
                                          observedAt: Date().timeIntervalSince1970,
                                          transportAcceptance: transportAcceptance.isEmpty ? nil : transportAcceptance)
        }
    }
    private func deliverAudio(now: TimeInterval) {
        for packet in receiveBuffer.drain(now: now).readyPackets
            where isMediaStarted && allowsAudio(from: packet.peerID, now: now) {
            emit(.receivedAudioPacket(packet))
        }
    }
    private func updateMembers() {
        let now = ProcessInfo.processInfo.systemUptime
        let next = (relay?.members(now: now) ?? []).map {
            CallMemberState(peer: $0, route: memberRoutes[$0.id], isConnected: true,
                            membershipID: relay?.membershipID(for: $0.id, now: now))
        }
        guard next != memberSnapshot else { return }
        let departed = Set(memberSnapshot.map { $0.peer.id }).subtracting(next.map { $0.peer.id })
        for peer in departed { receiveBuffer.removePeer(peer); memberRoutes[peer] = nil; observedPaths[peer] = nil }
        memberSnapshot = next
        emit(.membersChanged(next)); updateState()
    }
    private func updateState(routeStateDidChange: Bool = false) {
        let live = availableRoutes.intersection(started)
        activeRoute =
            live.contains(configuration.preferredRoute)
            ? configuration.preferredRoute : live.sorted { $0.rawValue < $1.rawValue }.first
        // A started route still on its first attempt (Local searching alone, say) is a normal wait,
        // so another route's retry does not make the call reconnecting.
        let searching = started.subtracting(blocked).contains { routeStates[$0] == .connecting && retries[$0] == nil }
        let state: CallConnectionState =
            live.isEmpty && configuration.enabledRoutes.isSubset(of: blocked)
            ? .failed
            : !memberSnapshot.isEmpty
                ? (isMediaStarted ? .mediaReady : .connected)
                : (live.isEmpty && !retries.isEmpty && !searching ? .reconnecting : .connecting)
        let recoveryChanged = (connectionState == .reconnecting) != (state == .reconnecting)
        if connectionState != state { emitState(state) }
        if routeStateDidChange || recoveryChanged { emitRouteSnapshot() }
    }
    private func emitState(_ state: CallConnectionState) {
        connectionState = state
        emit(.stateChanged(state))
    }

    func emit(_ event: CallSessionEvent) { eventSource.yield(event) }
}

private extension RouteManager {
    func handle(_ event: RouteEvent, generation token: UUID) async {
        guard generation == token, request != nil else { return }
        defer { if generation == token { scheduleMaintenance() } }
        switch event {
        case .stateChanged(let kind, let state):
            await handleStateChange(state, for: kind)
        case .availabilityChanged(let availability):
            routeAvailabilities[availability.route] = availability
            emit(.routeAvailabilityChanged([availability]))
        case .membersChanged(let kind, let members):
            guard !blocked.contains(kind) else { return }
            routeMembers[kind] = Set(members.filter(\.isConnected).map { $0.peer.id })
            await broadcast(.presence)
        case .receivedApplicationData(let kind, let data):
            await handleApplicationData(data, from: kind)
        case .metricsChanged(let metrics): emit(.metricsChanged(metrics))
        case .connectionBlocked(let kind, let message):
            blocked.insert(kind); retries[kind] = nil
            emit(.error(.connectionBlocked(kind, message)))
            await handleStateChange(.failed, for: kind)
        case .error(_, let error): emit(.error(error))
        }
    }

    func handleStateChange(_ state: RouteConnectionState, for kind: RouteKind) async {
        guard !blocked.contains(kind) || state == .failed else { return }
        let previous = routeStates.updateValue(state, forKey: kind)
        if kind == .webRTC { relay?.internetReady = state == .mediaReady }
        if [.connected, .authenticated, .mediaReady].contains(state) {
            let becameAvailable = availableRoutes.insert(kind).inserted
            retries[kind] = nil
            // Member events already announce newly authenticated links, including same-ID replacements.
            if becameAvailable || previous != state { await broadcast(.presence) }
        } else if state == .failed || state == .disconnected {
            availableRoutes.remove(kind); routeMembers[kind] = []
            // Several state events can report the same outage while a retry is already scheduled.
            if started.contains(kind), !blocked.contains(kind), retries[kind]?.deadline.isFinite != true {
                retries[kind] = ConnectionRetry(after: retries[kind],
                    at: ProcessInfo.processInfo.systemUptime, policy: .connectionRecovery)
            }
        }
        updateState(routeStateDidChange: true)
    }

    func handleApplicationData(_ data: ReceivedApplicationData, from kind: RouteKind) async {
        guard started.contains(kind), !blocked.contains(kind), routeMembers[kind, default: []].contains(data.peerID),
              data.message.namespace == GroupRelay.namespace,
            let result = relay?.receive(
                data.message.payload, from: data.peerID, now: ProcessInfo.processInfo.systemUptime)
        else { return }
        if result.didRestart {
            receiveBuffer.removePeer(result.peer.id)
            memberSnapshot.removeAll { $0.peer.id == result.peer.id }
            emit(.membersChanged(memberSnapshot))
        }
        observedPaths[result.peer.id] = .init(
            peerID: result.peer.id, route: kind, path: result.path, observedAt: Date().timeIntervalSince1970)
        memberRoutes[result.peer.id] = kind
        updateMembers()
        switch result.body {
        case .audio(let packet):
            let now = ProcessInfo.processInfo.systemUptime
            if isMediaStarted, allowsAudio(from: result.peer.id, now: now) {
                receiveBuffer.enqueue(
                    .init(received: .init(peerID: result.peer.id, packet: packet)), receivedAt: now)
                deliverAudio(now: now)
            }
        case .application(let message):
            emit(.receivedApplicationData(.init(peerID: result.peer.id, message: message)))
        case .presence, .leave: break
        }
        guard let bytes = result.forward else { return }
        let excluded = forwardingExclusion(from: kind, body: result.body, sender: result.peer.id)
        await forward(bytes, body: result.body, excluding: excluded, path: result.path)
    }
    /// Healthy packets leave in handle(). Wake only for an unresolved reorder
    /// gap, presence expiry, retry, or explicitly enabled diagnostics.
    func scheduleMaintenance() {
        guard isConnectionStarted else { return }
        if configuration.enabledRoutes.isSubset(of: blocked) {
            timer?.cancel(); timer = nil; maintenanceDeadline = nil
            return
        }
        var deadline = lastPresence + 2
        if let gap = receiveBuffer.nextDeadline { deadline = min(deadline, gap) }
        if let retry = retries.values.map(\.deadline).min() { deadline = min(deadline, retry) }
        if runtimeStatusPolicy.isAutomaticBroadcastEnabled, let interval = runtimeStatusPolicy.periodicInterval {
            deadline = min(deadline, lastRuntimeStatus + max(0.02, interval))
        }
        // Do not allocate/cancel a Task on every arriving audio packet.
        if let scheduled = maintenanceDeadline, scheduled <= deadline { return }
        timer?.cancel()
        maintenanceDeadline = deadline
        let token = generation
        let delay = max(0, deadline - ProcessInfo.processInfo.systemUptime)
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.tick(generation: token, deadline: deadline)
        }
    }

    func tick(generation token: UUID, deadline: TimeInterval) async {
        guard generation == token, maintenanceDeadline == deadline else { return }
        timer = nil; maintenanceDeadline = nil
        defer { if generation == token { scheduleMaintenance() } }
        guard generation == token, let request else { return }
        let now = ProcessInfo.processInfo.systemUptime
        deliverAudio(now: now)
        if now - lastPresence >= 2 {
            lastPresence = now
            await broadcast(.presence)
            guard generation == token else { return }
            updateMembers()
        }
        for (kind, retry) in retries where now >= retry.deadline {
            // The next attempt owns its connection timeout. Re-arming this
            // timer here repeatedly destroys a still-connecting native route.
            // A subsequent failure schedules the next backoff; success clears it.
            retries[kind]?.beginAttempt()
            started.remove(kind)
            await routes[kind]?.prepare(request)
            guard generation == token else { return }
            await start(kind)
            guard generation == token else { return }
        }
        if runtimeStatusPolicy.isAutomaticBroadcastEnabled, let interval = runtimeStatusPolicy.periodicInterval,
           now - lastRuntimeStatus >= max(0.02, interval) {
            lastRuntimeStatus = now
            await sendRuntimeStatus(reason: .periodic)
        }
    }
}
