import CryptoKit
import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct GroupContactInvitationTests {
    @Test func anUnsignedGroupAttachmentCannotBeAddedToAContactInvitation() throws {
        let token = try ContactInvitationSession.makeToken(authority: testInvitationAuthority(), signer: testIdentitySigner("group-author"),
            displayName: "Author", now: Date().timeIntervalSince1970)
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(token)) as? [String: Any])
        fields["invitedGroup"] = ["id": UUID().uuidString, "name": "Forged group", "secret": "forged-secret"]
        let data = try JSONSerialization.data(withJSONObject: fields)
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let url = try #require(URL(string: "rideintercom://contact?token=" + encoded))
        #expect(throws: (any Error).self) { try GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true) }
    }
    @Test func aCombinedInvitationBindsTheGroupWithoutPuttingItsKeyInTheReceipt() throws {
        let author = testIdentitySigner("group-author"), recipient = testIdentitySigner("group-recipient")
        let authority = testInvitationAuthority(), now = Date().timeIntervalSince1970
        let group = ContactGroupInvitation(id: UUID(), name: "Mountain riders", secret: "group-only-key")
        let token = try ContactInvitationSession.makeToken(authority: authority, signer: author, displayName: "Author", now: now, invitedGroup: group)
        let url = try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
        let decoded = try GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true)
        #expect(decoded.invitedGroup == group)
        #expect(decoded.groupID != group.id && decoded.groupSecret != group.secret)
        let accepted = try decoded.accept(signer: recipient, displayName: "Recipient", now: now, contactBootstrap: true)
        #expect(try authority.verify(accepted.receipt, now: now) != nil)
        #expect(accepted.receipt.invitation?.invitedGroupID == group.id)
        #expect(accepted.receipt.invitation?.invitedGroupDigest == (try group.digest()))
        #expect(!String(decoding: try JSONEncoder().encode(accepted.receipt), as: UTF8.self).contains(group.secret))
        var changed = accepted.receipt
        changed.invitation?.invitedGroupID = UUID()
        #expect(try authority.verify(changed, now: now) == nil)
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        fields["invitedGroup"] = ["id": group.id.uuidString, "name": group.name, "secret": "replaced-key"]
        let tampered = try JSONDecoder().decode(GroupInviteToken.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(throws: (any Error).self) { try tampered.validate(contactBootstrap: true) }
        #expect(!tampered.verifySignature())
    }

    private func prepared(recipientCredentials: GroupCredentialStoring? = nil, now: @escaping @MainActor () -> Date = Date.init) throws -> (AppTestSupport.Harness, AppTestSupport.Harness, GroupInviteToken, UUID) {
        let author = AppTestSupport.makeHarness(groups: [], localMemberID: "group-author", callAccessNow: now)
        let recipient = AppTestSupport.makeHarness(groups: [], credentialStore: recipientCredentials, localMemberID: "group-recipient", callAccessNow: now)
        author.viewModel.contactSessionFactory = { RecordingCallSession() }; recipient.viewModel.contactSessionFactory = { RecordingCallSession() }
        #expect(author.viewModel.createTalkGroup(name: "Mountain riders"))
        author.viewModel.disconnect()
        let group = try #require(author.viewModel.groups.first), person = UUID()
        try author.viewModel.groupRepository.saveContactPerson(person, name: "My new rider")
        author.viewModel.reloadSavedGroups()
        let credential = try #require(try author.viewModel.groupRepository.credential(for: group.id))
        let token = try ContactInvitationSession.makeToken(authority: author.viewModel.invitationAuthority,
            signer: author.viewModel.internetSettingsStore.invitationSigner(memberID: "group-author"), displayName: "Author", now: now().timeIntervalSince1970,
            invitedGroup: .init(id: group.id, name: group.name, secret: credential.secret))
        try author.viewModel.groupRepository.stageContactInvitation(token, now: now().timeIntervalSince1970, personID: person)
        author.viewModel.reloadSavedGroups()
        return (author, recipient, token, person)
    }

    @Test func registrationAndGroupJoinCompleteTogetherAndTheReplyFillsOnlyItsSlot() throws {
        let (a, b, token, person) = try prepared()
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        let target = try #require(token.invitedGroup), id = try #require(token.directInvitation?.context.id)
        #expect(a.viewModel.groups.first(where: { $0.id == target.id })?.members.count == 2)
        let url = try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
        try b.viewModel.acceptContactInviteURL(url)
        #expect(b.viewModel.savedRemoteUsers.count == 1)
        #expect(b.viewModel.groups.contains { $0.id == target.id && $0.kind == .group })
        #expect(try b.viewModel.groupRepository.credential(for: target.id)?.secret == target.secret)
        let reply = try b.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: b.viewModel.accountAccessID)
        try a.viewModel.receiveContactReplyURL(reply)
        #expect(a.viewModel.savedRemoteUsers.first?.id == person)
        #expect(a.viewModel.savedRemoteUsers.first?.resolvedDisplayName == "My new rider")
        #expect(a.viewModel.groups.first(where: { $0.id == target.id })?.members.map(\.id) == ["group-author", "group-recipient"])
        let direct = try #require(b.viewModel.groups.first(where: { $0.kind == .direct }))
        #expect(try b.viewModel.groupRepository.credential(for: direct.id)?.secret != target.secret)
        #expect(try a.viewModel.groupRepository.credential(for: direct.id) == b.viewModel.groupRepository.credential(for: direct.id))
        let before = b.groupStore.snapshot
        try b.viewModel.acceptContactInviteURL(url)
        #expect(b.groupStore.snapshot == before)
        let ack = try a.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: a.viewModel.accountAccessID)
        try b.viewModel.receiveContactReplyURL(ack)
        #expect(b.viewModel.contactInvitationRecord(id)?.state == .delivered)
        #expect(b.viewModel.groups.contains { $0.id == target.id })
        #expect(a.viewModel.activeGroupID == nil && b.viewModel.activeGroupID == nil)
    }

    @Test func failedRegistrationDoesNotLeaveOnlyAContactOrOnlyAGroup() throws {
        let (a, b, token, _) = try prepared()
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        let before = b.groupStore.snapshot, url = try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
        b.groupStore.failSaving = true
        #expect(throws: (any Error).self) { try b.viewModel.acceptContactInviteURL(url) }
        #expect(b.groupStore.snapshot == before)
        b.groupStore.failSaving = false
        b.viewModel.reloadSavedGroups()
        try b.viewModel.acceptContactInviteURL(url)
        #expect(b.viewModel.savedRemoteUsers.count == 1)
        #expect(b.viewModel.groups.contains { $0.id == token.invitedGroup?.id })
    }

    @Test func deletingTheGroupCancelsItsInvitationWithoutDeletingTheSavedName() throws {
        let (a, b, token, person) = try prepared()
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        let target = try #require(token.invitedGroup), id = try #require(token.directInvitation?.context.id)
        try b.viewModel.acceptContactInviteURL(GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true))
        let reply = try b.viewModel.contactReplyURLForSharing(id, expectedAccountAccessID: b.viewModel.accountAccessID)
        a.viewModel.deleteGroup(target.id)
        #expect(a.viewModel.contactInvitationRecord(id)?.state == .cancelled)
        let before = a.groupStore.snapshot
        #expect(throws: (any Error).self) { try a.viewModel.receiveContactReplyURL(reply) }
        #expect(a.groupStore.snapshot == before)
        #expect(a.viewModel.contactPerson(person)?.resolvedDisplayName == "My new rider")
        #expect(a.viewModel.savedRemoteUsers.isEmpty)
    }

    @Test func deletingAReceivedGroupStopsItsReplyAndKeepsTheRegisteredContactAndPairCall() throws {
        let keys = InMemoryGroupCredentialStore()
        let (a, b, token, _) = try prepared(recipientCredentials: keys)
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        let target = try #require(token.invitedGroup), id = try #require(token.directInvitation?.context.id)
        let url = try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
        try b.viewModel.acceptContactInviteURL(url)
        let person = try #require(b.viewModel.savedRemoteUsers.first)
        let pair = try #require(b.viewModel.groups.first(where: { $0.kind == .direct }))
        let pairKey = try b.viewModel.groupRepository.credential(for: pair.id)
        let replyKey = try #require(b.viewModel.contactInvitationRecord(id)?.credentialReference)
        #expect(b.viewModel.contactInvitationID == id && keys.values[replyKey] != nil)
        let saved = b.groupStore.snapshot
        b.groupStore.failSaving = true
        b.viewModel.deleteGroup(target.id)
        #expect(b.groupStore.snapshot == saved && keys.values[replyKey] != nil)
        #expect(b.viewModel.contactInvitationID == id)
        b.groupStore.failSaving = false; b.viewModel.reloadSavedGroups()
        #expect(b.viewModel.resumeContactInvitation(id))
        b.viewModel.deleteGroup(target.id)
        #expect(b.viewModel.contactInvitationRecord(id)?.state == .cancelled)
        #expect(b.viewModel.contactInvitationRecord(id)?.credentialReference == nil)
        #expect(b.viewModel.contactInvitationID == nil && keys.values[replyKey] == nil)
        #expect(b.viewModel.savedRemoteUsers == [person])
        #expect(b.viewModel.groups.contains { $0.id == pair.id })
        #expect(try b.viewModel.groupRepository.credential(for: pair.id) == pairKey)
        b.viewModel.reloadSavedGroups()
        let after = b.groupStore.snapshot
        #expect(throws: (any Error).self) { try b.viewModel.acceptContactInviteURL(url) }
        #expect(b.groupStore.snapshot == after && !b.viewModel.groups.contains { $0.id == target.id })
        #expect(!b.viewModel.canShareContactReply(try #require(b.viewModel.contactInvitationRecord(id))))
    }

    @Test func loadingAnOldReceivedReplyWithoutItsGroupCancelsItWithoutChangingACurrentCall() throws {
        let keys = InMemoryGroupCredentialStore()
        let (a, b, token, _) = try prepared(recipientCredentials: keys)
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        let target = try #require(token.invitedGroup), id = try #require(token.directInvitation?.context.id)
        let url = try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
        try b.viewModel.acceptContactInviteURL(url)
        let replyKey = try #require(b.viewModel.contactInvitationRecord(id)?.credentialReference)
        b.viewModel.stopContactInvitationSession()
        b.groupStore.snapshot.groups.removeAll { $0.id == target.id } // Previously saved by the old deletion path.
        let orphaned = b.groupStore.snapshot
        b.groupStore.failSaving = true
        b.viewModel.reloadSavedGroups()
        #expect(b.groupStore.snapshot == orphaned && keys.values[replyKey] != nil)
        b.groupStore.failSaving = false
        b.viewModel.reloadSavedGroups()
        #expect(b.viewModel.contactInvitationRecord(id)?.state == .cancelled)
        #expect(b.viewModel.contactInvitationRecord(id)?.credentialReference == nil && keys.values[replyKey] == nil)
        b.viewModel.setSoundIsolationEnabled(false)
        #expect(b.viewModel.createTalkGroup(name: "Unrelated call"))
        let current = b.viewModel.currentCallReference
        #expect(throws: (any Error).self) { try b.viewModel.acceptContactInviteURL(url) }
        #expect(b.viewModel.currentCallReference == current)
        #expect(b.viewModel.savedRemoteUsers.count == 1)
    }

    @Test func cancellationReleasesTheGroupSlotAndKeepsThePerson() throws {
        let (a, b, token, person) = try prepared()
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        let target = try #require(token.invitedGroup), id = try #require(token.directInvitation?.context.id)
        try a.viewModel.cancelContactInvitation(id)
        #expect(a.viewModel.groups.first(where: { $0.id == target.id })?.members.map(\.id) == ["group-author"])
        #expect(a.viewModel.contactPerson(person) != nil)
    }

    @Test func acceptingTheGroupKeepsAnExistingCallAndRejectsAConflictingKey() throws {
        let (a, b, token, _) = try prepared()
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        b.viewModel.setSoundIsolationEnabled(false)
        #expect(b.viewModel.createTalkGroup(name: "Current conversation"))
        let current = b.viewModel.currentCallReference
        let url = try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
        try b.viewModel.acceptContactInviteURL(url)
        #expect(b.viewModel.currentCallReference == current)
        let target = try #require(token.invitedGroup)
        let c = AppTestSupport.makeHarness(groups: [], localMemberID: "conflicting-recipient")
        defer { c.viewModel.disconnect() }
        let existing = try IntercomGroup(id: target.id, name: "Existing", members: [.init(id: "conflicting-recipient", displayName: "You")])
        try c.viewModel.groupRepository.save([existing], credential: .init(groupID: target.id, secret: "different-key"))
        c.viewModel.reloadSavedGroups()
        let before = c.groupStore.snapshot
        #expect(throws: (any Error).self) { try c.viewModel.acceptContactInviteURL(url) }
        #expect(c.groupStore.snapshot == before && c.viewModel.savedRemoteUsers.isEmpty)
    }

    @Test func multipleNewPeopleAndTheGroupSaveTogetherAndRetryDoesNotDuplicateThem() throws {
        let h = AppTestSupport.makeHarness(groups: [], localMemberID: "batch-author")
        defer { h.viewModel.disconnect() }
        h.viewModel.setSoundIsolationEnabled(false)
        var selection = MemberSelection(viewModel: h.viewModel, groupID: nil)
        selection.typedName = "Snow friends"
        selection.addNewPerson(); selection.newPeople[0].name = "First rider"
        selection.addNewPerson(); selection.newPeople[1].name = "Second rider"
        let before = h.groupStore.snapshot
        #expect(selection.memberCount == 3 && selection.canSave)
        #expect(h.groupStore.snapshot == before)
        h.groupStore.failSaving = true
        #expect(selection.save() == nil)
        #expect(h.groupStore.snapshot == before)
        h.groupStore.failSaving = false; h.viewModel.reloadSavedGroups()
        #expect(selection.save() == .some(.some(selection.newGroupID)))
        #expect(h.viewModel.groups.first?.members.count == 3)
        #expect(h.viewModel.directoryUsers.count == 2 && h.viewModel.savedRemoteUsers.isEmpty)
        #expect(h.groupStore.snapshot.contactInvitations.count == 2)
        let saved = h.groupStore.snapshot, reference = h.viewModel.currentCallReference
        #expect(selection.canSave && selection.memberCount == 3)
        #expect(selection.save() == .some(.some(selection.newGroupID)))
        #expect(h.groupStore.snapshot == saved && h.viewModel.currentCallReference == reference)
    }

    @Test func addingANewPersonKeepsTheCurrentCallAndGroupKey() throws {
        let h = AppTestSupport.makeHarness(groups: [], localMemberID: "adding-author")
        defer { h.viewModel.disconnect() }
        h.viewModel.setSoundIsolationEnabled(false)
        #expect(h.viewModel.createTalkGroup(name: "Ongoing"))
        let group = try #require(h.viewModel.groups.first), reference = h.viewModel.currentCallReference
        let key = try h.viewModel.groupRepository.credential(for: group.id)
        var selection = MemberSelection(viewModel: h.viewModel, groupID: group.id)
        selection.addNewPerson()
        #expect(selection.canSave && selection.memberCount == 2)
        #expect(selection.save() == .some(.some(group.id)))
        #expect(h.viewModel.currentCallReference == reference)
        #expect(try h.viewModel.groupRepository.credential(for: group.id) == key)
        #expect(h.viewModel.directoryUsers.count == 1)
    }

    @Test func aFreshInvitationAfterExpiryKeepsItsPersonAndTargetGroup() throws {
        var now = Date()
        let (a, b, token, person) = try prepared(now: { now })
        defer { a.viewModel.disconnect(); b.viewModel.disconnect() }
        now = now.addingTimeInterval(8 * 24 * 60 * 60)
        let share = try a.viewModel.prepareContactPersonShare(person, expectedAccountAccessID: a.viewModel.accountAccessID)
        let fresh = try GroupInviteTokenCodec.decodeJoinURL(share.url, contactBootstrap: true)
        #expect(fresh.invitedGroup == token.invitedGroup)
        #expect(fresh.directInvitation?.context.id != token.directInvitation?.context.id)
        #expect(a.viewModel.groupInvitationPeople(try #require(token.invitedGroup).id).map(\.id) == [person])
        #expect(a.viewModel.groups.first(where: { $0.id == token.invitedGroup?.id })?.members.count == 2)
        let pending = try #require(a.viewModel.contactInvitationRecord(share.id))
        #expect(a.viewModel.contactInvitationIsUnsent(pending))
        let repeated = try a.viewModel.prepareContactPersonShare(person, expectedAccountAccessID: a.viewModel.accountAccessID)
        #expect(repeated.id == share.id && repeated.url == share.url)
        a.viewModel.completeContactInvitationSharing(share)
        #expect(a.viewModel.contactInvitationRecord(share.id)?.sent == true)
        try b.viewModel.acceptContactInviteURL(share.url)
        #expect(b.viewModel.groups.contains { $0.id == token.invitedGroup?.id })
    }

    @Test func aMixedSelectionAndRenamedPendingPersonKeepTheSameSavedState() throws {
        let h = try AppTestSupport.makeHarnessWithSavedUser()
        defer { h.viewModel.disconnect() }
        h.viewModel.setSoundIsolationEnabled(false)
        let known = try #require(h.viewModel.savedRemoteUsers.first)
        var selection = MemberSelection(viewModel: h.viewModel, groupID: nil)
        selection.selected = [known.id]; selection.addNewPerson()
        #expect(selection.memberCount == 3)
        #expect(selection.save() == .some(.some(selection.newGroupID)))
        let saved = h.groupStore.snapshot
        #expect(selection.memberCount == 3 && selection.canSave)
        #expect(selection.save() == .some(.some(selection.newGroupID)))
        #expect(h.groupStore.snapshot == saved)
        let person = selection.newPeople[0].id
        #expect(h.viewModel.renameSavedUser(person, displayName: "Renamed new rider"))
        #expect(h.groupStore.snapshot.contactInvitations.first(where: { $0.personID == person })?.nickname == "Renamed new rider")
        #expect(h.viewModel.groups.first(where: { $0.id == selection.newGroupID })?.members.first(where: { $0.id.hasPrefix(GroupMember.pendingInvitePrefix) })?.resolvedDisplayName == "Renamed new rider")
    }

}
