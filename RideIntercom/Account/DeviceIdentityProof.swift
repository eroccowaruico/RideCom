import CryptoKit
import Foundation

nonisolated struct AccountPrincipal: Codable, Equatable, Hashable, Sendable {
    let issuer: String
    let userID: String
    var isValid: Bool {
        guard let url = try? InternetAccountClient.origin(issuer), IdentityEncoding.origin(url) == issuer else { return false }
        return userID.utf8.count == 64 && userID.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

/// Loaded only from our previously authenticated service response, never a peer.
nonisolated struct DeviceIdentityTrust: Sendable {
    let origin: URL
    let issuerKey: String
}

nonisolated struct DeviceIdentityProof: Codable, Equatable, Sendable {
    enum Purpose: String {
        case issueInvitation, acceptInvitation, acknowledgeInvitation
        case shareDisplayName, shareCallAccess, callNotificationPermission
        case deliverGroupInvitation, acknowledgeGroupInvitation, requestGroupInvitationRedelivery
        case cancelGroupInvitation, acknowledgeGroupInvitationCancellation
        case deleteContact, acknowledgeContactDeletion
        case readContactDeletion, acknowledgeContactDeletionRelay
    }
    let publicKey: String
    var certificate: DeviceIdentityCertificate?
    let signature: String
    enum Failure: Error { case invalid }

    static func isValidPublicKey(_ value: String) -> Bool {
        guard let bytes = IdentityEncoding.decode(value), bytes.count == 65 else { return false }
        return (try? P256.Signing.PublicKey(x963Representation: bytes)) != nil
    }

    func verify(_ payload: Data, purpose: Purpose, memberID: String, trust: DeviceIdentityTrust? = nil,
                now: Date = Date()) throws -> VerifiedDeviceProof {
        guard let keyBytes = IdentityEncoding.decode(publicKey), keyBytes.count == 65,
              let signatureBytes = IdentityEncoding.decode(signature) else { throw Failure.invalid }
        let key = try P256.Signing.PublicKey(x963Representation: keyBytes)
        let message = try Self.message(payload, purpose: purpose, memberID: memberID, publicKey: publicKey, certificate: certificate)
        guard key.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation: signatureBytes), for: message) else { throw Failure.invalid }
        var principal: AccountPrincipal?
        if let trust, let certificate,
           let identity = try? certificate.verify(origin: trust.origin, trustedIssuerKey: trust.issuerKey, now: now) {
            guard identity.memberID == memberID, identity.deviceKey == publicKey else { throw Failure.invalid }
            principal = AccountPrincipal(issuer: identity.issuer, userID: identity.userID)
        }
        // Missing/expired/foreign certification never asserts an account. The
        // device key can still prove a direct Local invitation offline.
        return VerifiedDeviceProof(memberID: memberID, publicKey: publicKey, principal: principal)
    }

    fileprivate static func message(_ payload: Data, purpose: Purpose, memberID: String, publicKey: String,
                                    certificate: DeviceIdentityCertificate?) throws -> Data {
        guard payload.count <= 16_384, IntercomGroup.isValidMemberID(memberID), !memberID.hasPrefix("invite-pending-"),
              publicKey.utf8.count == 87, (certificate?.certificate.utf8.count ?? 0) <= 4096,
              (certificate?.issuerKey.utf8.count ?? 0) <= 87 else { throw Failure.invalid }
        var result = Data("rideintercom.device-proof.v1\0".utf8)
        for field in [Data(purpose.rawValue.utf8), Data(memberID.utf8), Data(publicKey.utf8),
                      Data((certificate?.certificate ?? "").utf8), Data((certificate?.issuerKey ?? "").utf8), payload] {
            var count = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &count) { result.append(contentsOf: $0) }
            result.append(field)
        }
        return result
    }
}

nonisolated struct DeviceIdentitySigner: Sendable {
    let memberID: String
    let publicKey: String
    let principal: AccountPrincipal?
    private let key: P256.Signing.PrivateKey
    private let certificate: DeviceIdentityCertificate?
    init(memberID: String, key: P256.Signing.PrivateKey, identity: VerifiedDeviceIdentity? = nil) throws {
        let publicKey = IdentityEncoding.encode(key.publicKey.x963Representation)
        guard IntercomGroup.isValidMemberID(memberID), !memberID.hasPrefix("invite-pending-"),
              identity.map({ $0.memberID == memberID && $0.deviceKey == publicKey }) ?? true else { throw DeviceIdentityProof.Failure.invalid }
        self.principal = identity.map { AccountPrincipal(issuer: $0.issuer, userID: $0.userID) }
        self.memberID = memberID; self.key = key; self.publicKey = publicKey; self.certificate = identity?.envelope
    }
    static let nearbyGroupDeliveryDomain = "rideintercom.group-delivery.nearby.v1"

    /// The private scalar stays inside the signer; only authenticated plaintext is returned.
    func openSealedPayload(_ ciphertext: Data, ephemeralKey: Data, domain: String, header: Data) throws -> Data {
        let secret = try sharedSecret(with: ephemeralKey)
        let key = Self.sealedPayloadKey(secret, domain: domain, header: header)
        return try AES.GCM.open(.init(combined: ciphertext), using: key, authenticating: header)
    }

    static func sealedPayloadKey(_ secret: SharedSecret, domain: String, header: Data) -> SymmetricKey {
        secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(domain.utf8), sharedInfo: header, outputByteCount: 32)
    }

    /// Both ends derive this value from their own key and a previously verified peer key.
    func nearbyGroupDeliverySecret(peerMemberID: String, peerPublicKey: String) throws -> Data {
        try devicePairKey(peerMemberID: peerMemberID, peerPublicKey: peerPublicKey,
                          domain: Self.nearbyGroupDeliveryDomain).withUnsafeBytes { Data($0) }
    }

    func contactDeletionRelayKey(peerMemberID: String, peerPublicKey: String, slot: String) throws -> SymmetricKey {
        try devicePairKey(peerMemberID: peerMemberID, peerPublicKey: peerPublicKey,
                          domain: "rideintercom.contact-deletion.relay.v1", context: [slot])
    }

    func ordinaryGroupDirectCallSecret(peerMemberID: String, peerPublicKey: String, receiptID: UUID) throws -> String {
        try devicePairKey(peerMemberID: peerMemberID, peerPublicKey: peerPublicKey,
                          domain: "rideintercom.ordinary-group-direct-call.v1", context: [receiptID.uuidString])
            .withUnsafeBytes { Data($0).base64EncodedString() }
    }

    private func devicePairKey(peerMemberID: String, peerPublicKey: String,
                               domain: String, context: [String] = []) throws -> SymmetricKey {
        guard IntercomGroup.isValidMemberID(peerMemberID), !peerMemberID.hasPrefix("invite-pending-"),
              peerMemberID != memberID, peerPublicKey != publicKey,
              let peerKey = IdentityEncoding.decode(peerPublicKey), peerKey.count == 65
        else { throw DeviceIdentityProof.Failure.invalid }
        let devices = [(memberID, publicKey), (peerMemberID, peerPublicKey)].sorted { $0.0 < $1.0 }
        // IDs and encoded keys cannot contain NUL. Bind each key to its device ID in a canonical order.
        let info = (devices.flatMap { [$0.0, $0.1] } + context).joined(separator: "\0")
        let secret = try sharedSecret(with: peerKey)
        return secret.hkdfDerivedSymmetricKey(using: SHA256.self, salt: Data(domain.utf8),
            sharedInfo: Data(info.utf8), outputByteCount: 32)
    }

    private func sharedSecret(with publicKey: Data) throws -> SharedSecret {
        let agreement = try P256.KeyAgreement.PrivateKey(rawRepresentation: key.rawRepresentation)
        let peer = try P256.KeyAgreement.PublicKey(x963Representation: publicKey)
        return try agreement.sharedSecretFromKeyAgreement(with: peer)
    }

    func sign(_ payload: Data, purpose: DeviceIdentityProof.Purpose) throws -> DeviceIdentityProof {
        let message = try DeviceIdentityProof.message(payload, purpose: purpose, memberID: memberID, publicKey: publicKey, certificate: certificate)
        return DeviceIdentityProof(publicKey: publicKey, certificate: certificate,
                                   signature: IdentityEncoding.encode(try key.signature(for: message).rawRepresentation))
    }
}

nonisolated struct VerifiedDeviceProof {
    let memberID: String
    let publicKey: String
    let principal: AccountPrincipal?
    fileprivate init(memberID: String, publicKey: String, principal: AccountPrincipal?) {
        self.memberID = memberID; self.publicKey = publicKey; self.principal = principal
    }
}
