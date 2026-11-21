import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct OrdinaryGroupReplyTransportTests {
    // Browsing several invitations can take over 12 seconds on the simulator.
    // Allow discovery to finish within the application's 60-second attempt.
    private let replyTimeout: Duration = .seconds(30)

    @Test(arguments: [1, 2])
    func aRestoredLocalCallRouteResumesExpiredOrdinaryReplyAttempts(invitationCount: Int) async throws {
        let author = AppTestSupport.makeHarness(groups: [], localMemberID: "alice")
        let recipient = AppTestSupport.makeHarness(groups: [], localMemberID: "bob")
        let left = author.viewModel, right = recipient.viewModel
        defer {
            left.stopOrdinaryGroupReplyExchanges(); right.stopOrdinaryGroupReplyExchanges()
            left.disconnect(); right.disconnect()
        }
        let (invitationGroups, callIDs) = try prepareCalls(
            left: left, right: right, invitationCount: invitationCount)
        let (authorCall, recipientCall) = callIDs
        let authorReference = left.currentCallReference, recipientReference = right.currentCallReference
        try #require(right.setCallMuted(true, for: recipientReference))
        let deliverToAuthor = try #require(author.callSession.onEvent)
        let deliverToRecipient = try #require(recipient.callSession.onEvent)
        let internet = TransportEvent.routesChanged(.init(activeRoute: .webRTC, mediaRoute: .webRTC,
            availableRoutes: [.webRTC], isHandoverInProgress: false))
        let mixed = TransportEvent.routesChanged(.init(activeRoute: .webRTC, mediaRoute: .webRTC,
            availableRoutes: [.multipeer, .webRTC], isHandoverInProgress: false))
        deliverToAuthor(mixed)
        deliverToRecipient(internet)

        var authorRequests = 0, recipientRequests = 0
        var expireAuthor: (@MainActor () -> Void)?, expireRecipient: (@MainActor () -> Void)?
        left.beginOrdinaryGroupReplyBackgroundTime = { expire in
            authorRequests += 1; expireAuthor = expire; return nil
        }
        right.beginOrdinaryGroupReplyBackgroundTime = { expire in
            recipientRequests += 1; expireRecipient = expire; return nil
        }
        for group in invitationGroups {
            let url = try #require(left.makeGroupInviteURL(for: group))
            try right.acceptInviteURL(url)
        }
        let authorTimeout = try #require(expireAuthor), recipientTimeout = try #require(expireRecipient)
        authorTimeout(); recipientTimeout()
        deliverToAuthor(internet)
        deliverToRecipient(internet)
        #expect(left.ordinaryGroupReplyExchanges.isEmpty && right.ordinaryGroupReplyExchanges.isEmpty)
        #expect(left.savedRemoteUsers.isEmpty)
        let pending = invitationGroups.filter { right.groupRepository.pendingInvitation(for: $0) != nil }
        #expect(pending.count == invitationCount)

        deliverToAuthor(mixed); deliverToRecipient(mixed)
        try #require(left.ordinaryGroupReplyExchanges.count == invitationCount)
        try #require(right.ordinaryGroupReplyExchanges.count == invitationCount)
        deliverToAuthor(mixed); deliverToRecipient(mixed)
        #expect(authorRequests == 2 && recipientRequests == 2)
        await verifyDeliveredInvitations(invitationGroups, left: left, right: right)
        #expect(left.currentCallReference == authorReference && right.currentCallReference == recipientReference)
        #expect(left.activeGroupID == authorCall && right.activeGroupID == recipientCall)
        #expect(right.effectiveInputMuted)
    }

    private func prepareCalls(left: IntercomViewModel, right: IntercomViewModel, invitationCount: Int)
        throws -> ([UUID], (UUID, UUID)) {
        for model in [left, right] {
            model.setRTCTransportRoutes([.multipeer, .webRTC])
            model.allowsNearbyGroupDelivery = true
        }
        let invitationGroups = (1...invitationCount).map { _ in UUID() }
        let authorCall = UUID(), recipientCall = UUID()
        for (index, group) in invitationGroups.enumerated() {
            try #require(left.createTalkGroup(name: "Invitation group \(index + 1)", id: group))
        }
        try #require(left.createTalkGroup(name: "Author's call", id: authorCall))
        try #require(left.startCall(to: .group(authorCall), accountAccessID: left.accountAccessID))
        try #require(right.createTalkGroup(name: "Recipient's call", id: recipientCall))
        try #require(right.startCall(to: .group(recipientCall), accountAccessID: right.accountAccessID))
        return (invitationGroups, (authorCall, recipientCall))
    }

    private func verifyDeliveredInvitations(_ invitationGroups: [UUID], left: IntercomViewModel,
                                            right: IntercomViewModel) async {
        await AppTestSupport.waitUntil(timeout: replyTimeout) {
            invitationGroups.allSatisfy { right.groupRepository.pendingInvitation(for: $0) == nil }
        }
        let delivered = invitationGroups.allSatisfy { right.groupRepository.pendingInvitation(for: $0) == nil }
        #expect(delivered)
        #expect(right.ordinaryGroupReplyExchanges.isEmpty)
        #expect(left.savedRemoteUsers.first?.memberIDs == ["bob"])
    }

    @Test func reopenedInviterReceivesAcceptancesForBothIssuedLinks() async throws {
        let storage = try GroupStorageFixture()
        defer { storage.remove() }
        let group = try storage.group()
        let other = try storage.group()
        try storage.repository.save(
            [group, other], credential: .init(groupID: group.id, secret: "original-link-fixture"))
        try storage.repository.save([group, other], credential: .init(groupID: other.id, secret: "second-link-fixture"))
        let issuer = AppTestSupport.makeHarness(groups: [], groupRepository: storage.repository, localMemberID: "local")
        let url = try #require(issuer.viewModel.makeGroupInviteURL(for: group.id))
        let otherURL = try #require(issuer.viewModel.makeGroupInviteURL(for: other.id))
        issuer.viewModel.stopOrdinaryGroupReplyExchanges()

        let author = AppTestSupport.makeHarness(accountSession: issuer.viewModel.accountSession, groups: [],
            groupRepository: storage.restart(), internetSettingsStore: issuer.viewModel.internetSettingsStore,
            invitationAuthority: issuer.viewModel.invitationAuthority, localMemberID: "local")
        let recipient = AppTestSupport.makeHarness(groups: [], localMemberID: "bob")
        defer {
            author.viewModel.stopOrdinaryGroupReplyExchanges(); recipient.viewModel.stopOrdinaryGroupReplyExchanges()
            author.viewModel.disconnect(); recipient.viewModel.disconnect()
        }
        author.viewModel.allowsNearbyGroupDelivery = true
        recipient.viewModel.allowsNearbyGroupDelivery = false
        var authorWindows = 0, authorReleases = 0
        var expiration: (@MainActor () -> Void)?
        author.viewModel.beginOrdinaryGroupReplyBackgroundTime = { callback in
            authorWindows += 1
            expiration = callback
            return { authorReleases += 1 }
        }
        let owner = AppCallOwner(account: author.viewModel.accountSession, viewModel: author.viewModel)
        owner.systemSurfaceIsForeground = true
        let activeTargets = Set(author.viewModel.ordinaryGroupReplyExchanges.values.map(\.invitation.groupID))
        #expect(activeTargets == [group.id, other.id])
        #expect(authorWindows == 1)
        try await verifyBothLinks(author: author, recipient: recipient, groups: (group, other), urls: (url, otherURL))
        #expect(owner.viewModel === author.viewModel)

        let expire = try #require(expiration)
        expire()
        #expect(author.viewModel.ordinaryGroupReplyExchanges.isEmpty)
        #expect(authorReleases == 1)
        owner.systemSurfaceIsForeground = false
        owner.systemSurfaceIsForeground = true
        expire()
        #expect(authorWindows == 2)
        #expect(author.viewModel.ordinaryGroupReplyExchanges.count == 2)
        #expect(authorReleases == 1)
        try #require(author.viewModel.deleteGroup(group.id))
        let remainingTargets = author.viewModel.ordinaryGroupReplyExchanges.values.map(\.invitation.groupID)
        #expect(remainingTargets == [other.id])
        #expect(authorReleases == 1)
    }

    private func verifyBothLinks(author: AppTestSupport.Harness, recipient: AppTestSupport.Harness,
                                 groups: (IntercomGroup, IntercomGroup), urls: (URL, URL)) async throws {
        let (group, other) = groups
        let (url, otherURL) = urls
        // The newer link still works; its confirmation must leave the older link reachable.
        try recipient.viewModel.acceptInviteURL(otherURL)
        #expect(author.viewModel.savedRemoteUsers.isEmpty)
        #expect(recipient.viewModel.ordinaryGroupReplyExchanges.isEmpty)
        let selected = recipient.viewModel.activeGroupID
        let receiverOwner = AppCallOwner(account: recipient.viewModel.accountSession, viewModel: recipient.viewModel)
        recipient.viewModel.allowsNearbyGroupDelivery = true
        receiverOwner.systemSurfaceIsForeground = true
        await AppTestSupport.waitUntil(timeout: replyTimeout) {
            recipient.viewModel.groupRepository.pendingInvitation(for: other.id) == nil
        }
        let newerAcknowledged = recipient.viewModel.groupRepository.pendingInvitation(for: other.id) == nil
        try #require(newerAcknowledged)
        try recipient.viewModel.acceptInviteURL(url)
        await AppTestSupport.waitUntil(timeout: replyTimeout) {
            recipient.viewModel.groupRepository.pendingInvitation(for: group.id) == nil
        }
        let acknowledged = recipient.viewModel.groupRepository.pendingInvitation(for: group.id) == nil
        #expect(acknowledged)
        #expect(author.viewModel.savedRemoteUsers.map(\.memberIDs) == [["bob"]])
        #expect(author.viewModel.activeGroupID == nil)
        #expect(recipient.viewModel.activeGroupID == selected)
    }

    @Test func ordinaryInvitationReplyReachesTheInviterAfterSwitchingToAnIndividualCall() async throws {
        let group = try IntercomGroup(name: "Riders", members: [.init(id: "alice", displayName: "Alice")],
                                      accessSecret: "ordinary-group-reply-fixture")
        let firstPeer = AppTestSupport.makeHarness(groups: [group], localMemberID: "alice")
        let secondPeer = AppTestSupport.makeHarness(groups: [], localMemberID: "bob")
        defer {
            firstPeer.viewModel.stopOrdinaryGroupReplyExchanges()
            secondPeer.viewModel.stopOrdinaryGroupReplyExchanges()
            firstPeer.viewModel.disconnect(); secondPeer.viewModel.disconnect()
        }
        firstPeer.viewModel.allowsNearbyGroupDelivery = true
        secondPeer.viewModel.allowsNearbyGroupDelivery = true
        var requests = 0, releases = 0
        var expire: (@MainActor () -> Void)?
        secondPeer.viewModel.beginOrdinaryGroupReplyBackgroundTime = { callback in
            requests += 1
            expire = callback
            return { releases += 1 }
        }
        let url = try #require(firstPeer.viewModel.makeGroupInviteURL(for: group.id))
        try secondPeer.viewModel.acceptInviteURL(url)
        let alice = try #require(secondPeer.viewModel.savedRemoteUsers.first)
        #expect(secondPeer.viewModel.groupRepository.pendingInvitation(for: group.id) != nil)
        #expect(firstPeer.viewModel.savedRemoteUsers.isEmpty)
        let firstExpiration = try #require(expire)
        firstExpiration()
        #expect(secondPeer.viewModel.ordinaryGroupReplyExchanges.isEmpty)
        #expect(secondPeer.viewModel.groupRepository.pendingInvitation(for: group.id) != nil)
        try #require(
            secondPeer.viewModel.startCall(
                to: .user(alice.id), accountAccessID: secondPeer.viewModel.accountAccessID))
        let current = try #require(secondPeer.viewModel.activeDirectCall)
        firstExpiration()
        #expect(releases == 1)

        try await verifyReplyAfterSwitch(firstPeer: firstPeer, secondPeer: secondPeer, group: group,
                                         currentID: current.id)
        #expect(requests == 2)
        #expect(releases == 2)
        #expect(secondPeer.viewModel.ordinaryGroupReplyExchanges.isEmpty)
        #if os(iOS)
        let bob = try #require(firstPeer.viewModel.savedRemoteUsers.first)
        try #require(
            firstPeer.viewModel.startCall(to: .user(bob.id), accountAccessID: firstPeer.viewModel.accountAccessID))
        try await DirectCallTests.assertLocalCall(aliceGroup: try #require(firstPeer.callSession.connectedGroup),
                                  bobGroup: try #require(secondPeer.callSession.connectedGroup))
        #endif
    }
    private func verifyReplyAfterSwitch(firstPeer: AppTestSupport.Harness, secondPeer: AppTestSupport.Harness,
                                        group: IntercomGroup, currentID: UUID) async throws {
        await AppTestSupport.waitUntil(timeout: .seconds(10)) {
            secondPeer.viewModel.groupRepository.pendingInvitation(for: group.id) == nil
                && !firstPeer.viewModel.savedRemoteUsers.isEmpty
        }
        #expect(firstPeer.viewModel.activeGroupID == nil)
        #expect(secondPeer.viewModel.activeGroupID == currentID)
        #expect(secondPeer.viewModel.groupRepository.pendingInvitation(for: group.id) == nil)
        let bob = try #require(firstPeer.viewModel.savedRemoteUsers.first)
        #expect(firstPeer.viewModel.existingDirectCall(for: bob.id)?.id == currentID)
        let source = try #require(firstPeer.viewModel.groupRepository.credential(for: currentID)?.secret)
        let matches = try secondPeer.viewModel.groupRepository.credential(for: currentID)?.secret == source
        #expect(matches)
    }

}
