import Foundation

extension IntercomViewModel {
    private struct ContactDeletionRelaySession {
        let client: InternetAccountClient
        let access: CallNotificationServiceAccess
        let generation: UUID
        let signer: DeviceIdentitySigner
        let schedulesReceiptRetry: Bool
    }

    private struct ContactDeletionRelayPeer {
        let principal: AccountPrincipal
        let memberID: String
        let key: String
        let groupID: UUID
    }

    var hasPendingContactDeletionRelay: Bool {
        guard let localAccountPrincipal else { return false }
        let now = callAccessNow().timeIntervalSince1970 * 1_000
        return groupRepository.contactDeletionPublications.contains {
            $0.sender == localAccountPrincipal && Double($0.expiresAt) > now
        } || groupRepository.contactDeletionRelayReceipts.contains {
            $0.recipient == localAccountPrincipal && Double($0.expiresAt) > now
        }
    }

    var canReceiveRelayedContactDeletions: Bool {
        guard let principal = localAccountPrincipal else { return false }
        if savedRemoteUsers.contains(where: { contactDeletionRelayPeer($0, local: principal) != nil }) { return true }
        let formerPairs = groupRepository.contactDeletionFormerPairs
        guard !formerPairs.isEmpty,
              let signer = try? internetSettingsStore.contactDeletionSigner(memberID: localMemberIdentity.memberID)
        else { return false }
        return formerPairs.contains { formerContactDeletionRelayAddress($0, local: principal, signer: signer) != nil }
    }

    var needsContactDeletionBackgroundRefresh: Bool {
        contactDeletionBackgroundRefreshAccess != nil
    }

    private var contactDeletionBackgroundRefreshAccess: CallNotificationServiceAccess? {
        guard canEditSavedGroups, groupDeliveryClient != nil,
              hasPendingContactDeletionRelay || canReceiveRelayedContactDeletions else { return nil }
        return try? internetSettingsStore.notificationAccess(memberID: localMemberIdentity.memberID)
    }

    func refreshContactDeletionsInBackground() async -> Bool {
        guard !Task.isCancelled, let client = groupDeliveryClient,
              let access = contactDeletionBackgroundRefreshAccess
        else { return false }
        return await synchronizeContactDeletionRelay(
            client: client, access: access, generation: accountAccessID, schedulesReceiptRetry: false)
    }

    func backgroundContactDeletionUploadIDs(
        access: CallNotificationServiceAccess, binding: String
    ) -> Set<InvitationBackgroundUploadID> {
        let publications = groupRepository.contactDeletionPublications
        guard canEditSavedGroups, groupDeliveryClient != nil, !publications.isEmpty,
              let signer = try? internetSettingsStore.contactDeletionSigner(memberID: localMemberIdentity.memberID)
        else { return [] }
        let now = callAccessNow().timeIntervalSince1970 * 1_000
        return Set(publications.compactMap { record in
            guard record.sender == access.principal, record.senderKey == signer.publicKey,
                  Double(record.expiresAt) > now,
                  let payload = record.payload, payload.backgroundPublished != true else { return nil }
            return contactDeletionUploadID(record, binding: binding)
        })
    }

    private func contactDeletionUploadID(
        _ record: ContactDeletionPublication, binding: String
    ) -> InvitationBackgroundUploadID {
        .init(deliveryID: record.id, sessionBinding: binding, operation: .contactDeletion)
    }

    func scheduleBackgroundContactDeletions(
        _ keys: Set<InvitationBackgroundUploadID>, transfer: any InvitationBackgroundTransferring
    ) {
        let pending = keys.filter { $0.operation == .contactDeletion }
        let capacity = 60 - pending.count(where: { transfer.contains($0) })
        guard !pending.isEmpty, capacity > 0,
              let access = try? internetSettingsStore.notificationAccess(memberID: localMemberIdentity.memberID),
              let binding = InternetAccountClient.backgroundSubmissionSessionBinding(for: access.accessToken),
              let signer = try? internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID)
        else { return }
        let now = callAccessNow()
        for key in pending.lazy.filter({ !transfer.contains($0) }).prefix(capacity) {
            guard key.sessionBinding == binding,
                  let record = groupRepository.contactDeletionPublications.first(where: { $0.id == key.deliveryID }),
                  let request = try? InternetAccountClient.backgroundContactDeletionRequest(
                      record, access: access, signer: signer, now: now)
            else { continue }
            try? transfer.enqueue(request, for: key)
        }
    }

    func applyBackgroundContactDeletionReply(
        _ state: ContactDeletionWorkerState, for key: InvitationBackgroundUploadID
    ) {
        guard state == .pending || state == .received,
              let access = try? internetSettingsStore.notificationAccess(memberID: localMemberIdentity.memberID),
              let binding = InternetAccountClient.backgroundSubmissionSessionBinding(for: access.accessToken),
              backgroundContactDeletionUploadIDs(access: access, binding: binding).contains(key)
        else { return }
        do {
            try groupRepository.markContactDeletionBackgroundPublished(key.deliveryID, now: callAccessNow())
            if state == .received { requestGroupDeliverySync(.localChange) }
        } catch { reportGroupStorageError(error) }
    }

    func synchronizeContactDeletionRelay(
        client: InternetAccountClient, access: CallNotificationServiceAccess, generation: UUID,
        schedulesReceiptRetry: Bool = true
    ) async -> Bool {
        guard !groupDeliverySyncState.isSynchronizingContactDeletion,
              groupDeliveryIsCurrent(access, accountID: generation),
              let signer = try? internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID),
              signer.principal == access.principal else { return false }
        groupDeliverySyncState.isSynchronizingContactDeletion = true
        defer { groupDeliverySyncState.isSynchronizingContactDeletion = false }
        let session = ContactDeletionRelaySession(
            client: client, access: access, generation: generation, signer: signer,
            schedulesReceiptRetry: schedulesReceiptRetry)
        let sent = await sendContactDeletions(session)
        for receipt in groupRepository.contactDeletionRelayReceipts {
            guard contactDeletionRelayIsCurrent(session),
                  await submitContactDeletionReceipt(receipt, session: session) else { return false }
        }
        let received = await receiveRelayedContactDeletions(session)
        return sent && received && contactDeletionRelayIsCurrent(session)
    }

    private func contactDeletionRelayIsCurrent(_ session: ContactDeletionRelaySession) -> Bool {
        canEditSavedGroups && groupDeliveryIsCurrent(session.access, accountID: session.generation)
    }

    private func sendContactDeletions(_ session: ContactDeletionRelaySession) async -> Bool {
        var completed = true
        for id in groupRepository.contactDeletionPublications.map(\.id) {
            guard contactDeletionRelayIsCurrent(session) else { return false }
            guard let record = groupRepository.contactDeletionPublications.first(where: { $0.id == id }),
                  record.sender == session.access.principal, record.senderKey == session.signer.publicKey,
                  Double(record.expiresAt) > callAccessNow().timeIntervalSince1970 * 1_000
            else { continue }
            if record.payload != nil {
                let result = await synchronizeContactDeletionPublication(record, session: session)
                guard result.canContinue else { return false }
                completed = completed && result.completed
            }
            guard contactDeletionRelayIsCurrent(session) else { return false }
            // A nearby receipt can retire a record while the publish or receipt lookup is still outstanding.
            guard let retirement = groupRepository.contactDeletionPublications.first(where: {
                $0.id == id && $0.payload == nil
            }) else { continue }
            guard (try? await session.client.writeContactDeletion(retirement, access: session.access)) == .retired,
                  contactDeletionRelayIsCurrent(session) else { return false }
            do {
                try groupRepository.finishContactDeletionRelay(retirement, now: callAccessNow())
            } catch {
                reportGroupStorageError(error)
                return false
            }
        }
        return completed
    }

    private func hasBackgroundContactDeletionUpload(
        _ record: ContactDeletionPublication, access: CallNotificationServiceAccess
    ) -> Bool {
        guard let transfer = invitationBackgroundTransfer,
              let binding = InternetAccountClient.backgroundSubmissionSessionBinding(for: access.accessToken)
        else { return false }
        return transfer.contains(contactDeletionUploadID(record, binding: binding))
    }

    private func synchronizeContactDeletionPublication(
        _ record: ContactDeletionPublication, session: ContactDeletionRelaySession
    ) async -> (canContinue: Bool, completed: Bool) {
        if record.payload?.backgroundPublished == true {
            return (true, await acceptRelayedContactDeletionReceipt(record, session: session))
        }
        if hasBackgroundContactDeletionUpload(record, access: session.access) { return (true, true) }
        guard let state = try? await session.client.writeContactDeletion(record, access: session.access),
              contactDeletionRelayIsCurrent(session) else { return (false, false) }
        if state == .received { return (true, await acceptRelayedContactDeletionReceipt(record, session: session)) }
        return (true, true)
    }

    private func acceptRelayedContactDeletionReceipt(
        _ record: ContactDeletionPublication, session: ContactDeletionRelaySession
    ) async -> Bool {
        guard let notice = groupRepository.contactDeletions.first(where: { $0.id == record.id }) else { return true }
        let target = notice.target
        let message: ContactDeletionWorkerPacket?
        do {
            message = try await session.client.readContactDeletion(
                owner: session.access.principal, slot: record.slot, access: session.access)
        } catch { return false }
        guard contactDeletionRelayIsCurrent(session) else { return false }
        guard let message, message.matches(target),
              let receipt = try? ContactDeletionRelayReceipt.open(
                message.packet, slot: record.slot, sender: session.signer,
                recipientID: target.recipientMemberID, recipientKey: target.recipientKey)
        else { return true }
        do {
            try acknowledgeContactDeletion(receipt, from: target.recipientMemberID)
            finishNearbyGroupDeliveryIfComplete()
        } catch is DeviceIdentityProof.Failure {
            // A different signed receipt leaves the publication pending.
        } catch {
            reportGroupStorageError(error)
            return false
        }
        return true
    }

    private func receiveRelayedContactDeletions(_ session: ContactDeletionRelaySession) async -> Bool {
        for former in groupRepository.contactDeletionFormerPairs {
            guard contactDeletionRelayIsCurrent(session) else { return false }
            guard let address = formerContactDeletionRelayAddress(
                former, local: session.access.principal, signer: session.signer
            )
            else { continue }
            guard await receiveRelayedContactDeletion(
                address, member: former.peerID, key: former.peerKey, session: session) else { return false }
        }
        return await receiveRelayedDeletionsFromSavedContacts(session)
    }

    private func formerContactDeletionRelayAddress(
        _ former: ContactDeletionFormerPair, local: AccountPrincipal, signer: DeviceIdentitySigner
    ) -> ContactDeletionRelayAddress? {
        guard let address = former.relay, address.recipient == local,
              groupRepository.canUseFormerContactDeletionPair(former, signer: signer, now: callAccessNow())
        else { return nil }
        return address
    }

    private func contactDeletionRelayPeer(_ user: SavedUser, local: AccountPrincipal) -> ContactDeletionRelayPeer? {
        guard let peer = user.principal, peer.issuer == local.issuer, peer != local,
              user.memberIDs.count == 1, let member = user.memberIDs.first, let key = user.deviceKeys?[member]
        else { return nil }
        let groupID = IntercomGroup.directCallID(memberIDs: [localMemberIdentity.memberID, member])
        guard let group = groupRepository.storedGroup(groupID), group.kind == .direct, group.accountPair == nil
        else { return nil }
        return .init(principal: peer, memberID: member, key: key, groupID: groupID)
    }

    func refreshContactDeletionBeforeRestore(
        _ principal: AccountPrincipal, addressedTo signer: DeviceIdentitySigner
    ) async -> Bool {
        guard let local = signer.principal,
              let user = savedRemoteUsers.first(where: { $0.principal == principal }) else { return false }
        guard let peer = contactDeletionRelayPeer(user, local: local) else { return true }
        guard let client = groupDeliveryClient,
              let access = try? internetSettingsStore.notificationAccess(memberID: signer.memberID),
              access.principal == local else { return false }
        let session = ContactDeletionRelaySession(
            client: client, access: access, generation: accountAccessID, signer: signer, schedulesReceiptRetry: true)
        return await receiveRelayedDeletion(from: peer, session: session)
    }

    private func receiveRelayedDeletionsFromSavedContacts(_ session: ContactDeletionRelaySession) async -> Bool {
        for user in savedRemoteUsers {
            guard contactDeletionRelayIsCurrent(session) else { return false }
            guard let peer = contactDeletionRelayPeer(user, local: session.access.principal) else { continue }
            guard await receiveRelayedDeletion(from: peer, session: session) else { return false }
        }
        return true
    }

    private func receiveRelayedDeletion(from peer: ContactDeletionRelayPeer, session: ContactDeletionRelaySession)
        async -> Bool {
        guard contactDeletionRelayIsCurrent(session) else { return false }
        let secret: String?
        do {
            secret = try groupRepository.credential(for: peer.groupID)?.secret
        } catch {
            reportGroupStorageError(error)
            return false
        }
        guard let secret, let address = ContactDeletionRelayAddress(
            owner: peer.principal, recipient: session.access.principal,
            pairSecret: secret, senderID: peer.memberID, recipientID: session.signer.memberID) else { return true }
        return await receiveRelayedContactDeletion(
            address, member: peer.memberID, key: peer.key, session: session)
    }

    private func receiveRelayedContactDeletion(
        _ address: ContactDeletionRelayAddress, member: String, key: String, session: ContactDeletionRelaySession
    ) async -> Bool {
        let message: ContactDeletionWorkerPacket?
        do {
            message = try await session.client.readContactDeletion(
                owner: address.owner, slot: address.slot, access: session.access, recipient: session.signer)
        } catch { return false }
        guard contactDeletionRelayIsCurrent(session) else { return false }
        guard let message, let notice = try? ContactDeletionPublication.openNotice(
                message.packet, slot: address.slot, recipient: session.signer, senderID: member, senderKey: key),
              message.matches(notice.target) else { return true }
        do {
            _ = try receiveContactDeletion(notice, from: member, scheduleRelaySync: session.schedulesReceiptRetry)
        } catch is DeviceIdentityProof.Failure {
            return true
        } catch {
            reportGroupStorageError(error)
            return false
        }
        guard let receipt = groupRepository.contactDeletionRelayReceipts.first(where: { $0.id == notice.id })
        else { return true }
        return await submitContactDeletionReceipt(receipt, session: session)
    }

    private func submitContactDeletionReceipt(
        _ record: ContactDeletionRelayReceipt, session: ContactDeletionRelaySession
    ) async -> Bool {
        guard record.recipient == session.access.principal,
              Double(record.expiresAt) > callAccessNow().timeIntervalSince1970 * 1_000,
              groupRepository.contactDeletionReceipts.contains(where: {
                $0.id == record.id && $0.target.recipientKey == session.signer.publicKey
              })
        else { return true }
        guard let delivered = try? await session.client.acknowledgeRelayedContactDeletion(
                record, signer: session.signer, access: session.access),
              contactDeletionRelayIsCurrent(session) else { return false }
        if delivered {
            do {
                try groupRepository.finishContactDeletionRelay(record, now: callAccessNow())
            } catch {
                reportGroupStorageError(error)
                return false
            }
        }
        return true
    }
}
