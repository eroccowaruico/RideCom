import Foundation
import Testing
@testable import RTC

struct LocalControlProtocolTests {
    @Test func messagesKeepTheirBoundariesHoweverTheStreamIsCut() throws {
        let messages = [
            Data(), Data("a".utf8), Data(repeating: 7, count: 300),
            Data(repeating: 9, count: LocalControlFraming.maximumMessageBytes)
        ]
        let stream = try messages.reduce(Data()) { $0 + (try LocalControlFraming.frame($1)) }
        for chunk in [1, 3, 5, 4096, stream.count] {
            var framing = LocalControlFraming(), received: [Data] = []
            var offset = 0
            while offset < stream.count {
                let end = min(offset + chunk, stream.count)
                received += try framing.receive(stream.subdata(in: offset..<end))
                offset = end
            }
            #expect(received == messages, "chunks of \(chunk)")
        }
    }

    @Test func anOversizedMessageIsNeitherSentNorRead() throws {
        #expect(throws: LocalControlFraming.Failure.oversized) {
            try LocalControlFraming.frame(Data(count: LocalControlFraming.maximumMessageBytes + 1))
        }
        var framing = LocalControlFraming()
        #expect(throws: LocalControlFraming.Failure.oversized) {
            try framing.receive(Data([0x00, 0x01, 0x00, 0x01]) + Data(count: 16))
        }
        #expect(try framing.receive(try LocalControlFraming.frame(Data("next".utf8))) == [Data("next".utf8)],
                "Nothing of the refused announcement is kept")
    }

    private let credential = RTCCredential.derived(groupID: "local-control", secret: "test-only")
    private let senderFingerprint = Data(repeating: 0xA1, count: 32),
        receiverFingerprint = Data(repeating: 0xB2, count: 32),
        relay = Data(repeating: 0xEE, count: 32)

    @Test func theHandshakeProvesTheGroupKeyOnThisConnectionOnly() {
        let fromA = LocalControlHandshake.make(credential: credential, senderID: .init(rawValue: "a"),
            senderFingerprint: senderFingerprint, receiverFingerprint: receiverFingerprint)
        #expect(
            fromA.verify(
                credential: credential, localID: .init(rawValue: "b"), senderFingerprint: senderFingerprint,
                receiverFingerprint: receiverFingerprint
            ))

        // Someone in the middle presents their own certificate to each side.
        #expect(
            !fromA.verify(
                credential: credential, localID: .init(rawValue: "b"), senderFingerprint: relay,
                receiverFingerprint: receiverFingerprint))
        let towardsRelay = LocalControlHandshake.make(credential: credential, senderID: .init(rawValue: "a"),
            senderFingerprint: senderFingerprint, receiverFingerprint: relay)
        #expect(
            !towardsRelay.verify(
                credential: credential, localID: .init(rawValue: "b"), senderFingerprint: relay,
                receiverFingerprint: receiverFingerprint))
        #expect(
            !towardsRelay.verify(
                credential: credential, localID: .init(rawValue: "b"), senderFingerprint: senderFingerprint,
                receiverFingerprint: receiverFingerprint
            ))

        // The same message is no proof in the other direction, and not when sent back to its author.
        #expect(
            !fromA.verify(
                credential: credential, localID: .init(rawValue: "b"), senderFingerprint: receiverFingerprint,
                receiverFingerprint: senderFingerprint
            ))
        #expect(
            !fromA.verify(
                credential: credential, localID: .init(rawValue: "a"), senderFingerprint: senderFingerprint,
                receiverFingerprint: receiverFingerprint
            ))
    }

    @Test func anotherGroupAnotherKeyOrAnAlteredFieldIsRefused() {
        let local = PeerID(rawValue: "b")
        let valid = LocalControlHandshake.make(
            credential: credential, senderID: .init(rawValue: "a"), senderFingerprint: senderFingerprint,
            receiverFingerprint: receiverFingerprint)
        let otherGroup = RTCCredential.derived(groupID: "another", secret: "test-only")
        let otherKey = RTCCredential(groupHash: credential.groupHash, sharedSecret: Data(repeating: 1, count: 32))
        #expect(
            !valid.verify(
                credential: otherGroup, localID: local, senderFingerprint: senderFingerprint,
                receiverFingerprint: receiverFingerprint))
        #expect(
            !valid.verify(
                credential: otherKey, localID: local, senderFingerprint: senderFingerprint,
                receiverFingerprint: receiverFingerprint))
        for change: (inout LocalControlHandshake) -> Void in [
            { $0.senderID = .init(rawValue: "c") }, { $0.nonce = "other" }, { $0.nonce = "" },
            { $0.mac = String(repeating: "0", count: 64) }, { $0.mac = "" }, { $0.mac += "00" },
            { $0.mac = String(repeating: "é", count: 32) }
        ] {
            var altered = valid; change(&altered)
            #expect(
                !altered.verify(
                    credential: credential, localID: local, senderFingerprint: senderFingerprint,
                    receiverFingerprint: receiverFingerprint))
        }
    }

    @Test func fieldsCannotBeShiftedIntoOneAnother() {
        let local = PeerID(rawValue: "z")
        let first = LocalControlHandshake.make(credential: credential, senderID: .init(rawValue: "ab"), nonce: "c",
            senderFingerprint: senderFingerprint, receiverFingerprint: receiverFingerprint)
        var shifted = first; shifted.senderID = .init(rawValue: "a"); shifted.nonce = "bc"
        #expect(
            !shifted.verify(
                credential: credential, localID: local, senderFingerprint: senderFingerprint,
                receiverFingerprint: receiverFingerprint))
    }
}
