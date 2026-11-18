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

    func requestGroupDeliverySync(afterMutation: Bool = false) {
        guard groupDeliveryClient != nil, hasCurrentAccountAccess else { return }
        if groupDeliveryTask != nil { if afterMutation { groupDeliveryNeedsSync = true }; return }
        groupDeliveryNeedsSync = true
        let run = UUID(); groupDeliveryRunID = run
        groupDeliveryTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.groupDeliveryRunID == run { self.groupDeliveryTask = nil } }
            while self.groupDeliveryNeedsSync && !Task.isCancelled && self.hasCurrentAccountAccess {
                self.groupDeliveryNeedsSync = false
                await self.performGroupDeliverySync()
            }
        }
    }
    func synchronizeGroupDeliveries() async {
        requestGroupDeliverySync()
        await groupDeliveryTask?.value
    }
    func stopGroupDeliverySync() {
        groupDeliveryRunID = UUID(); groupDeliveryTask?.cancel(); groupDeliveryTask = nil; groupDeliveryNeedsSync = false
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
        for record in groupRepository.groupDeliveries where record.direction == .outgoing && record.state != .received {
            guard groupDeliveryIsCurrent(access, accountID: generation), canEditSavedGroups else { return }
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
        // Match the Worker mailbox capacity; stop at empty or failure without polling.
        for _ in 0..<64 {
            guard groupDeliveryIsCurrent(access, accountID: generation), canEditSavedGroups else { return }
            let item: GroupDeliveryItem
            do {
                guard let value = try await client.nextGroupInvitation(recipientKey: signer.publicKey, access: access) else { break }
                item = value
            } catch { break }
            guard groupDeliveryIsCurrent(access, accountID: generation), canEditSavedGroups, notifications.canUseNotifications else { return }
            let envelope: GroupInvitationEnvelope, token: GroupInviteToken
            do {
                guard let bytes = Data(base64Encoded: item.envelope), bytes.count <= 16384 else { throw InternetAccountClient.Failure.invalidResponse }
                envelope = try JSONDecoder().decode(GroupInvitationEnvelope.self, from: bytes)
                guard envelope.id == item.requestID, envelope.sender.userID == item.senderUserID,
                      abs(envelope.expiresAt * 1000 - item.expiresAt) < 1,
                      let user = savedRemoteUsers.first(where: { $0.principal == envelope.sender }) else { throw DeviceIdentityProof.Failure.invalid }
                token = try envelope.open(recipient: signer, local: access.principal, sender: user, now: callAccessNow())
            } catch {
                do { try await client.finishGroupInvitation(recipient: access.principal, id: item.requestID, discard: true, access: access) }
                catch { break } // Do not repeatedly fetch the same invalid packet after a failed discard.
                continue
            }
            do {
                try groupRepository.receiveGroupDelivery(envelope, token: token, localDisplayName: localMemberIdentity.displayName, now: callAccessNow().timeIntervalSince1970)
                if groups.contains(where: { $0.id == token.groupID }) { refreshStoredAccountCall(token.groupID) }
                else if let saved = groupRepository.storedGroup(token.groupID) { groups.insert(saved, at: 0) }
                refreshGroupStorageStatus()
            } catch { reportGroupStorageError(error); return }
            do { try await client.finishGroupInvitation(recipient: access.principal, id: item.requestID, access: access) }
            catch { break } // A repeated packet finds the persisted receipt without recreating the group.
        }
        refreshGroupStorageStatus()
    }
}
