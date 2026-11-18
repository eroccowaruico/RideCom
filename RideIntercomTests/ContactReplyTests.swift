import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct ContactReplyTests {
    private func pair(now: @escaping @MainActor () -> Date = Date.init) throws -> (AppTestSupport.Harness, AppTestSupport.Harness, UUID) {
        let author = AppTestSupport.makeHarness(groups: [], localMemberID: "reply-author", callAccessNow: now)
        let friend = AppTestSupport.makeHarness(groups: [], localMemberID: "reply-friend", callAccessNow: now)
        author.viewModel.contactSessionFactory = { RecordingCallSession() }
        friend.viewModel.contactSessionFactory = { RecordingCallSession() }
        author.viewModel.beginContactInvitationPresentation()
        guard case .person(let person) = author.viewModel.contactInvitationPresentation else { throw ContactInvitationError.unavailable }
        #expect(author.viewModel.saveContactPerson(person, name: "My Friend", usesProvisionalName: true))
        let url = try author.viewModel.contactPersonURLForSharing(person, expectedAccountAccessID: author.viewModel.accountAccessID)
        try friend.viewModel.acceptContactInviteURL(url)
        author.viewModel.stopContactInvitationSession(); friend.viewModel.stopContactInvitationSession()
        let id = try #require(friend.viewModel.pendingContactInvitations.first).id
        return (author, friend, id)
    }

    @Test func storedReplyAndConfirmationCompleteWithoutAnyTransport() throws {
        let (a, b, id) = try pair()
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        let person = try #require(a.viewModel.directoryUsers.first).id
        a.viewModel.showContactPerson(person)
        let presentation = a.viewModel.contactInvitationPresentation
        let before = b.groupStore.snapshot
        let reply = try b.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: b.viewModel.accountAccessID)
        #expect(b.groupStore.snapshot == before, "Export does not claim delivery")
        try a.viewModel.receiveContactReplyURL(reply)
        #expect(a.viewModel.directoryUsers.map(\.id) == [person])
        #expect(a.viewModel.contactPerson(person)?.isRegistered == true)
        #expect(a.viewModel.contactPerson(person)?.localName == "My Friend")
        #expect(a.viewModel.contactInvitationPresentation == presentation)
        #expect(a.viewModel.pendingContactInvitations.isEmpty)
        let confirmation = try a.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: a.viewModel.accountAccessID)
        try b.viewModel.receiveContactReplyURL(confirmation)
        #expect(b.viewModel.contactInvitationRecord(id)?.state == .delivered)
        #expect(b.viewModel.pendingContactInvitations.isEmpty)
        #expect(a.callSession.connectedGroup == nil && b.callSession.connectedGroup == nil)
    }

    @Test func duplicateRepliesAndConfirmationsAreIdempotentAndContainNoInviteSecrets() throws {
        let (a, b, id) = try pair()
        let reply = try b.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: b.viewModel.accountAccessID)
        let payload = try b.viewModel.groupRepository.contactInvitationPayload(id)
        let data = try JSONEncoder().encode(ContactReplyURL.decode(reply))
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains(payload.token.groupSecret))
        #expect(!text.contains(try #require(payload.token.directInvitation).secret))
        try a.viewModel.receiveContactReplyURL(reply)
        let saved = a.groupStore.snapshot, count = a.groupStore.saveCount
        try a.viewModel.receiveContactReplyURL(reply)
        #expect(a.groupStore.snapshot == saved && a.groupStore.saveCount == count)
        let ack = try a.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: a.viewModel.accountAccessID)
        try b.viewModel.receiveContactReplyURL(ack)
        let delivered = b.groupStore.snapshot
        try b.viewModel.receiveContactReplyURL(ack)
        #expect(b.groupStore.snapshot == delivered)
    }

    @Test func exportRevalidatesAccountCancellationAndExpiryWithoutChangingDelivery() throws {
        let (a, b, id) = try pair()
        let snapshot = b.groupStore.snapshot
        #expect(throws: (any Error).self) { try b.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: UUID()) }
        #expect(throws: (any Error).self) { try a.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: a.viewModel.accountAccessID) }
        #expect(b.groupStore.snapshot == snapshot)
        try b.viewModel.cancelContactInvitation(id)
        #expect(throws: (any Error).self) { try b.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: b.viewModel.accountAccessID) }
    }

    @Test func tamperedReplyWrongAccountAndCancelledInviteCannotRegisterAnyone() throws {
        let (a, b, id) = try pair()
        let reply = try b.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: b.viewModel.accountAccessID)
        var forged = try ContactReplyURL.decode(reply); forged.displayName = "Forged name"
        let before = a.groupStore.snapshot
        #expect(throws: (any Error).self) { try a.viewModel.receiveContactReplyURL(ContactReplyURL.make(forged)) }
        #expect(throws: (any Error).self) { try b.viewModel.receiveContactReplyURL(reply) }
        #expect(a.groupStore.snapshot == before)
        try a.viewModel.cancelContactInvitation(id)
        let cancelled = a.groupStore.snapshot
        #expect(throws: (any Error).self) { try a.viewModel.receiveContactReplyURL(reply) }
        #expect(a.groupStore.snapshot == cancelled)
    }

    @Test func tamperedAcknowledgementCannotClearPendingReply() throws {
        let (a, b, id) = try pair()
        let reply = try b.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: b.viewModel.accountAccessID)
        try a.viewModel.receiveContactReplyURL(reply)
        let ack = try a.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: a.viewModel.accountAccessID)
        var forged = try ContactReplyURL.decode(ack); forged.displayName = "Forged name"
        let before = b.groupStore.snapshot
        #expect(throws: (any Error).self) { try b.viewModel.receiveContactReplyURL(ContactReplyURL.make(forged)) }
        #expect(b.groupStore.snapshot == before)
        try b.viewModel.receiveContactReplyURL(ack)
        #expect(b.viewModel.contactInvitationRecord(id)?.state == .delivered)
    }

    @Test func failedSaveKeepsTheReplyAndCanBeRetriedAfterReload() throws {
        let (a, b, id) = try pair()
        let reply = try b.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: b.viewModel.accountAccessID)
        let before = a.groupStore.snapshot
        a.groupStore.failSaving = true
        #expect(throws: (any Error).self) { try a.viewModel.receiveContactReplyURL(reply) }
        #expect(a.groupStore.snapshot == before)
        a.groupStore.failSaving = false
        a.viewModel.reloadSavedGroups()
        try a.viewModel.receiveContactReplyURL(reply)
        #expect(a.viewModel.savedRemoteUsers.count == 1)
        let ack = try a.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: a.viewModel.accountAccessID)
        let pending = b.groupStore.snapshot
        b.groupStore.failSaving = true
        #expect(throws: (any Error).self) { try b.viewModel.receiveContactReplyURL(ack) }
        #expect(b.groupStore.snapshot == pending)
        b.groupStore.failSaving = false
        b.viewModel.reloadSavedGroups()
        try b.viewModel.receiveContactReplyURL(ack)
        #expect(b.viewModel.pendingContactInvitations.isEmpty)
    }

    @Test func restartKeepsTheSignedReplyAndActiveCallNeverChanges() throws {
        let credentials = InMemoryGroupCredentialStore()
        let a = AppTestSupport.makeHarness(groups: [], localMemberID: "restart-reply-author")
        let b = AppTestSupport.makeHarness(groups: [], credentialStore: credentials, localMemberID: "restart-reply-friend")
        a.viewModel.contactSessionFactory = { RecordingCallSession() }; b.viewModel.contactSessionFactory = { RecordingCallSession() }
        let url = try #require(a.viewModel.makeContactInviteURL())
        try b.viewModel.acceptContactInviteURL(url)
        let id = try #require(b.viewModel.pendingContactInvitations.first).id
        a.viewModel.stopContactInvitationSession(); b.viewModel.stopContactInvitationSession()
        let reloaded = AppTestSupport.makeHarness(accountSession: b.viewModel.accountSession, groups: [],
            groupStore: b.groupStore, credentialStore: credentials, internetSettingsStore: b.viewModel.internetSettingsStore,
            invitationAuthority: b.viewModel.invitationAuthority, localMemberID: "restart-reply-friend")
        let reply = try reloaded.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: reloaded.viewModel.accountAccessID)
        let group = try IntercomGroup(name: "Current trip", members: [.init(id: "restart-reply-author", displayName: "You")], accessSecret: "active-secret")
        try a.viewModel.groupRepository.save([group], credential: .init(groupID: group.id, secret: "active-secret"))
        a.viewModel.reloadSavedGroups()
        a.viewModel.selectGroup(group); a.viewModel.applyLocalMute(true)
        let call = a.callSession.connectedGroup, disconnects = a.callSession.disconnectCallCount
        try a.viewModel.receiveContactReplyURL(reply)
        #expect(a.callSession.connectedGroup == call && a.callSession.disconnectCallCount == disconnects)
        #expect(a.viewModel.isMuted)
        a.viewModel.disconnect(); reloaded.viewModel.disconnect(); b.viewModel.disconnect()
    }

    @Test(arguments: ["https://contact-reply?receipt=AA", "rideintercom://contact-reply?receipt=AA&receipt=BB", "rideintercom://contact-reply?receipt=AA#extra", "rideintercom://contact-reply/path?receipt=AA", "rideintercom://someone@contact-reply?receipt=AA", "rideintercom://contact-reply?receipt=***"])
    func malformedURLsAreRejected(_ value: String) throws {
        #expect(throws: (any Error).self) { try ContactReplyURL.decode(#require(URL(string: value))) }
    }


    @Test func expiredRepliesAndEndedSignInNeverChangeSavedPeople() throws {
        var now = Date()
        let (a, b, id) = try pair(now: { now })
        let reply = try b.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: b.viewModel.accountAccessID)
        let aBefore = a.groupStore.snapshot, bBefore = b.groupStore.snapshot
        now = now.addingTimeInterval(8 * 24 * 60 * 60)
        #expect(throws: (any Error).self) { try b.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: b.viewModel.accountAccessID) }
        #expect(throws: (any Error).self) { try a.viewModel.receiveContactReplyURL(reply) }
        #expect(a.groupStore.snapshot == aBefore && b.groupStore.snapshot == bBefore)
        now = Date()
        let access = b.viewModel.accountAccessID
        b.viewModel.accountSession.signOut()
        #expect(throws: (any Error).self) { try b.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: access) }
        #expect(throws: (any Error).self) { try b.viewModel.receiveContactReplyURL(reply) }
    }
}
