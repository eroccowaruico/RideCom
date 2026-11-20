import CryptoKit
import Foundation

/// A deletion is valid for one device pair and the call credential they saved when registering.
nonisolated struct ContactDeletionNotice: Codable, Equatable, Identifiable, Sendable {
    static let lifetime: TimeInterval = 28 * 86_400

    struct Target: Codable, Equatable, Sendable {
        let id: UUID
        let senderMemberID: String
        let recipientMemberID: String
        let recipientKey: String
        let expiresAt: TimeInterval

        var isValid: Bool {
            senderMemberID != recipientMemberID
                && [senderMemberID, recipientMemberID].allSatisfy {
                    IntercomGroup.isValidMemberID($0) && !$0.hasPrefix(GroupMember.pendingInvitePrefix)
                }
                && DeviceIdentityProof.isValidPublicKey(recipientKey) && expiresAt.isFinite && expiresAt > 0
        }

        func isCurrent(at now: Date) -> Bool {
            let time = now.timeIntervalSince1970
            return time < expiresAt && expiresAt <= time + ContactDeletionNotice.lifetime + 300
        }
    }

    private struct Claim: Codable, Equatable, Sendable {
        let target: Target
        let pairAuthentication: Data
    }

    private let claim: Claim
    let proof: DeviceIdentityProof
    var id: UUID { target.id }
    var target: Target { claim.target }

    init(signer: DeviceIdentitySigner, recipientMemberID: String, recipientKey: String,
         pairSecret: String, now: Date) throws {
        let target = Target(id: UUID(), senderMemberID: signer.memberID, recipientMemberID: recipientMemberID,
                            recipientKey: recipientKey, expiresAt: now.timeIntervalSince1970 + Self.lifetime)
        guard target.isValid, recipientKey != signer.publicKey else { throw DeviceIdentityProof.Failure.invalid }
        let authentication = try HMAC<SHA256>.authenticationCode(for: Self.canonicalJSON(target), using: Self.pairKey(pairSecret))
        claim = Claim(target: target, pairAuthentication: Data(authentication))
        proof = try signer.sign(Self.canonicalJSON(claim), purpose: .deleteContact)
        guard isValid else { throw DeviceIdentityProof.Failure.invalid }
    }

    var isValid: Bool {
        target.isValid && claim.pairAuthentication.count == 32 && proof.certificate == nil
            && proof.publicKey != target.recipientKey && DeviceIdentityProof.isValidPublicKey(proof.publicKey)
            && IdentityEncoding.decode(proof.signature)?.count == 64
    }

    func verify(from peerID: String, senderKey: String, recipient: DeviceIdentitySigner,
                pairSecret: String, now: Date) throws {
        guard isValid, peerID == target.senderMemberID, senderKey == proof.publicKey,
              target.recipientMemberID == recipient.memberID, target.recipientKey == recipient.publicKey,
              target.isCurrent(at: now),
              try HMAC<SHA256>.isValidAuthenticationCode(claim.pairAuthentication, authenticating: Self.canonicalJSON(target),
                                                         using: Self.pairKey(pairSecret))
        else { throw DeviceIdentityProof.Failure.invalid }
        _ = try proof.verify(Self.canonicalJSON(claim), purpose: .deleteContact, memberID: peerID)
    }

    fileprivate func digest() throws -> Data {
        try Data(SHA256.hash(data: Self.canonicalJSON(self)))
    }

    fileprivate static func canonicalJSON(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }

    private static func pairKey(_ secret: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(secret.utf8)),
                              salt: Data("rideintercom.contact-deletion.v1".utf8), outputByteCount: 32)
    }
}

/// The receiver keeps this signed response so the same notice can be acknowledged after a restart.
nonisolated struct ContactDeletionReceipt: Codable, Equatable, Identifiable, Sendable {
    private struct Claim: Codable, Equatable, Sendable {
        let target: ContactDeletionNotice.Target
        let senderKey: String
        let noticeDigest: Data
    }

    private let claim: Claim
    private let proof: DeviceIdentityProof
    var target: ContactDeletionNotice.Target { claim.target }
    var senderKey: String { claim.senderKey }
    var id: UUID { target.id }

    init(for notice: ContactDeletionNotice, recipient: DeviceIdentitySigner) throws {
        guard notice.target.recipientMemberID == recipient.memberID, notice.target.recipientKey == recipient.publicKey
        else { throw DeviceIdentityProof.Failure.invalid }
        claim = try Claim(target: notice.target, senderKey: notice.proof.publicKey, noticeDigest: notice.digest())
        proof = try recipient.sign(ContactDeletionNotice.canonicalJSON(claim), purpose: .acknowledgeContactDeletion)
        guard isValid else { throw DeviceIdentityProof.Failure.invalid }
    }

    var isValid: Bool {
        target.isValid && DeviceIdentityProof.isValidPublicKey(senderKey) && senderKey != target.recipientKey
            && claim.noticeDigest.count == 32 && proof.publicKey == target.recipientKey && proof.certificate == nil
            && IdentityEncoding.decode(proof.signature)?.count == 64
    }

    func verify(for notice: ContactDeletionNotice, now: Date) throws {
        guard isValid, target == notice.target, target.isCurrent(at: now),
              senderKey == notice.proof.publicKey, try claim.noticeDigest == notice.digest()
        else { throw DeviceIdentityProof.Failure.invalid }
        _ = try proof.verify(ContactDeletionNotice.canonicalJSON(claim), purpose: .acknowledgeContactDeletion,
                             memberID: target.recipientMemberID)
    }
}

/// Keep the original packet across retries. After acknowledgement, the same slot can still be retired.
nonisolated struct ContactDeletionPublication: Codable, Equatable, Identifiable, Sendable {
    struct Payload: Codable, Equatable, Sendable {
        let recipient: AccountPrincipal
        let recipientKey: String
        let packet: String
    }

    let id: UUID
    let expiresAt: Int64
    let slot: String
    let sender: AccountPrincipal
    let senderKey: String
    private(set) var payload: Payload?

    init(notice: ContactDeletionNotice, sender: AccountPrincipal, recipient: AccountPrincipal,
         signer: DeviceIdentitySigner, pairSecret: String) throws {
        let target = notice.target
        guard target.senderMemberID == signer.memberID, notice.proof.publicKey == signer.publicKey
        else { throw DeviceIdentityProof.Failure.invalid }
        id = target.id
        expiresAt = try ContactDeletionRelayPacket.expiry(target)
        slot = ContactDeletionRelayPacket.slot(pairSecret: pairSecret, senderID: signer.memberID, recipientID: target.recipientMemberID)
        self.sender = sender
        senderKey = signer.publicKey
        let packet = try ContactDeletionRelayPacket.notice.seal(notice, slot: slot, signer: signer,
                                                               peerID: target.recipientMemberID, peerKey: target.recipientKey)
        payload = .init(recipient: recipient, recipientKey: target.recipientKey, packet: packet)
        guard isValid else { throw DeviceIdentityProof.Failure.invalid }
    }

    mutating func markForRetirement() { payload = nil }

    var isValid: Bool {
        guard ContactDeletionRelayPacket.isValid(expiresAt: expiresAt, slot: slot),
              sender.isValid, DeviceIdentityProof.isValidPublicKey(senderKey)
        else { return false }
        guard let payload else { return true }
        return payload.recipient.isValid && payload.recipient.issuer == sender.issuer && payload.recipient != sender
            && payload.recipientKey != senderKey && DeviceIdentityProof.isValidPublicKey(payload.recipientKey)
            && ContactDeletionRelayPacket.packetBytes(payload.packet) != nil
    }

    static func openNotice(_ packet: String, slot: String, recipient: DeviceIdentitySigner,
                           senderID: String, senderKey: String) throws -> ContactDeletionNotice {
        try ContactDeletionRelayPacket.notice.open(packet, slot: slot, signer: recipient, peerID: senderID, peerKey: senderKey)
    }
}

/// Kept separately from the signed receipt, which is also returned over the nearby channel.
nonisolated struct ContactDeletionRelayReceipt: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let expiresAt: Int64
    let slot: String
    let owner: AccountPrincipal
    let recipient: AccountPrincipal
    let packet: String

    init(receipt: ContactDeletionReceipt, owner: AccountPrincipal, recipient: AccountPrincipal,
         signer: DeviceIdentitySigner, pairSecret: String) throws {
        let target = receipt.target
        guard target.recipientMemberID == signer.memberID, target.recipientKey == signer.publicKey
        else { throw DeviceIdentityProof.Failure.invalid }
        id = receipt.id
        expiresAt = try ContactDeletionRelayPacket.expiry(target)
        slot = ContactDeletionRelayPacket.slot(pairSecret: pairSecret, senderID: target.senderMemberID, recipientID: signer.memberID)
        self.owner = owner
        self.recipient = recipient
        packet = try ContactDeletionRelayPacket.receipt.seal(receipt, slot: slot, signer: signer,
                                                            peerID: target.senderMemberID, peerKey: receipt.senderKey)
        guard isValid else { throw DeviceIdentityProof.Failure.invalid }
    }

    var isValid: Bool {
        ContactDeletionRelayPacket.isValid(expiresAt: expiresAt, slot: slot)
            && owner.isValid && recipient.isValid && owner.issuer == recipient.issuer && owner != recipient
            && ContactDeletionRelayPacket.packetBytes(packet) != nil
    }

    static func open(_ packet: String, slot: String, sender: DeviceIdentitySigner,
                     recipientID: String, recipientKey: String) throws -> ContactDeletionReceipt {
        try ContactDeletionRelayPacket.receipt.open(packet, slot: slot, signer: sender, peerID: recipientID, peerKey: recipientKey)
    }
}

nonisolated enum ContactDeletionRelayPacket: String {
    case notice, receipt

    private var header: Data { Data("rideintercom.contact-deletion.\(rawValue).v1".utf8) }

    static func expiry(_ target: ContactDeletionNotice.Target) throws -> Int64 {
        guard let expiry = Int64(exactly: (target.expiresAt * 1_000).rounded(.down))
        else { throw DeviceIdentityProof.Failure.invalid }
        return expiry
    }

    static func isValid(expiresAt: Int64, slot: String) -> Bool {
        (1...9_007_199_254_740_991).contains(expiresAt) && slot.utf8.count == 64
            && slot.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }

    static func slot(pairSecret: String, senderID: String, recipientID: String) -> String {
        let info = Data([senderID, recipientID].joined(separator: "\0").utf8)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(pairSecret.utf8)),
            salt: Data("rideintercom.contact-deletion.slot.v1".utf8), info: info, outputByteCount: 32)
        return key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
    }

    fileprivate func seal(_ body: some Encodable, slot: String, signer: DeviceIdentitySigner,
                          peerID: String, peerKey: String) throws -> String {
        let key = try signer.contactDeletionRelayKey(peerMemberID: peerID, peerPublicKey: peerKey, slot: slot)
        let plaintext = try ContactDeletionNotice.canonicalJSON(body)
        guard let bytes = try AES.GCM.seal(plaintext, using: key, authenticating: header).combined
        else { throw DeviceIdentityProof.Failure.invalid }
        return bytes.base64EncodedString()
    }

    fileprivate func open<Body: Decodable>(_ packet: String, slot: String, signer: DeviceIdentitySigner,
                                           peerID: String, peerKey: String) throws -> Body {
        guard let bytes = Self.packetBytes(packet) else { throw DeviceIdentityProof.Failure.invalid }
        let key = try signer.contactDeletionRelayKey(peerMemberID: peerID, peerPublicKey: peerKey, slot: slot)
        let plaintext = try AES.GCM.open(.init(combined: bytes), using: key, authenticating: header)
        return try JSONDecoder().decode(Body.self, from: plaintext)
    }

    fileprivate static func packetBytes(_ packet: String) -> Data? {
        guard (40...4096).contains(packet.utf8.count) else { return nil }
        return Data(base64Encoded: packet)
    }
}
