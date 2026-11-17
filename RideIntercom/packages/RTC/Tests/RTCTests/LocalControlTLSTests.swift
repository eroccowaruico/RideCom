import Foundation
import Network
import Synchronization
import Testing
@testable import RTC

/// Real QUIC on this machine: the experiments that decide whether local control can leave
/// MultipeerConnectivity. Nothing here is simulated except the distance between the two ends.
struct LocalControlTLSTests {
    /// A listening end and a dialing end, each with its own throwaway identity and event log.
    private final class Pair: Sendable {
        let queue = DispatchQueue(label: "LocalControlTLSTests")
        let listener: NWListener
        let listenerIdentity: LocalControlIdentity
        let dialerIdentity: LocalControlIdentity
        private final class Record: Sendable {
            let groups = Mutex<[NWConnectionGroup]>([])
            let links = Mutex<[String: LocalControlLink]>([:])
            let events = Mutex<[String: [LocalControlLink.Event]]>([:])
        }
        private let record = Record()

        init(listenerCredential: RTCCredential, dialerCredential: RTCCredential) async throws {
            let listenerIdentity = try LocalControlIdentity.make(), dialerIdentity = try LocalControlIdentity.make()
            self.listenerIdentity = listenerIdentity; self.dialerIdentity = dialerIdentity
            let listener = try NWListener(using: LocalControlTLS.parameters(identity: listenerIdentity), on: .any)
            self.listener = listener
            let queue = queue, record = record
            // A QUIC listener hands over the connection as a group; its streams arrive through the group.
            // (A plain `newConnectionHandler` yields a connection that becomes ready and never receives.)
            listener.newConnectionGroupHandler = { group in
                record.groups.withLock { $0.append(group) }
                group.newConnectionHandler = { stream in
                    let link = LocalControlLink(connection: stream, identity: listenerIdentity, credential: listenerCredential,
                                                localID: .init(rawValue: "listener"), nonce: "listener-nonce", queue: queue) { event in
                        record.events.withLock { $0["listener", default: []].append(event) }
                    }
                    record.links.withLock { $0["listener"] = link }
                    link.start()
                }
                group.start(queue: queue)
            }
            let port = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NWEndpoint.Port, any Error>) in
                let resumed = Mutex(false)
                listener.stateUpdateHandler = { state in
                    switch state {
                    case .ready:
                        if let port = listener.port, !resumed.withLock({ done in defer { done = true }; return done }) {
                            continuation.resume(returning: port)
                        }
                    case .failed(let error):
                        if !resumed.withLock({ done in defer { done = true }; return done }) { continuation.resume(throwing: error) }
                    default: break
                    }
                }
                listener.start(queue: queue)
            }
            let dialer = LocalControlLink(connection: NWConnection(host: "127.0.0.1", port: port,
                                                                   using: LocalControlTLS.parameters(identity: dialerIdentity)),
                                          identity: dialerIdentity, credential: dialerCredential,
                                          localID: .init(rawValue: "dialer"), nonce: "dialer-nonce", queue: queue) { event in
                record.events.withLock { $0["dialer", default: []].append(event) }
            }
            record.links.withLock { $0["dialer"] = dialer }
            dialer.start()
        }

        func events(_ end: String) -> [LocalControlLink.Event] { record.events.withLock { $0[end] ?? [] } }
        func link(_ end: String) -> LocalControlLink? { record.links.withLock { $0[end] } }
        func wait(_ condition: @Sendable () -> Bool) async {
            for _ in 0..<1_000 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
        }
        func stop() {
            record.links.withLock { $0.values.forEach { $0.close() } }
            record.groups.withLock { $0.forEach { $0.cancel() } }
            listener.cancel()
        }
    }

    private let credential = RTCCredential.derived(groupID: "local-control-tls", secret: "test-only")

    @Test(.timeLimit(.minutes(1)))
    func twoMembersAuthenticateEachOtherAndExchangeMessagesInOrder() async throws {
        let pair = try await Pair(listenerCredential: credential, dialerCredential: credential)
        defer { pair.stop() }
        await pair.wait { pair.events("listener").count >= 1 && pair.events("dialer").count >= 1 }
        #expect(pair.events("listener") == [.authenticated(.init(rawValue: "dialer"), nonce: "dialer-nonce")])
        #expect(pair.events("dialer") == [.authenticated(.init(rawValue: "listener"), nonce: "listener-nonce")])
        #expect(pair.listenerIdentity.fingerprint != pair.dialerIdentity.fingerprint)

        let fromDialer = (0..<20).map { Data("d\($0)".utf8) } + [Data(repeating: 1, count: LocalControlFraming.maximumMessageBytes)]
        let fromListener = (0..<20).map { Data("l\($0)".utf8) }
        let dialer = try #require(pair.link("dialer")), listener = try #require(pair.link("listener"))
        fromDialer.forEach(dialer.send)
        fromListener.forEach(listener.send)
        await pair.wait { pair.events("listener").count == 1 + fromDialer.count && pair.events("dialer").count == 1 + fromListener.count }
        #expect(Array(pair.events("listener").dropFirst()) == fromDialer.map { .message($0) })
        #expect(Array(pair.events("dialer").dropFirst()) == fromListener.map { .message($0) })

        dialer.close()
        await pair.wait { pair.events("listener").last == .closed && pair.events("dialer").last == .closed }
        #expect(pair.events("dialer").filter { $0 == .closed }.count == 1)
        #expect(pair.events("listener").filter { $0 == .closed }.count == 1)
    }

    @Test(.timeLimit(.minutes(1)))
    func aPeerWithoutTheGroupKeyIsClosedWithoutEverBeingHeard() async throws {
        let stranger = RTCCredential(groupHash: credential.groupHash, sharedSecret: Data(repeating: 9, count: 32))
        let pair = try await Pair(listenerCredential: credential, dialerCredential: stranger)
        defer { pair.stop() }
        await pair.wait { pair.events("listener").last == .closed && pair.events("dialer").last == .closed }
        #expect(pair.events("listener") == [.closed], "TLS succeeded, the handshake did not")
        #expect(pair.events("dialer") == [.closed])
    }
}
