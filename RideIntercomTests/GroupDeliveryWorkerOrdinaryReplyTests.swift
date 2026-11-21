import Synchronization
#if os(macOS)
import CallControl
import Foundation
import RTC
import Testing
@testable import RideIntercom

extension GroupDeliveryWorkerTests {
    @Test(.timeLimit(.minutes(1))) func aRestoredInternetCallRouteResumesSavedOrdinaryInvitationReplies() async throws {
        try await withWorker {
            let author = GroupDeliveryTestIdentity("ordinary-reconnect-author")
            let recipient = GroupDeliveryTestIdentity("ordinary-reconnect-recipient")
            defer { author.remove(); recipient.remove() }
            try await register(author); try await register(recipient)
            let client = InternetAccountClient(session: workerSession())
            let source = try author.harness(knowing: [], onDisk: true)
            let receiver = try recipient.harness(knowing: [], onDisk: true)
            let left = source.viewModel, right = receiver.viewModel
            defer { left.stopGroupDeliverySync(); right.stopGroupDeliverySync(); left.disconnect(); right.disconnect() }
            for model in [left, right] {
                model.allowsNearbyGroupDelivery = false
                model.setRTCTransportRoutes([.multipeer, .webRTC])
                model.invitationInternetReplyRetryDelays = []
            }
            let invitationGroup = UUID(), authorCall = UUID(), recipientCall = UUID()
            try #require(left.createTalkGroup(name: "Invited", id: invitationGroup))
            try #require(left.createTalkGroup(name: "Author's local call", id: authorCall))
            try #require(left.startCall(to: .group(authorCall), accountAccessID: left.accountAccessID))
            try #require(right.createTalkGroup(name: "Recipient's local call", id: recipientCall))
            try #require(right.startCall(to: .group(recipientCall), accountAccessID: right.accountAccessID))
            let expectedAuthorCall = left.currentCallReference, expectedRecipientCall = right.currentCallReference
            let sendToAuthor = try #require(source.callSession.onEvent)
            let sendToRecipient = try #require(receiver.callSession.onEvent)
            let mixed = TransportEvent.routesChanged(.init(activeRoute: .multipeer, mediaRoute: .multipeer,
                availableRoutes: [.multipeer, .webRTC], isHandoverInProgress: false))
            let local = TransportEvent.routesChanged(.init(activeRoute: .multipeer, mediaRoute: .multipeer,
                availableRoutes: [.multipeer], isHandoverInProgress: false))
            sendToAuthor(mixed); sendToRecipient(mixed)

            left.groupDeliveryClient = client; right.groupDeliveryClient = client
            let link = try #require(left.makeGroupInviteURL(for: invitationGroup))
            await left.invitationInternetReplyWindow?.task?.value
            #expect(left.invitationInternetReplyWindow == nil)
            sendToAuthor(local)
            try right.acceptInviteURL(link)
            await right.invitationInternetReplyWindow?.task?.value
            #expect(right.invitationInternetReplyWindow == nil)
            let pending = right.groupRepository.pendingInvitation(for: invitationGroup) != nil
            #expect(pending)
            sendToRecipient(local)
            sendToAuthor(local)
            #expect(left.invitationInternetReplyWindow == nil)

            try await resumeInvitationInbox(left, recipientID: recipient.memberID) { sendToAuthor(mixed) }

            try await resumeInvitationReceipt(right, invitationGroup: invitationGroup) { sendToRecipient(mixed) }
            #expect(left.currentCallReference == expectedAuthorCall)
            #expect(right.currentCallReference == expectedRecipientCall)
            #expect(left.activeGroupID == authorCall)
            #expect(right.activeGroupID == recipientCall)
        }
    }

    @Test(.timeLimit(.minutes(1))) func lateOrdinaryInvitationReplyArrivesWithoutReturningToTheForeground()
        async throws {
        try await withWorker {
            let author = GroupDeliveryTestIdentity("ordinary-retry-author")
            let recipient = GroupDeliveryTestIdentity("ordinary-retry-recipient")
            defer { author.remove(); recipient.remove() }
            try await register(author); try await register(recipient)
            let client = InternetAccountClient(session: workerSession())
            let left = try author.harness(knowing: [], onDisk: true).viewModel
            let right = try recipient.harness(knowing: [], onDisk: true).viewModel
            defer { left.stopGroupDeliverySync(); right.stopGroupDeliverySync(); left.disconnect(); right.disconnect() }
            for model in [left, right] {
                model.allowsNearbyGroupDelivery = false
                model.setRTCTransportRoutes([.webRTC])
            }
            let invited = UUID()
            try #require(left.createTalkGroup(name: "Late reply", id: invited))
            left.groupDeliveryClient = client; right.groupDeliveryClient = client
            var issuerExpiration: (@MainActor () -> Void)?
            var issuerEnds = 0, recipientEnds = 0
            left.beginGroupDeliveryBackgroundTime = { expire in issuerExpiration = expire; return { issuerEnds += 1 } }
            right.beginGroupDeliveryBackgroundTime = { _ in { recipientEnds += 1 } }

            let (link, issuerWindow) = try await awaitInvitationInbox(for: invited, sender: left)
            await left.synchronizeGroupDeliveries()
            #expect(left.invitationInternetReplyWindow?.id == issuerWindow)
            try right.acceptInviteURL(link)
            await AppTestSupport.waitUntil(timeout: .seconds(6)) {
                !left.savedRemoteUsers.isEmpty && right.groupRepository.pendingInvitation(for: invited) == nil
            }
            #expect(left.savedRemoteUsers.first?.memberIDs == [recipient.memberID])
            let complete = right.groupRepository.pendingInvitation(for: invited) == nil
            #expect(complete)
            #expect(right.invitationInternetReplyWindow == nil)
            #expect(recipientEnds == 1)
            let expire = try #require(issuerExpiration)
            left.requestInvitationInternetReply(restart: true)
            let renewed = try #require(left.invitationInternetReplyWindow?.id)
            expire()
            #expect(left.invitationInternetReplyWindow?.id == renewed)
            #expect(issuerEnds == 1)
            let expireRenewed = try #require(issuerExpiration)
            expireRenewed()
            expireRenewed()
            expire()
            #expect(left.invitationInternetReplyWindow == nil)
            #expect(issuerEnds == 2)
        }
    }

    @Test(.timeLimit(.minutes(1))) func ordinaryInvitationOperationsDeliverAfterForegroundResumeAndKeepTheCall()
        async throws {
        try await withWorker {
            let author = GroupDeliveryTestIdentity("ordinary-reply-lifecycle-author")
            let recipient = GroupDeliveryTestIdentity("ordinary-reply-lifecycle-recipient")
            defer { author.remove(); recipient.remove() }
            try await register(author); try await register(recipient)
            let client = InternetAccountClient(session: workerSession())
            let left = try author.harness(knowing: [], onDisk: true).viewModel
            let right = try recipient.harness(knowing: [], onDisk: true).viewModel
            defer { left.stopGroupDeliverySync(); right.stopGroupDeliverySync(); left.disconnect(); right.disconnect() }
            for model in [left, right] {
                model.allowsNearbyGroupDelivery = false
                model.setRTCTransportRoutes([.webRTC])
                model.invitationInternetReplyRetryDelays = []
                #expect(!model.notifications.isEnabled)
            }
            let calls = try startOrdinaryReplyCalls(sender: left, recipient: right)

            left.groupDeliveryClient = client; right.groupDeliveryClient = client
            var leftWindows = 0, rightWindows = 0
            left.beginGroupDeliveryBackgroundTime = { _ in leftWindows += 1; return {} }
            right.beginGroupDeliveryBackgroundTime = { _ in rightWindows += 1; return {} }
            let link = try #require(left.makeGroupInviteURL(for: calls.invited))
            let opening = try #require(left.invitationInternetReplyWindow?.task)
            await opening.value
            #expect(leftWindows == 1)

            try right.acceptInviteURL(link)
            let accepting = try #require(right.invitationInternetReplyWindow?.task)
            await accepting.value
            #expect(rightWindows == 1)
            let pending = right.groupRepository.pendingInvitation(for: calls.invited) != nil
            #expect(pending)
            #expect(left.savedRemoteUsers.isEmpty)
            #expect(right.currentCallReference == calls.recipientReference)
            #expect(right.activeGroupID == calls.recipientID)

            let issuerOwner = AppCallOwner(account: left.accountSession, viewModel: left)
            GroupWorkerHTTPBridge.interruptOrdinaryGroupAcknowledgement = true
            defer { GroupWorkerHTTPBridge.interruptOrdinaryGroupAcknowledgement = false }
            issuerOwner.systemSurfaceIsForeground = true
            let delivering = try #require(left.invitationInternetReplyWindow?.task)
            await delivering.value
            #expect(!GroupWorkerHTTPBridge.interruptOrdinaryGroupAcknowledgement)
            #expect(left.savedRemoteUsers.first?.memberIDs == [recipient.memberID])
            #expect(left.currentCallReference == calls.issuerReference)
            #expect(left.activeGroupID == calls.issuerID)
            let savedUser = left.savedRemoteUsers.first?.id
            right.disconnect()

            let issuer = ReplyIssuer(
                identity: author, model: left, owner: issuerOwner, savedUser: savedUser, call: calls.issuerReference)
            try await verifyOrdinaryReplyAfterRestart(
                issuer: issuer, recipient: recipient, invited: calls.invited, client: client)
        }
    }

    @Test(.timeLimit(.minutes(1))) func reopenedInviterReceivesRepliesForBothIssuedGroupLinks() async throws {
        try await withWorker {
            let author = GroupDeliveryTestIdentity("multi-ordinary-author")
            let recipient = GroupDeliveryTestIdentity("multi-ordinary-recipient")
            defer { author.remove(); recipient.remove() }
            try await register(author); try await register(recipient)
            let client = InternetAccountClient(session: workerSession())
            let source = try author.harness(knowing: [], onDisk: true).viewModel
            defer { source.stopGroupDeliverySync(); source.disconnect() }
            source.allowsNearbyGroupDelivery = false
            source.setRTCTransportRoutes([.webRTC])
            let first = UUID(), second = UUID(), unrelated = UUID()
            try #require(source.createTalkGroup(name: "First", id: first))
            try #require(source.createTalkGroup(name: "Second", id: second))
            try #require(source.createTalkGroup(name: "Ongoing", id: unrelated))
            let firstLink = try #require(source.makeGroupInviteURL(for: first))
            let secondLink = try #require(source.makeGroupInviteURL(for: second))
            source.disconnect()

            let left = try author.harness(knowing: [], onDisk: true).viewModel
            let right = try recipient.harness(knowing: [], onDisk: true).viewModel
            defer { left.stopGroupDeliverySync(); right.stopGroupDeliverySync(); left.disconnect(); right.disconnect() }
            for model in [left, right] {
                model.allowsNearbyGroupDelivery = false
                model.setRTCTransportRoutes([.webRTC])
                model.invitationInternetReplyRetryDelays = []
                model.groupDeliveryClient = client
            }
            try #require(left.startCall(to: .group(unrelated), accountAccessID: left.accountAccessID))
            let currentCall = left.currentCallReference
            let owner = AppCallOwner(account: left.accountSession, viewModel: left)
            owner.systemSurfaceIsForeground = true
            await left.invitationInternetReplyWindow?.task?.value

            try right.acceptInviteURL(secondLink)
            await right.invitationInternetReplyWindow?.task?.value
            try right.acceptInviteURL(firstLink)
            await right.invitationInternetReplyWindow?.task?.value
            let before = [first, second].filter { right.groupRepository.pendingInvitation(for: $0) != nil }
            #expect(before.count == 2)

            owner.systemSurfaceIsForeground = false
            owner.systemSurfaceIsForeground = true
            await left.invitationInternetReplyWindow?.task?.value
            #expect(left.savedRemoteUsers.map(\.memberIDs) == [[recipient.memberID]])
            #expect(left.currentCallReference == currentCall)
            let recipientOwner = AppCallOwner(account: right.accountSession, viewModel: right)
            recipientOwner.systemSurfaceIsForeground = true
            await right.invitationInternetReplyWindow?.task?.value
            let newerCompleted = right.groupRepository.pendingInvitation(for: second) == nil
            let olderCompleted = right.groupRepository.pendingInvitation(for: first) == nil
            #expect(newerCompleted)
            #expect(olderCompleted)
        }
    }

    private func resumeInvitationInbox(
        _ left: IntercomViewModel, recipientID: String, restoreRoute: () -> Void
    ) async throws {
        restoreRoute()
        let authorWindow = try #require(left.invitationInternetReplyWindow)
        restoreRoute()
        #expect(left.invitationInternetReplyWindow?.id == authorWindow.id)
        await authorWindow.task?.value
        #expect(left.savedRemoteUsers.first?.memberIDs == [recipientID])
        restoreRoute()
        #expect(left.invitationInternetReplyWindow == nil)
    }

    private func resumeInvitationReceipt(
        _ right: IntercomViewModel, invitationGroup: UUID, restoreRoute: () -> Void
    ) async throws {
        restoreRoute()
        let recipientWindow = try #require(right.invitationInternetReplyWindow?.task)
        await recipientWindow.value
        let completed = right.groupRepository.pendingInvitation(for: invitationGroup) == nil
        #expect(completed)
    }

    private func awaitInvitationInbox(
        for invited: UUID, sender left: IntercomViewModel
    ) async throws -> (URL, UUID) {
        let reads = GroupWorkerHTTPBridge.ordinaryReplyInboxReads.withLock { $0 }
        let link = try #require(left.makeGroupInviteURL(for: invited))
        await AppTestSupport.waitUntil(timeout: .seconds(5)) {
            GroupWorkerHTTPBridge.ordinaryReplyInboxReads.withLock { $0 > reads }
        }
        try #require(GroupWorkerHTTPBridge.ordinaryReplyInboxReads.withLock { $0 > reads })
        let issuerWindow = try #require(left.invitationInternetReplyWindow?.id)
        return (link, issuerWindow)
    }

    private func verifyDirectCallAfterReply(
        issuer author: GroupDeliveryTestIdentity, recipient: GroupDeliveryTestIdentity,
        sender left: IntercomViewModel, receiver reopened: IntercomViewModel
    ) throws {
        let personOnLeft = try #require(left.savedRemoteUsers.first)
        let personOnRight = try #require(reopened.savedRemoteUsers.first)
        let leftPrincipal = try author.principal, rightPrincipal = try recipient.principal
        try #require(personOnLeft.principal == rightPrincipal && personOnRight.principal == leftPrincipal)
        let pair = AccountCallPair(leftPrincipal, rightPrincipal)
        try #require(
            left.existingDirectCall(for: personOnLeft.id) == nil
                && reopened.existingDirectCall(for: personOnRight.id) == nil)
        left.disconnect()
        try #require(left.startCall(to: .user(personOnLeft.id), accountAccessID: left.accountAccessID))
        try #require(reopened.startCall(to: .user(personOnRight.id), accountAccessID: reopened.accountAccessID))
        #expect(left.activeGroupID == pair.id && reopened.activeGroupID == pair.id)
        let firstKey = try left.groupRepository.credential(for: pair.id)
        let secondKey = try reopened.groupRepository.credential(for: pair.id)
        let match = firstKey != nil && firstKey == secondKey
        #expect(match)
    }

    private struct OrdinaryReplyCalls {
        let invited: UUID
        let issuerID: UUID
        let recipientID: UUID
        let issuerReference: CallReference
        let recipientReference: CallReference
    }

    private func startOrdinaryReplyCalls(
        sender left: IntercomViewModel, recipient right: IntercomViewModel
    ) throws -> OrdinaryReplyCalls {
        let invited = UUID(), ongoing = UUID(), otherCall = UUID()
        try #require(left.createTalkGroup(name: "Invited", id: invited))
        try #require(left.createTalkGroup(name: "Ongoing", id: ongoing))
        try #require(left.startCall(to: .group(ongoing), accountAccessID: left.accountAccessID))
        try #require(right.createTalkGroup(name: "Other call", id: otherCall))
        try #require(right.startCall(to: .group(otherCall), accountAccessID: right.accountAccessID))
        let oldCall = left.currentCallReference
        let oldInviteeCall = right.currentCallReference
        return OrdinaryReplyCalls(invited: invited, issuerID: ongoing, recipientID: otherCall,
                                  issuerReference: oldCall, recipientReference: oldInviteeCall)
    }

    private struct ReplyIssuer {
        let identity: GroupDeliveryTestIdentity
        let model: IntercomViewModel
        let owner: AppCallOwner
        let savedUser: UUID?
        let call: CallReference
    }

    private func verifyOrdinaryReplyAfterRestart(
        issuer: ReplyIssuer, recipient: GroupDeliveryTestIdentity, invited: UUID, client: InternetAccountClient
    ) async throws {
        let left = issuer.model
        let issuerOwner = issuer.owner
        let reopened = try recipient.harness(knowing: [], onDisk: true).viewModel
        defer { reopened.stopGroupDeliverySync(); reopened.disconnect() }
        reopened.allowsNearbyGroupDelivery = false
        reopened.setRTCTransportRoutes([.webRTC])
        reopened.invitationInternetReplyRetryDelays = []
        reopened.groupDeliveryClient = client
        let inviteeOwner = AppCallOwner(account: reopened.accountSession, viewModel: reopened)
        inviteeOwner.systemSurfaceIsForeground = true
        let receiving = try #require(reopened.invitationInternetReplyWindow?.task)
        await receiving.value
        let stillPending = reopened.groupRepository.pendingInvitation(for: invited) != nil
        #expect(stillPending)

        issuerOwner.systemSurfaceIsForeground = false
        issuerOwner.systemSurfaceIsForeground = true
        await left.invitationInternetReplyWindow?.task?.value
        #expect(left.savedRemoteUsers.map(\.id) == [issuer.savedUser].compactMap { $0 })
        #expect(left.currentCallReference == issuer.call)

        inviteeOwner.systemSurfaceIsForeground = false
        inviteeOwner.systemSurfaceIsForeground = true
        await reopened.invitationInternetReplyWindow?.task?.value
        let completed = reopened.groupRepository.pendingInvitation(for: invited) == nil
        #expect(completed)
        #expect(reopened.savedRemoteUsers.first?.memberIDs == [issuer.identity.memberID])
        #expect(reopened.activeGroupID == nil)
        let persisted =
            try recipient.harness(knowing: [], onDisk: true).viewModel.groupRepository.pendingInvitation(
                for: invited) == nil
        #expect(persisted)

        try verifyDirectCallAfterReply(issuer: issuer.identity, recipient: recipient, sender: left, receiver: reopened)
    }
}
#endif
