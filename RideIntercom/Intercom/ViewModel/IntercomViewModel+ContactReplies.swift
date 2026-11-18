import Foundation

extension IntercomViewModel {
    /// Sharing neither starts transport nor records delivery. The OS requests this only on export.
    func contactReplyURLForSharing(_ id: UUID, expectedAccountAccessID: UUID) throws -> URL {
        guard canEditSavedGroups, expectedAccountAccessID == accountAccessID,
              let record = contactInvitationRecord(id), record.canResume,
              callAccessNow().timeIntervalSince1970 < record.expiresAt else { throw ContactInvitationError.unavailable }
        let payload = try groupRepository.contactInvitationPayload(id)
        guard let receipt = payload.receipt else { throw ContactInvitationError.unavailable }
        let reply: DirectInvitationReceipt
        if record.direction == .incoming {
            guard record.state == .pending, receipt.inviteeMemberID == localMemberIdentity.memberID else { throw ContactInvitationError.unavailable }
            _ = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID, expectedPublicKey: receipt.inviteeDeviceKey)
            reply = receipt
        } else {
            guard record.state == .confirmed else { throw ContactInvitationError.unavailable }
            let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID, expectedPublicKey: payload.token.identityProof?.publicKey)
            reply = try receipt.acknowledged(by: signer)
        }
        return try ContactReplyURL.make(reply)
    }

    /// Equivalent to the bounded control exchange, without requiring any network or changing calls.
    func receiveContactReplyURL(_ url: URL) throws {
        guard canEditSavedGroups else { throw ContactInvitationError.unavailable }
        let receipt = try ContactReplyURL.decode(url)
        let now = callAccessNow().timeIntervalSince1970
        guard let context = receipt.invitation, now < context.expiresAt,
              let record = contactInvitationRecord(context.id), now < record.expiresAt else { throw ContactInvitationError.unavailable }
        switch receipt.kind {
        case .accepted:
            guard record.direction == .outgoing, record.canResume,
                  receipt.inviterMemberID == localMemberIdentity.memberID else { throw ContactInvitationError.unavailable }
            let payload = try groupRepository.contactInvitationPayload(record.id)
            guard payload.token.directInvitation?.context == context,
                  payload.receipt == nil || payload.receipt == receipt,
                  let verified = try invitationAuthority.verify(receipt, trust: internetSettingsStore.identityTrust(), now: now) else { throw GroupStorageError.identityConflict }
            try groupRepository.confirmContactInvitation(verified, localDisplayName: localMemberIdentity.displayName, now: now)
            adoptStoredDirectCall(with: verified.identity.memberID)
        case .acknowledged:
            guard record.direction == .incoming, receipt.inviteeMemberID == localMemberIdentity.memberID,
                  record.peerMemberID == receipt.inviterMemberID, record.peerDeviceKey == context.inviterDeviceKey,
                  record.receiptID == receipt.id, record.state == .pending || record.state == .delivered else { throw ContactInvitationError.unavailable }
            _ = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID, expectedPublicKey: receipt.inviteeDeviceKey)
            var expected = receipt; expected.kind = .accepted; expected.acknowledgementProof = nil
            if record.state == .pending {
                let payload = try groupRepository.contactInvitationPayload(record.id)
                guard payload.token.directInvitation?.context == context, payload.receipt == expected else { throw GroupStorageError.identityConflict }
            }
            try receipt.verifyAcknowledgement(of: expected, trust: internetSettingsStore.identityTrust(), now: now)
            if record.state == .pending { try groupRepository.completeContactNotification(record.id) }
            if contactInvitationID == record.id { stopContactInvitationSession() }
        }
        contactInvitationMessage = nil
        refreshGroupStorageStatus()
    }
}
