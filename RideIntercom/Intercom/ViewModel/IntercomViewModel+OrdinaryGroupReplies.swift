import Foundation
import RTC

@MainActor
final class OrdinaryGroupReplyExchange {
    enum Role: Hashable, Sendable { case inviter, invitee }

    let id: UUID
    let invitation: DirectInvitationContext
    let savedCredential: GroupRepository.OrdinaryGroupReplyCredential
    let channel: RTCLocalDataChannel
    var timeout: Task<Void, Never>?
    var endBackgroundTime: (() -> Void)?

    init(id: UUID, invitation: DirectInvitationContext, savedCredential: GroupRepository.OrdinaryGroupReplyCredential,
         channel: RTCLocalDataChannel) {
        self.id = id
        self.invitation = invitation
        self.savedCredential = savedCredential
        self.channel = channel
    }
}

extension IntercomViewModel {
    private var canExchangeOrdinaryGroupReplies: Bool {
        allowsNearbyGroupDelivery && canEditSavedGroups && enabledRTCTransportRoutes.contains(.multipeer)
    }

    func resumeSavedOrdinaryGroupReplies() {
        requestOrdinaryGroupInternetReply()
        resumeSavedNearbyOrdinaryGroupReplies()
    }

    func resumeSavedNearbyOrdinaryGroupReplies() {
        guard canExchangeOrdinaryGroupReplies else { return }
        resumeIssuedOrdinaryGroupReply()
        guard ordinaryGroupReplyExchanges[.invitee] == nil else { return }
        let invitation = groupRepository.resumableOrdinaryGroupReply(now: Date().timeIntervalSince1970)
        resumeReceivedOrdinaryGroupReply(invitation)
    }

    private func resumeIssuedOrdinaryGroupReply() {
        guard let invitation = groupRepository.issuedOrdinaryGroupInvitations(now: Date().timeIntervalSince1970).last,
              let expectedKey = invitation.inviterDeviceKey,
              (try? internetSettingsStore.invitationSigner(memberID: localMemberIdentity.memberID, expectedPublicKey: expectedKey)) != nil
        else { return }
        startOrdinaryGroupReplyExchange(invitation)
    }

    func resumeOrdinaryGroupReply(for group: IntercomGroup) {
        guard canExchangeOrdinaryGroupReplies else { return }
        let pending: DirectInvitationReceipt?
        if group.kind == .group {
            pending = groupRepository.pendingInvitation(for: group.id)
        } else if let personID = savedUserID(forDirectCall: group),
                  let person = savedRemoteUsers.first(where: { $0.id == personID }) {
            pending = groupRepository.pendingOrdinaryGroupReceipt(for: person, now: Date().timeIntervalSince1970)
        } else {
            pending = nil
        }
        resumeReceivedOrdinaryGroupReply(pending?.invitation)
    }

    private func resumeReceivedOrdinaryGroupReply(_ invitation: DirectInvitationContext?) {
        guard let invitation else { return }
        startOrdinaryGroupReplyExchange(invitation)
    }

    func startOrdinaryGroupReplyExchange(_ invitation: DirectInvitationContext) {
        let now = Date().timeIntervalSince1970
        guard canExchangeOrdinaryGroupReplies,
              let saved = groupRepository.ordinaryGroupReplyCredential(for: invitation, now: now) else { return }
        let role: OrdinaryGroupReplyExchange.Role = invitation.inviterMemberID == localMemberIdentity.memberID ? .inviter : .invitee
        if let current = ordinaryGroupReplyExchanges[role],
           current.invitation == invitation, current.savedCredential == saved { return }
        stopOrdinaryGroupReplyExchange(role)

        let id = UUID()
        let access = RTCCredential.derived(groupID: "rideintercom.ordinary-group-reply.v1:" + invitation.id.uuidString,
                                           secret: saved.credential.secret)
        let channel = RTCLocalDataChannel(localID: .init(rawValue: localMemberIdentity.memberID), credential: access) { [weak self] event in
            DispatchQueue.main.async { self?.receiveOrdinaryGroupReplyEvent(event, role: role, id: id) }
        }
        let exchange = OrdinaryGroupReplyExchange(id: id, invitation: invitation, savedCredential: saved, channel: channel)
        ordinaryGroupReplyExchanges[role] = exchange
        exchange.timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(min(60, invitation.expiresAt - now)))
            guard !Task.isCancelled else { return }
            self?.stopOrdinaryGroupReplyExchange(role, id: id)
        }
        let end = beginOrdinaryGroupReplyBackgroundTime { [weak self] in self?.stopOrdinaryGroupReplyExchange(role, id: id) }
        guard ordinaryGroupReplyExchanges[role] === exchange else { end?(); return }
        exchange.endBackgroundTime = end
        channel.start()
    }

    func stopOrdinaryGroupReplyExchanges() {
        for role in Array(ordinaryGroupReplyExchanges.keys) { stopOrdinaryGroupReplyExchange(role) }
    }

    func reconcileOrdinaryGroupReplyExchanges() {
        guard !ordinaryGroupReplyExchanges.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        for (role, exchange) in ordinaryGroupReplyExchanges where !isCurrentOrdinaryGroupReply(exchange, now: now) {
            stopOrdinaryGroupReplyExchange(role, id: exchange.id)
        }
    }

    private func isCurrentOrdinaryGroupReply(_ exchange: OrdinaryGroupReplyExchange, now: TimeInterval) -> Bool {
        canExchangeOrdinaryGroupReplies
            && groupRepository.ordinaryGroupReplyCredentialReference(for: exchange.invitation, now: now) == exchange.savedCredential.reference
    }

    private func stopOrdinaryGroupReplyExchange(_ role: OrdinaryGroupReplyExchange.Role, id: UUID? = nil) {
        guard let exchange = ordinaryGroupReplyExchanges[role], id == nil || exchange.id == id else { return }
        ordinaryGroupReplyExchanges.removeValue(forKey: role)
        exchange.timeout?.cancel()
        exchange.channel.stop()
        exchange.endBackgroundTime?()
    }

    private func receiveOrdinaryGroupReplyEvent(_ event: RTCLocalDataChannel.Event, role: OrdinaryGroupReplyExchange.Role, id: UUID) {
        guard let exchange = ordinaryGroupReplyExchanges[role], exchange.id == id else { return }
        let invitation = exchange.invitation
        guard canExchangeOrdinaryGroupReplies,
              groupRepository.ordinaryGroupReplyCredential(for: invitation, now: Date().timeIntervalSince1970) == exchange.savedCredential
        else {
            stopOrdinaryGroupReplyExchange(role, id: id)
            return
        }
        switch event {
        case .members(let members):
            let author = PeerID(rawValue: invitation.inviterMemberID)
            guard role == .invitee, members.contains(author),
                  let receipt = signedPendingInvitationReceipt(for: invitation.groupID), receipt.invitation == invitation,
                  let data = try? JSONEncoder().encode(receipt) else { return }
            exchange.channel.send(data, to: author)
        case .message(let data, let peer):
            guard data.count <= 8192, let receipt = try? JSONDecoder().decode(DirectInvitationReceipt.self, from: data),
                  receipt.isValid, receipt.invitation == invitation,
                  (role == .inviter && receipt.kind == .accepted) || (role == .invitee && receipt.kind == .acknowledged) else { return }
            if let acknowledgement = applyInvitationReceipt(receipt, from: peer.rawValue, standalone: true),
               let payload = try? JSONEncoder().encode(acknowledgement) {
                exchange.channel.send(payload, to: peer)
            }
        case .failed:
            stopOrdinaryGroupReplyExchange(role, id: id)
        }
    }
}
