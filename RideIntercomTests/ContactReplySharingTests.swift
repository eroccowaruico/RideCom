import CoreTransferable
import Foundation
import RTC
import UniformTypeIdentifiers
import Testing
@testable import RideIntercom

extension ContactReplyTests {
    @Test func duplicateRepliesAndConfirmationsAreIdempotentAndContainNoInviteSecrets() throws {
        let ((authorHarness, recipientHarness), id) = try pair()
        let reply = try recipientHarness.viewModel.contactReplyURLForSharing(
            id, expectedAccountAccessID: recipientHarness.viewModel.accountAccessID)
        let payload = try recipientHarness.viewModel.groupRepository.contactInvitationPayload(id)
        let data = try JSONEncoder().encode(ContactReplyURL.decode(reply))
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains(payload.token.groupSecret))
        #expect(!text.contains(try #require(payload.token.directInvitation).secret))
        try authorHarness.viewModel.receiveContactReplyURL(reply)
        let saved = authorHarness.groupStore.snapshot, count = authorHarness.groupStore.saveCount
        try authorHarness.viewModel.receiveContactReplyURL(reply)
        #expect(authorHarness.groupStore.snapshot == saved && authorHarness.groupStore.saveCount == count)
        let ack = try authorHarness.viewModel.contactReplyURLForSharing(
            id, expectedAccountAccessID: authorHarness.viewModel.accountAccessID)
        try recipientHarness.viewModel.receiveContactReplyURL(ack)
        let delivered = recipientHarness.groupStore.snapshot
        try recipientHarness.viewModel.receiveContactReplyURL(ack)
        #expect(recipientHarness.groupStore.snapshot == delivered)
    }

    @Test func exportRevalidatesAccountCancellationAndExpiryWithoutChangingDelivery() throws {
        let ((authorHarness, recipientHarness), id) = try pair()
        let snapshot = recipientHarness.groupStore.snapshot
        #expect(throws: (any Error).self) {
            try recipientHarness.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: UUID())
        }
        #expect(throws: (any Error).self) {
            try authorHarness.viewModel.contactReplyURLForSharing(
                id, expectedAccountAccessID: authorHarness.viewModel.accountAccessID)
        }
        #expect(recipientHarness.groupStore.snapshot == snapshot)
        try recipientHarness.viewModel.cancelContactInvitation(id)
        #expect(throws: (any Error).self) {
            try recipientHarness.viewModel.contactReplyURLForSharing(
                id, expectedAccountAccessID: recipientHarness.viewModel.accountAccessID)
        }
    }

    @Test func tamperedReplyWrongAccountAndCancelledInviteCannotRegisterAnyone() throws {
        let ((authorHarness, recipientHarness), id) = try pair()
        let reply = try recipientHarness.viewModel.contactReplyURLForSharing(
            id, expectedAccountAccessID: recipientHarness.viewModel.accountAccessID)
        var forged = try ContactReplyURL.decode(reply); forged.displayName = "Forged name"
        let before = authorHarness.groupStore.snapshot
        #expect(throws: (any Error).self) {
            try authorHarness.viewModel.receiveContactReplyURL(ContactReplyURL.make(forged))
        }
        #expect(throws: (any Error).self) { try recipientHarness.viewModel.receiveContactReplyURL(reply) }
        #expect(authorHarness.groupStore.snapshot == before)
        try authorHarness.viewModel.cancelContactInvitation(id)
        let cancelled = authorHarness.groupStore.snapshot
        #expect(throws: (any Error).self) { try authorHarness.viewModel.receiveContactReplyURL(reply) }
        #expect(authorHarness.groupStore.snapshot == cancelled)
    }

    @Test func tamperedAcknowledgementCannotClearPendingReply() throws {
        let ((authorHarness, recipientHarness), id) = try pair()
        let reply = try recipientHarness.viewModel.contactReplyURLForSharing(
            id, expectedAccountAccessID: recipientHarness.viewModel.accountAccessID)
        try authorHarness.viewModel.receiveContactReplyURL(reply)
        let ack = try authorHarness.viewModel.contactReplyURLForSharing(
            id, expectedAccountAccessID: authorHarness.viewModel.accountAccessID)
        var forged = try ContactReplyURL.decode(ack); forged.displayName = "Forged name"
        let before = recipientHarness.groupStore.snapshot
        #expect(throws: (any Error).self) {
            try recipientHarness.viewModel.receiveContactReplyURL(ContactReplyURL.make(forged))
        }
        #expect(recipientHarness.groupStore.snapshot == before)
        try recipientHarness.viewModel.receiveContactReplyURL(ack)
        #expect(recipientHarness.viewModel.contactInvitationRecord(id)?.state == .delivered)
    }

    @Test func failedSaveKeepsTheReplyAndCanBeRetriedAfterReload() throws {
        let ((authorHarness, recipientHarness), id) = try pair()
        let reply = try recipientHarness.viewModel.contactReplyURLForSharing(
            id, expectedAccountAccessID: recipientHarness.viewModel.accountAccessID)
        let before = authorHarness.groupStore.snapshot
        authorHarness.groupStore.failSaving = true
        #expect(throws: (any Error).self) { try authorHarness.viewModel.receiveContactReplyURL(reply) }
        #expect(authorHarness.groupStore.snapshot == before)
        authorHarness.groupStore.failSaving = false
        authorHarness.viewModel.reloadSavedGroups()
        try authorHarness.viewModel.receiveContactReplyURL(reply)
        #expect(authorHarness.viewModel.savedRemoteUsers.count == 1)
        let ack = try authorHarness.viewModel.contactReplyURLForSharing(
            id, expectedAccountAccessID: authorHarness.viewModel.accountAccessID)
        let pending = recipientHarness.groupStore.snapshot
        recipientHarness.groupStore.failSaving = true
        #expect(throws: (any Error).self) { try recipientHarness.viewModel.receiveContactReplyURL(ack) }
        #expect(recipientHarness.groupStore.snapshot == pending)
        recipientHarness.groupStore.failSaving = false
        recipientHarness.viewModel.reloadSavedGroups()
        try recipientHarness.viewModel.receiveContactReplyURL(ack)
        #expect(recipientHarness.viewModel.pendingContactInvitations.isEmpty)
    }

    @Test func restartKeepsTheSignedReplyAndActiveCallNeverChanges() throws {
        let credentials = InMemoryGroupCredentialStore()
        let authorHarness = AppTestSupport.makeHarness(groups: [], localMemberID: "restart-reply-author")
        let recipientHarness = AppTestSupport.makeHarness(
            groups: [], credentialStore: credentials, localMemberID: "restart-reply-friend")
        authorHarness.viewModel.contactSessionFactory = { RecordingCallSession() }
        recipientHarness.viewModel.contactSessionFactory = { RecordingCallSession() }
        let url = try #require(authorHarness.viewModel.makeContactInviteURL())
        try recipientHarness.viewModel.acceptContactInviteURL(url)
        let id = try #require(recipientHarness.viewModel.pendingContactInvitations.first).id
        authorHarness.viewModel.stopContactInvitationSession()
        recipientHarness.viewModel.stopContactInvitationSession()
        let reloaded = AppTestSupport.makeHarness(accountSession: recipientHarness.viewModel.accountSession, groups: [],
            groupStore: recipientHarness.groupStore, credentialStore: credentials,
            internetSettingsStore: recipientHarness.viewModel.internetSettingsStore,
            invitationAuthority: recipientHarness.viewModel.invitationAuthority, localMemberID: "restart-reply-friend")
        let reply = try reloaded.viewModel.contactReplyURLForSharing(
            id, expectedAccountAccessID: reloaded.viewModel.accountAccessID)
        let group = try IntercomGroup(
            name: "Current trip", members: [.init(id: "restart-reply-author", displayName: "You")],
            accessSecret: "active-secret")
        try authorHarness.viewModel.groupRepository.save(
            [group], credential: .init(groupID: group.id, secret: "active-secret"))
        authorHarness.viewModel.reloadSavedGroups()
        authorHarness.viewModel.selectGroup(group); authorHarness.viewModel.applyLocalMute(true)
        let call = authorHarness.callSession.connectedGroup, disconnects = authorHarness.callSession.disconnectCallCount
        try authorHarness.viewModel.receiveContactReplyURL(reply)
        #expect(
            authorHarness.callSession.connectedGroup == call
                && authorHarness.callSession.disconnectCallCount == disconnects)
        #expect(authorHarness.viewModel.isMuted)
        authorHarness.viewModel.disconnect(); reloaded.viewModel.disconnect(); recipientHarness.viewModel.disconnect()
    }

    @Test(arguments: [
        "https://contact-reply?receipt=AA", "rideintercom://contact-reply?receipt=AA&receipt=BB",
        "rideintercom://contact-reply?receipt=AA#extra", "rideintercom://contact-reply/path?receipt=AA",
        "rideintercom://someone@contact-reply?receipt=AA", "rideintercom://contact-reply?receipt=***"
    ])
    func malformedURLsAreRejected(_ value: String) throws {
        #expect(throws: (any Error).self) { try ContactReplyURL.decode(#require(URL(string: value))) }
    }

    @Test func expiredRepliesAndEndedSignInNeverChangeSavedPeople() throws {
        var now = Date()
        let ((authorHarness, recipientHarness), id) = try pair(now: { now })
        let reply = try recipientHarness.viewModel.contactReplyURLForSharing(
            id, expectedAccountAccessID: recipientHarness.viewModel.accountAccessID)
        let aBefore = authorHarness.groupStore.snapshot, bBefore = recipientHarness.groupStore.snapshot
        now = now.addingTimeInterval(8 * 24 * 60 * 60)
        #expect(throws: (any Error).self) {
            try recipientHarness.viewModel.contactReplyURLForSharing(
                id, expectedAccountAccessID: recipientHarness.viewModel.accountAccessID)
        }
        #expect(throws: (any Error).self) { try authorHarness.viewModel.receiveContactReplyURL(reply) }
        #expect(authorHarness.groupStore.snapshot == aBefore && recipientHarness.groupStore.snapshot == bBefore)
        now = Date()
        let access = recipientHarness.viewModel.accountAccessID
        recipientHarness.viewModel.accountSession.signOut()
        #expect(throws: (any Error).self) {
            try recipientHarness.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: access)
        }
        #expect(throws: (any Error).self) { try recipientHarness.viewModel.receiveContactReplyURL(reply) }
    }

    @Test func registrationCanKeepTheSamePreviewAndContinueIntoTheSavedPerson() throws {
        let ((_, recipientHarness), id) = try pair()
        let token = try recipientHarness.viewModel.groupRepository.contactInvitationPayload(id).token
        let url = try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
        #expect(recipientHarness.viewModel.previewContactInvitation(url))
        let presentation = recipientHarness.viewModel.contactInvitationPresentation
        #expect(
            recipientHarness.viewModel.acceptPresentedContactInvitation(
                expectedInvitationID: id, keepingPresentation: true))
        #expect(recipientHarness.viewModel.contactInvitationPresentation == presentation)
        let person = try #require(recipientHarness.viewModel.contactInvitationRecord(id)?.personID)
        #expect(recipientHarness.viewModel.contactPerson(person)?.isRegistered == true)
        recipientHarness.viewModel.dismissContactInvitationPresentation(expectedPresentationID: presentation?.id)
        #expect(recipientHarness.viewModel.contactInvitationPresentation == nil)
        #expect(
            recipientHarness.viewModel.canShareContactReply(
                try #require(recipientHarness.viewModel.contactInvitationRecord(id))))
        recipientHarness.viewModel.disconnect()
    }

}
