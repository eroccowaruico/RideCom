import CallControl
import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

extension GroupDeliveryFlowTests {
    @Test func changingAnOutgoingInvitationKeepsThePendingContactAcceptance() throws {
        let author = GroupDeliveryTestIdentity("parallel-invite-author")
        let receiver = GroupDeliveryTestIdentity("parallel-invite-receiver")
        let groupPeer = GroupDeliveryTestIdentity("parallel-group-peer")
        defer { [author, receiver, groupPeer].forEach { $0.remove() } }
        let issuer = P256.Signing.PrivateKey()
        try author.authorizeFixture(userID: String(repeating: "a", count: 64), issuer: issuer)
        try receiver.authorizeFixture(userID: String(repeating: "b", count: 64), issuer: issuer, relayEnabled: true)
        try groupPeer.authorizeFixture(userID: String(repeating: "c", count: 64), issuer: issuer)
        let model = try receiver.harness(knowing: [groupPeer]).viewModel
        let inviter = try author.harness(knowing: []).viewModel
        defer {
            model.stopGroupDeliverySync()
            inviter.stopGroupDeliverySync()
        }
        inviter.groupDeliveryClient = nil
        model.setRTCTransportRoutes([.webRTC])
        let transfer = RecordingBackgroundInvitationTransfer()
        _ = try startBackgroundContactAcceptance(on: model, invitedBy: inviter, transfer: transfer)
        let acceptance = try #require(transfer.active.first)
        #expect(acceptance.operation == .contactAcceptance)

        try grantGroupInvitationPermission(on: model, recipient: groupPeer, sender: receiver)
        let groupID = UUID()
        try #require(model.createTalkGroup(name: "Parallel transfer", userIDs: [groupPeer.personID], id: groupID))
        let send = try #require(transfer.active.first { $0.operation == .send })
        #expect(transfer.active == [acceptance, send])
        model.requestInvitationInternetReply(restart: true)
        #expect(transfer.active == [acceptance, send])

        try #require(model.removeMember(groupPeer.memberID, from: groupID))
        let cancellation = try #require(transfer.active.first { $0.operation == .cancel })
        #expect(cancellation.deliveryID == send.deliveryID)
        #expect(transfer.active == [acceptance, cancellation])
        #expect(transfer.enqueued.filter { $0 == acceptance }.count == 1)
    }

    @Test(arguments: [true, false])
    func acceptingContactInvitationLetsIOSOwnTheSavedAcceptance(relayEnabled: Bool) async throws {
        let authorDevice = GroupDeliveryTestIdentity("contact-upload-author")
        let recipientDevice = GroupDeliveryTestIdentity("contact-upload-recipient")
        defer {
            authorDevice.remove()
            recipientDevice.remove()
        }
        let issuer = P256.Signing.PrivateKey()
        try authorDevice.authorizeFixture(userID: String(repeating: "a", count: 64), issuer: issuer)
        try recipientDevice.authorizeFixture(
            userID: String(repeating: "b", count: 64), issuer: issuer, relayEnabled: relayEnabled)
        let author = try authorDevice.harness(knowing: []).viewModel
        let recipient = try recipientDevice.harness(knowing: [], onDisk: true).viewModel
        defer {
            author.stopGroupDeliverySync()
            recipient.stopGroupDeliverySync()
        }
        author.groupDeliveryClient = nil
        recipient.setRTCTransportRoutes([.webRTC])
        recipient.invitationInternetReplyRetryDelays = []
        let transfer = RecordingBackgroundInvitationTransfer()
        let url = try startBackgroundContactAcceptance(on: recipient, invitedBy: author, transfer: transfer)
        let record = try #require(recipient.groupRepository.contactInvitations.first)
        #expect(record.state == .pending)
        if !relayEnabled {
            #expect(transfer.enqueued.isEmpty)
            return
        }
        let upload = try #require(transfer.enqueued.first)
        #expect(upload.deliveryID == record.id)
        #expect(upload.operation == .contactAcceptance)
        let receiptID = try #require(record.receiptID)
        try checkSealedContactAcceptanceRequest(
            transfer.requests[upload], recipient: recipient, record: record, recipientDevice: recipientDevice,
            excluding: [try authorDevice.principal.userID, authorDevice.memberID, receiptID.uuidString.lowercased(),
                        url.absoluteString]
        )
        recipient.requestInvitationInternetReply(restart: true)
        #expect(transfer.enqueued.count == 1)

        try checkContactAcceptanceCompletion(
            recipient: recipient, record: record, receiptID: receiptID, upload: upload, transfer: transfer
        )
        let reopened = try recipientDevice.harness(knowing: [], onDisk: true).viewModel
        defer { reopened.stopGroupDeliverySync() }
        #expect(reopened.contactInvitationRecord(record.id)?.internetAcceptanceSubmitted == true)
        #expect(reopened.contactInvitationRecord(record.id)?.state == .pending)
    }

    private func checkSealedContactAcceptanceRequest(
        _ request: URLRequest?,
        recipient: IntercomViewModel,
        record: ContactInvitationRecord,
        recipientDevice: GroupDeliveryTestIdentity,
        excluding senderAndInvitationIdentifiers: [String]
    ) throws {
        let request = try #require(request)
        #expect(request.url?.path == "/api/ordinary-group-replies/background-acceptance")
        let anonymousRequest = request.value(forHTTPHeaderField: "Authorization") == nil
        let body = try #require(request.httpBody)
        let access = try #require(try recipientDevice.store.notificationAccess(memberID: recipientDevice.memberID))
        let payload = try recipient.groupRepository.contactInvitationPayload(record.id)
        let address = try InvitationReplyAddress(contactToken: payload.token)
        let anonymousBody = containsOnlySealedInvitation(
            body,
            excluding: [access.accessToken, recipientDevice.memberID, access.principal.userID, address.slot]
                + senderAndInvitationIdentifiers
        )
        #expect(anonymousRequest && anonymousBody)
    }

    func startBackgroundContactAcceptance(
        on recipient: IntercomViewModel,
        invitedBy author: IntercomViewModel,
        transfer: RecordingBackgroundInvitationTransfer
    ) throws -> URL {
        recipient.groupDeliveryClient = .init(session: GroupDeliveryHTTPStub.makeSession())
        recipient.invitationBackgroundTransfer = transfer
        let url = try #require(author.makeContactInviteURL())
        try recipient.acceptContactInviteURL(url)
        return url
    }

    private func checkContactAcceptanceCompletion(
        recipient: IntercomViewModel,
        record: ContactInvitationRecord,
        receiptID: UUID,
        upload: InvitationBackgroundUploadID,
        transfer: RecordingBackgroundInvitationTransfer
    ) throws {
        let expiry = Int64((record.expiresAt * 1000).rounded(.down))
        let wrongExpiry = try JSONSerialization.data(withJSONObject: [
            "id": receiptID.uuidString, "expiresAt": expiry + 1
        ])
        recipient.applyBackgroundInvitationResponse(wrongExpiry, for: upload)
        #expect(recipient.contactInvitationRecord(record.id)?.internetAcceptanceSubmitted == nil)
        let reply = try JSONSerialization.data(withJSONObject: ["id": receiptID.uuidString, "expiresAt": expiry])
        let oldSession = InvitationBackgroundUploadID(
            deliveryID: upload.deliveryID,
            sessionBinding: String(repeating: "0", count: 64), operation: .contactAcceptance)
        recipient.applyBackgroundInvitationResponse(reply, for: oldSession)
        #expect(recipient.contactInvitationRecord(record.id)?.internetAcceptanceSubmitted == nil)
        transfer.active.remove(upload)
        recipient.applyBackgroundInvitationResponse(reply, for: upload)
        #expect(recipient.contactInvitationRecord(record.id)?.internetAcceptanceSubmitted == true)
        #expect(recipient.contactInvitationRecord(record.id)?.state == .pending)
    }

    func containsOnlySealedInvitation(_ body: Data, excluding values: [String]) -> Bool {
        guard let fields = try? JSONSerialization.jsonObject(with: body) as? [String: String],
            fields.count == 1, let sealed = fields["sealed"]
        else { return false }
        let parts = sealed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 5, parts[1].isEmpty else { return false }
        var visible = body
        for part in parts where !part.isEmpty {
            let base64 = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            let padding = String(repeating: "=", count: (4 - base64.count % 4) % 4)
            guard let bytes = Data(base64Encoded: base64 + padding) else { return false }
            visible.append(bytes)
        }
        return values.allSatisfy { visible.range(of: Data($0.utf8)) == nil }
    }

    @Test(arguments: [true, false])
    func savingEnqueuesOneBackgroundUploadAndCancelsItWhenTheMemberIsRemoved(relayEnabled: Bool) async throws {
        let authorDevice = GroupDeliveryTestIdentity("background-author")
        let recipientDevice = GroupDeliveryTestIdentity("background-recipient")
        defer {
            authorDevice.remove()
            recipientDevice.remove()
            GroupDeliveryHTTPStub.reset()
        }
        try authorDevice.authorizeFixture(userID: String(repeating: "a", count: 64), relayEnabled: relayEnabled)
        try recipientDevice.authorizeFixture(userID: String(repeating: "b", count: 64))
        let model = try authorDevice.harness(knowing: [recipientDevice], onDisk: true).viewModel
        defer { model.stopGroupDeliverySync() }
        GroupDeliveryHTTPStub.reset()
        let access = try #require(try authorDevice.store.notificationAccess(memberID: authorDevice.memberID))
        GroupDeliveryHTTPStub.users = [access.accessToken: try authorDevice.principal.userID]
        model.groupDeliveryClient = .init(session: GroupDeliveryHTTPStub.makeSession())
        let transfer = RecordingBackgroundInvitationTransfer()
        model.invitationBackgroundTransfer = transfer
        try grantGroupInvitationPermission(on: model, recipient: recipientDevice, sender: authorDevice)

        let first = UUID()
        try #require(model.createTalkGroup(name: "Offline", userIDs: [recipientDevice.personID], id: first))
        let record = try #require(model.groupRepository.groupDeliveries.first { $0.groupID == first })
        if !relayEnabled {
            #expect(try model.backgroundGroupInvitationRequest(for: record.id) == nil)
            await model.synchronizeGroupDeliveries()
            #expect(GroupDeliveryHTTPStub.submitted.count == 1)
            #expect(model.groupRepository.groupDeliveries.first?.state == .queued)
            try #require(model.removeMember(recipientDevice.memberID, from: first))
            #expect(try model.backgroundGroupInvitationRequest(for: record.id) == nil)
            await model.synchronizeGroupDeliveries()
            #expect(GroupDeliveryHTTPStub.deletions == [record.id.uuidString.lowercased()])
            #expect(transfer.enqueued.isEmpty)
            return
        }
        try await checkWithdrawalAfterAcceptance(
            of: record, on: model, recipient: recipientDevice, transfer: transfer
        )
        try await checkWithdrawalBeforeAcceptance(on: model, recipient: recipientDevice, transfer: transfer)
    }

    private func checkWithdrawalAfterAcceptance(
        of record: GroupDeliveryRecord,
        on model: IntercomViewModel,
        recipient: GroupDeliveryTestIdentity,
        transfer: RecordingBackgroundInvitationTransfer
    ) async throws {
        let upload = try #require(transfer.enqueued.first)
        #expect(upload.deliveryID == record.id)
        await model.synchronizeGroupDeliveries()
        #expect(transfer.enqueued.count == 1 && GroupDeliveryHTTPStub.submitted.isEmpty)
        #expect(model.groupRepository.groupDeliveries.first?.state == .pending)
        let reply = GroupDeliveryReply(requestID: record.id, expiresAt: record.expiresAt * 1_000, status: .queued)
        model.applyBackgroundGroupInvitationReply(
            reply,
            for: .init(deliveryID: record.id, sessionBinding: String(repeating: "0", count: 64), operation: .send))
        #expect(model.groupRepository.groupDeliveries.first?.state == .pending)
        model.applyBackgroundGroupInvitationReply(reply, for: upload)
        #expect(model.groupRepository.groupDeliveries.first?.state == .queued)
        model.removeMember(recipient.memberID, from: record.groupID)
        let withdrawal = try #require(transfer.enqueued.last)
        #expect(withdrawal != upload && withdrawal.deliveryID == record.id)
        await model.synchronizeGroupDeliveries()
        #expect(GroupDeliveryHTTPStub.deletions.isEmpty)
        model.applyBackgroundGroupInvitationReply(reply, for: withdrawal)
        #expect(model.groupRepository.groupDeliveries.first { $0.id == record.id }?.state == .cancelled)
        model.applyBackgroundGroupInvitationReply(
            .init(requestID: record.id, expiresAt: record.expiresAt * 1_000 + 10, status: .received), for: withdrawal)
        #expect(model.groupRepository.groupDeliveries.first { $0.id == record.id }?.state == .cancelled)
        model.applyBackgroundGroupInvitationReply(
            .init(requestID: record.id, expiresAt: record.expiresAt * 1_000, status: .received), for: withdrawal)
        #expect(model.groupRepository.groupDeliveries.first { $0.id == record.id } == nil)
    }

    private func checkWithdrawalBeforeAcceptance(
        on model: IntercomViewModel,
        recipient: GroupDeliveryTestIdentity,
        transfer: RecordingBackgroundInvitationTransfer
    ) async throws {
        let second = UUID()
        try #require(model.createTalkGroup(name: "Withdrawn offline", userIDs: [recipient.personID], id: second))
        let removed = try #require(model.groupRepository.groupDeliveries.first { $0.groupID == second })
        let cancelledUpload = try #require(transfer.enqueued.last)
        #expect(cancelledUpload.deliveryID == removed.id)
        model.removeMember(recipient.memberID, from: second)
        #expect(!transfer.active.contains(cancelledUpload))
        let withdrawnBeforeAcceptance = try #require(transfer.enqueued.last)
        #expect(withdrawnBeforeAcceptance != cancelledUpload && withdrawnBeforeAcceptance.deliveryID == removed.id)
        model.applyBackgroundGroupInvitationReply(
            .init(requestID: removed.id, expiresAt: removed.expiresAt * 1_000, status: .queued), for: cancelledUpload)
        #expect(model.groupRepository.groupDeliveries.first { $0.id == removed.id }?.state == .cancelled)
        model.applyBackgroundGroupInvitationReply(
            .init(requestID: removed.id, expiresAt: removed.expiresAt * 1_000, status: .cancelled),
            for: withdrawnBeforeAcceptance)
        #expect(model.groupRepository.groupDeliveries.first { $0.id == removed.id } == nil)
        await model.groupDeliveryTask?.value
    }
}

@MainActor final class RecordingBackgroundInvitationTransfer: InvitationBackgroundTransferring {
    var hasRestored = true
    var active: Set<InvitationBackgroundUploadID> = []
    var enqueued: [InvitationBackgroundUploadID] = []
    private(set) var requests: [InvitationBackgroundUploadID: URLRequest] = [:]
    func restore() async { hasRestored = true }
    func reconcile(keeping keys: Set<InvitationBackgroundUploadID>) { active.formIntersection(keys) }
    func contains(_ key: InvitationBackgroundUploadID) -> Bool { active.contains(key) }
    func enqueue(_ request: URLRequest, for key: InvitationBackgroundUploadID) throws {
        active.insert(key)
        enqueued.append(key)
        requests[key] = request
    }
}
