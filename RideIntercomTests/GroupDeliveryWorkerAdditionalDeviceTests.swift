#if os(macOS)
import CallControl
import Foundation
import Testing
@testable import RideIntercom

extension GroupDeliveryWorkerTests {
    func verifyAdditionalRecipients(run: TransferRun, first: InitialDelivery, redelivery: Redelivery) async throws {
        let author = run.author, recipientDevice = run.recipientDevice, client = run.client
        let automatic = GroupDeliveryTestIdentity("worker-recipient-automatic")
        defer { automatic.remove() }
        try await register(automatic, appleSubject: recipientDevice.memberID)
        let automaticReceiver = try automatic.harness(knowing: [], onDisk: true).viewModel
        defer { automaticReceiver.stopGroupDeliverySync(); automaticReceiver.disconnect() }
        automaticReceiver.groupDeliveryClient = client
        let automaticCall = automaticReceiver.currentCallReference
        await automaticReceiver.synchronizeGroupDeliveries()
        await author.synchronizeGroupDeliveries()
        try await verifyAutomaticReceiptLoss(
            run: run, redelivery: redelivery, device: automatic, receiver: automaticReceiver, call: automaticCall)
        let reloadedAutomatic = try automatic.harness(knowing: [], onDisk: true).viewModel
        defer { reloadedAutomatic.stopGroupDeliverySync(); reloadedAutomatic.disconnect() }
        reloadedAutomatic.groupDeliveryClient = client
        await reloadedAutomatic.synchronizeGroupDeliveries()
        #expect(reloadedAutomatic.groups.filter { $0.id == redelivery.groupID }.count == 1)
        #expect(!reloadedAutomatic.groups.contains { $0.id == first.groups.revokedAfterDownload })
        #expect(Set(reloadedAutomatic.groups.map(\.id)).isDisjoint(with: first.groups.invited))
        #expect(reloadedAutomatic.savedRemoteUsers.isEmpty && reloadedAutomatic.activeGroupID == nil)
        #expect(
            try reloadedAutomatic.groupRepository.credential(for: redelivery.groupID)
                == author.groupRepository.credential(for: redelivery.groupID))
        await author.synchronizeGroupDeliveries()
        #expect(
            author.groupInvitationDeliveries(in: redelivery.groupID)
                .filter { $0.recipientMemberID == automatic.memberID }.count == 1)
        try await verifySecondRecipient(
            run: run, first: first, redelivery: redelivery, automaticID: automatic.memberID)
    }

    private func verifyAutomaticReceiptLoss(
        run: TransferRun, redelivery: Redelivery, device automatic: GroupDeliveryTestIdentity,
        receiver automaticReceiver: IntercomViewModel, call automaticCall: CallReference
    ) async throws {
        let author = run.author
        let automaticPackets = author.groupInvitationDeliveries(in: redelivery.groupID).filter {
            $0.recipientMemberID == automatic.memberID
        }
        #expect(automaticPackets.count == 1)
        let automaticPacket = try #require(automaticPackets.first)
        #expect(
            automaticPacket.noticeID == redelivery.record.noticeID
                && automaticPacket.expiresAt == redelivery.record.expiresAt)
        #expect(automaticPacket.sourceRequestID == redelivery.record.id)
        var changedSource = try author.groupRepository.groupDeliveryEnvelope(automaticPacket.id)
        changedSource.sourceRequestID = UUID()
        let trust = try #require(try automatic.store.identityTrust())
        #expect(throws: (any Error).self) {
            try changedSource.open(
                recipient: automatic.signer, local: automatic.principal, sender: nil, redeliveryTrust: trust)
        }
        #expect(
            author.savedRemoteUsers.first { $0.id == redelivery.recipient.id }?.memberIDs.contains(automatic.memberID)
                == false)
        GroupWorkerHTTPBridge.dropReceiptForID = automaticPacket.id
        GroupWorkerHTTPBridge.didDropReceipt = false
        await automaticReceiver.synchronizeGroupDeliveries()
        #expect(GroupWorkerHTTPBridge.didDropReceipt)
        #expect(!automaticReceiver.groups.contains { $0.id == redelivery.groupID })
        #expect(
            automaticReceiver.groupRepository.groupDeliveries.first { $0.id == automaticPacket.id }?.state
                == .pending)
        #expect(automaticReceiver.currentCallReference == automaticCall)
        automaticReceiver.stopGroupDeliverySync()
        automaticReceiver.disconnect()
    }

    private func verifySecondRecipient(
        run: TransferRun, first: InitialDelivery, redelivery: Redelivery, automaticID: String
    ) async throws {
        let author = run.author, recipientDevice = run.recipientDevice, client = run.client
        // The same recipient signs into a second device with its own key and an empty directory.
        let second = GroupDeliveryTestIdentity("worker-recipient-second")
        defer { second.remove() }
        try await register(second, appleSubject: recipientDevice.memberID)
        #expect(try second.principal == recipientDevice.principal)
        let secondReceiver = try second.harness(knowing: [], onDisk: true).viewModel
        defer {
            secondReceiver.stopGroupDeliverySync(); secondReceiver.stopContactInvitationSession()
            secondReceiver.disconnect()
        }
        secondReceiver.groupDeliveryClient = client
        struct AdditionalAddress: Decodable, Equatable, Sendable {
            let memberID: String
            let recipientKey: String
        }
        struct AdditionalDevices: Decodable, Sendable {
            let devices: [AdditionalAddress]
        }
        let deliveryPath = "api/notifications/group-invitations/\(redelivery.record.recipient.userID)"
        let path = "\(deliveryPath)/\(redelivery.record.id.uuidString.lowercased())/additional-devices"
        func workerAddresses() async throws -> [AdditionalAddress] {
            let response: AdditionalDevices = try await client.sendJSON(origin: first.sender.origin, path: path,
                method: "GET", token: first.sender.accessToken)
            return response.devices
        }
        let earlierAddresses = try await workerAddresses()
        #expect(earlierAddresses.count == 1 && earlierAddresses.first?.memberID == automaticID)
        await author.synchronizeGroupDeliveries()
        await secondReceiver.synchronizeGroupDeliveries()
        await secondReceiver.synchronizeGroupDeliveries()
        let address = AdditionalAddress(memberID: second.memberID, recipientKey: try second.signer.publicKey)
        let currentAddresses = try await workerAddresses()
        #expect(currentAddresses.count == 2 && currentAddresses.contains(address))
        #expect(secondReceiver.savedRemoteUsers.isEmpty && secondReceiver.groups.isEmpty)
        #expect(
            !author.groupInvitationDeliveries(in: redelivery.groupID).contains {
                $0.recipientMemberID == second.memberID
            })
        try await relayToRegisteredSecondRecipient(run: run, first: first, redelivery: redelivery,
                                                   device: second, receiver: secondReceiver)
    }

    private func relayToRegisteredSecondRecipient(
        run: TransferRun, first: InitialDelivery, redelivery: Redelivery,
        device second: GroupDeliveryTestIdentity, receiver secondReceiver: IntercomViewModel
    ) async throws {
        let author = run.author
        let contact = try #require(author.makeContactInviteURL())
        author.stopContactInvitationSession()
        try secondReceiver.acceptContactInviteURL(contact)
        secondReceiver.stopContactInvitationSession()
        let contactID = try #require(secondReceiver.groupRepository.contactInvitations.first?.id)
        let reply = try secondReceiver.contactReplyURLForSharing(
            contactID, expectedAccountAccessID: secondReceiver.accountAccessID)
        let secondCall = secondReceiver.currentCallReference
        let backgroundRequestsBeforeReply = first.backgroundTime.requested
        try author.receiveContactReplyURL(reply)
        try author.receiveContactReplyURL(reply)
        #expect(first.backgroundTime.requested == backgroundRequestsBeforeReply + 1)
        #expect(
            author.savedRemoteUsers.first { $0.id == redelivery.recipient.id }?.memberIDs.contains(second.memberID)
                == true)
        let relayed = author.groupInvitationDeliveries(in: redelivery.groupID).filter {
            $0.recipientMemberID == second.memberID
        }
        #expect(relayed.count == 1)
        if let packet = relayed.first {
            #expect(packet.noticeID == redelivery.record.noticeID && packet.expiresAt == redelivery.record.expiresAt)
        }
        #expect(
            !author.groupInvitationDeliveries(in: first.groups.revokedAfterDownload).contains {
                $0.recipientMemberID == second.memberID
            })
        await author.groupDeliveryTask?.value
        try await verifySecondDeviceNotification(run: run, initial: first.groups, redelivery: redelivery,
                                                 device: second, receiving: (secondReceiver, secondCall))
    }

    private func verifySecondDeviceNotification(
        run: TransferRun, initial: InitialGroups, redelivery: Redelivery,
        device second: GroupDeliveryTestIdentity, receiving: (model: IntercomViewModel, call: CallReference)
    ) async throws {
        let secondReceiver = receiving.model, secondCall = receiving.call
        let author = run.author
        var receivingStarts = 0, receivingEnds = 0
        secondReceiver.beginGroupDeliveryBackgroundTime = { _ in
            receivingStarts += 1
            return { receivingEnds += 1 }
        }
        let notice = try #require(GroupInvitationTap(payload: ["version": 1, "kind": "groupInvitation",
            "requestID": redelivery.record.noticeID.uuidString, "recipientID": try second.principal.userID]))
        let owner = AppCallOwner(account: secondReceiver.accountSession, viewModel: secondReceiver)
        #expect(await owner.respondToGroupInvitation(notice))
        #expect(receivingStarts == 1 && receivingEnds == 1)
        #expect(secondReceiver.groups.filter { $0.id == redelivery.groupID }.count == 1)
        #expect(!secondReceiver.groups.contains { $0.id == initial.revokedAfterDownload })
        #expect(secondReceiver.currentCallReference == secondCall && secondReceiver.activeGroupID == nil)
        let onSecondDevice = try second.harness(knowing: [], onDisk: true).viewModel
        defer { onSecondDevice.stopGroupDeliverySync(); onSecondDevice.disconnect() }
        let secondKey = try onSecondDevice.groupRepository.credential(for: redelivery.groupID)?.secret
        let sourceKey = try #require(try author.groupRepository.credential(for: redelivery.groupID)).secret
        let keyMatches = secondKey == sourceKey
        #expect(keyMatches)
    }
}
#endif
