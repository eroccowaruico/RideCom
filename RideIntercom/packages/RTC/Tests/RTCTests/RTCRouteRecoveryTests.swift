import Foundation
import Testing
@testable import RTC

@Test func rejectedHandshakeIsForwardedAsItsOwnError() async throws {
    let local = FakeRoute(kind: .multipeer)
    let configuration = CallRouteConfiguration(
        enabledRoutes: [.multipeer], preferredRoute: .multipeer, selectionMode: .singleRoute, fallbackDelay: 0)
    let manager = RouteManager(routes: [local], configuration: configuration)
    let recorded = CallEventRecorder(), events = manager.events
    let listener = Task { for await event in events { await recorded.append(event) } }
    defer { listener.cancel() }
    await manager.prepare(makeRequest(configuration: configuration)); await manager.startConnection()
    local.yield(.error(.multipeer, .handshakeRejected(.multipeer)))
    for _ in 0..<100 where !(await recorded.values.contains(.error(.handshakeRejected(.multipeer)))) {
        try await Task.sleep(for: .milliseconds(10))
    }
    let values = await recorded.values
    #expect(values.contains(.error(.handshakeRejected(.multipeer))))
    #expect(!values.contains { if case .error(.connectionFailed) = $0 { true } else { false } })
}

/// Waiting alone is not a lost connection: while a started route is still searching, a failed
/// route that will retry leaves the call connecting. Reconnecting starts once nothing is attempting.
@Test func aRouteStillSearchingKeepsTheCallConnectingWhileAnotherRetries() async throws {
    let internet = FakeRoute(kind: .webRTC), local = FakeRoute(kind: .multipeer)
    let configuration = CallRouteConfiguration(enabledRoutes: [.multipeer, .webRTC], preferredRoute: .multipeer,
        selectionMode: .automaticFallbackAndRestore, fallbackDelay: 0)
    let manager = RouteManager(routes: [internet, local], configuration: configuration)
    let recorded = CallEventRecorder(), events = manager.events
    let listener = Task { for await event in events { await recorded.append(event) } }
    defer { listener.cancel() }
    await manager.prepare(makeRequest(configuration: configuration)); await manager.startConnection()
    for _ in 0..<100 where internet.startConnectionCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
    internet.yield(.stateChanged(.webRTC, .failed))
    try await Task.sleep(for: .milliseconds(200))
    #expect(!(await recorded.values).contains(.stateChanged(.reconnecting)))
    local.yield(.stateChanged(.multipeer, .failed))
    for _ in 0..<100 where !(await recorded.values).contains(.stateChanged(.reconnecting)) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect((await recorded.values).contains(.stateChanged(.reconnecting)))
}

@Test(arguments: [false, true])
func blockedRouteWaitsForExplicitRestartAndPreservesOtherRoutes(localAvailable: Bool) async throws {
    let internet = FakeRoute(kind: .webRTC), local = FakeRoute(kind: .multipeer)
    let configuration = CallRouteConfiguration(enabledRoutes: localAvailable ? [.multipeer, .webRTC] : [.webRTC],
        preferredRoute: .webRTC, selectionMode: localAvailable ? .automaticFallbackAndRestore : .singleRoute,
        fallbackDelay: 0)
    let manager = RouteManager(routes: localAvailable ? [internet, local] : [internet], configuration: configuration)
    let recorded = CallEventRecorder(), events = manager.events
    let listener = Task { for await event in events { await recorded.append(event) } }
    defer { listener.cancel() }
    let request = makeRequest(configuration: configuration)
    await manager.prepare(request); await manager.startConnection()
    if localAvailable { local.yield(.stateChanged(.multipeer, .mediaReady)) }
    internet.yield(.connectionBlocked(.webRTC, "End the existing call"))
    internet.yield(.stateChanged(.webRTC, .failed))
    try await Task.sleep(for: .milliseconds(2300))
    #expect(internet.prepareCount == 1 && internet.startConnectionCount == 1)
    let values = await recorded.values
    #expect(values.contains(.error(.connectionBlocked(.webRTC, "End the existing call"))))
    if localAvailable {
        #expect(local.startConnectionCount == 1)
        #expect(await manager.maintenanceDeadline != nil)
        #expect(
            values.contains {
                if case .routeChanged(let snapshot) = $0 {
                    snapshot.availableRoutes.contains(.multipeer)
                } else {
                    false
                }
            })
    } else {
        #expect(values.contains(.stateChanged(.failed)))
        #expect(!values.contains(.stateChanged(.reconnecting)))
        #expect(await manager.maintenanceDeadline == nil, "User action wait must not keep a periodic timer alive")
    }
    await manager.prepare(request); await manager.startConnection()
    #expect(internet.startConnectionCount == 2)
    #expect(await manager.maintenanceDeadline != nil)
    await manager.stopConnection()
}

private actor CallEventRecorder {
    var values: [CallSessionEvent] = []
    func append(_ event: CallSessionEvent) { values.append(event) }
}

#if !os(watchOS)
    @Test func localDiscoveryCanCancelAndRestartWithPendingCallbacks() async {
        let route = LocalCallRoute()
        for _ in 0..<12 {
            await route.prepare(makeRequest(credential: .derived(groupID: "restart", secret: "fixture")))
            await route.startConnection()
            await Task.yield()
            await route.stopConnection()
            await route.stopConnection()
        }
    }
#endif
