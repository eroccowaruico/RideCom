import RTC
import Synchronization
#if os(macOS)
import Foundation
import Testing
@testable import RideIntercom

extension GroupDeliveryWorkerTests {
    enum ContactMailboxCase: CaseIterable { case group, contact, renewedAuthor, background, scheduledRefresh }

    @Test(.timeLimit(.minutes(1)))
    func backgroundAcceptanceCompletesDuringAnExistingBackgroundRefresh() async throws {
        try await withWorker {
            let author = GroupDeliveryTestIdentity("handoff-author")
            let recipient = GroupDeliveryTestIdentity("handoff-recipient")
            defer { author.remove(); recipient.remove() }
            try await register(author); try await register(recipient)
            let left = try author.harness(knowing: [], onDisk: true).viewModel
            let right = try recipient.harness(knowing: [], onDisk: true).viewModel
            defer { left.stopGroupDeliverySync(); right.stopGroupDeliverySync(); left.disconnect(); right.disconnect() }
            let calls = try startMailboxCalls(sender: left, recipient: right)
            let draft = GroupInvitationDraft(name: "Friend", suggestedName: "Rider")
            let (share, _) = try shareContactInvitation(from: left, invited: calls.invited, draft: draft,
                                                       includesGroup: true)
            let session = workerSession()
            let client = InternetAccountClient(session: session)
            let transfer = RecordingBackgroundInvitationTransfer()
            right.invitationBackgroundTransfer = transfer
            right.groupDeliveryClient = client
            try #require(right.previewContactInvitation(share.url))
            try #require(right.acceptPresentedContactInvitation())
            await right.invitationInternetReplyWindow?.task?.value
            try #require(right.contactInvitationRecord(share.id)?.state == .pending)
            left.groupDeliveryClient = client
            try await completeBackgroundAcceptanceWhileRefreshing(
                share.id, sender: left, recipient: right, transfer: transfer, session: session)
            #expect(right.contactInvitationRecord(share.id)?.state == .delivered)
            #expect(!right.pendingContactInvitations.contains { $0.id == share.id })
            #expect(left.activeGroupID == calls.author && right.activeGroupID == calls.recipient)
            try verifyMailboxGroup(calls.invited, sender: left, recipient: right, recipientID: recipient.memberID)
        }
    }

    private func completeBackgroundAcceptanceWhileRefreshing(
        _ id: UUID, sender left: IntercomViewModel, recipient right: IntercomViewModel,
        transfer: RecordingBackgroundInvitationTransfer, session: URLSession
    ) async throws {
        let key = try #require(transfer.enqueued.first)
        let request = try #require(transfer.requests[key])
        let writes = GroupWorkerHTTPBridge.contactAcceptanceWrites.withLock { $0 }
        let gate = ManualAsyncGate()
        GroupWorkerHTTPBridge.holdNextInvitationReceipt.withLock { $0 = gate }
        right.setGroupDeliveryForeground(false)
        let refresh = Task { await right.refreshInvitationRepliesInBackground() }
        defer {
            refresh.cancel()
            GroupWorkerHTTPBridge.holdNextInvitationReceipt.withLock { $0 = nil }
            Task { await gate.release() }
        }
        await gate.waitForEntry()
        let (reply, response) = try await session.data(for: request)
        try #require((response as? HTTPURLResponse)?.statusCode == 200)
        await refreshPersonalInvitationWhileInBackground(left)
        try #require(left.contactInvitationRecord(id)?.internetAcknowledged == true)
        transfer.active.remove(key)
        right.applyBackgroundInvitationResponse(reply, for: key)
        #expect(right.contactInvitationRecord(id)?.internetAcceptanceSubmitted == true)
        await gate.release()
        #expect(await refresh.value)
        #expect(transfer.enqueued.count == 1)
        #expect(GroupWorkerHTTPBridge.contactAcceptanceWrites.withLock { $0 } == writes)
    }

    @Test(.timeLimit(.minutes(1)), arguments: ContactMailboxCase.allCases)
    func contactInvitationCompletesWhileTheTwoAppsConnectAtDifferentTimes(scenario: ContactMailboxCase) async throws {
        try await withWorker {
            let includesGroup = scenario != .contact
            let authorDevice = GroupDeliveryTestIdentity("contact-box-author"),
                recipientDevice = GroupDeliveryTestIdentity("contact-box-recipient")
            defer { authorDevice.remove(); recipientDevice.remove() }
            try await register(authorDevice); try await register(recipientDevice)
            let session = workerSession()
            let client = InternetAccountClient(session: session)
            let left = try authorDevice.harness(knowing: [], onDisk: true).viewModel
            let right = try recipientDevice.harness(knowing: [], onDisk: true).viewModel
            defer { left.stopGroupDeliverySync(); right.stopGroupDeliverySync(); left.disconnect(); right.disconnect() }
            let calls = try startMailboxCalls(sender: left, recipient: right)
            let invited = calls.invited
            let draft = GroupInvitationDraft(name: "Friend", suggestedName: "Rider")
            let (share, personID) = try shareContactInvitation(
                from: left, invited: invited, draft: draft, includesGroup: includesGroup)
            // Renewal keeps the same issuing device but revokes its previous opening permission.
            if scenario == .renewedAuthor { try await register(authorDevice) }

            let transfer = RecordingBackgroundInvitationTransfer()
            if scenario == .background { right.invitationBackgroundTransfer = transfer }
            let acceptanceWrites = GroupWorkerHTTPBridge.contactAcceptanceWrites.withLock { $0 }
            right.groupDeliveryClient = client
            try #require(right.previewContactInvitation(share.url))
            try #require(right.acceptPresentedContactInvitation())
            let pending = try #require(right.contactInvitationRecord(share.id))
            #expect(!right.contactReplyWaitsForCurrentCall(pending))
            #expect(right.isTryingContactReply(share.id))
            right.suspendContactInvitationForBackground()
            await right.invitationInternetReplyWindow?.task?.value
            #expect(right.contactInvitationRecord(share.id)?.state == .pending)
            #expect(left.contactInvitationRecord(share.id)?.state == .pending)
            try await verifyRecipientMailbox(
                scenario, right: right, recipient: recipientDevice, shareID: share.id,
                relay: Relay(session: session, client: client, transfer: transfer, acceptanceWrites: acceptanceWrites))
            right.groupDeliveryClient = nil
            right.groupDeliveryNetworkPathChanged(isAvailable: false)

            await deliverMailboxAcceptance(to: left, from: right, shareID: share.id, scenario: scenario, client: client)
            #expect(left.contactInvitationRecord(share.id)?.state == .confirmed)
            #expect(left.contactInvitationRecord(share.id)?.internetAcknowledged == true)
            #expect(left.contactPerson(personID)?.memberIDs == [recipientDevice.memberID])
            left.groupDeliveryClient = nil

            await receiveMailboxAcknowledgement(on: right, scenario: scenario, client: client)
            #expect(right.contactInvitationRecord(share.id)?.state == .delivered)
            #expect(right.savedRemoteUsers.first?.memberIDs == [authorDevice.memberID])
            if includesGroup {
                try verifyMailboxGroup(invited, sender: left, recipient: right, recipientID: recipientDevice.memberID)
            }
            #expect(left.activeGroupID == calls.author && right.activeGroupID == calls.recipient)
        }
    }

    private struct MailboxCalls {
        let invited: UUID
        let author: UUID
        let recipient: UUID
    }

    private func startMailboxCalls(
        sender left: IntercomViewModel, recipient right: IntercomViewModel
    ) throws -> MailboxCalls {
        for model in [left, right] {
            model.groupDeliveryClient = nil
            model.allowsNearbyGroupDelivery = false
            model.setRTCTransportRoutes([.webRTC])
            model.invitationInternetReplyRetryDelays = []
        }
        let invited = UUID(), authorCall = UUID(), recipientCall = UUID()
        try #require(left.createTalkGroup(name: "Invited group", id: invited))
        try #require(left.createTalkGroup(name: "Author's call", id: authorCall))
        try #require(right.createTalkGroup(name: "Recipient's call", id: recipientCall))
        try #require(left.startCall(to: .group(authorCall), accountAccessID: left.accountAccessID))
        try #require(right.startCall(to: .group(recipientCall), accountAccessID: right.accountAccessID))
        return MailboxCalls(invited: invited, author: authorCall, recipient: recipientCall)
    }

    private struct Relay {
        let session: URLSession
        let client: InternetAccountClient
        let transfer: RecordingBackgroundInvitationTransfer
        let acceptanceWrites: Int
    }

    private func verifyMailboxGroup(
        _ invited: UUID, sender left: IntercomViewModel, recipient right: IntercomViewModel, recipientID: String
    ) throws {
        #expect(
            left.groups.first { $0.id == invited }?.members.contains { $0.id == recipientID }
                == true)
        let sameGroupKey =
            try right.groupRepository.credential(for: invited)
            == left.groupRepository.credential(for: invited)
        #expect(sameGroupKey)
    }

    private func shareContactInvitation(
        from left: IntercomViewModel, invited: UUID, draft: GroupInvitationDraft, includesGroup: Bool
    ) throws -> (PreparedContactInvitationShare, UUID) {
        let personID: UUID
        if includesGroup {
            try #require(
                left.saveGroupInvitations(
                    groupID: invited, creating: false, name: "", selected: [], newPeople: [draft]) == invited)
            personID = draft.id
        } else {
            left.beginContactInvitationPresentation()
            guard case .person(let id) = left.contactInvitationPresentation else {
                throw GroupStorageError.invalidUpdate
            }
            try #require(left.saveContactPerson(id, name: "Friend"))
            personID = id
        }
        let share = try left.prepareContactPersonShare(personID, expectedAccountAccessID: left.accountAccessID)
        left.completeContactInvitationSharing(share)
        return (share, personID)
    }

    private func verifyRecipientMailbox(
        _ scenario: ContactMailboxCase, right: IntercomViewModel, recipient recipientDevice: GroupDeliveryTestIdentity,
        shareID: UUID, relay: Relay
    ) async throws {
        if scenario == .group {
            #expect(GroupWorkerHTTPBridge.contactAcceptanceWrites.withLock { $0 } == relay.acceptanceWrites + 1)
            let reopened = try recipientDevice.harness(knowing: [], onDisk: true).viewModel
            defer { reopened.stopGroupDeliverySync() }
            #expect(reopened.contactInvitationRecord(shareID)?.internetAcceptanceSubmitted == true)
            #expect(reopened.contactInvitationRecord(shareID)?.state == .pending)
            reopened.setRTCTransportRoutes([.webRTC])
            reopened.invitationInternetReplyRetryDelays = []
            reopened.groupDeliveryClient = relay.client
            reopened.requestInvitationInternetReply()
            await reopened.invitationInternetReplyWindow?.task?.value
            #expect(GroupWorkerHTTPBridge.contactAcceptanceWrites.withLock { $0 } == relay.acceptanceWrites + 1)

            reopened.invitationBackgroundTransfer = relay.transfer
            reopened.requestInvitationInternetReply()
            #expect(relay.transfer.enqueued.isEmpty)
            #expect(reopened.contactInvitationRecord(shareID)?.state == .pending)
        }
        if scenario == .renewedAuthor {
            #expect(right.contactInvitationRecord(shareID)?.internetAcceptanceSubmitted != true)
        }
        if scenario == .background {
            let key = try #require(relay.transfer.enqueued.first)
            let queued = relay.transfer.requests[key]
            let request = try #require(queued)
            let (reply, response) = try await relay.session.data(for: request)
            try #require((response as? HTTPURLResponse)?.statusCode == 200)
            relay.transfer.active.remove(key)
            right.applyBackgroundInvitationResponse(reply, for: key)
            await right.invitationInternetReplyWindow?.task?.value
            #expect(right.contactInvitationRecord(shareID)?.internetAcceptanceSubmitted == true)
            #expect(right.contactInvitationRecord(shareID)?.state == .pending)
            #expect(relay.transfer.enqueued.count == 1)
        }
    }

    private func deliverMailboxAcceptance(
        to left: IntercomViewModel, from right: IntercomViewModel, shareID: UUID,
        scenario: ContactMailboxCase, client: InternetAccountClient
    ) async {
        left.groupDeliveryClient = client
        if scenario == .scheduledRefresh {
            await refreshPersonalInvitationWhileInBackground(left)
            return
        }
        left.groupDeliveryNetworkPathChanged(isAvailable: false)
        left.groupDeliveryNetworkPathChanged(isAvailable: true)
        await left.invitationInternetReplyWindow?.task?.value
        if scenario == .renewedAuthor {
            #expect(left.contactInvitationRecord(shareID)?.state == .pending)
            right.groupDeliveryClient = client
            right.groupDeliveryNetworkPathChanged(isAvailable: true)
            await right.invitationInternetReplyWindow?.task?.value
            #expect(right.contactInvitationRecord(shareID)?.state == .pending)
            right.groupDeliveryClient = nil
            right.groupDeliveryNetworkPathChanged(isAvailable: false)
            left.groupDeliveryNetworkPathChanged(isAvailable: false)
            left.groupDeliveryNetworkPathChanged(isAvailable: true)
            await left.invitationInternetReplyWindow?.task?.value
        }
    }

    private func refreshPersonalInvitationWhileInBackground(_ model: IntercomViewModel) async {
        model.setGroupDeliveryForeground(false)
        #expect(!model.notifications.isEnabled)
        #expect(model.invitationInternetReplyWindow == nil)
        let owner = AppCallOwner(account: model.accountSession, viewModel: model)
        #expect(model.needsInvitationReplyBackgroundRefresh)
        #expect(owner.needsSavedCommunicationBackgroundRefresh)
        #expect(await owner.refreshSavedCommunicationInBackground())
        #expect(!model.needsInvitationReplyBackgroundRefresh)
        #expect(model.invitationInternetReplyWindow == nil)
    }

    private func receiveMailboxAcknowledgement(
        on model: IntercomViewModel, scenario: ContactMailboxCase, client: InternetAccountClient
    ) async {
        model.groupDeliveryClient = client
        if scenario == .scheduledRefresh {
            await refreshPersonalInvitationWhileInBackground(model)
            return
        }
        model.groupDeliveryNetworkPathChanged(isAvailable: true)
        await model.invitationInternetReplyWindow?.task?.value
    }
}
#endif
