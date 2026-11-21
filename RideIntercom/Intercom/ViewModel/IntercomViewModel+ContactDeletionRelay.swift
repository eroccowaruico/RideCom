import Foundation

extension IntercomViewModel {
    private struct ContactDeletionRelaySession {
        let client: InternetAccountClient
        let access: CallNotificationServiceAccess
        let generation: UUID
        let signer: DeviceIdentitySigner
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

    func synchronizeContactDeletionRelay(
        client: InternetAccountClient, access: CallNotificationServiceAccess, generation: UUID
    ) async {
        guard let signer = try? internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID),
              signer.principal == access.principal else { return }
        let session = ContactDeletionRelaySession(
            client: client, access: access, generation: generation, signer: signer)
        await sendContactDeletions(session)
        for receipt in groupRepository.contactDeletionRelayReceipts {
            guard contactDeletionRelayIsCurrent(session) else { return }
            guard await submitContactDeletionReceipt(receipt, session: session) else { return }
        }
        await receiveRelayedContactDeletions(session)
    }

    private func contactDeletionRelayIsCurrent(_ session: ContactDeletionRelaySession) -> Bool {
        canEditSavedGroups && groupDeliveryIsCurrent(session.access, accountID: session.generation)
    }

    private func sendContactDeletions(_ session: ContactDeletionRelaySession) async {
        for id in groupRepository.contactDeletionPublications.map(\.id) {
            guard contactDeletionRelayIsCurrent(session) else { return }
            guard let record = groupRepository.contactDeletionPublications.first(where: { $0.id == id }),
                  record.sender == session.access.principal, record.senderKey == session.signer.publicKey,
                  Double(record.expiresAt) > callAccessNow().timeIntervalSince1970 * 1_000
            else { continue }
            if record.payload != nil {
                guard await publishContactDeletion(record, session: session) else { return }
            }
            guard contactDeletionRelayIsCurrent(session) else { return }
            // A nearby receipt can retire a record while the publish or receipt lookup is still outstanding.
            guard let retirement = groupRepository.contactDeletionPublications.first(where: {
                $0.id == id && $0.payload == nil
            }) else { continue }
            guard (try? await session.client.writeContactDeletion(retirement, access: session.access)) == .retired,
                  contactDeletionRelayIsCurrent(session) else { return }
            do {
                try groupRepository.finishContactDeletionRelay(retirement, now: callAccessNow())
            } catch {
                reportGroupStorageError(error)
                return
            }
        }
    }

    private func publishContactDeletion(
        _ record: ContactDeletionPublication, session: ContactDeletionRelaySession
    ) async -> Bool {
        guard let state = try? await session.client.writeContactDeletion(record, access: session.access),
              contactDeletionRelayIsCurrent(session) else { return false }
        if state == .received,
           let notice = groupRepository.contactDeletions.first(where: { $0.id == record.id }) {
            await acceptRelayedContactDeletionReceipt(notice, slot: record.slot, session: session)
        }
        return true
    }

    private func acceptRelayedContactDeletionReceipt(
        _ notice: ContactDeletionNotice, slot: String, session: ContactDeletionRelaySession
    ) async {
        let target = notice.target
        guard let message = try? await session.client.readContactDeletion(
                owner: session.access.principal, slot: slot, access: session.access),
              contactDeletionRelayIsCurrent(session), message.matches(target),
              let receipt = try? ContactDeletionRelayReceipt.open(
                message.packet, slot: slot, sender: session.signer,
                recipientID: target.recipientMemberID, recipientKey: target.recipientKey)
        else { return }
        do {
            try acknowledgeContactDeletion(receipt, from: target.recipientMemberID)
            finishNearbyGroupDeliveryIfComplete()
        } catch is DeviceIdentityProof.Failure {
            // A different signed receipt leaves the publication pending.
        } catch { reportGroupStorageError(error) }
    }

    private func receiveRelayedContactDeletions(_ session: ContactDeletionRelaySession) async {
        for former in groupRepository.contactDeletionFormerPairs {
            guard contactDeletionRelayIsCurrent(session) else { return }
            guard let address = former.relay, address.recipient == session.access.principal,
                  groupRepository.canUseFormerContactDeletionPair(former, signer: session.signer, now: callAccessNow())
            else { continue }
            guard await receiveRelayedContactDeletion(
                address, member: former.peerID, key: former.peerKey, session: session) else { return }
        }
        await receiveRelayedDeletionsFromSavedContacts(session)
    }

    private func receiveRelayedDeletionsFromSavedContacts(_ session: ContactDeletionRelaySession) async {
        for user in savedRemoteUsers {
            guard contactDeletionRelayIsCurrent(session) else { return }
            guard user.principal?.issuer == session.access.principal.issuer, user.principal != session.access.principal,
                  user.memberIDs.count == 1, let member = user.memberIDs.first, let key = user.deviceKeys?[member]
            else { continue }
            let pairID = IntercomGroup.directCallID(memberIDs: [session.signer.memberID, member])
            guard let group = groupRepository.storedGroup(pairID), group.kind == .direct, group.accountPair == nil
            else { continue }
            let secret: String?
            do {
                secret = try groupRepository.credential(for: pairID)?.secret
            } catch {
                reportGroupStorageError(error)
                return
            }
            guard let secret, let address = ContactDeletionRelayAddress(
                owner: user.principal, recipient: session.access.principal,
                pairSecret: secret, senderID: member, recipientID: session.signer.memberID) else { continue }
            guard await receiveRelayedContactDeletion(
                address, member: member, key: key, session: session) else { return }
        }
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
            _ = try receiveContactDeletion(notice, from: member)
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
