import Foundation
import Testing
@testable import RTC

func makeRequest(
    configuration: CallRouteConfiguration = CallRouteConfiguration(),
    credential: RTCCredential? = RTCCredential.derived(groupID: "test-group", secret: "secret"),
    audioPolicy: RTCAudioPolicy = RTCAudioPolicy()
) -> CallStartRequest {
    CallStartRequest(
        sessionID: "test-session",
        localPeer: PeerDescriptor(id: PeerID(rawValue: "local"), displayName: "Local"),
        credential: credential,
        configuration: configuration,
        audioPolicy: audioPolicy
    )
}

func makePacket(
    sequenceNumber: UInt64,
    codec: RTCAudioCodecIdentifier = .pcm16,
    format: RTCAudioFormat = RTCAudioFormat(sampleRate: 48_000, channelCount: 1),
    sampleCount: Int? = 1,
    bitRate: Int? = nil,
    payload: Data = Data([1])
) -> RTCAudioPacket {
    RTCAudioPacket(
        sequenceNumber: sequenceNumber,
        codec: codec,
        format: format,
        capturedAt: 100 + TimeInterval(sequenceNumber),
        sampleCount: sampleCount,
        bitRate: bitRate,
        payload: payload
    )
}

final class FakeRoute: RTCCallRoute, @unchecked Sendable {
    let kind: RouteKind
    let capabilities: RouteCapabilities
    var events: AsyncStream<RouteEvent> { eventSource.stream }

    private let eventSource = EventSource<RouteEvent>()
    private let onRetryPrepare: (@Sendable (RouteKind) async -> Void)?
    private let onStart: (@Sendable () async -> Void)?
    private(set) var prepareCount = 0
    private(set) var startConnectionCount = 0
    private(set) var sentApplicationData: [ApplicationDataMessage] = []
    var immediateRecipients: Set<PeerID> = []

    init(
        kind: RouteKind,
        onRetryPrepare: (@Sendable (RouteKind) async -> Void)? = nil,
        onStart: (@Sendable () async -> Void)? = nil
    ) {
        self.kind = kind
        self.onRetryPrepare = onRetryPrepare
        self.onStart = onStart
        self.capabilities = RouteCapabilities(
            supportsLocalDiscovery: kind == .multipeer,
            supportsOfflineOperation: kind == .multipeer,
            supportsReliableApplicationData: true,
            supportsUnreliableApplicationData: true,
            requiresSignaling: kind == .webRTC,
            supportedAudioCodecs: [.pcm16]
        )
    }

    func yield(_ event: RouteEvent) { eventSource.yield(event) }

    func prepare(_ request: CallStartRequest) async {
        prepareCount += 1
        if prepareCount > 1 { await onRetryPrepare?(kind) }
    }

    func startConnection() async {
        startConnectionCount += 1
        await onStart?()
    }

    func stopConnection() async {}

    func sendApplicationData(_ message: ApplicationDataMessage) async -> RTCRouteSendResult {
        sentApplicationData.append(message)
        return .init(verifiedLocalRecipients: immediateRecipients)
    }

}

func relayBodies(_ messages: [ApplicationDataMessage]) -> [RelayBody] {
    var request = makeRequest()
    request.localPeer = .init(id: .init(rawValue: "observer"), displayName: "Observer")
    var relay = GroupRelay(request: request)
    return messages.compactMap { relay.receive($0.payload, from: .init(rawValue: "local"), now: 0)?.body }
}
func relayMessages(_ messages: [ApplicationDataMessage]) -> [ApplicationDataMessage] {
    relayBodies(messages).compactMap { if case .application(let message) = $0 { message } else { nil } }
}
