import Foundation
import RTC
import RTCNativeWebRTC
import Synchronization

nonisolated final class InternetRouteConfigurationSource: Sendable {
    private let stored: Mutex<RTC.CloudflareRealtimeConfiguration?>

    init(_ configuration: RTC.CloudflareRealtimeConfiguration?) {
        stored = Mutex(configuration)
    }

    var current: RTC.CloudflareRealtimeConfiguration? { stored.withLock { $0 } }

    func supply(_ configuration: RTC.CloudflareRealtimeConfiguration?) {
        stored.withLock { $0 = configuration }
    }
}

extension RideIntercomCallSessionAdapter {
    typealias SessionFactory = @MainActor (
        RTC.RTCAudioPolicy, Set<RTC.RouteKind>, InternetRouteConfigurationSource
    ) -> RTC.CallSession

    static func makeRTCRequest(
        from group: IntercomGroup, memberID: String, routes: Set<RTC.RouteKind>, audioPolicy: RTC.RTCAudioPolicy
    ) -> RTC.CallStartRequest {
        let localMember = group.members.first(where: { $0.id == memberID })
        let localPeer = RTC.PeerDescriptor(
            id: RTC.PeerID(rawValue: memberID),
            displayName: localMember?.displayName ?? memberID
        )
        let expectedPeers = group.members
            .filter { $0.id != memberID }
            .map { RTC.PeerDescriptor(id: RTC.PeerID(rawValue: $0.id), displayName: $0.displayName) }
        return RTC.CallStartRequest(
            sessionID: group.id.uuidString,
            localPeer: localPeer,
            expectedPeers: expectedPeers,
            credential: group.accessSecret.map { RTC.RTCCredential.derived(groupID: group.id.uuidString, secret: $0) },
            configuration: makeRouteConfiguration(enabledRoutes: routes),
            audioPolicy: audioPolicy
        )
    }

    nonisolated static func makeRTCSession(
        audioPolicy: RTC.RTCAudioPolicy,
        enabledRoutes: Set<RTC.RouteKind>,
        internetConfiguration: InternetRouteConfigurationSource
    ) -> RTC.CallSession {
        RTC.CallSessionFactory.makeSession(
            RTC.CallSessionFactoryConfiguration(
                routeConfiguration: makeRouteConfiguration(enabledRoutes: enabledRoutes),
                audioPolicy: audioPolicy,
                webRTC: RTC.WebRTCRouteFactoryConfiguration(
                    cloudflareConfigurationProvider: { _ in internetConfiguration.current },
                    signalingClientFactory: {
                        CloudflareRealtimeSignalingClient(currentConfiguration: { internetConfiguration.current })
                    },
                    engineFactory: { WebRTCNativeEngine() }
                )
            )
        )
    }

    nonisolated static func makeRouteConfiguration(
        enabledRoutes: Set<RTC.RouteKind>
    ) -> RTC.CallRouteConfiguration {
        let preferredRoute: RTC.RouteKind
        if enabledRoutes.contains(.multipeer) {
            preferredRoute = .multipeer
        } else if enabledRoutes.contains(.webRTC) {
            preferredRoute = .webRTC
        } else {
            preferredRoute = .multipeer
        }

        return RTC.CallRouteConfiguration(
            enabledRoutes: enabledRoutes,
            preferredRoute: preferredRoute
        )
    }
}
