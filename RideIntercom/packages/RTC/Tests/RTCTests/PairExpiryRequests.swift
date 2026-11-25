import Foundation
import Synchronization

// Forward requests to the local Worker and record only the matching response.
final class PairExpiryRequests: URLProtocol, @unchecked Sendable {
    private struct Renewal: Decodable { let sessionId: String; let continuationOnly: Bool? }
    private struct State {
        var armed = false
        var rejectedSession: String?
        var didContinueAfterPullRejection = false
    }
    private let forwarding = Mutex<Task<Void, Never>?>(nil)
    private static let state = Mutex(State())
    static var didContinueAfterPullRejection: Bool { state.withLock { $0.didContinueAfterPullRejection } }
    static func arm() { state.withLock { $0 = State(armed: true) } }

    override static func canInit(with request: URLRequest) -> Bool {
        guard request.httpMethod == "POST", let url = request.url else { return false }
        return (url.lastPathComponent == "pull" || url.lastPathComponent == "renew") && state.withLock { $0.armed }
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = self.request
        forwarding.withLock {
            $0 = Task { @Sendable [weak self] in
                do {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    guard !Task.isCancelled, let self else { return }
                    Self.record(data, response: response, request: request)
                    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                    client?.urlProtocol(self, didLoad: data)
                    client?.urlProtocolDidFinishLoading(self)
                } catch {
                    guard !Task.isCancelled, let self else { return }
                    client?.urlProtocol(self, didFailWithError: error)
                }
            }
        }
    }

    override func stopLoading() { forwarding.withLock { $0?.cancel(); $0 = nil } }

    private static func record(_ data: Data, response: URLResponse, request: URLRequest) {
        guard let url = request.url, let response = response as? HTTPURLResponse else { return }
        let session = url.deletingLastPathComponent().lastPathComponent
        state.withLock {
            switch (url.lastPathComponent, response.statusCode) {
            case ("pull", 401): $0.rejectedSession = session
            case ("renew", 200):
                if let reply = try? JSONDecoder().decode(Renewal.self, from: data),
                   reply.continuationOnly == true, reply.sessionId == session, $0.rejectedSession == session {
                    $0.didContinueAfterPullRejection = true
                }
            default: break
            }
        }
    }
}
