import CoreTransferable
import Foundation
import RTC
import UniformTypeIdentifiers
import Testing
@testable import RideIntercom

extension ContactReplyTests {
    @Test func onlyManuallyReceivedRepliesOfferTheStandardReturnConfirmation() throws {
        let ((authorHarness, recipientHarness), id) = try pair()
        let pending = try #require(authorHarness.viewModel.contactInvitationRecord(id))
        #expect(pending.receivedBySharing == nil)
        #expect(!authorHarness.viewModel.canShareContactReply(pending))
        let reply = try recipientHarness.viewModel.contactReplyURLForSharing(
            id, expectedAccountAccessID: recipientHarness.viewModel.accountAccessID)
        #expect(authorHarness.viewModel.handleContactReplyURL(reply))
        let record = try #require(authorHarness.viewModel.contactInvitationRecord(id))
        #expect(record.receivedBySharing == true && authorHarness.viewModel.canShareContactReply(record))
        let reloaded = try GroupSnapshot.decode(authorHarness.groupStore.snapshot.encoded())
        #expect(reloaded.contactInvitations.first?.receivedBySharing == true)
        let snapshot = authorHarness.groupStore.snapshot
        #expect(
            !authorHarness.viewModel.handleContactReplyURL(
                URL(string: "rideintercom://contact-reply?receipt=invalid")!))
        #expect(authorHarness.groupStore.snapshot == snapshot && authorHarness.viewModel.groupStorageIssue == nil)
        #expect(authorHarness.viewModel.contactInvitationMessage != nil)
    }

    @Test func replyTransferableRechecksTheAccountAtTheActualExport() async throws {
        let ((_, recipientHarness), id) = try pair()
        let share = InvitationShare(viewModel: recipientHarness.viewModel, contactReplyID: id)
        let snapshot = recipientHarness.groupStore.snapshot
        let bytes = try await share.exported(as: .url)
        let url = try await URL(importing: bytes, contentType: .url)
        #expect(try ContactReplyURL.decode(url).kind == .accepted)
        #expect(recipientHarness.groupStore.snapshot == snapshot)
        recipientHarness.viewModel.accountSession.signOut()
        await #expect(throws: (any Error).self) { _ = try await share.exported(as: .url) }
    }

    @Test func unreadableReplyOffersTheExistingReloadAndCanBeSharedAfterRecovery() throws {
        let ((_, recipientHarness), id) = try pair()
        let before = recipientHarness.groupStore.snapshot
        recipientHarness.groupStore.readError = IntercomGroupError.storageUnavailable
        #expect(throws: (any Error).self) {
            try recipientHarness.viewModel.contactReplyURLForSharing(
                id, expectedAccountAccessID: recipientHarness.viewModel.accountAccessID)
        }
        #expect(recipientHarness.viewModel.groupStorageIssue != nil)
        #expect(recipientHarness.groupStore.snapshot == before)
        recipientHarness.groupStore.readError = nil
        recipientHarness.viewModel.reloadSavedGroups()
        #expect(recipientHarness.viewModel.groupStorageIssue == nil)
        _ = try recipientHarness.viewModel.contactReplyURLForSharing(
            id, expectedAccountAccessID: recipientHarness.viewModel.accountAccessID)
        #expect(recipientHarness.groupStore.snapshot == before)
    }

    @Test func deletingTheRegisteredPersonInvalidatesACapturedConfirmationShare() async throws {
        let ((authorHarness, recipientHarness), id) = try pair()
        let reply = try recipientHarness.viewModel.contactReplyURLForSharing(
            id, expectedAccountAccessID: recipientHarness.viewModel.accountAccessID)
        try authorHarness.viewModel.receiveContactReplyURL(reply)
        let record = try #require(authorHarness.viewModel.contactInvitationRecord(id))
        let share = InvitationShare(viewModel: authorHarness.viewModel, contactReplyID: id)
        #expect(authorHarness.viewModel.canShareContactReply(record))
        let person = try #require(authorHarness.viewModel.savedRemoteUsers.first).id
        #expect(authorHarness.viewModel.removeSavedUser(person))
        let afterDeletion = authorHarness.groupStore.snapshot
        #expect(authorHarness.viewModel.contactInvitationRecord(id)?.state == .cancelled)
        #expect(authorHarness.viewModel.contactInvitationRecord(id)?.credentialReference == nil)
        #expect(throws: GroupStorageError.invalidUpdate) {
            try authorHarness.viewModel.groupRepository.contactInvitationPayload(id)
        }
        #expect(!authorHarness.viewModel.canShareContactReply(record))
        await #expect(throws: (any Error).self) { _ = try await share.exported(as: .url) }
        #expect(authorHarness.groupStore.snapshot == afterDeletion)
        #expect(!authorHarness.viewModel.handleContactReplyURL(reply))
        #expect(authorHarness.viewModel.directoryUsers.isEmpty && authorHarness.viewModel.groups.isEmpty)
        #expect(authorHarness.groupStore.snapshot == afterDeletion, "A duplicate reply cannot restore a deleted person")
    }

    @Test func cancellingAReplyInvalidatesItsPreviouslyRenderedShareCondition() async throws {
        let ((_, recipientHarness), id) = try pair()
        let record = try #require(recipientHarness.viewModel.contactInvitationRecord(id))
        let share = InvitationShare(viewModel: recipientHarness.viewModel, contactReplyID: id)
        #expect(recipientHarness.viewModel.canShareContactReply(record))
        try recipientHarness.viewModel.cancelContactInvitation(id)
        let cancelled = recipientHarness.groupStore.snapshot
        #expect(!recipientHarness.viewModel.canShareContactReply(record))
        await #expect(throws: (any Error).self) { _ = try await share.exported(as: .url) }
        #expect(recipientHarness.groupStore.snapshot == cancelled)
    }

    @Test func expiredReplyAndConfirmationDoNotSuggestAnImpossibleRetry() throws {
        var now = Date()
        let ((authorHarness, recipientHarness), id) = try pair(now: { now })
        let reply = try recipientHarness.viewModel.contactReplyURLForSharing(
            id, expectedAccountAccessID: recipientHarness.viewModel.accountAccessID)
        try authorHarness.viewModel.receiveContactReplyURL(reply)
        let incoming = try #require(recipientHarness.viewModel.contactInvitationRecord(id))
        let confirmation = try #require(authorHarness.viewModel.contactInvitationRecord(id))
        let aBefore = authorHarness.groupStore.snapshot, bBefore = recipientHarness.groupStore.snapshot
        #expect(!incoming.hasExpired(at: incoming.expiresAt - 0.001))
        #expect(incoming.hasExpired(at: incoming.expiresAt))
        now = Date(timeIntervalSince1970: incoming.expiresAt)
        #expect(
            recipientHarness.viewModel.contactInvitationStatus(for: incoming)
                == "Contact saved. The reply has expired. Ask the sender for a new invitation.")
        #expect(
            authorHarness.viewModel.contactInvitationStatus(for: confirmation)
                == "Contact saved. This confirmation has expired.")
        #expect(
            !recipientHarness.viewModel.resumeContactInvitation(id)
                && !authorHarness.viewModel.resumeContactInvitation(id))
        #expect(authorHarness.viewModel.contactInvitationMessage == "This invitation can no longer be used.")
        #expect(recipientHarness.viewModel.contactInvitationMessage == "This invitation can no longer be used.")
        #expect(
            authorHarness.viewModel.savedRemoteUsers.count == 1
                && recipientHarness.viewModel.savedRemoteUsers.count == 1)
        #expect(authorHarness.groupStore.snapshot == aBefore && recipientHarness.groupStore.snapshot == bBefore)
    }

    func reopenLegacyPending(_ harness: AppTestSupport.Harness, id: UUID, personWasDeleted: Bool = false) throws
        -> URL {
        let url = try GroupInviteTokenCodec.joinURL(
            for: harness.viewModel.groupRepository.contactInvitationPayload(id).token, contactBootstrap: true)
        var old = harness.groupStore.snapshot
        old.version = 9
        for group in old.groups.indices { old.groups[group].contactRegistration = nil }
        let index = try #require(old.contactInvitations.firstIndex { $0.id == id })
        old.contactInvitations[index].personID = nil
        if personWasDeleted { old.users = []; old.groups = [] }
        let expectedPerson = old.users.first { $0.memberIDs.contains("reply-author") }?.id
        harness.groupStore.snapshot = try GroupSnapshot.decode(old.encoded())
        harness.viewModel.reloadSavedGroups()
        #expect(harness.groupStore.snapshot.version == GroupSnapshot.currentVersion)
        #expect(harness.viewModel.contactInvitationRecord(id)?.personID == expectedPerson)
        return url
    }

    @Test func migratingAnOldPendingInvitationFindsTheSameVerifiedPerson() throws {
        let ((_, recipientHarness), id) = try pair()
        let person = try #require(recipientHarness.viewModel.savedRemoteUsers.first)
        let url = try reopenLegacyPending(recipientHarness, id: id)
        #expect(recipientHarness.viewModel.previewContactInvitation(url))
        let presentation = recipientHarness.viewModel.contactInvitationPresentation
        #expect(
            recipientHarness.viewModel.acceptPresentedContactInvitation(
                expectedInvitationID: id, keepingPresentation: true))
        #expect(recipientHarness.viewModel.contactInvitationRecord(id)?.personID == person.id)
        #expect(recipientHarness.viewModel.contactInvitationPresentation == presentation)
        #expect(recipientHarness.viewModel.directoryUsers.count == 1)
        recipientHarness.viewModel.stopContactInvitationSession()
    }

    @Test func deletingTheMigratedPersonCancelsItsPendingReply() throws {
        let ((_, recipientHarness), id) = try pair()
        _ = try reopenLegacyPending(recipientHarness, id: id)
        let person = try #require(recipientHarness.viewModel.savedRemoteUsers.first).id
        #expect(recipientHarness.viewModel.removeSavedUser(person))
        #expect(recipientHarness.viewModel.contactInvitationRecord(id)?.state == .cancelled)
        #expect(recipientHarness.viewModel.contactInvitationRecord(id)?.credentialReference == nil)
        #expect(!recipientHarness.viewModel.resumeContactInvitation(id))
        #expect(recipientHarness.viewModel.directoryUsers.isEmpty && recipientHarness.viewModel.groups.isEmpty)
        recipientHarness.viewModel.stopContactInvitationSession()
    }

    @Test func anOldPendingReplyWithoutItsPersonCannotPretendToRegisterOrStartTransport() throws {
        let ((_, recipientHarness), id) = try pair()
        let url = try reopenLegacyPending(recipientHarness, id: id, personWasDeleted: true)
        #expect(recipientHarness.viewModel.contactInvitationRecord(id)?.state == .cancelled)
        #expect(recipientHarness.viewModel.contactInvitationRecord(id)?.credentialReference == nil)
        let before = recipientHarness.groupStore.snapshot
        var starts = 0
        recipientHarness.viewModel.contactSessionFactory = { starts += 1; return RecordingCallSession() }
        #expect(recipientHarness.viewModel.previewContactInvitation(url))
        #expect(
            !recipientHarness.viewModel.acceptPresentedContactInvitation(
                expectedInvitationID: id, keepingPresentation: true))
        #expect(starts == 0 && recipientHarness.viewModel.contactInvitationID == nil)
        #expect(recipientHarness.viewModel.directoryUsers.isEmpty && recipientHarness.viewModel.groups.isEmpty)
        #expect(recipientHarness.groupStore.snapshot == before)
        #expect(
            recipientHarness.viewModel.contactInvitationMessage
                == "This invitation could not be accepted. Ask the sender for a new invitation.")
        recipientHarness.viewModel.stopContactInvitationSession()
    }

    @Test func failedOrphanMigrationPreservesTheOldCheckpointUntilReloadSucceeds() throws {
        let ((_, recipientHarness), id) = try pair()
        var old = recipientHarness.groupStore.snapshot
        old.version = 9; old.users = []; old.groups = []
        let index = try #require(old.contactInvitations.firstIndex { $0.id == id })
        old.contactInvitations[index].personID = nil
        recipientHarness.groupStore.snapshot = try GroupSnapshot.decode(old.encoded())
        recipientHarness.groupStore.failSaving = true
        recipientHarness.viewModel.reloadSavedGroups()
        #expect(recipientHarness.viewModel.groupStorageIssue != nil)
        #expect(recipientHarness.groupStore.snapshot == old)
        #expect(!recipientHarness.viewModel.resumeContactInvitation(id))
        recipientHarness.groupStore.failSaving = false
        recipientHarness.viewModel.reloadSavedGroups()
        #expect(recipientHarness.viewModel.groupStorageIssue == nil)
        #expect(recipientHarness.viewModel.contactInvitationRecord(id)?.state == .cancelled)
        #expect(recipientHarness.viewModel.contactInvitationRecord(id)?.credentialReference == nil)
        #expect(recipientHarness.viewModel.directoryUsers.isEmpty && recipientHarness.viewModel.groups.isEmpty)
    }

    @Test(arguments: [false, true])
    func aPersonsReplyCanRetryAndStopFromSettingsOrItsAcceptedPreview(keepingPreview: Bool) throws {
        let ((_, recipientHarness), id) = try pair()
        let person = try #require(recipientHarness.viewModel.savedRemoteUsers.first).id
        if keepingPreview {
            let url = try GroupInviteTokenCodec.joinURL(
                for: recipientHarness.viewModel.groupRepository.contactInvitationPayload(id).token,
                contactBootstrap: true)
            #expect(recipientHarness.viewModel.previewContactInvitation(url))
            #expect(
                recipientHarness.viewModel.acceptPresentedContactInvitation(
                    expectedInvitationID: id, keepingPresentation: true))
            recipientHarness.viewModel.stopContactInvitationSession()
        }
        let presentation = recipientHarness.viewModel.contactInvitationPresentation
        let before = recipientHarness.groupStore.snapshot
        #expect(!recipientHarness.viewModel.retryContactPersonInvitation(id, personID: UUID()))
        #expect(!recipientHarness.viewModel.cancelContactPersonInvitation(id, personID: UUID()))
        #expect(recipientHarness.groupStore.snapshot == before)
        #expect(recipientHarness.viewModel.retryContactPersonInvitation(id, personID: person))
        #expect(recipientHarness.viewModel.contactInvitationID == id)
        #expect(recipientHarness.viewModel.contactInvitationPresentation == presentation)
        #expect(recipientHarness.viewModel.cancelContactPersonInvitation(id, personID: person))
        let stopped = try #require(recipientHarness.viewModel.contactInvitationRecord(id))
        #expect(stopped.state == .cancelled && !stopped.canResume)
        #expect(recipientHarness.viewModel.contactInvitationStatus(for: stopped) == "Retries stopped on this device.")
        #expect(recipientHarness.viewModel.contactInvitationID == nil)
        #expect(recipientHarness.viewModel.contactInvitationPresentation == presentation)
        #expect(recipientHarness.viewModel.savedRemoteUsers.map(\.id) == [person])
    }

}
