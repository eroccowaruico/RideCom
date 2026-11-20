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
        let authentication = try HMAC<SHA256>.authenticationCode(for: Self.encode(target), using: Self.pairKey(pairSecret))
        claim = Claim(target: target, pairAuthentication: Data(authentication))
        proof = try signer.sign(Self.encode(claim), purpose: .deleteContact)
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
              try HMAC<SHA256>.isValidAuthenticationCode(claim.pairAuthentication, authenticating: Self.encode(target),
                                                         using: Self.pairKey(pairSecret))
        else { throw DeviceIdentityProof.Failure.invalid }
        _ = try proof.verify(Self.encode(claim), purpose: .deleteContact, memberID: peerID)
    }

    fileprivate func digest() throws -> Data {
        try Data(SHA256.hash(data: Self.encode(self)))
    }

    fileprivate static func encode(_ value: some Encodable) throws -> Data {
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
        proof = try recipient.sign(ContactDeletionNotice.encode(claim), purpose: .acknowledgeContactDeletion)
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
        _ = try proof.verify(ContactDeletionNotice.encode(claim), purpose: .acknowledgeContactDeletion,
                             memberID: target.recipientMemberID)
    }
}
