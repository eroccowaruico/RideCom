import CryptoKit
import Foundation

/// The Worker receives routing fields and ciphertext. The restoration proofs stay inside the ciphertext.
enum DirectCallRestoreRelayPacket {
    private static let domain = "rideintercom.direct-restore.relay.ecdh.v1"
    private static let publicKeyBytes = 65
    private static let overheadBytes = publicKeyBytes + 28
    private static let maximumPacketCharacters = 24_576
    private static let maximumPlaintextBytes = maximumPacketCharacters * 3 / 4 - overheadBytes
    private static let lifetime: TimeInterval = 300

    enum Content: Codable {
        case request(value: CallRelationshipRestoreRequest)
        case response(value: DirectCallRestoreResponse)
    }

    struct Submission: Encodable {
        let id: String
        let recipient: String
        let deviceID: String
        let sessionBinding: String
        let expiresAt: Int64
        let packet: String
        let proof: DeviceIdentityProof
    }

    struct Delivery: Decodable {
        let id: String
        let senderUserID: String
        let expiresAt: Int64
        let packet: String

        func openRequest(as signer: DeviceIdentitySigner, trust: DeviceIdentityTrust, now: Date) throws
            -> (request: CallRelationshipRestoreRequest, replyTo: VerifiedDeviceIdentity) {
            guard case let .request(request) = try open(as: signer, now: now),
                  let sender = try request.verifiedDirectRequesterIdentity(addressedTo: signer, trust: trust, now: now),
                  sender.userID == senderUserID, sessionBinding(of: sender, now: now) != nil
            else { throw DeviceIdentityProof.Failure.invalid }
            return (request, sender)
        }

        func openResponse(for request: CallRelationshipRestoreRequest, as signer: DeviceIdentitySigner,
                          trust: DeviceIdentityTrust, now: Date) throws -> DirectCallRestoreResponse {
            guard case let .response(response) = try open(as: signer, now: now),
                  try response.confirmation.verify(for: request, as: signer, trust: trust, now: now)
                    .responder.principal.userID == senderUserID
            else { throw DeviceIdentityProof.Failure.invalid }
            return response
        }

        private func open(as signer: DeviceIdentitySigner, now: Date) throws -> Content {
            let time = now.timeIntervalSince1970
            guard let recipient = signer.identity, let binding = sessionBinding(of: recipient, now: now),
                  senderUserID != recipient.userID, InternetAccountClient.notificationUserID(senderUserID),
                  UUID(uuidString: id)?.uuidString.lowercased() == id,
                  Double(expiresAt) > time * 1000, Double(expiresAt) <= (time + lifetime) * 1000,
                  Double(expiresAt) <= recipient.expiresAt * 1000,
                  packet.utf8.count <= maximumPacketCharacters, let bytes = Data(base64Encoded: packet),
                  (overheadBytes + 1...overheadBytes + maximumPlaintextBytes).contains(bytes.count)
            else { throw DeviceIdentityProof.Failure.invalid }
            let header = try header(for: recipient, binding: binding, senderUserID: senderUserID,
                                    id: id, expiresAt: expiresAt)
            let plaintext = try signer.openSealedPayload(bytes.dropFirst(publicKeyBytes),
                ephemeralKey: bytes.prefix(publicKeyBytes), domain: domain, header: header)
            return try JSONDecoder().decode(Content.self, from: plaintext)
        }
    }

    static func seal(_ content: Content, to recipient: VerifiedDeviceIdentity, as signer: DeviceIdentitySigner,
                     now: Date) throws -> Submission {
        let time = now.timeIntervalSince1970
        guard let sender = signer.identity, sessionBinding(of: sender, now: now) != nil,
              let binding = sessionBinding(of: recipient, now: now),
              sender.issuer == recipient.issuer, sender.envelope.issuerKey == recipient.envelope.issuerKey,
              sender.userID != recipient.userID, let recipientKey = IdentityEncoding.decode(recipient.deviceKey)
        else { throw DeviceIdentityProof.Failure.invalid }
        let deadline = min(time + lifetime, sender.expiresAt, recipient.expiresAt)
        guard let expiresAt = Int64(exactly: (deadline * 1000).rounded(.down)), Double(expiresAt) > time * 1000
        else { throw DeviceIdentityProof.Failure.invalid }

        let id = UUID().uuidString.lowercased()
        let plaintext = try restoreProofPayload(content)
        guard plaintext.count <= maximumPlaintextBytes else { throw DeviceIdentityProof.Failure.invalid }
        let aad = try header(for: recipient, binding: binding, senderUserID: sender.userID,
                             id: id, expiresAt: expiresAt)
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let target = try P256.KeyAgreement.PublicKey(x963Representation: recipientKey)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: target)
        let key = DeviceIdentitySigner.sealedPayloadKey(shared, domain: domain, header: aad)
        guard let ciphertext = try AES.GCM.seal(plaintext, using: key, authenticating: aad).combined
        else { throw DeviceIdentityProof.Failure.invalid }
        let packet = (ephemeral.publicKey.x963Representation + ciphertext).base64EncodedString()
        let fields: [Any] = [recipient.userID, recipient.deviceID, binding, id, expiresAt, packet]
        let proof = try signer.sign(try fieldsJSON(fields), purpose: .submitDirectCallRestoreRelay)
        return .init(id: id, recipient: recipient.userID, deviceID: recipient.deviceID, sessionBinding: binding,
                     expiresAt: expiresAt, packet: packet, proof: proof)
    }

    private static func sessionBinding(of identity: VerifiedDeviceIdentity, now: Date) -> String? {
        guard identity.expiresAt > now.timeIntervalSince1970, let binding = identity.sessionBinding,
              InternetAccountClient.notificationUserID(binding) else { return nil }
        return binding
    }

    private static func header(for recipient: VerifiedDeviceIdentity, binding: String, senderUserID: String,
                               id: String, expiresAt: Int64) throws -> Data {
        try fieldsJSON([domain, recipient.userID, recipient.deviceID, binding, id, expiresAt, senderUserID])
    }

    private static func fieldsJSON(_ fields: [Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields, options: [.withoutEscapingSlashes])
    }
}
