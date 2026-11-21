import Foundation
import RTC

extension IntercomViewModel {
    private struct InternetReplyTarget {
        let invitation: DirectInvitationContext
        let credential: GroupAccessCredential
        let reference: UUID
        let address: OrdinaryGroupReplyAddress
    }

    private var allowsInternetOrdinaryReplies: Bool {
        canEditSavedGroups && enabledRTCTransportRoutes.contains(.webRTC)
    }

    func requestOrdinaryGroupInternetReply() {
        guard groupDeliveryClient != nil, allowsInternetOrdinaryReplies,
              (try? internetSettingsStore.notificationAccess(memberID: localMemberIdentity.memberID)) != nil else { return }
        let now = Date().timeIntervalSince1970
        if groupRepository.issuedOrdinaryGroupInvitation(now: now) != nil || !groupRepository.pendingOrdinaryGroupReplies(now: now).isEmpty {
            requestGroupDeliverySync(.ordinaryGroupReply)
        }
    }

    func synchronizeOrdinaryGroupInternetReplies(client: InternetAccountClient, access: CallNotificationServiceAccess, generation: UUID) async {
        guard allowsInternetOrdinaryReplies, groupDeliveryIsCurrent(access, accountID: generation) else { return }
        let now = Date().timeIntervalSince1970
        if let invitation = groupRepository.issuedOrdinaryGroupInvitation(now: now), let target = internetReplyTarget(invitation) {
            await receiveOrdinaryGroupInternetAcceptances(target, client: client, access: access, generation: generation)
        }
        for invitation in groupRepository.pendingOrdinaryGroupReplies(now: Date().timeIntervalSince1970) {
            guard allowsInternetOrdinaryReplies, groupDeliveryIsCurrent(access, accountID: generation) else { return }
            if let target = internetReplyTarget(invitation) {
                await submitOrdinaryGroupInternetAcceptance(target, client: client, access: access, generation: generation)
            }
        }
    }

    private func internetReplyTarget(_ invitation: DirectInvitationContext) -> InternetReplyTarget? {
        guard let reference = groupRepository.ordinaryGroupReplyCredentialReference(for: invitation, now: Date().timeIntervalSince1970),
              let key = try? groupRepository.credential(for: invitation.groupID),
              let address = try? OrdinaryGroupReplyAddress(invitation: invitation, credential: key) else { return nil }
        return .init(invitation: invitation, credential: key, reference: reference, address: address)
    }

    private func internetReplyIsCurrent(_ target: InternetReplyTarget, access: CallNotificationServiceAccess, generation: UUID) -> Bool {
        allowsInternetOrdinaryReplies && groupDeliveryIsCurrent(access, accountID: generation)
            && groupRepository.ordinaryGroupReplyCredentialReference(for: target.invitation, now: Date().timeIntervalSince1970) == target.reference
            && (try? groupRepository.credential(for: target.invitation.groupID)) == target.credential
    }

    private func receiveOrdinaryGroupInternetAcceptances(_ target: InternetReplyTarget, client: InternetAccountClient,
                                                         access: CallNotificationServiceAccess, generation: UUID) async {
        let invitation = target.invitation, address = target.address
        guard let expectedKey = invitation.inviterDeviceKey,
              let signer = try? internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID, expectedPublicKey: expectedKey) else { return }
        do { try await client.openOrdinaryGroupReply(address, access: access) }
        catch { return }
        guard internetReplyIsCurrent(target, access: access, generation: generation),
              let inbox = try? await client.ordinaryGroupReplyInbox(address, access: access) else { return }
        for packet in inbox {
            guard internetReplyIsCurrent(target, access: access, generation: generation) else { return }
            guard let receipt = try? packet.open(address: address, invitation: invitation, kind: .accepted, signer: signer),
                  let confirmation = applyInvitationReceipt(receipt, from: receipt.inviteeMemberID, standalone: true),
                  let response = try? OrdinaryGroupReplyPacket.seal(confirmation, address: address, invitation: invitation) else { continue }
            do { try await client.acknowledgeOrdinaryGroupReply(response, address: address, access: access) }
            catch { return }
        }
    }

    private func submitOrdinaryGroupInternetAcceptance(_ target: InternetReplyTarget, client: InternetAccountClient,
                                                        access: CallNotificationServiceAccess, generation: UUID) async {
        let invitation = target.invitation, address = target.address
        guard let authorKey = invitation.inviterDeviceKey,
              let owner = savedRemoteUsers.first(where: { $0.deviceKeys?[invitation.inviterMemberID] == authorKey })?.principal,
              owner.issuer == access.principal.issuer,
              let pending = groupRepository.pendingInvitation(for: invitation.groupID), pending.invitation == invitation,
              let expectedKey = pending.inviteeDeviceKey,
              let signer = try? internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID, expectedPublicKey: expectedKey),
              let packet = try? OrdinaryGroupReplyPacket.seal(pending, address: address, invitation: invitation) else { return }
        do { try await client.submitOrdinaryGroupAcceptance(packet, address: address, owner: owner, access: access) }
        catch { return }
        guard internetReplyIsCurrent(target, access: access, generation: generation),
              let reply = try? await client.ordinaryGroupReplyReceipt(id: pending.id, address: address, owner: owner, access: access),
              internetReplyIsCurrent(target, access: access, generation: generation),
              let confirmation = try? reply.open(address: address, invitation: invitation, kind: .acknowledged, signer: signer),
              (try? confirmation.verifyAcknowledgement(of: pending, trust: internetSettingsStore.identityTrust(), now: Date().timeIntervalSince1970)) != nil
        else { return }
        _ = applyInvitationReceipt(confirmation, from: confirmation.inviterMemberID, standalone: true)
    }
}
