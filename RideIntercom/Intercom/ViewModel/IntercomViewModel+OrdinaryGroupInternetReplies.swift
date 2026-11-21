import Foundation
import RTC

@MainActor final class OrdinaryGroupInternetReplyWindow {
    let id = UUID()
    let client: InternetAccountClient
    let access: CallNotificationServiceAccess
    let generation: UUID
    var task: Task<Void, Never>?
    var deadline: Task<Void, Never>?
    var endBackgroundTime: (() -> Void)?
    var openedInvitationIDs: Set<UUID> = []
    var submittedReceiptIDs: Set<UUID> = []

    init(client: InternetAccountClient, access: CallNotificationServiceAccess, generation: UUID) {
        self.client = client
        self.access = access
        self.generation = generation
    }
}

extension IntercomViewModel {
    private struct InternetReplyTarget {
        let invitation: DirectInvitationContext
        let savedCredential: GroupRepository.OrdinaryGroupReplyCredential
        let address: OrdinaryGroupReplyAddress
    }

    private var allowsInternetOrdinaryReplies: Bool {
        canEditSavedGroups && enabledRTCTransportRoutes.contains(.webRTC)
    }

    func requestOrdinaryGroupInternetReply(restart: Bool = false) {
        guard let client = groupDeliveryClient, hasCurrentAccountAccess, allowsInternetOrdinaryReplies,
              let access = try? internetSettingsStore.notificationAccess(memberID: localMemberIdentity.memberID),
              hasInternetOrdinaryReplies(access: access) else { return }
        if let window = ordinaryGroupInternetReplyWindow, !restart, window.access == access, window.generation == accountAccessID { return }
        stopOrdinaryGroupInternetReply()

        let window = OrdinaryGroupInternetReplyWindow(client: client, access: access, generation: accountAccessID)
        let id = window.id
        ordinaryGroupInternetReplyWindow = window
        let end = beginGroupDeliveryBackgroundTime { [weak self] in self?.stopOrdinaryGroupInternetReply(id: id) }
        guard ordinaryGroupInternetReplyWindow === window else { end?(); return }
        window.endBackgroundTime = end
        window.deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) }
            catch { return }
            self?.stopOrdinaryGroupInternetReply(id: id)
        }
        let delays = [Duration.zero] + ordinaryGroupInternetReplyRetryDelays
        window.task = Task { [weak self] in
            defer { self?.stopOrdinaryGroupInternetReply(id: id) }
            for delay in delays {
                do { if delay > .zero { try await Task.sleep(for: delay) } }
                catch { return }
                guard let self, let window = self.ordinaryGroupInternetReplyWindow, window.id == id,
                      self.internetReplyWindowIsCurrent(window), self.hasInternetOrdinaryReplies(access: window.access)
                else { return }
                if !(await self.synchronizeOrdinaryGroupInternetReplies(window)) { return }
            }
        }
    }

    func stopOrdinaryGroupInternetReply(id: UUID? = nil) {
        guard let window = ordinaryGroupInternetReplyWindow, id == nil || window.id == id else { return }
        ordinaryGroupInternetReplyWindow = nil
        window.task?.cancel()
        window.deadline?.cancel()
        window.endBackgroundTime?()
    }

    func reconcileOrdinaryGroupInternetReply() {
        guard let window = ordinaryGroupInternetReplyWindow else { return }
        if !internetReplyWindowIsCurrent(window) || !hasInternetOrdinaryReplies(access: window.access) {
            stopOrdinaryGroupInternetReply(id: window.id)
        }
    }

    private func hasInternetOrdinaryReplies(access: CallNotificationServiceAccess) -> Bool {
        let now = Date().timeIntervalSince1970
        if !groupRepository.issuedOrdinaryGroupInvitations(now: now).isEmpty { return true }
        return groupRepository.pendingOrdinaryGroupReplies(now: now).contains {
            internetOrdinaryReplyOwner(for: $0, access: access) != nil
        }
    }

    private func internetOrdinaryReplyOwner(for invitation: DirectInvitationContext, access: CallNotificationServiceAccess) -> AccountPrincipal? {
        guard let key = invitation.inviterDeviceKey,
              let owner = savedRemoteUsers.first(where: { $0.deviceKeys?[invitation.inviterMemberID] == key })?.principal,
              owner.issuer == access.principal.issuer else { return nil }
        return owner
    }

    private func synchronizeOrdinaryGroupInternetReplies(_ window: OrdinaryGroupInternetReplyWindow) async -> Bool {
        let now = Date().timeIntervalSince1970
        for invitation in groupRepository.issuedOrdinaryGroupInvitations(now: now) {
            guard internetReplyWindowIsCurrent(window) else { return false }
            guard let target = internetReplyTarget(invitation) else { continue }
            do { try await receiveOrdinaryGroupInternetAcceptances(target, window: window) }
            catch InternetAccountClient.Failure.rateLimited { return false }
            catch { /* A later pass can try the invitation again. */ }
        }
        for invitation in groupRepository.pendingOrdinaryGroupReplies(now: Date().timeIntervalSince1970) {
            guard internetReplyWindowIsCurrent(window) else { return false }
            if let target = internetReplyTarget(invitation) {
                do { try await submitOrdinaryGroupInternetAcceptance(target, window: window) }
                catch InternetAccountClient.Failure.rateLimited { return false }
                catch { /* The pending receipt stays saved. */ }
            }
        }
        return internetReplyWindowIsCurrent(window) && hasInternetOrdinaryReplies(access: window.access)
    }

    private func internetReplyTarget(_ invitation: DirectInvitationContext) -> InternetReplyTarget? {
        guard let saved = groupRepository.ordinaryGroupReplyCredential(for: invitation, now: Date().timeIntervalSince1970),
              let address = try? OrdinaryGroupReplyAddress(invitation: invitation, credential: saved.credential) else { return nil }
        return .init(invitation: invitation, savedCredential: saved, address: address)
    }

    private func internetReplyWindowIsCurrent(_ window: OrdinaryGroupInternetReplyWindow) -> Bool {
        ordinaryGroupInternetReplyWindow === window && allowsInternetOrdinaryReplies
            && groupDeliveryIsCurrent(window.access, accountID: window.generation)
    }

    private func internetReplyIsCurrent(_ target: InternetReplyTarget, window: OrdinaryGroupInternetReplyWindow) -> Bool {
        internetReplyWindowIsCurrent(window)
            && groupRepository.ordinaryGroupReplyCredential(for: target.invitation, now: Date().timeIntervalSince1970) == target.savedCredential
    }

    private func receiveOrdinaryGroupInternetAcceptances(_ target: InternetReplyTarget, window: OrdinaryGroupInternetReplyWindow) async throws {
        let invitation = target.invitation, address = target.address
        guard let signer = ordinaryGroupInviterSigner(for: invitation) else { return }
        if !window.openedInvitationIDs.contains(invitation.id) {
            try await window.client.openOrdinaryGroupReply(address, access: window.access)
            window.openedInvitationIDs.insert(invitation.id)
        }
        guard internetReplyIsCurrent(target, window: window) else { return }
        let inbox = try await window.client.ordinaryGroupReplyInbox(address, access: window.access)
        for packet in inbox {
            guard internetReplyIsCurrent(target, window: window) else { return }
            guard let receipt = try? packet.open(address: address, invitation: invitation, kind: .accepted, signer: signer),
                  let confirmation = applyInvitationReceipt(receipt, from: receipt.inviteeMemberID, standalone: true),
                  let response = try? OrdinaryGroupReplyPacket.seal(confirmation, address: address, invitation: invitation) else { continue }
            try await window.client.acknowledgeOrdinaryGroupReply(response, address: address, access: window.access)
        }
    }

    private func submitOrdinaryGroupInternetAcceptance(_ target: InternetReplyTarget, window: OrdinaryGroupInternetReplyWindow) async throws {
        let invitation = target.invitation, address = target.address
        guard let owner = internetOrdinaryReplyOwner(for: invitation, access: window.access),
              let pending = groupRepository.pendingInvitation(for: invitation.groupID), pending.invitation == invitation,
              let expectedKey = pending.inviteeDeviceKey,
              let signer = try? internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID, expectedPublicKey: expectedKey) else { return }
        if !window.submittedReceiptIDs.contains(pending.id) {
            let packet = try OrdinaryGroupReplyPacket.seal(pending, address: address, invitation: invitation)
            try await window.client.submitOrdinaryGroupAcceptance(packet, address: address, owner: owner, access: window.access)
            window.submittedReceiptIDs.insert(pending.id)
        }
        guard internetReplyIsCurrent(target, window: window),
              let reply = try await window.client.ordinaryGroupReplyReceipt(id: pending.id, address: address, owner: owner, access: window.access),
              internetReplyIsCurrent(target, window: window),
              let confirmation = try? reply.open(address: address, invitation: invitation, kind: .acknowledged, signer: signer),
              (try? confirmation.verifyAcknowledgement(of: pending, trust: internetSettingsStore.identityTrust(), now: Date().timeIntervalSince1970)) != nil
        else { return }
        _ = applyInvitationReceipt(confirmation, from: confirmation.inviterMemberID, standalone: true)
    }
}
