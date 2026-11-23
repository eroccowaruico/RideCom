import CallControl
import CryptoKit
import Foundation
import Testing

@testable import RideIntercom

extension GroupDeliveryFlowTests {
    @Test func unreadableNotificationPermissionsDoNotFetchAnInbox() async throws {
        let recipientDevice = GroupDeliveryTestIdentity("unreadable-recipient")
        let authorDevice = GroupDeliveryTestIdentity("known-sender")
        defer {
            recipientDevice.remove()
            authorDevice.remove()
        }
        try recipientDevice.authorizeFixture(userID: String(repeating: "a", count: 64))
        try authorDevice.authorizeFixture(userID: String(repeating: "b", count: 64))
        try recipientDevice.keychain.saveSecret(
            "unreadable permissions", service: recipientDevice.namespace + ".InternetConnection",
            account: "notification-permissions")
        let harness = try recipientDevice.harness(knowing: [authorDevice])
        defer {
            harness.viewModel.stopGroupDeliverySync()
            harness.viewModel.disconnect()
        }
        GroupDeliveryHTTPStub.reset()
        harness.viewModel.groupDeliveryClient = .init(session: GroupDeliveryHTTPStub.makeSession())
        #expect(!harness.viewModel.notifications.canUseNotifications)
        await harness.viewModel.synchronizeGroupDeliveries()
        #expect(GroupDeliveryHTTPStub.requestCount == 0)
    }
    @Test(arguments: [false, true])
    func automaticDeliveryRetriesTheSamePacketAndARepeatedReceiptDoesNotRecreateADeletedGroup(
        recoversDuringPass: Bool
    ) async throws {
        let authorDevice = GroupDeliveryTestIdentity("delivery-author")
        let recipientDevice = GroupDeliveryTestIdentity("delivery-recipient")
        defer {
            authorDevice.remove()
            recipientDevice.remove()
        }
        try authorDevice.authorizeFixture(userID: String(repeating: "a", count: 64))
        try recipientDevice.authorizeFixture(userID: String(repeating: "b", count: 64))
        let sender = try authorDevice.harness(knowing: [recipientDevice]).viewModel
        let receiver = try recipientDevice.harness(knowing: [authorDevice]).viewModel
        defer {
            sender.stopGroupDeliverySync()
            receiver.stopGroupDeliverySync()
            sender.disconnect()
            receiver.disconnect()
        }
        let client = InternetAccountClient(session: GroupDeliveryHTTPStub.makeSession())
        GroupDeliveryHTTPStub.reset()
        try allowGroupDeliveryRequests(from: authorDevice, recipientDevice)
        sender.groupDeliveryClient = client
        receiver.groupDeliveryClient = client
        try grantGroupInvitationPermission(on: sender, recipient: recipientDevice, sender: authorDevice)
        #expect(receiver.createTalkGroup(name: "Keep this conversation"))
        await receiver.synchronizeGroupDeliveries()
        let receiverCall = receiver.currentCallReference
        let queued = try await checkAutomaticDeliveryRetry(
            on: sender, recipientID: recipientDevice.personID, recoversDuringPass: recoversDuringPass
        )
        try await checkRepeatedInboxReceipt(
            groupID: queued.groupID, sender: sender, receiver: receiver, recipientDevice: recipientDevice,
            originalCalls: (sender: queued.call, receiver: receiverCall)
        )
        try await checkInvitationNoticeTargetsRecipient(
            receiver, receiverCall: receiverCall,
            recipientID: recipientDevice.principal.userID, authorID: authorDevice.principal.userID
        )
    }

    private func checkAutomaticDeliveryRetry(
        on sender: IntercomViewModel, recipientID: UUID, recoversDuringPass: Bool
    ) async throws -> (groupID: UUID, call: CallReference) {
        let beforeRecovery = GroupDeliveryHTTPStub.requestCount
        sender.groupDeliveryNetworkPathChanged(isAvailable: true)
        sender.groupDeliveryNetworkPathChanged(isAvailable: false)
        sender.groupDeliveryNetworkPathChanged(isAvailable: true)
        _ = await sender.groupDeliveryTask?.value
        #expect(GroupDeliveryHTTPStub.requestCount == beforeRecovery)
        sender.groupDeliveryNetworkPathChanged(isAvailable: false)
        if recoversDuringPass {
            GroupDeliveryHTTPStub.beforeReturningInbox = {
                sender.groupDeliveryNetworkPathChanged(isAvailable: true)
                sender.groupDeliveryNetworkPathChanged(isAvailable: true)
            }
        }
        GroupDeliveryHTTPStub.failNextSubmit = true
        #expect(sender.createTalkGroup(name: "Automatically delivered", userIDs: [recipientID]))
        let group = try #require(sender.groups.first)
        let senderCall = sender.currentCallReference
        _ = await sender.groupDeliveryTask?.value
        if !recoversDuringPass {
            #expect(sender.groupRepository.groupDeliveries.first?.state == .pending)
            sender.groupDeliveryNetworkPathChanged(isAvailable: true)
            sender.groupDeliveryNetworkPathChanged(isAvailable: true)
            _ = await sender.groupDeliveryTask?.value
        }
        try #require(sender.groupRepository.groupDeliveries.first?.state == .queued)
        #expect(
            GroupDeliveryHTTPStub.submitted.count == 2 && Set(GroupDeliveryHTTPStub.submitted).count == 1,
            "Retries use the exact same encrypted envelope")
        return (groupID: group.id, call: senderCall)
    }

    private func checkRepeatedInboxReceipt(
        groupID: UUID,
        sender: IntercomViewModel,
        receiver: IntercomViewModel,
        recipientDevice: GroupDeliveryTestIdentity,
        originalCalls: (sender: CallReference, receiver: CallReference)
    ) async throws {
        let senderCall = originalCalls.sender
        let receiverCall = originalCalls.receiver
        GroupDeliveryHTTPStub.failNextAcknowledgement = true
        await receiver.synchronizeGroupDeliveries()
        #expect(!receiver.groups.contains { $0.id == groupID })
        #expect(receiver.groupRepository.groupDeliveries.first?.state == .pending)
        await receiver.synchronizeGroupDeliveries()
        #expect(receiver.groups.contains { $0.id == groupID })
        #expect(receiver.currentCallReference == receiverCall && sender.currentCallReference == senderCall)
        #expect(
            try receiver.groupRepository.credential(for: groupID)
                == sender.groupRepository.credential(for: groupID))
        receiver.deleteGroup(groupID)
        await receiver.synchronizeGroupDeliveries()
        #expect(!receiver.groups.contains { $0.id == groupID })
        await sender.synchronizeGroupDeliveries()
        #expect(sender.groupRepository.groupDeliveries.first?.state == .received)
        #expect(sender.groupRepository.groupDeliveries.first?.credentialReference == nil)
        #expect(receiver.savedRemoteUsers.count == 1 && receiver.currentCallReference == receiverCall)
        #expect(
            sender.groupInvitationDeliveryState(for: try recipientDevice.savedUser(), in: groupID)
                == .received)
    }

    private func checkInvitationNoticeTargetsRecipient(
        _ receiver: IntercomViewModel, receiverCall: CallReference, recipientID: String, authorID: String
    ) async throws {
        let owner = AppCallOwner(account: receiver.accountSession, viewModel: receiver)
        let notice = try #require(
            GroupInvitationTap(payload: [
                "version": 1, "kind": "groupInvitation", "requestID": UUID().uuidString,
                "recipientID": recipientID
            ]))
        #expect(await owner.respondToGroupInvitation(notice))
        #expect(
            receiver.currentCallReference == receiverCall && owner.callPresentationID != nil
                && owner.groupsPresentationID == nil)
        let unrelated = try #require(
            GroupInvitationTap(payload: [
                "version": 1, "kind": "groupInvitation", "requestID": UUID().uuidString,
                "recipientID": authorID
            ]))
        #expect(!(await owner.respondToGroupInvitation(unrelated)))
    }

    @Test(arguments: [false, true])
    func oneForegroundPassReceivesMoreThanEightDifferentGroupInvitations(recoversNetwork: Bool) async throws {
        let authorDevice = GroupDeliveryTestIdentity("batch-author")
        let recipientDevice = GroupDeliveryTestIdentity("batch-recipient")
        defer {
            authorDevice.remove()
            recipientDevice.remove()
        }
        try authorDevice.authorizeFixture(userID: String(repeating: "a", count: 64))
        try recipientDevice.authorizeFixture(userID: String(repeating: "b", count: 64))
        let left = try authorDevice.harness(knowing: [recipientDevice])
        let right = try recipientDevice.harness(knowing: [authorDevice])
        defer {
            left.viewModel.stopGroupDeliverySync()
            right.viewModel.stopGroupDeliverySync()
            left.viewModel.disconnect()
            right.viewModel.disconnect()
        }
        let client = InternetAccountClient(session: GroupDeliveryHTTPStub.makeSession())
        GroupDeliveryHTTPStub.reset()
        GroupDeliveryHTTPStub.users = [
            try #require(try authorDevice.store.notificationAccess(memberID: authorDevice.memberID)).accessToken:
                try authorDevice.principal.userID,
            try #require(try recipientDevice.store.notificationAccess(memberID: recipientDevice.memberID)).accessToken:
                try recipientDevice.principal.userID
        ]
        try grantGroupInvitationPermission(on: left.viewModel, recipient: recipientDevice, sender: authorDevice)
        left.viewModel.groupDeliveryClient = nil
        var expected = Set<UUID>()
        for index in 0..<9 {
            let id = UUID()
            expected.insert(id)
            #expect(
                left.viewModel.createTalkGroup(
                    name: "Batch group \(index)", userIDs: [recipientDevice.personID], id: id))
        }
        left.viewModel.groupDeliveryClient = client
        right.viewModel.groupDeliveryClient = client
        await left.viewModel.synchronizeGroupDeliveries()
        #expect(GroupDeliveryHTTPStub.items.count == 9)
        let currentCall = right.viewModel.currentCallReference
        try await receiveInvitations(on: right.viewModel, afterRecovery: recoversNetwork)
        #expect(
            expected.isSubset(of: Set(right.viewModel.groups.map(\.id))),
            "All queued groups must arrive without a second foreground event")
        #expect(right.viewModel.currentCallReference == currentCall && !right.viewModel.hasAnyActiveGroupConnection)
        #expect(
            right.viewModel.groupRepository.groupDeliveries.filter {
                $0.direction == .incoming && $0.state == .received
            }.count == 9)
        await left.viewModel.synchronizeGroupDeliveries()
        #expect(left.viewModel.groupRepository.groupDeliveries.allSatisfy { $0.state == .received })
    }

    private func receiveInvitations(on recipient: IntercomViewModel, afterRecovery: Bool) async throws {
        guard afterRecovery else {
            await recipient.synchronizeGroupDeliveries()
            return
        }
        #expect(recipient.groupRepository.groupDeliveries.isEmpty)
        recipient.groupDeliveryNetworkPathChanged(isAvailable: false)
        recipient.groupDeliveryNetworkPathChanged(isAvailable: true)
        #expect(recipient.groupDeliveryTask == nil)
        recipient.setGroupDeliveryForeground(true)
        recipient.groupDeliveryNetworkPathChanged(isAvailable: true)
        #expect(recipient.groupDeliveryTask == nil)
        recipient.groupDeliveryNetworkPathChanged(isAvailable: false)
        recipient.groupDeliveryNetworkPathChanged(isAvailable: true)
        let recovered = try #require(recipient.groupDeliveryTask)
        recipient.groupDeliveryNetworkPathChanged(isAvailable: true)
        _ = await recovered.value
    }

    @Test func anInvalidInboxPacketWhoseDiscardFailsWaitsForTheNextLifecycleEvent() async throws {
        let recipientDevice = GroupDeliveryTestIdentity("discard-recipient")
        let authorDevice = GroupDeliveryTestIdentity("discard-sender")
        defer {
            recipientDevice.remove()
            authorDevice.remove()
        }
        try recipientDevice.authorizeFixture(userID: String(repeating: "a", count: 64))
        try authorDevice.authorizeFixture(userID: String(repeating: "b", count: 64))
        let harness = try recipientDevice.harness(knowing: [authorDevice])
        defer {
            harness.viewModel.stopGroupDeliverySync()
            harness.viewModel.disconnect()
        }
        GroupDeliveryHTTPStub.reset()
        GroupDeliveryHTTPStub.users = [
            try #require(try recipientDevice.store.notificationAccess(memberID: recipientDevice.memberID)).accessToken:
                try recipientDevice.principal.userID
        ]
        let id = UUID().uuidString.lowercased()
        let initialGroups = harness.viewModel.groups.map(\.id)
        GroupDeliveryHTTPStub.items[id] = [
            "requestID": id, "expiresAt": Date().addingTimeInterval(3600).timeIntervalSince1970 * 1000,
            "status": "queued", "senderUserID": try authorDevice.principal.userID,
            "recipientID": try recipientDevice.principal.userID,
            "recipientKey": try recipientDevice.signer.publicKey, "envelope": "invalid-base64"
        ]
        GroupDeliveryHTTPStub.failNextAcknowledgement = true
        harness.viewModel.groupDeliveryClient = .init(session: GroupDeliveryHTTPStub.makeSession())
        await harness.viewModel.synchronizeGroupDeliveries()
        #expect(
            GroupDeliveryHTTPStub.requestCount == 2,
            "GET and one failed discard, without re-fetching the same invalid packet")
        #expect(harness.viewModel.groups.map(\.id) == initialGroups)
        await harness.viewModel.synchronizeGroupDeliveries()
        #expect(
            GroupDeliveryHTTPStub.requestCount == 6,
            "A later pass retries discard before checking the empty inbox and additional invitations")
    }

    @Test(arguments: [false, true])
    func openingAnInvitationWhileAnOlderEmptyInboxResponseIsPendingReceivesTheGroup(
        expiresAfterReceipt: Bool
    ) async throws {
        let author = GroupDeliveryTestIdentity("notice-author")
        let recipient = GroupDeliveryTestIdentity("notice-recipient")
        defer {
            author.remove()
            recipient.remove()
        }
        try author.authorizeFixture(userID: String(repeating: "a", count: 64))
        try recipient.authorizeFixture(userID: String(repeating: "b", count: 64))
        let sender = try author.harness(knowing: [recipient]).viewModel
        let receiver = try recipient.harness(knowing: [author]).viewModel
        let owner = AppCallOwner(account: receiver.accountSession, viewModel: receiver)
        GroupDeliveryHTTPStub.reset()
        var resumeInbox: CheckedContinuation<Void, Never>?
        defer {
            resumeInbox?.resume()
            sender.stopGroupDeliverySync()
            receiver.stopGroupDeliverySync()
            sender.disconnect()
            receiver.disconnect()
            GroupDeliveryHTTPStub.reset()
        }
        let client = InternetAccountClient(session: GroupDeliveryHTTPStub.makeSession())
        try allowGroupDeliveryRequests(from: author, recipient)
        try grantGroupInvitationPermission(on: sender, recipient: recipient, sender: author)
        sender.groupDeliveryClient = client
        receiver.groupDeliveryClient = client
        GroupDeliveryHTTPStub.beforeReturningInbox = {
            await withCheckedContinuation { resumeInbox = $0 }
        }
        receiver.requestGroupDeliverySync()
        await AppTestSupport.waitUntil { resumeInbox != nil }
        let staleResponse = try #require(resumeInbox)

        let invitation = try await queueInvitationWhileInboxWaits(on: sender, to: recipient)
        try await checkInvitationTapWhileInboxWaits(
            invitation, receiver: receiver, owner: owner, expiresAfterReceipt: expiresAfterReceipt
        ) {
            resumeInbox = nil
            staleResponse.resume()
        }
    }

    private func queueInvitationWhileInboxWaits(
        on sender: IntercomViewModel, to recipient: GroupDeliveryTestIdentity
    ) async throws -> QueuedInvitationNotice {
        let groupID = UUID()
        #expect(sender.createTalkGroup(name: "Recently delivered", userIDs: [recipient.personID], id: groupID))
        await sender.synchronizeGroupDeliveries()
        let delivery = try #require(sender.groupRepository.groupDeliveries.first)
        #expect(delivery.state == .queued)
        let notice = try #require(
            GroupInvitationTap(payload: [
                "version": 1, "kind": "groupInvitation",
                "requestID": delivery.noticeID.uuidString, "recipientID": try recipient.principal.userID
            ]))
        return QueuedInvitationNotice(groupID: groupID, delivery: delivery, notice: notice)
    }

    private func checkInvitationTapWhileInboxWaits(
        _ invitation: QueuedInvitationNotice,
        receiver: IntercomViewModel,
        owner: AppCallOwner,
        expiresAfterReceipt: Bool,
        resumeOlderResponse: @escaping @MainActor () -> Void
    ) async throws {
        var started = 0
        var ended = 0
        var expire: (@MainActor () -> Void)?
        receiver.beginGroupDeliveryBackgroundTime = { expiration in
            started += 1
            expire = expiration
            return { ended += 1 }
        }
        GroupDeliveryHTTPStub.onAcknowledged = {
            #expect(started == 1 && ended == 0)
            if expiresAfterReceipt { expire?() }
        }

        // The tap and the older request join the same sync task on the main actor.
        Task { @MainActor in resumeOlderResponse() }
        #expect(await owner.respondToGroupInvitation(invitation.notice))
        #expect(started == 1 && ended == 1)
        #expect(
            GroupDeliveryHTTPStub.items[invitation.delivery.id.uuidString.lowercased()]?["status"] as? String
                == "received")
        if expiresAfterReceipt {
            #expect(!receiver.groups.contains { $0.id == invitation.groupID })
            #expect(receiver.groupRepository.groupDeliveries.first?.id == invitation.delivery.id)
            #expect(receiver.groupRepository.groupDeliveries.first?.state == .pending)
            await receiver.synchronizeGroupDeliveries()
            #expect(started == 1 && ended == 1)
        }
        #expect(receiver.groups.filter { $0.id == invitation.groupID }.count == 1)
        #expect(
            owner.groupsPresentationID != nil && owner.callPresentationID == nil
                && !receiver.hasAnyActiveGroupConnection)
    }
}

private struct QueuedInvitationNotice {
    let groupID: UUID
    let delivery: GroupDeliveryRecord
    let notice: GroupInvitationTap
}
