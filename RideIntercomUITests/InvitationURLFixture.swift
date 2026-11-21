import CoreFoundation
import CryptoKit
import Foundation

/// Synthetic remote signer; the UI tests never call a real account or service.
enum InvitationURLFixture {
    enum Failure: Error { case invalidURL }

    static func make(
        inviter: String,
        sharedName: String? = nil,
        contact: Bool = false,
        name: String? = nil,
        signingKey: P256.Signing.PrivateKey = .init(),
        expiresAfter: TimeInterval = 3600,
        invitedGroupName: String? = nil,
        directRecipient: String? = nil
    ) throws -> URL {
        let groupID = directRecipient.map { directCallID(inviter, $0) } ?? UUID()
        let issuedAt = floor(Date().timeIntervalSince1970)
        let expiresAt = issuedAt + expiresAfter
        let secret = "ui-test-invitation-key"
        let groupName = name ?? (contact ? "Contact Invitation" : "Talk Group")
        let publicKey = base64url(signingKey.publicKey.x963Representation)
        let invitedGroup = invitedGroupName.map { ["id": UUID().uuidString, "name": $0, "secret": "ui-test-group-key"] }
        let attachmentData = try invitedGroup.map {
            try JSONSerialization.data(withJSONObject: $0, options: [.sortedKeys])
        }
        let attachmentDigest = attachmentData.map { hex(SHA256.hash(data: $0)) }
        let context = Context(
            id: UUID(), groupID: groupID, inviterMemberID: inviter, inviterDeviceKey: publicKey,
            recipientMemberID: directRecipient, expiresAt: expiresAt, contactBootstrap: contact ? true : nil,
            invitedGroupID: invitedGroup?["id"], invitedGroupDigest: attachmentDigest
        )
        let grant = Grant(context: context, secret: Data(repeating: 42, count: 32).base64EncodedString())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let grantData = try encoder.encode(grant)
        var fields = [
            "6", groupID.uuidString, groupName, secret, inviter, String(format: "%.3f", issuedAt),
            String(format: "%.3f", expiresAt), directRecipient ?? "",
            Data((sharedName ?? "").utf8).base64EncodedString(), grantData.base64EncodedString()
        ]
        if let attachmentData { fields.append(attachmentData.base64EncodedString()) }
        let signature = hex(HMAC<SHA256>.authenticationCode(
            for: Data(fields.joined(separator: "|").utf8), using: SymmetricKey(data: Data(secret.utf8))
        ))
        let identityProof = try signedProof(
            "issueInvitation", memberID: inviter, publicKey: publicKey, message: Data(signature.utf8), key: signingKey
        )
        var object: [String: Any] = [
            "version": 6, "groupID": groupID.uuidString, "groupName": groupName, "groupSecret": secret,
            "inviterMemberID": inviter, "issuedAt": issuedAt, "expiresAt": expiresAt,
            "directInvitation": try JSONSerialization.jsonObject(with: grantData),
            "signature": signature, "identityProof": identityProof
        ]
        object["inviterDisplayName"] = sharedName
        object["recipientMemberID"] = directRecipient
        object["invitedGroup"] = invitedGroup
        return try makeURL(endpoint: contact ? "contact" : "join", query: "token", object: object)
    }

    private struct Context: Encodable {
        let id: UUID
        let groupID: UUID
        let inviterMemberID: String
        let inviterDeviceKey: String
        let recipientMemberID: String?
        let expiresAt: Double
        let contactBootstrap: Bool?
        let invitedGroupID: String?
        let invitedGroupDigest: String?
    }

    private struct Grant: Encodable {
        let context: Context
        let secret: String
    }

    static func fields(from url: URL) throws -> [String: Any] {
        guard let field = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value else {
            throw Failure.invalidURL
        }
        var encoded = field.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let bytes = Data(base64Encoded: encoded),
              let fields = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw Failure.invalidURL
        }
        return fields
    }

    private static func directCallID(_ inviter: String, _ recipient: String) -> UUID {
        let members = [inviter, recipient].sorted().joined(separator: "|")
        return hashedUUID("rideintercom.direct-call.v1|" + members)
    }

    private static func hashedUUID(_ input: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(input.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    static func acknowledgement(_ reply: URL, signingKey: P256.Signing.PrivateKey) throws -> URL {
        var object = try fields(from: reply)
        guard let inviter = object["inviterMemberID"] as? String else { throw Failure.invalidURL }
        object["kind"] = "acknowledged"
        let message = try canonicalData(object)
        let publicKey = base64url(signingKey.publicKey.x963Representation)
        object["acknowledgementProof"] = try signedProof(
            "acknowledgeInvitation", memberID: inviter, publicKey: publicKey, message: message, key: signingKey
        )
        return try makeURL(endpoint: "contact-reply", query: "receipt", object: object)
    }

    static func acceptance(
        _ invitation: URL, invitee: String, sharedName: String, signingKey: P256.Signing.PrivateKey = .init()
    ) throws -> URL {
        let token = try fields(from: invitation)
        guard let grant = token["directInvitation"] as? [String: Any],
              let context = grant["context"] as? [String: Any],
              let secret = grant["secret"] as? String,
              let secretBytes = Data(base64Encoded: secret),
              let id = context["id"] as? String,
              let inviter = context["inviterMemberID"] as? String,
              let group = context["groupID"] as? String else {
            throw Failure.invalidURL
        }
        let receiptID = hashedUUID("rideintercom.invitation-receipt.v2|" + id + "|" + invitee).uuidString
        let publicKey = base64url(signingKey.publicKey.x963Representation)
        let proofFields: [String: Any] = [
            "receiptID": receiptID, "inviteeMemberID": invitee, "inviteeDeviceKey": publicKey, "invitation": context
        ]
        let proofBytes = Data("rideintercom.direct-invitation.receipt.v2\0".utf8) + (try canonicalData(proofFields))
        let proof = Data(HMAC<SHA256>.authenticationCode(
            for: proofBytes, using: SymmetricKey(data: secretBytes)
        )).base64EncodedString()
        var object: [String: Any] = [
            "id": receiptID, "groupID": group, "inviterMemberID": inviter, "inviteeMemberID": invitee,
            "inviteeDeviceKey": publicKey, "displayName": sharedName, "invitation": context, "proof": proof
        ]
        let message = try canonicalData(object)
        object["kind"] = "accepted"
        object["acceptanceProof"] = try signedProof(
            "acceptInvitation", memberID: invitee, publicKey: publicKey, message: message, key: signingKey
        )
        return try makeURL(endpoint: "contact-reply", query: "receipt", object: object)
    }

    private static func signedProof(
        _ purpose: String, memberID: String, publicKey: String, message: Data, key: P256.Signing.PrivateKey
    ) throws -> [String: String] {
        var signed = Data("rideintercom.device-proof.v1\0".utf8)
        for field in [Data(purpose.utf8), Data(memberID.utf8), Data(publicKey.utf8), Data(), Data(), message] {
            var count = UInt32(field.count).bigEndian
            withUnsafeBytes(of: &count) { signed.append(contentsOf: $0) }
            signed.append(field)
        }
        return ["publicKey": publicKey, "signature": base64url(try key.signature(for: signed).rawRepresentation)]
    }

    private static func makeURL(endpoint: String, query: String, object: [String: Any]) throws -> URL {
        let encoded = base64url(try JSONSerialization.data(withJSONObject: object))
        guard let url = URL(string: "rideintercom://\(endpoint)?\(query)=\(encoded)") else {
            throw Failure.invalidURL
        }
        return url
    }

    /// Match the product's Codable representation, including fractional timestamp spelling.
    static func canonicalData(_ object: [String: Any]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(CanonicalJSON(value: object))
    }

    private struct CanonicalJSONKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }

    private struct CanonicalJSON: Encodable {
        let value: Any

        func encode(to encoder: Encoder) throws {
            if let object = value as? [String: Any] {
                var container = encoder.container(keyedBy: CanonicalJSONKey.self)
                for (key, value) in object { try container.encode(Self(value: value), forKey: CanonicalJSONKey(key)) }
            } else if let array = value as? [Any] {
                var container = encoder.unkeyedContainer()
                for value in array { try container.encode(Self(value: value)) }
            } else {
                var container = encoder.singleValueContainer()
                if let string = value as? String {
                    try container.encode(string)
                } else if let number = value as? NSNumber {
                    if CFGetTypeID(number) == CFBooleanGetTypeID() {
                        try container.encode(number.boolValue)
                    } else {
                        try container.encode(number.doubleValue)
                    }
                } else if value is NSNull {
                    try container.encodeNil()
                } else {
                    throw Failure.invalidURL
                }
            }
        }
    }

    private static func hex(_ bytes: some Sequence<UInt8>) -> String {
        bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func base64url(_ bytes: Data) -> String {
        bytes.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
