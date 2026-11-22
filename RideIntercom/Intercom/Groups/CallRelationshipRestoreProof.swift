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
        guard identity.expiresAt > time,
              let callID = try pinnedDirectCallID(for: contactID, memberID: identity.memberID, recipient: recipient)
        else { return nil }
        return try .init(callID: callID, recipientMemberID: identity.memberID, recipient: recipient,
                         signer: signer, now: now)
    }

    func matchesDirectRestoreRequest(_ request: CallRelationshipRestoreRequest, callID: UUID,
                                     contactID: UUID) throws -> Bool {
        let address = request.challenge
        guard address.callID == callID else { return false }
        return try pinnedDirectCallID(for: contactID, memberID: address.recipientMemberID,
                                      recipient: address.recipient) == callID
    }

    private func pinnedDirectCallID(for contactID: UUID, memberID: String, recipient: AccountDeviceBinding) throws
        -> UUID? {
        guard let contact = contacts.first(where: { $0.id == contactID }),
              contact.principal == recipient.principal, let saved = contact.restoreRecipientFingerprint
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

/// Carries a call key already authorized by the caller for release to the requesting device.
struct CallRelationshipRestoreCredential: Codable {
    private static let domain = "rideintercom.call-restore-credential.ecdh.v1"
    private static let publicKeySize = 65
    private static let overhead = publicKeySize + 28
    private static let maximumSecretSize = 256
    private let packet: Data
    private let proof: DeviceIdentityProof

    private struct Context: Encodable {
        let request: CallRelationshipRestoreRequest
        let confirmation: CallRelationshipRestoreConfirmation

        func header() throws -> Data { try Data(SHA256.hash(data: restoreProofPayload(self))) }
    }

    private struct Packet: Encodable {
        let header: Data
        let packet: Data
    }

    init(_ credential: GroupAccessCredential, request: CallRelationshipRestoreRequest,
         confirmation: CallRelationshipRestoreConfirmation, as signer: DeviceIdentitySigner,
         trust: DeviceIdentityTrust, now: Date) throws {
        let verified = try confirmation.verifiedConfirmation(for: request, trust: trust, now: now)
        let owner = try CallRelationshipBackup.verifiedOwner(of: signer, now: now.timeIntervalSince1970)
        let secret = Data(credential.secret.utf8)
        guard signer.memberID == verified.responderMemberID,
              verified.responder == .init(principal: owner, publicKey: signer.publicKey),
              credential.groupID == verified.callID, (1...Self.maximumSecretSize).contains(secret.count),
              let target = IdentityEncoding.decode(verified.requester.publicKey)
        else { throw DeviceIdentityProof.Failure.invalid }
        let header = try Context(request: request, confirmation: confirmation).header()
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let recipient = try P256.KeyAgreement.PublicKey(x963Representation: target)
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: recipient)
        let key = DeviceIdentitySigner.sealedPayloadKey(shared, domain: Self.domain, header: header)
        guard let sealed = try AES.GCM.seal(secret, using: key, authenticating: header).combined
        else { throw DeviceIdentityProof.Failure.invalid }
        packet = ephemeral.publicKey.x963Representation + sealed
        proof = try signer.sign(restoreProofPayload(Packet(header: header, packet: packet)),
                                purpose: .deliverCallRelationshipRestoreCredential)
    }

    func open(for request: CallRelationshipRestoreRequest, confirmation: CallRelationshipRestoreConfirmation,
              as signer: DeviceIdentitySigner, trust: DeviceIdentityTrust, now: Date) throws
        -> (confirmation: CallRelationshipRestoreConfirmation.Verified, credential: GroupAccessCredential) {
        let verified = try confirmation.verify(for: request, as: signer, trust: trust, now: now)
        guard (Self.overhead + 1...Self.overhead + Self.maximumSecretSize).contains(packet.count)
        else { throw DeviceIdentityProof.Failure.invalid }
        let header = try Context(request: request, confirmation: confirmation).header()
        let sender = try proof.verify(restoreProofPayload(Packet(header: header, packet: packet)),
            purpose: .deliverCallRelationshipRestoreCredential, memberID: verified.responderMemberID,
            trust: trust, now: now)
        guard sender.principal == verified.responder.principal, sender.publicKey == verified.responder.publicKey
        else { throw DeviceIdentityProof.Failure.invalid }
        let secret = try signer.openSealedPayload(packet.dropFirst(Self.publicKeySize),
            ephemeralKey: packet.prefix(Self.publicKeySize), domain: Self.domain, header: header)
        guard let text = String(data: secret, encoding: .utf8) else { throw DeviceIdentityProof.Failure.invalid }
        return (verified, .init(groupID: verified.callID, secret: text))
    }
}

extension GroupRepository {
    /// Verifies what this device currently holds. It does not reconcile other devices' changes.
    func confirmRestore(_ request: CallRelationshipRestoreRequest, as signer: DeviceIdentitySigner,
                        trust: DeviceIdentityTrust, now: Date) throws -> CallRelationshipRestoreConfirmation? {
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
                  record.accountDevices[signer.memberID] == .init(principal: responder, publicKey: signer.publicKey),
                  !record.excludesMember(challenge.requesterMemberID, principal: owner),
                  !record.members.contains(where: { $0.id == challenge.requesterMemberID }),
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
