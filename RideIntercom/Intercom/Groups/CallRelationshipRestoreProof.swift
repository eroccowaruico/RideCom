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
        let confirmedRegistrationID: UUID?

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
         signer: DeviceIdentitySigner, now: Date, confirmedRegistrationID: UUID? = nil) throws {
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
                                  expiresAt: now.addingTimeInterval(300),
                                  confirmedRegistrationID: confirmedRegistrationID)
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
        try verifiedDirectRequesterIdentity(addressedTo: signer, trust: trust, now: now)?.restoreBinding.principal
    }

    func verifiedDirectRequesterIdentity(
        addressedTo signer: DeviceIdentitySigner, trust: DeviceIdentityTrust, now: Date
    ) throws -> VerifiedDeviceIdentity? {
        let requester = try verifiedRequesterIdentity(trust: trust, now: now)
        let responder = try CallRelationshipBackup.verifiedOwner(of: signer, now: now.timeIntervalSince1970)
        guard challenge.addresses(memberID: signer.memberID, principal: responder, publicKey: signer.publicKey)
        else { throw DeviceIdentityProof.Failure.invalid }
        guard challenge.confirmedRegistrationID != nil,
              AccountCallPair(requester.restoreBinding.principal, responder).id == challenge.callID else { return nil }
        return requester
    }

    fileprivate func verifiedRequester(trust: DeviceIdentityTrust, now: Date) throws -> AccountDeviceBinding {
        try verifiedRequesterIdentity(trust: trust, now: now).restoreBinding
    }

    private func verifiedRequesterIdentity(trust: DeviceIdentityTrust, now: Date) throws -> VerifiedDeviceIdentity {
        guard challenge.isCurrent(at: now) else { throw DeviceIdentityProof.Failure.invalid }
        let requester = try proof.verify(restoreProofPayload(challenge), purpose: .requestCallRelationshipRestore,
                                         memberID: challenge.requesterMemberID, trust: trust, now: now)
        guard let identity = requester.identity, let principal = requester.principal, principal.isValid,
              principal != challenge.recipient.principal, principal.issuer == challenge.recipient.principal.issuer
        else {
            throw DeviceIdentityProof.Failure.invalid
        }
        return identity
    }
}

extension CallRelationshipBackup {
    func directRestoreRecipient(
        for contactID: UUID, from certificates: [DeviceIdentityCertificate], trust: DeviceIdentityTrust, now: Date
    ) throws -> VerifiedDeviceIdentity? {
        guard let contact = contacts.first(where: { $0.id == contactID }), contact.confirmedRegistrationID != nil,
              contact.restoreRecipientFingerprint != nil else { return nil }
        var matched: VerifiedDeviceIdentity?
        for certificate in certificates {
            guard let identity = try? certificate.verify(
                origin: trust.origin, trustedIssuerKey: trust.issuerKey, now: now),
                  try pinnedDirectCallID(for: contact, memberID: identity.memberID,
                                         recipient: identity.restoreBinding) != nil else { continue }
            if let matched, matched.deviceID != identity.deviceID { return nil }
            if matched.map({ $0.expiresAt < identity.expiresAt }) ?? true { matched = identity }
        }
        return matched
    }

    /// Uses the original device only to address the request. The reply still needs current membership checks.
    func directRestoreRequest(
        for contactID: UUID, to identity: VerifiedDeviceIdentity, as signer: DeviceIdentitySigner, now: Date
    ) throws -> CallRelationshipRestoreRequest? {
        let time = now.timeIntervalSince1970
        _ = try validated(for: Self.verifiedOwner(of: signer, now: time))
        let recipient = identity.restoreBinding
        let contact = contacts.first { $0.id == contactID }
        guard identity.expiresAt > time, let registration = contact?.confirmedRegistrationID,
              let callID = try pinnedDirectCallID(for: contact, memberID: identity.memberID, recipient: recipient)
        else { return nil }
        return try .init(callID: callID, recipientMemberID: identity.memberID, recipient: recipient,
                         signer: signer, now: now, confirmedRegistrationID: registration)
    }

    func matchesDirectRestoreRequest(_ context: CallRelationshipRestoreContext, contactID: UUID) throws -> Bool {
        let address = context.request.challenge
        guard address.callID == context.record.id, let registration = address.confirmedRegistrationID else {
            return false
        }
        let contact = contacts.first { $0.id == contactID }
        return try matchesDirectRestorePeer(contact, memberID: address.recipientMemberID, recipient: address.recipient,
                                            callID: address.callID, registration: registration)
    }

    fileprivate func containsDirectRestorePeer(_ peer: AccountDeviceBinding, memberID: String, callID: UUID,
                                               registration: UUID) throws -> Bool {
        let contact = contacts.first { $0.principal == peer.principal }
        return try matchesDirectRestorePeer(contact, memberID: memberID, recipient: peer,
                                            callID: callID, registration: registration)
    }

    private func matchesDirectRestorePeer(_ contact: Contact?, memberID: String, recipient: AccountDeviceBinding,
                                          callID: UUID, registration: UUID) throws -> Bool {
        guard contact?.confirmedRegistrationID == registration else { return false }
        return try pinnedDirectCallID(for: contact, memberID: memberID, recipient: recipient) == callID
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

private extension VerifiedDeviceIdentity {
    var restoreBinding: AccountDeviceBinding {
        .init(principal: .init(issuer: issuer, userID: userID), publicKey: deviceKey)
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

    func verifiedConfirmation(for request: CallRelationshipRestoreRequest, trust: DeviceIdentityTrust,
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

extension GroupRepository {
    /// A current backup can constrain a direct call to the same relationship recorded in both stores.
    func confirmRestore(
        _ request: CallRelationshipRestoreRequest, as signer: DeviceIdentitySigner, trust: DeviceIdentityTrust,
        now: Date, matchingDirectBackup backup: CallRelationshipBackup? = nil
    ) throws -> CallRelationshipRestoreConfirmation? {
        try withAuthorizedRestore(
            request, as: signer, matching: backup, verifying: (trust, now)
        ) { confirmation, _, _ in confirmation }
    }

    func sealDirectRestore(
        _ request: CallRelationshipRestoreRequest, as signer: DeviceIdentitySigner, trust: DeviceIdentityTrust,
        now: Date, matching backup: CallRelationshipBackup
    ) throws -> DirectCallRestoreResponse? {
        try withAuthorizedRestore(
            request, as: signer, matching: backup, verifying: (trust, now)
        ) { confirmation, record, credential in
            let context = CallRelationshipRestoreContext(request: request, confirmation: confirmation, record: record)
            let packet = try CallRelationshipRestoreCredential(
                credential, for: context, as: signer, trust: trust, now: now)
            return .init(confirmation: confirmation, credential: packet)
        }
    }

    private func withAuthorizedRestore<T>(
        _ request: CallRelationshipRestoreRequest, as signer: DeviceIdentitySigner,
        matching backup: CallRelationshipBackup?, verifying verification: (trust: DeviceIdentityTrust, now: Date),
        _ build: (CallRelationshipRestoreConfirmation, GroupSnapshot.Record, GroupAccessCredential) throws -> T
    ) throws -> T? {
        let (trust, now) = verification
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
                    guard let registration = challenge.confirmedRegistrationID, backup.owner == responder,
                          registration == snapshot.confirmedContactRegistration(
                            localMemberID: signer.memberID, peerMemberID: previous),
                          try backup.containsDirectRestorePeer(priorDevice, memberID: previous, callID: record.id,
                                                             registration: registration)
                    else { return nil }
                }
            }
            guard let reference = record.credentialReference, let secret = try credentialSecret(reference: reference),
                  !secret.isEmpty else { return nil }
            let confirmation = try CallRelationshipRestoreConfirmation(
                request, previousMemberID: previous, signer: signer)
            return try build(confirmation, record, .init(groupID: record.id, secret: secret))
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

func restoreProofPayload<T: Encodable>(_ value: T) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(value)
}
