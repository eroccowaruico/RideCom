import CryptoKit
import Foundation

/// Both sides derive this address from a secret held by the confirmed device pair.
struct DirectRestoreDeviceAddress {
    private static let domain = "rideintercom.direct-restore.device.v1"
    fileprivate static let lifetime: TimeInterval = 86_400
    fileprivate static let maximumPacketCharacters = 8192

    let publisher: AccountPrincipal
    let reader: AccountPrincipal
    let slot: String
    private let callID: UUID
    private let fingerprint: String
    private let key: SymmetricKey

    static func seed(from pairCredential: String, registration: UUID) -> String? {
        guard let bytes = Data(base64Encoded: pairCredential), bytes.count == 32 else { return nil }
        let seed = HKDF<SHA256>.deriveKey(inputKeyMaterial: SymmetricKey(data: bytes),
            salt: Data("rideintercom.direct-restore.device.seed.v1".utf8),
            info: Data(registration.uuidString.utf8), outputByteCount: 32)
        return seed.withUnsafeBytes { IdentityEncoding.encode(Data($0)) }
    }

    fileprivate init(publisher: AccountPrincipal, reader: AccountPrincipal,
                     registration: UUID, fingerprint: String, seed: String) throws {
        guard publisher.isValid, reader.isValid, publisher != reader, publisher.issuer == reader.issuer,
              IdentityEncoding.decode(fingerprint)?.count == 32,
              let seed = IdentityEncoding.decode(seed), seed.count == 32
        else { throw DeviceIdentityProof.Failure.invalid }
        self.publisher = publisher
        self.reader = reader
        self.fingerprint = fingerprint
        callID = AccountCallPair(publisher, reader).id
        let fields = [publisher.issuer, publisher.userID, reader.userID, callID.uuidString,
                      registration.uuidString, fingerprint]
        let secret = SymmetricKey(data: seed)
        let salt = Data(Self.domain.utf8)
        let slotKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: secret, salt: salt, info: try restoreProofPayload(["slot"] + fields), outputByteCount: 32)
        slot = slotKey.withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() }
        key = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: secret, salt: salt, info: try restoreProofPayload(["certificate"] + fields),
            outputByteCount: 32)
    }

    fileprivate func verify(_ identity: VerifiedDeviceIdentity) throws {
        guard identity.issuer == publisher.issuer, identity.userID == publisher.userID,
              let binding = identity.sessionBinding, InternetAccountClient.notificationUserID(binding),
              try CallRelationshipRestoreRequest.recipientFingerprint(
                  callID: callID, memberID: identity.memberID, key: identity.deviceKey) == fingerprint
        else { throw DeviceIdentityProof.Failure.invalid }
    }

    fileprivate func seal(_ certificate: DeviceIdentityCertificate, expiresAt: Int64) throws -> String {
        guard let sealed = try AES.GCM.seal(restoreProofPayload(certificate), using: key,
                                           authenticating: header(expiresAt)).combined
        else { throw DeviceIdentityProof.Failure.invalid }
        return sealed.base64EncodedString()
    }

    fileprivate func open(_ packet: String, expiresAt: Int64) throws -> DeviceIdentityCertificate {
        guard packet.utf8.count <= Self.maximumPacketCharacters, let bytes = Data(base64Encoded: packet)
        else { throw DeviceIdentityProof.Failure.invalid }
        let plaintext = try AES.GCM.open(.init(combined: bytes), using: key, authenticating: header(expiresAt))
        return try JSONDecoder().decode(DeviceIdentityCertificate.self, from: plaintext)
    }

    private func header(_ expiresAt: Int64) throws -> Data {
        try JSONSerialization.data(withJSONObject: [Self.domain, slot, expiresAt], options: [.withoutEscapingSlashes])
    }
}

nonisolated struct DirectRestoreDevicePublication: Encodable, Sendable {
    let slot: String
    let reader: String
    let issuedAt: Int64
    let expiresAt: Int64
    let packet: String
    let proof: DeviceIdentityProof

    nonisolated struct Delivery: Decodable, Sendable {
        let expiresAt: Int64
        let packet: String

        @MainActor func open(at address: DirectRestoreDeviceAddress, as signer: DeviceIdentitySigner,
                             trust: DeviceIdentityTrust, now: Date) throws -> DeviceIdentityCertificate {
            let time = now.timeIntervalSince1970
            guard try CallRelationshipBackup.verifiedOwner(of: signer, now: time) == address.reader
            else { throw GroupStorageError.identityConflict }
            guard Double(expiresAt) > time * 1000,
                  Double(expiresAt) <= (time + DirectRestoreDeviceAddress.lifetime + 60) * 1000
            else { throw DeviceIdentityProof.Failure.invalid }
            let certificate = try address.open(packet, expiresAt: expiresAt)
            let identity = try certificate.verify(origin: trust.origin, trustedIssuerKey: trust.issuerKey, now: now)
            try address.verify(identity)
            guard Double(expiresAt) <= identity.expiresAt * 1000 else { throw DeviceIdentityProof.Failure.invalid }
            return certificate
        }
    }

    @MainActor fileprivate init(at address: DirectRestoreDeviceAddress, as signer: DeviceIdentitySigner,
                                now: Date) throws {
        let time = now.timeIntervalSince1970
        guard let identity = signer.identity, identity.expiresAt > time,
              let issuedAt = Int64(exactly: (time * 1000).rounded(.down)),
              let expiresAt = Int64(exactly: (min(time + DirectRestoreDeviceAddress.lifetime,
                                                  identity.expiresAt) * 1000).rounded(.down)),
              expiresAt > issuedAt else { throw DeviceIdentityProof.Failure.invalid }
        try address.verify(identity)
        let packet = try address.seal(identity.envelope, expiresAt: expiresAt)
        guard (40...DirectRestoreDeviceAddress.maximumPacketCharacters).contains(packet.utf8.count)
        else { throw DeviceIdentityProof.Failure.invalid }
        slot = address.slot
        reader = address.reader.userID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.packet = packet
        let signed = try JSONSerialization.data(withJSONObject: [slot, reader, issuedAt, expiresAt, packet],
                                                 options: [.withoutEscapingSlashes])
        proof = try signer.sign(signed, purpose: .publishDirectRestoreDevice)
    }
}

extension CallRelationshipBackup {
    func directRestoreDeviceAddress(for contactID: UUID, as signer: DeviceIdentitySigner,
                                    now: Date) throws -> DirectRestoreDeviceAddress? {
        _ = try validated(for: Self.verifiedOwner(of: signer, now: now.timeIntervalSince1970))
        guard let contact = contacts.first(where: { $0.id == contactID }),
              let registration = contact.confirmedRegistrationID, let fingerprint = contact.restoreRecipientFingerprint,
              let seed = contact.restoreDiscoverySeed
        else { return nil }
        return try .init(publisher: contact.principal, reader: owner, registration: registration,
                         fingerprint: fingerprint, seed: seed)
    }
}

extension GroupRepository {
    func directRestoreDevicePublication(for contactID: UUID, as signer: DeviceIdentitySigner,
                                        now: Date) throws -> DirectRestoreDevicePublication? {
        let backup = try callRelationshipBackup(as: signer, now: now.timeIntervalSince1970)
        guard let contact = backup.contacts.first(where: { $0.id == contactID }),
              contact.restoreRecipientFingerprint != nil, let registration = contact.confirmedRegistrationID,
              let seed = contact.restoreDiscoverySeed
        else { return nil }
        let callID = AccountCallPair(backup.owner, contact.principal).id
        let fingerprint = try CallRelationshipRestoreRequest.recipientFingerprint(
            callID: callID, memberID: signer.memberID, key: signer.publicKey)
        let address = try DirectRestoreDeviceAddress(publisher: backup.owner, reader: contact.principal,
                                                     registration: registration, fingerprint: fingerprint, seed: seed)
        return try .init(at: address, as: signer, now: now)
    }
}
