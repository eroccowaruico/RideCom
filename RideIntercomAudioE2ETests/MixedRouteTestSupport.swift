#if DEBUG
import Foundation
import XCTest
@testable import RTC

@MainActor
func waitForMixedRoute(
    _ description: String, timeout: Duration = .seconds(12), condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
    _ = try XCTUnwrap(condition() ? true : nil, description)
}

/// Count control from the actual QUIC route independently of the rendezvous.
@MainActor
final class LocalControlCounter {
    private(set) var receivedCount = 0
    private var task: Task<Void, Never>?

    init(route: LocalCallRoute, peer: PeerID) {
        let events = route.events
        task = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                if case .receivedApplicationData(.multipeer, let data) = event,
                   data.peerID == peer, data.message.delivery == .reliable {
                    receivedCount += 1
                }
            }
        }
    }

    func stop() { task?.cancel() }
}
#endif
