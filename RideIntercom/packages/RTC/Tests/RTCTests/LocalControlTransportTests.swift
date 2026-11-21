import Foundation
import Network
import Synchronization
import Testing
@testable import RTC

/// Real Bonjour discovery and real QUIC between transports in this process.
struct LocalControlTransportTests {
    private final class EndReference: @unchecked Sendable { weak var end: End? }

    private final class End: Sendable {
        let id: PeerID
        private let log = Mutex<[LocalControlEvent]>([])
        let transport: LocalControlTransport
        init(_ name: String, credential: RTCCredential) {
            id = .init(rawValue: name)
            let box = EndReference()
            transport = LocalControlTransport(
                localID: id, credential: credential, nonce: name + "-nonce"
            ) { event in box.end?.record(event) }
            box.end = self
        }
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
        let leftChannel = RTCLocalDataChannel(localID: left, credential: credential) { event in
            receivedByLeft.withLock { $0.append(event) }
        }
        let rightChannel = RTCLocalDataChannel(localID: right, credential: credential) { event in
            receivedByRight.withLock { $0.append(event) }
        }
        let call = End("active-call", credential: credential)
        defer { leftChannel.stop(); rightChannel.stop(); call.transport.stop() }
        call.transport.start()
        leftChannel.start()
        rightChannel.start()

        await eventually {
            receivedByLeft.withLock { $0.contains(.members([right])) }
                && receivedByRight.withLock { $0.contains(.members([left])) }
        }
        try #require(receivedByLeft.withLock { $0.contains(.members([right])) })
        try #require(receivedByRight.withLock { $0.contains(.members([left])) })
        let invitation = Data("invitation".utf8), reply = Data("reply".utf8)
        leftChannel.send(invitation)
        await eventually { receivedByRight.withLock { $0.contains(.message(invitation, from: left)) } }
        try #require(receivedByRight.withLock { $0.contains(.message(invitation, from: left)) })
        rightChannel.send(reply)
        await eventually { receivedByLeft.withLock { $0.contains(.message(reply, from: right)) } }
        try #require(receivedByLeft.withLock { $0.contains(.message(reply, from: right)) })

        rightChannel.stop()
        await eventually { receivedByLeft.withLock { $0.last == .members([]) } }
        try #require(receivedByLeft.withLock { $0.last == .members([]) })
        rightChannel.start()
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
        let published = LocalAddressedAdvertisement(
            name: name, fingerprint: fingerprint, credentials: [key, anotherKey])
        let encoded = published.record
        let decoded = try #require(LocalAddressedAdvertisement(name: name, record: encoded, maximumOffers: 2))
        #expect(decoded.offers(key))
        #expect(decoded.offers(anotherKey))
        let unrelated = RTCCredential.derived(groupID: "intended-pair", secret: "other-key")
        #expect(!decoded.offers(unrelated))
        #expect(LocalAddressedAdvertisement(name: name, record: encoded, maximumOffers: 1) == nil)

        let changedName = try #require(
            LocalAddressedAdvertisement(name: UUID().uuidString, record: encoded, maximumOffers: 2))
        #expect(!changedName.offers(key))
        let offers = try #require(encoded["p"])
        let replacedCertificate = NWTXTRecord(["p": offers, "f": Data(repeating: 2, count: 32).base64EncodedString()])
        let changedIdentity = try #require(
            LocalAddressedAdvertisement(name: name, record: replacedCertificate, maximumOffers: 2))
        #expect(!changedIdentity.offers(key))
    }

    @Test(.timeLimit(.minutes(2)))
    func addressedOffersReachOnlyTheirAuthenticatedRecipients() async throws {
        let authorID = PeerID(rawValue: "author"), firstID = PeerID(rawValue: "first"),
            secondID = PeerID(rawValue: "second")
        let stranger = PeerID(rawValue: "unregistered")
        let firstPair = RTCCredential.derived(groupID: UUID().uuidString, secret: "first-pair")
        let secondPair = RTCCredential.derived(groupID: UUID().uuidString, secret: "second-pair")
        let unofferedPair = RTCCredential.derived(groupID: UUID().uuidString, secret: "unoffered-pair")
        let books = Mutex<[PeerID: [RTCLocalDataChannel.Event]]>([:])
        func channel(_ id: PeerID, peers: [PeerID: RTCCredential], offers: Set<PeerID> = []) -> RTCLocalDataChannel {
            RTCLocalDataChannel(localID: id, knownPeers: peers, offeredPeers: offers) { event in
                books.withLock { $0[id, default: []].append(event) }
            }
        }
        let author = channel(authorID, peers: [firstID: firstPair, secondID: secondPair], offers: [firstID, secondID])
        let first = channel(firstID, peers: [authorID: firstPair, secondID: unofferedPair])
        let second = channel(secondID, peers: [authorID: secondPair, firstID: unofferedPair])
        // A matching discovery tag still cannot authenticate an identity absent from the offer.
        let unknown = channel(stranger, peers: [authorID: firstPair])
        let call = End("active-call", credential: firstPair)
        defer {
            [author, first, second, unknown].forEach { $0.stop() }
            call.transport.stop()
        }
        first.start()
        second.start()
        unknown.start()
        call.transport.start()
        author.start()
        let allAddressesConnected: @Sendable () -> Bool = {
            books.withLock { ($0[authorID] ?? []).contains { event in
                    if case .members(let peers) = event { return Set(peers) == [firstID, secondID] }
                return false
            } }
        }
        await eventually(allAddressesConnected)
        try #require(allAddressesConnected())
        let invitation = Data("only first".utf8), receipt = Data("first receipt".utf8)
        let broadcast = Data("no destination".utf8)
        author.send(broadcast)
        author.send(invitation, to: firstID)
        await eventually { books.withLock { $0[firstID]?.contains(.message(invitation, from: authorID)) == true } }
        try #require(books.withLock { $0[firstID]?.contains(.message(invitation, from: authorID)) == true })
        first.send(receipt, to: authorID)
        await eventually { books.withLock { $0[authorID]?.contains(.message(receipt, from: firstID)) == true } }
        #expect(books.withLock { $0[authorID]?.contains(.message(receipt, from: firstID)) == true })
        #expect(books.withLock { $0[firstID]?.contains(.message(broadcast, from: authorID)) == false })
        #expect(books.withLock { $0[secondID]?.contains(.message(invitation, from: authorID)) == false })
        #expect(books.withLock { $0[stranger, default: []].isEmpty })
        #expect(call.members.isEmpty)
        author.stop()
        await eventually { books.withLock { $0[firstID]?.last == .members([]) && $0[secondID]?.last == .members([]) } }
        #expect(books.withLock { $0[firstID]?.last == .members([]) && $0[secondID]?.last == .members([]) })
    }

    @Test(.timeLimit(.minutes(2)))
    func membersOfOneGroupFindEachOtherAndNobodyElse() async throws {
        let group = RTCCredential.derived(groupID: "control-" + UUID().uuidString, secret: "test-only")
        let other = RTCCredential.derived(groupID: "control-" + UUID().uuidString, secret: "test-only")
        // Same group name on the air, different key: discovery matches, the handshake must not.
        let impostor = RTCCredential(groupHash: group.groupHash, sharedSecret: Data(repeating: 3, count: 32))
        let firstMember = End("a", credential: group), secondMember = End("b", credential: group),
            thirdMember = End("c", credential: group)
        let outsider = End("outsider", credential: other), stranger = End("stranger", credential: impostor)
        let all = [firstMember, secondMember, thirdMember, outsider, stranger]
        defer { all.forEach { $0.transport.stop() } }
        all.forEach { $0.transport.start() }

        await eventually {
            firstMember.members == [secondMember.id, thirdMember.id]
                && secondMember.members == [firstMember.id, thirdMember.id]
                && thirdMember.members == [firstMember.id, secondMember.id]
        }
        #expect(firstMember.members == [secondMember.id, thirdMember.id])
        #expect(secondMember.members == [firstMember.id, thirdMember.id])
        #expect(thirdMember.members == [firstMember.id, secondMember.id])
        #expect(
            firstMember.events.contains(.authenticated(secondMember.id, nonce: "b-nonce")),
            "The handshake carries the peer's audio listener nonce")

        firstMember.transport.send(Data("from a".utf8))
        secondMember.transport.send(Data("from b 1".utf8)); secondMember.transport.send(Data("from b 2".utf8))
        await eventually {
            thirdMember.messages(from: firstMember.id).count == 1
                && thirdMember.messages(from: secondMember.id).count == 2
                && firstMember.messages(from: secondMember.id).count == 2
        }
        #expect(thirdMember.messages(from: firstMember.id) == [Data("from a".utf8)])
        #expect(thirdMember.messages(from: secondMember.id) == [Data("from b 1".utf8), Data("from b 2".utf8)])
        #expect(firstMember.messages(from: secondMember.id) == [Data("from b 1".utf8), Data("from b 2".utf8)])
        #expect(firstMember.messages(from: firstMember.id).isEmpty)

        #expect(outsider.members.isEmpty && stranger.members.isEmpty)
        for end in [outsider, stranger] {
            #expect(!end.events.contains { if case .message = $0 { return true }; return false })
            #expect(!end.events.contains { if case .authenticated = $0 { return true }; return false })
        }
        for end in [firstMember, secondMember, thirdMember] {
            #expect(!end.events.contains(.authenticated(outsider.id, nonce: "outsider-nonce")))
            #expect(!end.events.contains(.authenticated(stranger.id, nonce: "stranger-nonce")))
        }
    }

    @Test(.timeLimit(.minutes(2)))
    func aMemberWhoLeavesIsLostAndFoundAgainWhenTheyReturn() async throws {
        let group = RTCCredential.derived(groupID: "control-" + UUID().uuidString, secret: "test-only")
        let remainingMember = End("a", credential: group), rejoiningMember = End("b", credential: group)
        defer { remainingMember.transport.stop(); rejoiningMember.transport.stop() }
        remainingMember.transport.start(); rejoiningMember.transport.start()
        await eventually {
            remainingMember.members == [rejoiningMember.id] && rejoiningMember.members == [remainingMember.id]
        }
        #expect(remainingMember.members == [rejoiningMember.id])

        rejoiningMember.transport.stop()
        await eventually { remainingMember.members.isEmpty && remainingMember.events.last == .state(.disconnected) }
        #expect(remainingMember.events.contains(.lost(rejoiningMember.id)))
        #expect(remainingMember.events.last == .state(.disconnected))

        rejoiningMember.transport.start()
        await eventually {
            remainingMember.members == [rejoiningMember.id] && rejoiningMember.members == [remainingMember.id]
        }
        #expect(
            remainingMember.members == [rejoiningMember.id] && rejoiningMember.members == [remainingMember.id],
            "A new start is a new advertisement and a new connection")
        remainingMember.transport.send(Data("again".utf8))
        await eventually { rejoiningMember.messages(from: remainingMember.id).last == Data("again".utf8) }
        #expect(rejoiningMember.messages(from: remainingMember.id).last == Data("again".utf8))
    }
}
