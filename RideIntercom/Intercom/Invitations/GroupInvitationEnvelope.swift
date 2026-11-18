import CryptoKit
import Foundation

/// Opaque transport for a signed group invitation, addressed to one previously verified device.
nonisolated struct GroupInvitationEnvelope: Codable, Sendable {
    private static let clockSkew: TimeInterval = 300
    private static let lifetime: TimeInterval = 7 * 86400

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

    static func seal(_ token: GroupInviteToken, sender: AccountPrincipal, recipient: AccountPrincipal,
                     recipientMemberID: String, recipientKey: String, signer: DeviceIdentitySigner,
                     now: Date = Date(), deliveryID: UUID = UUID()) throws -> Self {
        try token.validate()
        guard sender.isValid, recipient.isValid, sender.issuer == recipient.issuer, sender != recipient,
              signer.principal == nil || signer.principal == sender,
              token.inviterMemberID == signer.memberID, token.identityProof?.publicKey == signer.publicKey,
              token.verifySignature(), token.directInvitation?.context.contactBootstrap != true,
              let expiry = token.expiresAt, expiry > now.timeIntervalSince1970,
              expiry <= now.timeIntervalSince1970 + Self.lifetime + Self.clockSkew,
              token.issuedAt <= now.timeIntervalSince1970 + Self.clockSkew,
              expiry - token.issuedAt <= Self.lifetime + Self.clockSkew,
              IntercomGroup.isValidMemberID(recipientMemberID), !recipientMemberID.hasPrefix(GroupMember.pendingInvitePrefix),
              let targetBytes = IdentityEncoding.decode(recipientKey) else { throw DeviceIdentityProof.Failure.invalid }
        let target = try P256.KeyAgreement.PublicKey(x963Representation: targetBytes)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        var result = Self(id: deliveryID, sender: sender, recipient: recipient, senderMemberID: signer.memberID,
            recipientMemberID: recipientMemberID, recipientKey: recipientKey,
            ephemeralKey: IdentityEncoding.encode(ephemeral.publicKey.x963Representation), expiresAt: expiry, ciphertext: Data())
        let aad = try result.header()
        let secret = try ephemeral.sharedSecretFromKeyAgreement(with: target)
        let key = Self.key(secret, header: aad)
        result.ciphertext = try AES.GCM.seal(JSONEncoder().encode(token), using: key, authenticating: aad).combined!
        guard result.ciphertext.count <= 8192 else { throw DeviceIdentityProof.Failure.invalid }
        result.proof = try signer.sign(result.message(), purpose: .deliverGroupInvitation)
        return result
    }
    func open(recipient signer: DeviceIdentitySigner, local: AccountPrincipal, sender user: SavedUser,
              now: Date = Date()) throws -> GroupInviteToken {
        guard version == 1, sender.isValid, recipient == local, recipient.isValid, sender != recipient,
              sender.issuer == recipient.issuer, user.principal == sender, user.isRegistered,
              signer.principal == nil || signer.principal == local,
              recipientMemberID == signer.memberID, recipientKey == signer.publicKey,
              user.memberIDs.contains(senderMemberID), let proof, user.deviceKeys?[senderMemberID] == proof.publicKey,
              expiresAt.isFinite, expiresAt > now.timeIntervalSince1970, expiresAt <= now.timeIntervalSince1970 + Self.lifetime + Self.clockSkew,
              (29...8192).contains(ciphertext.count), let ephemeral = IdentityEncoding.decode(ephemeralKey), ephemeral.count == 65
        else { throw DeviceIdentityProof.Failure.invalid }
        _ = try proof.verify(message(), purpose: .deliverGroupInvitation, memberID: senderMemberID)
        let aad = try header()
        let data = try signer.decryptGroupInvitation(ciphertext, ephemeralKey: ephemeral, header: aad)
        let token = try JSONDecoder().decode(GroupInviteToken.self, from: data)
        try token.validate()
        guard token.inviterMemberID == senderMemberID, token.identityProof?.publicKey == proof.publicKey,
              token.verifySignature(), token.expiresAt == expiresAt,
              token.issuedAt <= now.timeIntervalSince1970 + Self.clockSkew,
              expiresAt - token.issuedAt <= Self.lifetime + Self.clockSkew, !token.isExpired(now: now.timeIntervalSince1970),
              token.directInvitation?.context.contactBootstrap != true else { throw DeviceIdentityProof.Failure.invalid }
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
    static func key(_ secret: SharedSecret, header: Data) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data("rideintercom.group-delivery.ecdh.v1".utf8), sharedInfo: header, outputByteCount: 32)
    }
}
