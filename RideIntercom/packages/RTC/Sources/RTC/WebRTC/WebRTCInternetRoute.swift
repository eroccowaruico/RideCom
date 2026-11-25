import Foundation

public actor WebRTCInternetRoute: RTCCallRoute {
    public let kind: RouteKind = .webRTC
    public let capabilities = RouteCapabilities(
        supportsLocalDiscovery: false,
        supportsOfflineOperation: false,
        supportsReliableApplicationData: true,
        supportsUnreliableApplicationData: true,
        requiresSignaling: true,
        supportedAudioCodecs: [.pcm16, .opus, .mpeg4AACELD, .mpeg4AACELDv2],
        backendName: "Cloudflare Realtime SFU"
    )
    public nonisolated var events: AsyncStream<RouteEvent> { eventSource.stream }

    private nonisolated let eventSource = EventSource<RouteEvent>(
        isTransient: { $0.isTransient }, overflowEvent: .stateChanged(.webRTC, .failed))
    private let cloudflareConfigurationProvider: @Sendable (CallStartRequest) -> CloudflareRealtimeConfiguration?
    private let signalingClient: WebRTCSignalingClient
    private let engine: NativeWebRTCEngine
    private var connectionTask: Task<Void, Never>?
    private var signalingTask: Task<Void, Never>?
    private var engineTask: Task<Void, Never>?
    private var request: CallStartRequest?
    private var remotePeers: [PeerID: PeerDescriptor] = [:]
    private var connecting = false
    private var iceConnected = false
    private var generation = UUID()
    private var rejectedAttempt: RejectedAttempt?
    private var replacementConfiguration: CloudflareRealtimeConfiguration?
    private let sfuPeer = PeerDescriptor(id: .init(rawValue: "cloudflare-sfu"), displayName: "Cloudflare SFU")

    public init(
        cloudflareConfiguration: CloudflareRealtimeConfiguration,
        signalingClient: WebRTCSignalingClient = CloudflareRealtimeSignalingClient(),
        engine: NativeWebRTCEngine = NativeWebRTCEngine()
    ) {
        self.cloudflareConfigurationProvider = { _ in cloudflareConfiguration }
        self.signalingClient = signalingClient
        self.engine = engine
    }

    public init(
        cloudflareConfigurationProvider: @escaping @Sendable (CallStartRequest) -> CloudflareRealtimeConfiguration?,
        signalingClient: WebRTCSignalingClient = CloudflareRealtimeSignalingClient(),
        engine: NativeWebRTCEngine = NativeWebRTCEngine()
    ) {
        self.cloudflareConfigurationProvider = cloudflareConfigurationProvider
        self.signalingClient = signalingClient
        self.engine = engine
    }

    public init(
        signalingClient: WebRTCSignalingClient = CloudflareRealtimeSignalingClient(),
        engine: NativeWebRTCEngine = NativeWebRTCEngine()
    ) {
        self.cloudflareConfigurationProvider = { _ in nil }
        self.signalingClient = signalingClient
        self.engine = engine
    }

    deinit {
        connectionTask?.cancel()
        signalingTask?.cancel()
        engineTask?.cancel()
    }

    public func networkDiagnostics() async -> RTCRouteNetworkDiagnostics {
        .init(route: kind, statistics: await engine.networkStatistics(for: sfuPeer.id),
              eventDrops: ["route": eventSource.report, "engine": engine.eventDropReport])
    }

    public func prepare(_ request: CallStartRequest) async {
        if self.request != nil { await stopConnection() }
        eventSource.resetDiagnostics()
        self.request = request
        guard engine.isAvailable else {
            eventSource.yield(
                .availabilityChanged(
                    RouteAvailability(route: kind, isAvailable: false, reason: "Native WebRTC SDK is unavailable"))
            )
            eventSource.yield(.stateChanged(kind, .failed))
            return
        }
        eventSource.yield(.availabilityChanged(RouteAvailability(route: kind, isAvailable: true)))
        eventSource.yield(.stateChanged(kind, .standby))
    }

    public func startConnection() async {
        guard let request else {
            eventSource.yield(.error(kind, .connectionFailed(kind, "prepare must be called before startConnection")))
            return
        }
        guard engine.isAvailable else {
            eventSource.yield(.stateChanged(kind, .failed))
            eventSource.yield(
                .availabilityChanged(
                    RouteAvailability(route: kind, isAvailable: false, reason: "Native WebRTC SDK is unavailable"))
            )
            return
        }
        guard let cloudflareConfiguration = replacementConfiguration ?? cloudflareConfigurationProvider(request) else {
            eventSource.yield(
                .availabilityChanged(
                    RouteAvailability(
                        route: kind, isAvailable: false, reason: "WebRTC route configuration is unavailable")))
            eventSource.yield(.stateChanged(kind, .failed))
            return
        }
        guard !connecting else { return }
        replacementConfiguration = nil
        generation = UUID()
        let generation = generation
        connecting = true
        iceConnected = false
        await engine.prepareTransport()
        guard self.generation == generation else { return }
        bindSignalingEvents(configuration: cloudflareConfiguration)
        bindEngineEvents()
        eventSource.yield(.stateChanged(kind, .connecting))
        let connection = WebRTCSignalingConnectRequest(call: request, cloudflare: cloudflareConfiguration)
        connectionTask = Task { [signalingClient] in
            guard !Task.isCancelled else { return }
            await signalingClient.connect(connection)
        }
    }

    public func stopConnection() async {
        rejectedAttempt = nil; replacementConfiguration = nil
        await stopConnection(finalState: .disconnected)
    }

    private func stopConnection(finalState: RouteConnectionState) async {
        generation = UUID()
        let generation = generation
        connecting = false
        iceConnected = false
        connectionTask?.cancel(); connectionTask = nil
        signalingTask?.cancel(); signalingTask = nil
        engineTask?.cancel(); engineTask = nil
        remotePeers.removeAll()
        emitMembers()
        await engine.close()
        guard self.generation == generation else { return }
        await signalingClient.disconnect()
        guard self.generation == generation else { return }
        eventSource.yield(.stateChanged(kind, finalState))
    }

    @discardableResult
    public func sendApplicationData(_ message: ApplicationDataMessage) async -> RTCRouteSendResult {
        guard connecting else { return .init(transportAccepted: false) }
        let accepted = await engine.sendApplicationData(message, to: sfuPeer.id)
        // SFU fan-out does not report immediate per-subscriber delivery.
        return .init(transportAccepted: accepted)
    }
}

extension WebRTCInternetRoute: DeviceCredentialRecoveringRoute {
    func requestCredentialRecovery() async {
        guard let rejectedAttempt else { return }
        await rejectedAttempt.cleanup.value
        guard !Task.isCancelled, self.rejectedAttempt?.id == rejectedAttempt.id, let request,
              let replacement = cloudflareConfigurationProvider(request),
              replacement.workerURL == rejectedAttempt.configuration.workerURL,
              !replacement.accessToken.isEmpty, replacement.accessToken != rejectedAttempt.configuration.accessToken
        else { return }
        self.rejectedAttempt = nil
        replacementConfiguration = replacement
        eventSource.yield(.deviceCredentialUpdated(kind))
    }
}

extension WebRTCInternetRoute {
    private struct RejectedAttempt {
        let id: UUID
        let configuration: CloudflareRealtimeConfiguration
        let cleanup: Task<Void, Never>
    }

    private func bindSignalingEvents(configuration: CloudflareRealtimeConfiguration) {
        let generation = generation
        let events = signalingClient.events
        signalingTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handleSignalingEvent(event, configuration: configuration, generation: generation)
            }
        }
    }

    private func handleSignalingEvent(
        _ event: WebRTCSignalingEvent, configuration: CloudflareRealtimeConfiguration, generation: UUID
    ) async {
        guard self.generation == generation, connecting else { return }
        switch event {
        case .iceServers(let servers):
            await configureIceServers(servers, generation: generation)
        case .connected:
            await sendInitialOffer(generation: generation)
        case .dataChannels(let channels):
            await engine.configureDataChannels(channels, for: sfuPeer.id)
        case .members(let peers):
            remotePeers = Dictionary(peers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            emitMembers()
        case .disconnected:
            await stopConnection()
        case .answer(let answer, let peerID):
            await acceptSignalingAnswer(answer, from: peerID, generation: generation)
        case .receivedApplicationData(let data):
            forwardApplicationData(data)
        case .blocked(let reason):
            await blockConnection(reason, configuration: configuration, generation: generation)
        case .failed(let message):
            await fail(message, generation: generation)
        }
    }

    private func blockConnection(
        _ reason: ConnectionBlockReason, configuration: CloudflareRealtimeConfiguration, generation: UUID
    ) async {
        let cleanup = Task {
            guard self.generation == generation else { return }
            await stopConnection(finalState: .failed)
        }
        if reason == .deviceCredentialRejected {
            rejectedAttempt = .init(id: generation, configuration: configuration, cleanup: cleanup)
        }
        eventSource.yield(.connectionBlocked(kind, reason))
        await cleanup.value
    }

    private func configureIceServers(_ servers: [WebRTCIceServer], generation: UUID) async {
        if await !engine.configureIceServers(servers) {
            await fail("Could not apply ICE credentials", generation: generation)
        }
    }

    private func sendInitialOffer(generation: UUID) async {
        await engine.createPeerConnection(for: sfuPeer)
        guard self.generation == generation else { return }
        if let offer = await engine.makeOffer(for: sfuPeer.id), self.generation == generation {
            await signalingClient.sendOffer(offer, to: sfuPeer.id)
        } else {
            await fail("Could not create WebRTC offer", generation: generation)
        }
    }

    private func acceptSignalingAnswer(
        _ answer: WebRTCSessionDescription, from peerID: PeerID, generation: UUID
    ) async {
        guard peerID == sfuPeer.id else { return }
        if await !engine.acceptAnswer(answer, from: peerID) {
            await fail("Could not accept WebRTC answer", generation: generation)
        }
    }

    private func forwardApplicationData(_ data: ReceivedApplicationData) {
        guard remotePeers[data.peerID] != nil else { return }
        eventSource.yield(.receivedApplicationData(kind, data))
    }

    private func fail(_ message: String, generation: UUID) async {
        guard self.generation == generation else { return }
        eventSource.yield(.error(kind, .connectionFailed(kind, message)))
        await stopConnection(finalState: .failed)
    }

    private func bindEngineEvents() {
        let generation = generation
        let events = engine.events
        engineTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled else { return }
                await self?.handleEngineEvent(event, generation: generation)
            }
        }
    }

    private func handleEngineEvent(_ event: WebRTCEngineEvent, generation: UUID) async {
        guard self.generation == generation, connecting else { return }
        switch event {
        case .receivedApplicationData(let data):
            forwardApplicationData(data)
        case .connectionStateChanged(let state):
            iceConnected = state == .connected || state == .mediaReady
            if iceConnected { await signalingClient.startPublishing() }
            if state == .failed {
                await fail("WebRTC media connection failed", generation: generation)
            } else {
                eventSource.yield(.stateChanged(kind, state))
            }
        }
    }

    private func emitMembers() {
        let members = remotePeers.values.map {
            CallMemberState(peer: $0, route: kind, isConnected: true)
        }
        eventSource.yield(.membersChanged(kind, members))
        eventSource.yield(.metricsChanged(RouteMetrics(route: kind, activePeerCount: members.count)))
    }
}

public enum WebRTCEngineEvent: Equatable, Sendable {
    var isTransient: Bool {
        if case .receivedApplicationData(let received) = self { return received.message.delivery == .unreliable }
        return false
    }

    case receivedApplicationData(ReceivedApplicationData)
    case connectionStateChanged(RouteConnectionState)
}

open class NativeWebRTCEngine: NSObject, @unchecked Sendable {
    private let eventSource = EventSource<WebRTCEngineEvent>(
        isTransient: { $0.isTransient }, overflowEvent: .connectionStateChanged(.failed))
    public var eventDropReport: RTCEventDropReport { eventSource.report }
    public func emit(_ event: WebRTCEngineEvent) { eventSource.yield(event) }
    open var isAvailable: Bool { false }
    open var events: AsyncStream<WebRTCEngineEvent> { eventSource.stream }

    public override init() {}

    open func prepareTransport() async { eventSource.resetDiagnostics() }
    open func configureIceServers(_ servers: [WebRTCIceServer]) async -> Bool { false }
    open func networkStatistics(for peerID: PeerID) async -> RTCNetworkStatistics { .init() }

    open func createPeerConnection(for peer: PeerDescriptor) async {}
    open func makeOffer(for peerID: PeerID) async -> WebRTCSessionDescription? { nil }

    open func acceptOffer(_ offer: WebRTCSessionDescription, from peerID: PeerID) async -> WebRTCSessionDescription? {
        nil
    }

    open func acceptAnswer(_ answer: WebRTCSessionDescription, from peerID: PeerID) async -> Bool { false }

    open func configureDataChannels(_ channels: [WebRTCDataChannel], for peerID: PeerID) async {}
    @discardableResult
    open func sendApplicationData(_ message: ApplicationDataMessage, to peerID: PeerID) async -> Bool? { nil }

    open func closePeerConnection(peerID: PeerID) async {}
    open func close() async {}
}
