import CallControl
import Foundation
import Testing

@testable import RideIntercom

extension GroupDeliveryFlowTests {
    @Test(arguments: [false, true])
    func foregroundAfterExpiryRecoversTheConfirmedInvitationOutcome(cancelled: Bool) async throws {
        let authorDevice = GroupDeliveryTestIdentity("expiry-author")
        let recipientDevice = GroupDeliveryTestIdentity("expiry-recipient")
        defer {
            authorDevice.remove()
            recipientDevice.remove()
        }
        let issued = Date()
        var now = issued
        try authorDevice.authorizeFixture(userID: String(repeating: "a", count: 64))
        try recipientDevice.authorizeFixture(userID: String(repeating: "b", count: 64))
        let sender = try authorDevice.harness(knowing: [recipientDevice], onDisk: true, callAccessNow: { now })
            .viewModel
        let receiver = try recipientDevice.harness(knowing: [authorDevice]).viewModel
        sender.allowsNearbyGroupDelivery = false
        receiver.allowsNearbyGroupDelivery = false
        defer {
            sender.stopGroupDeliverySync()
            receiver.stopGroupDeliverySync()
            sender.disconnect()
            receiver.disconnect()
        }
        let http = try configureExpiryDeliveryHTTP(
            sender: sender, receiver: receiver, author: authorDevice, recipient: recipientDevice
        )
        let invitation = try await confirmInvitationBeforeExpiry(
            sender: sender, receiver: receiver, recipient: recipientDevice,
            http: http, cancelled: cancelled
        )
        let writes = GroupDeliveryHTTPStub.submitted.count + GroupDeliveryHTTPStub.deletions.count

        now = issued.addingTimeInterval(8 * 86_400)
        try await checkExpiryWhileStatusUnavailable(
            on: sender, invitation: invitation, author: authorDevice, recipient: recipientDevice
        )

        let reopened = try authorDevice.harness(knowing: [recipientDevice], onDisk: true, callAccessNow: { now })
            .viewModel
        reopened.allowsNearbyGroupDelivery = false
        defer {
            reopened.stopGroupDeliverySync()
            reopened.disconnect()
            GroupDeliveryHTTPStub.reset()
        }
        reopened.groupDeliveryClient = http.client
        try await checkConfirmedOutcomeAfterRestart(
            on: reopened, receiver: receiver, recipient: recipientDevice,
            groupID: invitation.groupID, cancelled: cancelled
        )
        now = Date(timeIntervalSince1970: invitation.delivery.expiresAt + 21 * 86_400)
        await checkExpiredInvitationRetirement(on: reopened, originalWriteCount: writes)
    }

    private func checkExpiredInvitationRetirement(on reopened: IntercomViewModel, originalWriteCount: Int) async {
        await reopened.synchronizeGroupDeliveries()
        #expect(reopened.groupRepository.groupDeliveries.isEmpty)
        #expect(GroupDeliveryHTTPStub.statusLookups.count == 2)
        #expect(GroupDeliveryHTTPStub.submitted.count + GroupDeliveryHTTPStub.deletions.count == originalWriteCount)
    }

    private func configureExpiryDeliveryHTTP(
        sender: IntercomViewModel,
        receiver: IntercomViewModel,
        author authorDevice: GroupDeliveryTestIdentity,
        recipient recipientDevice: GroupDeliveryTestIdentity
    ) throws -> (client: InternetAccountClient, access: CallNotificationServiceAccess) {
        GroupDeliveryHTTPStub.reset()
        let senderAccess = try #require(try authorDevice.store.notificationAccess(memberID: authorDevice.memberID))
        let receiverAccess = try #require(
            try recipientDevice.store.notificationAccess(memberID: recipientDevice.memberID))
        GroupDeliveryHTTPStub.users = [
            senderAccess.accessToken: try authorDevice.principal.userID,
            receiverAccess.accessToken: try recipientDevice.principal.userID
        ]
        let client = InternetAccountClient(session: GroupDeliveryHTTPStub.makeSession())
        sender.groupDeliveryClient = nil
        receiver.groupDeliveryClient = client
        try grantGroupInvitationPermission(on: sender, recipient: recipientDevice, sender: authorDevice)
        return (client: client, access: senderAccess)
    }

    private func confirmInvitationBeforeExpiry(
        sender: IntercomViewModel,
        receiver: IntercomViewModel,
        recipient recipientDevice: GroupDeliveryTestIdentity,
        http: (client: InternetAccountClient, access: CallNotificationServiceAccess),
        cancelled: Bool
    ) async throws -> ExpiringGroupInvitation {
        let groupID = UUID()
        try #require(sender.createTalkGroup(name: "Trip group", userIDs: [recipientDevice.personID], id: groupID))
        sender.groupDeliveryClient = http.client
        await sender.synchronizeGroupDeliveries()
        let delivery = try #require(sender.groupRepository.groupDeliveries.first)
        try #require(delivery.state == .queued)
        let keyReference = try #require(delivery.credentialReference)
        if cancelled {
            _ = try await http.client.finishGroupInvitation(
                recipient: recipientDevice.principal, id: delivery.id, access: http.access)
        } else {
            await receiver.synchronizeGroupDeliveries()
        }
        return ExpiringGroupInvitation(groupID: groupID, delivery: delivery, keyReference: keyReference)
    }

    private func checkExpiryWhileStatusUnavailable(
        on sender: IntercomViewModel,
        invitation: ExpiringGroupInvitation,
        author authorDevice: GroupDeliveryTestIdentity,
        recipient recipientDevice: GroupDeliveryTestIdentity
    ) async throws {
        GroupDeliveryHTTPStub.failNextStatus = true
        await sender.synchronizeGroupDeliveries()
        let recoveredEnvelopeSlot = authorDevice.groupKeys.values[invitation.keyReference] == nil
        #expect(recoveredEnvelopeSlot)
        #expect(
            sender.groupInvitationDeliveryState(for: try recipientDevice.savedUser(), in: invitation.groupID) == nil)
        try #require(GroupDeliveryHTTPStub.statusLookups == [invitation.delivery.id.uuidString.lowercased()])
        sender.stopGroupDeliverySync()
        sender.disconnect()
    }

    private func checkConfirmedOutcomeAfterRestart(
        on reopened: IntercomViewModel,
        receiver: IntercomViewModel,
        recipient recipientDevice: GroupDeliveryTestIdentity,
        groupID: UUID,
        cancelled: Bool
    ) async throws {
        let expected: GroupDeliveryRecord.State = cancelled ? .cancelled : .received
        await reopened.synchronizeGroupDeliveries()
        #expect(reopened.groupInvitationDeliveryState(for: try recipientDevice.savedUser(), in: groupID) == expected)
        #expect(reopened.groupRepository.groupDeliveries.first?.credentialReference == nil)
        #expect(receiver.groups.contains { $0.id == groupID } == !cancelled)
    }

    @Test(arguments: [false, true])
    func savingAGroupRequestsBackgroundTimeAndKeepsTheSameDeliveryOnExpiry(expires: Bool) async throws {
        let authorDevice = GroupDeliveryTestIdentity("background-delivery-author")
        let recipientDevice = GroupDeliveryTestIdentity("background-delivery-recipient")
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
        }
        GroupDeliveryHTTPStub.reset()
        defer { GroupDeliveryHTTPStub.reset() }
        let access = try #require(try authorDevice.store.notificationAccess(memberID: authorDevice.memberID))
        GroupDeliveryHTTPStub.users = [access.accessToken: try authorDevice.principal.userID]
        model.groupDeliveryClient = .init(session: GroupDeliveryHTTPStub.makeSession())
        try grantGroupInvitationPermission(on: model, recipient: recipientDevice, sender: authorDevice)
        try await checkBackgroundTimeDuringSave(on: model, recipientID: recipientDevice.personID, expires: expires)
    }

    private func checkBackgroundTimeDuringSave(
        on model: IntercomViewModel, recipientID: UUID, expires: Bool
    ) async throws {
        var starts = 0
        var finishes = 0
        var expire: (@MainActor () -> Void)?
        model.beginGroupDeliveryBackgroundTime = { onExpiration in
            starts += 1
            expire = onExpiration
            return { finishes += 1 }
        }
        GroupDeliveryHTTPStub.onQueued = {
            #expect(starts == 1 && finishes == 0, "The network write begins inside the app's requested time")
            if expires { expire?() }
        }
        let groupID = UUID()
        if expires {
            model.requestGroupDeliverySync()
            #expect(starts == 0, "An ordinary inbox refresh does not request extra time")
        }
        #expect(
            model.createTalkGroup(
                name: "Saved before leaving the app", userIDs: [recipientID], id: groupID))
        #expect(starts == 1, "Request extra time before the save action returns")
        let pass = try #require(model.groupDeliveryTask)
        await pass.value
        #expect(finishes == 1)
        let record = try #require(model.groupRepository.groupDeliveries.first)
        #expect(record.groupID == groupID && GroupDeliveryHTTPStub.items.count == 1)
        #expect(record.state == (expires ? .pending : .queued))
        if expires {
            GroupDeliveryHTTPStub.onQueued = nil
            await model.synchronizeGroupDeliveries()
            let retried = try #require(model.groupRepository.groupDeliveries.first)
            #expect(retried.id == record.id && retried.state == .queued)
            #expect(GroupDeliveryHTTPStub.items.count == 1 && GroupDeliveryHTTPStub.submitted.count == 2)
            #expect(Set(GroupDeliveryHTTPStub.submitted).count == 1, "Retry uses the same committed envelope")
            #expect(starts == 1 && finishes == 1)
        }
    }
}

private struct ExpiringGroupInvitation {
    let groupID: UUID
    let delivery: GroupDeliveryRecord
    let keyReference: UUID
}
