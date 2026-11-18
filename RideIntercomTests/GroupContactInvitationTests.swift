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

    private func prepared() throws -> (AppTestSupport.Harness, AppTestSupport.Harness, GroupInviteToken, UUID) {
        let author = AppTestSupport.makeHarness(groups: [], localMemberID: "group-author")
        let recipient = AppTestSupport.makeHarness(groups: [], localMemberID: "group-recipient")
        author.viewModel.contactSessionFactory = { RecordingCallSession() }; recipient.viewModel.contactSessionFactory = { RecordingCallSession() }
        #expect(author.viewModel.createTalkGroup(name: "Mountain riders"))
        author.viewModel.disconnect()
        let group = try #require(author.viewModel.groups.first), person = UUID()
        try author.viewModel.groupRepository.saveContactPerson(person, name: "My new rider")
        author.viewModel.reloadSavedGroups()
        let credential = try #require(try author.viewModel.groupRepository.credential(for: group.id))
        let token = try ContactInvitationSession.makeToken(authority: author.viewModel.invitationAuthority,
            signer: author.viewModel.internetSettingsStore.invitationSigner(memberID: "group-author"), displayName: "Author", now: Date().timeIntervalSince1970,
            invitedGroup: .init(id: group.id, name: group.name, secret: credential.secret))
        try author.viewModel.groupRepository.stageContactInvitation(token, now: Date().timeIntervalSince1970, personID: person)
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

}
