import Foundation

extension IntercomViewModel {
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

    func requestGroupDeliverySync(forNewWork: Bool = false) {
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
        } else if forNewWork {
            groupDeliveryNeedsSync = true
        }
        if forNewWork { requestGroupDeliveryBackgroundTime(run: groupDeliveryRunID) }
    }

    /// Request time before the save action returns, including when a pass is already running.
    private func requestGroupDeliveryBackgroundTime(run: UUID) {
        guard endGroupDeliveryBackgroundTime == nil, canEditSavedGroups, notifications.canUseNotifications,
              groupRepository.groupDeliveries.contains(where: { $0.direction == .outgoing && $0.state != .received })
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

    func synchronizeGroupDeliveries(forNewWork: Bool = false) async {
        requestGroupDeliverySync(forNewWork: forNewWork)
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
                if record.credentialReference != nil { envelope = try groupRepository.groupDeliveryEnvelope(record.id) }
                else {
                    guard let group = groups.first(where: { $0.id == record.groupID }), let key = try credential(for: group) else { continue }
                    let signer = try internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID)
                    let token = try GroupInviteToken.make(authority: invitationAuthority, signer: signer, groupID: group.id, groupName: group.name,
                        groupSecret: key.secret, inviterMemberID: localMemberIdentity.memberID, inviterDisplayName: localMemberIdentity.displayName,
                        issuedAt: callAccessNow().timeIntervalSince1970, expiresAt: record.expiresAt)
                    envelope = try .seal(token, sender: access.principal, recipient: record.recipient, recipientMemberID: record.recipientMemberID,
                        recipientKey: record.recipientKey, signer: signer, now: callAccessNow(), deliveryID: record.id)
                    try groupRepository.saveGroupDeliveryEnvelope(envelope)
                }
            } catch { reportGroupStorageError(error); return }
            let reply: GroupDeliveryReply
            do { reply = try await client.sendGroupInvitation(envelope, noticeID: record.noticeID, capability: grant.capability, access: access) }
            catch InternetAccountClient.Failure.forbidden { continue } // This recipient's grant cannot block unrelated people.
            catch { break } // Shared auth, rate limit or network failure waits for the next lifecycle event.
            guard groupDeliveryIsCurrent(access, accountID: generation),
                  let current = groupRepository.groupDeliveries.first(where: { $0.id == record.id }) else { return }
            if current.state == .cancelled { groupDeliveryNeedsSync = true; continue }
            do { if current.state != reply.status { try groupRepository.setGroupDeliveryState(record.id, state: reply.status) } }
            catch { reportGroupStorageError(error); return }

        }
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
            guard let id = pending?.id ?? item?.requestID else { break }
            let restored: GroupInvitationEnvelope?
            do { restored = try pending.map { try groupRepository.groupDeliveryEnvelope($0.id) } }
            catch { reportGroupStorageError(error); return }
            let envelope: GroupInvitationEnvelope, token: GroupInviteToken
            do {
                if let restored {
                    envelope = restored
                } else {
                    guard let item, let bytes = Data(base64Encoded: item.envelope), bytes.count <= 16384
                    else { throw InternetAccountClient.Failure.invalidResponse }
                    envelope = try JSONDecoder().decode(GroupInvitationEnvelope.self, from: bytes)
                }
                guard envelope.id == id, item.map({
                    envelope.sender.userID == $0.senderUserID && abs(envelope.expiresAt * 1000 - $0.expiresAt) < 1
                }) ?? true, let user = savedRemoteUsers.first(where: { $0.principal == envelope.sender })
                else { throw DeviceIdentityProof.Failure.invalid }
                token = try envelope.open(recipient: signer, local: access.principal, sender: user, now: callAccessNow())
            } catch {
                do { try groupRepository.cancelPendingGroupReceipt(id) }
                catch { reportGroupStorageError(error); return }
                do { try await client.finishGroupInvitation(recipient: access.principal, id: id, discard: true, access: access) }
                catch { break } // Do not repeatedly fetch the same invalid packet after a failed discard.
                continue
            }
            let state: GroupDeliveryRecord.State
            do { state = try groupRepository.stageGroupDelivery(envelope, token: token, now: callAccessNow().timeIntervalSince1970) }
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
                } else if let saved = try groupRepository.receiveGroupDelivery(envelope, token: token, localDisplayName: localMemberIdentity.displayName, now: now) {
                    if groups.contains(where: { $0.id == saved.id }) { refreshStoredAccountCall(saved.id) }
                    else { groups.insert(saved, at: 0) }
                }
                refreshGroupStorageStatus()
            } catch { reportGroupStorageError(error); return }
        }
        refreshGroupStorageStatus()
    }
}
