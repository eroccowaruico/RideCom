import Foundation

extension IntercomViewModel {
    enum GroupDeliveryTrigger {
        case refresh
        case localChange
        case notification
        case networkRecovered
    }

    func groupDeliveryNetworkPathChanged(isAvailable: Bool) {
        let wasAvailable = groupDeliveryNetworkWasAvailable
        groupDeliveryNetworkWasAvailable = isAvailable
        guard wasAvailable == false, isAvailable else { return }
        requestDirectRestoreDeviceSync()
        guard groupDeliveryClient != nil, canEditSavedGroups else { return }
        requestInvitationInternetReply(restart: true)
        if hasPendingContactDeletionRelay {
            requestGroupDeliverySync(.networkRecovered)
            return
        }
        guard notifications.canUseNotifications else { return }
        let now = callAccessNow().timeIntervalSince1970
        if groupRepository.groupDeliveries.contains(where: { record in
            guard let current = record.retainingOutcome(at: now) else { return false }
            return current.internetAction != nil || (current.direction == .incoming && current.state == .pending)
        }) {
            requestGroupDeliverySync(.networkRecovered)
        }
    }

    func groupDeliveryRecords(for selected: Set<UUID>, groupID: UUID) -> [GroupDeliveryRecord] {
        let expiry = callAccessNow().addingTimeInterval(GroupDeliveryRecord.invitationLifetime).timeIntervalSince1970
        return savedRemoteUsers.filter { selected.contains($0.id) }.flatMap { user -> [GroupDeliveryRecord] in
            guard let recipient = user.principal, recipient.isValid else { return [] }
            let notice = UUID()
            return user.memberIDs.sorted().compactMap { member in
                guard let key = user.deviceKeys?[member], DeviceIdentityProof.isValidPublicKey(key) else { return nil }
                return .init(
                    noticeID: notice, groupID: groupID, recipient: recipient,
                    recipientMemberID: member, recipientKey: key, expiresAt: expiry
                )
            }
        }
    }

    func groupInvitationDeliveries(for people: Set<UUID>, in groupID: UUID) -> [GroupDeliveryRecord] {
        let accounts = Set(savedRemoteUsers.filter { people.contains($0.id) }.compactMap(\.principal))
        return groupInvitationDeliveries(in: groupID).filter { accounts.contains($0.recipient) }
    }
    func groupInvitationDeliveries(in groupID: UUID) -> [GroupDeliveryRecord] {
        _ = contactInvitationRevision
        let now = callAccessNow().timeIntervalSince1970
        return groupRepository.groupDeliveries.filter {
            $0.direction == .outgoing && $0.groupID == groupID && $0.visibleInvitation(at: now)
        }.sorted { $0.id.uuidString < $1.id.uuidString }
    }
    func groupInvitationDeliveryState(forMember memberID: String, in groupID: UUID) -> GroupDeliveryRecord.State? {
        guard let person = savedRemoteUsers.first(where: { $0.memberIDs.contains(memberID) }) else { return nil }
        return groupInvitationDeliveryState(for: person, in: groupID)
    }
    func groupInvitationDeliveryState(for person: SavedUser, in groupID: UUID) -> GroupDeliveryRecord.State? {
        guard let account = person.principal else { return nil }
        let records = groupInvitationDeliveries(in: groupID).filter { $0.recipient == account }
        if records.contains(where: { $0.state == .received }) { return .received }
        if records.contains(where: { $0.state == .pending || $0.state == .queued }) { return .pending }
        return records.isEmpty ? nil : .cancelled
    }

    func requestGroupDeliverySync(_ trigger: GroupDeliveryTrigger = .refresh) {
        if trigger == .localChange { refreshNearbyGroupDelivery(afterSave: true) }
        guard groupDeliveryClient != nil, hasCurrentAccountAccess else { return }
        if groupDeliveryTask == nil {
            groupDeliveryNeedsSync = true
            let run = UUID()
            groupDeliveryRunID = run
            groupDeliveryTask = Task {
                defer {
                    if groupDeliveryRunID == run {
                        groupDeliveryTask = nil
                        finishGroupDeliveryBackgroundTime()
                    }
                }
                while groupDeliveryNeedsSync && !Task.isCancelled && hasCurrentAccountAccess {
                    groupDeliveryNeedsSync = false
                    await performGroupDeliverySync()
                }
            }
        } else if trigger != .refresh {
            groupDeliveryNeedsSync = true
        }
        let outgoingInvitation = trigger == .localChange && groupRepository.groupDeliveries.contains {
            $0.internetAction != nil
        }
        let outgoingDeletion = trigger == .localChange && hasPendingContactDeletionRelay
        if outgoingDeletion || ((trigger == .notification || outgoingInvitation) && notifications.canUseNotifications) {
            requestGroupDeliveryBackgroundTime(run: groupDeliveryRunID)
        }
        if trigger == .localChange { scheduleBackgroundGroupInvitations() }
    }

    /// Request time before the save or notification callback yields, even if a pass is already running.
    private func requestGroupDeliveryBackgroundTime(run: UUID) {
        guard endGroupDeliveryBackgroundTime == nil, canEditSavedGroups
        else { return }
        let end = beginGroupDeliveryBackgroundTime { [weak self] in
            guard let self, self.groupDeliveryRunID == run else { return }
            self.stopInternetGroupDeliverySync()
        }
        guard groupDeliveryRunID == run else {
            end?()
            return
        }
        endGroupDeliveryBackgroundTime = end
    }

    private func finishGroupDeliveryBackgroundTime() {
        let end = endGroupDeliveryBackgroundTime
        endGroupDeliveryBackgroundTime = nil
        end?()
    }

    func synchronizeGroupDeliveries(_ trigger: GroupDeliveryTrigger = .refresh) async {
        requestGroupDeliverySync(trigger)
        await groupDeliveryTask?.value
    }
    func stopGroupDeliverySync() {
        invitationBackgroundTransfer?.reconcile(keeping: [])
        stopOrdinaryGroupReplyExchanges()
        stopInvitationInternetReply()
        stopNearbyGroupDelivery()
        stopInternetGroupDeliverySync()
    }
    private func stopInternetGroupDeliverySync() {
        groupDeliveryRunID = UUID()
        groupDeliveryTask?.cancel()
        groupDeliveryTask = nil
        groupDeliveryNeedsSync = false
        finishGroupDeliveryBackgroundTime()
    }
    func groupDeliveryIsCurrent(_ access: CallNotificationServiceAccess, accountID: UUID) -> Bool {
        hasCurrentAccountAccess && accountAccessID == accountID && !Task.isCancelled
            && (try? internetSettingsStore.notificationAccess(memberID: localMemberIdentity.memberID)) == access
    }

    func prepareGroupDeliveryEnvelope(
        _ record: GroupDeliveryRecord, sender: AccountPrincipal
    ) throws -> GroupInvitationEnvelope? {
        if record.credentialReference != nil { return try groupRepository.groupDeliveryEnvelope(record.id) }
        guard let group = groups.first(where: { $0.id == record.groupID }), let key = try credential(for: group)
        else { return nil }
        let now = callAccessNow()
        let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID)
        let token = try GroupInviteToken.make(
            authority: invitationAuthority, signer: signer,
            credential: key, groupName: group.name, inviterMemberID: signer.memberID,
            inviterDisplayName: localMemberIdentity.displayName,
            issuedAt: now.timeIntervalSince1970, expiresAt: record.expiresAt
        )
        let envelope = try GroupInvitationEnvelope.seal(
            token, sender: sender,
            recipient: .init(
                principal: record.recipient, memberID: record.recipientMemberID,
                encryptionKey: record.recipientKey), signer: signer, now: now, deliveryID: record.id,
            sourceRequestID: record.sourceRequestID)
        try groupRepository.saveGroupDeliveryEnvelope(envelope)
        return envelope
    }

    func receiveNearbyGroupInvitation(
        _ envelope: GroupInvitationEnvelope, from peerID: String
    ) throws -> GroupInvitationReceipt? {
        guard canEditSavedGroups, envelope.senderMemberID == peerID, envelope.sourceRequestID == nil,
              let localAccountPrincipal else { throw DeviceIdentityProof.Failure.invalid }
        let signer = try internetSettingsStore.invitationSigner(
            memberID: localMemberIdentity.memberID, expectedPublicKey: envelope.recipientKey
        )
        let user = savedRemoteUsers.first { $0.principal == envelope.sender }
        let now = callAccessNow()
        let token = try envelope.open(recipient: signer, local: localAccountPrincipal, sender: user, now: now)
        let saved = try groupRepository.receiveGroupDelivery(
            envelope, token: token, localDisplayName: localMemberIdentity.displayName,
            now: now.timeIntervalSince1970, fromNearby: true
        )
        publishReceivedGroup(saved)
        let digest = try envelope.receiptDigest()
        guard groupRepository.groupDeliveries.contains(where: {
            $0.id == envelope.id && $0.direction == .incoming && $0.state == .received
                && $0.acceptedEnvelopeDigest == digest
        }) else { return nil }
        return try GroupInvitationReceipt(for: envelope, signer: signer)
    }

    func receiveNearbyGroupInvitationCancellation(_ cancellation: GroupInvitationCancellation, from peerID: String)
        throws -> GroupInvitationCancellationReceipt {
        guard canEditSavedGroups, let localAccountPrincipal else { throw DeviceIdentityProof.Failure.invalid }
        let target = cancellation.target
        let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID,
                                                                 expectedPublicKey: target.recipientKey)
        let sender = savedRemoteUsers.first { $0.principal == target.sender }
        let now = callAccessNow()
        try cancellation.verify(from: peerID, local: localAccountPrincipal, signer: signer, sender: sender, now: now)
        let outcome = try groupRepository.rememberNearbyGroupCancellation(target, now: now.timeIntervalSince1970)
        refreshGroupStorageStatus()
        return try GroupInvitationCancellationReceipt(for: target, outcome: outcome, signer: signer)
    }

    func acknowledgeNearbyGroupInvitation(_ receipt: GroupInvitationReceipt, from peerID: String) throws {
        guard canEditSavedGroups, let record = groupRepository.groupDeliveries.first(where: { $0.id == receipt.id }),
              record.direction == .outgoing, record.sourceRequestID == nil, record.recipientMemberID == peerID
        else { throw DeviceIdentityProof.Failure.invalid }
        guard record.state == .pending || record.state == .queued,
              record.expiresAt > callAccessNow().timeIntervalSince1970 else { return }
        try receipt.verify(for: groupRepository.groupDeliveryEnvelope(record.id))
        try groupRepository.setGroupDeliveryState(record.id, state: .received)
        refreshGroupStorageStatus()
    }

    private func nearbyCancellationTarget(for record: GroupDeliveryRecord, sender: AccountPrincipal) throws
        -> GroupInvitationCancellation.Target {
        guard record.nearbyWork == .cancellation(record.id), let handoff = record.nearbyHandoff
        else { throw DeviceIdentityProof.Failure.invalid }
        return .init(
            id: record.id, groupID: record.groupID, sender: sender, senderMemberID: localMemberIdentity.memberID,
            recipient: record.recipient, recipientMemberID: record.recipientMemberID, recipientKey: record.recipientKey,
            expiresAt: record.expiresAt, envelopeDigest: handoff.envelopeDigest
        )
    }

    func makeNearbyGroupCancellation(
        for record: GroupDeliveryRecord, sender: AccountPrincipal
    ) throws -> GroupInvitationCancellation {
        let target = try nearbyCancellationTarget(for: record, sender: sender)
        let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID)
        return try GroupInvitationCancellation(target: target, signer: signer)
    }

    func acknowledgeNearbyGroupCancellation(_ receipt: GroupInvitationCancellationReceipt, from peerID: String) throws {
        let now = callAccessNow().timeIntervalSince1970
        guard canEditSavedGroups, let localAccountPrincipal,
              let record = groupRepository.groupDeliveries.first(where: { $0.id == receipt.target.id }),
              record.recipientMemberID == peerID, record.nearbyWork == .cancellation(record.id),
              record.expiresAt > now else { return }
        let target = try nearbyCancellationTarget(for: record, sender: localAccountPrincipal)
        try receipt.verify(for: target)
        try groupRepository.confirmNearbyGroupCancellation(record.id, outcome: receipt.outcome, now: now)
        refreshGroupStorageStatus()
    }

    func publishReceivedGroup(_ group: IntercomGroup?) {
        if let group {
            if groups.contains(where: { $0.id == group.id }) {
                refreshStoredAccountCall(group.id)
            } else {
                groups.insert(group, at: 0)
            }
        }
        refreshGroupStorageStatus()
    }
}
