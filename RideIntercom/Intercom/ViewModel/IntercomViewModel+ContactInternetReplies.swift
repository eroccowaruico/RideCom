import Foundation

extension IntercomViewModel {
    private struct ContactAcceptanceUploadReply: Decodable {
        let id: UUID
        let expiresAt: Int64
    }

    func backgroundInvitationUploadIDs() -> Set<InvitationBackgroundUploadID> {
        guard canEditSavedGroups,
              let access = try? internetSettingsStore.notificationAccess(memberID: localMemberIdentity.memberID)
        else { return [] }
        return backgroundInvitationUploadIDs(access: access)
    }

    private func backgroundInvitationUploadIDs(
        access: CallNotificationServiceAccess
    ) -> Set<InvitationBackgroundUploadID> {
        guard let binding = InternetAccountClient.backgroundSubmissionSessionBinding(for: access.accessToken)
        else { return [] }
        let outgoing = backgroundGroupInvitationUploadIDs(access: access, binding: binding)
            .union(backgroundContactDeletionUploadIDs(access: access, binding: binding))
        guard hasCurrentAccountAccess, allowsInternetInvitationReplies, groupDeliveryClient != nil
        else { return outgoing }
        return outgoing.union(internetContactReplyRecords(access: access).compactMap {
            contactAcceptanceUploadID($0, binding: binding)
        })
    }

    func applyBackgroundInvitationResponse(_ data: Data, for key: InvitationBackgroundUploadID) {
        let decoder = JSONDecoder()
        switch key.operation {
        case .send, .cancel:
            if let reply = try? decoder.decode(GroupDeliveryReply.self, from: data) {
                applyBackgroundGroupInvitationReply(reply, for: key)
            }
        case .contactDeletion:
            if let state = InternetAccountClient.contactDeletionResponseState(data) {
                applyBackgroundContactDeletionReply(state, for: key)
            }
        case .contactAcceptance:
            guard groupDeliveryClient != nil, let access = invitationInternetAccess,
                  let binding = InternetAccountClient.backgroundSubmissionSessionBinding(for: access.accessToken),
                  let record = contactInvitationRecord(key.deliveryID),
                  contactAcceptanceUploadID(record, binding: binding) == key,
                  contactInternetReplyIsEligible(record, access: access, now: callAccessNow().timeIntervalSince1970),
                let reply = try? decoder.decode(ContactAcceptanceUploadReply.self, from: data),
                record.receiptID == reply.id,
                  Int64(exactly: (record.expiresAt * 1000).rounded(.down)) == reply.expiresAt else { return }
            do {
                try groupRepository.markContactInternetAcceptanceSubmitted(record.id, receiptID: reply.id)
                contactAcceptanceSubmittedInBackground(record.id)
            } catch { reportGroupStorageError(error) }
        }
    }

    private func contactAcceptanceUploadID(
        _ record: ContactInvitationRecord, binding: String
    ) -> InvitationBackgroundUploadID? {
        guard record.direction == .incoming, record.state == .pending, record.internetAcceptanceSubmitted != true
        else { return nil }
        return .init(deliveryID: record.id, sessionBinding: binding, operation: .contactAcceptance)
    }

    func scheduleBackgroundContactAcceptances(access: CallNotificationServiceAccess) {
        guard let transfer = invitationBackgroundTransfer, transfer.hasRestored else { return }
        let keys = backgroundInvitationUploadIDs(access: access)
        transfer.reconcile(keeping: keys)
        let contactKeys = keys.filter { $0.operation == .contactAcceptance }
        let capacity = 60 - contactKeys.count(where: { transfer.contains($0) })
        guard capacity > 0 else { return }
        for key in contactKeys.lazy.filter({ !transfer.contains($0) }).prefix(capacity) {
            guard let record = contactInvitationRecord(key.deliveryID),
                  let request = try? backgroundContactAcceptanceRequest(record, access: access) else { continue }
            try? transfer.enqueue(request, for: key)
        }
    }

    private func backgroundContactAcceptanceRequest(
        _ record: ContactInvitationRecord, access: CallNotificationServiceAccess
    ) throws -> URLRequest? {
        let payload = try groupRepository.contactInvitationPayload(record.id)
        guard let owner = contactInternetReplyOwner(record, access: access),
              let pending = payload.receipt, let key = pending.inviteeDeviceKey,
              let invitation = payload.token.directInvitation?.context else { return nil }
        let signer = try internetSettingsStore.invitationSigner(
            memberID: localMemberIdentity.memberID, expectedPublicKey: key)
        let address = try InvitationReplyAddress(contactToken: payload.token)
        let (packet, admission) = try prepareContactInternetAcceptance(
            pending, payload: payload, invitation: invitation, address: address)
        let acceptance = InternetAccountClient.ContactAcceptance(
            packet: packet, address: address, owner: owner, admission: admission)
        return try InternetAccountClient.backgroundContactAcceptanceRequest(
            acceptance, access: access, signer: signer, now: callAccessNow())
    }

    func canTryContactInternetReply(_ record: ContactInvitationRecord) -> Bool {
        guard groupDeliveryClient != nil, let access = invitationInternetAccess else { return false }
        return contactInternetReplyIsEligible(record, access: access, now: callAccessNow().timeIntervalSince1970)
    }

    func contactReplyWaitsForCurrentCall(_ record: ContactInvitationRecord) -> Bool {
        contactInvitationWaitsForCurrentCall && !canTryContactInternetReply(record)
    }

    func isTryingContactReply(_ id: UUID) -> Bool {
        contactInvitationID == id || activeInternetContactReplyIDs.contains(id)
    }

    func internetContactReplyRecords(
        access: CallNotificationServiceAccess, includeUnshared: Bool = true
    ) -> [ContactInvitationRecord] {
        let now = callAccessNow().timeIntervalSince1970
        return groupRepository.contactInvitations.filter {
            contactInternetReplyIsEligible($0, access: access, now: now)
                && (includeUnshared || !$0.isPendingOutgoing || $0.sent != false)
        }
    }

    private func contactInternetReplyIsEligible(
        _ record: ContactInvitationRecord, access: CallNotificationServiceAccess, now: TimeInterval
    ) -> Bool {
        guard record.canResume(at: now) else { return false }
        if record.direction == .outgoing { return record.internetAcknowledged != true }
        return contactInternetReplyOwner(record, access: access) != nil
    }

    private func contactInternetReplyOwner(
        _ record: ContactInvitationRecord, access: CallNotificationServiceAccess
    ) -> AccountPrincipal? {
        guard let member = record.peerMemberID, let key = record.peerDeviceKey,
              let owner = groupRepository.users.first(where: { $0.deviceKeys?[member] == key })?.principal,
              owner.issuer == access.principal.issuer, owner != access.principal else { return nil }
        return owner
    }

    func synchronizeInternetContactReplies(
        _ window: InvitationInternetReplyWindow, records: [ContactInvitationRecord]
    ) async -> Bool {
        for record in records {
            guard internetReplyWindowIsCurrent(window) else { return false }
            do {
                let payload = try groupRepository.contactInvitationPayload(record.id)
                guard let invitation = payload.token.directInvitation?.context else { continue }
                let address = try InvitationReplyAddress(contactToken: payload.token)
                if record.direction == .outgoing {
                    try await receiveContactInternetAcceptance(
                        record, payload: payload, invitation: invitation, address: address, window: window)
                } else {
                    try await submitContactInternetAcceptance(
                        record, payload: payload, invitation: invitation, address: address, window: window)
                }
            } catch InternetAccountClient.Failure.rateLimited {
                return false
            } catch {
                // The signed checkpoint remains available on the next pass.
            }
        }
        return internetReplyWindowIsCurrent(window)
    }

    private func receiveContactInternetAcceptance(
        _ record: ContactInvitationRecord,
        payload: ContactInvitationPayload,
        invitation: DirectInvitationContext,
        address: InvitationReplyAddress,
        window: InvitationInternetReplyWindow
    ) async throws {
        guard let key = payload.token.identityProof?.publicKey else { return }
        let signer = try internetSettingsStore.invitationSigner(
            memberID: localMemberIdentity.memberID, expectedPublicKey: key)
        guard signer.principal == window.access.principal, invitation.inviterMemberID == signer.memberID else { return }
        if let bound = payload.receipt {
            try await acknowledgeContactInternetAcceptance(
                bound, invitation: invitation, address: address, signer: signer, window: window)
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
            guard
                let receipt = try? packet.open(
                    address: address, invitation: invitation, kind: .accepted, signer: signer, now: now),
                  (try? applyContactReply(receipt, receivedBySharing: false)) != nil else { continue }
            try await acknowledgeContactInternetAcceptance(
                receipt, invitation: invitation, address: address, signer: signer, window: window)
            return
        }
    }

    private func acknowledgeContactInternetAcceptance(
        _ receipt: DirectInvitationReceipt,
        invitation: DirectInvitationContext,
        address: InvitationReplyAddress,
        signer: DeviceIdentitySigner,
        window: InvitationInternetReplyWindow
    ) async throws {
        guard internetReplyWindowIsCurrent(window),
              contactInvitationRecord(invitation.id)?.state == .confirmed else { return }
        let confirmation = try receipt.acknowledged(by: signer)
        let sealed = try InvitationReplyPacket.seal(
            confirmation, address: address, invitation: invitation, now: callAccessNow().timeIntervalSince1970)
        try await window.client.acknowledgeInvitationReply(sealed, address: address, access: window.access)
        guard internetReplyWindowIsCurrent(window) else { return }
        try groupRepository.markContactInternetAcknowledged(invitation.id, receiptID: receipt.id)
        refreshGroupStorageStatus()
    }

    private func submitContactInternetAcceptance(
        _ record: ContactInvitationRecord,
        payload: ContactInvitationPayload,
        invitation: DirectInvitationContext,
        address: InvitationReplyAddress,
        window: InvitationInternetReplyWindow
    ) async throws {
        guard let owner = contactInternetReplyOwner(record, access: window.access), let pending = payload.receipt,
              let key = pending.inviteeDeviceKey else { return }
        let signer = try internetSettingsStore.invitationSigner(
            memberID: localMemberIdentity.memberID, expectedPublicKey: key)
        guard signer.principal == window.access.principal else { return }
        let uploadID = InternetAccountClient.backgroundSubmissionSessionBinding(for: window.access.accessToken)
            .flatMap { contactAcceptanceUploadID(record, binding: $0) }
        let uploadInProgress = uploadID.map { invitationBackgroundTransfer?.contains($0) == true } ?? false
        if record.internetAcceptanceSubmitted != true, !uploadInProgress {
            let (packet, admission) = try prepareContactInternetAcceptance(
                pending, payload: payload, invitation: invitation, address: address)
            do {
                try await window.client.submitInvitationAcceptance(
                    packet, address: address, owner: owner, access: window.access, admission: admission)
            } catch InternetAccountClient.Failure.rejected where admission != nil {
                // An existing mailbox can still accept replies after the author's session changes.
                guard contactInternetReplyIsCurrent(record, window: window) else { return }
                try await window.client.submitInvitationAcceptance(
                    packet, address: address, owner: owner, access: window.access)
            }
            guard contactInternetReplyIsCurrent(record, window: window) else { return }
            try groupRepository.markContactInternetAcceptanceSubmitted(record.id, receiptID: pending.id)
            refreshGroupStorageStatus()
        }
        guard contactInternetReplyIsCurrent(record, window: window),
            let reply = try await window.client.invitationReplyReceipt(
                id: pending.id, address: address, owner: owner, access: window.access),
              contactInternetReplyIsCurrent(record, window: window) else { return }
        let confirmation = try reply.open(address: address, invitation: invitation, kind: .acknowledged, signer: signer,
                                          now: callAccessNow().timeIntervalSince1970)
        try applyContactReply(confirmation, receivedBySharing: false)
    }

    private func prepareContactInternetAcceptance(_ receipt: DirectInvitationReceipt, payload: ContactInvitationPayload,
                                                  invitation: DirectInvitationContext, address: InvitationReplyAddress)
        throws -> (InvitationReplyPacket, ContactInvitationReplyAdmission?) {
        let now = callAccessNow()
        let packet = try InvitationReplyPacket.seal(
            receipt, address: address, invitation: invitation, now: now.timeIntervalSince1970)
        let admission = ContactInvitationReplyAdmission(token: payload.token, address: address,
                                                        trust: try internetSettingsStore.identityTrust(), now: now)
        return (packet, admission)
    }

    private func contactInternetReplyIsCurrent(
        _ record: ContactInvitationRecord, window: InvitationInternetReplyWindow
    ) -> Bool {
        guard internetReplyWindowIsCurrent(window), let current = contactInvitationRecord(record.id),
              current.state == record.state, current.receiptID == record.receiptID,
              current.credentialReference == record.credentialReference else { return false }
        return contactInternetReplyIsEligible(
            current, access: window.access, now: callAccessNow().timeIntervalSince1970)
    }
}
