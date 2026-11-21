import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct DirectCallTests {
    @Test func foregroundRestoresOnePendingReplyWithoutStartingAnotherCall() throws {
        let group = try IntercomGroup(name: "Riders", members: [.init(id: "alice", displayName: "Alice")],
                                      accessSecret: "foreground-reply-fixture")
        let author = AppTestSupport.makeHarness(groups: [group], localMemberID: "alice")
        let recipient = AppTestSupport.makeHarness(groups: [], localMemberID: "bob")
        defer { recipient.viewModel.stopOrdinaryGroupReplyExchanges(); recipient.viewModel.disconnect() }
        recipient.viewModel.allowsNearbyGroupDelivery = true
        var windows = 0
        var expire: (@MainActor () -> Void)?
        recipient.viewModel.beginOrdinaryGroupReplyBackgroundTime = { callback in
            windows += 1
            expire = callback
            return nil
        }
        let url = try #require(author.viewModel.makeGroupInviteURL(for: group.id))
        try recipient.viewModel.acceptInviteURL(url)
        let activeGroupID = recipient.viewModel.activeGroupID
        let disconnects = recipient.callSession.disconnectCallCount
        let mediaStarts = recipient.callSession.startMediaCallCount
        let expireFirstWindow = try #require(expire)
        expireFirstWindow()
        #expect(recipient.viewModel.ordinaryGroupReplyExchanges.isEmpty)

        let owner = AppCallOwner(account: recipient.viewModel.accountSession, viewModel: recipient.viewModel)
        owner.systemSurfaceIsForeground = true
        #expect(recipient.viewModel.ordinaryGroupReplyExchanges[.invitee(group.id)] != nil)
        #expect(recipient.viewModel.activeGroupID == activeGroupID)
        #expect(recipient.callSession.disconnectCallCount == disconnects)
        #expect(recipient.callSession.startMediaCallCount == mediaStarts)
        owner.systemSurfaceIsForeground = false
        owner.systemSurfaceIsForeground = true
        #expect(windows == 2)
    }

    @Test func foregroundRestoresBothPendingRepliesIndependently() throws {
        let members = [GroupMember(id: "alice", displayName: "Alice")]
        let first = try IntercomGroup(name: "First", members: members, accessSecret: "foreground-first-reply")
        let second = try IntercomGroup(name: "Second", members: members, accessSecret: "foreground-second-reply")
        let author = AppTestSupport.makeHarness(groups: [first, second], localMemberID: "alice")
        let recipient = AppTestSupport.makeHarness(groups: [], localMemberID: "bob")
        defer { recipient.viewModel.stopOrdinaryGroupReplyExchanges(); recipient.viewModel.disconnect() }
        recipient.viewModel.allowsNearbyGroupDelivery = false
        for group in [first, second] {
            let url = try #require(author.viewModel.makeGroupInviteURL(for: group.id))
            try recipient.viewModel.acceptInviteURL(url)
            let saved = recipient.viewModel.groupRepository.pendingInvitation(for: group.id) != nil
            try #require(saved)
        }

        let owner = AppCallOwner(account: recipient.viewModel.accountSession, viewModel: recipient.viewModel)
        recipient.viewModel.allowsNearbyGroupDelivery = true
        owner.systemSurfaceIsForeground = true
        #expect(recipient.viewModel.ordinaryGroupReplyExchanges.count == 2)
        let active = try #require(recipient.viewModel.ordinaryGroupReplyExchanges[.invitee(first.id)])
        #expect(recipient.viewModel.ordinaryGroupReplyExchanges[.invitee(second.id)] != nil)

        try #require(recipient.viewModel.deleteGroup(second.id))
        #expect(recipient.viewModel.ordinaryGroupReplyExchanges.count == 1)
        owner.systemSurfaceIsForeground = false
        owner.systemSurfaceIsForeground = true
        #expect(recipient.viewModel.ordinaryGroupReplyExchanges[.invitee(first.id)] === active)
    }

    @Test func removingTheSourceGroupReleasesBothKindsOfOrdinaryReplyWindowImmediately() throws {
        let group = try IntercomGroup(name: "Riders", members: [.init(id: "alice", displayName: "Alice")],
                                      accessSecret: "reply-window-fixture")
        let author = AppTestSupport.makeHarness(groups: [group], localMemberID: "alice")
        let recipient = AppTestSupport.makeHarness(groups: [], localMemberID: "bob")
        defer {
            author.viewModel.stopOrdinaryGroupReplyExchanges(); recipient.viewModel.stopOrdinaryGroupReplyExchanges()
            author.viewModel.disconnect(); recipient.viewModel.disconnect()
        }
        author.viewModel.allowsNearbyGroupDelivery = true
        recipient.viewModel.allowsNearbyGroupDelivery = true
        var authorReleases = 0, recipientReleases = 0
        author.viewModel.beginOrdinaryGroupReplyBackgroundTime = { _ in { authorReleases += 1 } }
        recipient.viewModel.beginOrdinaryGroupReplyBackgroundTime = { _ in { recipientReleases += 1 } }
        let url = try #require(author.viewModel.makeGroupInviteURL(for: group.id))
        try recipient.viewModel.acceptInviteURL(url)
        try #require(!author.viewModel.ordinaryGroupReplyExchanges.isEmpty)
        try #require(recipient.viewModel.ordinaryGroupReplyExchanges[.invitee(group.id)] != nil)

        #expect(author.viewModel.renameGroup(group.id, to: "New name"))
        #expect(authorReleases == 0)
        #expect(author.viewModel.deleteGroup(group.id))
        #expect(recipient.viewModel.deleteGroup(group.id))
        #expect(author.viewModel.ordinaryGroupReplyExchanges.isEmpty)
        #expect(recipient.viewModel.ordinaryGroupReplyExchanges.isEmpty)
        #expect(authorReleases == 1)
        #expect(recipientReleases == 1)
    }

    @Test func deletingAnInviterCancelsTheirPendingReplyWhileKeepingTheGroupCall() throws {
        let group = try IntercomGroup(name: "Riders", members: [.init(id: "alice", displayName: "Alice")],
                                      accessSecret: "recipient-reply-fixture")
        let author = AppTestSupport.makeHarness(groups: [group], localMemberID: "alice")
        let recipient = AppTestSupport.makeHarness(groups: [], localMemberID: "bob")
        defer { recipient.viewModel.stopOrdinaryGroupReplyExchanges(); recipient.viewModel.disconnect() }
        recipient.viewModel.allowsNearbyGroupDelivery = true
        var releases = 0
        recipient.viewModel.beginOrdinaryGroupReplyBackgroundTime = { _ in { releases += 1 } }
        let url = try #require(author.viewModel.makeGroupInviteURL(for: group.id))
        try recipient.viewModel.acceptInviteURL(url)
        let alice = try #require(recipient.viewModel.savedRemoteUsers.first)
        try #require(recipient.viewModel.ordinaryGroupReplyExchanges[.invitee(group.id)] != nil)

        try #require(recipient.viewModel.removeSavedUser(alice.id))
        #expect(recipient.viewModel.activeGroupID == group.id)
        #expect(recipient.viewModel.regularGroups.map(\.id) == [group.id])
        let remainsPending = recipient.groupStore.snapshot.groups.first?.pendingInvitation != nil
        #expect(!remainsPending)
        #expect(recipient.viewModel.ordinaryGroupReplyExchanges.isEmpty)
        #expect(releases == 1)

        try recipient.viewModel.acceptInviteURL(url)
        #expect(recipient.viewModel.savedRemoteUsers.isEmpty)
        let pendingAfterReopening = recipient.viewModel.groupRepository.pendingInvitation(for: group.id) != nil
        #expect(!pendingAfterReopening)
        #expect(recipient.viewModel.ordinaryGroupReplyExchanges.isEmpty)
    }

    @Test func issuedOrdinaryGroupInvitationsSurviveReloadOnlyWithTheirOriginalGroupKeys() throws {
        let storage = try GroupStorageFixture()
        defer { storage.remove() }
        let group = try storage.group()
        let otherGroup = try storage.group()
        try storage.repository.save(
            [group, otherGroup], credential: .init(groupID: group.id, secret: "original-fixture"))
        try storage.repository.save(
            [group, otherGroup], credential: .init(groupID: otherGroup.id, secret: "other-fixture"))
        let app = AppTestSupport.makeHarness(groups: [], groupRepository: storage.repository, localMemberID: "local")
        defer { app.viewModel.disconnect() }
        let firstURL = try #require(app.viewModel.makeGroupInviteURL(for: group.id))
        let firstToken = try GroupInviteTokenCodec.decodeJoinURL(firstURL)
        let first = try #require(firstToken.directInvitation).context
        let secondURL = try #require(app.viewModel.makeGroupInviteURL(for: group.id))
        let secondToken = try GroupInviteTokenCodec.decodeJoinURL(secondURL)
        let second = try #require(secondToken.directInvitation).context
        #expect(first.id != second.id)
        let otherURL = try #require(app.viewModel.makeGroupInviteURL(for: otherGroup.id))
        let otherToken = try GroupInviteTokenCodec.decodeJoinURL(otherURL)
        let other = try #require(otherToken.directInvitation).context
        let reopened = storage.restart()
        _ = try reopened.load(localMemberID: "local")
        let now = Date().timeIntervalSince1970
        #expect(reopened.issuedOrdinaryGroupInvitations(now: now).map(\.id) == [first.id, second.id, other.id])
        #expect(
            reopened.issuedOrdinaryGroupInvitations(now: max(first.expiresAt, second.expiresAt, other.expiresAt))
                .isEmpty)

        try reopened.save([group, otherGroup], credential: .init(groupID: group.id, secret: "replacement-fixture"))
        #expect(reopened.issuedOrdinaryGroupInvitations(now: now).map(\.id) == [other.id])
        let updated = AppTestSupport.makeHarness(groups: [], groupRepository: reopened, localMemberID: "local")
        defer { updated.viewModel.disconnect() }
        _ = try #require(updated.viewModel.makeGroupInviteURL(for: group.id))
        try reopened.delete(group.id, remaining: [otherGroup])
        #expect(try storage.file.read()?.issuedOrdinaryGroupInvitations.map(\.invitation.id) == [other.id])
    }

    @Test func groupInvitationCapacityKeepsPreviouslyIssuedLinksUntilExpiry() throws {
        let storage = try GroupStorageFixture()
        defer { storage.remove() }
        let group = try storage.group()
        try storage.repository.save([group], credential: .init(groupID: group.id, secret: "capacity-group-fixture"))
        let now = Date().timeIntervalSince1970
        let signer = testIdentitySigner("local")
        let existing = (0..<GroupSnapshot.maximumIssuedOrdinaryGroupInvitations).map {
            DirectInvitationContext(groupID: group.id, inviterMemberID: "local", inviterDeviceKey: signer.publicKey,
                                    expiresAt: now + ($0 == 0 ? 5 : 30))
        }
        for invitation in existing {
            try storage.repository.rememberIssuedOrdinaryGroupInvitation(invitation, now: now)
        }
        let new = DirectInvitationContext(
            groupID: group.id, inviterMemberID: "local", inviterDeviceKey: signer.publicKey, expiresAt: now + 30)
        #expect(throws: GroupInviteTokenError.activeOrdinaryGroupInvitationLimit) {
            try storage.repository.rememberIssuedOrdinaryGroupInvitation(new, now: now)
        }
        #expect(storage.repository.issuedOrdinaryGroupInvitations(now: now).map(\.id) == existing.map(\.id))
        try storage.repository.rememberIssuedOrdinaryGroupInvitation(new, now: now + 5)
        #expect(
            storage.repository.issuedOrdinaryGroupInvitations(now: now + 5).map(\.id) == Array(
                existing.dropFirst()
            ).map(\.id) + [new.id])
    }

    @Test func ordinaryTwoMemberGroupRemainsAGroup() throws {
        let group = try IntercomGroup(name: "Two Riders", members: [
            .init(id: "alice", displayName: "Alice"),
            .init(id: "bob", displayName: "Bob")
        ], accessSecret: "group-key")
        let testHarness = AppTestSupport.makeHarness(groups: [group], localMemberID: "alice")
        defer { testHarness.viewModel.disconnect() }
        #expect(group.kind == .group)
        #expect(testHarness.viewModel.regularGroups.map(\.id) == [group.id])
        #expect(testHarness.viewModel.activeDirectCall == nil)
    }

}
