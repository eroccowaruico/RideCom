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

    fileprivate func verify(trust: DeviceIdentityTrust, now: Date) throws -> VerifiedDeviceProof {
        guard challenge.isCurrent(at: now) else { throw DeviceIdentityProof.Failure.invalid }
        let requester = try proof.verify(restoreProofPayload(challenge), purpose: .requestCallRelationshipRestore,
                                         memberID: challenge.requesterMemberID, trust: trust, now: now)
        guard let principal = requester.principal, principal.isValid, principal != challenge.recipient.principal,
              principal.issuer == challenge.recipient.principal.issuer else {
            throw DeviceIdentityProof.Failure.invalid
        }
        return requester
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
        guard identity.expiresAt > time, let contact = contacts.first(where: { $0.id == contactID }),
              contact.principal == principal, let saved = contact.restoreRecipientFingerprint else { return nil }
        let callID = AccountCallPair(owner, principal).id
        let fingerprint = try CallRelationshipRestoreRequest.recipientFingerprint(
            callID: callID, memberID: identity.memberID, key: identity.deviceKey)
        guard fingerprint == saved else { return nil }
        let recipient = AccountDeviceBinding(principal: principal, publicKey: identity.deviceKey)
        return try .init(callID: callID, recipientMemberID: identity.memberID, recipient: recipient,
                         signer: signer, now: now)
    }
}

struct CallRelationshipRestoreConfirmation: Codable {
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

    func replacedMemberID(for request: CallRelationshipRestoreRequest, trust: DeviceIdentityTrust,
                          now: Date) throws -> String {
        let challenge = request.challenge
        guard challenge.isCurrent(at: now), IntercomGroup.isValidMemberID(previousMemberID),
              !previousMemberID.hasPrefix(GroupMember.pendingInvitePrefix),
              previousMemberID != challenge.requesterMemberID else {
            throw DeviceIdentityProof.Failure.invalid
        }
        let claim = Claim(request: request, previousMemberID: previousMemberID)
        let responder = try proof.verify(restoreProofPayload(claim), purpose: .confirmCallRelationshipRestore,
                                         memberID: challenge.recipientMemberID, trust: trust, now: now)
        guard challenge.addresses(memberID: responder.memberID, principal: responder.principal,
                                  publicKey: responder.publicKey) else { throw DeviceIdentityProof.Failure.invalid }
        return previousMemberID
    }
}

extension GroupRepository {
    /// Verifies what this device currently holds. It does not reconcile other devices' changes.
    func confirmRestore(_ request: CallRelationshipRestoreRequest, as signer: DeviceIdentitySigner,
                        trust: DeviceIdentityTrust, now: Date) throws -> CallRelationshipRestoreConfirmation? {
        let challenge = request.challenge
        let requester = try request.verify(trust: trust, now: now)
        let responder = try CallRelationshipBackup.verifiedOwner(of: signer, now: now.timeIntervalSince1970)
        guard challenge.addresses(memberID: signer.memberID, principal: responder, publicKey: signer.publicKey),
              localMemberID == signer.memberID,
              let owner = requester.principal else { throw DeviceIdentityProof.Failure.invalid }
        guard let snapshot = writableSnapshot else { throw IntercomGroupError.storageUnavailable }
        return try withCurrentSnapshot(snapshot) {
            guard let record = snapshot.groups.first(where: { $0.id == challenge.callID }),
                  record.pendingInvitation == nil,
                  record.accountDevices[signer.memberID] == .init(principal: responder, publicKey: signer.publicKey),
                  !record.excludesMember(requester.memberID, principal: owner),
                  !record.members.contains(where: { $0.id == requester.memberID }),
                  let previous = record.soleRestorePredecessor(for: owner, replacingKeyWith: requester.publicKey)
            else { return nil }
            if record.kind == .direct {
                guard record.accountPair == AccountCallPair(responder, owner),
                      snapshot.users.contains(where: { user in
                          user.principal == owner && user.memberIDs.contains(previous)
                              && user.deviceKeys?[previous] == record.accountDevices[previous]?.publicKey
                      }) else { return nil }
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
