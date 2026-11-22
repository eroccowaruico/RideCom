import Foundation

struct CallRelationshipRestoreRequest: Codable {
    fileprivate struct Challenge: Codable {
        let id: UUID
        let callID: UUID
        let recipient: AccountPrincipal
        let requesterMemberID: String
        let expiresAt: Date

        func isCurrent(at now: Date) -> Bool {
            expiresAt > now && expiresAt <= now.addingTimeInterval(330)
        }
    }

    fileprivate let challenge: Challenge
    fileprivate let proof: DeviceIdentityProof

    init(callID: UUID, recipient: AccountPrincipal, signer: DeviceIdentitySigner, now: Date) throws {
        let requester = try CallRelationshipBackup.verifiedOwner(of: signer, now: now.timeIntervalSince1970)
        guard recipient.isValid, requester != recipient, requester.issuer == recipient.issuer else {
            throw DeviceIdentityProof.Failure.invalid
        }
        let challenge = Challenge(id: UUID(), callID: callID, recipient: recipient, requesterMemberID: signer.memberID,
                                  expiresAt: now.addingTimeInterval(300))
        self.challenge = challenge
        proof = try signer.sign(restoreProofPayload(challenge), purpose: .requestCallRelationshipRestore)
    }

    fileprivate func verify(trust: DeviceIdentityTrust, now: Date) throws -> VerifiedDeviceProof {
        guard challenge.isCurrent(at: now) else { throw DeviceIdentityProof.Failure.invalid }
        let requester = try proof.verify(restoreProofPayload(challenge), purpose: .requestCallRelationshipRestore,
                                         memberID: challenge.requesterMemberID, trust: trust, now: now)
        guard let principal = requester.principal, principal.isValid, principal != challenge.recipient,
              principal.issuer == challenge.recipient.issuer else { throw DeviceIdentityProof.Failure.invalid }
        return requester
    }
}

struct CallRelationshipRestoreConfirmation: Codable {
    private struct Claim: Encodable {
        let request: CallRelationshipRestoreRequest
        let previousMemberID: String
    }

    let responderMemberID: String
    private let previousMemberID: String
    private let proof: DeviceIdentityProof

    fileprivate init(_ request: CallRelationshipRestoreRequest, previousMemberID: String,
                     signer: DeviceIdentitySigner) throws {
        responderMemberID = signer.memberID
        self.previousMemberID = previousMemberID
        let claim = Claim(request: request, previousMemberID: previousMemberID)
        proof = try signer.sign(restoreProofPayload(claim), purpose: .confirmCallRelationshipRestore)
    }

    func replacedMemberID(for request: CallRelationshipRestoreRequest, trust: DeviceIdentityTrust,
                          now: Date) throws -> String {
        guard request.challenge.isCurrent(at: now), IntercomGroup.isValidMemberID(previousMemberID),
              !previousMemberID.hasPrefix(GroupMember.pendingInvitePrefix),
              previousMemberID != request.challenge.requesterMemberID else {
            throw DeviceIdentityProof.Failure.invalid
        }
        let claim = Claim(request: request, previousMemberID: previousMemberID)
        let responder = try proof.verify(restoreProofPayload(claim), purpose: .confirmCallRelationshipRestore,
                                         memberID: responderMemberID, trust: trust, now: now)
        guard responder.principal == request.challenge.recipient else { throw DeviceIdentityProof.Failure.invalid }
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
        guard responder == challenge.recipient, localMemberID == signer.memberID,
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
