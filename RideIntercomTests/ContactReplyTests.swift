import CoreTransferable
import Foundation
import UniformTypeIdentifiers
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
        let receiver = try #require(b.viewModel.directoryUsers.first).id
        b.viewModel.showContactPerson(receiver)
        let receiverPresentation = b.viewModel.contactInvitationPresentation
        let confirmation = try a.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: a.viewModel.accountAccessID)
        try b.viewModel.receiveContactReplyURL(confirmation)
        #expect(b.viewModel.contactInvitationPresentation == receiverPresentation)
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

    @Test func registrationCanKeepTheSamePreviewAndContinueIntoTheSavedPerson() throws {
        let (_, b, id) = try pair()
        let token = try b.viewModel.groupRepository.contactInvitationPayload(id).token
        let url = try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
        #expect(b.viewModel.previewContactInvitation(url))
        let presentation = b.viewModel.contactInvitationPresentation
        #expect(b.viewModel.acceptPresentedContactInvitation(expectedInvitationID: id, keepingPresentation: true))
        #expect(b.viewModel.contactInvitationPresentation == presentation)
        let person = try #require(b.viewModel.contactInvitationRecord(id)?.personID)
        #expect(b.viewModel.contactPerson(person)?.isRegistered == true)
        b.viewModel.dismissContactInvitationPresentation(expectedPresentationID: presentation?.id)
        #expect(b.viewModel.contactInvitationPresentation == nil)
        #expect(b.viewModel.canShareContactReply(try #require(b.viewModel.contactInvitationRecord(id))))
        b.viewModel.disconnect()
    }

    @Test func onlyManuallyReceivedRepliesOfferTheStandardReturnConfirmation() throws {
        let (a, b, id) = try pair()
        let pending = try #require(a.viewModel.contactInvitationRecord(id))
        #expect(pending.receivedBySharing == nil)
        #expect(!a.viewModel.canShareContactReply(pending))
        let reply = try b.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: b.viewModel.accountAccessID)
        #expect(a.viewModel.handleContactReplyURL(reply))
        let record = try #require(a.viewModel.contactInvitationRecord(id))
        #expect(record.receivedBySharing == true && a.viewModel.canShareContactReply(record))
        let reloaded = try GroupSnapshot.decode(a.groupStore.snapshot.encoded())
        #expect(reloaded.contactInvitations.first?.receivedBySharing == true)
        let snapshot = a.groupStore.snapshot
        #expect(!a.viewModel.handleContactReplyURL(URL(string: "rideintercom://contact-reply?receipt=invalid")!))
        #expect(a.groupStore.snapshot == snapshot && a.viewModel.groupStorageIssue == nil)
        #expect(a.viewModel.contactInvitationMessage != nil)
    }

    @Test func replyTransferableRechecksTheAccountAtTheActualExport() async throws {
        let (_, b, id) = try pair()
        let share = InvitationShare(viewModel: b.viewModel, contactReplyID: id)
        let snapshot = b.groupStore.snapshot
        let bytes = try await share.exported(as: .url)
        let url = try await URL(importing: bytes, contentType: .url)
        #expect(try ContactReplyURL.decode(url).kind == .accepted)
        #expect(b.groupStore.snapshot == snapshot)
        b.viewModel.accountSession.signOut()
        await #expect(throws: (any Error).self) { _ = try await share.exported(as: .url) }
    }


    @Test func unreadableReplyOffersTheExistingReloadAndCanBeSharedAfterRecovery() throws {
        let (_, b, id) = try pair()
        let before = b.groupStore.snapshot
        b.groupStore.readError = IntercomGroupError.storageUnavailable
        #expect(throws: (any Error).self) { try b.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: b.viewModel.accountAccessID) }
        #expect(b.viewModel.groupStorageIssue != nil)
        #expect(b.groupStore.snapshot == before)
        b.groupStore.readError = nil
        b.viewModel.reloadSavedGroups()
        #expect(b.viewModel.groupStorageIssue == nil)
        _ = try b.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: b.viewModel.accountAccessID)
        #expect(b.groupStore.snapshot == before)
    }


    @Test func deletingTheRegisteredPersonInvalidatesACapturedConfirmationShare() async throws {
        let (a, b, id) = try pair()
        let reply = try b.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: b.viewModel.accountAccessID)
        try a.viewModel.receiveContactReplyURL(reply)
        let record = try #require(a.viewModel.contactInvitationRecord(id))
        let share = InvitationShare(viewModel: a.viewModel, contactReplyID: id)
        #expect(a.viewModel.canShareContactReply(record))
        let person = try #require(a.viewModel.savedRemoteUsers.first).id
        #expect(a.viewModel.removeSavedUser(person))
        let afterDeletion = a.groupStore.snapshot
        #expect(a.viewModel.contactInvitationRecord(id)?.state == .confirmed)
        #expect(try a.viewModel.groupRepository.contactInvitationPayload(id).receipt != nil,
                "The binding remains for duplicate control acknowledgements")
        #expect(!a.viewModel.canShareContactReply(record))
        await #expect(throws: (any Error).self) { _ = try await share.exported(as: .url) }
        #expect(a.groupStore.snapshot == afterDeletion)
        try a.viewModel.receiveContactReplyURL(reply)
        #expect(a.viewModel.directoryUsers.isEmpty && a.viewModel.groups.isEmpty)
        #expect(a.groupStore.snapshot == afterDeletion, "A duplicate reply cannot restore a deleted person")
    }

    @Test func cancellingAReplyInvalidatesItsPreviouslyRenderedShareCondition() async throws {
        let (_, b, id) = try pair()
        let record = try #require(b.viewModel.contactInvitationRecord(id))
        let share = InvitationShare(viewModel: b.viewModel, contactReplyID: id)
        #expect(b.viewModel.canShareContactReply(record))
        try b.viewModel.cancelContactInvitation(id)
        let cancelled = b.groupStore.snapshot
        #expect(!b.viewModel.canShareContactReply(record))
        await #expect(throws: (any Error).self) { _ = try await share.exported(as: .url) }
        #expect(b.groupStore.snapshot == cancelled)
    }


    @Test func expiredReplyAndConfirmationDoNotSuggestAnImpossibleRetry() throws {
        var now = Date()
        let (a, b, id) = try pair(now: { now })
        let reply = try b.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: b.viewModel.accountAccessID)
        try a.viewModel.receiveContactReplyURL(reply)
        let incoming = try #require(b.viewModel.contactInvitationRecord(id))
        let confirmation = try #require(a.viewModel.contactInvitationRecord(id))
        let aBefore = a.groupStore.snapshot, bBefore = b.groupStore.snapshot
        #expect(!incoming.hasExpired(at: incoming.expiresAt - 0.001))
        #expect(incoming.hasExpired(at: incoming.expiresAt))
        now = Date(timeIntervalSince1970: incoming.expiresAt)
        #expect(b.viewModel.contactInvitationStatus(for: incoming) == "Contact saved. The reply has expired. Ask the sender for a new invitation.")
        #expect(a.viewModel.contactInvitationStatus(for: confirmation) == "Contact saved. This confirmation has expired.")
        #expect(!b.viewModel.resumeContactInvitation(id) && !a.viewModel.resumeContactInvitation(id))
        #expect(a.viewModel.contactInvitationMessage == "This invitation can no longer be used.")
        #expect(b.viewModel.contactInvitationMessage == "This invitation can no longer be used.")
        #expect(a.viewModel.savedRemoteUsers.count == 1 && b.viewModel.savedRemoteUsers.count == 1)
        #expect(a.groupStore.snapshot == aBefore && b.groupStore.snapshot == bBefore)
    }

}
