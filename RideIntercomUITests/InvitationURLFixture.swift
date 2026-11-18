import CryptoKit
import Foundation
import CoreFoundation

/// Synthetic remote signer; the UI tests never call a real account or service.
enum InvitationURLFixture {
    enum Failure: Error { case invalidURL }

    static func make(inviter: String, sharedName: String? = nil, contact: Bool = false, name: String? = nil,
                     signingKey: P256.Signing.PrivateKey = .init(), expiresAfter: TimeInterval = 3600,
                     invitedGroupName: String? = nil, directRecipient: String? = nil) throws -> URL {
        let groupID = directRecipient.map { directCallID(inviter, $0) } ?? UUID()
        let issuedAt = floor(Date().timeIntervalSince1970)
        let expiresAt = issuedAt + expiresAfter
        let secret = "ui-test-invitation-key"
        let groupName = name ?? (contact ? "Contact Invitation" : "Talk Group")
        let publicKey = base64url(signingKey.publicKey.x963Representation)
        let invitedGroup = invitedGroupName.map { ["id": UUID().uuidString, "name": $0, "secret": "ui-test-group-key"] }
        let attachmentData = try invitedGroup.map { try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys]) }
        let attachmentDigest = attachmentData.map { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        struct Context: Encodable {
            let id: UUID; let groupID: UUID; let inviterMemberID: String
            let inviterDeviceKey: String; let recipientMemberID: String?
            let expiresAt: Double; let contactBootstrap: Bool?
            let invitedGroupID: String?; let invitedGroupDigest: String?
        }
        struct Grant: Encodable { let context: Context; let secret: String }
        let grant = Grant(context: .init(id: UUID(), groupID: groupID, inviterMemberID: inviter,
            inviterDeviceKey: publicKey, recipientMemberID: directRecipient, expiresAt: expiresAt,
            contactBootstrap: contact ? true : nil, invitedGroupID: invitedGroup?["id"], invitedGroupDigest: attachmentDigest),
            secret: Data(repeating: 42, count: 32).base64EncodedString())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let grantData = try encoder.encode(grant)
        var fields = ["6", groupID.uuidString, groupName, secret, inviter, String(format: "%.3f", issuedAt),
            String(format: "%.3f", expiresAt), directRecipient ?? "", Data((sharedName ?? "").utf8).base64EncodedString(), grantData.base64EncodedString()]
        if let attachmentData { fields.append(attachmentData.base64EncodedString()) }
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
        object["recipientMemberID"] = directRecipient
        object["invitedGroup"] = invitedGroup
        let encoded = base64url(try JSONSerialization.data(withJSONObject: object))
        guard let url = URL(string: "rideintercom://\(contact ? "contact" : "join")?token=\(encoded)") else { throw Failure.invalidURL }
        return url
    }

    static func fields(from url: URL) throws -> [String: Any] {
        guard let field = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value else {
            throw Failure.invalidURL
        }
        var encoded = field.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded),
              let fields = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { throw Failure.invalidURL }
        return fields
    }

    private static func directCallID(_ inviter: String, _ recipient: String) -> UUID {
        let members = [inviter, recipient].sorted().joined(separator: "|")
        var bytes = Array(SHA256.hash(data: Data(("rideintercom.direct-call.v1|" + members).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func acknowledgement(_ reply: URL, signingKey: P256.Signing.PrivateKey) throws -> URL {
        guard let raw = URLComponents(url: reply, resolvingAgainstBaseURL: false)?.queryItems?.first?.value else { throw Failure.invalidURL }
        var encoded = raw.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded), var object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let inviter = object["inviterMemberID"] as? String else { throw Failure.invalidURL }
        object["kind"] = "acknowledged"
        let message = try canonicalData(object)
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
        let proofBytes = Data("rideintercom.direct-invitation.receipt.v2\0".utf8) + (try canonicalData(proofFields))
        let proof = Data(HMAC<SHA256>.authenticationCode(for: proofBytes, using: SymmetricKey(data: secretBytes))).base64EncodedString()
        var object: [String: Any] = ["id": receiptID, "groupID": group, "inviterMemberID": inviter, "inviteeMemberID": invitee,
            "inviteeDeviceKey": publicKey, "displayName": sharedName, "invitation": context, "proof": proof]
        let message = try canonicalData(object)
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

    /// Match the product's Codable representation, including fractional timestamp spelling.
    static func canonicalData(_ object: [String: Any]) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(CanonicalJSON(value: object))
    }

    private struct CanonicalJSON: Encodable {
        let value: Any
        private struct Key: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init(_ value: String) { stringValue = value }
            init?(stringValue: String) { self.init(stringValue) }
            init?(intValue: Int) { return nil }
        }
        func encode(to encoder: Encoder) throws {
            if let object = value as? [String: Any] {
                var container = encoder.container(keyedBy: Key.self)
                for (key, value) in object { try container.encode(Self(value: value), forKey: Key(key)) }
            } else if let array = value as? [Any] {
                var container = encoder.unkeyedContainer()
                for value in array { try container.encode(Self(value: value)) }
            } else {
                var container = encoder.singleValueContainer()
                if let string = value as? String { try container.encode(string) }
                else if let number = value as? NSNumber {
                    if CFGetTypeID(number) == CFBooleanGetTypeID() { try container.encode(number.boolValue) }
                    else { try container.encode(number.doubleValue) }
                } else if value is NSNull { try container.encodeNil() }
                else { throw Failure.invalidURL }
            }
        }
    }

    private static func base64url(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
