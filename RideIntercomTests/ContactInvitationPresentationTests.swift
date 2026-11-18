import CryptoKit
import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct ContactInvitationPresentationTests {
    private func authorURL() throws -> (AppTestSupport.Harness, URL) {
        let h = AppTestSupport.makeHarness(groups: [], localMemberID: "presentation-author")
        h.viewModel.contactSessionFactory = { RecordingCallSession() }
        return (h, try #require(h.viewModel.makeContactInviteURL()))
    }

    @Test func previewAndCancelDoNotCreateAUserPendingRecordOrSigningKey() throws {
        let (author, url) = try authorURL(); defer { author.viewModel.disconnect() }
        let keychain = DictionaryKeychain(), namespace = "contact-preview-" + UUID().uuidString
        let settings = InternetConnectionSettingsStore(keychain: keychain, namespace: namespace)
        let friend = AppTestSupport.makeHarness(groups: [], internetSettingsStore: settings, localMemberID: "presentation-friend")
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
        #expect(notification.connectedGroup != nil, "Closing the accepted preview keeps the bounded Users-owned notification alive")
    }

    @Test func contactShareReusesOneStoredTokenAndWritesOnlyOnCurrentCompletion() throws {
        var now = Date()
        let h = AppTestSupport.makeHarness(groups: [], localMemberID: "sharing-author", callAccessNow: { now })
        let vm = h.viewModel
        vm.contactSessionFactory = { RecordingCallSession() }
        defer { vm.disconnect() }
        let url = try #require(vm.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation).context.id
        let before = h.groupStore.saveCount
        let access = vm.accountAccessID
        let first = try vm.prepareContactInvitationShare(id, expectedAccountAccessID: access)
        let second = try vm.prepareContactInvitationShare(id, expectedAccountAccessID: access)
        let expectedDigest = SHA256.hash(data: Data(url.absoluteString.utf8))
        for share in [first, second] {
            #expect(share.id == id)
            #expect(SHA256.hash(data: Data(share.url.absoluteString.utf8)) == expectedDigest)
        }
        #expect(h.groupStore.saveCount == before)
        #expect(vm.contactInvitationRecord(id)?.sent == false)
        vm.completeContactInvitationSharing(first)
        vm.completeContactInvitationSharing(second)
        #expect(h.groupStore.saveCount == before + 1, "Only the first successful activity updates storage")
        #expect(vm.contactInvitationRecord(id)?.sent == true)
        #expect(vm.unlinkedContactInvitations.map(\.id) == [id])
        now = now.addingTimeInterval(8 * 24 * 60 * 60)
        #expect(throws: (any Error).self) { _ = try vm.prepareContactInvitationShare(id, expectedAccountAccessID: access) }
        now = Date()
        try vm.cancelContactInvitation(id)
        #expect(throws: (any Error).self) { _ = try vm.prepareContactInvitationShare(id, expectedAccountAccessID: access) }
        let anotherURL = try #require(vm.makeContactInviteURL())
        let anotherID = try #require(GroupInviteTokenCodec.decodeJoinURL(anotherURL, contactBootstrap: true).directInvitation).context.id
        let currentShare = try vm.prepareContactInvitationShare(anotherID, expectedAccountAccessID: access)
        vm.accountSession.signOut()
        let signedOutSaves = h.groupStore.saveCount
        vm.completeContactInvitationSharing(currentShare)
        #expect(h.groupStore.saveCount == signedOutSaves)
        #expect(throws: (any Error).self) { _ = try vm.prepareContactInvitationShare(anotherID, expectedAccountAccessID: access) }
    }

    /// Not sent until a share destination takes the link; expired sent invitations stay, as Expired, until a new
    /// one with the same name replaces them.
    @Test func invitationIsNotSentUntilSharedAndExpiredOnesOfferANewOne() throws {
        var now = Date()
        let h = AppTestSupport.makeHarness(groups: [], localMemberID: "state-author", callAccessNow: { now })
        h.viewModel.contactSessionFactory = { RecordingCallSession() }
        defer { h.viewModel.disconnect() }
        let url = try #require(h.viewModel.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation).context.id
        #expect(h.viewModel.setContactInvitationNickname(id, "Haruka"))
        var record = try #require(h.viewModel.contactInvitationRecord(id))
        #expect(h.viewModel.contactInvitationStateWord(for: record) == "Not sent yet")
        let share = try h.viewModel.prepareContactInvitationShare(id, expectedAccountAccessID: h.viewModel.accountAccessID)
        h.viewModel.completeContactInvitationSharing(share)
        record = try #require(h.viewModel.contactInvitationRecord(id))
        #expect(h.viewModel.contactInvitationStateWord(for: record) == "Waiting to be accepted")
        now = now.addingTimeInterval(8 * 24 * 60 * 60)
        record = try #require(h.viewModel.pendingContactInvitations.first { $0.id == id }, "An expired sent invitation stays listed")
        #expect(h.viewModel.contactInvitationStateWord(for: record) == "Expired")
        try h.viewModel.groupRepository.removeExpiredContactInvitations(now: now.timeIntervalSince1970)
        record = try #require(h.viewModel.contactInvitationRecord(id))
        #expect(record.state == .expired && record.credentialReference == nil, "The secret is gone; only the name is kept")
        h.viewModel.contactInvitationPresentation = .sharing(id)
        h.viewModel.sendNewContactInvitation(replacing: id)
        #expect(h.viewModel.contactInvitationRecord(id) == nil, "The new invitation replaces the expired one")
        let replacement = try #require(h.viewModel.pendingContactInvitations.first)
        #expect(replacement.id != id && replacement.nickname == "Haruka")
        #expect(h.viewModel.contactInvitationStateWord(for: replacement) == "Not sent yet")
        #expect(h.viewModel.contactInvitationPresentation?.id == "share-" + replacement.id.uuidString)
    }

    @Test(arguments: [false, true])
    func replacingAnExpiredInvitationKeepsItsNameWithoutAnIntermediateSave(tombstone: Bool) throws {
        var now = Date()
        let keys = InMemoryGroupCredentialStore()
        let h = AppTestSupport.makeHarness(groups: [], credentialStore: keys, localMemberID: "replace-author", callAccessNow: { now })
        let vm = h.viewModel
        vm.contactSessionFactory = { RecordingCallSession() }
        defer { vm.disconnect() }
        let url = try #require(vm.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation).context.id
        #expect(vm.setContactInvitationNickname(id, "Edited Haruka"))
        vm.stopContactInvitationSession()
        now = now.addingTimeInterval(8 * 24 * 60 * 60)
        if tombstone { try vm.groupRepository.removeExpiredContactInvitations(now: now.timeIntervalSince1970) }
        let before = h.groupStore.snapshot
        vm.contactInvitationPresentation = .sharing(id)
        // A second write would expose a partially saved replacement if saving its name failed.
        h.groupStore.failOnSaveNumber = h.groupStore.saveCount + 2
        vm.sendNewContactInvitation(replacing: id)
        let replacement = try #require(vm.pendingContactInvitations.first { $0.id != id })
        #expect(replacement.nickname == "Edited Haruka")
        #expect(vm.contactInvitationRecord(id) == nil)
        #expect(vm.contactInvitationPresentation?.id == "share-" + replacement.id.uuidString)
        #expect(vm.contactInvitationMessage == nil)
        #expect(h.groupStore.snapshot.contactInvitations.count == 1)
        #expect(h.groupStore.snapshot.groups == before.groups && h.groupStore.snapshot.users == before.users)
        let reloaded = GroupRepository(store: h.groupStore, credentials: keys)
        _ = try reloaded.load(localMemberID: "replace-author")
        #expect(reloaded.contactInvitations == [replacement])
        #expect(keys.values.count == 1, "Only the new invitation's credential remains")
        #expect(h.callSession.connectedGroup == nil, "Replacing an invitation never starts a call")
    }

    @Test func failedReplacementPreservesTheOriginalInvitationAndCanBeRetried() throws {
        var now = Date()
        let keys = InMemoryGroupCredentialStore()
        let h = AppTestSupport.makeHarness(groups: [], credentialStore: keys, localMemberID: "replace-failure", callAccessNow: { now })
        let vm = h.viewModel
        vm.contactSessionFactory = { RecordingCallSession() }
        defer { vm.disconnect() }
        let url = try #require(vm.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation).context.id
        #expect(vm.setContactInvitationNickname(id, "Kept name"))
        vm.stopContactInvitationSession()
        now = now.addingTimeInterval(8 * 24 * 60 * 60)
        vm.contactInvitationPresentation = .sharing(id)
        let before = h.groupStore.snapshot
        let oldReference = try #require(vm.contactInvitationRecord(id)?.credentialReference)
        h.groupStore.failSaving = true
        vm.sendNewContactInvitation(replacing: id)
        #expect(h.groupStore.snapshot == before)
        #expect(vm.contactInvitationRecord(id)?.nickname == "Kept name")
        #expect(vm.contactInvitationPresentation?.id == "share-" + id.uuidString)
        #expect(vm.contactInvitationMessage != nil)
        #expect(keys.values[oldReference] != nil, "A failed save preserves the committed credential")
        h.groupStore.failSaving = false
        vm.reloadSavedGroups()
        #expect(keys.values.count == 1, "Reload removes only the uncommitted orphan credential")
        vm.sendNewContactInvitation(replacing: id)
        #expect(vm.contactInvitationRecord(id) == nil)
        #expect(vm.pendingContactInvitations.count == 1)
        #expect(vm.pendingContactInvitations.first?.nickname == "Kept name")
        #expect(vm.contactInvitationMessage == nil)
    }

    @Test(arguments: [false, true])
    func replacementRejectsUnknownOrStillLiveInvitation(unknown: Bool) throws {
        let keys = InMemoryGroupCredentialStore()
        let h = AppTestSupport.makeHarness(groups: [], credentialStore: keys, localMemberID: "replace-live")
        let vm = h.viewModel
        vm.contactSessionFactory = { RecordingCallSession() }
        defer { vm.disconnect() }
        let url = try #require(vm.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation).context.id
        vm.stopContactInvitationSession()
        let before = h.groupStore.snapshot, references = Set(keys.values.keys)
        #expect(vm.makeContactInviteURL(replacingExpiredInvitation: unknown ? UUID() : id) == nil)
        #expect(h.groupStore.snapshot == before)
        #expect(Set(keys.values.keys) == references)
        #expect(vm.contactInvitationID == nil)
    }

    @Test func acceptingAPreviewRegistersTheInviterWithoutInterruptingAnExistingCall() throws {
        let (author, url) = try authorURL(); defer { author.viewModel.disconnect() }
        let group = try IntercomGroup(name: "Current call", members: [.init(id: "presentation-friend", displayName: "Friend")], accessSecret: "current-call-key")
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
        #expect(notification.connectedGroup == nil)
        #expect(friend.viewModel.regularGroups.map(\.id) == [group.id])
    }
}
