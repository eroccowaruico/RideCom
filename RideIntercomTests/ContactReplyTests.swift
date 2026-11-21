import CoreTransferable
import Foundation
import RTC
import UniformTypeIdentifiers
import Testing
@testable import RideIntercom

@MainActor
struct ContactReplyTests {
    private func pair(
        now: @escaping @MainActor () -> Date = Date.init,
        authorCredentials: GroupCredentialStoring? = nil,
        friendCredentials: GroupCredentialStoring? = nil
    ) throws -> (AppTestSupport.Harness, AppTestSupport.Harness, UUID) {
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
        return (author, friend, id)
    }

    @Test func independentlyRemovedContactsConfirmBothDeletionsAfterRestart() throws {
        let aKeys = InMemoryGroupCredentialStore(), bKeys = InMemoryGroupCredentialStore()
        let (author, friend, id) = try pair(authorCredentials: aKeys, friendCredentials: bKeys)
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
        let (author, friend, id) = try pair()
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
        let (author, friend, id) = try pair(now: { now }, authorCredentials: keys)
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
        let (author, friend, id) = try pair()
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
        let (author, friend, id) = try pair()
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
        let (authorHarness, recipientHarness, id) = try pair()
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

    @Test(arguments: [false, true], [false, true])
    func anOlderGroupInvitationStaysBlockedAfterExplicitReadmission(selectSavedRider: Bool, legacyRemoval: Bool)
        throws {
        var now = Date()
        let author = AppTestSupport.makeHarness(groups: [], localMemberID: "group-inviter", callAccessNow: { now })
        let recipient = AppTestSupport.makeHarness(groups: [], localMemberID: "group-invitee", callAccessNow: { now })
        let other = AppTestSupport.makeHarness(groups: [], localMemberID: "other-invitee", callAccessNow: { now })
        let authorModel = author.viewModel, recipientModel = recipient.viewModel
        for viewModel in [authorModel, recipientModel, other.viewModel] {
            viewModel.contactSessionFactory = { RecordingCallSession() }
        }
        defer {
            for viewModel in [authorModel, recipientModel, other.viewModel] {
                viewModel.stopContactInvitationSession(); viewModel.disconnect()
            }
        }
        let groupID = UUID()
        #expect(authorModel.createTalkGroup(name: "Ready to ride", id: groupID))
        authorModel.disconnect()

        func share(_ draft: GroupInvitationDraft) throws -> (id: UUID, url: URL) {
            try #require(
                authorModel.saveGroupInvitations(
                    groupID: groupID, creating: false, name: "", selected: [], newPeople: [draft]) == groupID)
            let share = try authorModel.prepareContactPersonShare(
                draft.id, expectedAccountAccessID: authorModel.accountAccessID)
            return (share.id, share.url)
        }
        func reply(to share: (id: UUID, url: URL), from recipient: IntercomViewModel) throws -> URL {
            try recipient.acceptContactInviteURL(share.url)
            recipient.stopContactInvitationSession()
            return try recipient.contactReplyURLForSharing(share.id, expectedAccountAccessID: recipient.accountAccessID)
        }

        let first = GroupInvitationDraft(name: "Rider", suggestedName: "Rider")
        try authorModel.receiveContactReplyURL(reply(to: share(first), from: recipientModel))
        let memberID = recipientModel.localMemberIdentity.memberID
        #expect(authorModel.groups.first { $0.id == groupID }?.members.contains { $0.id == memberID } == true)
        let old = GroupInvitationDraft(name: "Earlier invitation", suggestedName: "Rider")
        let oldShare = try share(old)
        let delayedReply = try reply(to: oldShare, from: recipientModel)
        now.addTimeInterval(1)
        #expect(authorModel.removeMember(memberID, from: groupID))
        if legacyRemoval {
            var previous = author.groupStore.snapshot
            previous.version = 14
            let index = try #require(previous.groups.firstIndex { $0.id == groupID })
            previous.groups[index].removedMembers?[0].priorInvitationIDs = nil
            author.groupStore.snapshot = try GroupSnapshot.decode(previous.encoded())
            authorModel.reloadSavedGroups()
        }
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
            try authorModel.receiveContactReplyURL(reply(to: share(fresh), from: recipientModel))
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

    @Test func duplicateRepliesAndConfirmationsAreIdempotentAndContainNoInviteSecrets() throws {
        let (authorHarness, recipientHarness, id) = try pair()
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
        let (authorHarness, recipientHarness, id) = try pair()
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
        let (authorHarness, recipientHarness, id) = try pair()
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
        let (authorHarness, recipientHarness, id) = try pair()
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
        let (authorHarness, recipientHarness, id) = try pair()
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
        let (authorHarness, recipientHarness, id) = try pair(now: { now })
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
        let (_, recipientHarness, id) = try pair()
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

    @Test func onlyManuallyReceivedRepliesOfferTheStandardReturnConfirmation() throws {
        let (authorHarness, recipientHarness, id) = try pair()
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
        let (_, recipientHarness, id) = try pair()
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
        let (_, recipientHarness, id) = try pair()
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
        let (authorHarness, recipientHarness, id) = try pair()
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
        let (_, recipientHarness, id) = try pair()
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
        let (authorHarness, recipientHarness, id) = try pair(now: { now })
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

    private func reopenLegacyPending(_ harness: AppTestSupport.Harness, id: UUID, personWasDeleted: Bool = false) throws
        -> URL {
        let url = try GroupInviteTokenCodec.joinURL(
            for: harness.viewModel.groupRepository.contactInvitationPayload(id).token, contactBootstrap: true)
        var old = harness.groupStore.snapshot
        old.version = 9
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
        let (_, recipientHarness, id) = try pair()
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
        let (_, recipientHarness, id) = try pair()
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
        let (_, recipientHarness, id) = try pair()
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
        let (_, recipientHarness, id) = try pair()
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
        let (_, recipientHarness, id) = try pair()
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
