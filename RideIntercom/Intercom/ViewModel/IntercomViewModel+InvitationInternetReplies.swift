import Foundation
import RTC

@MainActor final class InvitationInternetReplyWindow {
    enum Purpose { case scheduledRefresh, retryWindow }

    let id = UUID()
    let client: InternetAccountClient
    let access: CallNotificationServiceAccess
    let generation: UUID
    let purpose: Purpose
    var task: Task<Void, Never>?
    var deadline: Task<Void, Never>?
    var endBackgroundTime: (() -> Void)?
    var openedInvitationIDs: Set<UUID> = []
    var submittedReceiptIDs: Set<UUID> = []
    fileprivate var backgroundAcceptanceIDs: Set<UUID> = []

    init(
        client: InternetAccountClient, access: CallNotificationServiceAccess, generation: UUID, purpose: Purpose
    ) {
        self.client = client
        self.access = access
        self.generation = generation
        self.purpose = purpose
    }
}

extension IntercomViewModel {
    private struct InternetReplyTarget {
        let invitation: DirectInvitationContext
        let savedCredential: GroupRepository.OrdinaryGroupReplyCredential
        let address: InvitationReplyAddress
    }

    var allowsInternetInvitationReplies: Bool {
        canEditSavedGroups && enabledRTCTransportRoutes.contains(.webRTC)
    }

    var invitationInternetAccess: CallNotificationServiceAccess? {
        guard hasCurrentAccountAccess, allowsInternetInvitationReplies else { return nil }
        return try? internetSettingsStore.notificationAccess(memberID: localMemberIdentity.memberID)
    }

    var needsInvitationReplyBackgroundRefresh: Bool {
        guard groupDeliveryClient != nil, let access = invitationInternetAccess else { return false }
        return hasInternetInvitationReplies(access: access, includeUnshared: false)
    }

    func refreshInvitationRepliesInBackground() async -> Bool {
        guard !Task.isCancelled, invitationInternetReplyWindow == nil, let client = groupDeliveryClient,
              let access = invitationInternetAccess,
              hasInternetInvitationReplies(access: access, includeUnshared: false)
        else { return false }
        let window = InvitationInternetReplyWindow(
            client: client, access: access, generation: accountAccessID, purpose: .scheduledRefresh)
        invitationInternetReplyWindow = window
        defer { stopInvitationInternetReply(id: window.id) }
        if let transfer = invitationBackgroundTransfer, !transfer.hasRestored { await transfer.restore() }
        guard await synchronizeInvitationInternetReplies(window, includeUnshared: false) else { return false }
        guard !window.backgroundAcceptanceIDs.isEmpty else { return true }
        let records = internetContactReplyRecords(access: window.access, includeUnshared: false).filter {
            window.backgroundAcceptanceIDs.contains($0.id) && $0.internetAcceptanceSubmitted == true
        }
        return await synchronizeInternetContactReplies(window, records: records)
    }

    func contactAcceptanceSubmittedInBackground(_ id: UUID) {
        if let window = invitationInternetReplyWindow, window.purpose == .scheduledRefresh, !groupDeliveryIsForeground,
           internetReplyWindowIsCurrent(window) {
            window.backgroundAcceptanceIDs.insert(id)
        } else {
            requestInvitationInternetReply()
        }
    }

    func requestInvitationInternetReply(restart: Bool = false) {
        guard let client = groupDeliveryClient, let access = invitationInternetAccess,
              hasInternetInvitationReplies(access: access) else { return }
        scheduleBackgroundContactAcceptances(access: access)
        let contactIDs = Set(internetContactReplyRecords(access: access).map(\.id))
        if let window = invitationInternetReplyWindow, !restart, window.access == access,
            window.generation == accountAccessID, window.purpose == .retryWindow || !groupDeliveryIsForeground {
            activeInternetContactReplyIDs = contactIDs
            return
        }
        stopInvitationInternetReply()

        let window = InvitationInternetReplyWindow(
            client: client, access: access, generation: accountAccessID, purpose: .retryWindow)
        let id = window.id
        invitationInternetReplyWindow = window
        activeInternetContactReplyIDs = contactIDs
        let end = beginGroupDeliveryBackgroundTime { [weak self] in self?.stopInvitationInternetReply(id: id) }
        guard invitationInternetReplyWindow === window else { end?(); return }
        window.endBackgroundTime = end
        window.deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self?.stopInvitationInternetReply(id: id)
        }
        scheduleInternetReplyAttempts(for: window)
    }

    private func scheduleInternetReplyAttempts(for window: InvitationInternetReplyWindow) {
        let id = window.id
        let delays = [Duration.zero] + invitationInternetReplyRetryDelays
        window.task = Task { [weak self] in
            defer { self?.stopInvitationInternetReply(id: id) }
            if let transfer = self?.invitationBackgroundTransfer, !transfer.hasRestored {
                await transfer.restore()
                guard let self, self.internetReplyWindowIsCurrent(window) else { return }
                self.scheduleBackgroundContactAcceptances(access: window.access)
            }
            for delay in delays {
                do { if delay > .zero { try await Task.sleep(for: delay) } } catch { return }
                guard let self, let window = self.invitationInternetReplyWindow, window.id == id,
                    self.internetReplyWindowIsCurrent(window),
                    self.hasInternetInvitationReplies(access: window.access)
                else { return }
                guard await self.synchronizeInvitationInternetReplies(window, includeUnshared: true),
                      self.hasInternetInvitationReplies(access: window.access) else { return }
            }
        }
    }

    func stopInvitationInternetReply(id: UUID? = nil) {
        guard let window = invitationInternetReplyWindow, id == nil || window.id == id else { return }
        invitationInternetReplyWindow = nil
        activeInternetContactReplyIDs = []
        window.task?.cancel()
        window.deadline?.cancel()
        window.endBackgroundTime?()
    }

    func reconcileInvitationInternetReply() {
        guard let window = invitationInternetReplyWindow else { return }
        if !internetReplyWindowIsCurrent(window)
            || (window.purpose == .retryWindow && !hasInternetInvitationReplies(access: window.access)) {
            stopInvitationInternetReply(id: window.id)
        } else {
            activeInternetContactReplyIDs = Set(internetContactReplyRecords(access: window.access).map(\.id))
        }
    }

    private func hasInternetInvitationReplies(
        access: CallNotificationServiceAccess, includeUnshared: Bool = true
    ) -> Bool {
        if !internetContactReplyRecords(access: access, includeUnshared: includeUnshared).isEmpty { return true }
        let now = Date().timeIntervalSince1970
        if !groupRepository.issuedOrdinaryGroupInvitations(now: now).isEmpty { return true }
        return groupRepository.pendingOrdinaryGroupReplies(now: now).contains {
            internetOrdinaryReplyOwner(for: $0, access: access) != nil
        }
    }

    private func synchronizeInvitationInternetReplies(
        _ window: InvitationInternetReplyWindow, includeUnshared: Bool
    ) async -> Bool {
        let records = internetContactReplyRecords(access: window.access, includeUnshared: includeUnshared)
        guard await synchronizeInternetContactReplies(window, records: records) else { return false }
        return await synchronizeOrdinaryGroupInternetReplies(window)
    }

    private func internetOrdinaryReplyOwner(
        for invitation: DirectInvitationContext, access: CallNotificationServiceAccess
    ) -> AccountPrincipal? {
        guard let key = invitation.inviterDeviceKey,
            let owner = savedRemoteUsers.first(where: { $0.deviceKeys?[invitation.inviterMemberID] == key })?
                .principal,
              owner.issuer == access.principal.issuer else { return nil }
        return owner
    }

    private func synchronizeOrdinaryGroupInternetReplies(_ window: InvitationInternetReplyWindow) async -> Bool {
        let now = Date().timeIntervalSince1970
        for invitation in groupRepository.issuedOrdinaryGroupInvitations(now: now) {
            guard internetReplyWindowIsCurrent(window) else { return false }
            guard let target = internetReplyTarget(invitation) else { continue }
            do {
                try await receiveOrdinaryGroupInternetAcceptances(target, window: window)
            } catch InternetAccountClient.Failure.rateLimited {
                return false
            } catch {
                // A later pass can try the invitation again.
            }
        }
        for invitation in groupRepository.pendingOrdinaryGroupReplies(now: Date().timeIntervalSince1970) {
            guard internetReplyWindowIsCurrent(window) else { return false }
            if let target = internetReplyTarget(invitation) {
                do {
                    try await submitOrdinaryGroupInternetAcceptance(target, window: window)
                } catch InternetAccountClient.Failure.rateLimited {
                    return false
                } catch {
                    // The pending receipt stays saved.
                }
            }
        }
        return internetReplyWindowIsCurrent(window)
    }

    private func internetReplyTarget(_ invitation: DirectInvitationContext) -> InternetReplyTarget? {
        guard
            let saved = groupRepository.ordinaryGroupReplyCredential(
                for: invitation, now: Date().timeIntervalSince1970),
            let address = try? InvitationReplyAddress(invitation: invitation, credential: saved.credential)
        else { return nil }
        return .init(invitation: invitation, savedCredential: saved, address: address)
    }

    func internetReplyWindowIsCurrent(_ window: InvitationInternetReplyWindow) -> Bool {
        invitationInternetReplyWindow === window && allowsInternetInvitationReplies
            && groupDeliveryIsCurrent(window.access, accountID: window.generation)
    }

    private func internetReplyIsCurrent(_ target: InternetReplyTarget, window: InvitationInternetReplyWindow) -> Bool {
        internetReplyWindowIsCurrent(window)
            && groupRepository.ordinaryGroupReplyCredential(
                for: target.invitation, now: Date().timeIntervalSince1970) == target.savedCredential
    }

    private func receiveOrdinaryGroupInternetAcceptances(
        _ target: InternetReplyTarget, window: InvitationInternetReplyWindow
    ) async throws {
        let invitation = target.invitation, address = target.address
        guard let signer = ordinaryGroupInviterSigner(for: invitation) else { return }
        if !window.openedInvitationIDs.contains(invitation.id) {
            try await window.client.openInvitationReplyMailbox(address, access: window.access)
            window.openedInvitationIDs.insert(invitation.id)
        }
        guard internetReplyIsCurrent(target, window: window) else { return }
        let inbox = try await window.client.invitationReplyInbox(address, access: window.access)
        for packet in inbox {
            guard internetReplyIsCurrent(target, window: window) else { return }
            guard
                let receipt = try? packet.open(
                    address: address, invitation: invitation, kind: .accepted, signer: signer),
                  let confirmation = applyInvitationReceipt(receipt, from: receipt.inviteeMemberID, standalone: true),
                let response = try? InvitationReplyPacket.seal(
                    confirmation, address: address, invitation: invitation)
            else { continue }
            try await window.client.acknowledgeInvitationReply(response, address: address, access: window.access)
        }
    }

    private func submitOrdinaryGroupInternetAcceptance(
        _ target: InternetReplyTarget, window: InvitationInternetReplyWindow
    ) async throws {
        let invitation = target.invitation, address = target.address
        guard let owner = internetOrdinaryReplyOwner(for: invitation, access: window.access),
            let pending = groupRepository.pendingInvitation(for: invitation.groupID),
            pending.invitation == invitation,
              let expectedKey = pending.inviteeDeviceKey,
            let signer = try? internetSettingsStore.invitationSigner(
                memberID: localMemberIdentity.memberID, expectedPublicKey: expectedKey)
        else { return }
        if !window.submittedReceiptIDs.contains(pending.id) {
            let packet = try InvitationReplyPacket.seal(pending, address: address, invitation: invitation)
            try await window.client.submitInvitationAcceptance(
                packet, address: address, owner: owner, access: window.access)
            window.submittedReceiptIDs.insert(pending.id)
        }
        guard internetReplyIsCurrent(target, window: window),
            let reply = try await window.client.invitationReplyReceipt(
                id: pending.id, address: address, owner: owner, access: window.access),
              internetReplyIsCurrent(target, window: window),
            let confirmation = try? reply.open(
                address: address, invitation: invitation, kind: .acknowledged, signer: signer),
            (try? confirmation.verifyAcknowledgement(
                of: pending, trust: internetSettingsStore.identityTrust(), now: Date().timeIntervalSince1970))
                != nil
        else { return }
        _ = applyInvitationReceipt(confirmation, from: confirmation.inviterMemberID, standalone: true)
    }
}
