import Foundation
import Network
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
    func standaloneDataExchangesRepliesAndDoesNotJoinCallControl() async throws {
        let credential = RTCCredential.derived(groupID: UUID().uuidString, secret: "standalone")
        let left = PeerID(rawValue: "sender"), right = PeerID(rawValue: "recipient")
        let receivedByLeft = Mutex<[RTCLocalDataChannel.Event]>([])
        let receivedByRight = Mutex<[RTCLocalDataChannel.Event]>([])
        let a = RTCLocalDataChannel(localID: left, credential: credential) { event in
            receivedByLeft.withLock { $0.append(event) }
        }
        let b = RTCLocalDataChannel(localID: right, credential: credential) { event in
            receivedByRight.withLock { $0.append(event) }
        }
        let call = End("active-call", credential: credential)
        defer { a.stop(); b.stop(); call.transport.stop() }
        call.transport.start()
        a.start()
        b.start()

        await eventually {
            receivedByLeft.withLock { $0.contains(.members([right])) }
                && receivedByRight.withLock { $0.contains(.members([left])) }
        }
        try #require(receivedByLeft.withLock { $0.contains(.members([right])) })
        try #require(receivedByRight.withLock { $0.contains(.members([left])) })
        let invitation = Data("invitation".utf8), reply = Data("reply".utf8)
        a.send(invitation)
        await eventually { receivedByRight.withLock { $0.contains(.message(invitation, from: left)) } }
        try #require(receivedByRight.withLock { $0.contains(.message(invitation, from: left)) })
        b.send(reply)
        await eventually { receivedByLeft.withLock { $0.contains(.message(reply, from: right)) } }
        try #require(receivedByLeft.withLock { $0.contains(.message(reply, from: right)) })

        b.stop()
        await eventually { receivedByLeft.withLock { $0.last == .members([]) } }
        try #require(receivedByLeft.withLock { $0.last == .members([]) })
        b.start()
        await eventually { receivedByLeft.withLock { $0.last == .members([right]) } }
        #expect(receivedByLeft.withLock { $0.last == .members([right]) })
        #expect(call.events.allSatisfy { event in
            if case .authenticated = event { return false }
            if case .message = event { return false }
            return true
        })
    }

    @Test
    func addressedAdvertisementMatchesOnlyThePairKeyAndTheAdvertisedCertificate() throws {
        let name = UUID().uuidString
        let fingerprint = Data(repeating: 1, count: 32)
        let key = RTCCredential.derived(groupID: "intended-pair", secret: "fixture-key")
        let anotherKey = RTCCredential.derived(groupID: "other-pair", secret: "fixture-key")
        let published = LocalAddressedAdvertisement(name: name, fingerprint: fingerprint, credentials: [key, anotherKey])
        let encoded = published.record
        let decoded = try #require(LocalAddressedAdvertisement(name: name, record: encoded, maximumOffers: 2))
        #expect(decoded.offers(key))
        #expect(decoded.offers(anotherKey))
        let unrelated = RTCCredential.derived(groupID: "intended-pair", secret: "other-key")
        #expect(!decoded.offers(unrelated))
        #expect(LocalAddressedAdvertisement(name: name, record: encoded, maximumOffers: 1) == nil)

        let changedName = try #require(LocalAddressedAdvertisement(name: UUID().uuidString, record: encoded, maximumOffers: 2))
        #expect(!changedName.offers(key))
        let offers = try #require(encoded["p"])
        let replacedCertificate = NWTXTRecord(["p": offers, "f": Data(repeating: 2, count: 32).base64EncodedString()])
        let changedIdentity = try #require(LocalAddressedAdvertisement(name: name, record: replacedCertificate, maximumOffers: 2))
        #expect(!changedIdentity.offers(key))
    }

    @Test(.timeLimit(.minutes(2)))
    func addressedOffersReachOnlyTheirAuthenticatedRecipients() async throws {
        let a = PeerID(rawValue: "author"), b = PeerID(rawValue: "first"), c = PeerID(rawValue: "second")
        let stranger = PeerID(rawValue: "unregistered")
        let ab = RTCCredential.derived(groupID: UUID().uuidString, secret: "first-pair")
        let ac = RTCCredential.derived(groupID: UUID().uuidString, secret: "second-pair")
        let bc = RTCCredential.derived(groupID: UUID().uuidString, secret: "unoffered-pair")
        let books = Mutex<[PeerID: [RTCLocalDataChannel.Event]]>([:])
        func channel(_ id: PeerID, peers: [PeerID: RTCCredential], offers: Set<PeerID> = []) -> RTCLocalDataChannel {
            RTCLocalDataChannel(localID: id, knownPeers: peers, offeredPeers: offers) { event in
                books.withLock { $0[id, default: []].append(event) }
            }
        }
        let author = channel(a, peers: [b: ab, c: ac], offers: [b, c])
        let first = channel(b, peers: [a: ab, c: bc])
        let second = channel(c, peers: [a: ac, b: bc])
        // A matching discovery tag still cannot authenticate an identity absent from the offer.
        let unknown = channel(stranger, peers: [a: ab])
        let call = End("active-call", credential: ab)
        defer {
            [author, first, second, unknown].forEach { $0.stop() }
            call.transport.stop()
        }
        first.start()
        second.start()
        unknown.start()
        call.transport.start()
        author.start()
        await eventually {
            books.withLock { ($0[a] ?? []).contains { event in
                if case .members(let peers) = event { return Set(peers) == [b, c] }
                return false
            } }
        }
        try #require(books.withLock { ($0[a] ?? []).contains { event in
            if case .members(let peers) = event { return Set(peers) == [b, c] }
            return false
        } })
        let invitation = Data("only first".utf8), receipt = Data("first receipt".utf8)
        let broadcast = Data("no destination".utf8)
        author.send(broadcast)
        author.send(invitation, to: b)
        await eventually { books.withLock { $0[b]?.contains(.message(invitation, from: a)) == true } }
        try #require(books.withLock { $0[b]?.contains(.message(invitation, from: a)) == true })
        first.send(receipt, to: a)
        await eventually { books.withLock { $0[a]?.contains(.message(receipt, from: b)) == true } }
        #expect(books.withLock { $0[a]?.contains(.message(receipt, from: b)) == true })
        #expect(books.withLock { $0[b]?.contains(.message(broadcast, from: a)) == false })
        #expect(books.withLock { $0[c]?.contains(.message(invitation, from: a)) == false })
        #expect(books.withLock { $0[stranger, default: []].isEmpty })
        #expect(call.members.isEmpty)
        author.stop()
        await eventually { books.withLock { $0[b]?.last == .members([]) && $0[c]?.last == .members([]) } }
        #expect(books.withLock { $0[b]?.last == .members([]) && $0[c]?.last == .members([]) })
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
