import Foundation
import Synchronization
import Testing
@testable import RTC
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct PeerAudioAdmissionTests {
    @Test func actualRTCAdmissionPrecedesTheIndependentAudioConsumer() async throws {
        let route = AdmissionTestRoute()
        let rtc = RouteManager(routes: [route], runtimeStatusPolicy: .init(isAutomaticBroadcastEnabled: false))
        let admissionSecret = "admission-fixture"
        var group = IntercomSeedData.recentGroups[0]
        group.accessSecret = admissionSecret
        let local = group.members[0].id
        let remote = group.members[1].id
        let peer = PeerDescriptor(id: .init(rawValue: remote), displayName: "Friend")
        let adapter = RideIntercomCallSessionAdapter(memberID: local, rtcSession: rtc)
        let processed = Mutex<[Data]>([])
        adapter.processReceivedAudio = { received in
            processed.withLock { $0.append(received.packet.payload) }
            return .processed(level: 0.1)
        }
        var members: [CallMemberState] = []
        var markers: Set<Data> = []
        adapter.onEvent = { event in
            if case .authenticated(let value) = event { members = value }
            if case .receivedApplicationData(_, let message) = event { markers.insert(message.payload) }
        }

        try await withConnectedCall(adapter, group: group, rtc: rtc) {
            await route.waitUntilStarted()
            route.source.yield(.membersChanged(.multipeer, [.init(peer: peer, route: .multipeer, isConnected: true)]))
            let receive = relayDelivery(groupID: group.id.uuidString, secret: admissionSecret, peer: peer, route: route)
            let hasMarker: (Data) -> Bool = { markers.contains($0) }

            try receive(.presence)
            try receive(packet(1))
            try await checkpoint(receive: receive, hasMarker: hasMarker)
            #expect(processed.withLock { $0.isEmpty })

            let membership = try #require(members.first?.membershipID)
            var policy = RTC.RTCAudioPolicy.intercomDefault
            policy.peerPolicy = .admittedMemberships([peer.id: membership])
            await applyPolicy(policy, marker: 1, adapter: adapter, route: route)
            try receive(packet(2))
            try await checkpoint(receive: receive, hasMarker: hasMarker)
            await AppTestSupport.waitUntil { processed.withLock { $0 == [Data([2])] } }
            #expect(processed.withLock { $0 == [Data([2])] })

            policy.peerPolicy = .admittedMemberships([:])
            await applyPolicy(policy, marker: 2, adapter: adapter, route: route)
            try receive(packet(3))
            try await checkpoint(receive: receive, hasMarker: hasMarker)
            #expect(processed.withLock { $0 == [Data([2])] })
        }
    }

    private func withConnectedCall(
        _ adapter: RideIntercomCallSessionAdapter,
        group: IntercomGroup,
        rtc: RouteManager,
        exercise: () async throws -> Void
    ) async throws {
        adapter.connect(group: group)
        adapter.startMedia()
        do {
            try await exercise()
        } catch {
            adapter.disconnect()
            await rtc.stopConnection()
            throw error
        }
        adapter.disconnect()
        await rtc.stopConnection()
    }

    private func relayDelivery(
        groupID: String, secret: String, peer: PeerDescriptor, route: AdmissionTestRoute
    ) -> (RelayBody) throws -> Void {
        var sender = GroupRelay(request: .init(
            sessionID: groupID,
            localPeer: peer,
            credential: .derived(groupID: groupID, secret: secret)
        ))
        return { body in
            let payload = try sender.make(body, now: ProcessInfo.processInfo.systemUptime)
            let message = ApplicationDataMessage(
                namespace: GroupRelay.namespace,
                payload: payload,
                delivery: body.delivery
            )
            route.source.yield(.receivedApplicationData(.multipeer, .init(peerID: peer.id, message: message)))
        }
    }

    private func checkpoint(
        receive: (RelayBody) throws -> Void,
        hasMarker: @escaping @MainActor (Data) -> Bool
    ) async throws {
        let marker = Data(UUID().uuidString.utf8)
        try receive(.application(.init(namespace: "test.marker", payload: marker)))
        await AppTestSupport.waitUntil { hasMarker(marker) }
        #expect(hasMarker(marker))
    }

    private func applyPolicy(
        _ policy: RTC.RTCAudioPolicy,
        marker: UInt8,
        adapter: RideIntercomCallSessionAdapter,
        route: AdmissionTestRoute
    ) async {
        adapter.setAudioPolicy(policy)
        let applied = ApplicationDataMessage(namespace: "test.applied", payload: Data([marker]))
        // The ordered command queue sends this marker after applying policy.
        adapter.sendApplicationData(applied)
        await route.waitForApplication(applied)
    }

    private func packet(_ value: UInt8) -> RelayBody {
        .audio(.init(sequenceNumber: 0, codec: .pcm16, payload: Data([value])))
    }
}

private actor AdmissionTestRoute: RTCCallRoute {
    nonisolated let source = EventSource<RouteEvent>()
    nonisolated var events: AsyncStream<RouteEvent> { source.stream }
    let kind = RouteKind.multipeer
    let capabilities = RouteCapabilities(supportsLocalDiscovery: true, supportsOfflineOperation: true,
        supportsReliableApplicationData: true, supportsUnreliableApplicationData: true,
        requiresSignaling: false, supportedAudioCodecs: [.pcm16])
    private var started = false
    private var localPeerID: PeerID?
    private var receiver: GroupRelay?
    private var messages: [ApplicationDataMessage] = []
    func prepare(_ request: CallStartRequest) async {
        localPeerID = request.localPeer.id
        var observer = request
        observer.localPeer = .init(id: .init(rawValue: "observer"), displayName: "Observer")
        receiver = GroupRelay(request: observer)
    }
    func startConnection() async { started = true }
    func stopConnection() async { started = false }
    func sendApplicationData(_ message: ApplicationDataMessage) async -> RTCRouteSendResult {
        if let localPeerID,
           let reception = receiver?.receive(
               message.payload,
               from: localPeerID,
               now: ProcessInfo.processInfo.systemUptime
           ),
           case .application(let application) = reception.body {
            messages.append(application)
        }
        return .init()
    }
    func waitUntilStarted() async {
        for _ in 0..<1_000 {
            if started { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(started)
    }
    func waitForApplication(_ message: ApplicationDataMessage) async {
        for _ in 0..<1_000 {
            if messages.contains(message) { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(messages.contains(message))
    }
}
