import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

extension GroupContactInvitationTests {
    @Test func deletingTheGroupCancelsItsInvitationWithoutDeletingTheSavedName() throws {
        let fixture = try prepared()
        let authorHarness = fixture.author, recipientHarness = fixture.recipient
        let token = fixture.token
        let person = fixture.personID
        defer { authorHarness.viewModel.disconnect(); recipientHarness.viewModel.disconnect() }
        let target = try #require(token.invitedGroup), id = try #require(token.directInvitation?.context.id)
        let shownInvitation = try #require(authorHarness.viewModel.contactInvitationRecord(id))
        #expect(authorHarness.viewModel.personForGroupInvitation(shownInvitation)?.id == person)
        try recipientHarness.viewModel.acceptContactInviteURL(
            GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true))
        let reply = try recipientHarness.viewModel.contactReplyURLForSharing(
            id, expectedAccountAccessID: recipientHarness.viewModel.accountAccessID)
        authorHarness.viewModel.deleteGroup(target.id)
        #expect(authorHarness.viewModel.contactInvitationRecord(id)?.state == .cancelled)
        #expect(authorHarness.viewModel.personForGroupInvitation(shownInvitation) == nil)
        let before = authorHarness.groupStore.snapshot
        #expect(throws: (any Error).self) { try authorHarness.viewModel.receiveContactReplyURL(reply) }
        #expect(authorHarness.groupStore.snapshot == before)
        #expect(authorHarness.viewModel.contactPerson(person)?.resolvedDisplayName == "My new rider")
        #expect(authorHarness.viewModel.savedRemoteUsers.isEmpty)
    }

    @Test(arguments: [false, true])
    func removingAnExpiredGroupInvitationKeepsThePersonWithoutRenewingTheGroup(wholeGroup: Bool) throws {
        var now = Date()
        let fixture = try prepared(now: { now })
        let authorHarness = fixture.author, recipientHarness = fixture.recipient
        let token = fixture.token
        let person = fixture.personID
        let authorModel = authorHarness.viewModel
        defer { authorModel.disconnect(); recipientHarness.viewModel.disconnect() }
        let target = try #require(token.invitedGroup)
        let context = try #require(token.directInvitation?.context)
        now = Date(timeIntervalSince1970: context.expiresAt)
        try authorModel.groupRepository.removeExpiredContactInvitations(now: now.timeIntervalSince1970)
        let expired = try #require(authorModel.contactInvitationRecord(context.id))
        try #require(expired.state == .expired)

        if wholeGroup {
            #expect(authorModel.deleteGroup(target.id))
        } else {
            #expect(authorModel.removeMember(expired.pendingGroupMemberID, from: target.id))
        }
        #expect(authorModel.contactInvitationRecord(context.id)?.state == .cancelled)

        // Simulate an older build that removed the target but left the expired record renewable.
        var oldSnapshot = authorHarness.groupStore.snapshot
        oldSnapshot.contactInvitations.removeAll { $0.id == expired.id }
        oldSnapshot.contactInvitations.append(expired)
        try authorHarness.groupStore.commit(oldSnapshot)
        authorModel.reloadSavedGroups()
        #expect(authorModel.contactInvitationRecord(context.id)?.state == .cancelled)
        #expect(authorModel.contactPerson(person)?.resolvedDisplayName == "My new rider")
        #expect(authorModel.contactPersonInvitationForSharing(person) == nil)

        let share = try authorModel.prepareContactPersonShare(
            person, expectedAccountAccessID: authorModel.accountAccessID)
        let replacement = try GroupInviteTokenCodec.decodeJoinURL(share.url, contactBootstrap: true)
        #expect(replacement.invitedGroup == nil)
        #expect(authorModel.contactInvitationRecord(share.id)?.personID == person)
        #expect(
            authorModel.groups.first(where: { $0.id == target.id })?.members.map(\.id)
                == (wholeGroup ? nil : ["group-author"]))
    }

    @Test(arguments: [false, true])
    func sharingAnExpiredInvitationWithItsGroupSlotIntactRenewsTheSamePersonAndGroup(cleanedUp: Bool) throws {
        var now = Date()
        let fixture = try prepared(now: { now })
        let authorHarness = fixture.author, recipientHarness = fixture.recipient
        let token = fixture.token
        let person = fixture.personID
        let authorModel = authorHarness.viewModel
        defer { authorModel.disconnect(); recipientHarness.viewModel.disconnect() }
        let target = try #require(token.invitedGroup)
        let id = try #require(token.directInvitation?.context.id)
        let initial = try #require(authorModel.contactInvitationRecord(id))
        now = Date(timeIntervalSince1970: initial.expiresAt - 0.001)
        let stillValid = try authorModel.prepareContactPersonShare(
            person, expectedAccountAccessID: authorModel.accountAccessID)
        #expect(stillValid.id == id)

        now = Date(timeIntervalSince1970: initial.expiresAt)
        if cleanedUp {
            try authorModel.groupRepository.removeExpiredContactInvitations(now: now.timeIntervalSince1970)
            authorModel.reloadSavedGroups()
        }
        #expect(authorModel.contactPersonInvitationForSharing(person)?.state == (cleanedUp ? .expired : .pending))

        let renewed = try authorModel.prepareContactPersonShare(
            person, expectedAccountAccessID: authorModel.accountAccessID)
        let replacement = try GroupInviteTokenCodec.decodeJoinURL(renewed.url, contactBootstrap: true)
        let record = try #require(authorModel.contactInvitationRecord(renewed.id))
        #expect(renewed.id != id && authorModel.contactInvitationRecord(id) == nil)
        #expect(record.personID == person && record.sent == false)
        #expect(replacement.invitedGroup == target)
        #expect(authorModel.personForGroupInvitation(initial) == nil)
        #expect(authorModel.personForGroupInvitation(record)?.id == person)
        #expect(
            authorModel.groups.first(where: { $0.id == target.id })?.members.map(\.id) == [
                "group-author", record.pendingGroupMemberID
            ])
    }

    @Test func deletingAReceivedGroupStopsItsReplyAndKeepsTheRegisteredContactAndPairCall() throws {
        let keys = InMemoryGroupCredentialStore()
        let fixture = try prepared(recipientCredentials: keys)
        let authorHarness = fixture.author, recipientHarness = fixture.recipient
        let token = fixture.token
        defer { authorHarness.viewModel.disconnect(); recipientHarness.viewModel.disconnect() }
        let target = try #require(token.invitedGroup), id = try #require(token.directInvitation?.context.id)
        let url = try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
        try recipientHarness.viewModel.acceptContactInviteURL(url)
        let person = try #require(recipientHarness.viewModel.savedRemoteUsers.first)
        let pair = try #require(recipientHarness.viewModel.groups.first(where: { $0.kind == .direct }))
        let pairKey = try recipientHarness.viewModel.groupRepository.credential(for: pair.id)
        let replyKey = try #require(recipientHarness.viewModel.contactInvitationRecord(id)?.credentialReference)
        #expect(recipientHarness.viewModel.contactInvitationID == id && keys.values[replyKey] != nil)
        let saved = recipientHarness.groupStore.snapshot
        recipientHarness.groupStore.failSaving = true
        recipientHarness.viewModel.deleteGroup(target.id)
        #expect(recipientHarness.groupStore.snapshot == saved && keys.values[replyKey] != nil)
        #expect(recipientHarness.viewModel.contactInvitationID == id)
        recipientHarness.groupStore.failSaving = false; recipientHarness.viewModel.reloadSavedGroups()
        #expect(recipientHarness.viewModel.resumeContactInvitation(id))
        recipientHarness.viewModel.deleteGroup(target.id)
        #expect(recipientHarness.viewModel.contactInvitationRecord(id)?.state == .cancelled)
        #expect(recipientHarness.viewModel.contactInvitationRecord(id)?.credentialReference == nil)
        #expect(recipientHarness.viewModel.contactInvitationID == nil && keys.values[replyKey] == nil)
        #expect(recipientHarness.viewModel.savedRemoteUsers == [person])
        #expect(recipientHarness.viewModel.groups.contains { $0.id == pair.id })
        #expect(try recipientHarness.viewModel.groupRepository.credential(for: pair.id) == pairKey)
        recipientHarness.viewModel.reloadSavedGroups()
        let after = recipientHarness.groupStore.snapshot
        #expect(throws: (any Error).self) { try recipientHarness.viewModel.acceptContactInviteURL(url) }
        #expect(
            recipientHarness.groupStore.snapshot == after
                && !recipientHarness.viewModel.groups.contains { $0.id == target.id })
        #expect(
            !recipientHarness.viewModel.canShareContactReply(
                try #require(recipientHarness.viewModel.contactInvitationRecord(id))))
    }

    @Test func loadingAnOldReceivedReplyWithoutItsGroupCancelsItWithoutChangingACurrentCall() throws {
        let keys = InMemoryGroupCredentialStore()
        let fixture = try prepared(recipientCredentials: keys)
        let authorHarness = fixture.author, recipientHarness = fixture.recipient
        let token = fixture.token
        defer { authorHarness.viewModel.disconnect(); recipientHarness.viewModel.disconnect() }
        let target = try #require(token.invitedGroup), id = try #require(token.directInvitation?.context.id)
        let url = try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
        try recipientHarness.viewModel.acceptContactInviteURL(url)
        let replyKey = try #require(recipientHarness.viewModel.contactInvitationRecord(id)?.credentialReference)
        recipientHarness.viewModel.stopContactInvitationSession()
        // Previously saved by the old deletion path.
        recipientHarness.groupStore.snapshot.groups.removeAll { $0.id == target.id }
        let orphaned = recipientHarness.groupStore.snapshot
        recipientHarness.groupStore.failSaving = true
        recipientHarness.viewModel.reloadSavedGroups()
        #expect(recipientHarness.groupStore.snapshot == orphaned && keys.values[replyKey] != nil)
        recipientHarness.groupStore.failSaving = false
        recipientHarness.viewModel.reloadSavedGroups()
        #expect(recipientHarness.viewModel.contactInvitationRecord(id)?.state == .cancelled)
        #expect(
            recipientHarness.viewModel.contactInvitationRecord(id)?.credentialReference == nil
                && keys.values[replyKey] == nil)
        recipientHarness.viewModel.setSoundIsolationEnabled(false)
        #expect(recipientHarness.viewModel.createTalkGroup(name: "Unrelated call"))
        let current = recipientHarness.viewModel.currentCallReference
        #expect(throws: (any Error).self) { try recipientHarness.viewModel.acceptContactInviteURL(url) }
        #expect(recipientHarness.viewModel.currentCallReference == current)
        #expect(recipientHarness.viewModel.savedRemoteUsers.count == 1)
    }

    @Test func cancellationReleasesTheGroupSlotAndKeepsThePerson() throws {
        let fixture = try prepared()
        let authorHarness = fixture.author, recipientHarness = fixture.recipient
        let token = fixture.token
        let person = fixture.personID
        defer { authorHarness.viewModel.disconnect(); recipientHarness.viewModel.disconnect() }
        let target = try #require(token.invitedGroup), id = try #require(token.directInvitation?.context.id)
        try authorHarness.viewModel.cancelContactInvitation(id)
        #expect(
            authorHarness.viewModel.groups.first(where: { $0.id == target.id })?.members.map(\.id) == [
                "group-author"
            ])
        #expect(authorHarness.viewModel.contactPerson(person) != nil)
    }

    @Test func acceptingTheGroupKeepsAnExistingCallAndRejectsAConflictingKey() throws {
        let fixture = try prepared()
        let authorHarness = fixture.author, recipientHarness = fixture.recipient
        let token = fixture.token
        defer { authorHarness.viewModel.disconnect(); recipientHarness.viewModel.disconnect() }
        recipientHarness.viewModel.setSoundIsolationEnabled(false)
        #expect(recipientHarness.viewModel.createTalkGroup(name: "Current conversation"))
        let current = recipientHarness.viewModel.currentCallReference
        let url = try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
        try recipientHarness.viewModel.acceptContactInviteURL(url)
        #expect(recipientHarness.viewModel.currentCallReference == current)
        let target = try #require(token.invitedGroup)
        let conflictingHarness = AppTestSupport.makeHarness(groups: [], localMemberID: "conflicting-recipient")
        defer { conflictingHarness.viewModel.disconnect() }
        let existing = try IntercomGroup(
            id: target.id, name: "Existing", members: [.init(id: "conflicting-recipient", displayName: "You")])
        try conflictingHarness.viewModel.groupRepository.save(
            [existing], credential: .init(groupID: target.id, secret: "different-key"))
        conflictingHarness.viewModel.reloadSavedGroups()
        let before = conflictingHarness.groupStore.snapshot
        #expect(throws: (any Error).self) { try conflictingHarness.viewModel.acceptContactInviteURL(url) }
        #expect(
            conflictingHarness.groupStore.snapshot == before
                && conflictingHarness.viewModel.savedRemoteUsers.isEmpty)
    }

    @Test func aFreshInvitationAfterExpiryKeepsItsPersonAndTargetGroup() throws {
        var now = Date()
        let fixture = try prepared(now: { now })
        let authorHarness = fixture.author, recipientHarness = fixture.recipient
        let token = fixture.token
        let person = fixture.personID
        defer { authorHarness.viewModel.disconnect(); recipientHarness.viewModel.disconnect() }
        now = now.addingTimeInterval(8 * 24 * 60 * 60)
        let share = try authorHarness.viewModel.prepareContactPersonShare(
            person, expectedAccountAccessID: authorHarness.viewModel.accountAccessID)
        let fresh = try GroupInviteTokenCodec.decodeJoinURL(share.url, contactBootstrap: true)
        #expect(fresh.invitedGroup == token.invitedGroup)
        #expect(fresh.directInvitation?.context.id != token.directInvitation?.context.id)
        #expect(
            authorHarness.viewModel.groupInvitationPeople(try #require(token.invitedGroup).id).map(\.id) == [
                person
            ])
        #expect(authorHarness.viewModel.groups.first(where: { $0.id == token.invitedGroup?.id })?.members.count == 2)
        let pending = try #require(authorHarness.viewModel.contactInvitationRecord(share.id))
        #expect(authorHarness.viewModel.contactInvitationIsUnsent(pending))
        let repeated = try authorHarness.viewModel.prepareContactPersonShare(
            person, expectedAccountAccessID: authorHarness.viewModel.accountAccessID)
        #expect(repeated.id == share.id && repeated.url == share.url)
        authorHarness.viewModel.completeContactInvitationSharing(share)
        #expect(authorHarness.viewModel.contactInvitationRecord(share.id)?.sent == true)
        try recipientHarness.viewModel.acceptContactInviteURL(share.url)
        #expect(recipientHarness.viewModel.groups.contains { $0.id == token.invitedGroup?.id })
    }
}
