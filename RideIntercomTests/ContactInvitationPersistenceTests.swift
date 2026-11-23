import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct ContactInvitationPersistenceTests {
    @MainActor final class DiskStore: GroupStoring {
        private let directory: URL
        private let file: FileGroupStore
        var failSaving = false
        init() throws {
            directory = FileManager.default.temporaryDirectory.appendingPathComponent(
                "RideComContactTest-" + UUID().uuidString)
            file = FileGroupStore(directory: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try file.commit(GroupSnapshot())
        }
        deinit { try? FileManager.default.removeItem(at: directory) }
        func snapshot() throws -> GroupSnapshot {
            let stored = try file.read()
            return try #require(stored)
        }

        func installSnapshot(_ snapshot: GroupSnapshot) throws {
            try file.commit(snapshot)
        }
        func corruptSnapshot() throws {
            try Data("{".utf8).write(to: file.url)
        }

        func read() throws -> GroupSnapshot? { try file.read() }
        func commit(_ snapshot: GroupSnapshot) throws {
            if failSaving { throw IntercomGroupError.storageUnavailable }
            try file.commit(snapshot)
        }
        func lock() throws { try file.lock() }
        func unlock() { file.unlock() }
        func archive() throws { try file.archive() }
    }

    @MainActor final class Fixture {
        let memberID: String
        let store: DiskStore
        let credentials = InMemoryGroupCredentialStore()
        let account = AppTestSupport.signedInAccount()
        let authority = testInvitationAuthority()
        init(_ memberID: String) throws {
            self.memberID = memberID
            store = try DiskStore()
        }
        func make() -> (AppTestSupport.Harness, RecordingCallSession) {
            let harness = AppTestSupport.makeHarness(accountSession: account, groups: [],
                groupRepository: GroupRepository(store: store, credentials: credentials),
                credentialStore: credentials, invitationAuthority: authority, localMemberID: memberID)
            let contact = RecordingCallSession()
            harness.viewModel.contactSessionFactory = { contact }
            return (harness, contact)
        }
    }

    @Test func oneContactInvitationSurvivesRestartAndCommitsBothUsersWithoutOrdinaryGroups() throws {
        let author = try Fixture("persist-author"), friend = try Fixture("persist-friend")
        let (initialAuthor, _) = author.make()
        let url = try #require(initialAuthor.viewModel.makeContactInviteURL())
        let token = try GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true)
        let id = try #require(token.directInvitation).context.id
        #expect(initialAuthor.viewModel.savedRemoteUsers.isEmpty)
        #expect(initialAuthor.viewModel.groups.isEmpty)
        #expect(initialAuthor.viewModel.pendingContactInvitations.map(\.id) == [id])
        let manifest = try #require(String(bytes: author.store.snapshot().encoded(), encoding: .utf8))
        #expect(!manifest.contains(token.groupSecret))
        #expect(!manifest.contains(try #require(token.directInvitation).secret))
        #expect(!manifest.contains(url.absoluteString))
        initialAuthor.viewModel.stopContactInvitationSession()

        let (authorHarness, authorTransport) = author.make()
        #expect(authorHarness.viewModel.pendingContactInvitations.map(\.id) == [id])
        let (initialFriend, _) = friend.make()
        try initialFriend.viewModel.acceptContactInviteURL(url)
        #expect(initialFriend.viewModel.savedRemoteUsers.map(\.memberIDs) == [["persist-author"]])
        #expect(initialFriend.viewModel.regularGroups.isEmpty)
        initialFriend.viewModel.stopContactInvitationSession()
        let (friendHarness, friendTransport) = friend.make()
        #expect(friendHarness.viewModel.savedRemoteUsers.map(\.memberIDs) == [["persist-author"]])
        #expect(friendHarness.viewModel.pendingContactInvitations.map(\.id) == [id])
        #expect(authorHarness.viewModel.resumeContactInvitation(id))
        #expect(friendHarness.viewModel.resumeContactInvitation(id))
        defer {
            authorHarness.viewModel.stopContactInvitationSession()
            friendHarness.viewModel.stopContactInvitationSession()
        }
        try verifyReceiptRetryAndDelivery(
            id: id, authorHarness: authorHarness, friendHarness: friendHarness,
            authorTransport: authorTransport, friendTransport: friendTransport
        )
        authorHarness.viewModel.stopContactInvitationSession(); friendHarness.viewModel.stopContactInvitationSession()
        try verifyCompletedInvitationReload(author: author, friend: friend, id: id)
        #expect(authorHarness.callSession.connectedGroup == nil && friendHarness.callSession.connectedGroup == nil)
        #expect(authorTransport.startMediaCallCount == 0 && friendTransport.startMediaCallCount == 0)
    }

    private func verifyReceiptRetryAndDelivery(
        id: UUID,
        authorHarness: AppTestSupport.Harness,
        friendHarness: AppTestSupport.Harness,
        authorTransport: RecordingCallSession,
        friendTransport: RecordingCallSession
    ) throws {
        authorHarness.viewModel.showContactInvitation(id)
        friendHarness.viewModel.showContactInvitation(id)
        #expect(
            authorHarness.viewModel.contactInvitationPresentation != nil
                && friendHarness.viewModel.contactInvitationPresentation != nil)
        friendTransport.authenticate(["persist-author"])
        let receipt = try #require(friendTransport.sentApplicationDataMessages.last)
        authorTransport.authenticate(["persist-friend"])
        authorTransport.onEvent?(.receivedApplicationData(peerID: "persist-friend", message: receipt))
        #expect(authorHarness.viewModel.savedRemoteUsers.map(\.memberIDs) == [["persist-friend"]])
        #expect(
            authorHarness.viewModel.pendingContactInvitations.isEmpty,
            "A saved person is no longer a pending invitation")
        #expect(
            authorHarness.viewModel.contactInvitationPresentation == nil,
            "Registration closes the invitation detail")
        #expect(
            friendHarness.viewModel.pendingContactInvitations.map(\.id) == [id],
            "Without the ACK the reply still needs delivery")
        // The first ACK may be lost: closing the completed detail must retain the bounded listener.
        authorHarness.viewModel.dismissContactInvitationPresentation(expectedPresentationID: "share-" + id.uuidString)
        authorHarness.viewModel.contactInvitationSheetDidDisappear(id)
        let sentBeforeRetry = authorTransport.sentApplicationDataMessages.count
        authorTransport.onEvent?(.receivedApplicationData(peerID: "persist-friend", message: receipt))
        #expect(authorTransport.sentApplicationDataMessages.count == sentBeforeRetry + 1)
        let ack = try #require(authorTransport.sentApplicationDataMessages.last)
        friendTransport.onEvent?(.receivedApplicationData(peerID: "persist-author", message: ack))
        let savedRecipientID = try #require(friendHarness.viewModel.savedRemoteUsers.first?.id)
        #expect(
            friendHarness.viewModel.contactInvitationPresentation == .person(savedRecipientID),
            "Delivery updates the saved person's detail without closing it")
        #expect(friendHarness.viewModel.unlinkedContactInvitations.isEmpty)
        friendHarness.viewModel.dismissContactInvitationPresentation()
    }

    private func verifyCompletedInvitationReload(author: Fixture, friend: Fixture, id: UUID) throws {
        let (reloadedAuthor, _) = author.make(), (reloadedFriend, _) = friend.make()
        #expect(reloadedAuthor.viewModel.savedRemoteUsers.map(\.memberIDs) == [["persist-friend"]])
        #expect(reloadedFriend.viewModel.savedRemoteUsers.map(\.memberIDs) == [["persist-author"]])
        #expect(reloadedFriend.viewModel.pendingContactInvitations.isEmpty)
        #expect(
            reloadedAuthor.viewModel.pendingContactInvitations.isEmpty,
            "Restart does not resurrect a completed invitation row")
        reloadedAuthor.viewModel.showContactInvitation(id)
        #expect(reloadedAuthor.viewModel.contactInvitationPresentation == nil)
        #expect(reloadedAuthor.viewModel.groupRepository.contactInvitations.first { $0.id == id }?.state == .confirmed,
                "Keep the binding for duplicate receipts without presenting it as pending")
        #expect(reloadedAuthor.viewModel.regularGroups.isEmpty && reloadedFriend.viewModel.regularGroups.isEmpty)
        // The invitation alone completes the pair call: both sides already hold one
        // call key, so a nearby call needs no further exchange or Internet service.
        #expect(reloadedAuthor.viewModel.selectUser(try #require(reloadedAuthor.viewModel.savedRemoteUsers.first).id))
        #expect(reloadedFriend.viewModel.selectUser(try #require(reloadedFriend.viewModel.savedRemoteUsers.first).id))
        let call = try #require(reloadedAuthor.viewModel.selectedGroup?.id)
        #expect(reloadedFriend.viewModel.selectedGroup?.id == call)
        let key = try #require(try reloadedAuthor.viewModel.groupRepository.credential(for: call))
        #expect(try reloadedFriend.viewModel.groupRepository.credential(for: call) == key)
        let manifest = try #require(String(bytes: author.store.snapshot().encoded(), encoding: .utf8))
        #expect(!manifest.contains(key.secret))
    }

    @Test func failedAcceptanceCannotCommitAUserWithoutItsPendingNotification() throws {
        let author = try Fixture("atomic-author"), friend = try Fixture("atomic-friend")
        let (authorHarness, _) = author.make(), (friendHarness, _) = friend.make()
        defer {
            authorHarness.viewModel.stopContactInvitationSession()
            friendHarness.viewModel.stopContactInvitationSession()
        }
        let url = try #require(authorHarness.viewModel.makeContactInviteURL())
        friend.store.failSaving = true
        #expect(throws: (any Error).self) { try friendHarness.viewModel.acceptContactInviteURL(url) }
        #expect(try friend.store.snapshot().users.isEmpty)
        friend.store.failSaving = false
        let (reloaded, _) = friend.make()
        #expect(reloaded.viewModel.savedRemoteUsers.isEmpty)
        #expect(reloaded.viewModel.pendingContactInvitations.isEmpty)
    }

    @Test func schemaEightUpgradesAndOrdinarySnapshotUpdatesKeepPendingUntilReset() throws {
        let fixture = try Fixture("schema-author")
        var legacySnapshot = try fixture.store.snapshot()
        legacySnapshot.version = 8
        try fixture.store.installSnapshot(legacySnapshot)
        let (harness, _) = fixture.make()
        defer { harness.viewModel.stopContactInvitationSession() }
        #expect(try fixture.store.snapshot().version == GroupSnapshot.currentVersion)
        let url = try #require(harness.viewModel.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation)
            .context.id
        try harness.viewModel.groupRepository.save([])
        let (reloaded, _) = fixture.make()
        #expect(reloaded.viewModel.pendingContactInvitations.map(\.id) == [id])
        #expect(!fixture.credentials.values.isEmpty)
        try fixture.store.corruptSnapshot()
        try reloaded.viewModel.groupRepository.reset()
        #expect(reloaded.viewModel.pendingContactInvitations.isEmpty)
        #expect(fixture.credentials.values.isEmpty)
    }
    @Test func boundedNotificationAttemptStopsTransportAndKeepsDurableRetry() async throws {
        let fixture = try Fixture("bounded-author")
        let (harness, contact) = fixture.make()
        harness.viewModel.contactNotificationAttemptDuration = .milliseconds(20)
        defer { harness.viewModel.stopContactInvitationSession() }
        let url = try #require(harness.viewModel.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation)
            .context.id
        #expect(contact.connectedGroup != nil)
        await AppTestSupport.waitUntil(timeout: .seconds(1)) { contact.connectedGroup == nil }
        #expect(contact.connectedGroup == nil)
        #expect(harness.viewModel.pendingContactInvitations.map(\.id) == [id])
        #expect(harness.viewModel.resumeContactInvitation(id))
        #expect(contact.connectedGroup != nil)
        #expect(harness.callSession.connectedGroup == nil)
    }

    @Test func actualSchemaEightBytesDecodeWithoutContactFieldAndSchemaNineRequiresIt() throws {
        var old = GroupSnapshot()
        old.version = 8
        var json = try #require(JSONSerialization.jsonObject(with: old.encoded()) as? [String: Any])
        json.removeValue(forKey: "contactInvitations")
        let legacy = try GroupSnapshot.decode(JSONSerialization.data(withJSONObject: json))
        let upgraded = legacy.upgraded()
        #expect(upgraded.version == GroupSnapshot.currentVersion)
        #expect(upgraded.contactInvitations.isEmpty)
        json["version"] = 9
        #expect(throws: (any Error).self) { try GroupSnapshot.decode(JSONSerialization.data(withJSONObject: json)) }
    }
}

extension ContactInvitationPersistenceTests {
    @Test func cancelledInvitationCannotRecreateAnExplicitlyRemovedUser() throws {
        let author = try Fixture("cancel-author"), friend = try Fixture("cancel-friend")
        let (authorHarness, _) = author.make(), (friendHarness, _) = friend.make()
        defer {
            authorHarness.viewModel.stopContactInvitationSession()
            friendHarness.viewModel.stopContactInvitationSession()
        }
        let url = try #require(authorHarness.viewModel.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation)
            .context.id
        try friendHarness.viewModel.acceptContactInviteURL(url)
        let user = try #require(friendHarness.viewModel.savedRemoteUsers.first)
        let pairKey = try #require(
            friend.store.snapshot().groups.first(where: { $0.kind == .direct })?.credentialReference)
        #expect(friendHarness.viewModel.removeSavedUser(user.id))
        try friendHarness.viewModel.cancelContactInvitation(id)
        let (reloaded, _) = friend.make()
        #expect(!reloaded.viewModel.resumeContactInvitation(id))
        #expect(throws: (any Error).self) { try reloaded.viewModel.acceptContactInviteURL(url) }
        #expect(reloaded.viewModel.savedRemoteUsers.isEmpty)
        #expect(friend.credentials.values[pairKey] == nil)
        let former = try #require(reloaded.viewModel.groupRepository.contactDeletionFormerPairs.first)
        #expect(Set(friend.credentials.values.keys) == [former.keyReference])
        #expect(reloaded.viewModel.regularGroups.isEmpty)
    }

    @Test(arguments: [false, true])
    func deletingTheConfirmedContactRejectsLateRepliesAndAllowsAFreshInvitation(legacyDeletion: Bool) throws {
        let author = try Fixture("sender-cancel-author"), friend = try Fixture("sender-cancel-friend")
        let (authorHarness, transport) = author.make(), (friendHarness, friendTransport) = friend.make()
        defer {
            authorHarness.viewModel.stopContactInvitationSession()
            friendHarness.viewModel.stopContactInvitationSession()
        }
        let url = try #require(authorHarness.viewModel.makeContactInviteURL())
        let id = try #require(GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true).directInvitation)
            .context.id
        try friendHarness.viewModel.acceptContactInviteURL(url)
        friendTransport.authenticate(["sender-cancel-author"])
        let receipt = try #require(friendTransport.sentApplicationDataMessages.last)
        transport.authenticate(["sender-cancel-friend"])
        let handler = try #require(transport.onEvent)
        handler(.receivedApplicationData(peerID: "sender-cancel-friend", message: receipt))
        let saved = try #require(authorHarness.viewModel.savedRemoteUsers.first)
        let oldReply = try friendHarness.viewModel.contactReplyURLForSharing(
            id, expectedAccountAccessID: friendHarness.viewModel.accountAccessID)
        let checkpoint = try #require(authorHarness.viewModel.groupRepository.contactInvitations.first { $0.id == id })
        let pairKey = try #require(
            author.store.snapshot().groups.first(where: { $0.kind == .direct })?.credentialReference)
        #expect(checkpoint.state == .confirmed)
        if legacyDeletion {
            authorHarness.viewModel.stopContactInvitationSession()
            // Earlier builds removed the user and pair call, but left this confirmed checkpoint.
            var snapshot = try author.store.snapshot()
            snapshot.users = []
            snapshot.groups = []
            try author.store.installSnapshot(snapshot)
        } else {
            #expect(authorHarness.viewModel.removeSavedUser(saved.id))
            let sent = transport.sentApplicationDataMessages.count
            handler(.receivedApplicationData(peerID: "sender-cancel-friend", message: receipt))
            #expect(transport.sentApplicationDataMessages.count == sent)
            #expect(transport.connectedGroup == nil)
            #expect(!authorHarness.viewModel.handleContactReplyURL(oldReply))
        }
        let (reloaded, _) = author.make()
        defer { reloaded.viewModel.stopContactInvitationSession() }
        #expect(reloaded.viewModel.groupRepository.contactInvitations.first { $0.id == id }?.state == .cancelled)
        #expect(!reloaded.viewModel.resumeContactInvitation(id))
        #expect(!reloaded.viewModel.handleContactReplyURL(oldReply))
        #expect(reloaded.viewModel.savedRemoteUsers.isEmpty)
        #expect(author.credentials.values[pairKey] == nil)
        let references = reloaded.viewModel.groupRepository.contactDeletionFormerPairs.map(\.keyReference)
        #expect(Set(author.credentials.values.keys) == Set(references))
        #expect(references.count == (legacyDeletion ? 0 : 1))
        #expect(reloaded.viewModel.regularGroups.isEmpty)

        try verifyFreshInvitationAfterDeletion(
            from: reloaded.viewModel, to: friendHarness.viewModel, oldID: id, oldReply: oldReply)
    }

    private func verifyFreshInvitationAfterDeletion(
        from authorModel: IntercomViewModel, to friendModel: IntercomViewModel, oldID: UUID, oldReply: URL
    ) throws {
        let freshURL = try #require(authorModel.makeContactInviteURL())
        let freshID = try #require(
            GroupInviteTokenCodec.decodeJoinURL(freshURL, contactBootstrap: true).directInvitation
        ).context.id
        #expect(freshID != oldID)
        try friendModel.acceptContactInviteURL(freshURL)
        let freshReply = try friendModel.contactReplyURLForSharing(
            freshID, expectedAccountAccessID: friendModel.accountAccessID)
        try authorModel.receiveContactReplyURL(freshReply)
        #expect(authorModel.savedRemoteUsers.map(\.memberIDs) == [["sender-cancel-friend"]])
        #expect(!authorModel.handleContactReplyURL(oldReply))
    }
}
