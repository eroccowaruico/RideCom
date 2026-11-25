import Foundation

extension RouteManager {
    public func retryInternetRouteAfterCredentialChange() async {
        guard request != nil, blocked[.webRTC] == .deviceCredentialRejected,
              let internet = routes[.webRTC] as? any DeviceCredentialRecoveringRoute else { return }
        await internet.requestCredentialRecovery()
    }

    func retryDueRoutes(at now: TimeInterval) async {
        guard let request else { return }
        let token = generation
        for (kind, retry) in retries where now >= retry.deadline && retries[kind]?.deadline == retry.deadline {
            retries[kind]?.beginAttempt()
            started.remove(kind)
            await routes[kind]?.prepare(request)
            guard generation == token else { return }
            await start(kind)
            guard generation == token else { return }
        }
    }
}
