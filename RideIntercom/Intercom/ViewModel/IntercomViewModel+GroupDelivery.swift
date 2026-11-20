import Foundation
import RTC

extension IntercomViewModel {
    enum GroupDeliveryTrigger {
        case refresh
        case localChange
        case notification
    }

    func groupDeliveryRecords(for selected: Set<UUID>, groupID: UUID) -> [GroupDeliveryRecord] {
        let expiry = callAccessNow().addingTimeInterval(7 * 86400).timeIntervalSince1970
        return savedRemoteUsers.filter { selected.contains($0.id) }.flatMap { user -> [GroupDeliveryRecord] in
            guard let recipient = user.principal, recipient.isValid else { return [] }
            let notice = UUID()
            return user.memberIDs.sorted().compactMap { member in
                guard let key = user.deviceKeys?[member], DeviceIdentityProof.isValidPublicKey(key) else { return nil }
                return .init(noticeID: notice, groupID: groupID, recipient: recipient, recipientMemberID: member, recipientKey: key, expiresAt: expiry)
            }
        }
    }

    func groupInvitationDeliveries(for people: Set<UUID>, in groupID: UUID) -> [GroupDeliveryRecord] {
        let accounts = Set(savedRemoteUsers.filter { people.contains($0.id) }.compactMap(\.principal))
        return groupInvitationDeliveries(in: groupID).filter { accounts.contains($0.recipient) }
    }
    func groupInvitationDeliveries(in groupID: UUID) -> [GroupDeliveryRecord] {
        _ = contactInvitationRevision
        return groupRepository.groupDeliveries.filter { $0.direction == .outgoing && $0.groupID == groupID }
            .sorted { $0.id.uuidString < $1.id.uuidString }
    }
    func groupInvitationDeliveryState(forMember memberID: String, in groupID: UUID) -> GroupDeliveryRecord.State? {
        guard let person = savedRemoteUsers.first(where: { $0.memberIDs.contains(memberID) }) else { return nil }
        return groupInvitationDeliveryState(for: person, in: groupID)
    }
    func groupInvitationDeliveryState(for person: SavedUser, in groupID: UUID) -> GroupDeliveryRecord.State? {
        _ = contactInvitationRevision
        guard let account = person.principal else { return nil }
        let records = groupRepository.groupDeliveries.filter { $0.direction == .outgoing && $0.groupID == groupID && $0.recipient == account }
        if records.contains(where: { $0.state == .received }) { return .received }
        if records.contains(where: { $0.state == .pending || $0.state == .queued }) { return .pending }
        return records.isEmpty ? nil : .cancelled
    }

    func requestGroupDeliverySync(_ trigger: GroupDeliveryTrigger = .refresh) {
        guard groupDeliveryClient != nil, hasCurrentAccountAccess else { return }
        if groupDeliveryTask == nil {
            groupDeliveryNeedsSync = true
            let run = UUID(); groupDeliveryRunID = run
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
        if trigger == .notification || (trigger == .localChange && groupRepository.groupDeliveries.contains {
            $0.direction == .outgoing && $0.state != .received
        }) {
            requestGroupDeliveryBackgroundTime(run: groupDeliveryRunID)
        }
    }

    /// Request time before the save or notification callback yields, even if a pass is already running.
    private func requestGroupDeliveryBackgroundTime(run: UUID) {
        guard endGroupDeliveryBackgroundTime == nil, canEditSavedGroups, notifications.canUseNotifications
        else { return }
        let end = beginGroupDeliveryBackgroundTime { [weak self] in
            guard let self, self.groupDeliveryRunID == run else { return }
            self.stopGroupDeliverySync()
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
        groupDeliveryRunID = UUID(); groupDeliveryTask?.cancel(); groupDeliveryTask = nil; groupDeliveryNeedsSync = false
        finishGroupDeliveryBackgroundTime()
    }
    private func groupDeliveryIsCurrent(_ access: CallNotificationServiceAccess, accountID: UUID) -> Bool {
        hasCurrentAccountAccess && accountAccessID == accountID && !Task.isCancelled
            && (try? internetSettingsStore.notificationAccess(memberID: localMemberIdentity.memberID)) == access
    }
    private func performGroupDeliverySync() async {
        guard canEditSavedGroups, notifications.canUseNotifications, let client = groupDeliveryClient,
              let access = try? internetSettingsStore.notificationAccess(memberID: localMemberIdentity.memberID) else { return }
        let generation = accountAccessID
        do { try groupRepository.removeFinishedGroupDeliveries(now: callAccessNow().timeIntervalSince1970) }
        catch { reportGroupStorageError(error); return }
        // One finite pass. Offline work remains in the manifest until the next explicit lifecycle event.
        let outgoing = groupRepository.groupDeliveries.filter { $0.direction == .outgoing && $0.state != .received }
        // The inbox accepts cancellations even when the Worker rejects new submissions.
        let outgoingIDs = (outgoing.filter { $0.state == .cancelled } + outgoing.filter { $0.state != .cancelled }).map(\.id)
        for id in outgoingIDs {
            guard groupDeliveryIsCurrent(access, accountID: generation), canEditSavedGroups else { return }
            // A member may have been removed while awaiting another delivery.
            guard let record = groupRepository.groupDeliveries.first(where: { $0.id == id }),
                  record.state != .received else { continue }
            if record.recipient.issuer != access.principal.issuer { continue }
            if record.state == .cancelled {
                do { try await client.finishGroupInvitation(recipient: record.recipient, id: record.id, access: access) }
                catch { continue }
                guard groupDeliveryIsCurrent(access, accountID: generation) else { return }
                do { try groupRepository.removeFinishedGroupDeliveries(now: callAccessNow().timeIntervalSince1970, cancelledID: record.id) }
                catch { reportGroupStorageError(error); return }
                continue
            }
            guard let user = savedRemoteUsers.first(where: { $0.principal == record.recipient }),
                  let grant = notifications.groupInvitationGrant(for: user.id) else { continue }
            let envelope: GroupInvitationEnvelope
            do {
                guard let prepared = try prepareGroupDeliveryEnvelope(record, sender: access.principal) else { continue }
                envelope = prepared
            } catch { reportGroupStorageError(error); return }
            let reply: GroupDeliveryReply
            do { reply = try await client.sendGroupInvitation(envelope, noticeID: record.noticeID, capability: grant.capability, access: access) }
            catch InternetAccountClient.Failure.forbidden { continue } // This recipient's grant cannot block unrelated people.
            catch { break } // Shared auth, rate limit or network failure waits for the next lifecycle event.
            guard groupDeliveryIsCurrent(access, accountID: generation),
                  let current = groupRepository.groupDeliveries.first(where: { $0.id == record.id }) else { return }
            if current.state == .cancelled { groupDeliveryNeedsSync = true; continue }
            if current.state == .received { continue }
            do { if current.state != reply.status { try groupRepository.setGroupDeliveryState(record.id, state: reply.status) } }
            catch { reportGroupStorageError(error); return }
        }
        await receiveGroupDeliveries(client: client, access: access, generation: generation)
        await queueDeliveriesForAdditionalDevices(client: client, access: access, generation: generation)
    }

    func prepareGroupDeliveryEnvelope(_ record: GroupDeliveryRecord, sender: AccountPrincipal) throws -> GroupInvitationEnvelope? {
        if record.credentialReference != nil { return try groupRepository.groupDeliveryEnvelope(record.id) }
        guard let group = groups.first(where: { $0.id == record.groupID }), let key = try credential(for: group) else { return nil }
        let now = callAccessNow()
        let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID)
        let token = try GroupInviteToken.make(authority: invitationAuthority, signer: signer, groupID: group.id, groupName: group.name,
            groupSecret: key.secret, inviterMemberID: signer.memberID, inviterDisplayName: localMemberIdentity.displayName,
            issuedAt: now.timeIntervalSince1970, expiresAt: record.expiresAt)
        let envelope = try GroupInvitationEnvelope.seal(token, sender: sender, recipient: record.recipient, recipientMemberID: record.recipientMemberID,
            recipientKey: record.recipientKey, signer: signer, now: now, deliveryID: record.id, sourceRequestID: record.sourceRequestID)
        try groupRepository.saveGroupDeliveryEnvelope(envelope)
        return envelope
    }

    func nearbyGroupDeliveryCredential(for peerMemberID: String) throws -> RTCCredential {
        guard canEditSavedGroups, let localAccountPrincipal,
              let peer = savedRemoteUsers.first(where: { $0.memberIDs.contains(peerMemberID) }),
              let account = peer.principal, account != localAccountPrincipal, account.issuer == localAccountPrincipal.issuer,
              let publicKey = peer.deviceKeys?[peerMemberID] else { throw DeviceIdentityProof.Failure.invalid }
        let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID)
        let secret = try signer.nearbyGroupDeliverySecret(peerMemberID: peerMemberID, peerPublicKey: publicKey)
        return RTCCredential.derived(groupID: DeviceIdentitySigner.nearbyGroupDeliveryDomain, secret: IdentityEncoding.encode(secret))
    }

    func receiveNearbyGroupInvitation(_ envelope: GroupInvitationEnvelope, from peerID: String) throws -> GroupInvitationReceipt? {
        guard canEditSavedGroups, envelope.senderMemberID == peerID, envelope.sourceRequestID == nil,
              let localAccountPrincipal else { throw DeviceIdentityProof.Failure.invalid }
        let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID, expectedPublicKey: envelope.recipientKey)
        let user = savedRemoteUsers.first { $0.principal == envelope.sender }
        let now = callAccessNow()
        let token = try envelope.open(recipient: signer, local: localAccountPrincipal, sender: user, now: now)
        let saved = try groupRepository.receiveGroupDelivery(envelope, token: token, localDisplayName: localMemberIdentity.displayName,
            now: now.timeIntervalSince1970, fromNearby: true)
        publishReceivedGroup(saved)
        let digest = try envelope.receiptDigest()
        guard groupRepository.groupDeliveries.contains(where: {
            $0.id == envelope.id && $0.direction == .incoming && $0.state == .received && $0.acceptedEnvelopeDigest == digest
        }) else { return nil }
        return try GroupInvitationReceipt(for: envelope, signer: signer)
    }

    func acknowledgeNearbyGroupInvitation(_ receipt: GroupInvitationReceipt, from peerID: String) throws {
        guard canEditSavedGroups, let record = groupRepository.groupDeliveries.first(where: { $0.id == receipt.id }),
              record.direction == .outgoing, record.sourceRequestID == nil, record.recipientMemberID == peerID
        else { throw DeviceIdentityProof.Failure.invalid }
        guard record.state == .pending || record.state == .queued, record.expiresAt > callAccessNow().timeIntervalSince1970 else { return }
        try receipt.verify(for: groupRepository.groupDeliveryEnvelope(record.id))
        try groupRepository.setGroupDeliveryState(record.id, state: .received)
        refreshGroupStorageStatus()
    }

    private func publishReceivedGroup(_ group: IntercomGroup?) {
        if let group {
            if groups.contains(where: { $0.id == group.id }) { refreshStoredAccountCall(group.id) }
            else { groups.insert(group, at: 0) }
        }
        refreshGroupStorageStatus()
    }

    private func queueDeliveriesForAdditionalDevices(client: InternetAccountClient, access: CallNotificationServiceAccess,
                                                      generation: UUID) async {
        let sources = groupRepository.additionalDeviceDeliverySources(now: callAccessNow().timeIntervalSince1970)
        for source in sources {
            guard groupDeliveryIsCurrent(access, accountID: generation), canEditSavedGroups, notifications.canUseNotifications else { return }
            let devices: [GroupInvitationAddress]
            do { devices = try await client.additionalDevices(for: source, access: access) }
            catch InternetAccountClient.Failure.forbidden { continue }
            catch { return }
            guard groupDeliveryIsCurrent(access, accountID: generation), canEditSavedGroups, notifications.canUseNotifications else { return }
            do {
                if try groupRepository.queueAdditionalDeviceDeliveries(sourceID: source.id, devices: devices,
                                                                        now: callAccessNow().timeIntervalSince1970) {
                    groupDeliveryNeedsSync = true
                }
            } catch { reportGroupStorageError(error); return }
        }
    }

    private func receiveGroupDeliveries(client: InternetAccountClient, access: CallNotificationServiceAccess, generation: UUID) async {
        guard groupDeliveryIsCurrent(access, accountID: generation), canEditSavedGroups else { return }
        guard let signer = try? internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID) else { return }
        // Resume locally saved work before reading new mail. An acknowledged packet
        // can disappear from the mailbox even if its response never reached this device.
        for _ in 0..<64 {
            guard groupDeliveryIsCurrent(access, accountID: generation), canEditSavedGroups, notifications.canUseNotifications
            else { return }
            let pending = groupRepository.groupDeliveries.first {
                $0.direction == .incoming && $0.state == .pending && $0.recipient == access.principal
                    && $0.recipientMemberID == signer.memberID && $0.recipientKey == signer.publicKey
            }
            let item: GroupDeliveryItem?
            if pending == nil {
                do { item = try await client.nextGroupInvitation(recipientKey: signer.publicKey, access: access) }
                catch { break }
                guard groupDeliveryIsCurrent(access, accountID: generation), canEditSavedGroups, notifications.canUseNotifications
                else { return }
            } else {
                item = nil
            }
            guard let id = pending?.id ?? item?.requestID else {
                await requestInvitationsForAdditionalDevice(client: client, signer: signer, access: access, generation: generation)
                break
            }
            let restored: GroupInvitationEnvelope?
            do { restored = try pending.map { try groupRepository.groupDeliveryEnvelope($0.id) } }
            catch { reportGroupStorageError(error); return }
            let envelope: GroupInvitationEnvelope, token: GroupInviteToken, redeliveryTrust: DeviceIdentityTrust?
            do {
                if let restored {
                    envelope = restored
                } else {
                    guard let item, let bytes = Data(base64Encoded: item.envelope), bytes.count <= 16384
                    else { throw InternetAccountClient.Failure.invalidResponse }
                    envelope = try JSONDecoder().decode(GroupInvitationEnvelope.self, from: bytes)
                }
                let sourceRequestID = pending?.sourceRequestID ?? item?.sourceRequestID
                guard envelope.id == id, envelope.sourceRequestID == sourceRequestID, item.map({
                    envelope.sender.userID == $0.senderUserID && abs(envelope.expiresAt * 1000 - $0.expiresAt) < 1
                }) ?? true
                else { throw DeviceIdentityProof.Failure.invalid }
                redeliveryTrust = try sourceRequestID.flatMap { _ in try internetSettingsStore.identityTrust() }
                let user = savedRemoteUsers.first { $0.principal == envelope.sender }
                token = try envelope.open(recipient: signer, local: access.principal, sender: user, now: callAccessNow(),
                                          redeliveryTrust: redeliveryTrust)
            } catch {
                do { try groupRepository.cancelPendingGroupReceipt(id) }
                catch { reportGroupStorageError(error); return }
                do { try await client.finishGroupInvitation(recipient: access.principal, id: id, discard: true, access: access) }
                catch { break } // Do not repeatedly fetch the same invalid packet after a failed discard.
                continue
            }
            let state: GroupDeliveryRecord.State
            do {
                state = try groupRepository.stageGroupDelivery(envelope, token: token,
                    now: callAccessNow().timeIntervalSince1970, redeliveryTrust: redeliveryTrust)
            }
            catch { reportGroupStorageError(error); return }
            let outcome: GroupDeliveryRecord.State?
            do {
                if state != .pending {
                    try await client.finishGroupInvitation(recipient: access.principal, id: id, discard: state == .cancelled, access: access)
                    continue
                }
                outcome = try await client.acknowledgeGroupInvitation(id, access: access)
            } catch { break } // The ciphertext stays committed for the next lifecycle event.
            guard groupDeliveryIsCurrent(access, accountID: generation), canEditSavedGroups, notifications.canUseNotifications
            else { return }
            do {
                let now = callAccessNow().timeIntervalSince1970
                if outcome != .received || envelope.expiresAt <= now {
                    try groupRepository.cancelPendingGroupReceipt(id)
                    refreshGroupStorageStatus()
                } else {
                    publishReceivedGroup(try groupRepository.receiveGroupDelivery(envelope, token: token,
                        localDisplayName: localMemberIdentity.displayName, now: now, redeliveryTrust: redeliveryTrust))
                }
            } catch { reportGroupStorageError(error); return }
        }
        refreshGroupStorageStatus()
    }

    private func requestInvitationsForAdditionalDevice(client: InternetAccountClient, signer: DeviceIdentitySigner,
                                                       access: CallNotificationServiceAccess, generation: UUID) async {
        guard signer.principal == access.principal,
              let ids = try? await client.invitationsForAdditionalDevice(recipientKey: signer.publicKey, access: access)
        else { return }
        for id in ids {
            guard groupDeliveryIsCurrent(access, accountID: generation), canEditSavedGroups, notifications.canUseNotifications
            else { return }
            do { try await client.requestGroupInvitationForAdditionalDevice(id, signer: signer, access: access) }
            catch InternetAccountClient.Failure.forbidden { continue }
            catch { return }
        }
    }
}
