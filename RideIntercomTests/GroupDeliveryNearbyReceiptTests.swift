import CallControl
import Foundation
import RTC
import Synchronization
import Testing

@testable import RideIntercom

extension GroupDeliveryFlowTests {
    @Test(.timeLimit(.minutes(1))) func nearbyReceiptRequiresTheSameEnvelopeAndSurvivesLostReply() async throws {
        let authorDevice = GroupDeliveryTestIdentity("nearby-group-author")
        let recipientDevice = GroupDeliveryTestIdentity("nearby-group-recipient")
        defer {
            authorDevice.remove()
            recipientDevice.remove()
        }
        try authorDevice.authorizeFixture(userID: String(repeating: "a", count: 64))
        try recipientDevice.authorizeFixture(userID: String(repeating: "b", count: 64))
        let sender = try authorDevice.harness(knowing: [recipientDevice], onDisk: true).viewModel
        let receiver = try recipientDevice.harness(knowing: [authorDevice], onDisk: true).viewModel
        defer {
            sender.disconnect()
            receiver.disconnect()
        }
        sender.groupDeliveryClient = nil
        receiver.groupDeliveryClient = nil
        try #require(sender.createTalkGroup(name: "Offline riders", userIDs: [recipientDevice.personID]))
        sender.disconnect()
        let delivery = try #require(sender.groupRepository.groupDeliveries.first)
        let envelope = try #require(try sender.prepareGroupDeliveryEnvelope(delivery, sender: authorDevice.principal))

        let credentials = try verifyNearbyDeliveryCredentials(
            sender: sender, receiver: receiver, author: authorDevice, recipient: recipientDevice)
        let exchange = NearbyReceiptChannels(
            author: .init(rawValue: authorDevice.memberID), authorCredential: credentials.author,
            recipient: .init(rawValue: recipientDevice.memberID), recipientCredential: credentials.recipient)
        defer { exchange.stop() }
        try await exchange.start()
        let incoming = try await exchange.transmit(envelope)
        let receipt = try receiveWithoutReply(
            incoming, sender: sender, receiver: receiver, senderID: authorDevice.memberID, groupID: delivery.groupID)

        receiver.deleteGroup(delivery.groupID)
        let restarted = try recipientDevice.harness(knowing: [authorDevice], onDisk: true).viewModel
        restarted.groupDeliveryClient = nil
        #expect(
            restarted.nearbyGroupDeliveryCredentials()[.init(rawValue: authorDevice.memberID)] == credentials.recipient)
        let repeated = try verifyNearbyReplayRequiresSameEnvelope(
            incoming, sender: sender, recipient: restarted, devices: (author: authorDevice, recipient: recipientDevice))
        let received = try await exchange.transmit(repeated)
        #expect(throws: (any Error).self) {
            try sender.acknowledgeNearbyGroupInvitation(received, from: authorDevice.memberID)
        }

        try await checkReceiptWhileInternetDeliveryIsInFlight(
            received, original: receipt, sender: sender, author: authorDevice, recipient: recipientDevice)
        #expect(restarted.groups.isEmpty, "A repeated envelope does not recreate the deleted group")
        #expect(sender.activeGroupID == nil && receiver.activeGroupID == nil)
    }

    private func receiveWithoutReply(
        _ incoming: GroupInvitationEnvelope, sender: IntercomViewModel, receiver: IntercomViewModel, senderID: String,
        groupID: UUID
    ) throws -> GroupInvitationReceipt {
        let receipt = try #require(try receiver.receiveNearbyGroupInvitation(incoming, from: senderID))
        #expect(
            sender.groupRepository.groupDeliveries.first?.state == .pending,
            "Losing the receipt leaves the same outgoing request")
        #expect(
            try receiver.groupRepository.credential(for: groupID) == sender.groupRepository.credential(for: groupID))
        return receipt
    }

    private func verifyNearbyDeliveryCredentials(
        sender: IntercomViewModel, receiver: IntercomViewModel, author authorDevice: GroupDeliveryTestIdentity,
        recipient recipientDevice: GroupDeliveryTestIdentity
    ) throws -> (author: RTCCredential, recipient: RTCCredential) {
        let authorCredential = try #require(
            sender.nearbyGroupDeliveryCredentials()[.init(rawValue: recipientDevice.memberID)])
        let recipientCredential = try #require(
            receiver.nearbyGroupDeliveryCredentials()[.init(rawValue: authorDevice.memberID)])
        try #require(authorCredential == recipientCredential)
        #expect(sender.nearbyGroupDeliveryCredentials()[.init(rawValue: "unsaved-device")] == nil)
        let signer = try authorDevice.signer
        let expected = try signer.nearbyGroupDeliverySecret(
            peerMemberID: recipientDevice.memberID, peerPublicKey: recipientDevice.signer.publicKey)
        #expect(
            try signer.nearbyGroupDeliverySecret(
                peerMemberID: "other-device", peerPublicKey: recipientDevice.signer.publicKey) != expected)
        #expect(
            try signer.nearbyGroupDeliverySecret(
                peerMemberID: recipientDevice.memberID, peerPublicKey: testIdentitySigner("replacement-key").publicKey)
                != expected)
        #expect(throws: DeviceIdentityProof.Failure.self) {
            try signer.nearbyGroupDeliverySecret(
                peerMemberID: recipientDevice.memberID, peerPublicKey: signer.publicKey)
        }
        return (author: authorCredential, recipient: recipientCredential)
    }

    private func verifyNearbyReplayRequiresSameEnvelope(
        _ incoming: GroupInvitationEnvelope, sender: IntercomViewModel, recipient: IntercomViewModel,
        devices: (author: GroupDeliveryTestIdentity, recipient: GroupDeliveryTestIdentity)
    ) throws -> GroupInvitationReceipt {
        let authorDevice = devices.author
        let recipientDevice = devices.recipient
        let opened = try incoming.open(
            recipient: recipientDevice.signer, local: recipientDevice.principal, sender: authorDevice.savedUser())
        let reencrypted = try GroupInvitationEnvelope.seal(
            opened, sender: authorDevice.principal,
            recipient: .init(
                principal: recipientDevice.principal, memberID: recipientDevice.memberID,
                encryptionKey: recipientDevice.signer.publicKey), signer: authorDevice.signer, deliveryID: incoming.id)
        #expect(try recipient.receiveNearbyGroupInvitation(reencrypted, from: authorDevice.memberID) == nil)
        let replacementReceipt = try GroupInvitationReceipt(for: reencrypted, signer: recipientDevice.signer)
        #expect(throws: (any Error).self) {
            try sender.acknowledgeNearbyGroupInvitation(replacementReceipt, from: recipientDevice.memberID)
        }
        let repeated = try #require(try recipient.receiveNearbyGroupInvitation(incoming, from: authorDevice.memberID))
        return repeated
    }

    private func checkReceiptWhileInternetDeliveryIsInFlight(
        _ received: GroupInvitationReceipt, original receipt: GroupInvitationReceipt, sender: IntercomViewModel,
        author authorDevice: GroupDeliveryTestIdentity, recipient recipientDevice: GroupDeliveryTestIdentity
    ) async throws {
        GroupDeliveryHTTPStub.reset()
        defer {
            sender.stopGroupDeliverySync()
            GroupDeliveryHTTPStub.reset()
        }
        let access = try #require(try authorDevice.store.notificationAccess(memberID: authorDevice.memberID))
        GroupDeliveryHTTPStub.users = [access.accessToken: try authorDevice.principal.userID]
        try grantGroupInvitationPermission(on: sender, recipient: recipientDevice, sender: authorDevice)
        sender.groupDeliveryNetworkPathChanged(isAvailable: false)
        GroupDeliveryHTTPStub.onQueued = {
            sender.groupDeliveryNetworkPathChanged(isAvailable: true)
            do { try sender.acknowledgeNearbyGroupInvitation(received, from: recipientDevice.memberID) } catch {
                Issue.record("The near-range receipt must succeed while Internet delivery is in flight: \(error)")
            }
        }
        sender.groupDeliveryClient = .init(session: GroupDeliveryHTTPStub.makeSession())
        await sender.synchronizeGroupDeliveries()
        #expect(GroupDeliveryHTTPStub.submitted.count == 1)
        #expect(sender.groupStorageIssue == nil)
        try sender.acknowledgeNearbyGroupInvitation(receipt, from: recipientDevice.memberID)
        #expect(sender.groupRepository.groupDeliveries.first?.state == .received)
    }
}

@MainActor private final class NearbyReceiptChannels {
    private let authorID: PeerID
    private let recipientID: PeerID
    private let author: RTCLocalDataChannel
    private let recipient: RTCLocalDataChannel
    private let fromAuthor: NearbyReceiptEvents
    private let fromRecipient: NearbyReceiptEvents

    init(author: PeerID, authorCredential: RTCCredential, recipient: PeerID, recipientCredential: RTCCredential) {
        authorID = author
        recipientID = recipient
        let authorEvents = NearbyReceiptEvents()
        let recipientEvents = NearbyReceiptEvents()
        fromAuthor = authorEvents
        fromRecipient = recipientEvents
        self.author = RTCLocalDataChannel(localID: author, credential: authorCredential) { event in
            authorEvents.values.withLock { $0.append(event) }
        }
        self.recipient = RTCLocalDataChannel(localID: recipient, credential: recipientCredential) { event in
            recipientEvents.values.withLock { $0.append(event) }
        }
    }

    func start() async throws {
        author.start()
        recipient.start()
        await AppTestSupport.waitUntil(timeout: .seconds(12)) {
            self.fromAuthor.values.withLock { $0.contains(.members([self.recipientID])) }
                && self.fromRecipient.values.withLock { $0.contains(.members([self.authorID])) }
        }
        try #require(fromAuthor.values.withLock { $0.contains(.members([recipientID])) })
    }

    func transmit(_ envelope: GroupInvitationEnvelope) async throws -> GroupInvitationEnvelope {
        let packet = try JSONEncoder().encode(envelope)
        author.send(packet)
        await AppTestSupport.waitUntil(timeout: .seconds(5)) {
            self.fromRecipient.values.withLock { $0.contains(.message(packet, from: self.authorID)) }
        }
        try #require(fromRecipient.values.withLock { $0.contains(.message(packet, from: authorID)) })
        return try JSONDecoder().decode(GroupInvitationEnvelope.self, from: packet)
    }

    func transmit(_ receipt: GroupInvitationReceipt) async throws -> GroupInvitationReceipt {
        let reply = try JSONEncoder().encode(receipt)
        recipient.send(reply)
        await AppTestSupport.waitUntil(timeout: .seconds(5)) {
            self.fromAuthor.values.withLock { $0.contains(.message(reply, from: self.recipientID)) }
        }
        try #require(fromAuthor.values.withLock { $0.contains(.message(reply, from: recipientID)) })
        return try JSONDecoder().decode(GroupInvitationReceipt.self, from: reply)
    }

    func stop() {
        author.stop()
        recipient.stop()
    }
}

private final class NearbyReceiptEvents: Sendable { let values = Mutex<[RTCLocalDataChannel.Event]>([]) }
