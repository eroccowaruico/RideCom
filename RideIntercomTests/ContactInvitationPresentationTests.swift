import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct ContactInvitationPresentationTests {
    private func authorURL() throws -> (AppTestSupport.Harness, URL) {
        let harness = AppTestSupport.makeHarness(groups: [], localMemberID: "presentation-author")
        harness.viewModel.contactSessionFactory = { RecordingCallSession() }
        return (harness, try #require(harness.viewModel.makeContactInviteURL()))
    }

    @Test func previewAndCancelDoNotCreateAUserPendingRecordOrSigningKey() throws {
        let (author, url) = try authorURL(); defer { author.viewModel.disconnect() }
        let keychain = DictionaryKeychain(), namespace = "contact-preview-" + UUID().uuidString
        let settings = InternetConnectionSettingsStore(keychain: keychain, namespace: namespace)
        let friend = AppTestSupport.makeHarness(
            groups: [], internetSettingsStore: settings, localMemberID: "presentation-friend")
        let notification = RecordingCallSession()
        friend.viewModel.contactSessionFactory = { notification }
        defer { friend.viewModel.disconnect() }
        let snapshot = friend.groupStore.snapshot, saves = friend.groupStore.saveCount
        #expect(friend.viewModel.previewContactInvitation(url))
        #expect(friend.viewModel.contactInvitationPresentation?.id.hasPrefix("accept-") == true)
        #expect(friend.groupStore.snapshot == snapshot)
        #expect(friend.groupStore.saveCount == saves)
        #expect(keychain.accounts(service: namespace + ".InternetConnection").isEmpty)
        friend.viewModel.dismissContactInvitationPresentation()
        #expect(friend.viewModel.contactInvitationPresentation?.id == nil)
        #expect(friend.groupStore.snapshot == snapshot)
        #expect(friend.viewModel.savedRemoteUsers.isEmpty)
        #expect(friend.viewModel.pendingContactInvitations.isEmpty)
        #expect(friend.viewModel.previewContactInvitation(url))
        #expect(friend.viewModel.acceptPresentedContactInvitation())
        #expect(friend.viewModel.contactInvitationPresentation?.id == nil)
        #expect(friend.viewModel.contactInvitationID != nil)
        #expect(
            notification.connectedGroup != nil,
            "Closing the accepted preview keeps the bounded Users-owned notification alive")
    }

    @Test func contactShareReusesOneStoredTokenAndWritesOnlyOnCurrentCompletion() throws {
        var now = Date()
        let harness = AppTestSupport.makeHarness(groups: [], localMemberID: "sharing-author", callAccessNow: { now })
        let viewModel = harness.viewModel
        viewModel.contactSessionFactory = { RecordingCallSession() }
        defer { viewModel.disconnect() }
        let url = try #require(viewModel.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation)
            .context.id
        let before = harness.groupStore.saveCount
        let access = viewModel.accountAccessID
        let first = try viewModel.prepareContactInvitationShare(id, expectedAccountAccessID: access)
        let second = try viewModel.prepareContactInvitationShare(id, expectedAccountAccessID: access)
        let expectedDigest = SHA256.hash(data: Data(url.absoluteString.utf8))
        for share in [first, second] {
            #expect(share.id == id)
            #expect(SHA256.hash(data: Data(share.url.absoluteString.utf8)) == expectedDigest)
        }
        #expect(harness.groupStore.saveCount == before)
        #expect(viewModel.contactInvitationRecord(id)?.sent == false)
        viewModel.completeContactInvitationSharing(first)
        viewModel.completeContactInvitationSharing(second)
        #expect(harness.groupStore.saveCount == before + 1, "Only the first successful activity updates storage")
        #expect(viewModel.contactInvitationRecord(id)?.sent == true)
        #expect(viewModel.unlinkedContactInvitations.map(\.id) == [id])
        now = now.addingTimeInterval(8 * 24 * 60 * 60)
        #expect(throws: (any Error).self) {
            _ = try viewModel.prepareContactInvitationShare(id, expectedAccountAccessID: access)
        }
        now = Date()
        try viewModel.cancelContactInvitation(id)
        #expect(throws: (any Error).self) {
            _ = try viewModel.prepareContactInvitationShare(id, expectedAccountAccessID: access)
        }
        let anotherURL = try #require(viewModel.makeContactInviteURL())
        let anotherID = try #require(
            GroupInviteTokenCodec.decodeJoinURL(anotherURL, contactBootstrap: true).directInvitation
        ).context.id
        let currentShare = try viewModel.prepareContactInvitationShare(anotherID, expectedAccountAccessID: access)
        viewModel.accountSession.signOut()
        let signedOutSaves = harness.groupStore.saveCount
        viewModel.completeContactInvitationSharing(currentShare)
        #expect(harness.groupStore.saveCount == signedOutSaves)
        #expect(throws: (any Error).self) {
            _ = try viewModel.prepareContactInvitationShare(anotherID, expectedAccountAccessID: access)
        }
    }

    /// Not sent until a share destination takes the link; expired sent invitations stay, as Expired, until a new
    /// one with the same name replaces them.
    @Test func invitationIsNotSentUntilSharedAndExpiredOnesOfferANewOne() throws {
        var now = Date()
        let harness = AppTestSupport.makeHarness(groups: [], localMemberID: "state-author", callAccessNow: { now })
        harness.viewModel.contactSessionFactory = { RecordingCallSession() }
        defer { harness.viewModel.disconnect() }
        let url = try #require(harness.viewModel.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation)
            .context.id
        #expect(harness.viewModel.setContactInvitationNickname(id, "Haruka"))
        var record = try #require(harness.viewModel.contactInvitationRecord(id))
        #expect(harness.viewModel.contactInvitationStateWord(for: record) == "Not sent yet")
        let share = try harness.viewModel.prepareContactInvitationShare(
            id, expectedAccountAccessID: harness.viewModel.accountAccessID)
        harness.viewModel.completeContactInvitationSharing(share)
        record = try #require(harness.viewModel.contactInvitationRecord(id))
        #expect(harness.viewModel.contactInvitationStateWord(for: record) == "Waiting to be accepted")
        now = now.addingTimeInterval(8 * 24 * 60 * 60)
        record = try #require(
            harness.viewModel.pendingContactInvitations.first { $0.id == id },
            "An expired sent invitation stays listed")
        #expect(harness.viewModel.contactInvitationStateWord(for: record) == "Expired")
        try harness.viewModel.groupRepository.removeExpiredContactInvitations(now: now.timeIntervalSince1970)
        record = try #require(harness.viewModel.contactInvitationRecord(id))
        #expect(
            record.state == .expired && record.credentialReference == nil,
            "The secret is gone; only the name is kept")
        harness.viewModel.contactInvitationPresentation = .sharing(id)
        harness.viewModel.sendNewContactInvitation(replacing: id)
        #expect(harness.viewModel.contactInvitationRecord(id) == nil, "The new invitation replaces the expired one")
        let replacement = try #require(harness.viewModel.pendingContactInvitations.first)
        #expect(replacement.id != id && replacement.nickname == "Haruka")
        #expect(harness.viewModel.contactInvitationStateWord(for: replacement) == "Not sent yet")
        #expect(harness.viewModel.contactInvitationPresentation?.id == "share-" + replacement.id.uuidString)
    }

    @Test(arguments: [false, true])
    func replacingAnExpiredInvitationKeepsItsNameWithoutAnIntermediateSave(tombstone: Bool) throws {
        var now = Date()
        let keys = InMemoryGroupCredentialStore()
        let harness = AppTestSupport.makeHarness(
            groups: [], credentialStore: keys, localMemberID: "replace-author", callAccessNow: { now })
        let viewModel = harness.viewModel
        viewModel.contactSessionFactory = { RecordingCallSession() }
        defer { viewModel.disconnect() }
        let url = try #require(viewModel.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation)
            .context.id
        #expect(viewModel.setContactInvitationNickname(id, "Edited Haruka"))
        viewModel.stopContactInvitationSession()
        now = now.addingTimeInterval(8 * 24 * 60 * 60)
        if tombstone { try viewModel.groupRepository.removeExpiredContactInvitations(now: now.timeIntervalSince1970) }
        let before = harness.groupStore.snapshot
        viewModel.contactInvitationPresentation = .sharing(id)
        // A second write would expose a partially saved replacement if saving its name failed.
        harness.groupStore.failOnSaveNumber = harness.groupStore.saveCount + 2
        viewModel.sendNewContactInvitation(replacing: id)
        let replacement = try #require(viewModel.pendingContactInvitations.first { $0.id != id })
        #expect(replacement.nickname == "Edited Haruka")
        #expect(viewModel.contactInvitationRecord(id) == nil)
        #expect(viewModel.contactInvitationPresentation?.id == "share-" + replacement.id.uuidString)
        #expect(viewModel.contactInvitationMessage == nil)
        #expect(harness.groupStore.snapshot.contactInvitations.count == 1)
        #expect(
            harness.groupStore.snapshot.groups == before.groups
                && harness.groupStore.snapshot.users == before.users)
        let reloaded = GroupRepository(store: harness.groupStore, credentials: keys)
        _ = try reloaded.load(localMemberID: "replace-author")
        #expect(reloaded.contactInvitations == [replacement])
        #expect(keys.values.count == 1, "Only the new invitation's credential remains")
        #expect(harness.callSession.connectedGroup == nil, "Replacing an invitation never starts a call")
    }

    @Test func failedReplacementPreservesTheOriginalInvitationAndCanBeRetried() throws {
        var now = Date()
        let keys = InMemoryGroupCredentialStore()
        let harness = AppTestSupport.makeHarness(
            groups: [], credentialStore: keys, localMemberID: "replace-failure", callAccessNow: { now })
        let viewModel = harness.viewModel
        viewModel.contactSessionFactory = { RecordingCallSession() }
        defer { viewModel.disconnect() }
        let url = try #require(viewModel.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation)
            .context.id
        #expect(viewModel.setContactInvitationNickname(id, "Kept name"))
        viewModel.stopContactInvitationSession()
        now = now.addingTimeInterval(8 * 24 * 60 * 60)
        viewModel.contactInvitationPresentation = .sharing(id)
        let before = harness.groupStore.snapshot
        let oldReference = try #require(viewModel.contactInvitationRecord(id)?.credentialReference)
        harness.groupStore.failSaving = true
        viewModel.sendNewContactInvitation(replacing: id)
        #expect(harness.groupStore.snapshot == before)
        #expect(viewModel.contactInvitationRecord(id)?.nickname == "Kept name")
        #expect(viewModel.contactInvitationPresentation?.id == "share-" + id.uuidString)
        #expect(viewModel.contactInvitationMessage != nil)
        #expect(keys.values[oldReference] != nil, "A failed save preserves the committed credential")
        harness.groupStore.failSaving = false
        viewModel.reloadSavedGroups()
        #expect(keys.values.count == 1, "Reload removes only the uncommitted orphan credential")
        viewModel.sendNewContactInvitation(replacing: id)
        #expect(viewModel.contactInvitationRecord(id) == nil)
        #expect(viewModel.pendingContactInvitations.count == 1)
        #expect(viewModel.pendingContactInvitations.first?.nickname == "Kept name")
        #expect(viewModel.contactInvitationMessage == nil)
    }

    @Test(arguments: [false, true])
    func replacementRejectsUnknownOrStillLiveInvitation(unknown: Bool) throws {
        let keys = InMemoryGroupCredentialStore()
        let harness = AppTestSupport.makeHarness(groups: [], credentialStore: keys, localMemberID: "replace-live")
        let viewModel = harness.viewModel
        viewModel.contactSessionFactory = { RecordingCallSession() }
        defer { viewModel.disconnect() }
        let url = try #require(viewModel.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation)
            .context.id
        viewModel.stopContactInvitationSession()
        let before = harness.groupStore.snapshot, references = Set(keys.values.keys)
        #expect(viewModel.makeContactInviteURL(replacingExpiredInvitation: unknown ? UUID() : id) == nil)
        #expect(harness.groupStore.snapshot == before)
        #expect(Set(keys.values.keys) == references)
        #expect(viewModel.contactInvitationID == nil)
    }

    @Test func acceptingAPreviewRegistersTheInviterWithoutInterruptingAnExistingCall() throws {
        let (author, url) = try authorURL(); defer { author.viewModel.disconnect() }
        let group = try IntercomGroup(
            name: "Current call", members: [.init(id: "presentation-friend", displayName: "Friend")],
            accessSecret: "current-call-key")
        let friend = AppTestSupport.makeHarness(groups: [group], localMemberID: "presentation-friend")
        let notification = RecordingCallSession()
        friend.viewModel.contactSessionFactory = { notification }
        defer { friend.viewModel.disconnect() }
        friend.viewModel.selectGroup(group)
        friend.viewModel.applyLocalMute(true)
        let disconnects = friend.callSession.disconnectCallCount
        #expect(friend.viewModel.previewContactInvitation(url))
        #expect(friend.viewModel.acceptPresentedContactInvitation())
        #expect(friend.viewModel.savedRemoteUsers.map(\.memberIDs) == [["presentation-author"]])
        #expect(friend.viewModel.activeGroupID == group.id)
        #expect(friend.viewModel.isMuted)
        #expect(friend.callSession.disconnectCallCount == disconnects)
        #expect(friend.callSession.connectedGroup?.id == group.id)
        #expect(notification.connectedGroup != nil && notification.connectedGroup?.id != group.id)
        #expect(notification.enabledRouteValues.last == [.multipeer])
        #expect(notification.startMediaCallCount == 0)
        #expect(friend.viewModel.regularGroups.map(\.id) == [group.id])
    }
}
