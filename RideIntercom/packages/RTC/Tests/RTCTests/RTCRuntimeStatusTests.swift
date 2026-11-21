import Foundation
import Testing
@testable import RTC

@Test func runtimeStatusApplicationDataRoundTripsThroughPackageNamespace() throws {
    let status = runtimeStatusFixture()
    let message = try RTCRuntimeStatusTransport.makeMessage(status)
    let decoded = try RTCRuntimeStatusTransport.decode(message)

    #expect(message.namespace == RTCRuntimeStatusTransport.namespace)
    #expect(message.delivery == .reliable)
    #expect(decoded == status)
}

private func runtimeStatusFixture() -> RTCRuntimeStatus {
    let audioPolicy = RTCAudioPolicy(preferredSendFormat: .init(sampleRate: 16_000, channelCount: 1),
        preferredCodecs: [.opus, .pcm16], maximumBitRate: 32_000)
    let capabilities = RouteCapabilities(
        supportsLocalDiscovery: true,
        supportsOfflineOperation: true,
        supportsReliableApplicationData: true,
        supportsUnreliableApplicationData: true,
        requiresSignaling: false,
        supportedAudioCodecs: [.opus, .pcm16],
        backendName: "test"
    )
    return RTCRuntimeStatus(
        reason: .connectionStarted,
        generatedAt: 123,
        sessionID: "session",
        localPeer: PeerDescriptor(id: PeerID(rawValue: "local"), displayName: "Local"),
        expectedPeers: [PeerDescriptor(id: PeerID(rawValue: "remote"), displayName: "Remote")],
        connectionState: .connected,
        isMediaStarted: false,
        localMute: false,
        outputMute: false,
        routeSnapshot: ActiveRouteSnapshot(
            activeRoute: .multipeer,
            mediaRoute: .multipeer,
            availableRoutes: [.multipeer],
            isHandoverInProgress: false
        ),
        routes: [
            RTCRouteRuntimeStatus(
                route: .multipeer,
                state: .connected,
                isAvailable: true,
                availabilityReason: nil,
                capabilities: capabilities,
                isActiveRoute: true,
                isMediaRoute: true,
                selectedAudioCodec: .opus
            )
        ],
        packageReports: [
            RTCRuntimePackageReport(
                package: "Codec",
                kind: "runtime",
                generatedAt: 122,
                payload: Data([1, 2, 3])
            )
        ],
        configuration: CallRouteConfiguration(),
        audioPolicy: audioPolicy
    )
}

@Test func routeManagerBroadcastsRuntimeStatusWhenConnectionStarts() async throws {
    let multipeer = FakeRoute(kind: .multipeer)
    let configuration = CallRouteConfiguration(enabledRoutes: [.multipeer], preferredRoute: .multipeer)
    let request = makeRequest(
        configuration: configuration,
        audioPolicy: RTCAudioPolicy(preferredCodecs: [.pcm16])
    )
    let manager = RouteManager(routes: [multipeer], configuration: configuration)

    await manager.prepare(request)
    await manager.startConnection()

    let messages = relayMessages(multipeer.sentApplicationData).filter {
        $0.namespace == RTCRuntimeStatusTransport.namespace
    }
    let firstMessage = try #require(messages.first)
    let status = try #require(try RTCRuntimeStatusTransport.decode(firstMessage))
    #expect(status.reason == .connectionStarted)
    #expect(status.sessionID == request.sessionID)
    #expect(status.localPeer == request.localPeer)
    #expect(status.configuration == configuration)
    #expect(status.audioPolicy == request.audioPolicy)
    #expect(status.routes.first?.selectedAudioCodec == .pcm16)
}

@Test func routeManagerCanAttachPackageRuntimeReportsToBroadcastStatus() async throws {
    let multipeer = FakeRoute(kind: .multipeer)
    let manager = RouteManager(
        routes: [multipeer],
        configuration: CallRouteConfiguration(enabledRoutes: [.multipeer], preferredRoute: .multipeer),
        runtimeStatusPolicy: .init(periodicInterval: nil)
    )
    let report = RTCRuntimePackageReport(
        package: "AudioMixer",
        kind: "snapshot",
        generatedAt: 10,
        payload: Data([9])
    )

    await manager.prepare(makeRequest())
    await manager.startConnection()
    await manager.updateRuntimePackageReports([report])

    let statuses = try relayMessages(multipeer.sentApplicationData)
        .filter { $0.namespace == RTCRuntimeStatusTransport.namespace }
        .compactMap { try RTCRuntimeStatusTransport.decode($0) }
    let status = try #require(statuses.last)
    #expect(status.reason == .packageReportsChanged)
    #expect(status.packageReports.contains(report))
    #expect(status.packageReports.contains { $0.package == "RTC" && $0.kind == "network" })
}

@Test func packageSnapshotsCoalesceWithoutDelayingControlChanges() async throws {
    let route = FakeRoute(kind: .multipeer)
    let config = CallRouteConfiguration(enabledRoutes: [.multipeer], preferredRoute: .multipeer)
    let manager = RouteManager(routes: [route], configuration: config,
        runtimeStatusPolicy: .init(periodicInterval: 0.2))
    await manager.prepare(makeRequest(configuration: config)); await manager.startConnection()
    let before = route.sentApplicationData.count
    for index in 0..<100 {
        await manager.updateRuntimePackageReports([
            .init(package: "AudioMixer", kind: "snapshot", generatedAt: Double(index), payload: Data([UInt8(index)]))
        ])
    }
    #expect(
        route.sentApplicationData.count == before,
        "Repeated diagnostic snapshots must not serialize/send or query native stats immediately")
    await manager.setLocalMute(true)
    let statuses = relayMessages(route.sentApplicationData).compactMap { try? RTCRuntimeStatusTransport.decode($0) }
    #expect(statuses.last?.localMute == true, "User controls remain immediate")
    #expect(statuses.last?.packageReports.contains { $0.package == "AudioMixer" && $0.generatedAt == 99 } == true)
    let afterControl = route.sentApplicationData.count
    try await Task.sleep(for: .milliseconds(250))
    #expect(route.sentApplicationData.count > afterControl, "Periodic status still carries the latest report")
    await manager.stopConnection()
}
