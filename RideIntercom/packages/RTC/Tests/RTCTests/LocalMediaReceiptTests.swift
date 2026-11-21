import CryptoKit
import Foundation
import Testing
@testable import RTC

struct LocalMediaReceiptTests {
    private let credential = RTCCredential.derived(groupID: "receipt", secret: "private-fixture")
    private let senderPeer = PeerID(rawValue: "a"), receiverPeer = PeerID(rawValue: "b")
    private func authenticator(
        sender: PeerID? = nil, receiver: PeerID? = nil, senderNonce: String = "a-generation",
        receiverNonce: String = "b-generation", credential: RTCCredential? = nil
    ) -> LocalMediaReceiptAuthenticator {
        .init(
            credential: credential ?? self.credential, sender: sender ?? senderPeer,
            receiver: receiver ?? receiverPeer,
              senderNonce: senderNonce, receiverNonce: receiverNonce)
    }
    @Test func completeMediaReceiptsBindBothPeersGenerationsAndGroup() throws {
        let digest = Data(SHA256.hash(data: Data(repeating: 0x71, count: 960)))
        let receipt = try #require(authenticator().make(digest: digest))
        #expect(receipt.count == 67 && authenticator().decode(receipt) == digest)
        for other in [
            authenticator(sender: receiverPeer, receiver: senderPeer),
            authenticator(sender: .init(rawValue: "other")),
                      authenticator(receiver: .init(rawValue: "other")), authenticator(senderNonce: "old-a"),
                      authenticator(receiverNonce: "old-b"),
                      authenticator(credential: .init(groupHash: "other", sharedSecret: credential.sharedSecret)),
                      authenticator(credential: .derived(groupID: "receipt", secret: "wrong"))] {
            #expect(other.decode(receipt) == nil)
        }
        for index in receipt.indices {
            var modified = receipt; modified[index] ^= 1
            #expect(authenticator().decode(modified) == nil)
        }
        #expect(authenticator().decode(Data(receipt.dropLast())) == nil)
        #expect(authenticator().decode(receipt + Data([0])) == nil)
        #expect(authenticator().make(digest: Data([1])) == nil)
    }
    @Test func receiptCannotExtendTheOriginalSendTimeOrBeReplayed() {
        let digest = Data(repeating: 1, count: 32), other = Data(repeating: 2, count: 32)
        var window = LocalMediaReceiptWindow()
        window.record(digest: digest, at: 10)
        #expect(!window.isRecent(at: 10))
        let accepted0 = window.accept(digest: other, at: 10.1)
        #expect(!accepted0)
        let accepted1 = window.accept(digest: digest, at: 11)
        #expect(accepted1)
        let accepted2 = window.accept(digest: digest, at: 11.4)
        #expect(!accepted2)
        window.record(digest: digest, at: 11.4)
        let accepted3 = window.accept(digest: digest, at: 11.4)
        #expect(!accepted3)
        #expect(window.isRecent(at: 11.49))
        #expect(!window.isRecent(at: 11.5))
        window.record(digest: other, at: 12)
        let accepted4 = window.accept(digest: other, at: 11.9)
        #expect(!accepted4)
        let accepted5 = window.accept(digest: other, at: 13.5)
        #expect(!accepted5)
    }
    @Test func candidateUsesLiveMediaWithASeparateReceiptIdentity() throws {
        let original = Data([1]) + Data("a".utf8) + Data(repeating: 0x71, count: 256)
        let candidate = LocalMediaFraming.candidate(original)
        #expect(candidate != LocalMediaFraming.candidate(original))
        #expect(SHA256.hash(data: original) != SHA256.hash(data: candidate))
        let packet = try #require(LocalMediaFraming.decode(candidate))
        #expect(packet.sender == senderPeer && packet.payload == Data(repeating: 0x71, count: 256))
        #expect(LocalMediaFraming.decode(original)?.payload == packet.payload)
        #expect(LocalMediaFraming.decode(Data([0, 2, 1]) + candidate) == nil)
        #expect(LocalMediaFraming.decode(Data([0, 1, 1])) == nil)
        #expect(LocalMediaFraming.decode(Data([81]) + Data(repeating: 0, count: 100)) == nil)
    }
    @Test func trackingIsBoundedAndOldHashesCannotProveANewDatagram() {
        var window = LocalMediaReceiptWindow()
        let old = Data(SHA256.hash(data: Data("old".utf8)))
        window.record(digest: old, at: 10)
        var newest = Data()
        for index in 0..<LocalMediaReceiptWindow.capacity {
            newest = Data(SHA256.hash(data: Data(String(index).utf8)))
            window.record(digest: newest, at: 10.1)
        }
        let retired = window.accept(digest: old, at: 10.2)
        #expect(!retired)
        let current = window.accept(digest: newest, at: 10.2)
        #expect(current)
        var replacement = LocalMediaReceiptWindow()
        let candidate = Data(SHA256.hash(data: LocalMediaFraming.candidate(Data([1, 65, 1]))))
        replacement.record(digest: candidate, at: 11)
        let wrongPath = replacement.accept(digest: newest, at: 11.1)
        #expect(!wrongPath && !replacement.isRecent(at: 11.1))
    }
}
