import Foundation
import RTC
import Testing
@testable import RideIntercom

extension ContactInvitationPersistenceTests {
    @Test func internetOnlyContactReplyWaitsDuringARegularCall() throws {
        let group = try IntercomGroup(
            name: "Current Group", members: [.init(id: "call-author", displayName: "Author")],
            accessSecret: "existing-call-key")
        let harness = AppTestSupport.makeHarness(
            groups: [group], hasInternetCallCredential: true, localMemberID: "call-author")
        let viewModel = harness.viewModel
        let contact = RecordingCallSession()
        viewModel.contactSessionFactory = { contact }
        viewModel.enabledRTCTransportRoutes = [.webRTC]
        defer { viewModel.stopContactInvitationSession(); viewModel.disconnect() }
        viewModel.selectGroup(group)
        #expect(harness.callSession.connectedGroup?.id == group.id)
        let disconnects = harness.callSession.disconnectCallCount
        let url = try #require(viewModel.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation)
            .context.id
        #expect(!viewModel.resumeContactInvitation(id))
        #expect(viewModel.contactInvitationWaitsForCurrentCall)
        #expect(harness.callSession.connectedGroup?.id == group.id)
        #expect(harness.callSession.disconnectCallCount == disconnects)
        #expect(contact.connectedGroup == nil)
        #expect(viewModel.pendingContactInvitations.map(\.id) == [id])
    }

    @Test(.timeLimit(.minutes(1)))
    func nearRangeReplyCompletesDuringBothCallsWithoutChangingTheAudio() async throws {
        let suffix = String(UUID().uuidString.prefix(8))
        let authorID = "live-author-" + suffix, friendID = "live-friend-" + suffix
        let groups = try [authorID, friendID].map { id in
            try IntercomGroup(
                name: "Current Group", members: [.init(id: id, displayName: id)], accessSecret: "existing-call-key"
            )
        }
        let authorHarness = AppTestSupport.makeHarness(groups: [groups[0]], localMemberID: authorID)
        let friendHarness = AppTestSupport.makeHarness(groups: [groups[1]], localMemberID: friendID)
        let author = authorHarness.viewModel, friend = friendHarness.viewModel
        defer {
            for viewModel in [author, friend] { viewModel.stopContactInvitationSession(); viewModel.disconnect() }
        }
        let url = try #require(author.makeContactInviteURL())
        let beforeCall = try #require(author.contactInvitationSession)
        for (viewModel, group) in zip([author, friend], groups) {
            viewModel.selectGroup(group)
            viewModel.applyLocalMute(true)
        }
        try #require(author.contactInvitationSession === beforeCall)
        await AppTestSupport.waitUntil { author.isAudioReady && friend.isAudioReady }
        try #require(author.isAudioReady && friend.isAudioReady)
        let calls = [authorHarness.callSession, friendHarness.callSession]
        let deadlines = [author.callDisconnectDeadline, friend.callDisconnectDeadline]
        let mediaStarts = calls.map(\.startMediaCallCount)
        let mediaStops = calls.map(\.stopMediaCallCount)
        let disconnects = calls.map(\.disconnectCallCount)

        try friend.acceptContactInviteURL(url)
        try #require(friend.contactInvitationSession != nil)
        #expect(!friend.contactInvitationWaitsForCurrentCall)
        await AppTestSupport.waitUntil(timeout: .seconds(12)) {
            author.savedRemoteUsers.map(\.memberIDs) == [[friendID]] && friend.pendingContactInvitations.isEmpty
        }
        #expect(author.savedRemoteUsers.map(\.memberIDs) == [[friendID]])
        #expect(friend.savedRemoteUsers.map(\.memberIDs) == [[authorID]])
        #expect(friend.pendingContactInvitations.isEmpty)
        #expect(author.pendingContactInvitations.isEmpty)
        #expect([author.activeGroupID, friend.activeGroupID] == groups.map { Optional($0.id) })
        #expect([author.callDisconnectDeadline, friend.callDisconnectDeadline] == deadlines)
        #expect(author.isMuted && friend.isMuted)
        #expect(author.isAudioReady && friend.isAudioReady)
        #expect(calls.map(\.startMediaCallCount) == mediaStarts)
        #expect(calls.map(\.stopMediaCallCount) == mediaStops)
        #expect(calls.map(\.disconnectCallCount) == disconnects)
        author.disconnect()
        #expect(author.contactInvitationSession === beforeCall)
        author.accountSession.signOut()
        #expect(author.contactInvitationSession == nil)
    }

    @Test func ordinaryCallStartAndSignOutStopContactTransportWithoutErasingPending() throws {
        let group = try IntercomGroup(
            name: "Current Group", members: [.init(id: "lifecycle-author", displayName: "Author")],
            accessSecret: "ordinary-key")
        let harness = AppTestSupport.makeHarness(groups: [group], localMemberID: "lifecycle-author")
        let contact = RecordingCallSession()
        harness.viewModel.contactSessionFactory = { contact }
        defer { harness.viewModel.stopContactInvitationSession(); harness.viewModel.disconnect() }
        let url = try #require(harness.viewModel.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation)
            .context.id
        #expect(contact.connectedGroup != nil)
        harness.viewModel.selectGroup(group)
        #expect(contact.connectedGroup == nil)
        #expect(harness.callSession.connectedGroup?.id == group.id)
        #expect(harness.viewModel.pendingContactInvitations.map(\.id) == [id])
        harness.viewModel.disconnect()
        #expect(harness.viewModel.resumeContactInvitation(id))
        #expect(contact.connectedGroup != nil)
        harness.viewModel.accountSession.signOut()
        #expect(contact.connectedGroup == nil)
        #expect(!harness.viewModel.resumeContactInvitation(id))
        #expect(harness.groupStore.snapshot.users.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func nativeVMNotificationCommitsBothUsersAndSurvivesDiskReload(includesGroup: Bool) async throws {
        let suffix = String(UUID().uuidString.prefix(8))
        let authorID = "native-vm-author-" + suffix, friendID = "native-vm-friend-" + suffix
        let author = try Fixture(authorID), friend = try Fixture(friendID)
        let (authorHarness, _) = author.make(), (friendHarness, _) = friend.make()
        let authorModel = authorHarness.viewModel
        let friendModel = friendHarness.viewModel
        authorModel.contactSessionFactory = nil
        friendModel.contactSessionFactory = nil
        authorModel.enabledRTCTransportRoutes = [.multipeer, .webRTC]
        friendModel.enabledRTCTransportRoutes = [.multipeer, .webRTC]
        #expect(!authorModel.hasInternetCredentials && !friendModel.hasInternetCredentials,
                "Local invitation acceptance does not depend on Internet registration")
        defer {
            authorModel.stopContactInvitationSession()
            friendModel.stopContactInvitationSession()
        }
        guard let (personID, groupID) = try prepareNativeInvitation(
            in: authorModel, includesGroup: includesGroup
        ) else { return }
        let mediaStartsBeforeSharing = authorHarness.callSession.startMediaCallCount
        try await verifyNativeInvitationDelivery(
            personID: personID, from: authorModel, to: friendModel, authorID: authorID, friendID: friendID)
        #expect(friendModel.contactInvitationID == nil)
        #expect(authorModel.pendingContactInvitations.isEmpty)
        #expect(
            authorModel.contactInvitationMessage == nil
                && friendModel.contactInvitationMessage == nil,
                "Verified registration and delivery clear earlier retry failures")
        #expect(authorModel.contactInvitationPresentation == .person(personID))
        #expect(authorModel.savedRemoteUsers.map(\.id) == [personID])
        #expect(
            authorModel.directoryUsers.count == 1
                && authorModel.unlinkedContactInvitations.isEmpty)
        let namedPerson = try #require(authorModel.contactPerson(personID))
        #expect(namedPerson.needsNameConfirmation)
        #expect(authorModel.resolveContactPersonName(namedPerson, useSharedName: false))
        #expect(authorModel.contactPerson(personID)?.needsNameConfirmation == false)
        authorModel.dismissContactInvitationPresentation()
        #expect(authorModel.contactInvitationPresentation == nil)
        #expect(authorHarness.callSession.connectedGroup == nil && friendHarness.callSession.connectedGroup == nil)
        #expect(
            authorHarness.callSession.startMediaCallCount == mediaStartsBeforeSharing
                && friendHarness.callSession.startMediaCallCount == 0)
        authorModel.stopContactInvitationSession()
        friendModel.stopContactInvitationSession()
        try verifyNativeInvitationReload(author: author, friend: friend, personID: personID, groupID: groupID)
    }

    private func verifyNativeInvitationDelivery(
        personID: UUID, from authorModel: IntercomViewModel, to friendModel: IntercomViewModel,
        authorID: String, friendID: String
    ) async throws {
        let share = try authorModel.prepareContactPersonShare(
            personID, expectedAccountAccessID: authorModel.accountAccessID)
        authorModel.completeContactInvitationSharing(share)
        let url = share.url
        #expect(authorModel.savedRemoteUsers.isEmpty)
        #expect(friendModel.previewContactInvitation(url))
        #expect(friendModel.savedRemoteUsers.isEmpty)
        authorModel.contactInvitationMessage = "This invitation could not be resumed. Try again."
        #expect(friendModel.acceptPresentedContactInvitation())
        friendModel.contactInvitationMessage = "This invitation could not be resumed. Try again."
        #expect(friendModel.savedRemoteUsers.map(\.memberIDs) == [[authorID]])
        // Allow discovery, authentication and the route’s automatic retry to complete.
        let deadline = ContinuousClock.now + .seconds(45)
        while authorModel.savedRemoteUsers.isEmpty
            || !friendModel.pendingContactInvitations.isEmpty,
            ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(
            authorModel.savedRemoteUsers.map(\.memberIDs) == [[friendID]],
            "Actual near-range acceptance reaches the author's atomic registration")
        #expect(
            friendModel.pendingContactInvitations.isEmpty,
            "Actual acknowledgement completes the recipient's durable notification")
    }

    private func prepareNativeInvitation(
        in viewModel: IntercomViewModel, includesGroup: Bool
    ) throws -> (personID: UUID, groupID: UUID?)? {
        let personID: UUID
        let groupID: UUID?
        if includesGroup {
            let draft = GroupInvitationDraft(suggestedName: "Native Partner")
            personID = draft.id
            let savedGroup = try #require(viewModel.saveGroupInvitations(groupID: UUID(), creating: true,
                name: "Native Group", selected: [], newPeople: [draft]))
            groupID = savedGroup
            // Creation's explicit "Create and Connect" is separate from sharing the saved invite.
            viewModel.disconnect()
            viewModel.showContactPerson(personID)
        } else {
            viewModel.beginContactInvitationPresentation()
            guard case .person(let id) = viewModel.contactInvitationPresentation else {
                Issue.record("Expected person")
                return nil
            }
            personID = id
            groupID = nil
            #expect(viewModel.saveContactPerson(personID, name: "Native Partner", usesProvisionalName: true))
        }
        return (personID, groupID)
    }

    private func verifyNativeInvitationReload(
        author: Fixture, friend: Fixture, personID: UUID, groupID: UUID?
    ) throws {
        let authorID = author.memberID
        let friendID = friend.memberID
        let (reloadedAuthor, _) = author.make(), (reloadedFriend, _) = friend.make()
        #expect(reloadedAuthor.viewModel.savedRemoteUsers.map(\.memberIDs) == [[friendID]])
        #expect(reloadedAuthor.viewModel.directoryUsers.map(\.id) == [personID])
        #expect(reloadedAuthor.viewModel.directoryUsers.first?.usesProvisionalName == false)
        #expect(reloadedFriend.viewModel.savedRemoteUsers.map(\.memberIDs) == [[authorID]])
        let expectedGroups = groupID.map { [$0] } ?? []
        #expect(reloadedAuthor.viewModel.regularGroups.map(\.id) == expectedGroups)
        #expect(reloadedFriend.viewModel.regularGroups.map(\.id) == expectedGroups)
        if let groupID {
            let group = try #require(reloadedAuthor.viewModel.regularGroups.first)
            #expect(Set(group.members.map(\.id)) == [authorID, friendID])
            let credential = try #require(try reloadedAuthor.viewModel.groupRepository.credential(for: groupID))
            #expect(try reloadedFriend.viewModel.groupRepository.credential(for: groupID) == credential)
        }
        #expect(reloadedFriend.viewModel.pendingContactInvitations.isEmpty)
        // The real exchange leaves both sides with one pair call key.
        let call = IntercomGroup.directCallID(memberIDs: [authorID, friendID])
        let key = try #require(try reloadedAuthor.viewModel.groupRepository.credential(for: call))
        #expect(try reloadedFriend.viewModel.groupRepository.credential(for: call) == key)
    }
}
