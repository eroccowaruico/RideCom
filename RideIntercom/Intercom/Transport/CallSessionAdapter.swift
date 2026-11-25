import Foundation
import RTC

final class RideIntercomCallSessionAdapter: CallSession {
    var onEvent: ((TransportEvent) -> Void)?
    var processReceivedAudio: (@Sendable (RTC.ReceivedAudioPacket) -> AudioPacketReception)? {
        didSet { bindReceivedAudio() }
    }
    func makeAudioPacketSink(
        whileSourceIsActive: @escaping @Sendable () -> Bool
    ) -> @Sendable (RTC.RTCAudioPacket) -> Void {
        let delivery = audioDelivery
        return { delivery.enqueue($0, whileSourceIsActive: whileSourceIsActive) }
    }

    func lastOutboundAudioDispatch() async -> RTCOutboundAudioDispatch? {
        guard mediaActive else { return nil }
        let generation = eventGeneration
        let dispatch = await rtcSession.lastOutboundAudioDispatch()
        return mediaActive && eventGeneration == generation ? dispatch : nil
    }

    private(set) var activeRouteDebugTypeName: String = "RTC RouteManager"
    private var internetConfiguration: InternetRouteConfigurationSource
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
    private var requestedMediaStart: UUID?
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
        let source = InternetRouteConfigurationSource(internetConfiguration)
        self.internetConfiguration = source
        self.rtcSession = sessionFactory(.intercomDefault, AppRTCTransportRoutePolicy.supportedRoutes, source)
        bindEvents()
    }

    init(memberID: String = "member-local", rtcSession: RTC.CallSession) {
        self.memberID = memberID
        self.ownsRTCSession = false
        self.sessionFactory = Self.makeRTCSession
        self.internetConfiguration = InternetRouteConfigurationSource(nil)
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

    func updateInternetConfiguration(_ configuration: RTC.CloudflareRealtimeConfiguration?, preservingCall: Bool) {
        if preservingCall {
            internetConfiguration.supply(configuration)
        } else {
            internetConfiguration = InternetRouteConfigurationSource(configuration)
            if ownsRTCSession { rebuildOwnedRTCSession() }
        }
    }

    func retryInternetRouteAfterCredentialChange() { enqueue(.retryInternetRoute) }

    func connect(group: IntercomGroup) {
        prepareConnection(group: group)
    }

    func startMedia() {
        guard !commandQueueFailed else { return }
        let startID = requestedMediaStart ?? UUID()
        requestedMediaStart = startID
        if !requestedLocalMute { audioDelivery.begin() }
        enqueue(.startMedia(startID))
    }

    func stopMedia() {
        suspendMediaDelivery()
        requestedMediaStart = nil
        enqueue(.stopMedia)
    }

    func disconnect() {
        activeRouteDebugTypeName = "RTC RouteManager"
        resetConnection(to: nil)
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
        if muted { audioDelivery.suspend() } else if requestedMediaStart != nil { audioDelivery.begin() }
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

    private func drainPendingAudio() {
        guard mediaActive, !appliedLocalMute, !requestedLocalMute else { return }
        audioDelivery.resume(with: rtcSession)
    }

    private func suspendMediaDelivery() {
        mediaActive = false
        audioDelivery.suspend()
    }

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
            resetConnection(to: nil)
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
            await openRTCConnection(request, generation: entry.generation)
        case .startMedia(let startID):
            await rtcSession.setLocalMute(appliedLocalMute)
            await rtcSession.setOutputMute(appliedOutputMute)
            await rtcSession.startMedia()
            activateMedia(for: entry.generation, startID: startID)
        case .stopMedia:
            await rtcSession.stopMedia()
        case .disconnect:
            await rtcSession.stopConnection()
            commandQueueFailed = false
        case .localMute(let muted):
            await applyLocalMute(muted)
        case .outputMute(let muted):
            appliedOutputMute = muted
            await rtcSession.setOutputMute(muted)
        case .reports(let reports):
            appliedReports = reports
            await rtcSession.updateRuntimePackageReports(reports)
        case .audioPolicy, .retryInternetRoute, .application, .stateMessage:
            await entry.command.applyToSession(rtcSession, belongsToCurrentCall: entry.generation == eventGeneration)
        case .configure(let change):
            await applyConfiguration(change, generation: entry.generation)
        }
    }

    private func applyConfiguration(_ change: CallConfigurationChange, generation: UUID) async {
        hasPendingConfiguration = false
        let request = await rtcSession.stopConnection(preservingContinuationIn: change.request)
        rtcSession = sessionFactory(change.audioPolicy, change.routes, change.internet)
        await rtcSession.setLocalMute(appliedLocalMute)
        await rtcSession.setOutputMute(appliedOutputMute)
        await rtcSession.updateRuntimePackageReports(appliedReports)
        // Subscribe after priming so initial reports stay off the idle Diagnostics page.
        await openRTCConnection(request, generation: generation, startID: change.mediaStartID)
    }

    private func openRTCConnection(_ request: RTC.CallStartRequest?, generation: UUID, startID: UUID? = nil) async {
        bindEvents(for: generation)
        guard let request else { return }
        await rtcSession.prepare(request)
        await rtcSession.startConnection()
        if let startID {
            await rtcSession.startMedia()
            activateMedia(for: generation, startID: startID)
        }
    }

    private func applyLocalMute(_ muted: Bool) async {
        appliedLocalMute = muted
        await rtcSession.setLocalMute(muted)
        if !muted { drainPendingAudio() }
    }

    private func activateMedia(for generation: UUID, startID: UUID) {
        guard generation == eventGeneration, requestedMediaStart == startID else { return }
        mediaActive = true
        drainPendingAudio()
    }

    private func invalidateEvents() {
        suspendMediaDelivery()
        eventGeneration = UUID()
        publishedPeerIDs = nil
        publishedAuthenticatedMembers = nil
        eventTask?.cancel()
        eventTask = nil
        audioReceiveTask?.cancel(); audioReceiveTask = nil
        audioNotificationTask?.cancel(); audioNotificationTask = nil
    }

    private func resetConnection(to request: RTC.CallStartRequest?) {
        connectionRequest = request
        requestedMediaStart = nil
        invalidateEvents()
    }

    private func prepareConnection(group: IntercomGroup) {
        guard !commandQueueFailed else { onEvent?(.commandQueueFailed); return }
        let request = Self.makeRTCRequest(
            from: group, memberID: memberID, routes: enabledRoutes, audioPolicy: audioPolicy
        )
        resetConnection(to: request)
        if needsConfigurationRecovery {
            needsConfigurationRecovery = false
            if ownsRTCSession {
                enqueue(.configure(.init(audioPolicy: audioPolicy, routes: enabledRoutes,
                    internet: internetConfiguration, request: nil, mediaStartID: nil)))
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
        let update = Self.membershipEvents(members, excluding: memberID)
        let notifyConnected = update.peerIDs != publishedPeerIDs
        let notifyAuthenticated = update.comparable != publishedAuthenticatedMembers
        publishedPeerIDs = update.peerIDs
        publishedAuthenticatedMembers = update.comparable
        let generation = eventGeneration
        if notifyConnected { onEvent?(.connected(peerIDs: update.peerIDs)) }
        if notifyAuthenticated, generation == eventGeneration {
            onEvent?(.authenticated(members: update.authenticated))
        }
    }

    private func activeAudioCodec() -> AudioCodecIdentifier {
        audioPolicy.preferredCodecs.first ?? .pcm16
    }

    private func rebuildOwnedRTCSession() {
        // Invalidate once per pending configuration segment. Further updates can
        // replace that segment without allocating intermediate RTC sessions.
        if !hasPendingConfiguration { invalidateEvents() }
        hasPendingConfiguration = true
        if var request = connectionRequest {
            request.audioPolicy = audioPolicy
            request.configuration = Self.makeRouteConfiguration(enabledRoutes: enabledRoutes)
            connectionRequest = request
        }
        enqueue(.configure(.init(audioPolicy: audioPolicy, routes: enabledRoutes,
            internet: internetConfiguration, request: connectionRequest, mediaStartID: requestedMediaStart)))
        activeRouteDebugTypeName = "RTC RouteManager"
    }
}
