#if os(macOS)
import CallControl
import CryptoKit
import Foundation
import Testing
@testable import RideIntercom

extension GroupDeliveryWorkerTests {
    @Test(.timeLimit(.minutes(1)), arguments: [1, 9], [false, true])
    func theActualWorkerDeliversAndAcknowledgesAGroupWithoutStartingTheRecipientsCall(
        count: Int, backgroundRefresh: Bool
    ) async throws {
        try await withWorker { try await exerciseGroupDelivery(count: count, backgroundRefresh: backgroundRefresh) }
    }

    private func exerciseGroupDelivery(count: Int, backgroundRefresh: Bool) async throws {
        let authorDevice = GroupDeliveryTestIdentity("worker-author"),
            recipientDevice = GroupDeliveryTestIdentity("worker-recipient")
        defer { authorDevice.remove(); recipientDevice.remove() }
        try await register(authorDevice); try await register(recipientDevice)
        let left = try authorDevice.harness(knowing: [recipientDevice], onDisk: true),
            right = try recipientDevice.harness(knowing: [authorDevice], onDisk: true)
        defer {
            left.viewModel.stopGroupDeliverySync(); right.viewModel.stopGroupDeliverySync()
            left.viewModel.disconnect(); right.viewModel.disconnect()
        }
        let client = InternetAccountClient(session: workerSession())
        left.viewModel.groupDeliveryClient = nil; right.viewModel.groupDeliveryClient = client
        right.viewModel.notifications = CallNotifications(
            store: recipientDevice.store, memberID: recipientDevice.memberID, client: client,
            isCurrentUser: { [weak model = right.viewModel] in model?.canStartCalls == true },
            contacts: { [weak model = right.viewModel] in model?.savedRemoteUsers ?? [] })
        await right.viewModel.notifications.allowGroupInvitations()
        let permission = try #require(
            try right.viewModel.notifications.groupPermissionMessage(
                for: authorDevice.memberID, signer: recipientDevice.signer))
        #expect(permission.groupGrant != nil)
        try left.viewModel.notifications.receivePermission(permission, peerID: recipientDevice.memberID)
        let run = TransferRun(
            authorDevice: authorDevice, recipientDevice: recipientDevice, left: left, right: right, client: client,
            backgroundRefresh: backgroundRefresh)
        let first = try await startInitialDelivery(count: count, run: run)
        GroupWorkerHTTPBridge.dropReceiptForID = first.lostReceiptID
        defer {
            GroupWorkerHTTPBridge.cancellation = nil; GroupWorkerHTTPBridge.cancellationResponse = nil
            GroupWorkerHTTPBridge.dropReceiptForID = nil; GroupWorkerHTTPBridge.didDropReceipt = false
        }
        try await verifyFirstDelivery(count: count, run: run, first: first)
    }

    private func makeInitialGroups(count: Int, author: IntercomViewModel, recipientID: UUID) -> InitialGroups {
        var invitedGroups = Set<UUID>()
        for index in 0..<count {
            let id = UUID(); invitedGroups.insert(id)
            #expect(
                author.createTalkGroup(
                    name: "Actual Worker group \(index)", userIDs: [recipientID], id: id))
        }
        let revokedAfterDownload = UUID()
        #expect(
            author.createTalkGroup(
                name: "Cancelled after download", userIDs: [recipientID], id: revokedAfterDownload))
        let revokedGroupID = UUID()
        #expect(
            author.createTalkGroup(
                name: "Removed before receipt", userIDs: [recipientID], id: revokedGroupID))
        let cancelledBeforeSend = UUID()
        #expect(
            author.createTalkGroup(
                name: "Cancelled before arrival", userIDs: [recipientID], id: cancelledBeforeSend))
        return InitialGroups(invited: invitedGroups, revokedAfterDownload: revokedAfterDownload,
                             revokedBeforeReceipt: revokedGroupID, cancelledBeforeSend: cancelledBeforeSend)
    }

    private func startInitialDelivery(count: Int, run: TransferRun) async throws -> InitialDelivery {
        let authorDevice = run.authorDevice, recipientDevice = run.recipientDevice
        let left = run.left, right = run.right, client = run.client
        let groups = makeInitialGroups(count: count, author: left.viewModel, recipientID: recipientDevice.personID)
        let unsent = try #require(
            left.viewModel.groupRepository.groupDeliveries.first { $0.groupID == groups.cancelledBeforeSend })
        let sender = try #require(try authorDevice.store.notificationAccess(memberID: authorDevice.memberID))
        // Exercise the same HTTP DELETE after an ambiguous upload, while the Worker has no row.
        try await client.finishGroupInvitation(recipient: unsent.recipient, id: unsent.id, access: sender)
        left.viewModel.groupDeliveryClient = client
        let group = try #require(left.viewModel.groups.first(where: { groups.invited.contains($0.id) }))
        let call = left.viewModel.currentCallReference
        let recipientCall = right.viewModel.currentCallReference
        if run.backgroundRefresh {
            try await refreshSavedGroupDeliveries(left.viewModel)
        } else {
            await left.viewModel.synchronizeGroupDeliveries()
        }
        let author = left.viewModel
        #expect(author.groupRepository.groupDeliveries.first(where: { $0.id == unsent.id })?.state == .cancelled)
        let revoked = try #require(
            author.groupRepository.groupDeliveries.first(where: { $0.groupID == groups.revokedBeforeReceipt }))
        #expect(revoked.state == .queued)
        let backgroundTime = DeliveryBackgroundTime()
        author.beginGroupDeliveryBackgroundTime = { _ in
            backgroundTime.requested += 1
            return { backgroundTime.released += 1 }
        }
        author.removeMember(recipientDevice.memberID, from: groups.revokedBeforeReceipt)
        #expect(backgroundTime.requested == 1, "Request time before returning from the removal")
        #expect(author.groupRepository.groupDeliveries.first(where: { $0.id == revoked.id })?.state == .cancelled)
        _ = await author.groupDeliveryTask?.value
        #expect(backgroundTime.released == 1)
        #expect(!author.groupRepository.groupDeliveries.contains { $0.id == revoked.id })
        #expect(author.savedRemoteUsers.contains { $0.id == recipientDevice.personID })
        let afterDownload = try #require(
            author.groupRepository.groupDeliveries.first { $0.groupID == groups.revokedAfterDownload })
        #expect(afterDownload.state == .queued)
        GroupWorkerHTTPBridge.cancellation = .init(
            id: afterDownload.id, recipient: try recipientDevice.principal.userID, token: sender.accessToken)
        let lostReceipt = try #require(author.groupRepository.groupDeliveries.first { $0.groupID == group.id })
        return InitialDelivery(
            groups: groups, sender: sender, groupID: group.id, call: call, recipientCall: recipientCall,
            afterDownloadID: afterDownload.id, lostReceiptID: lostReceipt.id, backgroundTime: backgroundTime)
    }

    private func verifyFirstDelivery(count: Int, run: TransferRun, first: InitialDelivery) async throws {
        let left = run.left, right = run.right
        let authorDevice = run.authorDevice, recipientDevice = run.recipientDevice
        await right.viewModel.synchronizeGroupDeliveries()
        #expect(GroupWorkerHTTPBridge.didDropReceipt)
        #expect(!right.viewModel.groups.contains { $0.id == first.groupID })
        #expect(
            right.viewModel.groupRepository.groupDeliveries.first(where: { $0.id == first.lostReceiptID })?.state
                == .pending)
        #expect(
            right.viewModel.currentCallReference == first.recipientCall
                && left.viewModel.currentCallReference == first.call)
        right.viewModel.stopGroupDeliverySync(); right.viewModel.disconnect()
        let reopened = try recipientDevice.harness(knowing: [authorDevice], onDisk: true)
        defer { reopened.viewModel.stopGroupDeliverySync(); reopened.viewModel.disconnect() }
        let receiver = reopened.viewModel
        try await verifyDeliveryAfterRestart(count: count, run: run, first: first, reopened: reopened)
        let followUp = try await verifyConflictingInvitation(run: run, receiver: receiver)
        let redelivery = try await redeliverGroup(followUp, run: run, receiver: receiver, initial: first.groups)
        try await verifyAdditionalRecipients(run: run, first: first, redelivery: redelivery)
    }

    private func verifyDeliveryAfterRestart(
        count: Int, run: TransferRun, first: InitialDelivery, reopened: AppTestSupport.Harness
    ) async throws {
        let left = run.left, client = run.client
        let receiver = reopened.viewModel
        #expect(!receiver.groups.contains { $0.id == first.groupID })
        let reopenedCall = receiver.currentCallReference
        receiver.groupDeliveryClient = client
        if run.backgroundRefresh {
            #expect(!receiver.canReceiveRelayedContactDeletions && !receiver.hasPendingContactDeletionRelay)
            try await refreshSavedGroupDeliveries(receiver)
        } else {
            await receiver.synchronizeGroupDeliveries()
        }
        #expect(GroupWorkerHTTPBridge.cancellationResponse == "cancelled")
        #expect(
            !receiver.groups.contains { $0.id == first.groups.revokedAfterDownload },
            "Cancellation between downloading and saving should suppress the incoming group")
        #expect(try receiver.groupRepository.credential(for: first.groups.revokedAfterDownload) == nil)
        #expect(
            receiver.groupRepository.groupDeliveries.first(where: { $0.id == first.afterDownloadID })?
                .credentialReference == nil)
        #expect(first.groups.invited.isSubset(of: Set(receiver.groups.map(\.id))))
        #expect(receiver.groups.filter { $0.id == first.groupID }.count == 1)
        #expect(!receiver.groups.contains { $0.id == first.groups.revokedBeforeReceipt })
        #expect(!receiver.groups.contains { $0.id == first.groups.cancelledBeforeSend })
        #expect(receiver.currentCallReference == reopenedCall)
        #expect(
            receiver.activeGroupID == nil && !receiver.hasAnyActiveGroupConnection
                && reopened.callSession.connectedGroup == nil)
        let source = try #require(try left.viewModel.groupRepository.credential(for: first.groupID))
        let target = try #require(try receiver.groupRepository.credential(for: first.groupID))
        #expect(SHA256.hash(data: Data(source.secret.utf8)) == SHA256.hash(data: Data(target.secret.utf8)))
        if run.backgroundRefresh {
            try await refreshSavedGroupDeliveries(left.viewModel)
        } else {
            await left.viewModel.synchronizeGroupDeliveries()
        }
        #expect(left.viewModel.groupRepository.groupDeliveries.filter { $0.state == .received }.count == count)
        #expect(
            left.viewModel.groupRepository.groupDeliveries.first(where: { $0.id == first.afterDownloadID })?.state
                == .cancelled)
        #expect(left.viewModel.groupRepository.groupDeliveries.allSatisfy { $0.credentialReference == nil })
        #expect(
            receiver.groupRepository.groupDeliveries.first(where: { $0.id == first.lostReceiptID })?.state
                == .received)
        #expect(receiver.savedRemoteUsers.count == 1)
    }

    private func refreshSavedGroupDeliveries(_ model: IntercomViewModel) async throws {
        let owner = AppCallOwner(account: model.accountSession, viewModel: model)
        model.setGroupDeliveryForeground(false)
        try #require(owner.needsSavedCommunicationBackgroundRefresh)
        try #require(await owner.refreshSavedCommunicationInBackground())
    }

    private func verifyConflictingInvitation(run: TransferRun, receiver: IntercomViewModel) async throws -> UUID {
        let author = run.author, recipientDevice = run.recipientDevice, client = run.client
        let collision = UUID(), followUp = UUID()
        #expect(receiver.createTalkGroup(name: "Saved locally", id: collision))
        let localCredential = try #require(try receiver.groupRepository.credential(for: collision))
        let localCall = receiver.currentCallReference
        #expect(
            author.createTalkGroup(
                name: "Conflicting invitation", userIDs: [recipientDevice.personID], id: collision))
        await author.synchronizeGroupDeliveries()
        let conflict = try #require(author.groupRepository.groupDeliveries.first { $0.groupID == collision })
        #expect(conflict.state == .queued)
        await receiver.synchronizeGroupDeliveries()
        #expect(
            author.createTalkGroup(
                name: "Valid invitation after conflict", userIDs: [recipientDevice.personID], id: followUp))
        await author.synchronizeGroupDeliveries()
        await receiver.synchronizeGroupDeliveries()
        await author.synchronizeGroupDeliveries()
        let recipientAccess = try #require(
            try recipientDevice.store.notificationAccess(memberID: recipientDevice.memberID))
        #expect(try await client.acknowledgeGroupInvitation(conflict.id, access: recipientAccess) == .cancelled)
        #expect(!author.groupRepository.groupDeliveries.contains { $0.id == conflict.id && $0.state != .cancelled })
        #expect(receiver.groups.first(where: { $0.id == followUp })?.name == "Valid invitation after conflict")
        #expect(receiver.groups.first(where: { $0.id == collision })?.name == "Saved locally")
        #expect(try receiver.groupRepository.credential(for: collision) == localCredential)
        #expect(receiver.currentCallReference == localCall && receiver.groupErrorMessage == nil)
        return followUp
    }

    private func redeliverGroup(
        _ followUp: UUID, run: TransferRun, receiver: IntercomViewModel, initial: InitialGroups
    ) async throws -> Redelivery {
        let author = run.author, recipientDevice = run.recipientDevice
        let person = try recipientDevice.savedUser()
        let firstReceipt = try #require(author.groupInvitationDeliveries(in: followUp).first)
        #expect(firstReceipt.state == .received)
        #expect(author.removeMember(recipientDevice.memberID, from: followUp))
        #expect(receiver.deleteGroup(followUp))
        #expect(author.addSavedUsers([person.id], to: followUp))
        #expect(author.groupInvitationDeliveryState(for: person, in: followUp) == .pending)
        #expect(author.groupInvitationDeliveries(in: followUp).count == 1)
        let newDelivery = try #require(
            author.groupInvitationDeliveries(in: followUp).first { $0.id != firstReceipt.id })
        await author.synchronizeGroupDeliveries()
        #expect(author.groupInvitationDeliveryState(for: person, in: followUp) == .pending)
        #expect(!receiver.groups.contains { $0.id == followUp })
        await receiver.synchronizeGroupDeliveries()
        await author.synchronizeGroupDeliveries()
        #expect(author.groupInvitationDeliveries(in: followUp).map(\.id) == [newDelivery.id])
        #expect(author.groupInvitationDeliveryState(for: person, in: followUp) == .received)
        #expect(receiver.groups.filter { $0.id == followUp }.count == 1)
        try #require(author.removeMember(recipientDevice.memberID, from: initial.revokedAfterDownload))
        for id in initial.invited {
            // The first device received these groups. Removing it must also
            // stop automatic delivery to a new device of the same account.
            try #require(author.removeMember(recipientDevice.memberID, from: id))
        }
        return Redelivery(groupID: followUp, recipient: person, record: newDelivery)
    }

    struct TransferRun {
        let authorDevice: GroupDeliveryTestIdentity
        let recipientDevice: GroupDeliveryTestIdentity
        let left: AppTestSupport.Harness
        let right: AppTestSupport.Harness
        let client: InternetAccountClient
        let backgroundRefresh: Bool

        var author: IntercomViewModel { left.viewModel }
    }

    struct InitialGroups {
        let invited: Set<UUID>
        let revokedAfterDownload: UUID
        let revokedBeforeReceipt: UUID
        let cancelledBeforeSend: UUID
    }

    struct InitialDelivery {
        let groups: InitialGroups
        let sender: CallNotificationServiceAccess
        let groupID: UUID
        let call: CallReference
        let recipientCall: CallReference
        let afterDownloadID: UUID
        let lostReceiptID: UUID
        let backgroundTime: DeliveryBackgroundTime
    }

    final class DeliveryBackgroundTime {
        var requested = 0
        var released = 0
    }

    struct Redelivery {
        let groupID: UUID
        let recipient: SavedUser
        let record: GroupDeliveryRecord
    }
}
#endif
