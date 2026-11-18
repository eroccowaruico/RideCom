import CryptoKit
import Foundation

/// Synthetic remote signer; the UI tests never call a real account or service.
enum InvitationURLFixture {
    enum Failure: Error { case invalidURL }

    static func make(inviter: String, sharedName: String? = nil, contact: Bool = false, name: String? = nil,
                     signingKey: P256.Signing.PrivateKey = .init(), expiresAfter: TimeInterval = 3600) throws -> URL {
        let groupID = UUID(), issuedAt = floor(Date().timeIntervalSince1970)
        let expiresAt = issuedAt + expiresAfter
        let secret = "ui-test-invitation-key"
        let groupName = name ?? (contact ? "Contact Invitation" : "Talk Group")
        let publicKey = base64url(signingKey.publicKey.x963Representation)
        struct Context: Encodable {
            let id: UUID; let groupID: UUID; let inviterMemberID: String
            let inviterDeviceKey: String; let expiresAt: Double; let contactBootstrap: Bool?
        }
        struct Grant: Encodable { let context: Context; let secret: String }
        let grant = Grant(context: .init(id: UUID(), groupID: groupID, inviterMemberID: inviter,
            inviterDeviceKey: publicKey, expiresAt: expiresAt, contactBootstrap: contact ? true : nil),
            secret: Data(repeating: 42, count: 32).base64EncodedString())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let grantData = try encoder.encode(grant)
        let fields = ["6", groupID.uuidString, groupName, secret, inviter, String(format: "%.3f", issuedAt),
            String(format: "%.3f", expiresAt), "", Data((sharedName ?? "").utf8).base64EncodedString(), grantData.base64EncodedString()]
        let signature = HMAC<SHA256>.authenticationCode(for: Data(fields.joined(separator: "|").utf8),
            using: SymmetricKey(data: Data(secret.utf8))).map { String(format: "%02x", $0) }.joined()
        var signed = Data("rideintercom.device-proof.v1\0".utf8)
        for field in [Data("issueInvitation".utf8), Data(inviter.utf8), Data(publicKey.utf8), Data(), Data(), Data(signature.utf8)] {
            var count = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &count) { signed.append(contentsOf: $0) }
            signed.append(field)
        }
        let identityProof = ["publicKey": publicKey, "signature": base64url(try signingKey.signature(for: signed).rawRepresentation)]
        var object: [String: Any] = ["version": 6, "groupID": groupID.uuidString, "groupName": groupName,
            "groupSecret": secret, "inviterMemberID": inviter, "issuedAt": issuedAt, "expiresAt": expiresAt,
            "directInvitation": try JSONSerialization.jsonObject(with: grantData), "signature": signature, "identityProof": identityProof]
        object["inviterDisplayName"] = sharedName
        let encoded = base64url(try JSONSerialization.data(withJSONObject: object))
        guard let url = URL(string: "rideintercom://\(contact ? "contact" : "join")?token=\(encoded)") else { throw Failure.invalidURL }
        return url
    }

    static func acknowledgement(_ reply: URL, signingKey: P256.Signing.PrivateKey) throws -> URL {
        guard let raw = URLComponents(url: reply, resolvingAgainstBaseURL: false)?.queryItems?.first?.value else { throw Failure.invalidURL }
        var encoded = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded), var object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let inviter = object["inviterMemberID"] as? String else { throw Failure.invalidURL }
        object["kind"] = "acknowledged"
        let message = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        let publicKey = base64url(signingKey.publicKey.x963Representation)
        var signed = Data("rideintercom.device-proof.v1\0".utf8)
        for field in [Data("acknowledgeInvitation".utf8), Data(inviter.utf8), Data(publicKey.utf8), Data(), Data(), message] {
            var count = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &count) { signed.append(contentsOf: $0) }; signed.append(field)
        }
        object["acknowledgementProof"] = ["publicKey": publicKey, "signature": base64url(try signingKey.signature(for: signed).rawRepresentation)]
        guard let url = URL(string: "rideintercom://contact-reply?receipt=" + base64url(try JSONSerialization.data(withJSONObject: object))) else { throw Failure.invalidURL }
        return url
    }

    static func acceptance(_ invitation: URL, invitee: String, sharedName: String,
                           signingKey: P256.Signing.PrivateKey = .init()) throws -> URL {
        guard let raw = URLComponents(url: invitation, resolvingAgainstBaseURL: false)?.queryItems?.first?.value else { throw Failure.invalidURL }
        var encoded = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded), let token = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let grant = token["directInvitation"] as? [String: Any], let context = grant["context"] as? [String: Any],
              let secret = grant["secret"] as? String, let secretBytes = Data(base64Encoded: secret),
              let id = context["id"] as? String, let inviter = context["inviterMemberID"] as? String,
              let group = context["groupID"] as? String else { throw Failure.invalidURL }
        var hash = Array(SHA256.hash(data: Data(("rideintercom.invitation-receipt.v2|" + id + "|" + invitee).utf8)).prefix(16))
        hash[6] = (hash[6] & 0x0f) | 0x80; hash[8] = (hash[8] & 0x3f) | 0x80
        let receiptID = UUID(uuid: (hash[0],hash[1],hash[2],hash[3],hash[4],hash[5],hash[6],hash[7],hash[8],hash[9],hash[10],hash[11],hash[12],hash[13],hash[14],hash[15])).uuidString
        let publicKey = base64url(signingKey.publicKey.x963Representation)
        let proofFields: [String: Any] = ["receiptID": receiptID, "inviteeMemberID": invitee, "inviteeDeviceKey": publicKey, "invitation": context]
        let proofBytes = Data("rideintercom.direct-invitation.receipt.v2\0".utf8) + (try JSONSerialization.data(withJSONObject: proofFields, options: [.sortedKeys]))
        let proof = Data(HMAC<SHA256>.authenticationCode(for: proofBytes, using: SymmetricKey(data: secretBytes))).base64EncodedString()
        var object: [String: Any] = ["id": receiptID, "groupID": group, "inviterMemberID": inviter, "inviteeMemberID": invitee,
            "inviteeDeviceKey": publicKey, "displayName": sharedName, "invitation": context, "proof": proof]
        let message = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        var signed = Data("rideintercom.device-proof.v1\0".utf8)
        for field in [Data("acceptInvitation".utf8), Data(invitee.utf8), Data(publicKey.utf8), Data(), Data(), message] {
            var count = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &count) { signed.append(contentsOf: $0) }; signed.append(field)
        }
        object["kind"] = "accepted"
        object["acceptanceProof"] = ["publicKey": publicKey, "signature": base64url(try signingKey.signature(for: signed).rawRepresentation)]
        guard let url = URL(string: "rideintercom://contact-reply?receipt=" + base64url(try JSONSerialization.data(withJSONObject: object))) else { throw Failure.invalidURL }
        return url
    }

    private static func base64url(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
