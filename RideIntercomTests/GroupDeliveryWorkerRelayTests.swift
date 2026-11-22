#if os(macOS)
import Foundation
import Testing
@testable import RideIntercom

extension GroupDeliveryWorkerTests {
    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func savedContactDeletionCanBePublishedByTheBackgroundTransfer(nearbyFirst: Bool) async throws {
        try await withWorker {
            let author = GroupDeliveryTestIdentity("background-contact-delete-author")
            let recipient = GroupDeliveryTestIdentity("background-contact-delete-recipient")
            defer { author.remove(); recipient.remove() }
            try await register(author); try await register(recipient)
            let sender = try author.harness(knowing: [], onDisk: true).viewModel
            let receiver = try recipient.harness(knowing: [], onDisk: true).viewModel
            defer { sender.stopGroupDeliverySync(); receiver.stopGroupDeliverySync() }
            for model in [sender, receiver] {
                model.groupDeliveryClient = nil
                model.contactSessionFactory = { RecordingCallSession() }
                #expect(!model.notifications.isEnabled)
            }
            try exchangeContactInvitation(sender: sender, recipient: receiver)
            let session = workerSession()
            let client = InternetAccountClient(session: session)
            let transfer = RecordingBackgroundInvitationTransfer()
            sender.groupDeliveryClient = client
            sender.invitationBackgroundTransfer = transfer
            try #require(sender.removeSavedUser(try #require(sender.savedRemoteUsers.first).id))
            let key = try #require(transfer.enqueued.first)
            let request = try #require(transfer.requests[key])
            #expect(request.url?.path == "/api/contact-deletions/background-publish")
            #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
            let publication = try #require(sender.groupRepository.contactDeletionPublications.first)
            #expect(key.deliveryID == publication.id)
            await sender.synchronizeGroupDeliveries()
            receiver.groupDeliveryClient = client
            await receiver.synchronizeGroupDeliveries()
            #expect(receiver.savedRemoteUsers.count == 1, "The regular sync does not also publish the queued upload")
            try await completeBackgroundContactDeletion(
                models: (sender, receiver), identities: (author, recipient),
                client: client, upload: .init(key: key, request: request, transfer: transfer), nearbyFirst: nearbyFirst)
        }
    }

    private struct BackgroundContactDeletionUpload {
        let key: InvitationBackgroundUploadID
        let request: URLRequest
        let transfer: RecordingBackgroundInvitationTransfer
    }

    private func completeBackgroundContactDeletion(
        models: (sender: IntercomViewModel, receiver: IntercomViewModel),
        identities: (author: GroupDeliveryTestIdentity, recipient: GroupDeliveryTestIdentity),
        client: InternetAccountClient, upload: BackgroundContactDeletionUpload, nearbyFirst: Bool
    ) async throws {
        let (sender, receiver) = models
        let (key, request, transfer) = (upload.key, upload.request, upload.transfer)
        if nearbyFirst {
            let notice = try #require(sender.groupRepository.contactDeletions.first)
            let receipt = try receiver.receiveContactDeletion(notice, from: identities.author.memberID)
            try sender.acknowledgeContactDeletion(receipt, from: identities.recipient.memberID)
            sender.requestGroupDeliverySync(.localChange)
            #expect(!transfer.contains(key))
            await sender.synchronizeGroupDeliveries()
        }
        let (reply, response) = try await client.session.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let state = try JSONDecoder().decode([String: String].self, from: reply)["state"]
        #expect(state == (nearbyFirst ? "retired" : "pending"))
        if !nearbyFirst {
            let oldKey = InvitationBackgroundUploadID(
                deliveryID: key.deliveryID, sessionBinding: String(repeating: "0", count: 64),
                operation: key.operation)
            sender.applyBackgroundInvitationResponse(reply, for: oldKey)
            #expect(sender.backgroundInvitationUploadIDs().contains(key))
        }
        transfer.active.remove(key)
        sender.applyBackgroundInvitationResponse(reply, for: key)
        #expect(!sender.backgroundInvitationUploadIDs().contains(key))
        #expect(sender.groupRepository.contactDeletions.count == (nearbyFirst ? 0 : 1))
        if nearbyFirst {
            await receiver.synchronizeGroupDeliveries()
        } else {
            #expect(!receiver.notifications.isEnabled)
            #expect(!receiver.hasPendingContactDeletionRelay)
            receiver.setGroupDeliveryForeground(false)
            receiver.groupDeliveryNetworkPathChanged(isAvailable: false)
            receiver.groupDeliveryNetworkPathChanged(isAvailable: true)
            await receiver.groupDeliveryTask?.value
        }
        #expect(receiver.savedRemoteUsers.isEmpty)
        let reopened = try identities.author.harness(knowing: [], onDisk: true).viewModel
        defer { reopened.stopGroupDeliverySync() }
        reopened.groupDeliveryClient = client
        reopened.invitationBackgroundTransfer = RecordingBackgroundInvitationTransfer()
        #expect(!reopened.backgroundInvitationUploadIDs().contains(key))
        await reopened.synchronizeGroupDeliveries()
        #expect(reopened.groupRepository.contactDeletions.isEmpty)
        #expect(reopened.groupRepository.contactDeletionPublications.isEmpty)
    }

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
