import CryptoKit
import Foundation

/// Secret attachment remains in the signed token/Keychain, never the public receipt context.
struct ContactGroupInvitation: Codable, Equatable {
    let id: UUID
    let name: String
    let secret: String
    var isValid: Bool {
        IntercomGroup.isValidName(name) && !name.contains("|")
            && !secret.isEmpty && secret.utf8.count <= 256 && !secret.contains("|")
    }
    func digest() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(self)).map { String(format: "%02x", $0) }.joined()
    }
}

struct GroupInviteToken: Codable, Equatable {
    static let currentVersion = 6

    let version: Int
    let groupID: UUID
    let groupName: String
    let groupSecret: String
    let inviterMemberID: String
    let inviterDisplayName: String?
    let recipientMemberID: String?
    let issuedAt: TimeInterval
    let expiresAt: TimeInterval?
    let directInvitation: DirectInvitationGrant?
    let signature: String
    let identityProof: DeviceIdentityProof?
    let invitedGroup: ContactGroupInvitation?
    let replyAdmissionSignature: String?
    var accountPair: AccountCallPair? { directInvitation?.context.accountPair }
    var recipientAccount: AccountPrincipal? { directInvitation?.context.recipientAccount }

    func isAddressed(to memberID: String, principal: AccountPrincipal?) -> Bool {
        (recipientMemberID == nil || recipientMemberID == memberID)
            && (recipientAccount == nil || recipientAccount == principal)
    }

    init(
        version: Int = GroupInviteToken.currentVersion,
        groupID: UUID,
        groupName: String,
        groupSecret: String,
        inviterMemberID: String,
        inviterDisplayName: String? = nil,
        recipientMemberID: String? = nil,
        issuedAt: TimeInterval,
        expiresAt: TimeInterval?,
        directInvitation: DirectInvitationGrant? = nil,
        signature: String,
        identityProof: DeviceIdentityProof? = nil,
        invitedGroup: ContactGroupInvitation? = nil,
        replyAdmissionSignature: String? = nil
    ) throws {
        guard version == Self.currentVersion else {
            throw GroupInviteTokenError.unsupportedVersion
        }

        self.version = version
        self.groupID = groupID
        self.groupName = groupName
        self.groupSecret = groupSecret
        self.inviterMemberID = inviterMemberID
        self.inviterDisplayName = inviterDisplayName
        self.recipientMemberID = recipientMemberID
        self.issuedAt = issuedAt
        self.expiresAt = expiresAt
        self.directInvitation = directInvitation
        self.signature = signature
        self.identityProof = identityProof
        self.invitedGroup = invitedGroup
        self.replyAdmissionSignature = replyAdmissionSignature
    }

    static func make(
        authority: DirectInvitationAuthority,
        signer: DeviceIdentitySigner,
        credential: GroupAccessCredential,
        groupName: String,
        inviterMemberID: String,
        inviterDisplayName: String? = nil,
        recipientMemberID: String? = nil,
        recipientAccount: AccountPrincipal? = nil,
        contactBootstrap: Bool? = nil,
        invitedGroup: ContactGroupInvitation? = nil,
        issuedAt: TimeInterval = Date().timeIntervalSince1970,
        expiresAt: TimeInterval? = nil
    ) throws -> GroupInviteToken {
        guard signer.memberID == inviterMemberID else { throw GroupInviteTokenError.invalidTokenEncoding }
        guard recipientAccount == nil || signer.principal != nil else {
            throw GroupInviteTokenError.accountVerificationRequired
        }
        let expiresAt = expiresAt ?? issuedAt + 7 * 24 * 60 * 60
        let grant = try authority.issue(
            .init(
                groupID: credential.groupID, inviterMemberID: inviterMemberID, inviterDeviceKey: signer.publicKey,
                recipientMemberID: recipientMemberID, expiresAt: expiresAt,
                inviterAccount: recipientAccount == nil ? nil : signer.principal,
                recipientAccount: recipientAccount, contactBootstrap: contactBootstrap,
                invitedGroupID: invitedGroup?.id, invitedGroupDigest: try invitedGroup?.digest()))
        let signature = SignatureContents(
            version: currentVersion, credential: credential, groupName: groupName,
            inviterMemberID: inviterMemberID, inviterDisplayName: inviterDisplayName,
            recipientMemberID: recipientMemberID,
            issuedAt: issuedAt, expiresAt: expiresAt, directInvitation: grant, invitedGroup: invitedGroup).signature
        let replyAdmissionSignature = contactBootstrap == true
            ? try ContactInvitationReplyAdmission.makeSignature(
                for: grant.context, secret: credential.secret, signer: signer) : nil
        return try GroupInviteToken(
            groupID: credential.groupID, groupName: groupName, groupSecret: credential.secret,
            inviterMemberID: inviterMemberID,
            inviterDisplayName: inviterDisplayName, recipientMemberID: recipientMemberID, issuedAt: issuedAt,
            expiresAt: expiresAt,
            directInvitation: grant, signature: signature,
            identityProof: signer.sign(Data(signature.utf8), purpose: .issueInvitation), invitedGroup: invitedGroup,
            replyAdmissionSignature: replyAdmissionSignature)
    }

    func accept(
        signer: DeviceIdentitySigner, displayName: String, trust: DeviceIdentityTrust? = nil,
        now: TimeInterval = Date().timeIntervalSince1970, contactBootstrap: Bool? = nil
    ) throws -> AcceptedDirectInvitation {
        try validate(contactBootstrap: contactBootstrap)
        guard verifySignature(), let grant = directInvitation else {
            throw GroupInviteTokenError.invalidSignature
        }
        guard !isExpired(now: now) else { throw GroupInviteTokenError.expired }
        let inviter = try verifyInviterProof(trust: trust, now: Date(timeIntervalSince1970: now))
        if let recipientAccount {
            guard signer.principal == recipientAccount else { throw GroupInviteTokenError.wrongRecipient }
            guard inviter.principal == grant.context.inviterAccount else {
                throw GroupInviteTokenError.invalidSignature
            }
        }
        let receipt = try DirectInvitationReceipt.make(
            grant: grant, signer: signer, inviteeMemberID: signer.memberID, displayName: displayName)
        return AcceptedDirectInvitation(receipt: receipt, inviter: inviter)
    }

    func verifyInviterProof(trust: DeviceIdentityTrust? = nil, now: Date = Date()) throws -> VerifiedDeviceProof {
        guard let identityProof, let inviter = try? identityProof.verify(
            Data(signature.utf8), purpose: .issueInvitation, memberID: inviterMemberID, trust: trust, now: now)
        else { throw GroupInviteTokenError.invalidSignature }
        return inviter
    }

    func verifySignature() -> Bool {
        signature == SignatureContents(
            version: version,
            credential: .init(groupID: groupID, secret: groupSecret),
            groupName: groupName,
            inviterMemberID: inviterMemberID,
            inviterDisplayName: inviterDisplayName,
            recipientMemberID: recipientMemberID,
            issuedAt: issuedAt,
            expiresAt: expiresAt,
            directInvitation: directInvitation, invitedGroup: invitedGroup
        ).signature
    }

    func validate(contactBootstrap: Bool? = nil) throws {
        guard version == Self.currentVersion else { throw GroupInviteTokenError.unsupportedVersion }
        guard let directInvitation, directInvitation.context.contactBootstrap == contactBootstrap,
            directInvitation.isValid,
              let identityProof, identityProof.publicKey == directInvitation.context.inviterDeviceKey,
              directInvitation.context.groupID == groupID,
              directInvitation.context.inviterMemberID == inviterMemberID,
              directInvitation.context.recipientMemberID == recipientMemberID,
              directInvitation.context.expiresAt == expiresAt,
            inviterDisplayName.map(IntercomGroup.isValidName) ?? true
        else { throw GroupInviteTokenError.invalidTokenEncoding }
        if let invitedGroup {
            guard contactBootstrap == true, invitedGroup.isValid,
                  directInvitation.context.invitedGroupID == invitedGroup.id,
                directInvitation.context.invitedGroupDigest == (try invitedGroup.digest())
            else { throw GroupInviteTokenError.invalidTokenEncoding }
        } else if directInvitation.context.invitedGroupID != nil || directInvitation.context.invitedGroupDigest != nil {
            throw GroupInviteTokenError.invalidTokenEncoding
        }
        if let recipientMemberID {
            guard groupID == IntercomGroup.directCallID(memberIDs: [inviterMemberID, recipientMemberID])
            else { throw GroupInviteTokenError.invalidTokenEncoding }
        }
        guard IntercomGroup.isValidName(groupName), !groupName.contains("|"),
              IntercomGroup.isValidMemberID(inviterMemberID),
              !groupSecret.isEmpty, groupSecret.utf8.count <= 256, !groupSecret.contains("|"),
              issuedAt.isFinite, issuedAt >= 0,
              expiresAt.map({ $0.isFinite && $0 >= issuedAt }) ?? true else {
            throw GroupInviteTokenError.invalidTokenEncoding
        }
    }

    func isExpired(now: TimeInterval = Date().timeIntervalSince1970) -> Bool {
        guard let expiresAt else { return false }
        return now >= expiresAt
    }

    private struct SignatureContents {
        let version: Int
        let credential: GroupAccessCredential
        let groupName: String
        let inviterMemberID: String
        let inviterDisplayName: String?
        let recipientMemberID: String?
        let issuedAt: TimeInterval
        let expiresAt: TimeInterval?
        let directInvitation: DirectInvitationGrant?
        let invitedGroup: ContactGroupInvitation?

        var signature: String {
            var fields = [
                "\(version)",
                credential.groupID.uuidString,
                groupName,
                credential.secret,
                inviterMemberID,
                String(format: "%.3f", issuedAt),
                expiresAt.map { String(format: "%.3f", $0) } ?? ""
            ]
            fields.append(recipientMemberID ?? "")
            // Base64 keeps arbitrary user-chosen separators out of the signed field framing.
            fields.append(Data((inviterDisplayName ?? "").utf8).base64EncodedString())
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            fields.append((try? encoder.encode(directInvitation))?.base64EncodedString() ?? "")
            // Keep ordinary v6 invitations byte-compatible; only combined invitations add a field.
            if let invitedGroup { fields.append((try? encoder.encode(invitedGroup))?.base64EncodedString() ?? "") }
            let message = fields.joined(separator: "|")
            let key = SymmetricKey(data: Data(credential.secret.utf8))
            return HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: key)
                .map { String(format: "%02x", $0) }
                .joined()
        }
    }
}

struct AcceptedDirectInvitation {
    let receipt: DirectInvitationReceipt
    let inviter: VerifiedDeviceProof
    fileprivate init(receipt: DirectInvitationReceipt, inviter: VerifiedDeviceProof) {
        self.receipt = receipt; self.inviter = inviter
    }
}

enum GroupInviteTokenError: Error, Equatable {
    case unsupportedVersion
    case invalidURL
    case invalidTokenEncoding
    case invalidSignature
    case expired
    case retiredGroupLink
    case credentialStorageFailed
    case activeGroupKeyChanged
    case wrongRecipient
    case incompatibleCall
    case accountVerificationRequired
    case activeOrdinaryGroupInvitationLimit
}

enum GroupInviteTokenCodec {
    static func joinURL(for token: GroupInviteToken, contactBootstrap: Bool? = nil) throws -> URL {
        let encoder = JSONEncoder()
        if contactBootstrap == true { encoder.outputFormatting = [.sortedKeys] }
        let data = try encoder.encode(token)
        let encodedToken = data.base64URLEncodedString()
        guard
            let url = URL(
                string: "rideintercom://\(contactBootstrap == true ? "contact" : "join")?token=\(encodedToken)")
        else {
            throw GroupInviteTokenError.invalidURL
        }
        return url
    }

    static func decodeJoinURL(_ url: URL, contactBootstrap: Bool? = nil) throws -> GroupInviteToken {
        guard url.absoluteString.utf8.count <= 8192, url.scheme == "rideintercom",
              url.host == (contactBootstrap == true ? "contact" : "join"),
              url.user == nil, url.password == nil, url.port == nil, url.fragment == nil, url.path.isEmpty,
              URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.count == 1,
              let encodedToken = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "token" })?
                .value,
              let data = Data(base64URLEncoded: encodedToken) else {
            throw GroupInviteTokenError.invalidURL
        }

        let token = try JSONDecoder().decode(GroupInviteToken.self, from: data)
        try token.validate(contactBootstrap: contactBootstrap)
        guard token.verifySignature() else {
            throw GroupInviteTokenError.invalidSignature
        }
        _ = try token.verifyInviterProof()
        return token
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded string: String) {
        var base64 = string
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let padding = (4 - base64.count % 4) % 4
        base64.append(String(repeating: "=", count: padding))
        self.init(base64Encoded: base64)
    }
}
