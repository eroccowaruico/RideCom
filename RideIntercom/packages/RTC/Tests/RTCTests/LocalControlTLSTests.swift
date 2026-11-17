import Foundation
import Network
import Synchronization
import Testing
@testable import RTC

struct LocalControlTLSTests {
    /// The decisive experiment for moving local control off MultipeerConnectivity: two throwaway
    /// identities open one QUIC stream on this machine, and each end sees the other's certificate.
    @Test(.timeLimit(.minutes(1)))
    func twoThrowawayIdentitiesOpenAQUICStreamAndSeeEachOthersCertificate() async throws {
        let listenerIdentity = try LocalControlIdentity.make(), dialerIdentity = try LocalControlIdentity.make()
        let seenByListener = Mutex<Data?>(nil), seenByDialer = Mutex<Data?>(nil)
        let queue = DispatchQueue(label: "LocalControlTLSTests")

        let listener = try NWListener(using: LocalControlTLS.parameters(identity: listenerIdentity) { fingerprint in
            seenByListener.withLock { $0 = fingerprint }
        }, on: .any)
        defer { listener.cancel() }
        let accepted = AsyncStream<NWConnection>.makeStream()
        let groups = Mutex<[NWConnectionGroup]>([])
        // A QUIC listener hands over the connection as a group; its streams arrive through the group.
        // (A plain `newConnectionHandler` yields a connection that becomes ready and never receives.)
        listener.newConnectionGroupHandler = { group in
            groups.withLock { $0.append(group) }
            group.newConnectionHandler = { accepted.continuation.yield($0) }
            group.start(queue: queue)
        }
        defer { groups.withLock { $0.forEach { $0.cancel() } } }
        let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWEndpoint.Port, any Error>) in
            let resumed = Mutex(false)
            listener.stateUpdateHandler = { state in
                let first = resumed.withLock { done in defer { done = true }; return !done }
                switch state {
                case .ready: if first, let port = listener.port { continuation.resume(returning: port) }
                case .failed(let error): if first { continuation.resume(throwing: error) }
                default: resumed.withLock { $0 = false }
                }
            }
            listener.start(queue: queue)
        }

        let dialer = NWConnection(host: "127.0.0.1", port: port, using: LocalControlTLS.parameters(identity: dialerIdentity) { fingerprint in
            seenByDialer.withLock { $0 = fingerprint }
        })
        defer { dialer.cancel() }
        dialer.start(queue: queue)
        // QUIC opens the stream with its first bytes; the listener sees the stream only then.
        let request = Data("hello".utf8), reply = Data("welcome".utf8)
        dialer.send(content: request, completion: .contentProcessed { _ in })

        var incoming: NWConnection?
        for await connection in accepted.stream { incoming = connection; break }
        let server = try #require(incoming)
        defer { server.cancel() }
        server.start(queue: queue)
        #expect(try await receive(server, count: request.count) == request)
        server.send(content: reply, completion: .contentProcessed { _ in })
        #expect(try await receive(dialer, count: reply.count) == reply)

        #expect(seenByDialer.withLock { $0 } == listenerIdentity.fingerprint)
        #expect(seenByListener.withLock { $0 } == dialerIdentity.fingerprint)
        #expect(listenerIdentity.fingerprint != dialerIdentity.fingerprint)
    }

    private func receive(_ connection: NWConnection, count: Int) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                if let data, data.count == count { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? NWError.posix(.ECONNRESET)) }
            }
        }
    }
}
