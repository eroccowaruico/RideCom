#if os(macOS)
import CryptoKit
import Foundation
import RTC
import Synchronization
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized) struct GroupDeliveryWorkerTests {
    @Test(.timeLimit(.minutes(1))) func savedInvitationMakesAnUploadThatTheWorkerCanReceiveWithoutTheBearer() async throws {
        try await withWorker {
            let a = GroupDeliveryTestIdentity("background-author"), b = GroupDeliveryTestIdentity("background-recipient")
            defer { a.remove(); b.remove() }
            try await register(a); try await register(b)
            let sender = try a.harness(knowing: [b], onDisk: true).viewModel
            let recipient = try b.harness(knowing: [a], onDisk: true).viewModel
            defer { sender.stopGroupDeliverySync(); recipient.stopGroupDeliverySync() }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GroupWorkerHTTPBridge.self]
            let session = URLSession(configuration: configuration)
            let client = InternetAccountClient(session: session)
            sender.groupDeliveryClient = nil
            recipient.groupDeliveryClient = client
            recipient.notifications = CallNotifications(store: b.store, memberID: b.memberID, client: client,
                isCurrentUser: { [weak recipient] in recipient?.canStartCalls == true }, contacts: { [weak recipient] in recipient?.savedRemoteUsers ?? [] })
            await recipient.notifications.allowGroupInvitations()
            let permission = try #require(try recipient.notifications.groupPermissionMessage(for: a.memberID, signer: b.signer))
            try sender.notifications.receivePermission(permission, peerID: b.memberID)

            let groupID = UUID()
            try #require(sender.createTalkGroup(name: "Background delivery", userIDs: [b.personID], id: groupID))
            let record = try #require(sender.groupRepository.groupDeliveries.first)
            #expect(record.state == .pending && recipient.groups.isEmpty)
            let request = try #require(try sender.backgroundGroupInvitationRequest(for: record.id))
            #expect(request.url?.path == "/api/notifications/group-invitations/background")
            #expect(request.httpMethod == "POST" && request.value(forHTTPHeaderField: "Authorization") == nil)
            let outbound = try #require(request.httpBody)
            let object = try #require(JSONSerialization.jsonObject(with: outbound) as? [String: String])
            let hasOnlySealedField = Set(object.keys) == ["sealed"]
            let access = try #require(try a.store.notificationAccess(memberID: a.memberID))
            let locator = try #require(access.accessToken.split(separator: ".").dropFirst().first)
            let body = String(decoding: outbound, as: UTF8.self)
            let containsNoCredentials = !body.contains(access.accessToken) && !body.contains(locator)
            #expect(hasOnlySealedField && containsNoCredentials)

            let identity = try #require(try a.store.loadIdentity(memberID: a.memberID))
            let tokenPrefix = access.accessToken.split(separator: ".").dropLast().joined(separator: ".")
            try a.store.save(url: access.origin.absoluteString, token: tokenPrefix + "." + String(repeating: "a", count: 64), identity: identity)
            #expect(try sender.backgroundGroupInvitationRequest(for: record.id) == nil)
            try a.store.save(url: access.origin.absoluteString, token: access.accessToken, identity: identity)

            let reopened = try a.harness(knowing: [b], onDisk: true).viewModel
            defer { reopened.stopGroupDeliverySync() }
            let retry = try #require(try reopened.backgroundGroupInvitationRequest(for: record.id))
            let retryBody = try #require(retry.httpBody)
            let sealedAgain = outbound != retryBody
            #expect(sealedAgain)
            for upload in [request, retry] {
                let (bytes, response) = try await session.data(for: upload)
                try #require((response as? HTTPURLResponse)?.statusCode == 200)
                let reply = try JSONDecoder().decode(GroupDeliveryReply.self, from: bytes)
                #expect(reply.matches(id: record.id, expiresAt: record.expiresAt) && reply.status == .queued)
            }
            await recipient.synchronizeGroupDeliveries()
            #expect(recipient.groups.map(\.id) == [groupID])
            let sameGroupKey = try recipient.groupRepository.credential(for: groupID) == reopened.groupRepository.credential(for: groupID)
            #expect(sameGroupKey)
            reopened.groupDeliveryClient = client
            await reopened.synchronizeGroupDeliveries()
            #expect(reopened.groupInvitationDeliveryState(for: try b.savedUser(), in: groupID) == .received)
            #expect(try reopened.backgroundGroupInvitationRequest(for: record.id) == nil)

            reopened.groupDeliveryClient = nil
            let secondGroup = UUID()
            try #require(reopened.createTalkGroup(name: "Withdrawn background delivery", userIDs: [b.personID], id: secondGroup))
            let pending = try #require(reopened.groupRepository.groupDeliveries.first { $0.groupID == secondGroup })
            let pendingRequest = try #require(try reopened.backgroundGroupInvitationRequest(for: pending.id))
            let (accepted, response) = try await session.data(for: pendingRequest)
            try #require((response as? HTTPURLResponse)?.statusCode == 200)
            let sendKey = try #require(reopened.backgroundGroupInvitationUploadIDs().first { $0.deliveryID == pending.id })
            reopened.applyBackgroundGroupInvitationReply(try JSONDecoder().decode(GroupDeliveryReply.self, from: accepted), for: sendKey)
            try #require(reopened.removeMember(b.memberID, from: secondGroup))
            let cancelKey = try #require(reopened.backgroundGroupInvitationUploadIDs().first { $0.deliveryID == pending.id })
            let cancelRequest = try #require(try reopened.backgroundGroupInvitationRequest(for: pending.id))
            #expect(cancelKey.operation == .cancel)
            #expect(cancelRequest.url?.path == "/api/notifications/group-invitations/background-cancellation")
            #expect(cancelRequest.httpMethod == "POST" && cancelRequest.value(forHTTPHeaderField: "Authorization") == nil)
            let cancelBytes = try #require(cancelRequest.httpBody)
            let cancelObject = try #require(JSONSerialization.jsonObject(with: cancelBytes) as? [String: String])
            let cancelBody = String(decoding: cancelBytes, as: UTF8.self)
            let sealedCancellation = Set(cancelObject.keys) == ["sealed"] && !cancelBody.contains(access.accessToken)
                && !cancelBody.contains(locator)
            #expect(sealedCancellation)
            let (withdrawn, cancellationResponse) = try await session.data(for: cancelRequest)
            try #require((cancellationResponse as? HTTPURLResponse)?.statusCode == 200)
            let cancellation = try JSONDecoder().decode(GroupDeliveryReply.self, from: withdrawn)
            #expect(cancellation.status == .cancelled)
            reopened.applyBackgroundGroupInvitationReply(cancellation, for: cancelKey)
            #expect(reopened.groupRepository.groupDeliveries.first { $0.id == pending.id } == nil)
            await recipient.synchronizeGroupDeliveries()
            #expect(recipient.groups.map(\.id) == [groupID])
        }
    }

    enum ContactMailboxCase: CaseIterable { case group, contact, renewedAuthor, background }

    @Test(.timeLimit(.minutes(1)), arguments: ContactMailboxCase.allCases)
    func contactInvitationCompletesWhileTheTwoAppsConnectAtDifferentTimes(scenario: ContactMailboxCase) async throws {
        try await withWorker {
            let includesGroup = scenario != .contact
            let a = GroupDeliveryTestIdentity("contact-box-author"), b = GroupDeliveryTestIdentity("contact-box-recipient")
            defer { a.remove(); b.remove() }
            try await register(a); try await register(b)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GroupWorkerHTTPBridge.self]
            let session = URLSession(configuration: configuration)
            let client = InternetAccountClient(session: session)
            let left = try a.harness(knowing: [], onDisk: true).viewModel
            let right = try b.harness(knowing: [], onDisk: true).viewModel
            defer { left.stopGroupDeliverySync(); right.stopGroupDeliverySync(); left.disconnect(); right.disconnect() }
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
            let draft = GroupInvitationDraft(name: "Friend", suggestedName: "Rider")
            let personID: UUID
            if includesGroup {
                try #require(left.saveGroupInvitations(groupID: invited, creating: false, name: "", selected: [], newPeople: [draft]) == invited)
                personID = draft.id
            } else {
                left.beginContactInvitationPresentation()
                guard case .person(let id) = left.contactInvitationPresentation else { throw GroupStorageError.invalidUpdate }
                try #require(left.saveContactPerson(id, name: "Friend"))
                personID = id
            }
            let share = try left.prepareContactPersonShare(personID, expectedAccountAccessID: left.accountAccessID)
            left.completeContactInvitationSharing(share)
            // Renewal keeps the same issuing device but revokes its previous opening permission.
            if scenario == .renewedAuthor { try await register(a) }

            let transfer = RecordingBackgroundInvitationTransfer()
            if scenario == .background { right.invitationBackgroundTransfer = transfer }
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
            if scenario == .background {
                let key = try #require(transfer.enqueued.first)
                let queued = transfer.requests[key]
                let request = try #require(queued)
                let (reply, response) = try await session.data(for: request)
                try #require((response as? HTTPURLResponse)?.statusCode == 200)
                transfer.active.remove(key)
                right.applyBackgroundInvitationResponse(reply, for: key)
                await right.invitationInternetReplyWindow?.task?.value
                #expect(right.contactInvitationRecord(share.id)?.internetAcceptanceSubmitted == true)
                #expect(right.contactInvitationRecord(share.id)?.state == .pending)
                #expect(transfer.enqueued.count == 1)
            }
            right.groupDeliveryClient = nil
            right.groupDeliveryNetworkPathChanged(isAvailable: false)

            left.groupDeliveryClient = client
            left.groupDeliveryNetworkPathChanged(isAvailable: false)
            left.groupDeliveryNetworkPathChanged(isAvailable: true)
            await left.invitationInternetReplyWindow?.task?.value
            if scenario == .renewedAuthor {
                #expect(left.contactInvitationRecord(share.id)?.state == .pending)
                right.groupDeliveryClient = client
                right.groupDeliveryNetworkPathChanged(isAvailable: true)
                await right.invitationInternetReplyWindow?.task?.value
                #expect(right.contactInvitationRecord(share.id)?.state == .pending)
                right.groupDeliveryClient = nil
                right.groupDeliveryNetworkPathChanged(isAvailable: false)
                left.groupDeliveryNetworkPathChanged(isAvailable: false)
                left.groupDeliveryNetworkPathChanged(isAvailable: true)
                await left.invitationInternetReplyWindow?.task?.value
            }
            #expect(left.contactInvitationRecord(share.id)?.state == .confirmed)
            #expect(left.contactInvitationRecord(share.id)?.internetAcknowledged == true)
            #expect(left.contactPerson(personID)?.memberIDs == [b.memberID])
            left.groupDeliveryClient = nil

            right.groupDeliveryClient = client
            right.groupDeliveryNetworkPathChanged(isAvailable: true)
            await right.invitationInternetReplyWindow?.task?.value
            #expect(right.contactInvitationRecord(share.id)?.state == .delivered)
            #expect(right.savedRemoteUsers.first?.memberIDs == [a.memberID])
            if includesGroup {
                #expect(left.groups.first { $0.id == invited }?.members.contains { $0.id == b.memberID } == true)
                let sameGroupKey = try right.groupRepository.credential(for: invited) == left.groupRepository.credential(for: invited)
                #expect(sameGroupKey)
            }
            #expect(left.activeGroupID == authorCall && right.activeGroupID == recipientCall)
        }
    }

    @Test(.timeLimit(.minutes(1))) func aRestoredInternetCallRouteResumesSavedOrdinaryInvitationReplies() async throws {
        try await withWorker {
            let author = GroupDeliveryTestIdentity("ordinary-reconnect-author")
            let recipient = GroupDeliveryTestIdentity("ordinary-reconnect-recipient")
            defer { author.remove(); recipient.remove() }
            try await register(author); try await register(recipient)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GroupWorkerHTTPBridge.self]
            let client = InternetAccountClient(session: URLSession(configuration: configuration))
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

            sendToAuthor(mixed)
            let authorWindow = try #require(left.invitationInternetReplyWindow)
            sendToAuthor(mixed)
            #expect(left.invitationInternetReplyWindow?.id == authorWindow.id)
            await authorWindow.task?.value
            #expect(left.savedRemoteUsers.first?.memberIDs == [recipient.memberID])
            sendToAuthor(mixed)
            #expect(left.invitationInternetReplyWindow == nil)

            sendToRecipient(mixed)
            let recipientWindow = try #require(right.invitationInternetReplyWindow?.task)
            await recipientWindow.value
            let completed = right.groupRepository.pendingInvitation(for: invitationGroup) == nil
            #expect(completed)
            #expect(left.currentCallReference == expectedAuthorCall)
            #expect(right.currentCallReference == expectedRecipientCall)
            #expect(left.activeGroupID == authorCall)
            #expect(right.activeGroupID == recipientCall)
        }
    }

    @Test(.timeLimit(.minutes(1))) func lateOrdinaryInvitationReplyArrivesWithoutReturningToTheForeground() async throws {
        try await withWorker {
            let author = GroupDeliveryTestIdentity("ordinary-retry-author")
            let recipient = GroupDeliveryTestIdentity("ordinary-retry-recipient")
            defer { author.remove(); recipient.remove() }
            try await register(author); try await register(recipient)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GroupWorkerHTTPBridge.self]
            let client = InternetAccountClient(session: URLSession(configuration: configuration))
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

            let reads = GroupWorkerHTTPBridge.ordinaryReplyInboxReads.withLock { $0 }
            let link = try #require(left.makeGroupInviteURL(for: invited))
            await AppTestSupport.waitUntil(timeout: .seconds(5)) {
                GroupWorkerHTTPBridge.ordinaryReplyInboxReads.withLock { $0 > reads }
            }
            try #require(GroupWorkerHTTPBridge.ordinaryReplyInboxReads.withLock { $0 > reads })
            let issuerWindow = try #require(left.invitationInternetReplyWindow?.id)
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

    @Test(.timeLimit(.minutes(1))) func ordinaryInvitationOperationsDeliverAfterForegroundResumeAndKeepTheCall() async throws {
        try await withWorker {
            let author = GroupDeliveryTestIdentity("ordinary-reply-lifecycle-author")
            let recipient = GroupDeliveryTestIdentity("ordinary-reply-lifecycle-recipient")
            defer { author.remove(); recipient.remove() }
            try await register(author); try await register(recipient)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GroupWorkerHTTPBridge.self]
            let client = InternetAccountClient(session: URLSession(configuration: configuration))
            let left = try author.harness(knowing: [], onDisk: true).viewModel
            let right = try recipient.harness(knowing: [], onDisk: true).viewModel
            defer { left.stopGroupDeliverySync(); right.stopGroupDeliverySync(); left.disconnect(); right.disconnect() }
            for model in [left, right] {
                model.allowsNearbyGroupDelivery = false
                model.setRTCTransportRoutes([.webRTC])
                model.invitationInternetReplyRetryDelays = []
                #expect(!model.notifications.isEnabled)
            }
            let invited = UUID(), ongoing = UUID(), otherCall = UUID()
            try #require(left.createTalkGroup(name: "Invited", id: invited))
            try #require(left.createTalkGroup(name: "Ongoing", id: ongoing))
            try #require(left.startCall(to: .group(ongoing), accountAccessID: left.accountAccessID))
            try #require(right.createTalkGroup(name: "Other call", id: otherCall))
            try #require(right.startCall(to: .group(otherCall), accountAccessID: right.accountAccessID))
            let oldCall = left.currentCallReference
            let oldInviteeCall = right.currentCallReference

            left.groupDeliveryClient = client; right.groupDeliveryClient = client
            var leftWindows = 0, rightWindows = 0
            left.beginGroupDeliveryBackgroundTime = { _ in leftWindows += 1; return {} }
            right.beginGroupDeliveryBackgroundTime = { _ in rightWindows += 1; return {} }
            let link = try #require(left.makeGroupInviteURL(for: invited))
            let opening = try #require(left.invitationInternetReplyWindow?.task)
            await opening.value
            #expect(leftWindows == 1)

            try right.acceptInviteURL(link)
            let accepting = try #require(right.invitationInternetReplyWindow?.task)
            await accepting.value
            #expect(rightWindows == 1)
            let pending = right.groupRepository.pendingInvitation(for: invited) != nil
            #expect(pending)
            #expect(left.savedRemoteUsers.isEmpty)
            #expect(right.currentCallReference == oldInviteeCall)
            #expect(right.activeGroupID == otherCall)

            let issuerOwner = AppCallOwner(account: left.accountSession, viewModel: left)
            GroupWorkerHTTPBridge.interruptOrdinaryGroupAcknowledgement = true
            defer { GroupWorkerHTTPBridge.interruptOrdinaryGroupAcknowledgement = false }
            issuerOwner.systemSurfaceIsForeground = true
            let delivering = try #require(left.invitationInternetReplyWindow?.task)
            await delivering.value
            #expect(!GroupWorkerHTTPBridge.interruptOrdinaryGroupAcknowledgement)
            #expect(left.savedRemoteUsers.first?.memberIDs == [recipient.memberID])
            #expect(left.currentCallReference == oldCall)
            #expect(left.activeGroupID == ongoing)
            let savedUser = left.savedRemoteUsers.first?.id
            right.disconnect()

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
            #expect(left.savedRemoteUsers.map(\.id) == [savedUser].compactMap { $0 })
            #expect(left.currentCallReference == oldCall)

            inviteeOwner.systemSurfaceIsForeground = false
            inviteeOwner.systemSurfaceIsForeground = true
            await reopened.invitationInternetReplyWindow?.task?.value
            let completed = reopened.groupRepository.pendingInvitation(for: invited) == nil
            #expect(completed)
            #expect(reopened.savedRemoteUsers.first?.memberIDs == [author.memberID])
            #expect(reopened.activeGroupID == nil)
            let persisted = try recipient.harness(knowing: [], onDisk: true).viewModel.groupRepository.pendingInvitation(for: invited) == nil
            #expect(persisted)

            let personOnLeft = try #require(left.savedRemoteUsers.first)
            let personOnRight = try #require(reopened.savedRemoteUsers.first)
            let leftPrincipal = try author.principal, rightPrincipal = try recipient.principal
            try #require(personOnLeft.principal == rightPrincipal && personOnRight.principal == leftPrincipal)
            let pair = AccountCallPair(leftPrincipal, rightPrincipal)
            try #require(left.existingDirectCall(for: personOnLeft.id) == nil && reopened.existingDirectCall(for: personOnRight.id) == nil)
            left.disconnect()
            try #require(left.startCall(to: .user(personOnLeft.id), accountAccessID: left.accountAccessID))
            try #require(reopened.startCall(to: .user(personOnRight.id), accountAccessID: reopened.accountAccessID))
            #expect(left.activeGroupID == pair.id && reopened.activeGroupID == pair.id)
            let firstKey = try left.groupRepository.credential(for: pair.id)
            let secondKey = try reopened.groupRepository.credential(for: pair.id)
            let match = firstKey != nil && firstKey == secondKey
            #expect(match)
        }
    }

    @Test(.timeLimit(.minutes(1))) func reopenedInviterReceivesRepliesForBothIssuedGroupLinks() async throws {
        try await withWorker {
            let author = GroupDeliveryTestIdentity("multi-ordinary-author")
            let recipient = GroupDeliveryTestIdentity("multi-ordinary-recipient")
            defer { author.remove(); recipient.remove() }
            try await register(author); try await register(recipient)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GroupWorkerHTTPBridge.self]
            let client = InternetAccountClient(session: URLSession(configuration: configuration))
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

    enum RelayedInvitation: CaseIterable { case group, contact, contactWithGroup }

    @Test(.timeLimit(.minutes(1)), arguments: RelayedInvitation.allCases)
    func workerCarriesEncryptedAcceptanceAndAcknowledgement(invitation: RelayedInvitation) async throws {
        try await withWorker {
            let author = GroupDeliveryTestIdentity("ordinary-reply-author")
            let recipient = GroupDeliveryTestIdentity("ordinary-reply-recipient")
            defer { author.remove(); recipient.remove() }
            try await register(author); try await register(recipient)
            let left = try #require(try author.store.notificationAccess(memberID: author.memberID))
            let right = try #require(try recipient.store.notificationAccess(memberID: recipient.memberID))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GroupWorkerHTTPBridge.self]
            let client = InternetAccountClient(session: URLSession(configuration: configuration))
            let authority = testInvitationAuthority()
            let key = GroupAccessCredential(groupID: UUID(), secret: "worker-ordinary-reply-fixture")
            let token: GroupInviteToken
            if invitation == .group {
                token = try GroupInviteToken.make(authority: authority, signer: author.signer, groupID: key.groupID,
                    groupName: "Test group", groupSecret: key.secret, inviterMemberID: author.memberID)
            } else {
                let group = invitation == .contactWithGroup ? ContactGroupInvitation(id: key.groupID, name: "Test group", secret: key.secret) : nil
                let issued = try ContactInvitationSession.makeToken(authority: authority, signer: author.signer, displayName: "Sender",
                    now: Date().timeIntervalSince1970, invitedGroup: group)
                let url = try GroupInviteTokenCodec.joinURL(for: issued, contactBootstrap: true)
                token = try GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true)
            }
            let invite = try #require(token.directInvitation?.context)
            let accepted = try token.accept(signer: recipient.signer, displayName: "Recipient",
                trust: recipient.store.identityTrust(), contactBootstrap: invitation == .group ? nil : true)
            #expect(accepted.inviter.principal == left.principal)
            let address = try invitation == .group
                ? InvitationReplyAddress(invitation: invite, credential: key)
                : InvitationReplyAddress(contactToken: token)
            let admission: ContactInvitationReplyAdmission?
            if invitation != .group {
                let trust = try recipient.store.identityTrust()
                admission = try #require(ContactInvitationReplyAdmission(token: token, address: address, trust: trust))
                #expect(admission?.owner == left.principal)
                var otherContext = invite
                otherContext.contactBootstrap = nil
                otherContext.invitedGroupID = nil
                otherContext.invitedGroupDigest = nil
                let ordinarySlot = try InvitationReplyAddress(invitation: otherContext,
                    credential: .init(groupID: token.groupID, secret: token.groupSecret))
                #expect(ordinarySlot.slot != address.slot)
                #expect(ContactInvitationReplyAdmission(token: token, address: ordinarySlot, trust: trust) == nil)
                #expect(ContactInvitationReplyAdmission(token: token, address: address, trust: trust,
                    now: Date(timeIntervalSince1970: invite.expiresAt)) == nil)
            } else {
                admission = nil
            }
            let packet = try InvitationReplyPacket.seal(accepted.receipt, address: address, invitation: invite)
            let absent = try await client.invitationReplyReceipt(id: packet.id, address: address, owner: left.principal, access: right)
            #expect(absent == nil)
            if invitation == .group { try await client.openInvitationReplyMailbox(address, access: left) }
            try await client.submitInvitationAcceptance(packet, address: address, owner: left.principal, access: right, admission: admission)
            let inbox = try await client.invitationReplyInbox(address, access: left)
            #expect(inbox.count == 1)
            let first = try #require(inbox.first)
            let received = try first.open(address: address, invitation: invite, kind: .accepted, signer: author.signer)
            let verified = try authority.verify(received, trust: author.store.identityTrust())
            #expect(verified?.identity.principal == right.principal)
            let reply = try InvitationReplyPacket.seal(received.acknowledged(by: author.signer), address: address, invitation: invite)
            try await client.acknowledgeInvitationReply(reply, address: address, access: left)
            let delivered = try await client.invitationReplyReceipt(id: packet.id, address: address, owner: left.principal, access: right)
            let acknowledgement = try #require(delivered).open(address: address, invitation: invite, kind: .acknowledged, signer: recipient.signer)
            try acknowledgement.verifyAcknowledgement(of: accepted.receipt, trust: recipient.store.identityTrust(), now: Date().timeIntervalSince1970)
            #expect(try await client.invitationReplyInbox(address, access: left).isEmpty)
        }
    }

    @Test(.timeLimit(.minutes(1))) func workerInboxReadsEightMaximumSizePackets() async throws {
        try await withWorker {
            let author = GroupDeliveryTestIdentity("ordinary-reply-limit-author")
            let participants = (0..<8).map { GroupDeliveryTestIdentity("ordinary-reply-limit-\($0)") }
            defer { author.remove(); participants.forEach { $0.remove() } }
            try await register(author)
            let access = try #require(try author.store.notificationAccess(memberID: author.memberID))
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GroupWorkerHTTPBridge.self]
            let client = InternetAccountClient(session: URLSession(configuration: configuration))
            let key = GroupAccessCredential(groupID: UUID(), secret: "worker-ordinary-reply-limit")
            let invitation = DirectInvitationContext(groupID: key.groupID, inviterMemberID: author.memberID,
                inviterDeviceKey: try author.signer.publicKey, expiresAt: Date().timeIntervalSince1970 + 60)
            let address = try InvitationReplyAddress(invitation: invitation, credential: key)
            try await client.openInvitationReplyMailbox(address, access: access)
            let data = String(repeating: "A", count: 12 * 1024)
            var ids = Set<UUID>()
            for participant in participants {
                try await register(participant)
                let recipient = try #require(try participant.store.notificationAccess(memberID: participant.memberID))
                let packet = InvitationReplyPacket(id: UUID(), packet: data)
                ids.insert(packet.id)
                try await client.submitInvitationAcceptance(packet, address: address, owner: access.principal, access: recipient)
            }
            let results = try await client.invitationReplyInbox(address, access: access)
            #expect(Set(results.map(\.id)) == ids)
            let sizesMatch = results.allSatisfy { $0.packet.utf8.count == 12 * 1024 }
            #expect(sizesMatch)
        }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [1, 9]) func theActualWorkerDeliversAndAcknowledgesAGroupWithoutStartingTheRecipientsCall(count: Int) async throws {
        try await withWorker { try await exerciseGroupDelivery(count: count) }
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func theActualWorkerCompletesContactDeletionAfterRevokingTheNotificationGrant(bothRemoved: Bool) async throws {
        try await withWorker {
            let a = GroupDeliveryTestIdentity("worker-contact-delete-author")
            let b = GroupDeliveryTestIdentity("worker-contact-delete-recipient")
            defer { a.remove(); b.remove() }
            try await register(a); try await register(b)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [GroupWorkerHTTPBridge.self]
            let client = InternetAccountClient(session: URLSession(configuration: configuration))
            let ownerAccess = try #require(try a.store.notificationAccess(memberID: a.memberID))
            let recipientAccess = try #require(try b.store.notificationAccess(memberID: b.memberID))
            let grant = try await client.issueNotificationGrant(origin: recipientAccess.origin, token: recipientAccess.accessToken,
                                                                 senderUserID: ownerAccess.principal.userID)
            try await client.revokeNotificationGrant(origin: recipientAccess.origin, token: recipientAccess.accessToken, grantID: grant.grantID)
            let sender = try a.harness(knowing: [], onDisk: true).viewModel
            let recipient = try b.harness(knowing: [], onDisk: true).viewModel
            defer { sender.stopGroupDeliverySync(); recipient.stopGroupDeliverySync() }
            for model in [sender, recipient] {
                model.groupDeliveryClient = nil
                model.contactSessionFactory = { RecordingCallSession() }
                #expect(!model.notifications.isEnabled)
            }
            try recipient.acceptContactInviteURL(try #require(sender.makeContactInviteURL()))
            let invitation = try #require(recipient.pendingContactInvitations.first?.id)
            try sender.receiveContactReplyURL(recipient.contactReplyURLForSharing(invitation, expectedAccountAccessID: recipient.accountAccessID))
            sender.stopContactInvitationSession(); recipient.stopContactInvitationSession()
            try #require(sender.removeSavedUser(try #require(sender.savedRemoteUsers.first).id))
            if bothRemoved { try #require(recipient.removeSavedUser(try #require(recipient.savedRemoteUsers.first).id)) }
            let first = try #require(sender.groupRepository.contactDeletionPublications.first)
            let reverse = recipient.groupRepository.contactDeletionPublications.first

            let left = try a.harness(knowing: [], onDisk: true).viewModel
            let right = try b.harness(knowing: [], onDisk: true).viewModel
            defer { left.stopGroupDeliverySync(); right.stopGroupDeliverySync() }
            left.groupDeliveryClient = client; right.groupDeliveryClient = client
            await left.synchronizeGroupDeliveries()
            await right.synchronizeGroupDeliveries()
            await left.synchronizeGroupDeliveries()
            await right.synchronizeGroupDeliveries()
            #expect(left.savedRemoteUsers.isEmpty && right.savedRemoteUsers.isEmpty)
            #expect(left.groupRepository.contactDeletions.isEmpty && right.groupRepository.contactDeletions.isEmpty)
            #expect(left.groupRepository.contactDeletionPublications.isEmpty && right.groupRepository.contactDeletionPublications.isEmpty)
            #expect(left.groupRepository.contactDeletionRelayReceipts.isEmpty && right.groupRepository.contactDeletionRelayReceipts.isEmpty)
            #expect(right.groupRepository.contactDeletionReceipts.map(\.id) == [first.id])
            #expect(try await client.writeContactDeletion(first, access: ownerAccess) == .retired)
            if bothRemoved {
                let reverse = try #require(reverse)
                #expect(left.groupRepository.contactDeletionReceipts.map(\.id) == [reverse.id])
                #expect(try await client.writeContactDeletion(reverse, access: recipientAccess) == .retired)
            }
        }
    }

    private func withWorker(_ exercise: () async throws -> Void) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("RideIntercom-GroupWorker-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let portFile = directory.appendingPathComponent("port.json"), logFile = directory.appendingPathComponent("fixture.log")
        _ = FileManager.default.createFile(atPath: logFile.path, contents: Data())
        let log = try FileHandle(forWritingTo: logFile), process = Process()
        defer {
            if process.isRunning { process.terminate(); process.waitUntilExit() }
            try? log.close(); try? FileManager.default.removeItem(at: directory)
        }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", root.appendingPathComponent("server/test/group-delivery-app-bridge.mjs").path, portFile.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment; process.standardOutput = log; process.standardError = log
        try process.run()
        let deadline = ContinuousClock.now + .seconds(15)
        while !FileManager.default.fileExists(atPath: portFile.path), process.isRunning, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        guard FileManager.default.fileExists(atPath: portFile.path) else { throw WorkerFixtureFailure.unavailable }
        let fields = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: portFile)) as? [String: Int])
        let port = try #require(fields["port"])
        GroupWorkerHTTPBridge.origin = URL(string: "http://127.0.0.1:\(port)")!
        defer { GroupWorkerHTTPBridge.origin = nil }
        try await exercise()
    }

    private func exerciseGroupDelivery(count: Int) async throws {
        let a = GroupDeliveryTestIdentity("worker-author"), b = GroupDeliveryTestIdentity("worker-recipient")
        defer { a.remove(); b.remove() }
        try await register(a); try await register(b)
        let left = try a.harness(knowing: [b], onDisk: true), right = try b.harness(knowing: [a], onDisk: true)
        defer { left.viewModel.stopGroupDeliverySync(); right.viewModel.stopGroupDeliverySync(); left.viewModel.disconnect(); right.viewModel.disconnect() }
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [GroupWorkerHTTPBridge.self]
        let client = InternetAccountClient(session: URLSession(configuration: configuration))
        left.viewModel.groupDeliveryClient = nil; right.viewModel.groupDeliveryClient = client
        right.viewModel.notifications = CallNotifications(store: b.store, memberID: b.memberID, client: client,
            isCurrentUser: { [weak model = right.viewModel] in model?.canStartCalls == true }, contacts: { [weak model = right.viewModel] in model?.savedRemoteUsers ?? [] })
        await right.viewModel.notifications.allowGroupInvitations()
        let permission = try #require(try right.viewModel.notifications.groupPermissionMessage(for: a.memberID, signer: b.signer))
        #expect(permission.groupGrant != nil)
        try left.viewModel.notifications.receivePermission(permission, peerID: b.memberID)
        var invitedGroups = Set<UUID>()
        for index in 0..<count {
            let id = UUID(); invitedGroups.insert(id)
            #expect(left.viewModel.createTalkGroup(name: "Actual Worker group \(index)", userIDs: [b.personID], id: id))
        }
        let revokedAfterDownload = UUID()
        #expect(left.viewModel.createTalkGroup(name: "Cancelled after download", userIDs: [b.personID], id: revokedAfterDownload))
        let revokedGroupID = UUID()
        #expect(left.viewModel.createTalkGroup(name: "Removed before receipt", userIDs: [b.personID], id: revokedGroupID))
        let cancelledBeforeSend = UUID()
        #expect(left.viewModel.createTalkGroup(name: "Cancelled before arrival", userIDs: [b.personID], id: cancelledBeforeSend))
        let unsent = try #require(left.viewModel.groupRepository.groupDeliveries.first { $0.groupID == cancelledBeforeSend })
        let sender = try #require(try a.store.notificationAccess(memberID: a.memberID))
        // Exercise the same HTTP DELETE after an ambiguous upload, while the Worker has no row.
        try await client.finishGroupInvitation(recipient: unsent.recipient, id: unsent.id, access: sender)
        left.viewModel.groupDeliveryClient = client
        let group = try #require(left.viewModel.groups.first(where: { invitedGroups.contains($0.id) }))
        let call = left.viewModel.currentCallReference
        let recipientCall = right.viewModel.currentCallReference
        await left.viewModel.synchronizeGroupDeliveries()
        let author = left.viewModel
        #expect(author.groupRepository.groupDeliveries.first(where: { $0.id == unsent.id })?.state == .cancelled)
        let revoked = try #require(author.groupRepository.groupDeliveries.first(where: { $0.groupID == revokedGroupID }))
        #expect(revoked.state == .queued)
        var requested = 0, released = 0
        author.beginGroupDeliveryBackgroundTime = { _ in
            requested += 1
            return { released += 1 }
        }
        author.removeMember(b.memberID, from: revokedGroupID)
        #expect(requested == 1, "Request time before returning from the removal")
        #expect(author.groupRepository.groupDeliveries.first(where: { $0.id == revoked.id })?.state == .cancelled)
        await author.groupDeliveryTask?.value
        #expect(released == 1)
        #expect(!author.groupRepository.groupDeliveries.contains { $0.id == revoked.id })
        #expect(author.savedRemoteUsers.contains { $0.id == b.personID })
        let afterDownload = try #require(author.groupRepository.groupDeliveries.first { $0.groupID == revokedAfterDownload })
        #expect(afterDownload.state == .queued)
        GroupWorkerHTTPBridge.cancellation = (afterDownload.id, try b.principal.userID, sender.accessToken)
        let lostReceipt = try #require(author.groupRepository.groupDeliveries.first { $0.groupID == group.id })
        GroupWorkerHTTPBridge.dropReceiptForID = lostReceipt.id
        defer {
            GroupWorkerHTTPBridge.cancellation = nil; GroupWorkerHTTPBridge.cancellationResponse = nil
            GroupWorkerHTTPBridge.dropReceiptForID = nil; GroupWorkerHTTPBridge.didDropReceipt = false
        }
        await right.viewModel.synchronizeGroupDeliveries()
        #expect(GroupWorkerHTTPBridge.didDropReceipt)
        #expect(!right.viewModel.groups.contains { $0.id == group.id })
        #expect(right.viewModel.groupRepository.groupDeliveries.first(where: { $0.id == lostReceipt.id })?.state == .pending)
        #expect(right.viewModel.currentCallReference == recipientCall && left.viewModel.currentCallReference == call)
        right.viewModel.stopGroupDeliverySync(); right.viewModel.disconnect()
        let reopened = try b.harness(knowing: [a], onDisk: true)
        defer { reopened.viewModel.stopGroupDeliverySync(); reopened.viewModel.disconnect() }
        let receiver = reopened.viewModel
        #expect(!receiver.groups.contains { $0.id == group.id })
        let reopenedCall = receiver.currentCallReference
        receiver.groupDeliveryClient = client
        await receiver.synchronizeGroupDeliveries()
        #expect(GroupWorkerHTTPBridge.cancellationResponse == "cancelled")
        #expect(!receiver.groups.contains { $0.id == revokedAfterDownload }, "Cancellation between downloading and saving should suppress the incoming group")
        #expect(try receiver.groupRepository.credential(for: revokedAfterDownload) == nil)
        #expect(receiver.groupRepository.groupDeliveries.first(where: { $0.id == afterDownload.id })?.credentialReference == nil)
        #expect(invitedGroups.isSubset(of: Set(receiver.groups.map(\.id))))
        #expect(receiver.groups.filter { $0.id == group.id }.count == 1)
        #expect(!receiver.groups.contains { $0.id == revokedGroupID })
        #expect(!receiver.groups.contains { $0.id == cancelledBeforeSend })
        #expect(receiver.currentCallReference == reopenedCall)
        #expect(receiver.activeGroupID == nil && !receiver.hasAnyActiveGroupConnection && reopened.callSession.connectedGroup == nil)
        let source = try #require(try left.viewModel.groupRepository.credential(for: group.id))
        let target = try #require(try receiver.groupRepository.credential(for: group.id))
        #expect(SHA256.hash(data: Data(source.secret.utf8)) == SHA256.hash(data: Data(target.secret.utf8)))
        await left.viewModel.synchronizeGroupDeliveries()
        #expect(left.viewModel.groupRepository.groupDeliveries.filter { $0.state == .received }.count == count)
        #expect(left.viewModel.groupRepository.groupDeliveries.first(where: { $0.id == afterDownload.id })?.state == .cancelled)
        #expect(left.viewModel.groupRepository.groupDeliveries.allSatisfy { $0.credentialReference == nil })
        #expect(receiver.groupRepository.groupDeliveries.first(where: { $0.id == lostReceipt.id })?.state == .received)
        #expect(receiver.savedRemoteUsers.count == 1)

        let collision = UUID(), followUp = UUID()
        #expect(receiver.createTalkGroup(name: "Saved locally", id: collision))
        let localCredential = try #require(try receiver.groupRepository.credential(for: collision))
        let localCall = receiver.currentCallReference
        #expect(author.createTalkGroup(name: "Conflicting invitation", userIDs: [b.personID], id: collision))
        await author.synchronizeGroupDeliveries()
        let conflict = try #require(author.groupRepository.groupDeliveries.first { $0.groupID == collision })
        #expect(conflict.state == .queued)
        await receiver.synchronizeGroupDeliveries()
        #expect(author.createTalkGroup(name: "Valid invitation after conflict", userIDs: [b.personID], id: followUp))
        await author.synchronizeGroupDeliveries()
        await receiver.synchronizeGroupDeliveries()
        await author.synchronizeGroupDeliveries()
        let recipientAccess = try #require(try b.store.notificationAccess(memberID: b.memberID))
        #expect(try await client.acknowledgeGroupInvitation(conflict.id, access: recipientAccess) == .cancelled)
        #expect(!author.groupRepository.groupDeliveries.contains { $0.id == conflict.id && $0.state != .cancelled })
        #expect(receiver.groups.first(where: { $0.id == followUp })?.name == "Valid invitation after conflict")
        #expect(receiver.groups.first(where: { $0.id == collision })?.name == "Saved locally")
        #expect(try receiver.groupRepository.credential(for: collision) == localCredential)
        #expect(receiver.currentCallReference == localCall && receiver.groupErrorMessage == nil)

        let person = try b.savedUser()
        let firstReceipt = try #require(author.groupInvitationDeliveries(in: followUp).first)
        #expect(firstReceipt.state == .received)
        #expect(author.removeMember(b.memberID, from: followUp))
        #expect(receiver.deleteGroup(followUp))
        #expect(author.addSavedUsers([person.id], to: followUp))
        #expect(author.groupInvitationDeliveryState(for: person, in: followUp) == .pending)
        #expect(author.groupInvitationDeliveries(in: followUp).count == 1)
        let newDelivery = try #require(author.groupInvitationDeliveries(in: followUp).first { $0.id != firstReceipt.id })
        await author.synchronizeGroupDeliveries()
        #expect(author.groupInvitationDeliveryState(for: person, in: followUp) == .pending)
        #expect(!receiver.groups.contains { $0.id == followUp })
        await receiver.synchronizeGroupDeliveries()
        await author.synchronizeGroupDeliveries()
        #expect(author.groupInvitationDeliveries(in: followUp).map(\.id) == [newDelivery.id])
        #expect(author.groupInvitationDeliveryState(for: person, in: followUp) == .received)
        #expect(receiver.groups.filter { $0.id == followUp }.count == 1)
        try #require(author.removeMember(b.memberID, from: revokedAfterDownload))
        for id in invitedGroups {
            // The first device received these groups. Removing it must also
            // stop automatic delivery to a new device of the same account.
            try #require(author.removeMember(b.memberID, from: id))
        }

        let automatic = GroupDeliveryTestIdentity("worker-recipient-automatic")
        defer { automatic.remove() }
        try await register(automatic, appleSubject: b.memberID)
        let automaticReceiver = try automatic.harness(knowing: [], onDisk: true).viewModel
        defer { automaticReceiver.stopGroupDeliverySync(); automaticReceiver.disconnect() }
        automaticReceiver.groupDeliveryClient = client
        let automaticCall = automaticReceiver.currentCallReference
        await automaticReceiver.synchronizeGroupDeliveries()
        await author.synchronizeGroupDeliveries()
        let automaticPackets = author.groupInvitationDeliveries(in: followUp).filter { $0.recipientMemberID == automatic.memberID }
        #expect(automaticPackets.count == 1)
        let automaticPacket = try #require(automaticPackets.first)
        #expect(automaticPacket.noticeID == newDelivery.noticeID && automaticPacket.expiresAt == newDelivery.expiresAt)
        #expect(automaticPacket.sourceRequestID == newDelivery.id)
        var changedSource = try author.groupRepository.groupDeliveryEnvelope(automaticPacket.id)
        changedSource.sourceRequestID = UUID()
        let trust = try #require(try automatic.store.identityTrust())
        #expect(throws: (any Error).self) {
            try changedSource.open(recipient: automatic.signer, local: automatic.principal, sender: nil, redeliveryTrust: trust)
        }
        #expect(author.savedRemoteUsers.first { $0.id == person.id }?.memberIDs.contains(automatic.memberID) == false)
        GroupWorkerHTTPBridge.dropReceiptForID = automaticPacket.id
        GroupWorkerHTTPBridge.didDropReceipt = false
        await automaticReceiver.synchronizeGroupDeliveries()
        #expect(GroupWorkerHTTPBridge.didDropReceipt)
        #expect(!automaticReceiver.groups.contains { $0.id == followUp })
        #expect(automaticReceiver.groupRepository.groupDeliveries.first { $0.id == automaticPacket.id }?.state == .pending)
        #expect(automaticReceiver.currentCallReference == automaticCall)
        automaticReceiver.stopGroupDeliverySync()
        automaticReceiver.disconnect()
        let reloadedAutomatic = try automatic.harness(knowing: [], onDisk: true).viewModel
        defer { reloadedAutomatic.stopGroupDeliverySync(); reloadedAutomatic.disconnect() }
        reloadedAutomatic.groupDeliveryClient = client
        await reloadedAutomatic.synchronizeGroupDeliveries()
        #expect(reloadedAutomatic.groups.filter { $0.id == followUp }.count == 1)
        #expect(!reloadedAutomatic.groups.contains { $0.id == revokedAfterDownload })
        #expect(Set(reloadedAutomatic.groups.map(\.id)).isDisjoint(with: invitedGroups))
        #expect(reloadedAutomatic.savedRemoteUsers.isEmpty && reloadedAutomatic.activeGroupID == nil)
        #expect(try reloadedAutomatic.groupRepository.credential(for: followUp) == author.groupRepository.credential(for: followUp))
        await author.synchronizeGroupDeliveries()
        #expect(author.groupInvitationDeliveries(in: followUp).filter { $0.recipientMemberID == automatic.memberID }.count == 1)

        // The same recipient signs into a second device with its own key and an empty directory.
        let second = GroupDeliveryTestIdentity("worker-recipient-second")
        defer { second.remove() }
        try await register(second, appleSubject: b.memberID)
        #expect(try second.principal == b.principal)
        let secondReceiver = try second.harness(knowing: [], onDisk: true).viewModel
        defer { secondReceiver.stopGroupDeliverySync(); secondReceiver.stopContactInvitationSession(); secondReceiver.disconnect() }
        secondReceiver.groupDeliveryClient = client
        struct AdditionalAddress: Decodable, Equatable, Sendable {
            let memberID: String
            let recipientKey: String
        }
        struct AdditionalDevices: Decodable, Sendable {
            let devices: [AdditionalAddress]
        }
        let path = "api/notifications/group-invitations/\(newDelivery.recipient.userID)/\(newDelivery.id.uuidString.lowercased())/additional-devices"
        func workerAddresses() async throws -> [AdditionalAddress] {
            let response: AdditionalDevices = try await client.sendJSON(origin: sender.origin, path: path,
                method: "GET", token: sender.accessToken)
            return response.devices
        }
        let earlierAddresses = try await workerAddresses()
        #expect(earlierAddresses.count == 1 && earlierAddresses.first?.memberID == automatic.memberID)
        await author.synchronizeGroupDeliveries()
        await secondReceiver.synchronizeGroupDeliveries()
        await secondReceiver.synchronizeGroupDeliveries()
        let address = AdditionalAddress(memberID: second.memberID, recipientKey: try second.signer.publicKey)
        let currentAddresses = try await workerAddresses()
        #expect(currentAddresses.count == 2 && currentAddresses.contains(address))
        #expect(secondReceiver.savedRemoteUsers.isEmpty && secondReceiver.groups.isEmpty)
        #expect(!author.groupInvitationDeliveries(in: followUp).contains { $0.recipientMemberID == second.memberID })

        let contact = try #require(author.makeContactInviteURL())
        author.stopContactInvitationSession()
        try secondReceiver.acceptContactInviteURL(contact)
        secondReceiver.stopContactInvitationSession()
        let contactID = try #require(secondReceiver.groupRepository.contactInvitations.first?.id)
        let reply = try secondReceiver.contactReplyURLForSharing(contactID, expectedAccountAccessID: secondReceiver.accountAccessID)
        let secondCall = secondReceiver.currentCallReference
        let backgroundRequestsBeforeReply = requested
        try author.receiveContactReplyURL(reply)
        try author.receiveContactReplyURL(reply)
        #expect(requested == backgroundRequestsBeforeReply + 1)
        #expect(author.savedRemoteUsers.first { $0.id == person.id }?.memberIDs.contains(second.memberID) == true)
        let relayed = author.groupInvitationDeliveries(in: followUp).filter { $0.recipientMemberID == second.memberID }
        #expect(relayed.count == 1)
        if let packet = relayed.first {
            #expect(packet.noticeID == newDelivery.noticeID && packet.expiresAt == newDelivery.expiresAt)
        }
        #expect(!author.groupInvitationDeliveries(in: revokedAfterDownload).contains { $0.recipientMemberID == second.memberID })
        await author.groupDeliveryTask?.value
        var receivingStarts = 0, receivingEnds = 0
        secondReceiver.beginGroupDeliveryBackgroundTime = { _ in
            receivingStarts += 1
            return { receivingEnds += 1 }
        }
        let notice = try #require(GroupInvitationTap(payload: ["version": 1, "kind": "groupInvitation",
            "requestID": newDelivery.noticeID.uuidString, "recipientID": try second.principal.userID]))
        let owner = AppCallOwner(account: secondReceiver.accountSession, viewModel: secondReceiver)
        #expect(await owner.respondToGroupInvitation(notice))
        #expect(receivingStarts == 1 && receivingEnds == 1)
        #expect(secondReceiver.groups.filter { $0.id == followUp }.count == 1)
        #expect(!secondReceiver.groups.contains { $0.id == revokedAfterDownload })
        #expect(secondReceiver.currentCallReference == secondCall && secondReceiver.activeGroupID == nil)
        let onSecondDevice = try second.harness(knowing: [], onDisk: true).viewModel
        defer { onSecondDevice.stopGroupDeliverySync(); onSecondDevice.disconnect() }
        let secondKey = try onSecondDevice.groupRepository.credential(for: followUp)?.secret
        let sourceKey = try #require(try author.groupRepository.credential(for: followUp)).secret
        let keyMatches = secondKey == sourceKey
        #expect(keyMatches)
    }
    private func register(_ peer: GroupDeliveryTestIdentity, appleSubject: String? = nil) async throws {
        struct Registration: Decodable { let credential: InternetAccountCredential; let identity: DeviceIdentityCertificate }
        var request = URLRequest(url: try #require(GroupWorkerHTTPBridge.origin).appendingPathComponent("fixture/register"))
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["memberID": peer.memberID, "deviceID": peer.store.accountDeviceID(),
            "appleSubject": appleSubject ?? peer.memberID,
            "deviceKey": IdentityEncoding.encode(peer.store.deviceSigningKey().publicKey.x963Representation)])
        let (data, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let value = try JSONDecoder().decode(Registration.self, from: data)
        let identity = try value.identity.verify(origin: URL(string: "https://delivery.test")!, trustedIssuerKey: value.identity.issuerKey)
        try peer.store.save(url: "https://delivery.test", token: value.credential.accessToken, identity: identity)
    }
}
private enum WorkerFixtureFailure: Error { case unavailable }

private final class GroupWorkerHTTPBridge: URLProtocol, @unchecked Sendable {
    nonisolated static let ordinaryReplyInboxReads = Mutex(0)
    nonisolated(unsafe) static var origin: URL?
    nonisolated(unsafe) static var cancellation: (id: UUID, recipient: String, token: String)?
    nonisolated(unsafe) static var cancellationResponse: String?
    nonisolated(unsafe) static var dropReceiptForID: UUID?
    nonisolated(unsafe) static var didDropReceipt = false
    nonisolated(unsafe) static var interruptOrdinaryGroupAcknowledgement = false
    private var requestWork: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "delivery.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var forwarded = request
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var data = Data(), buffer = [UInt8](repeating: 0, count: 8192)
            while true { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
            forwarded.httpBody = data
        }
        guard let base = Self.origin, let original = request.url else { return }
        if Self.interruptOrdinaryGroupAcknowledgement, original.path == "/api/ordinary-group-replies/acknowledgement" {
            Self.interruptOrdinaryGroupAcknowledgement = false
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        var components = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        components.path = original.path; components.percentEncodedQuery = URLComponents(url: original, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        forwarded.url = components.url
        let value = forwarded
        requestWork = Task { [self] in
            do {
                let (data, result) = try await URLSession.shared.data(for: value)
                let status = (result as? HTTPURLResponse)?.statusCode ?? 500
                if status == 200, value.url?.path == "/api/ordinary-group-replies/inbox" {
                    Self.ordinaryReplyInboxReads.withLock { $0 += 1 }
                }
                if value.httpMethod == "DELETE", status == 200,
                   let id = Self.dropReceiptForID, value.url?.lastPathComponent == id.uuidString.lowercased(),
                   let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: String], receipt["status"] == "received" {
                    Self.dropReceiptForID = nil
                    Self.didDropReceipt = true
                    client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
                    return
                }
                if value.httpMethod == "GET", value.url?.path == "/api/notifications/group-invitations",
                   let cancellation = Self.cancellation,
                   let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let delivery = result["delivery"] as? [String: Any],
                   let id = delivery["requestID"] as? String, UUID(uuidString: id) == cancellation.id {
                    let path = "api/notifications/group-invitations/\(cancellation.recipient)/\(id)"
                    var cancel = URLRequest(url: base.appendingPathComponent(path))
                    cancel.httpMethod = "DELETE"
                    cancel.setValue("Bearer " + cancellation.token, forHTTPHeaderField: "Authorization")
                    let (data, response) = try await URLSession.shared.data(for: cancel)
                    if (response as? HTTPURLResponse)?.statusCode == 200,
                       let body = try JSONSerialization.jsonObject(with: data) as? [String: String] {
                        Self.cancellationResponse = body["status"]
                    }
                }
                let response = HTTPURLResponse(url: original, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
    }
    override func stopLoading() { requestWork?.cancel() }
}
#endif
