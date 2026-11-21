import Foundation
import Logging
import RTC

private struct PeerMuteStateApplicationPayload: Codable, Equatable {
    let isMuted: Bool
}

private struct PeerMetadataApplicationPayload: Codable, Equatable {
    let activeCodec: AudioCodecIdentifier?
}

extension RideIntercomCallSessionAdapter {
    private nonisolated static let keepaliveNamespace = "rideintercom.keepalive"
    private nonisolated static let peerMuteStateNamespace = "rideintercom.peerMuteState"

    static func makeKeepaliveMessage(activeCodec: AudioCodecIdentifier) -> ApplicationDataMessage {
        let payload = try? JSONEncoder().encode(PeerMetadataApplicationPayload(activeCodec: activeCodec))
        return ApplicationDataMessage(namespace: keepaliveNamespace, payload: payload ?? Data(), delivery: .reliable)
    }

    static func makePeerMuteStateMessage(isMuted: Bool) -> ApplicationDataMessage? {
        let state = PeerMuteStateApplicationPayload(isMuted: isMuted)
        guard let payload = try? JSONEncoder().encode(state) else { return nil }
        return ApplicationDataMessage(namespace: peerMuteStateNamespace, payload: payload, delivery: .reliable)
    }

    static func makeAppEvent(
        peerID: String, applicationData message: RTC.ApplicationDataMessage
    ) -> TransportEvent {
        if let status = try? RTCRuntimeStatusTransport.decode(message) {
            return .remoteRuntimeStatus(peerID: peerID, status: status)
        }
        if message.namespace == peerMuteStateNamespace,
           let payload = try? JSONDecoder().decode(PeerMuteStateApplicationPayload.self, from: message.payload) {
            return .remotePeerMuteState(peerID: peerID, isMuted: payload.isMuted)
        }
        if message.namespace == keepaliveNamespace,
           let payload = try? JSONDecoder().decode(PeerMetadataApplicationPayload.self, from: message.payload) {
            return .remotePeerMetadata(peerID: peerID, activeCodec: payload.activeCodec)
        }

        return .receivedApplicationData(peerID: peerID, message: message)
    }

    func handleRTCError(_ error: RTC.CallSessionError) {
        switch error {
        case .noEnabledRoute:
            onEvent?(.linkFailed(willRetry: false))
        case .connectionFailed(let route, let reason):
            if route == .webRTC { onEvent?(.serviceError(reason)) }
        case .connectionBlocked(let route, let reason):
            if route == .webRTC { onEvent?(.serviceBlocked(reason)) }
        case .handshakeRejected(let route):
            // The rejected peer is never authenticated; the call itself continues.
            AppLoggers.rtc.warning("rtc.handshake.rejected", metadata: HandshakeLog.rejected(route: route))
        case .routeUnavailable,
             .signalingUnavailable,
             .unsupportedApplicationDataDelivery,
             .unsupportedAudioCodec:
            break
        }
    }

    func handleRTCStateChanged(_ state: RTC.CallConnectionState) {
        switch state {
        case .idle:
            publishLocalStatus(.idle)
        case .preparing, .connecting:
            publishLocalStatus(.advertisingBrowsing)
        case .connected, .mediaReady:
            publishLocalStatus(.connected)
        case .reconnecting:
            onEvent?(.linkFailed(willRetry: true))
        case .disconnected:
            onEvent?(.disconnected)
        case .failed:
            onEvent?(.linkFailed(willRetry: false))
        }
    }

    private func publishLocalStatus(_ status: LocalNetworkStatus) {
        onEvent?(.localNetworkStatus(LocalNetworkEvent(status: status, occurredAt: Date().timeIntervalSince1970)))
    }

    static func routeDebugName(_ route: RTC.RouteKind?) -> String {
        switch route {
        case .multipeer:
            "LocalCallRoute"
        case .webRTC:
            "WebRTCInternetRoute"
        case nil:
            "RTC RouteManager"
        }
    }
}

enum HandshakeLog {
    static func rejected(route: RTC.RouteKind) -> Logging.Logger.Metadata {
        .event("rtc.handshake.rejected", ["route": "\(route.rawValue)"])
    }
}
