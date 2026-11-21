import Foundation
import Testing
@testable import RTC

@Test func diagnosticsReportUnavailableMeasurementsWithoutInventingZeros() async throws {
    let manager = RouteManager(routes: [], runtimeStatusPolicy: .init(isAutomaticBroadcastEnabled: false))
    let report = await manager.networkDiagnostics()
    #expect(report.peers.isEmpty)
    let engine = NativeWebRTCEngine()
    let stats = await engine.networkStatistics(for: .init(rawValue: "missing"))
    #expect(stats.roundTripTime == nil)
    #expect(stats.bufferedBytes == nil)
    #expect(stats.packetLoss == nil)
    #expect(!stats.unavailableReason.isEmpty)
    let encoded = try RTCRuntimePackageReport.json(package: "RTC", kind: "network", payload: report)
    #expect(try encoded.decodeJSON(RTCNetworkDiagnostics.self) == report)
}

@Test func relayReportsTheAuthenticatedObservedPath() throws {
    func request(_ id: String) -> CallStartRequest {
        .init(
            sessionID: "group", localPeer: .init(id: .init(rawValue: id), displayName: id),
            credential: .derived(groupID: "group", secret: "secret"))
    }
    var sender = GroupRelay(request: request("a")), relay = GroupRelay(request: request("b")),
        receiver = GroupRelay(request: request("c"))
    let presence = try sender.make(.presence, now: 1)
    let accepted = relay.receive(presence, from: .init(rawValue: "a"), now: 1)
    let direct = try #require(accepted)
    #expect(direct.path.map(\.rawValue) == ["a", "b"])
    let forwarded = try #require(direct.forward)
    let received = receiver.receive(forwarded, from: .init(rawValue: "b"), now: 1)
    let relayed = try #require(received)
    #expect(relayed.path.map(\.rawValue) == ["a", "b", "c"])
    #expect(receiver.receive(forwarded, from: .init(rawValue: "impostor"), now: 1) == nil)
}
