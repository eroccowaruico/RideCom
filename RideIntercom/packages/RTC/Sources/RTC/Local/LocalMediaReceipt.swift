import CryptoKit
import Foundation

/// Receipts name the hash of a complete media datagram. Both identities and
/// authenticated listener generations are MAC-bound without exposing them.
struct LocalMediaReceiptAuthenticator {
    static let byteCount = 67
    private let key: SymmetricKey
    init(credential: RTCCredential, sender: PeerID, receiver: PeerID,
         senderNonce: String, receiverNonce: String) {
        var context = Data("rideintercom.local-media-receipt.v1\0".utf8)
        for field in [credential.groupHash, sender.rawValue, receiver.rawValue, senderNonce, receiverNonce] {
            let bytes = Data(field.utf8)
            var size = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &size) { context.append(contentsOf: $0) }
            context.append(bytes)
        }
        key = SymmetricKey(data: Data(HMAC<SHA256>.authenticationCode(for: context,
            using: SymmetricKey(data: credential.sharedSecret))))
    }
    func make(digest: Data) -> Data? {
        guard digest.count == 32 else { return nil }
        var bytes = Data([0, 1, 2]); bytes.append(digest)
        bytes.append(contentsOf: HMAC<SHA256>.authenticationCode(for: bytes, using: key))
        return bytes
    }
    func decode(_ bytes: Data) -> Data? {
        guard bytes.count == Self.byteCount, bytes.prefix(3) == Data([0, 1, 2]),
            HMAC<SHA256>.isValidAuthenticationCode(bytes.suffix(32), authenticating: bytes.prefix(35), using: key)
        else { return nil }
        return Data(bytes.dropFirst(3).prefix(32))
    }
}

enum LocalMediaFraming {
    /// A replacement path sends a new live frame with its own random envelope.
    /// A receipt captured on the current flow cannot validate this candidate.
    static func candidate(_ media: Data) -> Data {
        var result = Data([0, 1, 1]), nonce = UUID().uuid
        withUnsafeBytes(of: &nonce) { result.append(contentsOf: $0) }
        result.append(media)
        return result
    }
    static func decode(_ bytes: Data) -> (sender: PeerID, payload: Data)? {
        let media: Data
        if bytes.first == 0 {
            guard bytes.prefix(3) == Data([0, 1, 1]), bytes.count > 19 else { return nil }
            media = Data(bytes.dropFirst(19))
        } else { media = bytes }
        guard let length = media.first, (1...PeerID.maximumRelayIDBytes).contains(Int(length)),
              media.count > Int(length) + 1, media.count <= 60_001 + Int(length),
              let sender = String(data: media.dropFirst().prefix(Int(length)), encoding: .utf8) else { return nil }
        return (.init(rawValue: sender), Data(media.dropFirst(Int(length) + 1)))
    }
}

/// GroupRelay's encrypted envelopes are unique and are never retransmitted.
/// Keep only hashes/timestamps, never queued audio. All time is sender-local.
struct LocalMediaReceiptWindow {
    static let lifetime: TimeInterval = 1.5
    static let interval: TimeInterval = 0.5
    static let capacity = 128
    private struct Sent { let sentAt: TimeInterval; var acknowledged = false }
    private var sent: [Data: Sent] = [:]
    private var order = [Data?](repeating: nil, count: Self.capacity)
    private var nextSlot = 0
    private var verifiedAt: TimeInterval?
    private(set) var lastSentAt: TimeInterval = -.infinity
    mutating func record(digest: Data, at now: TimeInterval) {
        if sent[digest] == nil {
            if let expired = order[nextSlot] { sent[expired] = nil }
            order[nextSlot] = digest
            nextSlot = (nextSlot + 1) % Self.capacity
            sent[digest] = .init(sentAt: now)
        }
        lastSentAt = now
    }
    mutating func accept(digest: Data, at now: TimeInterval) -> Bool {
        guard var packet = sent[digest], !packet.acknowledged,
              now >= packet.sentAt, now - packet.sentAt < Self.lifetime else { return false }
        packet.acknowledged = true; sent[digest] = packet
        verifiedAt = max(verifiedAt ?? packet.sentAt, packet.sentAt)
        return true
    }
    func isRecent(at now: TimeInterval) -> Bool {
        guard let verifiedAt else { return false }
        return now >= verifiedAt && now - verifiedAt < Self.lifetime
    }
}
