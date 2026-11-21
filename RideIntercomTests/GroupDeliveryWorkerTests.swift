#if os(macOS)
import Foundation
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized) struct GroupDeliveryWorkerTests {
    @Test(.timeLimit(.minutes(1))) func savedInvitationMakesAnUploadThatTheWorkerCanReceiveWithoutTheBearer()
        async throws {
        try await withWorker {
            let authorDevice = GroupDeliveryTestIdentity("background-author"),
                recipientDevice = GroupDeliveryTestIdentity("background-recipient")
            defer { authorDevice.remove(); recipientDevice.remove() }
            try await register(authorDevice); try await register(recipientDevice)
            let sender = try authorDevice.harness(knowing: [recipientDevice], onDisk: true).viewModel
            let recipient = try recipientDevice.harness(knowing: [authorDevice], onDisk: true).viewModel
            defer { sender.stopGroupDeliverySync(); recipient.stopGroupDeliverySync() }
            let session = workerSession()
            let client = InternetAccountClient(session: session)
            sender.groupDeliveryClient = nil
            recipient.groupDeliveryClient = client
            recipient.notifications = CallNotifications(
                store: recipientDevice.store, memberID: recipientDevice.memberID, client: client,
                isCurrentUser: { [weak recipient] in recipient?.canStartCalls == true },
                contacts: { [weak recipient] in recipient?.savedRemoteUsers ?? [] })
            await recipient.notifications.allowGroupInvitations()
            let permission = try #require(
                try recipient.notifications.groupPermissionMessage(
                    for: authorDevice.memberID, signer: recipientDevice.signer))
            try sender.notifications.receivePermission(permission, peerID: recipientDevice.memberID)

            let groupID = UUID()
            try #require(
                sender.createTalkGroup(
                    name: "Background delivery", userIDs: [recipientDevice.personID], id: groupID))
            let record = try #require(sender.groupRepository.groupDeliveries.first)
            #expect(record.state == .pending && recipient.groups.isEmpty)
            let upload = try verifiedBackgroundUpload(for: record, sender: sender, device: authorDevice)

            let reopened = try authorDevice.harness(knowing: [recipientDevice], onDisk: true).viewModel
            defer { reopened.stopGroupDeliverySync() }
            try await verifyQueuedBackgroundUploads(upload, retryingFrom: reopened, record: record, session: session)
            await recipient.synchronizeGroupDeliveries()
            #expect(recipient.groups.map(\.id) == [groupID])
            let sameGroupKey =
                try recipient.groupRepository.credential(for: groupID)
                == reopened.groupRepository.credential(for: groupID)
            #expect(sameGroupKey)
            reopened.groupDeliveryClient = client
            await reopened.synchronizeGroupDeliveries()
            #expect(
                reopened.groupInvitationDeliveryState(for: try recipientDevice.savedUser(), in: groupID)
                    == .received)
            #expect(try reopened.backgroundGroupInvitationRequest(for: record.id) == nil)

            try await verifyBackgroundCancellation(
                sender: reopened, recipient: recipientDevice, upload: upload, session: session)
            await recipient.synchronizeGroupDeliveries()
            #expect(recipient.groups.map(\.id) == [groupID])
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func theActualWorkerCompletesContactDeletionAfterRevokingTheNotificationGrant(bothRemoved: Bool) async throws {
        try await withWorker {
            let authorDevice = GroupDeliveryTestIdentity("worker-contact-delete-author")
            let recipientDevice = GroupDeliveryTestIdentity("worker-contact-delete-recipient")
            defer { authorDevice.remove(); recipientDevice.remove() }
            try await register(authorDevice); try await register(recipientDevice)
            let client = InternetAccountClient(session: workerSession())
            let (ownerAccess, recipientAccess) = try await revokeContactDeletionGrant(
                client: client, author: authorDevice, recipient: recipientDevice)
            let sender = try authorDevice.harness(knowing: [], onDisk: true).viewModel
            let recipient = try recipientDevice.harness(knowing: [], onDisk: true).viewModel
            defer { sender.stopGroupDeliverySync(); recipient.stopGroupDeliverySync() }
            for model in [sender, recipient] {
                model.groupDeliveryClient = nil
                model.contactSessionFactory = { RecordingCallSession() }
                #expect(!model.notifications.isEnabled)
            }
            try exchangeContactInvitation(sender: sender, recipient: recipient)
            try #require(sender.removeSavedUser(try #require(sender.savedRemoteUsers.first).id))
            if bothRemoved {
                try #require(recipient.removeSavedUser(try #require(recipient.savedRemoteUsers.first).id))
            }
            let first = try #require(sender.groupRepository.contactDeletionPublications.first)
            let reverse = recipient.groupRepository.contactDeletionPublications.first

            let left = try authorDevice.harness(knowing: [], onDisk: true).viewModel
            let right = try recipientDevice.harness(knowing: [], onDisk: true).viewModel
            defer { left.stopGroupDeliverySync(); right.stopGroupDeliverySync() }
            left.groupDeliveryClient = client; right.groupDeliveryClient = client
            await left.synchronizeGroupDeliveries()
            await right.synchronizeGroupDeliveries()
            await left.synchronizeGroupDeliveries()
            await right.synchronizeGroupDeliveries()
            #expect(left.savedRemoteUsers.isEmpty && right.savedRemoteUsers.isEmpty)
            #expect(left.groupRepository.contactDeletions.isEmpty && right.groupRepository.contactDeletions.isEmpty)
            #expect(
                left.groupRepository.contactDeletionPublications.isEmpty
                    && right.groupRepository.contactDeletionPublications.isEmpty)
            #expect(
                left.groupRepository.contactDeletionRelayReceipts.isEmpty
                    && right.groupRepository.contactDeletionRelayReceipts.isEmpty)
            #expect(right.groupRepository.contactDeletionReceipts.map(\.id) == [first.id])
            #expect(try await client.writeContactDeletion(first, access: ownerAccess) == .retired)
            if bothRemoved {
                let reverse = try #require(reverse)
                #expect(left.groupRepository.contactDeletionReceipts.map(\.id) == [reverse.id])
                #expect(try await client.writeContactDeletion(reverse, access: recipientAccess) == .retired)
            }
        }
    }

    private struct BackgroundUpload {
        let request: URLRequest
        let bytes: Data
        let access: CallNotificationServiceAccess
        let locator: Substring
    }

    private func verifiedBackgroundUpload(
        for record: GroupDeliveryRecord, sender: IntercomViewModel, device: GroupDeliveryTestIdentity
    ) throws -> BackgroundUpload {
        let request = try #require(try sender.backgroundGroupInvitationRequest(for: record.id))
        #expect(request.url?.path == "/api/notifications/group-invitations/background")
        #expect(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") == nil)
        let outbound = try #require(request.httpBody)
        let object = try #require(JSONSerialization.jsonObject(with: outbound) as? [String: String])
        let hasOnlySealedField = Set(object.keys) == ["sealed"]
        let access = try #require(try device.store.notificationAccess(memberID: device.memberID))
        let locator = try #require(access.accessToken.split(separator: ".").dropFirst().first)
        let body = try #require(String(data: outbound, encoding: .utf8))
        let containsNoCredentials = !body.contains(access.accessToken) && !body.contains(locator)
        #expect(hasOnlySealedField && containsNoCredentials)

        let identity = try #require(try device.store.loadIdentity(memberID: device.memberID))
        let tokenPrefix = access.accessToken.split(separator: ".").dropLast().joined(separator: ".")
        try device.store.save(
            url: access.origin.absoluteString, token: tokenPrefix + "." + String(repeating: "a", count: 64),
            identity: identity)
        #expect(try sender.backgroundGroupInvitationRequest(for: record.id) == nil)
        try device.store.save(
            url: access.origin.absoluteString, token: access.accessToken, identity: identity)
        return BackgroundUpload(request: request, bytes: outbound, access: access, locator: locator)
    }

    private func verifyBackgroundCancellation(
        sender reopened: IntercomViewModel, recipient recipientDevice: GroupDeliveryTestIdentity,
        upload: BackgroundUpload, session: URLSession
    ) async throws {
        reopened.groupDeliveryClient = nil
        let secondGroup = UUID()
        try #require(
            reopened.createTalkGroup(
                name: "Withdrawn background delivery", userIDs: [recipientDevice.personID], id: secondGroup))
        let pending = try #require(reopened.groupRepository.groupDeliveries.first { $0.groupID == secondGroup })
        let pendingRequest = try #require(try reopened.backgroundGroupInvitationRequest(for: pending.id))
        let (accepted, response) = try await session.data(for: pendingRequest)
        try #require((response as? HTTPURLResponse)?.statusCode == 200)
        let sendKey = try #require(
            reopened.backgroundGroupInvitationUploadIDs().first { $0.deliveryID == pending.id })
        reopened.applyBackgroundGroupInvitationReply(
            try JSONDecoder().decode(GroupDeliveryReply.self, from: accepted), for: sendKey)
        try #require(reopened.removeMember(recipientDevice.memberID, from: secondGroup))
        let cancelKey = try #require(
            reopened.backgroundGroupInvitationUploadIDs().first { $0.deliveryID == pending.id })
        let cancelRequest = try #require(try reopened.backgroundGroupInvitationRequest(for: pending.id))
        #expect(cancelKey.operation == .cancel)
        #expect(cancelRequest.url?.path == "/api/notifications/group-invitations/background-cancellation")
        #expect(
            cancelRequest.httpMethod == "POST"
                && cancelRequest.value(forHTTPHeaderField: "Authorization") == nil)
        let cancelBytes = try #require(cancelRequest.httpBody)
        let cancelObject = try #require(JSONSerialization.jsonObject(with: cancelBytes) as? [String: String])
        let cancelBody = try #require(String(data: cancelBytes, encoding: .utf8))
        let sealedCancellation = Set(cancelObject.keys) == ["sealed"] && !cancelBody.contains(upload.access.accessToken)
            && !cancelBody.contains(upload.locator)
        #expect(sealedCancellation)
        let (withdrawn, cancellationResponse) = try await session.data(for: cancelRequest)
        try #require((cancellationResponse as? HTTPURLResponse)?.statusCode == 200)
        let cancellation = try JSONDecoder().decode(GroupDeliveryReply.self, from: withdrawn)
        #expect(cancellation.status == .cancelled)
        reopened.applyBackgroundGroupInvitationReply(cancellation, for: cancelKey)
        #expect(reopened.groupRepository.groupDeliveries.first { $0.id == pending.id } == nil)
    }

    private func revokeContactDeletionGrant(
        client: InternetAccountClient, author authorDevice: GroupDeliveryTestIdentity,
        recipient recipientDevice: GroupDeliveryTestIdentity
    ) async throws -> (CallNotificationServiceAccess, CallNotificationServiceAccess) {
        let ownerAccess = try #require(try authorDevice.store.notificationAccess(memberID: authorDevice.memberID))
        let recipientAccess = try #require(
            try recipientDevice.store.notificationAccess(memberID: recipientDevice.memberID))
        let grant = try await client.issueNotificationGrant(
            origin: recipientAccess.origin, token: recipientAccess.accessToken,
                senderUserID: ownerAccess.principal.userID)
        try await client.revokeNotificationGrant(
            origin: recipientAccess.origin, token: recipientAccess.accessToken, grantID: grant.grantID)
        return (ownerAccess, recipientAccess)
    }

    private func verifyQueuedBackgroundUploads(
        _ upload: BackgroundUpload, retryingFrom reopened: IntercomViewModel,
        record: GroupDeliveryRecord, session: URLSession
    ) async throws {
        let retry = try #require(try reopened.backgroundGroupInvitationRequest(for: record.id))
        let retryBody = try #require(retry.httpBody)
        let sealedAgain = upload.bytes != retryBody
        #expect(sealedAgain)
        for request in [upload.request, retry] {
            let (bytes, response) = try await session.data(for: request)
            try #require((response as? HTTPURLResponse)?.statusCode == 200)
            let reply = try JSONDecoder().decode(GroupDeliveryReply.self, from: bytes)
            #expect(reply.matches(id: record.id, expiresAt: record.expiresAt) && reply.status == .queued)
        }
    }

    private func exchangeContactInvitation(sender: IntercomViewModel, recipient: IntercomViewModel) throws {
        try recipient.acceptContactInviteURL(try #require(sender.makeContactInviteURL()))
        let invitation = try #require(recipient.pendingContactInvitations.first?.id)
        try sender.receiveContactReplyURL(
            recipient.contactReplyURLForSharing(invitation, expectedAccountAccessID: recipient.accountAccessID)
        )
        sender.stopContactInvitationSession(); recipient.stopContactInvitationSession()
    }
}
#endif
