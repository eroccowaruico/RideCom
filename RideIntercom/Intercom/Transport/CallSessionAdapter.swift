import Foundation
import RTC

final class RideIntercomCallSessionAdapter: CallSession {
    var onEvent: ((TransportEvent) -> Void)?
    var processReceivedAudio: (@Sendable (RTC.ReceivedAudioPacket) -> AudioPacketReception)? {
        didSet { bindReceivedAudio() }
    }
    var audioPacketSink: @Sendable (RTC.RTCAudioPacket) -> Void {
        let delivery = audioDelivery
        return { delivery.enqueue($0) }
    }
    private(set) var activeRouteDebugTypeName: String = "RTC RouteManager"

    private var internetConfiguration: RTC.CloudflareRealtimeConfiguration?
    private let memberID: String
    private var rtcSession: RTC.CallSession
    private let ownsRTCSession: Bool
    private let sessionFactory: SessionFactory
    private var eventTask: Task<Void, Never>?
    private var audioReceiveTask: Task<Void, Never>?
    private var audioNotificationTask: Task<Void, Never>?
    private var commandTask: Task<Void, Never>?
    private var commands = CallCommandQueue()
    private var commandQueueFailed = false
    private var needsConfigurationRecovery = false
    private var hasPendingConfiguration = false
    private var appliedLocalMute = false
    private var requestedLocalMute = false
    private var appliedOutputMute = false
    private var requestedOutputMute = false
    private var appliedReports: [RTCRuntimePackageReport] = []
    private var requestedReports: [RTCRuntimePackageReport] = []
    private var mediaActive = false
    var pendingCommandCount: Int { commands.count }
    private let audioDelivery = AudioPacketDelivery()
    var droppedAudioPacketCount: Int { audioDelivery.droppedPacketCount }
    private var eventGeneration = UUID()
    private var publishedPeerIDs: [String]?
    private var publishedAuthenticatedMembers: [RTC.CallMemberState]?
    private var connectionRequest: RTC.CallStartRequest?
    private var mediaRequested = false
    private var audioPolicy: RTC.RTCAudioPolicy = .intercomDefault
    private var enabledRoutes: Set<RTC.RouteKind> = AppRTCTransportRoutePolicy.supportedRoutes

    init(
        memberID: String,
        internetConfiguration: RTC.CloudflareRealtimeConfiguration? = nil,
        sessionFactory: @escaping SessionFactory = RideIntercomCallSessionAdapter.makeRTCSession
    ) {
        self.memberID = memberID
        self.ownsRTCSession = true
        self.sessionFactory = sessionFactory
        self.internetConfiguration = internetConfiguration
        self.rtcSession = sessionFactory(
            .intercomDefault, AppRTCTransportRoutePolicy.supportedRoutes, internetConfiguration
        )
        bindEvents()
    }

    init(memberID: String = "member-local", rtcSession: RTC.CallSession) {
        self.memberID = memberID
        self.ownsRTCSession = false
        self.sessionFactory = Self.makeRTCSession
        self.rtcSession = rtcSession
        bindEvents()
    }

    deinit {
        eventTask?.cancel()
        audioReceiveTask?.cancel()
        audioNotificationTask?.cancel()
        audioDelivery.suspend()
        commandTask?.cancel()
    }

    func updateInternetConfiguration(_ configuration: RTC.CloudflareRealtimeConfiguration) {
        internetConfiguration = configuration
        if ownsRTCSession { rebuildOwnedRTCSession() }
    }

    func connect(group: IntercomGroup) {
        prepareConnection(group: group)
    }

    func startMedia() {
        mediaRequested = true
        if !requestedLocalMute { audioDelivery.begin() }
        enqueue(.startMedia)
    }

    func stopMedia() {
        clearPendingAudio()
        mediaActive = false
        mediaRequested = false
        enqueue(.stopMedia)
    }

    func disconnect() {
        connectionRequest = nil
        mediaRequested = false
        mediaActive = false
        activeRouteDebugTypeName = "RTC RouteManager"
        invalidateEvents()
        enqueue(.disconnect)
    }

    func setAudioPolicy(_ policy: RTC.RTCAudioPolicy) {
        guard policy != audioPolicy else { return }
        audioPolicy = policy
        connectionRequest?.audioPolicy = policy
        enqueue(.audioPolicy(policy))
    }

    func setEnabledRoutes(_ routes: Set<RTC.RouteKind>) {
        let requestedRoutes = routes.intersection(AppRTCTransportRoutePolicy.supportedRoutes)
        let normalizedRoutes = requestedRoutes.isEmpty ? AppRTCTransportRoutePolicy.supportedRoutes : requestedRoutes
        guard normalizedRoutes != enabledRoutes else { return }
        enabledRoutes = normalizedRoutes
        guard ownsRTCSession else { return }
        rebuildOwnedRTCSession()
    }

    func setLocalMute(_ muted: Bool) {
        requestedLocalMute = muted
        if muted { clearPendingAudio() } else if mediaRequested { audioDelivery.begin() }
        enqueue(.localMute(muted))
    }

    func setOutputMute(_ muted: Bool) {
        requestedOutputMute = muted
        enqueue(.outputMute(muted))
    }
    func updateRuntimePackageReports(_ reports: [RTCRuntimePackageReport]) {
        requestedReports = reports
        enqueue(.reports(reports))
    }

    func sendAudioPacket(_ packet: RTC.RTCAudioPacket) {
        guard mediaRequested, !requestedLocalMute, !commandQueueFailed else { return }
        audioDelivery.enqueue(packet)
        drainPendingAudio()
    }

    private func drainPendingAudio() {
        guard mediaActive, !appliedLocalMute, !requestedLocalMute else { return }
        audioDelivery.resume(with: rtcSession)
    }

    private func clearPendingAudio() { audioDelivery.suspend() }

    func sendControl(_ message: ControlMessage) {
        switch message {
        case .keepalive:
            let message = Self.makeKeepaliveMessage(activeCodec: activeAudioCodec())
            enqueue(.stateMessage(message.namespace, message))
        case .peerMuteState(let isMuted):
            guard let message = Self.makePeerMuteStateMessage(isMuted: isMuted) else { return }
            enqueue(.stateMessage(message.namespace, message))
        }
    }

    func sendApplicationData(_ message: ApplicationDataMessage) { enqueue(.application(message)) }
}

extension RideIntercomCallSessionAdapter {
    private func enqueue(_ command: CallCommand) {
        if command.coalescingKey == nil { hasPendingConfiguration = false }
        if commandQueueFailed { return }
        guard commands.append(command, generation: eventGeneration) else {
            commandQueueFailed = true
            needsConfigurationRecovery = true
            connectionRequest = nil; mediaRequested = false; mediaActive = false
            invalidateEvents()
            commands.removeAll()
            _ = commands.append(.disconnect, generation: eventGeneration)
            onEvent?(.commandQueueFailed)
            startCommandWorker()
            return
        }
        startCommandWorker()
    }

    private func startCommandWorker() {
        guard commandTask == nil else { return }
        commandTask = Task { [weak self] in
            while !Task.isCancelled, let self, let entry = self.commands.popFirst() {
                await self.execute(entry)
            }
            self?.commandTask = nil
        }
    }

    private func execute(_ entry: CallCommandQueue.Entry) async {
        switch entry.command {
        case .connect(let request):
            bindEvents(for: entry.generation)
            await rtcSession.prepare(request)
            await rtcSession.startConnection()
        case .startMedia:
            await rtcSession.setLocalMute(appliedLocalMute)
            await rtcSession.setOutputMute(appliedOutputMute)
            await rtcSession.startMedia()
            activateMedia(for: entry.generation)
        case .stopMedia:
            await rtcSession.stopMedia()
            mediaActive = false
        case .disconnect:
            await rtcSession.stopConnection()
            mediaActive = false
            commandQueueFailed = false
        case .localMute(let muted):
            await applyLocalMute(muted)
        case .outputMute(let muted):
            appliedOutputMute = muted
            await rtcSession.setOutputMute(muted)
        case .reports(let reports):
            appliedReports = reports
            await rtcSession.updateRuntimePackageReports(reports)
        case .audioPolicy(let policy):
            await rtcSession.updateAudioPolicy(policy)
        case .application(let message), .stateMessage(_, let message):
            await rtcSession.sendApplicationData(message)
        case .configure(let change):
            await applyConfiguration(change, generation: entry.generation)
        }
    }

    private func applyConfiguration(_ change: CallConfigurationChange, generation: UUID) async {
        hasPendingConfiguration = false
        await rtcSession.stopConnection()
        rtcSession = sessionFactory(change.audioPolicy, change.routes, change.internet)
        await rtcSession.setLocalMute(appliedLocalMute)
        await rtcSession.setOutputMute(appliedOutputMute)
        await rtcSession.updateRuntimePackageReports(appliedReports)
        // Initial settings can emit runtime reports without any connection.
        // Subscribe after priming, before prepare/start, so those reports do
        // not appear as network measurements on the idle Diagnostics page.
        bindEvents(for: generation)
        guard let request = change.request else { return }
        await rtcSession.prepare(request)
        await rtcSession.startConnection()
        if change.startMedia {
            await rtcSession.startMedia()
            activateMedia(for: generation)
        }
    }

    private func applyLocalMute(_ muted: Bool) async {
        appliedLocalMute = muted
        await rtcSession.setLocalMute(muted)
        if !muted { drainPendingAudio() }
    }

    private func activateMedia(for generation: UUID) {
        guard generation == eventGeneration else { return }
        mediaActive = true
        drainPendingAudio()
    }

    private func invalidateEvents() {
        clearPendingAudio()
        eventGeneration = UUID()
        publishedPeerIDs = nil
        publishedAuthenticatedMembers = nil
        eventTask?.cancel()
        eventTask = nil
        audioReceiveTask?.cancel(); audioReceiveTask = nil
        audioNotificationTask?.cancel(); audioNotificationTask = nil
    }

    private func prepareConnection(group: IntercomGroup) {
        guard !commandQueueFailed else { onEvent?(.commandQueueFailed); return }
        let request = Self.makeRTCRequest(
            from: group, memberID: memberID, routes: enabledRoutes, audioPolicy: audioPolicy
        )
        connectionRequest = request
        invalidateEvents()
        if needsConfigurationRecovery {
            needsConfigurationRecovery = false
            if ownsRTCSession {
                enqueue(.configure(.init(audioPolicy: audioPolicy, routes: enabledRoutes,
                    internet: internetConfiguration, request: nil, startMedia: false)))
            }
            enqueue(.localMute(requestedLocalMute))
            enqueue(.outputMute(requestedOutputMute))
            enqueue(.reports(requestedReports))
        }
        enqueue(.connect(request))
    }

    private func bindEvents(for expectedGeneration: UUID? = nil) {
        guard expectedGeneration == nil || expectedGeneration == eventGeneration else { return }
        eventTask?.cancel()
        let generation = eventGeneration
        let events = rtcSession.events
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self, self.eventGeneration == generation else { return }
                self.handleRTCEvent(event)
            }
        }
        bindReceivedAudio()
    }

    private func bindReceivedAudio() {
        audioReceiveTask?.cancel()
        audioNotificationTask?.cancel()
        guard let processReceivedAudio else { return }
        let generation = eventGeneration
        // RTC supplies an independent bounded subscription. UI event handling
        // cannot hold up this consumer's decoding and native playback schedule.
        let events = rtcSession.events
        let notifications = AsyncStream<(RTC.ReceivedAudioPacket, AudioPacketReception)>
            .makeStream(bufferingPolicy: .bufferingNewest(64))
        audioReceiveTask = Task.detached(priority: .userInitiated) {
            defer { notifications.continuation.finish() }
            for await event in events {
                guard !Task.isCancelled else { return }
                if case .receivedAudioPacket(let received) = event {
                    let result = processReceivedAudio(received)
                    notifications.continuation.yield((received, result))
                }
            }
        }
        audioNotificationTask = Task { [weak self] in
            for await (received, result) in notifications.stream {
                guard !Task.isCancelled, let self, self.eventGeneration == generation else { return }
                self.onEvent?(.receivedAudioPacket(received, result))
            }
        }
    }

    private func handleRTCEvent(_ event: RTC.CallSessionEvent) {
        switch event {
        case .stateChanged(let state):
            handleRTCStateChanged(state)
        case .routeChanged(let snapshot):
            // All production routes carry the same App-owned encoded audio pipeline.
            activeRouteDebugTypeName = Self.routeDebugName(snapshot.activeRoute ?? snapshot.mediaRoute)
            onEvent?(.routesChanged(snapshot))
        case .routeAvailabilityChanged:
            break
        case .membersChanged(let members):
            publishMembershipChanges(members)
        case .receivedApplicationData(let received):
            onEvent?(Self.makeAppEvent(peerID: received.peerID.rawValue, applicationData: received.message))
        case .receivedAudioPacket:
            break // The independent media consumer owns playback and notification.
        case .metricsChanged(let metrics):
            onEvent?(.routeMetrics(metrics))
        case .networkDiagnosticsChanged(let report):
            onEvent?(.networkDiagnostics(report))
        case .error(let error):
            handleRTCError(error)
        }
    }

    private func publishMembershipChanges(_ members: [RTC.CallMemberState]) {
        let remote = members.filter { $0.peer.id.rawValue != memberID }
            .sorted { $0.peer.id.rawValue < $1.peer.id.rawValue }
        let peerIDs = remote.map { $0.peer.id.rawValue }
        let authenticated = remote.filter(\.isConnected)
        // RTC reports the most recent path on each member. Admission responds
        // to participant changes, while routesChanged carries route state.
        let membership = authenticated.map { member in
            var copy = member
            copy.route = nil
            return copy
        }
        let notifyConnected = peerIDs != publishedPeerIDs
        let notifyAuthenticated = membership != publishedAuthenticatedMembers
        publishedPeerIDs = peerIDs
        publishedAuthenticatedMembers = membership
        let generation = eventGeneration
        if notifyConnected { onEvent?(.connected(peerIDs: peerIDs)) }
        if notifyAuthenticated, generation == eventGeneration {
            onEvent?(.authenticated(members: authenticated))
        }
    }

    private func activeAudioCodec() -> AudioCodecIdentifier {
        audioPolicy.preferredCodecs.first ?? .pcm16
    }

    private func rebuildOwnedRTCSession() {
        // Invalidate once per pending configuration segment. Further updates can
        // replace that segment without allocating intermediate RTC sessions.
        if !hasPendingConfiguration { invalidateEvents(); mediaActive = false }
        hasPendingConfiguration = true
        if var request = connectionRequest {
            request.audioPolicy = audioPolicy
            request.configuration = Self.makeRouteConfiguration(enabledRoutes: enabledRoutes)
            connectionRequest = request
        }
        enqueue(.configure(.init(audioPolicy: audioPolicy, routes: enabledRoutes,
            internet: internetConfiguration, request: connectionRequest, startMedia: mediaRequested)))
        activeRouteDebugTypeName = "RTC RouteManager"
    }
}
