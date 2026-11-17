import Foundation
import Synchronization
import Testing
@testable import RTC

/// Real Bonjour discovery and real QUIC between transports in this process.
struct LocalControlTransportTests {
    private final class End: Sendable {
        let id: PeerID
        private let log = Mutex<[LocalControlEvent]>([])
        let transport: LocalControlTransport
        init(_ name: String, credential: RTCCredential) {
            id = .init(rawValue: name)
            let box = Box()
            transport = LocalControlTransport(localID: id, credential: credential, nonce: name + "-nonce") { event in box.end?.record(event) }
            box.end = self
        }
        private final class Box: @unchecked Sendable { weak var end: End? }
        private func record(_ event: LocalControlEvent) { log.withLock { $0.append(event) } }
        var events: [LocalControlEvent] { log.withLock { $0 } }
        var members: Set<PeerID> {
            Set(events.reversed().lazy.compactMap { event -> [PeerID]? in
                if case .members(let peers) = event { return peers }
                return nil
            }.first ?? [])
        }
        func messages(from peer: PeerID) -> [Data] {
            events.compactMap { if case .message(let data, peer) = $0 { return data }; return nil }
        }
    }

    private func eventually(_ condition: @Sendable () -> Bool) async {
        for _ in 0..<3_000 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test(.timeLimit(.minutes(2)))
    func membersOfOneGroupFindEachOtherAndNobodyElse() async throws {
        let group = RTCCredential.derived(groupID: "control-" + UUID().uuidString, secret: "test-only")
        let other = RTCCredential.derived(groupID: "control-" + UUID().uuidString, secret: "test-only")
        // Same group name on the air, different key: discovery matches, the handshake must not.
        let impostor = RTCCredential(groupHash: group.groupHash, sharedSecret: Data(repeating: 3, count: 32))
        let a = End("a", credential: group), b = End("b", credential: group), c = End("c", credential: group)
        let outsider = End("outsider", credential: other), stranger = End("stranger", credential: impostor)
        let all = [a, b, c, outsider, stranger]
        defer { all.forEach { $0.transport.stop() } }
        all.forEach { $0.transport.start() }

        await eventually { a.members == [b.id, c.id] && b.members == [a.id, c.id] && c.members == [a.id, b.id] }
        #expect(a.members == [b.id, c.id])
        #expect(b.members == [a.id, c.id])
        #expect(c.members == [a.id, b.id])
        #expect(a.events.contains(.authenticated(b.id, nonce: "b-nonce")), "The handshake carries the peer's audio listener nonce")

        a.transport.send(Data("from a".utf8))
        b.transport.send(Data("from b 1".utf8)); b.transport.send(Data("from b 2".utf8))
        await eventually { c.messages(from: a.id).count == 1 && c.messages(from: b.id).count == 2 && a.messages(from: b.id).count == 2 }
        #expect(c.messages(from: a.id) == [Data("from a".utf8)])
        #expect(c.messages(from: b.id) == [Data("from b 1".utf8), Data("from b 2".utf8)])
        #expect(a.messages(from: b.id) == [Data("from b 1".utf8), Data("from b 2".utf8)])
        #expect(a.messages(from: a.id).isEmpty)

        #expect(outsider.members.isEmpty && stranger.members.isEmpty)
        for end in [outsider, stranger] {
            #expect(!end.events.contains { if case .message = $0 { return true }; return false })
            #expect(!end.events.contains { if case .authenticated = $0 { return true }; return false })
        }
        for end in [a, b, c] {
            #expect(!end.events.contains(.authenticated(outsider.id, nonce: "outsider-nonce")))
            #expect(!end.events.contains(.authenticated(stranger.id, nonce: "stranger-nonce")))
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func aMemberWhoLeavesIsLostAndFoundAgainWhenTheyReturn() async throws {
        let group = RTCCredential.derived(groupID: "control-" + UUID().uuidString, secret: "test-only")
        let a = End("a", credential: group), b = End("b", credential: group)
        defer { a.transport.stop(); b.transport.stop() }
        a.transport.start(); b.transport.start()
        await eventually { a.members == [b.id] && b.members == [a.id] }
        #expect(a.members == [b.id])

        b.transport.stop()
        await eventually { a.members.isEmpty && a.events.last == .state(.disconnected) }
        #expect(a.events.contains(.lost(b.id)))
        #expect(a.events.last == .state(.disconnected))

        b.transport.start()
        await eventually { a.members == [b.id] && b.members == [a.id] }
        #expect(a.members == [b.id] && b.members == [a.id], "A new start is a new advertisement and a new connection")
        a.transport.send(Data("again".utf8))
        await eventually { b.messages(from: a.id).last == Data("again".utf8) }
        #expect(b.messages(from: a.id).last == Data("again".utf8))
    }
}
