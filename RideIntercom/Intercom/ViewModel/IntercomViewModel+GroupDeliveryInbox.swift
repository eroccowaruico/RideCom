import Foundation

extension IntercomViewModel {
    private struct GroupDeliveryInboxSession {
        let client: InternetAccountClient
        let signer: DeviceIdentitySigner
        let access: CallNotificationServiceAccess
        let generation: UUID
    }

    private struct OpenedGroupDeliveryInvitation {
        let envelope: GroupInvitationEnvelope
        let token: GroupInviteToken
        let redeliveryTrust: DeviceIdentityTrust?
    }

    private enum IncomingGroupDeliveryStep {
        case next
        case finishInbox
        case stopInbox
    }

    func receiveGroupDeliveries(
        client: InternetAccountClient, access: CallNotificationServiceAccess, generation: UUID
    ) async {
        guard groupDeliveryIsCurrent(access, accountID: generation), canEditSavedGroups,
              let signer = try? internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID)
        else { return }
        let session = GroupDeliveryInboxSession(client: client, signer: signer, access: access, generation: generation)

        // Resume locally saved work before reading new mail. An acknowledged packet
        // can disappear from the mailbox even if its response never reached this device.
        receiving: for _ in 0..<64 {
            guard groupDeliveryInboxIsCurrent(session) else { return }
            let pending = groupRepository.groupDeliveries.first {
                $0.direction == .incoming && $0.state == .pending && $0.recipient == access.principal
                    && $0.recipientMemberID == signer.memberID && $0.recipientKey == signer.publicKey
            }
            let item: GroupDeliveryItem?
            if pending == nil {
                do {
                    item = try await client.nextGroupInvitation(recipientKey: signer.publicKey, access: access)
                } catch {
                    break
                }
                guard groupDeliveryInboxIsCurrent(session) else { return }
            } else {
                item = nil
            }
            guard let id = pending?.id ?? item?.requestID else {
                await requestInvitationsForAdditionalDevice(session)
                break
            }
            switch await receiveGroupInvitation(id, pending: pending, item: item, session: session) {
            case .next: continue
            case .finishInbox: break receiving
            case .stopInbox: return
            }
        }
        refreshGroupStorageStatus()
    }

    private func groupDeliveryInboxIsCurrent(_ session: GroupDeliveryInboxSession) -> Bool {
        groupDeliveryIsCurrent(session.access, accountID: session.generation)
            && canEditSavedGroups && notifications.canUseNotifications
    }

    private func receiveGroupInvitation(
        _ id: UUID, pending: GroupDeliveryRecord?, item: GroupDeliveryItem?, session: GroupDeliveryInboxSession
    ) async -> IncomingGroupDeliveryStep {
        let access = session.access
        let client = session.client
        do {
            let restored = try pending.map { try groupRepository.groupDeliveryEnvelope($0.id) }
            let invitation: OpenedGroupDeliveryInvitation
            do {
                invitation = try openGroupDeliveryInvitation(
                    restored, id: id, sourceRequestID: pending?.sourceRequestID ?? item?.sourceRequestID,
                    item: item, session: session
                )
            } catch {
                try groupRepository.cancelPendingGroupReceipt(id)
                do {
                    try await client.finishGroupInvitation(
                        recipient: access.principal, id: id, discard: true, access: access
                    )
                } catch {
                    // Do not repeatedly fetch the same invalid packet after a failed discard.
                    return .finishInbox
                }
                return .next
            }
            let state = try groupRepository.stageGroupDelivery(
                invitation.envelope, token: invitation.token, now: callAccessNow().timeIntervalSince1970,
                redeliveryTrust: invitation.redeliveryTrust
            )
            let outcome: GroupDeliveryRecord.State?
            do {
                if state != .pending {
                    try await client.finishGroupInvitation(
                        recipient: access.principal, id: id, discard: state == .cancelled, access: access
                    )
                    return .next
                }
                outcome = try await client.acknowledgeGroupInvitation(id, access: access)
            } catch {
                // The ciphertext stays committed for the next lifecycle event.
                return .finishInbox
            }
            guard groupDeliveryInboxIsCurrent(session) else { return .stopInbox }
            try completeGroupInvitationReceipt(invitation, outcome: outcome)
        } catch {
            reportGroupStorageError(error)
            return .stopInbox
        }
        return .next
    }

    private func openGroupDeliveryInvitation(
        _ restored: GroupInvitationEnvelope?,
        id: UUID,
        sourceRequestID: UUID?,
        item: GroupDeliveryItem?,
        session: GroupDeliveryInboxSession
    ) throws -> OpenedGroupDeliveryInvitation {
        let envelope: GroupInvitationEnvelope
        if let restored {
            envelope = restored
        } else {
            guard let item, let bytes = Data(base64Encoded: item.envelope), bytes.count <= 16384
            else { throw InternetAccountClient.Failure.invalidResponse }
            envelope = try JSONDecoder().decode(GroupInvitationEnvelope.self, from: bytes)
        }
        guard envelope.id == id, envelope.sourceRequestID == sourceRequestID, item.map({
            envelope.sender.userID == $0.senderUserID && abs(envelope.expiresAt * 1000 - $0.expiresAt) < 1
        }) ?? true
        else { throw DeviceIdentityProof.Failure.invalid }
        let redeliveryTrust = try sourceRequestID.flatMap { _ in try internetSettingsStore.identityTrust() }
        let user = savedRemoteUsers.first { $0.principal == envelope.sender }
        let token = try envelope.open(
            recipient: session.signer, local: session.access.principal, sender: user, now: callAccessNow(),
            redeliveryTrust: redeliveryTrust
        )
        return .init(envelope: envelope, token: token, redeliveryTrust: redeliveryTrust)
    }

    private func completeGroupInvitationReceipt(
        _ invitation: OpenedGroupDeliveryInvitation, outcome: GroupDeliveryRecord.State?
    ) throws {
        let envelope = invitation.envelope
        let now = callAccessNow().timeIntervalSince1970
        if outcome != .received || envelope.expiresAt <= now {
            try groupRepository.cancelPendingGroupReceipt(envelope.id)
            refreshGroupStorageStatus()
        } else {
            publishReceivedGroup(try groupRepository.receiveGroupDelivery(
                envelope, token: invitation.token, localDisplayName: localMemberIdentity.displayName, now: now,
                redeliveryTrust: invitation.redeliveryTrust
            ))
        }
    }

    private func requestInvitationsForAdditionalDevice(_ session: GroupDeliveryInboxSession) async {
        let signer = session.signer
        let access = session.access
        guard signer.principal == access.principal,
              let ids = try? await session.client.invitationsForAdditionalDevice(
                  recipientKey: signer.publicKey, access: access
              )
        else { return }
        for id in ids {
            guard groupDeliveryInboxIsCurrent(session) else { return }
            do {
                try await session.client.requestGroupInvitationForAdditionalDevice(id, signer: signer, access: access)
            } catch InternetAccountClient.Failure.forbidden {
                continue
            } catch {
                return
            }
        }
    }
}
