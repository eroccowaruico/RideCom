import Foundation

extension IntercomViewModel {
    var hasPendingContactDeletionRelay: Bool {
        guard let localAccountPrincipal else { return false }
        let now = callAccessNow().timeIntervalSince1970 * 1_000
        return groupRepository.contactDeletionPublications.contains {
            $0.sender == localAccountPrincipal && Double($0.expiresAt) > now
        } || groupRepository.contactDeletionRelayReceipts.contains {
            $0.recipient == localAccountPrincipal && Double($0.expiresAt) > now
        }
    }

    func synchronizeContactDeletionRelay(client: InternetAccountClient, access: CallNotificationServiceAccess, generation: UUID) async {
        guard let signer = try? internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID),
              signer.principal == access.principal else { return }
        await sendContactDeletions(client: client, access: access, generation: generation, signer: signer)
        for receipt in groupRepository.contactDeletionRelayReceipts {
            guard contactDeletionRelayIsCurrent(access, generation: generation) else { return }
            if !(await submitContactDeletionReceipt(receipt, client: client, access: access, generation: generation, signer: signer)) { return }
        }
        await receiveRelayedContactDeletions(client: client, access: access, generation: generation, signer: signer)
    }

    private func contactDeletionRelayIsCurrent(_ access: CallNotificationServiceAccess, generation: UUID) -> Bool {
        canEditSavedGroups && groupDeliveryIsCurrent(access, accountID: generation)
    }

    private func sendContactDeletions(client: InternetAccountClient, access: CallNotificationServiceAccess, generation: UUID,
                                      signer: DeviceIdentitySigner) async {
        for id in groupRepository.contactDeletionPublications.map(\.id) {
            guard contactDeletionRelayIsCurrent(access, generation: generation) else { return }
            guard let record = groupRepository.contactDeletionPublications.first(where: { $0.id == id }),
                  record.sender == access.principal, record.senderKey == signer.publicKey,
                  Double(record.expiresAt) > callAccessNow().timeIntervalSince1970 * 1_000
            else { continue }
            if record.payload != nil {
                guard let state = try? await client.writeContactDeletion(record, access: access) else { return }
                guard contactDeletionRelayIsCurrent(access, generation: generation) else { return }
                if state == .received,
                   let notice = groupRepository.contactDeletions.first(where: { $0.id == id }) {
                    await acceptRelayedContactDeletionReceipt(notice, slot: record.slot, client: client, access: access,
                                                             generation: generation, signer: signer)
                }
            }
            guard contactDeletionRelayIsCurrent(access, generation: generation) else { return }
            // A nearby receipt can retire a record while the publish or receipt lookup is still outstanding.
            guard let retirement = groupRepository.contactDeletionPublications.first(where: { $0.id == id && $0.payload == nil })
            else { continue }
            guard (try? await client.writeContactDeletion(retirement, access: access)) == .retired,
                  contactDeletionRelayIsCurrent(access, generation: generation) else { return }
            do { try groupRepository.finishContactDeletionRelay(retirement, now: callAccessNow()) }
            catch { reportGroupStorageError(error); return }
        }
    }

    private func acceptRelayedContactDeletionReceipt(_ notice: ContactDeletionNotice, slot: String, client: InternetAccountClient,
                                                     access: CallNotificationServiceAccess, generation: UUID, signer: DeviceIdentitySigner) async {
        let target = notice.target
        guard let message = try? await client.readContactDeletion(owner: access.principal, slot: slot, access: access),
              contactDeletionRelayIsCurrent(access, generation: generation), message.matches(target),
              let receipt = try? ContactDeletionRelayReceipt.open(message.packet, slot: slot, sender: signer,
                  recipientID: target.recipientMemberID, recipientKey: target.recipientKey)
        else { return }
        do {
            try acknowledgeContactDeletion(receipt, from: target.recipientMemberID)
            finishNearbyGroupDeliveryIfComplete()
        } catch is DeviceIdentityProof.Failure {
            // A different signed receipt leaves the publication pending.
        } catch { reportGroupStorageError(error) }
    }

    private func receiveRelayedContactDeletions(client: InternetAccountClient, access: CallNotificationServiceAccess,
                                               generation: UUID, signer: DeviceIdentitySigner) async {
        for user in savedRemoteUsers {
            guard contactDeletionRelayIsCurrent(access, generation: generation) else { return }
            guard let owner = user.principal, owner.issuer == access.principal.issuer, owner != access.principal,
                  user.memberIDs.count == 1, let member = user.memberIDs.first, let key = user.deviceKeys?[member]
            else { continue }
            let pairID = IntercomGroup.directCallID(memberIDs: [signer.memberID, member])
            guard let group = groupRepository.storedGroup(pairID), group.kind == .direct, group.accountPair == nil else { continue }
            let secret: String?
            do { secret = try groupRepository.credential(for: pairID)?.secret }
            catch { reportGroupStorageError(error); return }
            guard let secret else { continue }
            let slot = ContactDeletionRelayPacket.slot(pairSecret: secret, senderID: member, recipientID: signer.memberID)
            let message: ContactDeletionWorkerPacket?
            do { message = try await client.readContactDeletion(owner: owner, slot: slot, access: access, recipient: signer) }
            catch { return }
            guard contactDeletionRelayIsCurrent(access, generation: generation) else { return }
            guard let message, let notice = try? ContactDeletionPublication.openNotice(message.packet, slot: slot,
                recipient: signer, senderID: member, senderKey: key), message.matches(notice.target) else { continue }
            do { _ = try receiveContactDeletion(notice, from: member) }
            catch is DeviceIdentityProof.Failure { continue }
            catch { reportGroupStorageError(error); return }
            if let receipt = groupRepository.contactDeletionRelayReceipts.first(where: { $0.id == notice.id }),
               !(await submitContactDeletionReceipt(receipt, client: client, access: access, generation: generation, signer: signer)) { return }
        }
    }

    private func submitContactDeletionReceipt(_ record: ContactDeletionRelayReceipt, client: InternetAccountClient,
                                              access: CallNotificationServiceAccess, generation: UUID, signer: DeviceIdentitySigner) async -> Bool {
        guard record.recipient == access.principal, Double(record.expiresAt) > callAccessNow().timeIntervalSince1970 * 1_000,
              groupRepository.contactDeletionReceipts.contains(where: { $0.id == record.id && $0.target.recipientKey == signer.publicKey })
        else { return true }
        guard let delivered = try? await client.acknowledgeRelayedContactDeletion(record, signer: signer, access: access),
              contactDeletionRelayIsCurrent(access, generation: generation) else { return false }
        if delivered {
            do { try groupRepository.finishContactDeletionRelay(record, now: callAccessNow()) }
            catch { reportGroupStorageError(error); return false }
        }
        return true
    }
}
