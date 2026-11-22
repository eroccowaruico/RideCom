import CryptoKit
import Foundation

struct CallRelationshipRestoreRequest: Codable {
    fileprivate struct Challenge: Codable {
        let id: UUID
        let callID: UUID
        let recipientMemberID: String
        let recipient: AccountDeviceBinding
        let requesterMemberID: String
        let expiresAt: Date

        func isCurrent(at now: Date) -> Bool {
            expiresAt > now && expiresAt <= now.addingTimeInterval(330)
        }

        func addresses(memberID: String, principal: AccountPrincipal?, publicKey: String) -> Bool {
            memberID == recipientMemberID && principal == recipient.principal && publicKey == recipient.publicKey
        }
    }

    fileprivate let challenge: Challenge
    fileprivate let proof: DeviceIdentityProof

    init(callID: UUID, recipientMemberID: String, recipient: AccountDeviceBinding,
         signer: DeviceIdentitySigner, now: Date) throws {
        let requester = try CallRelationshipBackup.verifiedOwner(of: signer, now: now.timeIntervalSince1970)
        guard recipient.principal.isValid, requester != recipient.principal,
              requester.issuer == recipient.principal.issuer,
              IntercomGroup.isValidMemberID(recipientMemberID),
              !recipientMemberID.hasPrefix(GroupMember.pendingInvitePrefix),
              DeviceIdentityProof.isValidPublicKey(recipient.publicKey) else {
            throw DeviceIdentityProof.Failure.invalid
        }
        let challenge = Challenge(id: UUID(), callID: callID, recipientMemberID: recipientMemberID,
                                  recipient: recipient, requesterMemberID: signer.memberID,
                                  expiresAt: now.addingTimeInterval(300))
        self.challenge = challenge
        proof = try signer.sign(restoreProofPayload(challenge), purpose: .requestCallRelationshipRestore)
    }

    static func recipientFingerprint(callID: UUID, memberID: String, key: String) throws -> String {
        let payload = try restoreProofPayload(["rideintercom.call-restore-recipient.v1", callID.uuidString,
                                               memberID, key])
        return IdentityEncoding.encode(Data(SHA256.hash(data: payload)))
    }

    func verifiedDirectRequester(
        addressedTo signer: DeviceIdentitySigner, trust: DeviceIdentityTrust, now: Date
    ) throws -> AccountPrincipal? {
        let requester = try verifiedRequester(trust: trust, now: now).principal
        let responder = try CallRelationshipBackup.verifiedOwner(of: signer, now: now.timeIntervalSince1970)
        guard challenge.addresses(memberID: signer.memberID, principal: responder, publicKey: signer.publicKey)
        else { throw DeviceIdentityProof.Failure.invalid }
        return AccountCallPair(requester, responder).id == challenge.callID ? requester : nil
    }

    fileprivate func verifiedRequester(trust: DeviceIdentityTrust, now: Date) throws -> AccountDeviceBinding {
        guard challenge.isCurrent(at: now) else { throw DeviceIdentityProof.Failure.invalid }
        let requester = try proof.verify(restoreProofPayload(challenge), purpose: .requestCallRelationshipRestore,
                                         memberID: challenge.requesterMemberID, trust: trust, now: now)
        guard let principal = requester.principal, principal.isValid, principal != challenge.recipient.principal,
              principal.issuer == challenge.recipient.principal.issuer else {
            throw DeviceIdentityProof.Failure.invalid
        }
        return .init(principal: principal, publicKey: requester.publicKey)
    }
}

extension CallRelationshipBackup {
    /// Uses the original device only to address the request. The reply still needs current membership checks.
    func directRestoreRequest(
        for contactID: UUID, to identity: VerifiedDeviceIdentity, as signer: DeviceIdentitySigner, now: Date
    ) throws -> CallRelationshipRestoreRequest? {
        let time = now.timeIntervalSince1970
        _ = try validated(for: Self.verifiedOwner(of: signer, now: time))
        let principal = AccountPrincipal(issuer: identity.issuer, userID: identity.userID)
        let recipient = AccountDeviceBinding(principal: principal, publicKey: identity.deviceKey)
        let contact = contacts.first { $0.id == contactID }
        guard identity.expiresAt > time,
              let callID = try pinnedDirectCallID(for: contact, memberID: identity.memberID, recipient: recipient)
        else { return nil }
        return try .init(callID: callID, recipientMemberID: identity.memberID, recipient: recipient,
                         signer: signer, now: now)
    }

    func matchesDirectRestoreRequest(_ context: CallRelationshipRestoreContext, contactID: UUID) throws -> Bool {
        let address = context.request.challenge
        guard address.callID == context.record.id else { return false }
        let contact = contacts.first { $0.id == contactID }
        return try pinnedDirectCallID(for: contact, memberID: address.recipientMemberID,
                                      recipient: address.recipient) == context.record.id
    }

    fileprivate func containsDirectRestorePeer(_ peer: AccountDeviceBinding, memberID: String, callID: UUID)
        throws -> Bool {
        let contact = contacts.first { $0.principal == peer.principal }
        return try pinnedDirectCallID(for: contact, memberID: memberID, recipient: peer) == callID
    }

    private func pinnedDirectCallID(for contact: Contact?, memberID: String, recipient: AccountDeviceBinding) throws
        -> UUID? {
        guard let contact, contact.principal == recipient.principal, let saved = contact.restoreRecipientFingerprint
        else { return nil }
        let callID = AccountCallPair(owner, recipient.principal).id
        let fingerprint = try CallRelationshipRestoreRequest.recipientFingerprint(
            callID: callID, memberID: memberID, key: recipient.publicKey)
        return fingerprint == saved ? callID : nil
    }
}

struct CallRelationshipRestoreConfirmation: Codable {
    /// The addressed device's local membership check. The caller still verifies current access and the call key.
    struct Verified {
        let callID: UUID
        let previousMemberID: String
        let requesterMemberID: String
        let requester: AccountDeviceBinding
        let responderMemberID: String
        let responder: AccountDeviceBinding

        fileprivate init(challenge: CallRelationshipRestoreRequest.Challenge, previousMemberID: String,
                         requester: AccountDeviceBinding) {
            callID = challenge.callID
            self.previousMemberID = previousMemberID
            requesterMemberID = challenge.requesterMemberID
            self.requester = requester
            responderMemberID = challenge.recipientMemberID
            responder = challenge.recipient
        }
    }

    private struct Claim: Encodable {
        let request: CallRelationshipRestoreRequest
        let previousMemberID: String
    }

    private let previousMemberID: String
    private let proof: DeviceIdentityProof

    fileprivate init(_ request: CallRelationshipRestoreRequest, previousMemberID: String,
                     signer: DeviceIdentitySigner) throws {
        self.previousMemberID = previousMemberID
        let claim = Claim(request: request, previousMemberID: previousMemberID)
        proof = try signer.sign(restoreProofPayload(claim), purpose: .confirmCallRelationshipRestore)
    }

    func verify(for request: CallRelationshipRestoreRequest, as signer: DeviceIdentitySigner,
                trust: DeviceIdentityTrust, now: Date) throws -> Verified {
        let verified = try verifiedConfirmation(for: request, trust: trust, now: now)
        let owner = try CallRelationshipBackup.verifiedOwner(of: signer, now: now.timeIntervalSince1970)
        guard signer.memberID == verified.requesterMemberID,
              verified.requester == .init(principal: owner, publicKey: signer.publicKey)
        else { throw DeviceIdentityProof.Failure.invalid }
        return verified
    }

    fileprivate func verifiedConfirmation(for request: CallRelationshipRestoreRequest, trust: DeviceIdentityTrust,
                                          now: Date) throws -> Verified {
        let challenge = request.challenge
        let requester = try request.verifiedRequester(trust: trust, now: now)
        guard IntercomGroup.isValidMemberID(previousMemberID),
              !previousMemberID.hasPrefix(GroupMember.pendingInvitePrefix),
              previousMemberID != challenge.requesterMemberID else {
            throw DeviceIdentityProof.Failure.invalid
        }
        let claim = Claim(request: request, previousMemberID: previousMemberID)
        let responder = try proof.verify(restoreProofPayload(claim), purpose: .confirmCallRelationshipRestore,
                                         memberID: challenge.recipientMemberID, trust: trust, now: now)
        guard challenge.addresses(memberID: responder.memberID, principal: responder.principal,
                                  publicKey: responder.publicKey) else { throw DeviceIdentityProof.Failure.invalid }
        return .init(challenge: challenge, previousMemberID: previousMemberID, requester: requester)
    }
}

/// The same request, confirmation and membership used for candidate checks, key transfer and local storage.
struct CallRelationshipRestoreContext {
    let request: CallRelationshipRestoreRequest
    let confirmation: CallRelationshipRestoreConfirmation
    let record: GroupSnapshot.Record

    fileprivate func header() throws -> Data {
        let authorization = Authorization(request: request, confirmation: confirmation)
        return try Data(SHA256.hash(data: restoreProofPayload(authorization)))
    }

    fileprivate func membershipFingerprint() throws -> Data {
        try Data(SHA256.hash(data: restoreProofPayload(RestoreMembership(record))))
    }

    private struct Authorization: Encodable {
        let request: CallRelationshipRestoreRequest
        let confirmation: CallRelationshipRestoreConfirmation
    }
}

/// Carries a call key already authorized by the caller for release to the requesting device.
struct CallRelationshipRestoreCredential: Codable {
    private static let domain = "rideintercom.call-restore-credential.ecdh.v2"
    private static let publicKeySize = 65
    private static let fingerprintSize = 32
    private static let overhead = publicKeySize + 28 + fingerprintSize
    private static let maximumSecretSize = 256
    private let packet: Data
    private let proof: DeviceIdentityProof

    private struct Packet: Encodable {
        let header: Data
        let packet: Data
    }

    init(
        _ credential: GroupAccessCredential, for context: CallRelationshipRestoreContext,
        as signer: DeviceIdentitySigner, trust: DeviceIdentityTrust, now: Date
    ) throws {
        let verified = try context.confirmation.verifiedConfirmation(for: context.request, trust: trust, now: now)
        let owner = try CallRelationshipBackup.verifiedOwner(of: signer, now: now.timeIntervalSince1970)
        let secret = Data(credential.secret.utf8)
        guard signer.memberID == verified.responderMemberID,
              verified.responder == .init(principal: owner, publicKey: signer.publicKey),
              context.record.id == verified.callID,
              credential.groupID == verified.callID, (1...Self.maximumSecretSize).contains(secret.count),
              let target = IdentityEncoding.decode(verified.requester.publicKey)
        else { throw DeviceIdentityProof.Failure.invalid }
        let header = try context.header()
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let recipient = try P256.KeyAgreement.PublicKey(x963Representation: target)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let key = DeviceIdentitySigner.sealedPayloadKey(shared, domain: Self.domain, header: header)
        let payload = try context.membershipFingerprint() + secret
        guard let sealed = try AES.GCM.seal(payload, using: key, authenticating: header).combined
        else { throw DeviceIdentityProof.Failure.invalid }
        packet = ephemeral.publicKey.x963Representation + sealed
        proof = try signer.sign(restoreProofPayload(Packet(header: header, packet: packet)),
                                purpose: .deliverCallRelationshipRestoreCredential)
    }

    func open(for context: CallRelationshipRestoreContext, as signer: DeviceIdentitySigner,
              trust: DeviceIdentityTrust, now: Date) throws
        -> (confirmation: CallRelationshipRestoreConfirmation.Verified, credential: GroupAccessCredential) {
        let verified = try context.confirmation.verify(for: context.request, as: signer, trust: trust, now: now)
        guard context.record.id == verified.callID,
              (Self.overhead + 1...Self.overhead + Self.maximumSecretSize).contains(packet.count)
        else { throw DeviceIdentityProof.Failure.invalid }
        let header = try context.header()
        let sender = try proof.verify(restoreProofPayload(Packet(header: header, packet: packet)),
            purpose: .deliverCallRelationshipRestoreCredential, memberID: verified.responderMemberID,
            trust: trust, now: now)
        guard sender.principal == verified.responder.principal, sender.publicKey == verified.responder.publicKey
        else { throw DeviceIdentityProof.Failure.invalid }
        let payload = try signer.openSealedPayload(packet.dropFirst(Self.publicKeySize),
            ephemeralKey: packet.prefix(Self.publicKeySize), domain: Self.domain, header: header)
        guard try payload.prefix(Self.fingerprintSize) == context.membershipFingerprint(),
              let text = String(data: payload.dropFirst(Self.fingerprintSize), encoding: .utf8)
        else { throw DeviceIdentityProof.Failure.invalid }
        return (verified, .init(groupID: verified.callID, secret: text))
    }
}

/// The authorization fields that may affect the restored membership and group permissions.
private struct RestoreMembership: Encodable {
    private struct Removal: Encodable {
        let memberIDs: [String]
        let principal: AccountPrincipal?
        let removedAt: TimeInterval
        let priorInvitationIDs: [String]?
        let reinstated: Bool?

        init(_ removal: GroupSnapshot.RemovedMember) {
            memberIDs = removal.memberIDs.sorted()
            principal = removal.principal
            removedAt = removal.removedAt
            priorInvitationIDs = removal.priorInvitationIDs?.map(\.uuidString).sorted()
            reinstated = removal.reinstated
        }
    }

    private let id: UUID
    private let kind: IntercomGroup.Kind?
    private let members: [String]
    private let accountPair: AccountCallPair?
    private let accountDevices: [String: AccountDeviceBinding]
    private let invitationDeviceKeys: [String: String]?
    private let joinedByInvitation: Bool?
    private let removedMembers: [Removal]?

    init(_ record: GroupSnapshot.Record) {
        id = record.id
        kind = record.kind
        members = record.members.map(\.id).sorted()
        accountPair = record.accountPair
        accountDevices = record.accountDevices
        invitationDeviceKeys = record.invitationDeviceKeys
        joinedByInvitation = record.joinedByInvitation
        removedMembers = record.removedMembers?.map(Removal.init)
    }
}

extension GroupRepository {
    /// A current backup can constrain a direct call to the same relationship recorded in both stores.
    func confirmRestore(
        _ request: CallRelationshipRestoreRequest, as signer: DeviceIdentitySigner, trust: DeviceIdentityTrust,
        now: Date, matchingDirectBackup backup: CallRelationshipBackup? = nil
    ) throws -> CallRelationshipRestoreConfirmation? {
        let challenge = request.challenge
        let requester = try request.verifiedRequester(trust: trust, now: now)
        let owner = requester.principal
        let responder = try CallRelationshipBackup.verifiedOwner(of: signer, now: now.timeIntervalSince1970)
        guard challenge.addresses(memberID: signer.memberID, principal: responder, publicKey: signer.publicKey),
              localMemberID == signer.memberID else { throw DeviceIdentityProof.Failure.invalid }
        guard let snapshot = writableSnapshot else { throw IntercomGroupError.storageUnavailable }
        return try withCurrentSnapshot(snapshot) {
            guard let record = snapshot.groups.first(where: { $0.id == challenge.callID }),
                  record.pendingInvitation == nil,
                  backup == nil || record.kind == .direct,
                  record.accountDevices[signer.memberID] == .init(principal: responder, publicKey: signer.publicKey),
                  !record.excludesMember(challenge.requesterMemberID, principal: owner),
                  !record.members.contains(where: { $0.id == challenge.requesterMemberID }),
                  let previous = record.soleRestorePredecessor(for: owner, replacingKeyWith: requester.publicKey)
            else { return nil }
            if record.kind == .direct {
                guard record.accountPair == AccountCallPair(responder, owner),
                      let priorDevice = record.accountDevices[previous],
                      snapshot.users.contains(where: { user in
                          user.principal == owner && user.memberIDs.contains(previous)
                              && user.deviceKeys?[previous] == priorDevice.publicKey
                      }) else { return nil }
                if let backup {
                    guard backup.owner == responder,
                          try backup.containsDirectRestorePeer(priorDevice, memberID: previous, callID: record.id)
                    else { return nil }
                }
            }
            guard let reference = record.credentialReference, let secret = try credentialSecret(reference: reference),
                  !secret.isEmpty else { return nil }
            return try .init(request, previousMemberID: previous, signer: signer)
        }
    }
}

private extension GroupSnapshot.Record {
    func soleRestorePredecessor(for owner: AccountPrincipal, replacingKeyWith newKey: String) -> String? {
        let matches = members.filter { member in
            accountDevices[member.id]?.principal == owner && !excludesMember(member.id, principal: owner)
        }
        guard matches.count == 1, let previous = matches.first?.id,
              accountDevices[previous]?.publicKey != newKey else { return nil }
        return previous
    }
}

private func restoreProofPayload<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
