import Foundation

extension IntercomViewModel {
    private enum OutgoingGroupDeliveryStep {
        case next
        case stopSending
        case stopSync
    }

    func performGroupDeliverySync() async {
        guard canEditSavedGroups, let client = groupDeliveryClient,
              let access = try? internetSettingsStore.notificationAccess(memberID: localMemberIdentity.memberID)
        else { return }
        let generation = accountAccessID
        if let transfer = invitationBackgroundTransfer {
            await transfer.restore()
            guard groupDeliveryIsCurrent(access, accountID: generation) else { return }
            scheduleBackgroundGroupInvitations()
        }
        let uploadBinding = invitationBackgroundTransfer.flatMap { _ in
            InternetAccountClient.backgroundSubmissionSessionBinding(for: access.accessToken)
        }
        await synchronizeContactDeletionRelay(client: client, access: access, generation: generation)
        guard canEditSavedGroups, notifications.canUseNotifications,
              groupDeliveryIsCurrent(access, accountID: generation) else { return }
        do {
            try groupRepository.removeFinishedGroupDeliveries(now: callAccessNow().timeIntervalSince1970)
        } catch {
            reportGroupStorageError(error)
            return
        }
        guard await sendOutgoingGroupDeliveries(
            client: client, access: access, generation: generation, uploadBinding: uploadBinding
        ) else { return }
        await receiveGroupDeliveries(client: client, access: access, generation: generation)
        await queueDeliveriesForAdditionalDevices(client: client, access: access, generation: generation)
        finishNearbyGroupDeliveryIfComplete()
    }

    private func sendOutgoingGroupDeliveries(
        client: InternetAccountClient,
        access: CallNotificationServiceAccess,
        generation: UUID,
        uploadBinding: String?
    ) async -> Bool {
        // One finite pass. Offline work stays in the manifest for the next sync trigger.
        let outgoing = groupRepository.groupDeliveries
        // The inbox accepts cancellations even when the Worker rejects new submissions.
        let outgoingIDs = (outgoing.filter { $0.internetAction == .cancel }
            + outgoing.filter { $0.internetAction == .send }
            + outgoing.filter { $0.internetAction == .checkOutcome }).map(\.id)
        sending: for id in outgoingIDs {
            guard groupDeliveryIsCurrent(access, accountID: generation), canEditSavedGroups else { return false }
            // A member may have been removed while awaiting another delivery.
            guard let record = groupRepository.groupDeliveries.first(where: { $0.id == id }) else { continue }
            let step = await attemptOutgoingGroupDelivery(
                record, client: client, access: access, generation: generation, uploadBinding: uploadBinding
            )
            switch step {
            case .next: continue
            case .stopSending: break sending
            case .stopSync: return false
            }
        }
        return true
    }

    private func attemptOutgoingGroupDelivery(
        _ record: GroupDeliveryRecord,
        client: InternetAccountClient,
        access: CallNotificationServiceAccess,
        generation: UUID,
        uploadBinding: String?
    ) async -> OutgoingGroupDeliveryStep {
        guard let action = record.internetAction, record.recipient.issuer == access.principal.issuer
        else { return .next }
        let now = callAccessNow().timeIntervalSince1970
        if action == .checkOutcome {
            guard now < record.outcomeDeadline else { return .next }
            return await checkExpiredGroupDeliveryOutcome(
                record, client: client, access: access, generation: generation
            )
        }
        guard now < record.expiresAt else { return .next }
        let operation: InvitationBackgroundUploadID.Operation = action == .cancel ? .cancel : .send
        if let uploadBinding, invitationBackgroundTransfer?.contains(.init(
            deliveryID: record.id, sessionBinding: uploadBinding, operation: operation
        )) == true { return .next }
        if action == .cancel {
            return await cancelOutgoingGroupInvitation(record, client: client, access: access, generation: generation)
        }
        return await sendOutgoingGroupInvitation(record, client: client, access: access, generation: generation)
    }

    private func checkExpiredGroupDeliveryOutcome(
        _ record: GroupDeliveryRecord,
        client: InternetAccountClient,
        access: CallNotificationServiceAccess,
        generation: UUID
    ) async -> OutgoingGroupDeliveryStep {
        let outcome: GroupDeliveryRecord.State?
        do {
            outcome = try await client.expiredGroupInvitationOutcome(for: record, access: access)
        } catch InternetAccountClient.Failure.forbidden {
            return .next
        } catch {
            return .stopSending
        }
        guard groupDeliveryIsCurrent(access, accountID: generation), canEditSavedGroups else { return .stopSync }
        do {
            try groupRepository.confirmExpiredGroupDeliveryOutcome(
                record.id, state: outcome, now: callAccessNow().timeIntervalSince1970
            )
            refreshGroupStorageStatus()
        } catch {
            reportGroupStorageError(error)
            return .stopSync
        }
        return .next
    }

    private func cancelOutgoingGroupInvitation(
        _ record: GroupDeliveryRecord,
        client: InternetAccountClient,
        access: CallNotificationServiceAccess,
        generation: UUID
    ) async -> OutgoingGroupDeliveryStep {
        do {
            try await client.finishGroupInvitation(recipient: record.recipient, id: record.id, access: access)
        } catch {
            return .next
        }
        guard groupDeliveryIsCurrent(access, accountID: generation) else { return .stopSync }
        do {
            try confirmInternetGroupInvitationCancellation(record.id)
        } catch {
            reportGroupStorageError(error)
            return .stopSync
        }
        return .next
    }

    private func sendOutgoingGroupInvitation(
        _ record: GroupDeliveryRecord,
        client: InternetAccountClient,
        access: CallNotificationServiceAccess,
        generation: UUID
    ) async -> OutgoingGroupDeliveryStep {
        guard let grant = groupDeliveryGrant(for: record) else { return .next }
        let envelope: GroupInvitationEnvelope
        do {
            guard let prepared = try prepareGroupDeliveryEnvelope(record, sender: access.principal)
            else { return .next }
            envelope = prepared
        } catch {
            reportGroupStorageError(error)
            return .stopSync
        }
        let reply: GroupDeliveryReply
        do {
            reply = try await client.sendGroupInvitation(
                envelope, noticeID: record.noticeID, capability: grant.capability, access: access
            )
        } catch InternetAccountClient.Failure.forbidden {
            // This recipient's grant cannot block unrelated people.
            return .next
        } catch {
            // Shared auth, rate limit or network failure waits for the next sync trigger.
            return .stopSending
        }
        guard groupDeliveryIsCurrent(access, accountID: generation),
              let current = groupRepository.groupDeliveries.first(where: { $0.id == record.id })
        else { return .stopSync }
        if current.internetAction == .cancel { groupDeliveryNeedsSync = true }
        guard current.internetAction == .send else { return .next }
        do {
            if current.state != reply.status {
                try groupRepository.setGroupDeliveryState(record.id, state: reply.status)
            }
        } catch {
            reportGroupStorageError(error)
            return .stopSync
        }
        return .next
    }

    private func groupDeliveryGrant(for record: GroupDeliveryRecord) -> CallNotificationGrant? {
        guard let user = savedRemoteUsers.first(where: { $0.principal == record.recipient }) else { return nil }
        return notifications.groupInvitationGrant(for: user.id)
    }

    private func backgroundGroupInvitationOperation(
        for record: GroupDeliveryRecord, access: CallNotificationServiceAccess, now: TimeInterval
    ) -> InvitationBackgroundUploadID.Operation? {
        guard record.recipient.issuer == access.principal.issuer, record.expiresAt > now else { return nil }
        if record.internetAction == .cancel { return .cancel }
        guard record.state == .pending, record.internetAction == .send, groupDeliveryGrant(for: record) != nil
        else { return nil }
        return .send
    }

    func backgroundGroupInvitationUploadIDs() -> Set<InvitationBackgroundUploadID> {
        guard canEditSavedGroups, notifications.canUseNotifications,
              let access = try? internetSettingsStore.notificationAccess(memberID: localMemberIdentity.memberID),
              let binding = InternetAccountClient.backgroundSubmissionSessionBinding(for: access.accessToken)
        else { return [] }
        let now = callAccessNow().timeIntervalSince1970
        return Set(groupRepository.groupDeliveries.compactMap { record in
            guard let operation = backgroundGroupInvitationOperation(for: record, access: access, now: now)
            else { return nil }
            return .init(deliveryID: record.id, sessionBinding: binding, operation: operation)
        })
    }

    func scheduleBackgroundGroupInvitations() {
        guard let transfer = invitationBackgroundTransfer, transfer.hasRestored else { return }
        let keys = backgroundGroupInvitationUploadIDs()
        transfer.reconcile(keeping: backgroundInvitationUploadIDs())
        // The send budget must not delay withdrawals.
        let sends = keys.filter { $0.operation == .send }
        var sendCapacity = 60 - sends.count(where: { transfer.contains($0) })
        let cancellations = keys.filter { $0.operation == .cancel }
        for key in Array(cancellations) + Array(sends) where !transfer.contains(key) {
            if key.operation == .send && sendCapacity <= 0 { break }
            if let request = try? backgroundGroupInvitationRequest(for: key.deliveryID) {
                // The usual HTTP pass still runs if the system cannot take this upload.
                try? transfer.enqueue(request, for: key)
                if key.operation == .send && transfer.contains(key) { sendCapacity -= 1 }
            }
        }
    }

    func applyBackgroundGroupInvitationReply(_ reply: GroupDeliveryReply, for key: InvitationBackgroundUploadID) {
        guard canEditSavedGroups, notifications.canUseNotifications,
              let access = try? internetSettingsStore.notificationAccess(memberID: localMemberIdentity.memberID),
              InternetAccountClient.backgroundSubmissionSessionBinding(for: access.accessToken) == key.sessionBinding,
              let record = groupRepository.groupDeliveries.first(where: { $0.id == key.deliveryID }),
              backgroundGroupInvitationOperation(
                  for: record, access: access, now: callAccessNow().timeIntervalSince1970
              ) == key.operation,
              reply.matches(id: record.id, expiresAt: record.expiresAt) else { return }
        do {
            switch key.operation {
            case .send:
                guard [.queued, .received, .cancelled].contains(reply.status) else { return }
                try groupRepository.setGroupDeliveryState(record.id, state: reply.status)
                refreshGroupStorageStatus()
            case .cancel:
                guard reply.status == .cancelled || reply.status == .received else { return }
                try confirmInternetGroupInvitationCancellation(record.id)
            case .contactAcceptance: return
            }
            finishNearbyGroupDeliveryIfComplete()
        } catch { reportGroupStorageError(error) }
    }

    private func confirmInternetGroupInvitationCancellation(_ id: UUID) throws {
        try groupRepository.removeFinishedGroupDeliveries(
            now: callAccessNow().timeIntervalSince1970, internetCancelledID: id
        )
        refreshGroupStorageStatus()
    }

    func backgroundGroupInvitationRequest(for id: UUID) throws -> URLRequest? {
        guard canEditSavedGroups, notifications.canUseNotifications,
              let access = try internetSettingsStore.notificationAccess(memberID: localMemberIdentity.memberID),
              let record = groupRepository.groupDeliveries.first(where: { $0.id == id }),
              let operation = backgroundGroupInvitationOperation(
                  for: record, access: access, now: callAccessNow().timeIntervalSince1970
              )
        else { return nil }
        let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID)
        guard signer.identity?.sessionBinding != nil else { return nil }
        switch operation {
        case .send:
            guard let grant = groupDeliveryGrant(for: record),
                  let envelope = try prepareGroupDeliveryEnvelope(record, sender: access.principal) else { return nil }
            return try InternetAccountClient.backgroundGroupInvitationRequest(
                envelope, noticeID: record.noticeID, capability: grant.capability, access: access, signer: signer
            )
        case .cancel:
            return try InternetAccountClient.backgroundGroupInvitationCancellationRequest(
                record, access: access, signer: signer
            )
        case .contactAcceptance: return nil
        }
    }

    private func queueDeliveriesForAdditionalDevices(
        client: InternetAccountClient, access: CallNotificationServiceAccess, generation: UUID
    ) async {
        let sources = groupRepository.additionalDeviceDeliverySources(now: callAccessNow().timeIntervalSince1970)
        for source in sources {
            guard groupDeliveryIsCurrent(access, accountID: generation), canEditSavedGroups,
                  notifications.canUseNotifications else { return }
            let devices: [GroupInvitationAddress]
            do {
                devices = try await client.additionalDevices(for: source, access: access)
            } catch InternetAccountClient.Failure.forbidden {
                continue
            } catch {
                return
            }
            guard groupDeliveryIsCurrent(access, accountID: generation), canEditSavedGroups,
                  notifications.canUseNotifications else { return }
            do {
                if try groupRepository.queueAdditionalDeviceDeliveries(
                    sourceID: source.id, devices: devices, now: callAccessNow().timeIntervalSince1970
                ) {
                    groupDeliveryNeedsSync = true
                }
            } catch {
                reportGroupStorageError(error)
                return
            }
        }
    }
}
