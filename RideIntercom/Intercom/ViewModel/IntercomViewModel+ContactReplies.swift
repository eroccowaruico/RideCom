import Foundation

extension IntercomViewModel {
    func canShareContactReply(_ record: ContactInvitationRecord) -> Bool {
        guard canEditSavedGroups, contactInvitationRecord(record.id) == record,
              let peer = record.peerMemberID, let key = record.peerDeviceKey,
              savedRemoteUsers.contains(where: { $0.memberIDs.contains(peer) && $0.deviceKeys?[peer] == key })
        else { return false }
        return record.canResume(at: callAccessNow().timeIntervalSince1970)
            && ((record.direction == .incoming && record.state == .pending)
                || (record.direction == .outgoing && record.state == .confirmed))
    }

    @discardableResult
    func handleContactReplyURL(_ url: URL) -> Bool {
        do { try receiveContactReplyURL(url); return true } catch {
            contactInvitationMessage = "This reply could not be saved. Check the sender and invitation, then try again."
            return false
        }
    }

    /// Sharing neither starts transport nor records delivery. The OS requests this only on export.
    func contactReplyURLForSharing(_ id: UUID, expectedAccountAccessID: UUID) throws -> URL {
        guard expectedAccountAccessID == accountAccessID,
              let record = contactInvitationRecord(id), canShareContactReply(record)
        else { throw ContactInvitationError.unavailable }
        let payload = try loadContactReplyPayload(id)
        guard let receipt = payload.receipt else { throw ContactInvitationError.unavailable }
        let reply: DirectInvitationReceipt
        if record.direction == .incoming {
            guard record.state == .pending, receipt.inviteeMemberID == localMemberIdentity.memberID else {
                throw ContactInvitationError.unavailable
            }
            _ = try internetSettingsStore.invitationSigner(
                memberID: localMemberIdentity.memberID, expectedPublicKey: receipt.inviteeDeviceKey)
            reply = receipt
        } else {
            guard record.state == .confirmed else { throw ContactInvitationError.unavailable }
            let signer = try internetSettingsStore.invitationSigner(
                memberID: localMemberIdentity.memberID, expectedPublicKey: payload.token.identityProof?.publicKey)
            reply = try receipt.acknowledged(by: signer)
        }
        return try ContactReplyURL.make(reply)
    }

    /// Equivalent to the bounded control exchange, without requiring any network or changing calls.
    func receiveContactReplyURL(_ url: URL) throws {
        try applyContactReply(ContactReplyURL.decode(url), receivedBySharing: true)
    }

    func applyContactReply(_ receipt: DirectInvitationReceipt, receivedBySharing: Bool) throws {
        guard canEditSavedGroups else { throw ContactInvitationError.unavailable }
        let now = callAccessNow().timeIntervalSince1970
        guard let context = receipt.invitation, now < context.expiresAt,
              let record = contactInvitationRecord(context.id), now < record.expiresAt
        else { throw ContactInvitationError.unavailable }
        switch receipt.kind {
        case .accepted:
            try applyContactAcceptance(receipt, record: record, context: context, now: now,
                                       receivedBySharing: receivedBySharing)
        case .acknowledged:
            try applyContactAcknowledgement(receipt, record: record, context: context, now: now)
        }
        contactInvitationMessage = nil
        refreshGroupStorageStatus()
    }

    private func applyContactAcceptance(
        _ receipt: DirectInvitationReceipt, record: ContactInvitationRecord,
        context: DirectInvitationContext, now: TimeInterval, receivedBySharing: Bool
    ) throws {
        guard record.direction == .outgoing, record.canResume,
              receipt.inviterMemberID == localMemberIdentity.memberID
        else { throw ContactInvitationError.unavailable }
        let payload = try loadContactReplyPayload(record.id)
        guard payload.token.directInvitation?.context == context,
              payload.receipt == nil || payload.receipt == receipt,
              let verified = try invitationAuthority.verify(
                receipt, trust: internetSettingsStore.identityTrust(), now: now)
        else { throw GroupStorageError.identityConflict }
        do {
            try groupRepository.confirmContactInvitation(
                verified, localDisplayName: localMemberIdentity.displayName,
                now: now, receivedBySharing: receivedBySharing)
        } catch { reportGroupStorageError(error); throw error }
        adoptStoredContactRegistration(with: verified.identity.memberID, invitationID: record.id)
    }

    private func applyContactAcknowledgement(
        _ receipt: DirectInvitationReceipt, record: ContactInvitationRecord,
        context: DirectInvitationContext, now: TimeInterval
    ) throws {
        guard record.direction == .incoming, receipt.inviteeMemberID == localMemberIdentity.memberID,
              record.peerMemberID == receipt.inviterMemberID, record.peerDeviceKey == context.inviterDeviceKey,
              record.receiptID == receipt.id, record.state == .pending || record.state == .delivered
        else { throw ContactInvitationError.unavailable }
        _ = try internetSettingsStore.invitationSigner(
            memberID: localMemberIdentity.memberID, expectedPublicKey: receipt.inviteeDeviceKey)
        var expected = receipt
        expected.kind = .accepted
        expected.acknowledgementProof = nil
        if record.state == .pending {
            let payload = try loadContactReplyPayload(record.id)
            guard payload.token.directInvitation?.context == context, payload.receipt == expected else {
                throw GroupStorageError.identityConflict
            }
        }
        try receipt.verifyAcknowledgement(of: expected, trust: internetSettingsStore.identityTrust(), now: now)
        if record.state == .pending {
            do { try groupRepository.completeContactNotification(record.id) } catch {
                reportGroupStorageError(error); throw error
            }
        }
        if contactInvitationID == record.id { stopContactInvitationSession() }
    }

    /// A checkpoint read failure needs the same reload path as a failed registration write.
    private func loadContactReplyPayload(_ id: UUID) throws -> ContactInvitationPayload {
        do { return try groupRepository.contactInvitationPayload(id) } catch {
            reportGroupStorageError(error); throw error
        }
    }

}
