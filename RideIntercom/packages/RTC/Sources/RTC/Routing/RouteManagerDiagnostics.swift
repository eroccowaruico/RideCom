import Foundation

extension RouteManager {
    func emitRouteSnapshot() { emit(.routeChanged(routeSnapshot())) }
    private func routeSnapshot() -> ActiveRouteSnapshot {
        ActiveRouteSnapshot(activeRoute: activeRoute, mediaRoute: activeRoute, availableRoutes: availableRoutes,
                            isHandoverInProgress: connectionState == .reconnecting)
    }
    func sendRuntimeStatus(reason: RTCRuntimeStatusReason) async {
        guard runtimeStatusPolicy.isAutomaticBroadcastEnabled else { return }
        let token = generation
        let network = await networkDiagnostics()
        guard token == generation else { return }
        emit(.networkDiagnosticsChanged(network))
        var status = makeRuntimeStatus(reason: reason)
        if let report = try? RTCRuntimePackageReport.json(package: "RTC", kind: "network", payload: network) {
            status.packageReports.append(report)
        }
        guard let message = try? RTCRuntimeStatusTransport.makeMessage(status) else { return }
        await sendApplicationData(message)
    }
    public func networkDiagnostics() async -> RTCNetworkDiagnostics {
        let token = generation
        var diagnostics: [RTCRouteNetworkDiagnostics] = []
        for kind in started.sorted(by: { $0.rawValue < $1.rawValue }) {
            if let route = routes[kind] { diagnostics.append(await route.networkDiagnostics()) }
            guard generation == token else {
                return .init(generatedAt: Date().timeIntervalSince1970, eventDrops: .init(), routes: [], peers: [])
            }
        }
        let now = Date().timeIntervalSince1970
        let paths = observedPaths.values.filter { path in
            now - path.observedAt < GroupRelay.presenceLifetime && availableRoutes.contains(path.route)
                && path.path.dropLast().last.map { routeMembers[path.route, default: []].contains($0) } == true
        }
        return .init(generatedAt: now, eventDrops: eventDropReport, routes: diagnostics,
                     peers: paths.sorted { $0.peerID.rawValue < $1.peerID.rawValue },
                     outboundAudioDispatch: outboundAudioDispatch)
    }

    private func makeRuntimeStatus(reason: RTCRuntimeStatusReason) -> RTCRuntimeStatus {
        let request = request ?? CallStartRequest(
            sessionID: "",
            localPeer: PeerDescriptor(id: PeerID(rawValue: ""), displayName: ""),
            configuration: configuration
        )
        return RTCRuntimeStatus(
            reason: reason,
            generatedAt: Date().timeIntervalSince1970,
            sessionID: request.sessionID,
            localPeer: request.localPeer,
            expectedPeers: request.expectedPeers,
            connectionState: connectionState,
            isMediaStarted: isMediaStarted,
            localMute: localMute,
            outputMute: outputMute,
            routeSnapshot: routeSnapshot(),
            routes: routes.values
                .sorted { $0.kind.rawValue < $1.kind.rawValue }
                .map { route in
                    RTCRouteRuntimeStatus(
                        route: route.kind,
                        state: routeStates[route.kind] ?? .idle,
                        isAvailable: availableRoutes.contains(route.kind),
                        availabilityReason: routeAvailabilities[route.kind]?.reason,
                        capabilities: route.capabilities,
                        isActiveRoute: activeRoute == route.kind,
                        isMediaRoute: activeRoute == route.kind,
                        selectedAudioCodec: selectedAudioCodec(for: route, request: request)
                    )
                },
            packageReports: runtimePackageReports,
            configuration: configuration,
            audioPolicy: request.audioPolicy
        )
    }

    private func selectedAudioCodec(
        for route: RTCCallRoute,
        request: CallStartRequest
    ) -> RTCAudioCodecIdentifier? {
        let supported = route.capabilities.supportedAudioCodecs
        return request.audioPolicy.preferredCodecs.first { supported.contains($0) } ?? supported.first
    }
}
