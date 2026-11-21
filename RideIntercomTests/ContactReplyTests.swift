import CoreTransferable
import Foundation
import RTC
import UniformTypeIdentifiers
import Testing
@testable import RideIntercom

@MainActor
struct ContactReplyTests {
    func pair(
        now: @escaping @MainActor () -> Date = Date.init,
        authorCredentials: GroupCredentialStoring? = nil,
        friendCredentials: GroupCredentialStoring? = nil
    ) throws -> ((AppTestSupport.Harness, AppTestSupport.Harness), UUID) {
        let author = AppTestSupport.makeHarness(groups: [], credentialStore: authorCredentials,
                                               localMemberID: "reply-author", callAccessNow: now)
        let friend = AppTestSupport.makeHarness(groups: [], credentialStore: friendCredentials,
                                               localMemberID: "reply-friend", callAccessNow: now)
        author.viewModel.contactSessionFactory = { RecordingCallSession() }
        friend.viewModel.contactSessionFactory = { RecordingCallSession() }
        author.viewModel.beginContactInvitationPresentation()
        guard case .person(let person) = author.viewModel.contactInvitationPresentation else {
            throw ContactInvitationError.unavailable
        }
        #expect(author.viewModel.saveContactPerson(person, name: "My Friend", usesProvisionalName: true))
        let share = try author.viewModel.prepareContactPersonShare(
            person, expectedAccountAccessID: author.viewModel.accountAccessID)
        author.viewModel.completeContactInvitationSharing(share)
        try friend.viewModel.acceptContactInviteURL(share.url)
        author.viewModel.stopContactInvitationSession(); friend.viewModel.stopContactInvitationSession()
        let id = try #require(friend.viewModel.pendingContactInvitations.first).id
        return ((author, friend), id)
    }

    @Test func independentlyRemovedContactsConfirmBothDeletionsAfterRestart() throws {
        let aKeys = InMemoryGroupCredentialStore(), bKeys = InMemoryGroupCredentialStore()
        let ((author, friend), id) = try pair(authorCredentials: aKeys, friendCredentials: bKeys)
        let authorModel = author.viewModel, recipientModel = friend.viewModel
        defer { authorModel.disconnect(); recipientModel.disconnect() }
        try authorModel.receiveContactReplyURL(
            recipientModel.contactReplyURLForSharing(id, expectedAccountAccessID: recipientModel.accountAccessID))
        let pairID = IntercomGroup.directCallID(memberIDs: ["reply-author", "reply-friend"])
        let oldKey = try #require(try authorModel.groupRepository.credential(for: pairID)).secret
        try #require(authorModel.removeSavedUser(try #require(authorModel.savedRemoteUsers.first).id))
        try #require(recipientModel.removeSavedUser(try #require(recipientModel.savedRemoteUsers.first).id))
        #expect(!aKeys.values.values.contains(oldKey) && !bKeys.values.values.contains(oldKey))
        let aDeletion = try #require(authorModel.groupRepository.contactDeletions.first)
        let bDeletion = try #require(recipientModel.groupRepository.contactDeletions.first)
        author.groupStore.snapshot = try GroupSnapshot.decode(author.groupStore.snapshot.encoded())
        friend.groupStore.snapshot = try GroupSnapshot.decode(friend.groupStore.snapshot.encoded())
        let left = AppTestSupport.makeHarness(groups: [], groupStore: author.groupStore, credentialStore: aKeys,
                                              localMemberID: "reply-author").viewModel
        let right = AppTestSupport.makeHarness(groups: [], groupStore: friend.groupStore, credentialStore: bKeys,
                                               localMemberID: "reply-friend").viewModel
        defer { left.disconnect(); right.disconnect() }
        let rightSigner = try #require(try right.internetSettingsStore.contactDeletionSigner(memberID: "reply-friend"))
        let wrong = try ContactDeletionNotice(signer: rightSigner, recipientMemberID: "reply-author",
            recipientKey: bDeletion.target.recipientKey, pairSecret: "unrelated-relationship", now: Date())
        #expect(throws: (any Error).self) { try left.receiveContactDeletion(wrong, from: "reply-friend") }
        let aReceipt = try right.receiveContactDeletion(aDeletion, from: "reply-author")
        try left.acknowledgeContactDeletion(aReceipt, from: "reply-friend")
        #expect(left.groupRepository.contactDeletions.isEmpty)
        #expect(left.nearbyGroupDeliveryCredentials()[.init(rawValue: "reply-friend")] != nil)
        let bReceipt = try left.receiveContactDeletion(bDeletion, from: "reply-friend")
        let saves = author.groupStore.saveCount
        #expect(try left.receiveContactDeletion(bDeletion, from: "reply-friend") == bReceipt)
        #expect(author.groupStore.saveCount == saves)
        try right.acknowledgeContactDeletion(bReceipt, from: "reply-author")
        #expect(left.savedRemoteUsers.isEmpty && right.savedRemoteUsers.isEmpty)
        #expect(left.groupRepository.contactDeletions.isEmpty && right.groupRepository.contactDeletions.isEmpty)
        #expect(aKeys.values.isEmpty && bKeys.values.isEmpty)
    }

    @Test func aFormerContactKeyCannotAuthorizeDeletingTheNewRegistration() throws {
        let ((author, friend), id) = try pair()
        let authorModel = author.viewModel, recipientModel = friend.viewModel
        defer { authorModel.disconnect(); recipientModel.disconnect() }
        try authorModel.receiveContactReplyURL(
            recipientModel.contactReplyURLForSharing(id, expectedAccountAccessID: recipientModel.accountAccessID))
        try #require(authorModel.removeSavedUser(try #require(authorModel.savedRemoteUsers.first).id))
        try #require(recipientModel.removeSavedUser(try #require(recipientModel.savedRemoteUsers.first).id))
        let old = try #require(authorModel.groupRepository.contactDeletions.first)
        try #require(recipientModel.groupRepository.contactDeletionFormerPairs.count == 1)
        try recipientModel.acceptContactInviteURL(try #require(authorModel.makeContactInviteURL()))
        let before = friend.groupStore.snapshot
        #expect(throws: (any Error).self) { try recipientModel.receiveContactDeletion(old, from: "reply-author") }
        #expect(friend.groupStore.snapshot == before)
        #expect(recipientModel.savedRemoteUsers.count == 1)
    }

    @Test func offlineContactRemovalKeepsOnlyADeliverableDeletionAfterRestart() throws {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let keys = InMemoryGroupCredentialStore()
        let ((author, friend), id) = try pair(now: { now }, authorCredentials: keys)
        let authorModel = author.viewModel, recipientModel = friend.viewModel
        defer { authorModel.disconnect(); recipientModel.disconnect() }
        let reply = try recipientModel.contactReplyURLForSharing(
            id, expectedAccountAccessID: recipientModel.accountAccessID)
        try authorModel.receiveContactReplyURL(reply)
        let person = try #require(authorModel.savedRemoteUsers.first)
        let friendRecord = try #require(recipientModel.savedRemoteUsers.first)
        let senderKey = try #require(friendRecord.deviceKeys?["reply-author"])
        let pairID = IntercomGroup.directCallID(memberIDs: ["reply-author", "reply-friend"])
        let oldSecret = try #require(try recipientModel.groupRepository.credential(for: pairID)).secret
        let recipient = try recipientModel.internetSettingsStore.invitationSigner(memberID: "reply-friend")

        author.groupStore.failSaving = true
        #expect(!authorModel.removeSavedUser(person.id))
        #expect(author.groupStore.snapshot.contactDeletions.isEmpty)
        #expect(author.groupStore.snapshot.users.contains { $0.id == person.id })
        author.groupStore.failSaving = false
        authorModel.reloadSavedGroups()

        #expect(authorModel.removeSavedUser(person.id))
        #expect(authorModel.savedRemoteUsers.isEmpty)
        #expect(try authorModel.groupRepository.credential(for: pairID) == nil)
        #expect(keys.values.count == 1 && !keys.values.values.contains(oldSecret))
        #expect(!authorModel.handleContactReplyURL(reply))
        var older = author.groupStore.snapshot
        older.version = 19
        older.contactDeletionFormerPairs = []
        author.groupStore.snapshot = try GroupSnapshot.decode(older.encoded())
        let restarted = AppTestSupport.makeHarness(groups: [], groupStore: author.groupStore,
            credentialStore: keys, localMemberID: "reply-author", callAccessNow: { now })
        #expect(author.groupStore.snapshot.version == GroupSnapshot.currentVersion)
        #expect(restarted.viewModel.groupRepository.contactDeletionPublications.isEmpty)
        let notice = try #require(restarted.viewModel.groupRepository.contactDeletions.first)
        #expect(notice.target.expiresAt == now.timeIntervalSince1970 + 28 * 86_400)
        try notice.verify(
            from: "reply-author", senderKey: senderKey, recipient: recipient, pairSecret: oldSecret, now: now)
        #expect(throws: (any Error).self) {
            try notice.verify(from: "reply-author", senderKey: senderKey, recipient: recipient,
                              pairSecret: "replacement-key", now: now)
        }
        #expect(throws: (any Error).self) {
            try notice.verify(from: "reply-author", senderKey: senderKey, recipient: recipient,
                              pairSecret: oldSecret, now: now.addingTimeInterval(28 * 86_400))
        }
    }

    @Test func contactDeletionCommitsBeforeConfirmationAndCanBeAcknowledgedAfterReceiverRestart() throws {
        let ((author, friend), id) = try pair()
        let authorModel = author.viewModel, recipientModel = friend.viewModel
        defer { authorModel.disconnect(); recipientModel.disconnect() }
        let reply = try recipientModel.contactReplyURLForSharing(
            id, expectedAccountAccessID: recipientModel.accountAccessID)
        try authorModel.receiveContactReplyURL(reply)
        let bUser = try #require(recipientModel.savedRemoteUsers.first)
        let local = GroupMember(id: "reply-friend", displayName: "Friend")
        let remote = GroupMember(id: "reply-author", displayName: "Author")
        let regular = try IntercomGroup(name: "Riders", members: [local, remote])
        try recipientModel.groupRepository.save(
            recipientModel.groups + [regular], credential: .init(groupID: regular.id, secret: "regular-key"))
        recipientModel.reloadSavedGroups()
        let direct = try #require(recipientModel.existingDirectCall(for: bUser.id))
        recipientModel.selectGroup(direct)
        recipientModel.connectLocal()
        #expect(recipientModel.activeGroupID == direct.id)

        #expect(authorModel.removeSavedUser(try #require(authorModel.savedRemoteUsers.first).id))
        let sent = try #require(authorModel.groupRepository.contactDeletions.first)
        let notice = try JSONDecoder().decode(ContactDeletionNotice.self, from: JSONEncoder().encode(sent))
        #expect(throws: (any Error).self) {
            try recipientModel.receiveContactDeletion(notice, from: "wrong-device")
        }
        friend.groupStore.failSaving = true
        #expect(throws: (any Error).self) {
            try recipientModel.receiveContactDeletion(notice, from: "reply-author")
        }
        #expect(friend.groupStore.snapshot.users.map(\.id) == [bUser.id])
        #expect(friend.groupStore.snapshot.contactDeletionReceipts.isEmpty)
        #expect(recipientModel.activeGroupID == direct.id)
        friend.groupStore.failSaving = false
        recipientModel.disconnect()
        recipientModel.reloadSavedGroups()
        recipientModel.selectGroup(try #require(recipientModel.existingDirectCall(for: bUser.id)))
        recipientModel.connectLocal()
        #expect(recipientModel.activeGroupID == direct.id)

        let receipt = try recipientModel.receiveContactDeletion(notice, from: "reply-author")
        #expect(recipientModel.savedRemoteUsers.isEmpty)
        #expect(recipientModel.activeGroupID == nil)
        #expect(recipientModel.groups.map(\.id) == [regular.id])
        #expect(recipientModel.groups.first?.members.map(\.id) == ["reply-friend", "reply-author"])
        #expect(recipientModel.groupRepository.contactDeletions.isEmpty)
        #expect(recipientModel.contactInvitationRecord(id)?.state == .cancelled)

        try verifyDeletionAfterRestart(authorModel: authorModel, friend: friend, notice: notice, receipt: receipt)

    }

    private func verifyDeletionAfterRestart(
        authorModel: IntercomViewModel, friend: AppTestSupport.Harness,
        notice: ContactDeletionNotice, receipt: ContactDeletionReceipt
    ) throws {
        var old = friend.groupStore.snapshot
        old.version = 20
        friend.groupStore.snapshot = try GroupSnapshot.decode(old.encoded())
        let restarted = AppTestSupport.makeHarness(
            groups: [], groupStore: friend.groupStore, localMemberID: "reply-friend")
        #expect(friend.groupStore.snapshot.version == GroupSnapshot.currentVersion)
        #expect(restarted.viewModel.groupRepository.contactDeletionPublications.isEmpty)
        let saves = friend.groupStore.saveCount
        let repeated = try restarted.viewModel.receiveContactDeletion(notice, from: "reply-author")
        #expect(repeated == receipt)
        #expect(friend.groupStore.saveCount == saves)
        #expect(throws: (any Error).self) { try authorModel.acknowledgeContactDeletion(repeated, from: "wrong-device") }
        #expect(authorModel.groupRepository.contactDeletions == [notice])
        try authorModel.acknowledgeContactDeletion(repeated, from: "reply-friend")
        #expect(authorModel.groupRepository.contactDeletions.isEmpty)
    }

    @Test func delayedContactDeletionPreservesANewRegistration() throws {
        let ((author, friend), id) = try pair()
        let authorModel = author.viewModel, recipientModel = friend.viewModel
        defer { authorModel.disconnect(); recipientModel.disconnect() }
        try authorModel.receiveContactReplyURL(
            try recipientModel.contactReplyURLForSharing(
                id, expectedAccountAccessID: recipientModel.accountAccessID))
        #expect(authorModel.removeSavedUser(try #require(authorModel.savedRemoteUsers.first).id))
        let notice = try #require(authorModel.groupRepository.contactDeletions.first)
        let fresh = try #require(authorModel.makeContactInviteURL())
        try recipientModel.acceptContactInviteURL(fresh)
        let before = friend.groupStore.snapshot
        #expect(throws: (any Error).self) {
            try recipientModel.receiveContactDeletion(notice, from: "reply-author")
        }
        #expect(friend.groupStore.snapshot == before)
        #expect(recipientModel.savedRemoteUsers.map(\.memberIDs) == [["reply-author"]])
    }

    @Test func storedReplyAndConfirmationCompleteWithoutAnyTransport() throws {
        let ((authorHarness, recipientHarness), id) = try pair()
        defer { authorHarness.viewModel.disconnect(); recipientHarness.viewModel.disconnect() }
        let person = try #require(authorHarness.viewModel.directoryUsers.first).id
        authorHarness.viewModel.showContactPerson(person)
        let presentation = authorHarness.viewModel.contactInvitationPresentation
        let before = recipientHarness.groupStore.snapshot
        let reply = try recipientHarness.viewModel.contactReplyURLForSharing(
            id, expectedAccountAccessID: recipientHarness.viewModel.accountAccessID)
        #expect(recipientHarness.groupStore.snapshot == before, "Export does not claim delivery")
        try authorHarness.viewModel.receiveContactReplyURL(reply)
        #expect(authorHarness.viewModel.directoryUsers.map(\.id) == [person])
        #expect(authorHarness.viewModel.contactPerson(person)?.isRegistered == true)
        #expect(authorHarness.viewModel.contactPerson(person)?.localName == "My Friend")
        #expect(authorHarness.viewModel.contactInvitationPresentation == presentation)
        #expect(authorHarness.viewModel.pendingContactInvitations.isEmpty)
        let receiver = try #require(recipientHarness.viewModel.directoryUsers.first).id
        recipientHarness.viewModel.showContactPerson(receiver)
        let receiverPresentation = recipientHarness.viewModel.contactInvitationPresentation
        let confirmation = try authorHarness.viewModel.contactReplyURLForSharing(
            id, expectedAccountAccessID: authorHarness.viewModel.accountAccessID)
        try recipientHarness.viewModel.receiveContactReplyURL(confirmation)
        #expect(recipientHarness.viewModel.contactInvitationPresentation == receiverPresentation)
        #expect(recipientHarness.viewModel.contactInvitationRecord(id)?.state == .delivered)
        #expect(recipientHarness.viewModel.pendingContactInvitations.isEmpty)
        #expect(authorHarness.callSession.connectedGroup == nil && recipientHarness.callSession.connectedGroup == nil)
    }

}

extension ContactReplyTests {
    @Test(arguments: [false, true], [false, true])
    func anOlderGroupInvitationStaysBlockedAfterExplicitReadmission(selectSavedRider: Bool, legacyRemoval: Bool)
        throws {
        var now = Date()
        let author = AppTestSupport.makeHarness(groups: [], localMemberID: "group-inviter", callAccessNow: { now })
        let recipient = AppTestSupport.makeHarness(groups: [], localMemberID: "group-invitee", callAccessNow: { now })
        let other = AppTestSupport.makeHarness(groups: [], localMemberID: "other-invitee", callAccessNow: { now })
        let authorModel = author.viewModel, recipientModel = recipient.viewModel
        configureContactSessions([authorModel, recipientModel, other.viewModel])
        defer {
            for viewModel in [authorModel, recipientModel, other.viewModel] {
                viewModel.stopContactInvitationSession(); viewModel.disconnect()
            }
        }
        let groupID = UUID()
        #expect(authorModel.createTalkGroup(name: "Ready to ride", id: groupID))
        authorModel.disconnect()

        let memberID = try addInitialRider(authorModel: authorModel, recipientModel: recipientModel, groupID: groupID)
        let old = GroupInvitationDraft(name: "Earlier invitation", suggestedName: "Rider")
        let oldShare = try share(old, authorModel: authorModel, groupID: groupID)
        let delayedReply = try reply(to: oldShare, from: recipientModel)
        now.addTimeInterval(1)
        #expect(authorModel.removeMember(memberID, from: groupID))
        if legacyRemoval { try reopenLegacyRemoval(author: author, groupID: groupID) }
        let removed = author.groupStore.snapshot
        #expect(throws: (any Error).self) { try authorModel.receiveContactReplyURL(delayedReply) }
        #expect(author.groupStore.snapshot == removed)

        if selectSavedRider {
            let saved = try #require(authorModel.savedRemoteUsers.first { $0.memberIDs.contains(memberID) })
            #expect(authorModel.addSavedUsers([saved.id], to: groupID))
        } else {
            // The order of local saves remains meaningful if the clock moves back.
            now.addTimeInterval(legacyRemoval ? 1 : -2)
            let fresh = GroupInvitationDraft(name: "Invite the rider again", suggestedName: "Rider")
            try authorModel.receiveContactReplyURL(
                reply(to: share(fresh, authorModel: authorModel, groupID: groupID), from: recipientModel))
        }
        #expect(authorModel.groups.first { $0.id == groupID }?.members.contains { $0.id == memberID } == true)
        authorModel.disconnect()
        author.groupStore.snapshot = try GroupSnapshot.decode(author.groupStore.snapshot.encoded())
        authorModel.reloadSavedGroups()
        let beforeReplay = author.groupStore.snapshot
        let pair = IntercomGroup.directCallID(memberIDs: [authorModel.localMemberIdentity.memberID, memberID])
        let pairCredential = try #require(try authorModel.groupRepository.credential(for: pair))
        #expect(throws: (any Error).self) { try authorModel.receiveContactReplyURL(delayedReply) }
        #expect(author.groupStore.snapshot == beforeReplay)
        #expect(try authorModel.groupRepository.credential(for: pair) == pairCredential)

        // The exclusion applies to that rider, not to another recipient of the unaddressed link.
        try authorModel.receiveContactReplyURL(reply(to: oldShare, from: other.viewModel))
        #expect(
            authorModel.groups.first { $0.id == groupID }?.members.contains {
                $0.id == other.viewModel.localMemberIdentity.memberID
            } == true)
        #expect(try authorModel.groupRepository.credential(for: pair) == pairCredential)
        #expect(author.groupStore.snapshot.groups.first { $0.id == groupID }?.removedMembers == nil)
    }

    private func configureContactSessions(_ viewModels: [IntercomViewModel]) {
        for viewModel in viewModels {
            viewModel.contactSessionFactory = { RecordingCallSession() }
        }
    }

    private func addInitialRider(
        authorModel: IntercomViewModel, recipientModel: IntercomViewModel, groupID: UUID
    ) throws -> String {
        let first = GroupInvitationDraft(name: "Rider", suggestedName: "Rider")
        try authorModel.receiveContactReplyURL(
            reply(to: share(first, authorModel: authorModel, groupID: groupID), from: recipientModel))
        let memberID = recipientModel.localMemberIdentity.memberID
        #expect(authorModel.groups.first { $0.id == groupID }?.members.contains { $0.id == memberID } == true)
        return memberID
    }

    private func reopenLegacyRemoval(author: AppTestSupport.Harness, groupID: UUID) throws {
        var previous = author.groupStore.snapshot
        previous.version = 14
        let index = try #require(previous.groups.firstIndex { $0.id == groupID })
        previous.groups[index].removedMembers?[0].priorInvitationIDs = nil
        author.groupStore.snapshot = try GroupSnapshot.decode(previous.encoded())
        author.viewModel.reloadSavedGroups()
    }

    private func share(
        _ draft: GroupInvitationDraft, authorModel: IntercomViewModel, groupID: UUID
    ) throws -> (id: UUID, url: URL) {
        try #require(
            authorModel.saveGroupInvitations(
                groupID: groupID, creating: false, name: "", selected: [], newPeople: [draft]) == groupID)
        let share = try authorModel.prepareContactPersonShare(
            draft.id, expectedAccountAccessID: authorModel.accountAccessID)
        return (share.id, share.url)
    }

    private func reply(to share: (id: UUID, url: URL), from recipient: IntercomViewModel) throws -> URL {
        try recipient.acceptContactInviteURL(share.url)
        recipient.stopContactInvitationSession()
        return try recipient.contactReplyURLForSharing(share.id, expectedAccountAccessID: recipient.accountAccessID)
    }

}
