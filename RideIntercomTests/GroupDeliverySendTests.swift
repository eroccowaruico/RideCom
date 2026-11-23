import CallControl
import Foundation
import Testing

@testable import RideIntercom

extension GroupDeliveryFlowTests {
    @Test func aRateLimitedRetryDoesNotDelayANewInvitation() async throws {
        let author = GroupDeliveryTestIdentity("priority-author")
        let firstRecipient = GroupDeliveryTestIdentity("priority-first")
        let secondRecipient = GroupDeliveryTestIdentity("priority-second")
        defer {
            author.remove()
            firstRecipient.remove()
            secondRecipient.remove()
        }
        try author.authorizeFixture(userID: String(repeating: "a", count: 64))
        try firstRecipient.authorizeFixture(userID: String(repeating: "b", count: 64))
        try secondRecipient.authorizeFixture(userID: String(repeating: "c", count: 64))
        let sender = try author.harness(knowing: [firstRecipient, secondRecipient]).viewModel
        GroupDeliveryHTTPStub.reset()
        defer {
            sender.stopGroupDeliverySync()
            sender.disconnect()
            GroupDeliveryHTTPStub.reset()
        }
        try allowGroupDeliveryRequests(from: author)
        for recipient in [firstRecipient, secondRecipient] {
            try grantGroupInvitationPermission(on: sender, recipient: recipient, sender: author)
        }
        let client = InternetAccountClient(session: GroupDeliveryHTTPStub.makeSession())
        let oldGroup = UUID(), newGroup = UUID()
        sender.groupDeliveryClient = nil
        try #require(sender.createTalkGroup(name: "Already queued", userIDs: [firstRecipient.personID], id: oldGroup))
        sender.groupDeliveryClient = client
        await sender.synchronizeGroupDeliveries()
        try #require(sender.groupRepository.groupDeliveries.first?.state == .queued)

        sender.groupDeliveryClient = nil
        try #require(sender.createTalkGroup(name: "New invitation", userIDs: [secondRecipient.personID], id: newGroup))
        GroupDeliveryHTTPStub.rejectedRecipientID = try firstRecipient.principal.userID
        GroupDeliveryHTTPStub.submitRejectionStatus = 429
        let submissionsBeforeSync = GroupDeliveryHTTPStub.submitted.count
        sender.groupDeliveryClient = client
        await sender.synchronizeGroupDeliveries()

        let deliveries = sender.groupRepository.groupDeliveries
        let newDelivery = try #require(deliveries.first(where: { $0.groupID == newGroup }))
        let oldDelivery = try #require(deliveries.first(where: { $0.groupID == oldGroup }))
        #expect(newDelivery.state == .queued)
        #expect(oldDelivery.state == .queued)
        let submittedIDs = try GroupDeliveryHTTPStub.submitted.dropFirst(submissionsBeforeSync).map { packet in
            let data = try #require(Data(base64Encoded: packet))
            return try JSONDecoder().decode(GroupInvitationEnvelope.self, from: data).id
        }
        #expect(submittedIDs == [newDelivery.id, oldDelivery.id])
    }

    @Test(arguments: [403, 401, 429, 503])
    func aRecipientRejectionDoesNotBlockOtherPeopleButASharedFailureStopsThePass(status: Int) async throws {
        let author = GroupDeliveryTestIdentity("rejection-author")
        let firstRecipient = GroupDeliveryTestIdentity("rejection-first")
        let secondRecipient = GroupDeliveryTestIdentity("rejection-second")
        defer {
            author.remove()
            firstRecipient.remove()
            secondRecipient.remove()
        }
        try author.authorizeFixture(userID: String(repeating: "a", count: 64))
        try firstRecipient.authorizeFixture(userID: String(repeating: "b", count: 64))
        try secondRecipient.authorizeFixture(userID: String(repeating: "c", count: 64))
        let harness = try author.harness(knowing: [firstRecipient, secondRecipient])
        defer {
            harness.viewModel.stopGroupDeliverySync()
            harness.viewModel.disconnect()
        }
        harness.viewModel.groupDeliveryClient = nil
        GroupDeliveryHTTPStub.reset()
        GroupDeliveryHTTPStub.users = [
            try #require(try author.store.notificationAccess(memberID: author.memberID)).accessToken:
                try author.principal.userID
        ]
        for peer in [firstRecipient, secondRecipient] {
            try grantGroupInvitationPermission(on: harness.viewModel, recipient: peer, sender: author)
        }
        #expect(
            harness.viewModel.createTalkGroup(
                name: "Independent recipients", userIDs: [firstRecipient.personID, secondRecipient.personID]))
        let first = try #require(harness.viewModel.groupRepository.groupDeliveries.first)
        GroupDeliveryHTTPStub.rejectedRecipientID = first.recipient.userID
        GroupDeliveryHTTPStub.submitRejectionStatus = status
        harness.viewModel.groupDeliveryClient = .init(session: GroupDeliveryHTTPStub.makeSession())
        await harness.viewModel.synchronizeGroupDeliveries()
        let records = harness.viewModel.groupRepository.groupDeliveries
        #expect(
            records.first(where: { $0.id == first.id })?.state == .pending, "A rejected recipient stays recoverable")
        #expect(GroupDeliveryHTTPStub.submitted.count == (status == 403 ? 2 : 1))
        #expect(records.filter { $0.id != first.id }.allSatisfy { $0.state == (status == 403 ? .queued : .pending) })
    }

    @Test(arguments: [false, true])
    func removedMemberIsNotSentAnInvitationAfterExpiryOrDuringAnotherDelivery(duringDelivery: Bool) async throws {
        let authorDevice = GroupDeliveryTestIdentity("removing-author")
        let recipientDevice = GroupDeliveryTestIdentity("removed-recipient")
        defer {
            authorDevice.remove()
            recipientDevice.remove()
        }
        try authorDevice.authorizeFixture(userID: String(repeating: "a", count: 64))
        try recipientDevice.authorizeFixture(userID: String(repeating: "b", count: 64))
        let harness = try authorDevice.harness(knowing: [recipientDevice])
        let model = harness.viewModel
        defer {
            model.stopGroupDeliverySync()
            model.disconnect()
            GroupDeliveryHTTPStub.reset()
        }
        GroupDeliveryHTTPStub.reset()
        let access = try #require(try authorDevice.store.notificationAccess(memberID: authorDevice.memberID))
        GroupDeliveryHTTPStub.users = [access.accessToken: try authorDevice.principal.userID]
        try grantGroupInvitationPermission(on: model, recipient: recipientDevice, sender: authorDevice)
        model.groupDeliveryClient = nil
        #expect(model.createTalkGroup(name: "Continue sending", userIDs: [recipientDevice.personID]))
        #expect(model.createTalkGroup(name: "Remove before sending", userIDs: [recipientDevice.personID]))
        let queuedRecords = model.groupRepository.groupDeliveries
        let unaffected = try #require(queuedRecords.first)
        let removed = try #require(queuedRecords.last)
        #expect(unaffected.id != removed.id && removed.credentialReference == nil)
        model.groupDeliveryClient = .init(session: GroupDeliveryHTTPStub.makeSession())
        try await removeRecipientDuringDelivery(
            from: model, memberID: recipientDevice.memberID, record: removed, duringDelivery: duringDelivery
        )
        #expect(model.groupStorageIssue == nil)
        #expect(model.groupRepository.groupDeliveries.map(\.id) == [unaffected.id])
        #expect(model.groupRepository.groupDeliveries.first?.state == .queued)
        let submittedIDs = try GroupDeliveryHTTPStub.submitted.map { packet in
            let data = try #require(Data(base64Encoded: packet))
            return try JSONDecoder().decode(GroupInvitationEnvelope.self, from: data).id
        }
        let expectedIDs: Set<UUID> = [unaffected.id]
        #expect(Set(submittedIDs) == expectedIDs)
        #expect(GroupDeliveryHTTPStub.items[removed.id.uuidString.lowercased()] == nil)
    }

    private func removeRecipientDuringDelivery(
        from model: IntercomViewModel, memberID: String, record removed: GroupDeliveryRecord, duringDelivery: Bool
    ) async throws {
        if duringDelivery {
            GroupDeliveryHTTPStub.onQueued = { model.removeMember(memberID, from: removed.groupID) }
            model.requestGroupDeliverySync()
        } else {
            var expire: (@MainActor () -> Void)?
            model.beginGroupDeliveryBackgroundTime = { onExpiration in
                expire = onExpiration
                return {}
            }
            model.removeMember(memberID, from: removed.groupID)
            let endBackgroundTime = try #require(expire)
            endBackgroundTime()
            #expect(GroupDeliveryHTTPStub.submitted.isEmpty)
            #expect(model.groupRepository.groupDeliveries.first(where: { $0.id == removed.id })?.state == .cancelled)
            model.requestGroupDeliverySync()
        }
        _ = await model.groupDeliveryTask?.value
    }

    @Test(arguments: [false, true])
    func anOlderSendFailureDoesNotLeaveARemovedMembersInvitationAvailable(backgroundRefresh: Bool) async throws {
        let author = GroupDeliveryTestIdentity("cancellation-author")
        let waiting = GroupDeliveryTestIdentity("waiting-recipient")
        let removed = GroupDeliveryTestIdentity("removed-recipient")
        defer {
            author.remove()
            waiting.remove()
            removed.remove()
        }
        try author.authorizeFixture(userID: String(repeating: "a", count: 64))
        try waiting.authorizeFixture(userID: String(repeating: "b", count: 64))
        try removed.authorizeFixture(userID: String(repeating: "c", count: 64))
        let sender = try author.harness(knowing: [waiting, removed]).viewModel
        let receiver = try removed.harness(knowing: [author]).viewModel
        GroupDeliveryHTTPStub.reset()
        defer {
            sender.stopGroupDeliverySync()
            receiver.stopGroupDeliverySync()
            sender.disconnect()
            receiver.disconnect()
            GroupDeliveryHTTPStub.reset()
        }
        let client = InternetAccountClient(session: GroupDeliveryHTTPStub.makeSession())
        try allowGroupDeliveryRequests(from: author, removed)

        let waitingID = UUID()
        let removedID = UUID()
        #expect(sender.createTalkGroup(name: "Waiting for permission", userIDs: [waiting.personID], id: waitingID))
        #expect(sender.createTalkGroup(name: "Invitation to cancel", userIDs: [removed.personID], id: removedID))
        try grantGroupInvitationPermission(on: sender, recipient: removed, sender: author)
        sender.groupDeliveryClient = client
        await sender.synchronizeGroupDeliveries()
        let records = sender.groupRepository.groupDeliveries
        let pending = try #require(records.first { $0.groupID == waitingID && $0.state == .pending })
        let queued = try #require(records.first { $0.groupID == removedID && $0.state == .queued })

        try grantGroupInvitationPermission(on: sender, recipient: waiting, sender: author)
        GroupDeliveryHTTPStub.failNextSubmit = true
        if backgroundRefresh { sender.groupDeliveryClient = nil }
        #expect(sender.removeMember(removed.memberID, from: removedID))
        if backgroundRefresh {
            sender.groupDeliveryClient = client
            try await expectSavedGroupBackgroundRefresh(sender, completes: false)
        } else {
            await sender.synchronizeGroupDeliveries()
        }
        #expect(sender.groupRepository.groupDeliveries.map(\.id) == [pending.id])
        #expect(sender.groupRepository.groupDeliveries.first?.state == .pending)
        #expect(GroupDeliveryHTTPStub.items[queued.id.uuidString.lowercased()]?["status"] as? String == "cancelled")
        #expect(!GroupDeliveryHTTPStub.failNextSubmit, "The unrelated POST was attempted and rejected")

        receiver.groupDeliveryClient = client
        await receiver.synchronizeGroupDeliveries()
        #expect(!receiver.groups.contains { $0.id == removedID })
    }

    enum GroupDeliveryInterruption: CaseIterable {
        case signOut, backgroundSignOut, backgroundExpiration
    }

    @Test(arguments: GroupDeliveryInterruption.allCases)
    func aLateResponseCannotCommitAfterTheSyncIsInterrupted(interruption: GroupDeliveryInterruption) async throws {
        let authorDevice = GroupDeliveryTestIdentity("late-author")
        let recipientDevice = GroupDeliveryTestIdentity("late-recipient")
        defer {
            authorDevice.remove()
            recipientDevice.remove()
        }
        try authorDevice.authorizeFixture(userID: String(repeating: "a", count: 64))
        try recipientDevice.authorizeFixture(userID: String(repeating: "b", count: 64))
        let harness = try authorDevice.harness(knowing: [recipientDevice])
        let model = harness.viewModel
        defer { model.stopGroupDeliverySync(); model.disconnect(); GroupDeliveryHTTPStub.reset() }
        GroupDeliveryHTTPStub.reset()
        GroupDeliveryHTTPStub.users = [
            try #require(try authorDevice.store.notificationAccess(memberID: authorDevice.memberID)).accessToken:
                try authorDevice.principal.userID
        ]
        try grantGroupInvitationPermission(on: model, recipient: recipientDevice, sender: authorDevice)
        model.groupDeliveryClient = nil
        try #require(model.createTalkGroup(name: "No late commit", userIDs: [recipientDevice.personID]))
        model.groupDeliveryClient = .init(session: GroupDeliveryHTTPStub.makeSession())
        var refresh: Task<Bool, Never>?
        GroupDeliveryHTTPStub.onQueued = {
            if interruption == .backgroundExpiration { refresh?.cancel() } else { model.accountSession.signOut() }
        }

        if interruption == .signOut {
            await model.synchronizeGroupDeliveries()
        } else {
            let owner = AppCallOwner(account: model.accountSession, viewModel: model)
            model.setGroupDeliveryForeground(false)
            try #require(owner.needsSavedCommunicationBackgroundRefresh)
            let task = Task { await owner.refreshSavedCommunicationInBackground() }
            refresh = task
            #expect(!(await task.value))
        }
        #expect(GroupDeliveryHTTPStub.submitted.count == 1)
        #expect(model.hasCurrentAccountAccess == (interruption == .backgroundExpiration))
        #expect(model.groupRepository.groupDeliveries.first?.state == .pending)
    }

    @Test func aLocalWriteFailureAfterRemoteAcceptanceRemainsRecoverable() async throws {
        let authorDevice = GroupDeliveryTestIdentity("write-author")
        let recipientDevice = GroupDeliveryTestIdentity("write-recipient")
        defer {
            authorDevice.remove()
            recipientDevice.remove()
        }
        try authorDevice.authorizeFixture(userID: String(repeating: "a", count: 64))
        try recipientDevice.authorizeFixture(userID: String(repeating: "b", count: 64))
        let harness = try authorDevice.harness(knowing: [recipientDevice])
        defer {
            harness.viewModel.stopGroupDeliverySync()
            harness.viewModel.disconnect()
        }
        GroupDeliveryHTTPStub.reset()
        GroupDeliveryHTTPStub.users = [
            try #require(try authorDevice.store.notificationAccess(memberID: authorDevice.memberID)).accessToken:
                try authorDevice.principal.userID
        ]
        harness.viewModel.groupDeliveryClient = .init(session: GroupDeliveryHTTPStub.makeSession())
        try grantGroupInvitationPermission(on: harness.viewModel, recipient: recipientDevice, sender: authorDevice)
        GroupDeliveryHTTPStub.onQueued = { harness.groupStore.failSaving = true }
        #expect(harness.viewModel.createTalkGroup(name: "Saved before delivery", userIDs: [recipientDevice.personID]))
        await harness.viewModel.synchronizeGroupDeliveries()
        #expect(
            harness.viewModel.groupStorageIssue != nil,
            "A failed manifest write must expose the existing reload recovery")
        #expect(harness.viewModel.groupRepository.groupDeliveries.first?.state == .pending)
        harness.groupStore.failSaving = false
        GroupDeliveryHTTPStub.onQueued = nil
        harness.viewModel.disconnect()
        harness.viewModel.reloadSavedGroups()
        await harness.viewModel.synchronizeGroupDeliveries()
        #expect(harness.viewModel.groupRepository.groupDeliveries.first?.state == .queued)
        #expect(harness.viewModel.groups.count == 1 && harness.viewModel.groupStorageIssue == nil)
        #expect(
            harness.viewModel.createTalkGroup(
                name: "Saved before delivery", userIDs: [recipientDevice.personID],
                id: try #require(harness.viewModel.groups.first).id))
        #expect(harness.viewModel.groups.count == 1 && harness.viewModel.groupRepository.groupDeliveries.count == 1)
    }
}
