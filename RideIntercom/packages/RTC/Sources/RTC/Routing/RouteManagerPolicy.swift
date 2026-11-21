import Foundation

extension RouteManager {
    func allowsAudio(from peerID: PeerID, now: TimeInterval) -> Bool {
        guard let membership = relay?.membershipID(for: peerID, now: now) else { return false }
        switch request?.audioPolicy.peerPolicy {
        case .groupMembers: return true
        case .admittedMemberships(let admitted): return admitted[peerID] == membership
        case nil: return false
        }
    }

    func forwardingExclusion(from kind: RouteKind, body: RelayBody, sender: PeerID) -> RouteKind? {
        // SFU already fans out to every subscriber. Local links may be a chain.
        if kind == .webRTC { return .webRTC }
        guard case .audio = body, kind == .multipeer else { return nil }
        // One ready gateway per directly connected Local neighborhood.
        // During topology convergence duplicate suppression still protects playback.
        var candidates = (relay?.internetGateways(now: ProcessInfo.processInfo.systemUptime) ?? [])
            .intersection(routeMembers[.multipeer, default: []])
        if relay?.internetReady == true, let id = request?.localPeer.id { candidates.insert(id) }
        let elected = candidates.min { $0.rawValue < $1.rawValue }
        let originHasInternet = relay?.internetGateways(now: ProcessInfo.processInfo.systemUptime).contains(sender)
            == true
        return originHasInternet || elected != request?.localPeer.id ? .webRTC : nil
    }
}
