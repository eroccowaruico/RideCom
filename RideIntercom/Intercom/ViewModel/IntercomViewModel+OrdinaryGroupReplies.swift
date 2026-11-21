import Foundation
import RTC

@MainActor
final class OrdinaryGroupReplyExchange {
    enum Role: Hashable, Sendable { case inviter, invitee }

    let id: UUID
    let invitation: DirectInvitationContext
    let credential: GroupAccessCredential
    let channel: RTCLocalDataChannel
    var timeout: Task<Void, Never>?
    var endBackgroundTime: (() -> Void)?

    init(id: UUID, invitation: DirectInvitationContext, credential: GroupAccessCredential, channel: RTCLocalDataChannel) {
        self.id = id
        self.invitation = invitation
        self.credential = credential
        self.channel = channel
    }
}

extension IntercomViewModel {
    private var canExchangeOrdinaryGroupReplies: Bool {
        allowsNearbyGroupDelivery && canEditSavedGroups && enabledRTCTransportRoutes.contains(.multipeer)
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
        guard let invitation = pending?.invitation,
              let credential = try? groupRepository.credential(for: invitation.groupID) else { return }
        startOrdinaryGroupReplyExchange(invitation, credential: credential, role: .invitee)
    }

    func startOrdinaryGroupReplyExchange(_ invitation: DirectInvitationContext, credential: GroupAccessCredential,
                                         role: OrdinaryGroupReplyExchange.Role) {
        guard canExchangeOrdinaryGroupReplies, invitation.groupID == credential.groupID,
              invitation.contactBootstrap != true, invitation.recipientAccount == nil, invitation.recipientMemberID == nil,
              (role == .inviter) == (invitation.inviterMemberID == localMemberIdentity.memberID) else { return }
        let remaining = invitation.expiresAt - Date().timeIntervalSince1970
        guard remaining > 0 else { return }
        if let current = ordinaryGroupReplyExchanges[role],
           current.invitation == invitation, current.credential == credential { return }
        stopOrdinaryGroupReplyExchange(role)

        let id = UUID()
        let access = RTCCredential.derived(groupID: "rideintercom.ordinary-group-reply.v1:" + invitation.id.uuidString,
                                           secret: credential.secret)
        let channel = RTCLocalDataChannel(localID: .init(rawValue: localMemberIdentity.memberID), credential: access) { [weak self] event in
            DispatchQueue.main.async { self?.receiveOrdinaryGroupReplyEvent(event, role: role, id: id) }
        }
        let exchange = OrdinaryGroupReplyExchange(id: id, invitation: invitation, credential: credential, channel: channel)
        ordinaryGroupReplyExchanges[role] = exchange
        exchange.timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(min(60, remaining)))
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

    func finishOrdinaryGroupReply(_ invitationID: UUID) {
        guard ordinaryGroupReplyExchanges[.invitee]?.invitation.id == invitationID else { return }
        stopOrdinaryGroupReplyExchange(.invitee)
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
        guard canExchangeOrdinaryGroupReplies, invitation.expiresAt > Date().timeIntervalSince1970,
              (try? groupRepository.credential(for: invitation.groupID)) == exchange.credential else {
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
            if let acknowledgement = applyInvitationReceipt(receipt, from: peer.rawValue, nearby: true),
               let payload = try? JSONEncoder().encode(acknowledgement) {
                exchange.channel.send(payload, to: peer)
            }
        case .failed:
            stopOrdinaryGroupReplyExchange(role, id: id)
        }
    }
}
