import CallControl
import CryptoKit
import Foundation
import Testing

@testable import RideIntercom

extension GroupDeliveryFlowTests {
    func establishContact(sender: IntercomViewModel, recipient: IntercomViewModel) throws {
        let invitation = try #require(sender.makeContactInviteURL())
        try recipient.acceptContactInviteURL(invitation)
        let invitationID = try #require(recipient.pendingContactInvitations.first?.id)
        try sender.receiveContactReplyURL(
            recipient.contactReplyURLForSharing(invitationID, expectedAccountAccessID: recipient.accountAccessID))
        sender.stopContactInvitationSession()
        recipient.stopContactInvitationSession()
    }

    enum ContactDeletionOrder: CaseIterable { case internet, internetOnPathRecovery, nearbyFirst, bothRemoved }

    @Test(arguments: ContactDeletionOrder.allCases) func internetContactDeletionCompletesWithoutNotificationPermissions(
        order: ContactDeletionOrder
    ) async throws {
        let authorDevice = GroupDeliveryTestIdentity("internet-delete-author")
        let recipientDevice = GroupDeliveryTestIdentity("internet-delete-recipient")
        let issuer = P256.Signing.PrivateKey()
        try authorDevice.authorizeFixture(userID: String(repeating: "a", count: 64), issuer: issuer)
        try recipientDevice.authorizeFixture(userID: String(repeating: "b", count: 64), issuer: issuer)
        for identity in [authorDevice, recipientDevice] {
            try identity.keychain.saveSecret(
                "unreadable", service: identity.namespace + ".InternetConnection", account: "notification-permissions")
        }
        let sender = try authorDevice.harness(knowing: [], onDisk: true).viewModel
        let recipient = try recipientDevice.harness(knowing: [], onDisk: true).viewModel
        defer {
            sender.stopGroupDeliverySync()
            recipient.stopGroupDeliverySync()
            authorDevice.remove()
            recipientDevice.remove()
        }
        for model in [sender, recipient] {
            model.groupDeliveryClient = nil
            model.contactSessionFactory = { RecordingCallSession() }
            #expect(!model.notifications.canUseNotifications)
        }
        try establishContact(sender: sender, recipient: recipient)

        let client = InternetAccountClient(session: GroupDeliveryHTTPStub.makeSession())
        let relays = try installContactDeletionRelays(author: authorDevice, recipient: recipientDevice, order: order)
        defer { GroupDeliveryHTTPStub.reset() }
        sender.groupDeliveryClient = client
        let transfer = RecordingBackgroundInvitationTransfer()
        sender.invitationBackgroundTransfer = transfer
        let packet = try await checkContactDeletionPublication(on: sender, order: order, relay: relays.forward)
        #expect(transfer.enqueued.isEmpty, "Without the relay key, the regular HTTP path uses the saved packet")

        if order == .nearbyFirst {
            let notice = try #require(sender.groupRepository.contactDeletions.first)
            _ = try recipient.receiveContactDeletion(notice, from: authorDevice.memberID)
        } else if order == .bothRemoved {
            try #require(recipient.removeSavedUser(try #require(recipient.savedRemoteUsers.first).id))
        }
        try await checkContactDeletionAfterRestart(
            devices: (author: authorDevice, recipient: recipientDevice), client: client, relays: relays, packet: packet,
            order: order)
    }

    private func installContactDeletionRelays(
        author authorDevice: GroupDeliveryTestIdentity, recipient recipientDevice: GroupDeliveryTestIdentity,
        order: ContactDeletionOrder
    ) throws -> (forward: ContactDeletionHTTPFixture, reverse: ContactDeletionHTTPFixture) {
        GroupDeliveryHTTPStub.reset()
        let owner = try authorDevice.principal
        let target = try recipientDevice.principal
        let senderToken = try #require(try authorDevice.store.notificationAccess(memberID: authorDevice.memberID))
            .accessToken
        let recipientToken = try #require(
            try recipientDevice.store.notificationAccess(memberID: recipientDevice.memberID)
        ).accessToken
        GroupDeliveryHTTPStub.users = [senderToken: owner.userID, recipientToken: target.userID]
        let relay = ContactDeletionHTTPFixture(
            owner: owner.userID, recipient: target.userID, memberID: recipientDevice.memberID,
            trust: try #require(try recipientDevice.store.identityTrust()))
        relay.dropFirstReceiptResponse = order == .nearbyFirst
        let reverse = ContactDeletionHTTPFixture(
            owner: target.userID, recipient: owner.userID, memberID: authorDevice.memberID,
            trust: try #require(try authorDevice.store.identityTrust()))
        GroupDeliveryHTTPStub.onContactDeletion = { request, caller in
            guard order == .bothRemoved else { return relay.respond(request, caller) }
            let body = request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let sender = body?["owner"] as? String ?? caller
            return (sender == owner.userID ? relay : reverse).respond(request, caller)
        }
        return (forward: relay, reverse: reverse)
    }

    private func checkContactDeletionPublication(
        on sender: IntercomViewModel, order: ContactDeletionOrder, relay: ContactDeletionHTTPFixture
    ) async throws -> String {
        var backgroundStarts = 0
        sender.beginGroupDeliveryBackgroundTime = { _ in
            backgroundStarts += 1
            return {}
        }
        if order == .internetOnPathRecovery { sender.groupDeliveryNetworkPathChanged(isAvailable: false) }
        try #require(sender.removeSavedUser(try #require(sender.savedRemoteUsers.first).id))
        #expect(backgroundStarts == 1)
        await sender.synchronizeGroupDeliveries()
        let pending = try #require(sender.groupRepository.contactDeletionPublications.first)
        let packet = try #require(pending.payload?.packet)
        #expect(relay.entry == nil && relay.submitted == [packet])
        if order == .internetOnPathRecovery {
            sender.groupDeliveryNetworkPathChanged(isAvailable: true)
            sender.groupDeliveryNetworkPathChanged(isAvailable: true)
            await sender.groupDeliveryTask?.value
            try #require(relay.entry?.state == "pending")
            let reusedPacket = relay.submitted == [packet, packet]
            #expect(reusedPacket)
            #expect(backgroundStarts == 2)
        }
        sender.stopGroupDeliverySync()
        return packet
    }

    private func checkContactDeletionAfterRestart(
        devices: (author: GroupDeliveryTestIdentity, recipient: GroupDeliveryTestIdentity),
        client: InternetAccountClient,
        relays: (forward: ContactDeletionHTTPFixture, reverse: ContactDeletionHTTPFixture), packet: String,
        order: ContactDeletionOrder
    ) async throws {
        let relay = relays.forward
        let reverse = relays.reverse
        let reopenedSender = try devices.author.harness(knowing: [], onDisk: true).viewModel
        let reopenedRecipient = try devices.recipient.harness(knowing: [], onDisk: true).viewModel
        defer {
            reopenedSender.stopGroupDeliverySync()
            reopenedRecipient.stopGroupDeliverySync()
        }
        reopenedSender.groupDeliveryClient = client
        reopenedRecipient.groupDeliveryClient = client
        if order != .internetOnPathRecovery { await reopenedSender.synchronizeGroupDeliveries() }
        #expect(relay.entry?.state == "pending")
        #expect(relay.submitted == [packet, packet])
        if order == .internetOnPathRecovery {
            await receiveContactDeletionOnBackgroundNetworkRecovery(reopenedRecipient)
        } else {
            await reopenedRecipient.synchronizeGroupDeliveries()
        }
        #expect(reopenedRecipient.savedRemoteUsers.isEmpty)
        #expect(relay.entry?.state == "received")
        if order == .nearbyFirst {
            let kept = try #require(reopenedRecipient.groupRepository.contactDeletionRelayReceipts.first)
            #expect(relay.received == [kept.packet])
            await reopenedRecipient.synchronizeGroupDeliveries()
            #expect(relay.received == [kept.packet, kept.packet])
        }
        #expect(reopenedRecipient.groupRepository.contactDeletionRelayReceipts.isEmpty)
        if order == .bothRemoved {
            await reopenedRecipient.synchronizeGroupDeliveries()
            #expect(reverse.entry?.state == "pending")
        }
        await reopenedSender.synchronizeGroupDeliveries()
        #expect(reopenedSender.groupRepository.contactDeletions.isEmpty)
        #expect(reopenedSender.groupRepository.contactDeletionPublications.isEmpty)
        #expect(relay.entry?.state == "retired" && relay.entry?.packet == nil)
        #expect(relay.readCount == (order == .nearbyFirst ? 0 : 1))
        #expect(relay.received.count == (order == .nearbyFirst ? 2 : 1))
        if order == .bothRemoved {
            await reopenedRecipient.synchronizeGroupDeliveries()
            #expect(reverse.entry?.state == "retired" && reverse.entry?.packet == nil)
            #expect(reverse.readCount == 1)
            #expect(reopenedRecipient.groupRepository.contactDeletions.isEmpty)
            #expect(reopenedRecipient.groupRepository.contactDeletionFormerPairs.isEmpty)
            #expect(reopenedSender.groupRepository.contactDeletionFormerPairs.isEmpty)
        }
    }

    private func receiveContactDeletionOnBackgroundNetworkRecovery(_ recipient: IntercomViewModel) async {
        #expect(!recipient.notifications.canUseNotifications)
        #expect(!recipient.hasPendingContactDeletionRelay)
        var backgroundStarts = 0
        recipient.beginGroupDeliveryBackgroundTime = { _ in
            backgroundStarts += 1
            return {}
        }
        recipient.setGroupDeliveryForeground(false)
        recipient.groupDeliveryNetworkPathChanged(isAvailable: false)
        recipient.groupDeliveryNetworkPathChanged(isAvailable: true)
        #expect(recipient.endGroupDeliveryBackgroundTime != nil)
        let requestsOnRecovery = backgroundStarts
        recipient.groupDeliveryNetworkPathChanged(isAvailable: true)
        #expect(backgroundStarts == requestsOnRecovery)
        await recipient.groupDeliveryTask?.value
    }

    @Test func contactDeletionSealsOneInternetPacketBeforeDiscardingThePairKey() throws {
        let authorDevice = GroupDeliveryTestIdentity("relay-contact-author")
        let recipientDevice = GroupDeliveryTestIdentity("relay-contact-recipient")
        defer {
            authorDevice.remove()
            recipientDevice.remove()
        }
        let issuer = P256.Signing.PrivateKey()
        try authorDevice.authorizeFixture(userID: String(repeating: "a", count: 64), issuer: issuer)
        try recipientDevice.authorizeFixture(userID: String(repeating: "b", count: 64), issuer: issuer)
        let sender = try authorDevice.harness(knowing: [], onDisk: true).viewModel
        let recipient = try recipientDevice.harness(knowing: [], onDisk: true).viewModel
        for model in [sender, recipient] {
            model.groupDeliveryClient = nil
            model.contactSessionFactory = { RecordingCallSession() }
        }
        defer {
            sender.stopGroupDeliverySync()
            recipient.stopGroupDeliverySync()
        }
        try establishContact(sender: sender, recipient: recipient)

        let person = try #require(sender.savedRemoteUsers.first)
        let senderPrincipal = try authorDevice.principal
        let recipientPrincipal = try recipientDevice.principal
        #expect(person.principal == recipientPrincipal)
        #expect(sender.localAccountPrincipal == senderPrincipal)
        let pairID = IntercomGroup.directCallID(memberIDs: [authorDevice.memberID, recipientDevice.memberID])
        let oldSecret = try #require(try recipient.groupRepository.credential(for: pairID)).secret
        try #require(sender.removeSavedUser(person.id))
        #expect(try sender.groupRepository.credential(for: pairID) == nil)
        let notice = try #require(sender.groupRepository.contactDeletions.first)
        let publication = try #require(sender.groupRepository.contactDeletionPublications.first)
        #expect(publication.id == notice.id)
        #expect(publication.sender == senderPrincipal && publication.payload?.recipient == recipientPrincipal)
        let reopened = try checkSealedContactDeletionPacket(
            publication, notice: notice, formerSecret: oldSecret, author: authorDevice, recipient: recipientDevice)
        try checkSealedContactDeletionReceipt(
            notices: (original: notice, reopened: reopened), publication: publication, on: recipient,
            devices: (author: authorDevice, recipient: recipientDevice), pairID: pairID)
    }

    private func checkSealedContactDeletionPacket(
        _ publication: ContactDeletionPublication, notice: ContactDeletionNotice, formerSecret oldSecret: String,
        author authorDevice: GroupDeliveryTestIdentity, recipient recipientDevice: GroupDeliveryTestIdentity
    ) throws -> ContactDeletionNotice {
        #expect(
            publication.slot
                == ContactDeletionRelayPacket.slot(
                    pairSecret: oldSecret, senderID: authorDevice.memberID, recipientID: recipientDevice.memberID))
        #expect(
            publication.slot
                != ContactDeletionRelayPacket.slot(
                    pairSecret: oldSecret, senderID: recipientDevice.memberID, recipientID: authorDevice.memberID))
        let packet = try #require(publication.payload?.packet)
        let recipientSigner = try recipientDevice.signer
        let senderKey = try authorDevice.signer.publicKey
        let reopened = try ContactDeletionPublication.openNotice(
            packet, slot: publication.slot, recipient: recipientSigner, senderID: authorDevice.memberID,
            senderKey: senderKey)
        #expect(reopened == notice)
        let otherSlot = ContactDeletionRelayPacket.slot(
            pairSecret: "new-pair-key", senderID: authorDevice.memberID, recipientID: recipientDevice.memberID)
        #expect(throws: (any Error).self) {
            try ContactDeletionPublication.openNotice(
                packet, slot: otherSlot, recipient: recipientSigner, senderID: authorDevice.memberID,
                senderKey: senderKey)
        }
        var altered = try #require(Data(base64Encoded: packet))
        altered[altered.startIndex] ^= 1
        #expect(throws: (any Error).self) {
            try ContactDeletionPublication.openNotice(
                altered.base64EncodedString(), slot: publication.slot, recipient: recipientSigner,
                senderID: authorDevice.memberID, senderKey: senderKey)
        }
        return reopened
    }

    private func checkSealedContactDeletionReceipt(
        notices: (original: ContactDeletionNotice, reopened: ContactDeletionNotice),
        publication: ContactDeletionPublication, on recipient: IntercomViewModel,
        devices: (author: GroupDeliveryTestIdentity, recipient: GroupDeliveryTestIdentity), pairID: UUID
    ) throws {
        let authorDevice = devices.author
        let recipientDevice = devices.recipient
        let senderPrincipal = try authorDevice.principal
        let recipientPrincipal = try recipientDevice.principal
        let recipientSigner = try recipientDevice.signer
        let senderKey = try authorDevice.signer.publicKey
        let restarted = try authorDevice.harness(knowing: [], onDisk: true).viewModel
        defer { restarted.stopGroupDeliverySync() }
        restarted.groupDeliveryClient = nil
        #expect(restarted.groupRepository.contactDeletionPublications == [publication])
        let receipt = try recipient.receiveContactDeletion(notices.original, from: authorDevice.memberID)
        #expect(try recipient.groupRepository.credential(for: pairID) == nil)
        let sealedReceipt = try #require(recipient.groupRepository.contactDeletionRelayReceipts.first)
        #expect(sealedReceipt.id == publication.id && sealedReceipt.slot == publication.slot)
        #expect(sealedReceipt.expiresAt == publication.expiresAt)
        #expect(sealedReceipt.owner == senderPrincipal && sealedReceipt.recipient == recipientPrincipal)
        let restartedRecipient = try recipientDevice.harness(knowing: [], onDisk: true).viewModel
        defer { restartedRecipient.stopGroupDeliverySync() }
        restartedRecipient.groupDeliveryClient = nil
        #expect(try restartedRecipient.receiveContactDeletion(notices.reopened, from: authorDevice.memberID) == receipt)
        #expect(restartedRecipient.groupRepository.contactDeletionRelayReceipts == [sealedReceipt])
        let senderSigner = try authorDevice.signer
        let openedReceipt = try ContactDeletionRelayReceipt.open(
            sealedReceipt.packet, slot: publication.slot, sender: senderSigner, recipientID: recipientDevice.memberID,
            recipientKey: recipientSigner.publicKey)
        #expect(openedReceipt == receipt)
        #expect(throws: (any Error).self) {
            try ContactDeletionPublication.openNotice(
                sealedReceipt.packet, slot: publication.slot, recipient: recipientSigner,
                senderID: authorDevice.memberID, senderKey: senderKey)
        }
        try restarted.acknowledgeContactDeletion(openedReceipt, from: recipientDevice.memberID)
        #expect(restarted.groupRepository.contactDeletions.isEmpty)
        let retirement = try #require(restarted.groupRepository.contactDeletionPublications.first)
        #expect(retirement.id == publication.id && retirement.slot == publication.slot && retirement.payload == nil)
        let afterReceipt = try authorDevice.harness(knowing: [], onDisk: true).viewModel
        defer { afterReceipt.stopGroupDeliverySync() }
        #expect(afterReceipt.groupRepository.contactDeletionPublications == [retirement])
    }
}
