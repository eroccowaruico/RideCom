import Foundation
import Synchronization
import Testing
@testable import RTC

@Test(arguments: [RouteKind.multipeer, .webRTC])
func fallbackStartsWhileThePreferredRouteIsStillStarting(preferredKind: RouteKind) async throws {
    let alternateKind: RouteKind = preferredKind == .multipeer ? .webRTC : .multipeer
    let (entered, reportEntered) = AsyncStream<Void>.makeStream()
    let (release, resumePreferred) = AsyncStream<Void>.makeStream()
    let preferred = FakeRoute(kind: preferredKind, onStart: {
        reportEntered.yield()
        for await _ in release { break }
    })
    let alternateStarted = Mutex(false)
    let alternate = FakeRoute(kind: alternateKind, onStart: {
        alternateStarted.withLock { $0 = true }
    })
    let configuration = CallRouteConfiguration(enabledRoutes: [preferredKind, alternateKind],
        preferredRoute: preferredKind, selectionMode: .automaticFallback, fallbackDelay: 0)
    let manager = RouteManager(routes: [preferred, alternate], configuration: configuration)
    await manager.prepare(makeRequest(configuration: configuration))
    let start = Task { await manager.startConnection() }
    defer { resumePreferred.finish(); start.cancel() }
    for await _ in entered { break }

    for _ in 0..<100 where !alternateStarted.withLock({ $0 }) {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(alternateStarted.withLock { $0 })
    resumePreferred.finish()
    await start.value
    await manager.stopConnection()
}

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
    for _ in 0..<100 where (await recorded.routeSnapshots).count < 2 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect((await recorded.routeSnapshots).count >= 2)
    #expect((await recorded.routeSnapshots).last?.isHandoverInProgress == false)
    #expect(!(await recorded.values).contains(.stateChanged(.reconnecting)))
    local.yield(.stateChanged(.multipeer, .failed))
    for _ in 0..<100 where (await recorded.routeSnapshots).count < 3 {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect((await recorded.values).contains(.stateChanged(.reconnecting)))
    #expect((await recorded.routeSnapshots).last?.isHandoverInProgress == true)

    internet.yield(.stateChanged(.webRTC, .mediaReady))
    for _ in 0..<100 where (await recorded.routeSnapshots).last?.activeRoute != .webRTC {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect((await recorded.routeSnapshots).last?.activeRoute == .webRTC)
    #expect((await recorded.routeSnapshots).last?.isHandoverInProgress == false)
    await manager.stopConnection()
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
    internet.yield(.stateChanged(.webRTC, .mediaReady))
    // Transport shutdown may still be in progress. The blocked event itself carries the terminal outcome.
    internet.yield(.connectionBlocked(.webRTC, "End the existing call"))
    internet.yield(.stateChanged(.webRTC, .mediaReady))
    try await Task.sleep(for: .milliseconds(2300))
    #expect(internet.prepareCount == 1 && internet.startConnectionCount == 1)
    let internetSends = internet.sentApplicationData.count
    await manager.sendApplicationData(.init(namespace: "test", payload: Data([1])))
    #expect(internet.sentApplicationData.count == internetSends)
    let values = await recorded.values
    #expect(values.contains(.error(.connectionBlocked(.webRTC, "End the existing call"))))
    #expect((await recorded.routeSnapshots).last?.availableRoutes.contains(.webRTC) == false)
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
    var routeSnapshots: [ActiveRouteSnapshot] {
        values.compactMap { if case .routeChanged(let snapshot) = $0 { snapshot } else { nil } }
    }
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
