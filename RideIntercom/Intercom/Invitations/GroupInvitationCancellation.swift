import Foundation

nonisolated struct GroupInvitationCancellation: Codable, Sendable {
    struct Target: Codable, Hashable, Sendable {
        let id: UUID
        let groupID: UUID
        let sender: AccountPrincipal
        let senderMemberID: String
        let recipient: AccountPrincipal
        let recipientMemberID: String
        let recipientKey: String
        let expiresAt: TimeInterval
        let envelopeDigest: Data

        var isValid: Bool {
            sender.isValid && recipient.isValid && sender != recipient && sender.issuer == recipient.issuer
                && IntercomGroup.isValidMemberID(senderMemberID) && IntercomGroup.isValidMemberID(recipientMemberID)
                && senderMemberID != recipientMemberID && DeviceIdentityProof.isValidPublicKey(recipientKey)
                && expiresAt.isFinite && expiresAt > 0 && envelopeDigest.count == 32
        }
    }

    let target: Target
    let proof: DeviceIdentityProof

    init(target: Target, signer: DeviceIdentitySigner) throws {
        guard target.isValid, signer.memberID == target.senderMemberID,
              signer.principal == nil || signer.principal == target.sender else { throw DeviceIdentityProof.Failure.invalid }
        self.target = target
        proof = try signer.sign(Self.message(target), purpose: .cancelGroupInvitation)
    }

    func verify(from peerID: String, local: AccountPrincipal, signer: DeviceIdentitySigner, sender: SavedUser?, now: Date) throws {
        let time = now.timeIntervalSince1970
        guard target.isValid, target.senderMemberID == peerID, target.recipient == local,
              target.recipientMemberID == signer.memberID, target.recipientKey == signer.publicKey,
              target.expiresAt > time, target.expiresAt <= time + 7 * 86400 + 300,
              let sender, sender.principal == target.sender, sender.memberIDs.contains(peerID),
              sender.deviceKeys?[peerID] == proof.publicKey else { throw DeviceIdentityProof.Failure.invalid }
        _ = try proof.verify(Self.message(target), purpose: .cancelGroupInvitation, memberID: peerID)
    }

    fileprivate static func message(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
}

extension GroupInvitationCancellation.Target {
    init(envelope: GroupInvitationEnvelope, groupID: UUID) throws {
        self.init(id: envelope.id, groupID: groupID, sender: envelope.sender, senderMemberID: envelope.senderMemberID,
                  recipient: envelope.recipient, recipientMemberID: envelope.recipientMemberID, recipientKey: envelope.recipientKey,
                  expiresAt: envelope.expiresAt, envelopeDigest: try envelope.receiptDigest())
    }
}

nonisolated struct GroupInvitationCancellationReceipt: Codable, Sendable {
    enum Outcome: String, Codable, Sendable { case cancelled, alreadyReceived }

    private struct Decision: Codable, Sendable {
        let target: GroupInvitationCancellation.Target
        let outcome: Outcome
    }

    private let decision: Decision
    private let proof: DeviceIdentityProof

    var target: GroupInvitationCancellation.Target { decision.target }
    var outcome: Outcome { decision.outcome }

    init(for target: GroupInvitationCancellation.Target, outcome: Outcome, signer: DeviceIdentitySigner) throws {
        guard signer.memberID == target.recipientMemberID, signer.publicKey == target.recipientKey
        else { throw DeviceIdentityProof.Failure.invalid }
        decision = Decision(target: target, outcome: outcome)
        proof = try signer.sign(GroupInvitationCancellation.message(decision), purpose: .acknowledgeGroupInvitationCancellation)
    }

    func verify(for target: GroupInvitationCancellation.Target) throws {
        guard self.target == target, proof.publicKey == target.recipientKey else { throw DeviceIdentityProof.Failure.invalid }
        _ = try proof.verify(GroupInvitationCancellation.message(decision), purpose: .acknowledgeGroupInvitationCancellation,
                             memberID: target.recipientMemberID)
    }
}
