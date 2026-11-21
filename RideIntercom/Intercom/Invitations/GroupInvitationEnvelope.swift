import CryptoKit
import Foundation

/// Opaque transport for a signed group invitation, addressed to one previously verified device.
nonisolated struct GroupInvitationEnvelope: Codable, Sendable {
    struct Recipient: Sendable {
        let principal: AccountPrincipal
        let memberID: String
        let encryptionKey: String
    }

    private static let clockSkew: TimeInterval = 300
    private static let lifetime: TimeInterval = 7 * 86400
    private static let encryptionDomain = "rideintercom.group-delivery.ecdh.v1"

    var version = 1
    var id: UUID
    var sender: AccountPrincipal
    var recipient: AccountPrincipal
    var senderMemberID: String
    var recipientMemberID: String
    var recipientKey: String
    var ephemeralKey: String
    var expiresAt: TimeInterval
    var ciphertext: Data
    var proof: DeviceIdentityProof?
    var sourceRequestID: UUID?

    @MainActor
    static func seal(_ token: GroupInviteToken, sender: AccountPrincipal, recipient: Recipient,
                     signer: DeviceIdentitySigner,
                     now: Date = Date(), deliveryID: UUID = UUID(), sourceRequestID: UUID? = nil) throws -> Self {
        try token.validate()
        let recipientMemberID = recipient.memberID
        let recipientKey = recipient.encryptionKey
        let recipient = recipient.principal
        guard sourceRequestID != deliveryID, sender.isValid, recipient.isValid,
            sender.issuer == recipient.issuer, sender != recipient,
              signer.principal == nil || signer.principal == sender,
              sourceRequestID == nil || signer.principal == sender,
              token.inviterMemberID == signer.memberID, token.identityProof?.publicKey == signer.publicKey,
              token.verifySignature(), token.directInvitation?.context.contactBootstrap != true,
              let expiry = token.expiresAt, expiry > now.timeIntervalSince1970,
              expiry <= now.timeIntervalSince1970 + Self.lifetime + Self.clockSkew,
              token.issuedAt <= now.timeIntervalSince1970 + Self.clockSkew,
              expiry - token.issuedAt <= Self.lifetime + Self.clockSkew,
            IntercomGroup.isValidMemberID(recipientMemberID),
            !recipientMemberID.hasPrefix(GroupMember.pendingInvitePrefix),
              let targetBytes = IdentityEncoding.decode(recipientKey) else { throw DeviceIdentityProof.Failure.invalid }
        let target = try P256.KeyAgreement.PublicKey(x963Representation: targetBytes)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        var result = Self(id: deliveryID, sender: sender, recipient: recipient, senderMemberID: signer.memberID,
            recipientMemberID: recipientMemberID, recipientKey: recipientKey,
            ephemeralKey: IdentityEncoding.encode(ephemeral.publicKey.x963Representation), expiresAt: expiry,
            ciphertext: Data(),
            sourceRequestID: sourceRequestID)
        let aad = try result.header()
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: target)
        let key = DeviceIdentitySigner.sealedPayloadKey(secret, domain: Self.encryptionDomain, header: aad)
        guard let ciphertext = try AES.GCM.seal(
            JSONEncoder().encode(token), using: key, authenticating: aad
        ).combined else { throw DeviceIdentityProof.Failure.invalid }
        result.ciphertext = ciphertext
        guard result.ciphertext.count <= 8192 else { throw DeviceIdentityProof.Failure.invalid }
        result.proof = try signer.sign(result.message(), purpose: .deliverGroupInvitation)
        return result
    }
    @MainActor
    func open(recipient signer: DeviceIdentitySigner, local: AccountPrincipal, sender user: SavedUser?,
              now: Date = Date(), redeliveryTrust: DeviceIdentityTrust? = nil) throws -> GroupInviteToken {
        guard version == 1, sender.isValid, recipient == local, recipient.isValid, sender != recipient,
              sender.issuer == recipient.issuer, sourceRequestID != id,
              signer.principal == nil || signer.principal == local,
              recipientMemberID == signer.memberID, recipientKey == signer.publicKey,
              let proof,
            expiresAt.isFinite, expiresAt > now.timeIntervalSince1970,
            expiresAt <= now.timeIntervalSince1970 + Self.lifetime + Self.clockSkew,
            (29...8192).contains(ciphertext.count), let ephemeral = IdentityEncoding.decode(ephemeralKey),
            ephemeral.count == 65
        else { throw DeviceIdentityProof.Failure.invalid }
        if sourceRequestID != nil {
            guard let redeliveryTrust, signer.principal == local,
                  try proof.verify(message(), purpose: .deliverGroupInvitation, memberID: senderMemberID,
                    trust: redeliveryTrust, now: now
                ).principal == sender
            else { throw DeviceIdentityProof.Failure.invalid }
        } else {
            guard let user, user.principal == sender, user.isRegistered,
                  user.memberIDs.contains(senderMemberID), user.deviceKeys?[senderMemberID] == proof.publicKey
            else { throw DeviceIdentityProof.Failure.invalid }
            _ = try proof.verify(message(), purpose: .deliverGroupInvitation, memberID: senderMemberID)
        }
        let aad = try header()
        let data = try signer.openSealedPayload(
            ciphertext, ephemeralKey: ephemeral, domain: Self.encryptionDomain, header: aad)
        let token = try JSONDecoder().decode(GroupInviteToken.self, from: data)
        try token.validate()
        guard token.inviterMemberID == senderMemberID, token.identityProof?.publicKey == proof.publicKey,
              token.verifySignature(), token.expiresAt == expiresAt,
              token.issuedAt <= now.timeIntervalSince1970 + Self.clockSkew,
            expiresAt - token.issuedAt <= Self.lifetime + Self.clockSkew,
            !token.isExpired(now: now.timeIntervalSince1970),
            token.directInvitation?.context.contactBootstrap != true
        else { throw DeviceIdentityProof.Failure.invalid }
        return token
    }
    private func header() throws -> Data {
        var copy = self; copy.ciphertext = Data(); copy.proof = nil
        return try copy.message()
    }
    private func message() throws -> Data {
        var copy = self; copy.proof = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(copy)
    }

    func receiptDigest() throws -> Data { Data(SHA256.hash(data: try message())) }
}

/// The recipient's device attests that it saved this exact delivery.
nonisolated struct GroupInvitationReceipt: Codable, Sendable {
    let id: UUID
    let envelopeDigest: Data
    let proof: DeviceIdentityProof

    init(for envelope: GroupInvitationEnvelope, signer: DeviceIdentitySigner) throws {
        guard signer.memberID == envelope.recipientMemberID, signer.publicKey == envelope.recipientKey else {
            throw DeviceIdentityProof.Failure.invalid
        }
        id = envelope.id
        envelopeDigest = try envelope.receiptDigest()
        proof = try signer.sign(envelopeDigest, purpose: .acknowledgeGroupInvitation)
    }

    func verify(for envelope: GroupInvitationEnvelope) throws {
        guard id == envelope.id, proof.publicKey == envelope.recipientKey,
              envelopeDigest == (try envelope.receiptDigest()) else { throw DeviceIdentityProof.Failure.invalid }
        _ = try proof.verify(envelopeDigest, purpose: .acknowledgeGroupInvitation, memberID: envelope.recipientMemberID)
    }
}
