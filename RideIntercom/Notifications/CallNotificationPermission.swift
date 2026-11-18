import Foundation

nonisolated struct CallNotificationTap: Equatable, Sendable {
    let requestID: UUID
    let recipientID: String
    init(requestID: UUID, recipientID: String) { self.requestID = requestID; self.recipientID = recipientID }
    init?(payload: [AnyHashable: Any]) {
        guard payload["kind"] == nil, payload["version"] as? Int == 1, let value = payload["requestID"] as? String, let requestID = UUID(uuidString: value),
              let recipientID = payload["recipientID"] as? String, recipientID.utf8.count == 64,
              recipientID.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        self.init(requestID: requestID, recipientID: recipientID)
    }
}

/// Secrets stay in the existing account-scoped InternetConnection Keychain service.
nonisolated struct CallNotificationPermission: Codable, Equatable, Sendable {
    var contactID: UUID
    let owner: AccountPrincipal
    let peer: AccountPrincipal
    var allowsIncoming = false
    var receiving: CallNotificationGrant?
    var sending: CallNotificationGrant?
    var allowsGroupInvitations: Bool? = nil
    var groupReceiving: CallNotificationGrant?
    var groupSending: CallNotificationGrant?
    var groupReceivedRevision: UInt64? = nil
    var groupReceivedRevisionSource: String? = nil
    var revision: UInt64 = 0
    var receivedRevision: UInt64 = 0
    var receivedRevisionSource: String?
    var isValid: Bool {
        revision < UInt64.max && receivedRevision < UInt64.max && owner.isValid && peer.isValid && owner.issuer == peer.issuer && owner != peer
        && receiving.map(\.isValid) != false && sending.map(\.isValid) != false
        && groupReceiving.map(\.isValid) != false && groupSending.map(\.isValid) != false
        && (groupReceivedRevision ?? 0) < UInt64.max && groupReceivedRevisionSource.map(DeviceIdentityProof.isValidPublicKey) != false
        && receivedRevisionSource.map(DeviceIdentityProof.isValidPublicKey) != false
    }
}

nonisolated struct CallNotificationPermissionMessage: Codable, Equatable, Sendable {
    static let namespace = "rideintercom.call-notification-permission.v1"
    static let groupNamespace = "rideintercom.group-invitation-permission.v1"
    var owner: AccountPrincipal
    var allowedSender: AccountPrincipal
    var revision: UInt64
    var grant: CallNotificationGrant?
    var proof: DeviceIdentityProof?
    var groupGrant: CallNotificationGrant? = nil
    var groupInvitationsSupported: Bool? = nil

    static func make(owner: AccountPrincipal, allowedSender: AccountPrincipal, revision: UInt64,
                     grant: CallNotificationGrant?, signer: DeviceIdentitySigner, groupGrant: CallNotificationGrant? = nil, groupInvitationsSupported: Bool? = nil) throws -> Self {
        guard signer.principal == nil || signer.principal == owner else { throw DeviceIdentityProof.Failure.invalid }
        var value = Self(owner: owner, allowedSender: allowedSender, revision: revision, grant: grant, groupGrant: groupGrant, groupInvitationsSupported: groupInvitationsSupported)
        value.proof = try signer.sign(value.message(), purpose: .callNotificationPermission)
        return value
    }
    func verifiedGrant(peerID: String, savedUser: SavedUser, local: AccountPrincipal) throws -> CallNotificationGrant? {
        guard owner.isValid, allowedSender.isValid, owner.issuer == allowedSender.issuer, owner != allowedSender, revision > 0,
              (groupGrant == nil || groupInvitationsSupported == true),
              groupGrant.map({ $0.isAddressed(to: owner, from: local, audience: "rideintercom-group-invitation") }) != false,
              grant.map({ $0.isAddressed(to: owner, from: local) }) != false, savedUser.principal == owner, allowedSender == local,
              savedUser.memberIDs.contains(peerID), let proof, savedUser.deviceKeys?[peerID] == proof.publicKey else { throw DeviceIdentityProof.Failure.invalid }
        _ = try proof.verify(message(), purpose: .callNotificationPermission, memberID: peerID)
        return grant
    }
    private func message() throws -> Data {
        var copy = self; copy.proof = nil
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(copy)
    }
}

nonisolated struct CallNotificationServiceAccess: Equatable, Sendable {
    let origin: URL
    let accessToken: String
    let principal: AccountPrincipal
}


nonisolated struct GroupInvitationTap: Equatable, Sendable {
    let requestID: UUID
    let recipientID: String
    init?(payload: [AnyHashable: Any]) {
        guard payload["kind"] as? String == "groupInvitation", payload["version"] as? Int == 1,
              let raw = payload["requestID"] as? String, let id = UUID(uuidString: raw),
              let recipient = payload["recipientID"] as? String, InternetAccountClient.notificationUserID(recipient) else { return nil }
        requestID = id; recipientID = recipient
    }
}
