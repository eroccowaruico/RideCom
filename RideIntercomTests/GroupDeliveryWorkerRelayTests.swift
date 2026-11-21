#if os(macOS)
import Foundation
import Testing
@testable import RideIntercom

extension GroupDeliveryWorkerTests {
    enum RelayedInvitation: CaseIterable { case group, contact, contactWithGroup }

    @Test(.timeLimit(.minutes(1)), arguments: RelayedInvitation.allCases)
    func workerCarriesEncryptedAcceptanceAndAcknowledgement(invitation: RelayedInvitation) async throws {
        try await withWorker {
            let author = GroupDeliveryTestIdentity("ordinary-reply-author")
            let recipient = GroupDeliveryTestIdentity("ordinary-reply-recipient")
            defer { author.remove(); recipient.remove() }
            try await register(author); try await register(recipient)
            let left = try #require(try author.store.notificationAccess(memberID: author.memberID))
            let right = try #require(try recipient.store.notificationAccess(memberID: recipient.memberID))
            let client = InternetAccountClient(session: workerSession())
            let authority = testInvitationAuthority()
            let key = GroupAccessCredential(groupID: UUID(), secret: "worker-ordinary-reply-fixture")
            let token = try issueRelayedInvitation(invitation, key: key, author: author, authority: authority)
            let invite = try #require(token.directInvitation?.context)
            let accepted = try token.accept(signer: recipient.signer, displayName: "Recipient",
                trust: recipient.store.identityTrust(), contactBootstrap: invitation == .group ? nil : true)
            #expect(accepted.inviter.principal == left.principal)
            let address = try invitation == .group
                ? InvitationReplyAddress(invitation: invite, credential: key)
                : InvitationReplyAddress(contactToken: token)
            let admission = invitation == .group ? nil
                : try verifyContactAdmission(token, address: address, owner: left, recipient: recipient, invite: invite)
            let packet = try InvitationReplyPacket.seal(accepted.receipt, address: address, invitation: invite)
            let absent = try await client.invitationReplyReceipt(
                id: packet.id, address: address, owner: left.principal, access: right)
            #expect(absent == nil)
            if invitation == .group { try await client.openInvitationReplyMailbox(address, access: left) }
            try await client.submitInvitationAcceptance(
                packet, address: address, owner: left.principal, access: right, admission: admission)
            let inbox = try await client.invitationReplyInbox(address, access: left)
            #expect(inbox.count == 1)
            let first = try #require(inbox.first)
            let received = try first.open(address: address, invitation: invite, kind: .accepted, signer: author.signer)
            let verified = try authority.verify(received, trust: author.store.identityTrust())
            #expect(verified?.identity.principal == right.principal)
            let reply = try InvitationReplyPacket.seal(
                received.acknowledged(by: author.signer), address: address, invitation: invite)
            try await client.acknowledgeInvitationReply(reply, address: address, access: left)
            let delivered = try await client.invitationReplyReceipt(
                id: packet.id, address: address, owner: left.principal, access: right)
            let acknowledgement = try #require(delivered).open(
                address: address, invitation: invite, kind: .acknowledged, signer: recipient.signer)
            try acknowledgement.verifyAcknowledgement(
                of: accepted.receipt, trust: recipient.store.identityTrust(), now: Date().timeIntervalSince1970)
            #expect(try await client.invitationReplyInbox(address, access: left).isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1))) func workerInboxReadsEightMaximumSizePackets() async throws {
        try await withWorker {
            let author = GroupDeliveryTestIdentity("ordinary-reply-limit-author")
            let participants = (0..<8).map { GroupDeliveryTestIdentity("ordinary-reply-limit-\($0)") }
            defer { author.remove(); participants.forEach { $0.remove() } }
            try await register(author)
            let access = try #require(try author.store.notificationAccess(memberID: author.memberID))
            let client = InternetAccountClient(session: workerSession())
            let key = GroupAccessCredential(groupID: UUID(), secret: "worker-ordinary-reply-limit")
            let invitation = DirectInvitationContext(groupID: key.groupID, inviterMemberID: author.memberID,
                inviterDeviceKey: try author.signer.publicKey, expiresAt: Date().timeIntervalSince1970 + 60)
            let address = try InvitationReplyAddress(invitation: invitation, credential: key)
            try await client.openInvitationReplyMailbox(address, access: access)
            let data = String(repeating: "A", count: 12 * 1024)
            var ids = Set<UUID>()
            for participant in participants {
                try await register(participant)
                let recipient = try #require(try participant.store.notificationAccess(memberID: participant.memberID))
                let packet = InvitationReplyPacket(id: UUID(), packet: data)
                ids.insert(packet.id)
                try await client.submitInvitationAcceptance(
                    packet, address: address, owner: access.principal, access: recipient)
            }
            let results = try await client.invitationReplyInbox(address, access: access)
            #expect(Set(results.map(\.id)) == ids)
            let sizesMatch = results.allSatisfy { $0.packet.utf8.count == 12 * 1024 }
            #expect(sizesMatch)
        }
    }

    private func issueRelayedInvitation(
        _ invitation: RelayedInvitation, key: GroupAccessCredential, author: GroupDeliveryTestIdentity,
        authority: DirectInvitationAuthority
    ) throws -> GroupInviteToken {
        let token: GroupInviteToken
        if invitation == .group {
            token = try GroupInviteToken.make(authority: authority, signer: author.signer,
                credential: key, groupName: "Test group", inviterMemberID: author.memberID)
        } else {
            let group =
                invitation == .contactWithGroup
                ? ContactGroupInvitation(id: key.groupID, name: "Test group", secret: key.secret) : nil
            let issued = try ContactInvitationSession.makeToken(
                authority: authority, signer: author.signer, displayName: "Sender",
                now: Date().timeIntervalSince1970, invitedGroup: group)
            let url = try GroupInviteTokenCodec.joinURL(for: issued, contactBootstrap: true)
            token = try GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true)
        }
        return token
    }

    private func verifyContactAdmission(
        _ token: GroupInviteToken, address: InvitationReplyAddress,
        owner left: CallNotificationServiceAccess, recipient: GroupDeliveryTestIdentity, invite: DirectInvitationContext
    ) throws -> ContactInvitationReplyAdmission? {
        let trust = try recipient.store.identityTrust()
        let admission = ContactInvitationReplyAdmission(token: token, address: address, trust: trust)
        #expect(admission?.owner == left.principal)
        var otherContext = invite
        otherContext.contactBootstrap = nil
        otherContext.invitedGroupID = nil
        otherContext.invitedGroupDigest = nil
        let ordinarySlot = try InvitationReplyAddress(invitation: otherContext,
            credential: .init(groupID: token.groupID, secret: token.groupSecret))
        #expect(ordinarySlot.slot != address.slot)
        #expect(ContactInvitationReplyAdmission(token: token, address: ordinarySlot, trust: trust) == nil)
        #expect(ContactInvitationReplyAdmission(token: token, address: address, trust: trust,
            now: Date(timeIntervalSince1970: invite.expiresAt)) == nil)
        return admission
    }
}
#endif
