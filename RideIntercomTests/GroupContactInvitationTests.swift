import CryptoKit
import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct GroupContactInvitationTests {
    @Test func anUnsignedGroupAttachmentCannotBeAddedToAContactInvitation() throws {
        let token = try ContactInvitationSession.makeToken(
            authority: testInvitationAuthority(), signer: testIdentitySigner("group-author"),
            displayName: "Author", now: Date().timeIntervalSince1970)
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(token)) as? [String: Any])
        fields["invitedGroup"] = ["id": UUID().uuidString, "name": "Forged group", "secret": "forged-secret"]
        let data = try JSONSerialization.data(withJSONObject: fields)
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
            of: "/", with: "_"
        ).replacingOccurrences(of: "=", with: "")
        let url = try #require(URL(string: "rideintercom://contact?token=" + encoded))
        #expect(throws: (any Error).self) { try GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true) }
    }
    @Test func aCombinedInvitationBindsTheGroupWithoutPuttingItsKeyInTheReceipt() throws {
        let author = testIdentitySigner("group-author"), recipient = testIdentitySigner("group-recipient")
        let authority = testInvitationAuthority(), now = Date().timeIntervalSince1970
        let group = ContactGroupInvitation(id: UUID(), name: "Mountain riders", secret: "group-only-key")
        let token = try ContactInvitationSession.makeToken(
            authority: authority, signer: author, displayName: "Author", now: now, invitedGroup: group)
        let url = try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
        let decoded = try GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true)
        #expect(decoded.invitedGroup == group)
        #expect(decoded.groupID != group.id && decoded.groupSecret != group.secret)
        let accepted = try decoded.accept(signer: recipient, displayName: "Recipient", now: now, contactBootstrap: true)
        #expect(try authority.verify(accepted.receipt, now: now) != nil)
        #expect(accepted.receipt.invitation?.invitedGroupID == group.id)
        #expect(accepted.receipt.invitation?.invitedGroupDigest == (try group.digest()))
        let receiptBytes = try JSONEncoder().encode(accepted.receipt)
        let receiptText = try #require(String(bytes: receiptBytes, encoding: .utf8))
        #expect(!receiptText.contains(group.secret))
        var changed = accepted.receipt
        changed.invitation?.invitedGroupID = UUID()
        #expect(try authority.verify(changed, now: now) == nil)
        var fields = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded)) as? [String: Any])
        fields["invitedGroup"] = ["id": group.id.uuidString, "name": group.name, "secret": "replaced-key"]
        let tampered = try JSONDecoder().decode(
            GroupInviteToken.self, from: JSONSerialization.data(withJSONObject: fields))
        #expect(throws: (any Error).self) { try tampered.validate(contactBootstrap: true) }
        #expect(!tampered.verifySignature())
    }

    struct PreparedInvitation {
        let author: AppTestSupport.Harness
        let recipient: AppTestSupport.Harness
        let token: GroupInviteToken
        let personID: UUID
    }

    func prepared(
        recipientCredentials: GroupCredentialStoring? = nil, now: @escaping @MainActor () -> Date = Date.init
    ) throws -> PreparedInvitation {
        let author = AppTestSupport.makeHarness(groups: [], localMemberID: "group-author", callAccessNow: now)
        let recipient = AppTestSupport.makeHarness(
            groups: [], credentialStore: recipientCredentials, localMemberID: "group-recipient", callAccessNow: now
        )
        author.viewModel.contactSessionFactory = { RecordingCallSession() }
        recipient.viewModel.contactSessionFactory = { RecordingCallSession() }
        #expect(author.viewModel.createTalkGroup(name: "Mountain riders"))
        author.viewModel.disconnect()
        let group = try #require(author.viewModel.groups.first), person = UUID()
        try author.viewModel.groupRepository.saveContactPerson(person, name: "My new rider")
        author.viewModel.reloadSavedGroups()
        let credential = try #require(try author.viewModel.groupRepository.credential(for: group.id))
        let token = try ContactInvitationSession.makeToken(authority: author.viewModel.invitationAuthority,
            signer: author.viewModel.internetSettingsStore.invitationSigner(memberID: "group-author"),
            displayName: "Author", now: now().timeIntervalSince1970,
            invitedGroup: .init(id: group.id, name: group.name, secret: credential.secret))
        try author.viewModel.groupRepository.stageContactInvitation(
            token, now: now().timeIntervalSince1970, personID: person)
        author.viewModel.reloadSavedGroups()
        return PreparedInvitation(author: author, recipient: recipient, token: token, personID: person)
    }

    @Test func registrationAndGroupJoinCompleteTogetherAndTheReplyFillsOnlyItsSlot() throws {
        let fixture = try prepared()
        let authorHarness = fixture.author, recipientHarness = fixture.recipient
        let token = fixture.token
        let person = fixture.personID
        defer { authorHarness.viewModel.disconnect(); recipientHarness.viewModel.disconnect() }
        let target = try #require(token.invitedGroup), id = try #require(token.directInvitation?.context.id)
        #expect(authorHarness.viewModel.groups.first(where: { $0.id == target.id })?.members.count == 2)
        let beforeReply = authorHarness.viewModel.groupInvitationPeople(target.id)
        #expect(beforeReply.map(\.id) == [person])
        #expect(beforeReply.first?.person.isRegistered == false)
        let url = try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
        try recipientHarness.viewModel.acceptContactInviteURL(url)
        #expect(recipientHarness.viewModel.savedRemoteUsers.count == 1)
        #expect(recipientHarness.viewModel.groups.contains { $0.id == target.id && $0.kind == .group })
        #expect(try recipientHarness.viewModel.groupRepository.credential(for: target.id)?.secret == target.secret)
        let reply = try recipientHarness.viewModel.contactReplyURLForSharing(
            id, expectedAccountAccessID: recipientHarness.viewModel.accountAccessID)
        try authorHarness.viewModel.receiveContactReplyURL(reply)
        #expect(authorHarness.viewModel.savedRemoteUsers.first?.id == person)
        #expect(authorHarness.viewModel.savedRemoteUsers.first?.resolvedDisplayName == "My new rider")
        let afterReply = authorHarness.viewModel.groupInvitationPeople(target.id, including: [person])
        #expect(afterReply.map(\.id) == [person])
        #expect(afterReply.first?.person.isRegistered == true)
        #expect(
            authorHarness.viewModel.groups.first(where: { $0.id == target.id })?.members.map(\.id) == [
                "group-author", "group-recipient"
            ])
        let direct = try #require(recipientHarness.viewModel.groups.first(where: { $0.kind == .direct }))
        #expect(try recipientHarness.viewModel.groupRepository.credential(for: direct.id)?.secret != target.secret)
        #expect(
            try authorHarness.viewModel.groupRepository.credential(for: direct.id)
                == recipientHarness.viewModel.groupRepository.credential(for: direct.id))
        let before = recipientHarness.groupStore.snapshot
        try recipientHarness.viewModel.acceptContactInviteURL(url)
        #expect(recipientHarness.groupStore.snapshot == before)
        let ack = try authorHarness.viewModel.contactReplyURLForSharing(
            id, expectedAccountAccessID: authorHarness.viewModel.accountAccessID)
        try recipientHarness.viewModel.receiveContactReplyURL(ack)
        #expect(recipientHarness.viewModel.contactInvitationRecord(id)?.state == .delivered)
        #expect(recipientHarness.viewModel.groups.contains { $0.id == target.id })
        #expect(authorHarness.viewModel.activeGroupID == nil && recipientHarness.viewModel.activeGroupID == nil)
    }

    @Test func failedRegistrationDoesNotLeaveOnlyAContactOrOnlyAGroup() throws {
        let fixture = try prepared()
        let authorHarness = fixture.author, recipientHarness = fixture.recipient
        let token = fixture.token
        defer { authorHarness.viewModel.disconnect(); recipientHarness.viewModel.disconnect() }
        let before = recipientHarness.groupStore.snapshot,
            url = try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: true)
        recipientHarness.groupStore.failSaving = true
        #expect(throws: (any Error).self) { try recipientHarness.viewModel.acceptContactInviteURL(url) }
        #expect(recipientHarness.groupStore.snapshot == before)
        recipientHarness.groupStore.failSaving = false
        recipientHarness.viewModel.reloadSavedGroups()
        try recipientHarness.viewModel.acceptContactInviteURL(url)
        #expect(recipientHarness.viewModel.savedRemoteUsers.count == 1)
        #expect(recipientHarness.viewModel.groups.contains { $0.id == token.invitedGroup?.id })
    }

    @Test func multipleNewPeopleAndTheGroupSaveTogetherAndRetryDoesNotDuplicateThem() throws {
        let harness = AppTestSupport.makeHarness(groups: [], localMemberID: "batch-author")
        defer { harness.viewModel.disconnect() }
        harness.viewModel.setSoundIsolationEnabled(false)
        var selection = MemberSelection(viewModel: harness.viewModel, groupID: nil)
        selection.typedName = "Snow friends"
        selection.addNewPerson(); selection.newPeople[0].name = "First rider"
        selection.addNewPerson(); selection.newPeople[1].name = "Second rider"
        let before = harness.groupStore.snapshot
        #expect(selection.memberCount == 3 && selection.canSave)
        #expect(harness.groupStore.snapshot == before)
        harness.groupStore.failSaving = true
        #expect(selection.save() == nil)
        #expect(harness.groupStore.snapshot == before)
        harness.groupStore.failSaving = false; harness.viewModel.reloadSavedGroups()
        #expect(selection.save() == .some(.some(selection.newGroupID)))
        #expect(harness.viewModel.groups.first?.members.count == 3)
        #expect(harness.viewModel.directoryUsers.count == 2 && harness.viewModel.savedRemoteUsers.isEmpty)
        #expect(harness.groupStore.snapshot.contactInvitations.count == 2)
        let saved = harness.groupStore.snapshot, reference = harness.viewModel.currentCallReference
        #expect(selection.canSave && selection.memberCount == 3)
        #expect(selection.save() == .some(.some(selection.newGroupID)))
        #expect(harness.groupStore.snapshot == saved && harness.viewModel.currentCallReference == reference)
    }

    @Test func addingANewPersonKeepsTheCurrentCallAndGroupKey() throws {
        let harness = AppTestSupport.makeHarness(groups: [], localMemberID: "adding-author")
        defer { harness.viewModel.disconnect() }
        harness.viewModel.setSoundIsolationEnabled(false)
        #expect(harness.viewModel.createTalkGroup(name: "Ongoing"))
        let group = try #require(harness.viewModel.groups.first), reference = harness.viewModel.currentCallReference
        let key = try harness.viewModel.groupRepository.credential(for: group.id)
        var selection = MemberSelection(viewModel: harness.viewModel, groupID: group.id)
        selection.addNewPerson()
        #expect(selection.canSave && selection.memberCount == 2)
        #expect(selection.save() == .some(.some(group.id)))
        #expect(harness.viewModel.currentCallReference == reference)
        #expect(try harness.viewModel.groupRepository.credential(for: group.id) == key)
        #expect(harness.viewModel.directoryUsers.count == 1)
    }

    @Test func aMixedSelectionAndRenamedPendingPersonKeepTheSameSavedState() throws {
        let harness = try AppTestSupport.makeHarnessWithSavedUser()
        defer { harness.viewModel.disconnect() }
        harness.viewModel.setSoundIsolationEnabled(false)
        let known = try #require(harness.viewModel.savedRemoteUsers.first)
        var selection = MemberSelection(viewModel: harness.viewModel, groupID: nil)
        selection.selected = [known.id]; selection.addNewPerson()
        #expect(selection.memberCount == 3)
        #expect(selection.save() == .some(.some(selection.newGroupID)))
        let saved = harness.groupStore.snapshot
        #expect(selection.memberCount == 3 && selection.canSave)
        #expect(selection.save() == .some(.some(selection.newGroupID)))
        #expect(harness.groupStore.snapshot == saved)
        let person = selection.newPeople[0].id
        #expect(harness.viewModel.renameSavedUser(person, displayName: "Renamed new rider"))
        #expect(
            harness.groupStore.snapshot.contactInvitations.first(where: { $0.personID == person })?.nickname
                == "Renamed new rider")
        #expect(
            harness.viewModel.groups.first(where: { $0.id == selection.newGroupID })?.members.first(where: {
                $0.id.hasPrefix(GroupMember.pendingInvitePrefix)
            })?.resolvedDisplayName == "Renamed new rider")
    }

}
