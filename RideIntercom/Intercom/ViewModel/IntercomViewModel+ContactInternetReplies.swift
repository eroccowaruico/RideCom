import Foundation

extension IntercomViewModel {
    func canTryContactInternetReply(_ record: ContactInvitationRecord) -> Bool {
        guard groupDeliveryClient != nil, hasCurrentAccountAccess, allowsInternetInvitationReplies,
              let access = try? internetSettingsStore.notificationAccess(memberID: localMemberIdentity.memberID) else { return false }
        return contactInternetReplyIsEligible(record, access: access, now: callAccessNow().timeIntervalSince1970)
    }

    func contactReplyWaitsForCurrentCall(_ record: ContactInvitationRecord) -> Bool {
        contactInvitationWaitsForCurrentCall && !canTryContactInternetReply(record)
    }

    func isTryingContactReply(_ id: UUID) -> Bool {
        contactInvitationID == id || activeInternetContactReplyIDs.contains(id)
    }

    func internetContactReplyRecords(access: CallNotificationServiceAccess) -> [ContactInvitationRecord] {
        let now = callAccessNow().timeIntervalSince1970
        return groupRepository.contactInvitations.filter { contactInternetReplyIsEligible($0, access: access, now: now) }
    }

    private func contactInternetReplyIsEligible(_ record: ContactInvitationRecord, access: CallNotificationServiceAccess, now: TimeInterval) -> Bool {
        guard record.canResume(at: now) else { return false }
        if record.direction == .outgoing { return record.internetAcknowledged != true }
        return contactInternetReplyOwner(record, access: access) != nil
    }

    private func contactInternetReplyOwner(_ record: ContactInvitationRecord, access: CallNotificationServiceAccess) -> AccountPrincipal? {
        guard let member = record.peerMemberID, let key = record.peerDeviceKey,
              let owner = groupRepository.users.first(where: { $0.deviceKeys?[member] == key })?.principal,
              owner.issuer == access.principal.issuer, owner != access.principal else { return nil }
        return owner
    }

    func synchronizeInternetContactReplies(_ window: InvitationInternetReplyWindow) async -> Bool {
        for record in internetContactReplyRecords(access: window.access) {
            guard internetReplyWindowIsCurrent(window) else { return false }
            do {
                let payload = try groupRepository.contactInvitationPayload(record.id)
                guard let invitation = payload.token.directInvitation?.context else { continue }
                let address = try InvitationReplyAddress(contactToken: payload.token)
                if record.direction == .outgoing {
                    try await receiveContactInternetAcceptance(record, payload: payload, invitation: invitation, address: address, window: window)
                } else {
                    try await submitContactInternetAcceptance(record, payload: payload, invitation: invitation, address: address, window: window)
                }
            } catch InternetAccountClient.Failure.rateLimited {
                return false
            } catch {
                // The signed checkpoint remains available on the next pass.
            }
        }
        return internetReplyWindowIsCurrent(window)
    }

    private func receiveContactInternetAcceptance(_ record: ContactInvitationRecord, payload: ContactInvitationPayload,
                                                 invitation: DirectInvitationContext, address: InvitationReplyAddress,
                                                 window: InvitationInternetReplyWindow) async throws {
        guard let key = payload.token.identityProof?.publicKey else { return }
        let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID, expectedPublicKey: key)
        guard signer.principal == window.access.principal, invitation.inviterMemberID == signer.memberID else { return }
        if let bound = payload.receipt {
            try await acknowledgeContactInternetAcceptance(bound, invitation: invitation, address: address, signer: signer, window: window)
            return
        }
        if record.isPendingOutgoing, record.sent != false, !window.openedInvitationIDs.contains(record.id) {
            try await window.client.openInvitationReplyMailbox(address, access: window.access)
            window.openedInvitationIDs.insert(record.id)
        }
        guard contactInternetReplyIsCurrent(record, window: window) else { return }
        let inbox = try await window.client.invitationReplyInbox(address, access: window.access)
        for packet in inbox {
            guard contactInternetReplyIsCurrent(record, window: window) else { return }
            let now = callAccessNow().timeIntervalSince1970
            guard let receipt = try? packet.open(address: address, invitation: invitation, kind: .accepted, signer: signer, now: now),
                  (try? applyContactReply(receipt, receivedBySharing: false)) != nil else { continue }
            try await acknowledgeContactInternetAcceptance(receipt, invitation: invitation, address: address, signer: signer, window: window)
            return
        }
    }

    private func acknowledgeContactInternetAcceptance(_ receipt: DirectInvitationReceipt, invitation: DirectInvitationContext,
                                                     address: InvitationReplyAddress, signer: DeviceIdentitySigner,
                                                     window: InvitationInternetReplyWindow) async throws {
        guard internetReplyWindowIsCurrent(window),
              contactInvitationRecord(invitation.id)?.state == .confirmed else { return }
        let confirmation = try receipt.acknowledged(by: signer)
        let sealed = try InvitationReplyPacket.seal(confirmation, address: address, invitation: invitation, now: callAccessNow().timeIntervalSince1970)
        try await window.client.acknowledgeInvitationReply(sealed, address: address, access: window.access)
        guard internetReplyWindowIsCurrent(window) else { return }
        try groupRepository.markContactInternetAcknowledged(invitation.id, receiptID: receipt.id)
        refreshGroupStorageStatus()
    }

    private func submitContactInternetAcceptance(_ record: ContactInvitationRecord, payload: ContactInvitationPayload,
                                                invitation: DirectInvitationContext, address: InvitationReplyAddress,
                                                window: InvitationInternetReplyWindow) async throws {
        guard let owner = contactInternetReplyOwner(record, access: window.access), let pending = payload.receipt,
              let key = pending.inviteeDeviceKey else { return }
        let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID, expectedPublicKey: key)
        guard signer.principal == window.access.principal else { return }
        if !window.submittedReceiptIDs.contains(pending.id) {
            let now = callAccessNow()
            let packet = try InvitationReplyPacket.seal(pending, address: address, invitation: invitation, now: now.timeIntervalSince1970)
            let admission = ContactInvitationReplyAdmission(token: payload.token, address: address,
                                                                 trust: try internetSettingsStore.identityTrust(), now: now)
            do {
                try await window.client.submitInvitationAcceptance(packet, address: address, owner: owner, access: window.access, admission: admission)
            } catch InternetAccountClient.Failure.rejected where admission != nil {
                // An existing mailbox can still accept replies after the author's session changes.
                guard contactInternetReplyIsCurrent(record, window: window) else { return }
                try await window.client.submitInvitationAcceptance(packet, address: address, owner: owner, access: window.access)
            }
            window.submittedReceiptIDs.insert(pending.id)
        }
        guard contactInternetReplyIsCurrent(record, window: window),
              let reply = try await window.client.invitationReplyReceipt(id: pending.id, address: address, owner: owner, access: window.access),
              contactInternetReplyIsCurrent(record, window: window) else { return }
        let confirmation = try reply.open(address: address, invitation: invitation, kind: .acknowledged, signer: signer,
                                          now: callAccessNow().timeIntervalSince1970)
        try applyContactReply(confirmation, receivedBySharing: false)
    }

    private func contactInternetReplyIsCurrent(_ record: ContactInvitationRecord, window: InvitationInternetReplyWindow) -> Bool {
        internetReplyWindowIsCurrent(window) && contactInvitationRecord(record.id) == record
            && contactInternetReplyIsEligible(record, access: window.access, now: callAccessNow().timeIntervalSince1970)
    }
}
