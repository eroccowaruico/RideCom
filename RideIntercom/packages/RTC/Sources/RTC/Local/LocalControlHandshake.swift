import CryptoKit
import Foundation

/// The message that decides who the peer on a local control connection is. TLS accepted any
/// certificate; this proves knowledge of the group key and ties that proof to this one connection, by
/// covering both certificate fingerprints. Someone relaying between two members must present
/// certificates of their own, so the fingerprints the two members see differ and the proof fails.
struct LocalControlHandshake: Codable, Equatable, Sendable {
    var groupHash: String
    var senderID: PeerID
    /// Also names the sender's UDP audio listener for this generation.
    var nonce: String
    var mac: String

    /// - Parameters:
    ///   - senderFingerprint: the certificate this end presents.
    ///   - receiverFingerprint: the certificate this end saw from the peer.
    static func make(credential: RTCCredential, senderID: PeerID, nonce: String = UUID().uuidString,
                     senderFingerprint: Data, receiverFingerprint: Data) -> LocalControlHandshake {
        .init(groupHash: credential.groupHash, senderID: senderID, nonce: nonce,
              mac: mac(groupHash: credential.groupHash, senderID: senderID, nonce: nonce,
                       senderFingerprint: senderFingerprint, receiverFingerprint: receiverFingerprint, secret: credential.sharedSecret))
    }

    /// - Parameters:
    ///   - localID: a handshake that claims to come from this end is its own, sent back.
    ///   - senderFingerprint: the certificate the peer presented on this connection.
    ///   - receiverFingerprint: the certificate this end presents.
    func verify(credential: RTCCredential, localID: PeerID, senderFingerprint: Data, receiverFingerprint: Data) -> Bool {
        guard groupHash == credential.groupHash, senderID != localID, !nonce.isEmpty,
              let claimed = Data(hexadecimal: mac) else { return false }
        let expected = Self.code(groupHash: groupHash, senderID: senderID, nonce: nonce,
                                 senderFingerprint: senderFingerprint, receiverFingerprint: receiverFingerprint, secret: credential.sharedSecret)
        return HMAC<SHA256>.isValidAuthenticationCode(claimed, authenticating: expected.message, using: expected.key)
    }

    private static func mac(groupHash: String, senderID: PeerID, nonce: String,
                            senderFingerprint: Data, receiverFingerprint: Data, secret: Data) -> String {
        let input = code(groupHash: groupHash, senderID: senderID, nonce: nonce,
                         senderFingerprint: senderFingerprint, receiverFingerprint: receiverFingerprint, secret: secret)
        return HMAC<SHA256>.authenticationCode(for: input.message, using: input.key).map { String(format: "%02x", $0) }.joined()
    }

    /// Every field is length-prefixed, so no choice of identifier or nonce can imitate another field.
    private static func code(groupHash: String, senderID: PeerID, nonce: String,
                             senderFingerprint: Data, receiverFingerprint: Data, secret: Data) -> (message: Data, key: SymmetricKey) {
        var message = Data("rideintercom.local-control.v1".utf8)
        for field in [Data(groupHash.utf8), Data(senderID.rawValue.utf8), Data(nonce.utf8), senderFingerprint, receiverFingerprint] {
            withUnsafeBytes(of: UInt32(field.count).bigEndian) { message.append(contentsOf: $0) }
            message.append(field)
        }
        return (message, SymmetricKey(data: secret))
    }
}

private extension Data {
    init?(hexadecimal text: String) {
        guard text.utf8.count == 64 else { return nil }
        var bytes: [UInt8] = []
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte); index = next
        }
        self.init(bytes)
    }
}
