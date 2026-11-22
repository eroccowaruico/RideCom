import CallControl
import Foundation
import RTC
import Synchronization
import Testing

@testable import RideIntercom

extension GroupDeliveryFlowTests {
    @Test(.timeLimit(.minutes(1)))
    func receivedCancellationBlocksTheExactLateInvitationAndPreservesAnAlreadyReceivedGroup() async throws {
        let authorDevice = GroupDeliveryTestIdentity("cancellation-wire-sender")
        let recipientDevice = GroupDeliveryTestIdentity("cancellation-wire-recipient")
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
            receiver.stopGroupDeliverySync()
        }
        sender.groupDeliveryClient = nil
        receiver.groupDeliveryClient = nil
        receiver.allowsNearbyGroupDelivery = true

        let invitations = try prepareInvitationsForCancellation(
            on: sender, to: recipientDevice.personID, author: authorDevice)
        let incomingToken = try invitations.staged.envelope.open(
            recipient: recipientDevice.signer, local: recipientDevice.principal, sender: authorDevice.savedUser())
        let stagedState = try receiver.groupRepository.stageGroupDelivery(
            invitations.staged.envelope, token: incomingToken, now: Date().timeIntervalSince1970)
        try #require(stagedState == .pending)
        _ = try #require(
            try receiver.receiveNearbyGroupInvitation(invitations.accepted.envelope, from: authorDevice.memberID))

        try await checkWireCancellation(
            sender: sender, receiver: receiver, invitations: invitations, incomingToken: incomingToken,
            devices: (author: authorDevice, recipient: recipientDevice))
    }

    private func prepareInvitationsForCancellation(
        on sender: IntercomViewModel, to personID: UUID, author authorDevice: GroupDeliveryTestIdentity
    ) throws -> InvitationsToCancel {
        let lateGroup = UUID()
        let stagedGroup = UUID()
        let acceptedGroup = UUID()
        try #require(sender.createTalkGroup(name: "Late group", userIDs: [personID], id: lateGroup))
        try #require(sender.createTalkGroup(name: "Staged group", userIDs: [personID], id: stagedGroup))
        try #require(sender.createTalkGroup(name: "Saved group", userIDs: [personID], id: acceptedGroup))
        let lateRecord = try #require(sender.groupRepository.groupDeliveries.first { $0.groupID == lateGroup })
        let stagedRecord = try #require(sender.groupRepository.groupDeliveries.first { $0.groupID == stagedGroup })
        let acceptedRecord = try #require(sender.groupRepository.groupDeliveries.first { $0.groupID == acceptedGroup })
        let late = try #require(try sender.prepareGroupDeliveryEnvelope(lateRecord, sender: authorDevice.principal))
        let incoming = try #require(
            try sender.prepareGroupDeliveryEnvelope(stagedRecord, sender: authorDevice.principal))
        let accepted = try #require(
            try sender.prepareGroupDeliveryEnvelope(acceptedRecord, sender: authorDevice.principal))
        return InvitationsToCancel(
            late: (lateGroup, late), staged: (stagedGroup, incoming), accepted: (acceptedGroup, accepted))
    }

    private func checkWireCancellation(
        sender: IntercomViewModel, receiver: IntercomViewModel, invitations: InvitationsToCancel,
        incomingToken: GroupInviteToken,
        devices: (author: GroupDeliveryTestIdentity, recipient: GroupDeliveryTestIdentity)
    ) async throws {
        let authorDevice = devices.author
        let recipientDevice = devices.recipient
        let receipts = NearbyCancellationReceipts()
        let recipients = Mutex<Set<PeerID>>([])
        let recipientID = PeerID(rawValue: recipientDevice.memberID)
        let channel = RTCLocalDataChannel(
            localID: .init(rawValue: authorDevice.memberID), knownPeers: sender.nearbyGroupDeliveryCredentials(),
            offeredPeers: [recipientID]
        ) { event in
            switch event {
            case .members(let peers): recipients.withLock { $0 = Set(peers) }
            case .message(let bytes, let peer):
                if peer == recipientID,
                    case .cancellationReceipt(let receipt) = try? JSONDecoder().decode(
                        NearbyGroupDeliveryFrame.self, from: bytes) {
                    receipts.values.withLock { $0.append(receipt) }
                }
            case .failed: break
            }
        }
        defer { channel.stop() }
        receiver.setGroupDeliveryForeground(true)
        channel.start()
        await AppTestSupport.waitUntil(timeout: .seconds(12)) { recipients.withLock { $0.contains(recipientID) } }
        try #require(recipients.withLock { $0.contains(recipientID) })

        let lateTarget = try GroupInvitationCancellation.Target(
            envelope: invitations.late.envelope, groupID: invitations.late.groupID)
        let stagedTarget = try GroupInvitationCancellation.Target(
            envelope: invitations.staged.envelope, groupID: invitations.staged.groupID)
        let acceptedTarget = try GroupInvitationCancellation.Target(
            envelope: invitations.accepted.envelope, groupID: invitations.accepted.groupID)
        try await checkCancellationReceipts(
            targets: .init(late: lateTarget, staged: stagedTarget, accepted: acceptedTarget), from: authorDevice,
            on: channel, to: recipientID, observedIn: receipts)
        let discarded = try #require(
            receiver.groupRepository.groupDeliveries.first { $0.id == invitations.staged.envelope.id })
        #expect(discarded.state == .cancelled && discarded.credentialReference == nil)
        #expect(
            try receiver.groupRepository.receiveGroupDelivery(
                invitations.staged.envelope, token: incomingToken, localDisplayName: "You",
                now: Date().timeIntervalSince1970) == nil)

        try checkCancelledInvitationAfterRestart(
            receiver, devices: (author: authorDevice, recipient: recipientDevice), envelope: invitations.late.envelope,
            acceptedGroup: invitations.accepted.groupID)
    }

    private func checkCancellationReceipts(
        targets: CancellationTargets, from authorDevice: GroupDeliveryTestIdentity, on channel: RTCLocalDataChannel,
        to recipientID: PeerID, observedIn receipts: NearbyCancellationReceipts
    ) async throws {
        let forged = try GroupInvitationCancellation(
            target: targets.late, signer: testIdentitySigner(authorDevice.memberID))
        let cancel = try GroupInvitationCancellation(target: targets.late, signer: authorDevice.signer)
        let alreadyReceived = try GroupInvitationCancellation(target: targets.accepted, signer: authorDevice.signer)
        let cancelStaged = try GroupInvitationCancellation(target: targets.staged, signer: authorDevice.signer)
        for request in [forged, cancel, alreadyReceived, cancelStaged, cancel] {
            channel.send(try JSONEncoder().encode(NearbyGroupDeliveryFrame.cancellation(request)), to: recipientID)
        }
        await AppTestSupport.waitUntil(timeout: .seconds(5)) { receipts.values.withLock { $0.count >= 4 } }
        let observed = receipts.values.withLock { $0 }
        #expect(observed.map(\.outcome) == [.cancelled, .alreadyReceived, .cancelled, .cancelled])
        for (receipt, target) in zip(observed, [targets.late, targets.accepted, targets.staged, targets.late]) {
            try receipt.verify(for: target)
        }
    }

    private func checkCancelledInvitationAfterRestart(
        _ receiver: IntercomViewModel,
        devices: (author: GroupDeliveryTestIdentity, recipient: GroupDeliveryTestIdentity),
        envelope late: GroupInvitationEnvelope, acceptedGroup: UUID
    ) throws {
        let authorDevice = devices.author
        let recipientDevice = devices.recipient
        receiver.stopGroupDeliverySync()
        let reopened = try recipientDevice.harness(knowing: [authorDevice], onDisk: true).viewModel
        #expect(try reopened.receiveNearbyGroupInvitation(late, from: authorDevice.memberID) == nil)
        #expect(reopened.groups.map(\.id) == [acceptedGroup])
        let staged = try reopened.groupRepository.stageGroupDelivery(
            late,
            token: late.open(
                recipient: recipientDevice.signer, local: recipientDevice.principal, sender: authorDevice.savedUser()),
            now: Date().timeIntervalSince1970)
        #expect(staged == .cancelled)
    }

    @Test(.timeLimit(.minutes(1)))
    func internetCancellationKeepsTheUnacknowledgedNearbyHandoffAfterRestart() async throws {
        let authorDevice = GroupDeliveryTestIdentity("cancel-nearby-sender")
        let recipientDevice = GroupDeliveryTestIdentity("cancel-nearby-recipient")
        defer {
            authorDevice.remove()
            recipientDevice.remove()
        }
        try authorDevice.authorizeFixture(userID: String(repeating: "a", count: 64))
        try recipientDevice.authorizeFixture(userID: String(repeating: "b", count: 64))
        let sender = try authorDevice.harness(knowing: [recipientDevice], onDisk: true).viewModel
        let recipient = try recipientDevice.harness(knowing: [authorDevice], onDisk: true).viewModel
        sender.groupDeliveryClient = nil
        sender.allowsNearbyGroupDelivery = true
        GroupDeliveryHTTPStub.reset()
        defer {
            sender.stopGroupDeliverySync()
            sender.disconnect()
            GroupDeliveryHTTPStub.reset()
        }

        let receivedFrame = Mutex<Data?>(nil)
        let channel = RTCLocalDataChannel(
            localID: .init(rawValue: recipientDevice.memberID),
            knownPeers: recipient.nearbyGroupDeliveryCredentials()
        ) { event in
            if case .message(let data, _) = event {
                receivedFrame.withLock { $0 = data }
            }
        }
        defer { channel.stop() }
        channel.start()
        sender.setGroupDeliveryForeground(true)
        try #require(sender.createTalkGroup(name: "Invite to cancel", userIDs: [recipientDevice.personID]))
        let delivery = try #require(sender.groupRepository.groupDeliveries.first)
        await AppTestSupport.waitUntil(timeout: .seconds(12)) { receivedFrame.withLock { $0 != nil } }
        let bytes = try #require(receivedFrame.withLock { $0 })
        let digest = try JSONDecoder().decode(CapturedInvitation.self, from: bytes).invitation.envelope.receiptDigest()
        #expect(sender.groupRepository.groupDeliveries.first?.state == .pending)
        #expect(sender.groupRepository.groupDeliveries.first?.nearbyHandoff?.envelopeDigest == digest)

        try #require(sender.removeMember(recipientDevice.memberID, from: delivery.groupID))
        let access = try #require(try authorDevice.store.notificationAccess(memberID: authorDevice.memberID))
        GroupDeliveryHTTPStub.users = [access.accessToken: try authorDevice.principal.userID]
        sender.groupDeliveryClient = .init(session: GroupDeliveryHTTPStub.makeSession())
        await sender.synchronizeGroupDeliveries()
        try #require(
            sender.groupRepository.groupDeliveries.first?.state == .cancelled,
            "HTTP cancellation must leave the independently dispatched near-range cancellation pending")
        #expect(GroupDeliveryHTTPStub.deletions == [delivery.id.uuidString.lowercased()])

        try await checkInternetCancellationRetained(
            afterRestartOf: authorDevice, recipient: recipientDevice, deliveryID: delivery.id,
            digest: digest, client: sender.groupDeliveryClient
        )
    }

    private func checkInternetCancellationRetained(
        afterRestartOf authorDevice: GroupDeliveryTestIdentity,
        recipient recipientDevice: GroupDeliveryTestIdentity,
        deliveryID: UUID,
        digest: Data,
        client: InternetAccountClient?
    ) async throws {
        let reopened = try authorDevice.harness(knowing: [recipientDevice], onDisk: true).viewModel
        defer { reopened.stopGroupDeliverySync() }
        let saved = try #require(reopened.groupRepository.groupDeliveries.first)
        #expect(saved.id == deliveryID && saved.state == .cancelled && saved.credentialReference == nil)
        #expect(
            saved.nearbyHandoff?.envelopeDigest == digest && saved.nearbyHandoff?.internetCancellationConfirmed == true
        )
        reopened.groupDeliveryClient = client
        var internetBackgroundRequests = 0
        reopened.beginGroupDeliveryBackgroundTime = { _ in
            internetBackgroundRequests += 1
            return {}
        }
        await reopened.synchronizeGroupDeliveries(.localChange)
        #expect(
            GroupDeliveryHTTPStub.deletions == [deliveryID.uuidString.lowercased()],
            "The Internet acknowledgement remains known after reopening the manifest")
        #expect(
            internetBackgroundRequests == 0,
            "A locally retained cancellation with no Internet work must not ask for Internet background time")
    }

    @Test(.timeLimit(.minutes(1)))
    func savedNearbyCancellationResumesAfterRestartAndUsesTheRecipientsOutcome() async throws {
        let authorDevice = GroupDeliveryTestIdentity("cancel-resuming-author")
        let recipientDevice = GroupDeliveryTestIdentity("cancel-resuming-recipient")
        defer {
            authorDevice.remove()
            recipientDevice.remove()
        }
        try authorDevice.authorizeFixture(userID: String(repeating: "a", count: 64))
        try recipientDevice.authorizeFixture(userID: String(repeating: "b", count: 64))
        let sender = try authorDevice.harness(knowing: [recipientDevice], onDisk: true).viewModel
        let recipient = try recipientDevice.harness(knowing: [authorDevice], onDisk: true).viewModel
        defer {
            sender.stopGroupDeliverySync()
            sender.disconnect()
            recipient.stopGroupDeliverySync()
        }
        sender.groupDeliveryClient = nil
        sender.allowsNearbyGroupDelivery = true
        recipient.groupDeliveryClient = nil
        recipient.allowsNearbyGroupDelivery = true

        let sent = Mutex<[UUID: GroupInvitationEnvelope]>([:])
        let interceptor = RTCLocalDataChannel(
            localID: .init(rawValue: recipientDevice.memberID),
            knownPeers: recipient.nearbyGroupDeliveryCredentials()
        ) { event in
            if case .message(let bytes, _) = event,
                case .invitation(let envelope) = try? JSONDecoder().decode(NearbyGroupDeliveryFrame.self, from: bytes) {
                sent.withLock { $0[envelope.id] = envelope }
            }
        }
        defer { interceptor.stop() }
        interceptor.start()
        sender.setGroupDeliveryForeground(true)
        let first = UUID()
        let second = UUID()
        try #require(
            sender.createTalkGroup(name: "Delayed before save", userIDs: [recipientDevice.personID], id: first))
        try #require(
            sender.createTalkGroup(name: "Saved without reply", userIDs: [recipientDevice.personID], id: second))
        let late = try #require(sender.groupRepository.groupDeliveries.first { $0.groupID == first })
        let accepted = try #require(sender.groupRepository.groupDeliveries.first { $0.groupID == second })
        await AppTestSupport.waitUntil(timeout: .seconds(12)) { sent.withLock { $0.count == 2 } }
        let lateEnvelope = try #require(sent.withLock { $0[late.id] })
        let acceptedEnvelope = try #require(sent.withLock { $0[accepted.id] })
        _ = try #require(try recipient.receiveNearbyGroupInvitation(acceptedEnvelope, from: authorDevice.memberID))
        interceptor.stop()

        try await resumeNearbyCancellation(
            sender: sender, recipient: recipient, devices: (author: authorDevice, recipient: recipientDevice),
            late: (groupID: first, envelope: lateEnvelope), accepted: (recordID: accepted.id, groupID: second)
        )
    }

    private func resumeNearbyCancellation(
        sender: IntercomViewModel,
        recipient: IntercomViewModel,
        devices: (author: GroupDeliveryTestIdentity, recipient: GroupDeliveryTestIdentity),
        late: (groupID: UUID, envelope: GroupInvitationEnvelope),
        accepted: (recordID: UUID, groupID: UUID)
    ) async throws {
        let authorDevice = devices.author
        let recipientDevice = devices.recipient
        try #require(sender.removeMember(recipientDevice.memberID, from: late.groupID))
        try #require(sender.removeMember(recipientDevice.memberID, from: accepted.groupID))
        sender.stopGroupDeliverySync()
        let restarted = try authorDevice.harness(knowing: [recipientDevice], onDisk: true).viewModel
        defer { restarted.stopGroupDeliverySync() }
        restarted.groupDeliveryClient = nil
        restarted.allowsNearbyGroupDelivery = true
        recipient.setGroupDeliveryForeground(true)
        restarted.setGroupDeliveryForeground(true)

        try await checkNearbyCancellationOutcomes(
            on: restarted, recipient: recipient, late: (late.envelope.id, late.envelope),
            accepted: (accepted.recordID, accepted.groupID), senderID: authorDevice.memberID
        )
        try await checkRemainingInternetCancellation(
            on: restarted, author: authorDevice, lateID: late.envelope.id, acceptedID: accepted.recordID
        )
    }

    private func checkNearbyCancellationOutcomes(
        on restarted: IntercomViewModel,
        recipient: IntercomViewModel,
        late: (id: UUID, envelope: GroupInvitationEnvelope),
        accepted: (id: UUID, groupID: UUID),
        senderID: String
    ) async throws {
        await AppTestSupport.waitUntil(timeout: .seconds(12)) {
            restarted.groupRepository.groupDeliveries.contains { $0.id == late.id && $0.nearbyHandoff == nil }
                && restarted.groupRepository.groupDeliveries.contains {
                    $0.id == accepted.id && $0.nearbyHandoff?.recipientAlreadyReceived == true
                }
        }
        try #require(
            restarted.groupRepository.groupDeliveries.contains {
                $0.id == late.id && $0.state == .cancelled && $0.nearbyHandoff == nil && $0.internetAction == .cancel
            })
        #expect(
            restarted.groupRepository.groupDeliveries.contains {
                $0.id == accepted.id && $0.nearbyHandoff?.recipientAlreadyReceived == true && $0.nearbyWork == nil
            })
        #expect(try recipient.receiveNearbyGroupInvitation(late.envelope, from: senderID) == nil)
        #expect(recipient.groups.map(\.id) == [accepted.groupID])
    }

    private func checkRemainingInternetCancellation(
        on restarted: IntercomViewModel,
        author authorDevice: GroupDeliveryTestIdentity,
        lateID: UUID,
        acceptedID: UUID
    ) async throws {
        GroupDeliveryHTTPStub.reset()
        defer { GroupDeliveryHTTPStub.reset() }
        let access = try #require(try authorDevice.store.notificationAccess(memberID: authorDevice.memberID))
        GroupDeliveryHTTPStub.users = [access.accessToken: try authorDevice.principal.userID]
        restarted.groupDeliveryClient = .init(session: GroupDeliveryHTTPStub.makeSession())
        await restarted.synchronizeGroupDeliveries()
        #expect(!restarted.groupRepository.groupDeliveries.contains { $0.id == lateID })
        #expect(
            restarted.groupRepository.groupDeliveries.contains {
                $0.id == acceptedID && $0.nearbyHandoff?.recipientAlreadyReceived == true && $0.internetAction == nil
            })
    }
}

private struct CapturedInvitation: Decodable {
    let invitation: CapturedInvitationPayload
}

private struct CapturedInvitationPayload: Decodable {
    let envelope: GroupInvitationEnvelope

    private enum CodingKeys: String, CodingKey {
        case envelope = "_0"
    }
}

private struct CancellationTargets {
    let late: GroupInvitationCancellation.Target
    let staged: GroupInvitationCancellation.Target
    let accepted: GroupInvitationCancellation.Target
}

private struct InvitationsToCancel {
    let late: (groupID: UUID, envelope: GroupInvitationEnvelope)
    let staged: (groupID: UUID, envelope: GroupInvitationEnvelope)
    let accepted: (groupID: UUID, envelope: GroupInvitationEnvelope)
}

private final class NearbyCancellationReceipts: Sendable {
    let values = Mutex<[GroupInvitationCancellationReceipt]>([])
}
