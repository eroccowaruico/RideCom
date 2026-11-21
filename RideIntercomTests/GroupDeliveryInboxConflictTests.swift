import CallControl
import CryptoKit
import Foundation
import Testing

@testable import RideIntercom

extension GroupDeliveryFlowTests {
    enum KeyConflictTiming: String, CaseIterable { case alreadySaved, beforeReceiptRetry, afterReceipt }

    @Test(arguments: KeyConflictTiming.allCases) func aConflictingGroupKeyDoesNotBlockTheNextInvitation(
        timing: KeyConflictTiming
    ) async throws {
        let author = GroupDeliveryTestIdentity("conflicting-group-author")
        let recipient = GroupDeliveryTestIdentity("conflicting-group-recipient")
        defer {
            author.remove()
            recipient.remove()
        }
        try author.authorizeFixture(userID: String(repeating: "a", count: 64))
        try recipient.authorizeFixture(userID: String(repeating: "b", count: 64))
        let left = try author.harness(knowing: [recipient]).viewModel
        let right = try recipient.harness(knowing: [author]).viewModel
        GroupDeliveryHTTPStub.reset()
        defer {
            left.stopGroupDeliverySync()
            right.stopGroupDeliverySync()
            left.disconnect()
            right.disconnect()
            GroupDeliveryHTTPStub.reset()
        }
        let client = InternetAccountClient(session: GroupDeliveryHTTPStub.makeSession())
        try allowGroupDeliveryRequests(from: author, recipient)
        left.groupDeliveryClient = client
        try grantGroupInvitationPermission(on: left, recipient: recipient, sender: author)

        let collision = UUID()
        var localCall: CallReference?
        func saveLocalGroup() {
            #expect(right.createTalkGroup(name: "Saved locally", id: collision))
            localCall = right.currentCallReference
        }
        if timing == .afterReceipt { GroupDeliveryHTTPStub.onAcknowledged = saveLocalGroup }
        if timing == .alreadySaved { saveLocalGroup() }
        #expect(left.createTalkGroup(name: "Conflicting invitation", userIDs: [recipient.personID], id: collision))
        await left.synchronizeGroupDeliveries()
        let record = try #require(left.groupRepository.groupDeliveries.first { $0.groupID == collision })
        let conflictID = record.id.uuidString.lowercased()
        #expect(GroupDeliveryHTTPStub.items[conflictID]?["status"] as? String == "queued")
        right.groupDeliveryClient = client
        if timing == .beforeReceiptRetry {
            GroupDeliveryHTTPStub.failNextAcknowledgement = true
            await right.synchronizeGroupDeliveries()
            #expect(right.groupRepository.groupDeliveries.first(where: { $0.id == record.id })?.state == .pending)
            saveLocalGroup()
        }
        await right.synchronizeGroupDeliveries()
        let localCredential = try checkConflictingInboxRecord(record, sender: left, receiver: right, timing: timing)
        try await checkNextInvitationAfterConflict(
            sender: left, receiver: right, recipientID: recipient.personID,
            existing: (id: collision, credential: localCredential), localCall: localCall)
    }

    private func checkConflictingInboxRecord(
        _ record: GroupDeliveryRecord, sender left: IntercomViewModel, receiver right: IntercomViewModel,
        timing: KeyConflictTiming
    ) throws -> GroupAccessCredential {
        let localCredential = try #require(try right.groupRepository.credential(for: record.groupID))
        #expect(localCredential != (try left.groupRepository.credential(for: record.groupID)))
        #expect(
            GroupDeliveryHTTPStub.items[record.id.uuidString.lowercased()]?["status"] as? String
                == (timing == .afterReceipt ? "received" : "cancelled"))
        #expect(!right.groupRepository.groupDeliveries.contains { $0.id == record.id && $0.state == .pending })
        #expect(right.groupStorageIssue == nil)
        #expect(right.groupErrorMessage == nil)
        return localCredential
    }

    private func checkNextInvitationAfterConflict(
        sender left: IntercomViewModel, receiver right: IntercomViewModel, recipientID: UUID,
        existing: (id: UUID, credential: GroupAccessCredential), localCall: CallReference?
    ) async throws {
        let valid = UUID()
        #expect(left.createTalkGroup(name: "Valid invitation", userIDs: [recipientID], id: valid))
        await left.synchronizeGroupDeliveries()
        await right.synchronizeGroupDeliveries()
        #expect(right.groups.first(where: { $0.id == valid })?.name == "Valid invitation")
        #expect(right.groups.first(where: { $0.id == existing.id })?.name == "Saved locally")
        #expect(try right.groupRepository.credential(for: existing.id) == existing.credential)
        #expect(right.currentCallReference == localCall)
    }

    @Test(arguments: [false, true]) func removingTheSenderPreventsReceivingTheirInvitationForOnlyThatGroup(
        duringAcknowledgement: Bool
    ) async throws {
        let author = GroupDeliveryTestIdentity("excluded-inviter")
        let recipient = GroupDeliveryTestIdentity("excluding-recipient")
        defer {
            author.remove()
            recipient.remove()
        }
        try author.authorizeFixture(userID: String(repeating: "a", count: 64))
        try recipient.authorizeFixture(userID: String(repeating: "b", count: 64))
        let sender = try author.harness(knowing: [recipient]).viewModel
        let receiver = try recipient.harness(knowing: [author]).viewModel
        GroupDeliveryHTTPStub.reset()
        defer {
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

        let invitation = try await readdExistingGroupMember(from: sender, on: receiver, recipient: recipient)
        let retryID = invitation.retryID.uuidString.lowercased()
        let groupID = invitation.groupID

        if duringAcknowledgement {
            GroupDeliveryHTTPStub.onAcknowledged = { #expect(receiver.removeMember(author.memberID, from: groupID)) }
        } else {
            #expect(receiver.removeMember(author.memberID, from: groupID))
        }
        await receiver.synchronizeGroupDeliveries()
        #expect(
            GroupDeliveryHTTPStub.items[retryID]?["status"] as? String
                == (duringAcknowledgement ? "received" : "cancelled"))
        let incoming = receiver.groupRepository.groupDeliveries.first { $0.id == invitation.retryID }
        #expect(incoming?.state == (duringAcknowledgement ? .cancelled : nil))
        #expect(receiver.groupRepository.storedGroup(groupID)?.members.map(\.id) == [recipient.memberID])
        #expect(try receiver.groupRepository.credential(for: groupID) == invitation.credential)
        #expect(
            receiver.currentCallReference == invitation.call
                && receiver.savedRemoteUsers.contains { $0.id == author.personID })

        let otherGroup = UUID()
        #expect(sender.createTalkGroup(name: "A different group", userIDs: [recipient.personID], id: otherGroup))
        await sender.synchronizeGroupDeliveries()
        await receiver.synchronizeGroupDeliveries()
        #expect(receiver.groupRepository.storedGroup(otherGroup)?.members.contains { $0.id == author.memberID } == true)
        #expect(receiver.groupErrorMessage == nil && receiver.currentCallReference == invitation.call)
    }

    private func readdExistingGroupMember(
        from sender: IntercomViewModel, on receiver: IntercomViewModel, recipient: GroupDeliveryTestIdentity
    ) async throws -> ReaddedGroupInvitation {
        let groupID = UUID()
        #expect(sender.createTalkGroup(name: "Previously joined", userIDs: [recipient.personID], id: groupID))
        await sender.synchronizeGroupDeliveries()
        await receiver.synchronizeGroupDeliveries()
        await sender.synchronizeGroupDeliveries()
        let credential = try #require(try receiver.groupRepository.credential(for: groupID))
        let call = receiver.currentCallReference
        #expect(sender.removeMember(recipient.memberID, from: groupID))
        #expect(sender.addSavedUsers([recipient.personID], to: groupID))
        await sender.synchronizeGroupDeliveries()
        let retry = try #require(
            sender.groupRepository.groupDeliveries.first { $0.groupID == groupID && $0.state == .queued })
        return ReaddedGroupInvitation(groupID: groupID, retryID: retry.id, credential: credential, call: call)
    }
}

private struct ReaddedGroupInvitation {
    let groupID: UUID
    let retryID: UUID
    let credential: GroupAccessCredential
    let call: CallReference
}
