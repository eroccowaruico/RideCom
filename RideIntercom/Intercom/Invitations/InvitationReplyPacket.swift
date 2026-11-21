import CryptoKit
import Foundation

nonisolated struct InvitationReplyAddress: Sendable {
    let slot: String
    let expiresAt: Int64

    @MainActor init(invitation: DirectInvitationContext, credential: GroupAccessCredential) throws {
        guard invitation.isOrdinaryGroupInvitation, invitation.isValid, invitation.groupID == credential.groupID
        else { throw DeviceIdentityProof.Failure.invalid }
        try self.init(invitation: invitation, secret: credential.secret, salt: "rideintercom.ordinary-group-reply.slot.v1")
    }

    @MainActor init(contactToken: GroupInviteToken) throws {
        try contactToken.validate(contactBootstrap: true)
        guard contactToken.verifySignature(), let invitation = contactToken.directInvitation?.context else {
            throw DeviceIdentityProof.Failure.invalid
        }
        try self.init(invitation: invitation, secret: contactToken.groupSecret, salt: "rideintercom.contact-invitation-reply.slot.v1")
    }

    @MainActor private init(invitation: DirectInvitationContext, secret: String, salt: String) throws {
        guard !secret.isEmpty, let expiry = Int64(exactly: (invitation.expiresAt * 1000).rounded(.down)),
              (1...9_007_199_254_740_991).contains(expiry) else { throw DeviceIdentityProof.Failure.invalid }
        let info = Data([invitation.groupID.uuidString, invitation.id.uuidString].joined(separator: "\0").utf8)
        let key = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: Data(secret.utf8)),
            salt: Data(salt.utf8), info: info, outputByteCount: 32)
        slot = key.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
        expiresAt = expiry
    }
}

/// The Worker relays the UUID and opaque bytes. The peer's identities and signatures travel inside the sealed receipt.
nonisolated struct InvitationReplyPacket: Decodable, Sendable {
    let id: UUID
    let packet: String

    // Keep the existing packet domain; the authenticated slot separates the two types of invitation.
    private static let domain = "rideintercom.ordinary-group-reply.ecdh.v1"
    private static let publicKeyBytes = 65
    private static let maximumPlaintextBytes = 8192
    private static let maximumPacketCharacters = 12 * 1024
    private static let gcmOverheadBytes = 28

    @MainActor static func seal(_ receipt: DirectInvitationReceipt, address: InvitationReplyAddress,
                                invitation: DirectInvitationContext, now: TimeInterval = Date().timeIntervalSince1970) throws -> Self {
        guard matches(receipt, invitation: invitation, id: receipt.id, kind: receipt.kind, now: now),
              let target = receipt.kind == .accepted ? invitation.inviterDeviceKey : receipt.inviteeDeviceKey,
              let keyBytes = IdentityEncoding.decode(target) else { throw DeviceIdentityProof.Failure.invalid }
        let plaintext = try JSONEncoder().encode(receipt)
        guard plaintext.count <= maximumPlaintextBytes else { throw DeviceIdentityProof.Failure.invalid }
        let header = Self.header(address, id: receipt.id, kind: receipt.kind)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let receiver = try P256.KeyAgreement.PublicKey(x963Representation: keyBytes)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: receiver)
        let key = DeviceIdentitySigner.sealedPayloadKey(shared, domain: domain, header: header)
        guard let sealed = try AES.GCM.seal(plaintext, using: key, authenticating: header).combined else {
            throw DeviceIdentityProof.Failure.invalid
        }
        return .init(id: receipt.id, packet: (ephemeral.publicKey.x963Representation + sealed).base64EncodedString())
    }

    @MainActor func open(address: InvitationReplyAddress, invitation: DirectInvitationContext, kind: DirectInvitationReceipt.Kind,
                         signer: DeviceIdentitySigner, now: TimeInterval = Date().timeIntervalSince1970) throws -> DirectInvitationReceipt {
        let overhead = Self.publicKeyBytes + Self.gcmOverheadBytes
        guard now.isFinite, now < invitation.expiresAt, packet.utf8.count <= Self.maximumPacketCharacters,
              let bytes = Data(base64Encoded: packet), bytes.count > overhead, bytes.count <= overhead + Self.maximumPlaintextBytes
        else { throw DeviceIdentityProof.Failure.invalid }
        let header = Self.header(address, id: id, kind: kind)
        let plaintext = try signer.openSealedPayload(bytes.dropFirst(Self.publicKeyBytes), ephemeralKey: bytes.prefix(Self.publicKeyBytes),
                                                     domain: Self.domain, header: header)
        let receipt = try JSONDecoder().decode(DirectInvitationReceipt.self, from: plaintext)
        let target = kind == .accepted ? receipt.inviterMemberID : receipt.inviteeMemberID
        let key = kind == .accepted ? invitation.inviterDeviceKey : receipt.inviteeDeviceKey
        guard Self.matches(receipt, invitation: invitation, id: id, kind: kind, now: now), target == signer.memberID, key == signer.publicKey
        else { throw DeviceIdentityProof.Failure.invalid }
        return receipt
    }

    @MainActor private static func matches(_ receipt: DirectInvitationReceipt, invitation: DirectInvitationContext, id: UUID,
                                          kind: DirectInvitationReceipt.Kind, now: TimeInterval) -> Bool {
        (invitation.isOrdinaryGroupInvitation || invitation.contactBootstrap == true)
            && now.isFinite && now < invitation.expiresAt && receipt.isValid
            && receipt.invitation == invitation && receipt.id == id && receipt.kind == kind
            && receipt.id == DirectInvitationReceipt.receiptID(invitationID: invitation.id, inviteeMemberID: receipt.inviteeMemberID)
            && receipt.proof != nil && receipt.acceptanceProof != nil && (receipt.acknowledgementProof != nil) == (kind == .acknowledged)
    }

    @MainActor private static func header(_ address: InvitationReplyAddress, id: UUID, kind: DirectInvitationReceipt.Kind) -> Data {
        Data([domain, address.slot, id.uuidString.lowercased(), kind.rawValue].joined(separator: "\0").utf8)
    }
}
