import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct ContactPersonTests {
    @Test func aNameCanBeSavedWithoutAnIdentityInvitationOrCredential() throws {
        let user = SavedUser(displayName: "Maki", memberIDs: [], localName: "Maki")
        let snapshot = GroupSnapshot(users: [user])
        let restored = try GroupSnapshot.decode(snapshot.encoded())
        #expect(restored.users == [user])
        #expect(restored.groups.isEmpty && restored.contactInvitations.isEmpty)
    }
    @Test func explicitSaveIsAtomicAndDoesNotMakeThePersonCallable() throws {
        let keys = InMemoryGroupCredentialStore()
        let harness = AppTestSupport.makeHarness(groups: [], credentialStore: keys)
        let id = UUID(), before = harness.groupStore.snapshot
        harness.groupStore.failSaving = true
        #expect(throws: (any Error).self) { try harness.viewModel.groupRepository.saveContactPerson(id, name: "Maki") }
        #expect(harness.groupStore.snapshot == before)
        harness.groupStore.failSaving = false
        harness.viewModel.reloadSavedGroups()
        try harness.viewModel.groupRepository.saveContactPerson(id, name: "Maki")
        harness.viewModel.reloadSavedGroups()
        #expect(harness.viewModel.savedRemoteUsers.isEmpty, "A name is not a verified call destination")
        #expect(harness.viewModel.directoryUsers.map(\.id) == [id])
        #expect(harness.viewModel.groupRepository.contactInvitations.isEmpty && keys.values.isEmpty)
        #expect(harness.callSession.connectedGroup == nil)
        #expect(throws: (any Error).self) {
            try harness.viewModel.groupRepository.saveContactPerson(id, name: "Duplicate")
        }
    }

    @Test func confirmationUpgradesTheSamePersonAndCancellationDoesNotResurrectThem() throws {
        let harness = AppTestSupport.makeHarness(groups: [], localMemberID: "person-author")
        let id = UUID(), viewModel = harness.viewModel
        try viewModel.groupRepository.saveContactPerson(id, name: "My Maki")
        let token = try ContactInvitationSession.makeToken(authority: viewModel.invitationAuthority,
            signer: testIdentitySigner("person-author"), displayName: "Author", now: Date().timeIntervalSince1970)
        try viewModel.groupRepository.stageContactInvitation(token, now: Date().timeIntervalSince1970, personID: id)
        let acceptance = try token.accept(signer: testIdentitySigner("person-peer"), displayName: "Peer Name",
            trust: nil, now: Date().timeIntervalSince1970, contactBootstrap: true)
        let verified = try #require(
            try viewModel.invitationAuthority.verify(
                acceptance.receipt, trust: nil, now: Date().timeIntervalSince1970))
        try viewModel.groupRepository.confirmContactInvitation(
            verified, localDisplayName: "Author", now: Date().timeIntervalSince1970)
        viewModel.reloadSavedGroups()
        let person = try #require(viewModel.directoryUsers.first)
        #expect(person.id == id && person.displayName == "Peer Name" && person.localName == "My Maki")
        #expect(person.memberIDs == ["person-peer"] && viewModel.directoryUsers.count == 1)
        #expect(viewModel.savedRemoteUsers.map(\.id) == [id])
        _ = try viewModel.groupRepository.removeUser(id)
        #expect(throws: GroupStorageError.invalidUpdate) {
            try viewModel.groupRepository.confirmContactInvitation(
                verified, localDisplayName: "Author", now: Date().timeIntervalSince1970)
        }
        #expect(viewModel.groupRepository.users.isEmpty)
    }

    @Test func versionNineMigrationRetainsInvitationsAndAssignsSeparatePeopleEvenWithTheSameName() throws {
        let harness = AppTestSupport.makeHarness(groups: [], localMemberID: "migration-author")
        harness.viewModel.contactSessionFactory = { RecordingCallSession() }
        defer { harness.viewModel.disconnect() }
        _ = try #require(harness.viewModel.makeContactInviteURL())
        _ = try #require(harness.viewModel.makeContactInviteURL())
        for record in harness.viewModel.groupRepository.contactInvitations {
            try harness.viewModel.groupRepository.setContactInvitationNickname(record.id, nickname: "Maki")
        }
        var old = harness.groupStore.snapshot
        old.version = 9
        let upgraded = try GroupSnapshot.decode(old.encoded()).upgraded()
        #expect(upgraded.version == GroupSnapshot.currentVersion && upgraded.contactInvitations.count == 2)
        #expect(upgraded.users.count == 2 && Set(upgraded.users.map(\.id)).count == 2)
        #expect(upgraded.contactInvitations.allSatisfy { $0.personID != nil })
        _ = try upgraded.encoded()
    }

    @Test func expiredLinkReplacementKeepsThePersonAndDeletingThemCancelsTheExchange() throws {
        let keys = InMemoryGroupCredentialStore()
        let harness = AppTestSupport.makeHarness(groups: [], credentialStore: keys, localMemberID: "link-author")
        let repo = harness.viewModel.groupRepository, id = UUID(), now = Date().timeIntervalSince1970
        try repo.saveContactPerson(id, name: "Maki")
        func token(at time: TimeInterval) throws -> GroupInviteToken {
            try ContactInvitationSession.makeToken(authority: harness.viewModel.invitationAuthority,
                signer: testIdentitySigner("link-author"), displayName: "Author", now: time)
        }
        let first = try token(at: now), second = try token(at: now + 8 * 86400)
        try repo.stageContactInvitation(first, now: now, personID: id)
        let oldID = try #require(first.directInvitation?.context.id)
        let before = harness.groupStore.snapshot
        #expect(throws: (any Error).self) { try repo.stageContactInvitation(first, now: now, personID: UUID()) }
        #expect(harness.groupStore.snapshot == before)
        try repo.stageContactInvitation(second, now: now + 8 * 86400, replacingExpiredInvitation: oldID, personID: id)
        #expect(repo.users.map(\.id) == [id] && repo.users.first?.localName == "Maki")
        #expect(repo.contactInvitations.count == 1 && repo.contactInvitations.first?.personID == id)
        _ = try repo.removeUser(id)
        #expect(repo.users.isEmpty && repo.contactInvitations.first?.state == .cancelled)
        #expect(keys.values.isEmpty)
    }

    @Test func alreadyKnownIdentityKeepsItsIDWithoutDuplicatingThePersonOrOverwritingTheirName() throws {
        let harness = AppTestSupport.makeHarness(groups: [], localMemberID: "known-author")
        let repo = harness.viewModel.groupRepository, now = Date().timeIntervalSince1970
        var retainedID: UUID?
        for name in ["First name", "Second name"] {
            let id = UUID()
            try repo.saveContactPerson(id, name: name)
            let token = try ContactInvitationSession.makeToken(authority: harness.viewModel.invitationAuthority,
                signer: testIdentitySigner("known-author"), displayName: "Author", now: now)
            try repo.stageContactInvitation(token, now: now, personID: id)
            let acceptance = try token.accept(signer: testIdentitySigner("known-peer"), displayName: "Peer",
                now: now, contactBootstrap: true)
            let verified = try #require(try harness.viewModel.invitationAuthority.verify(acceptance.receipt, now: now))
            try repo.confirmContactInvitation(verified, localDisplayName: "Author", now: now)
            retainedID = retainedID ?? id
            #expect(repo.users.map(\.id) == [try #require(retainedID)])
            #expect(repo.users.first?.localName == "First name")
        }
    }

    @Test func unnamedIdentitiesCannotCarryAuthenticationOrBeEncodedInOldSchema() throws {
        var snapshot = GroupSnapshot(users: [SavedUser(displayName: "Maki", memberIDs: [])])
        snapshot.version = 9
        #expect(throws: (any Error).self) { try snapshot.encoded() }
        snapshot.version = 10
        snapshot.users[0].deviceKeys = [:]
        #expect(throws: (any Error).self) { try snapshot.encoded() }
    }

    @Test func saveAndShareKeepOnePresentationAndCompletionDoesNotCloseIt() throws {
        let harness = AppTestSupport.makeHarness(groups: [], localMemberID: "presentation-person")
        let viewModel = harness.viewModel
        viewModel.contactSessionFactory = { RecordingCallSession() }
        defer { viewModel.disconnect() }
        let before = harness.groupStore.snapshot
        viewModel.beginContactInvitationPresentation()
        guard case .person = viewModel.contactInvitationPresentation else {
            Issue.record("Expected an unsaved person"); return
        }
        #expect(harness.groupStore.snapshot == before && viewModel.contactInvitationID == nil)
        viewModel.dismissContactInvitationPresentation()
        #expect(harness.groupStore.snapshot == before)
        viewModel.beginContactInvitationPresentation()
        guard case .person(let id) = viewModel.contactInvitationPresentation else {
            Issue.record("Expected the reopened draft"); return
        }
        #expect(viewModel.saveContactPerson(id, name: "My Partner"))
        #expect(viewModel.contactInvitationPresentation == .person(id) && viewModel.pendingContactInvitations.isEmpty)
        let access = viewModel.accountAccessID
        viewModel.contactInvitationMessage = "Could not prepare this invitation. Try again."
        let first = try viewModel.prepareContactPersonShare(id, expectedAccountAccessID: access)
        let second = try viewModel.prepareContactPersonShare(id, expectedAccountAccessID: access)
        #expect(first.id == second.id && first.url == second.url && viewModel.directoryUsers.map(\.id) == [id])
        viewModel.completeContactInvitationSharing(.init(id: first.id, accountAccessID: UUID(), url: first.url))
        #expect(viewModel.contactInvitationRecord(first.id)?.sent == false)
        viewModel.completeContactInvitationSharing(first)
        #expect(viewModel.contactInvitationRecord(first.id)?.sent == true)
        #expect(viewModel.contactInvitationMessage == nil, "A successful retry clears the earlier preparation failure")
        #expect(viewModel.unlinkedContactInvitations.isEmpty && viewModel.contactInvitationPresentation == .person(id))
        let token = try GroupInviteTokenCodec.decodeJoinURL(first.url, contactBootstrap: true)
        let acceptance = try token.accept(
            signer: testIdentitySigner("person-response"), displayName: "Peer Name", contactBootstrap: true)
        let verified = try #require(try viewModel.invitationAuthority.verify(acceptance.receipt))
        try viewModel.groupRepository.confirmContactInvitation(
            verified, localDisplayName: "Author", now: Date().timeIntervalSince1970)
        viewModel.refreshGroupStorageStatus()
        #expect(
            viewModel.contactInvitationPresentation == .person(id),
            "Registration updates the same detail instead of closing it")
        #expect(viewModel.contactPerson(id)?.isRegistered == true && viewModel.directoryUsers.count == 1)
        #expect(viewModel.unlinkedContactInvitations.isEmpty)
        #expect(throws: (any Error).self) {
            _ = try viewModel.prepareContactPersonShare(id, expectedAccountAccessID: access)
        }
    }

    @Test func foregroundResumesOnlyTheSuspendedExchangeInTheSameAccount() throws {
        var now = Date()
        let harness = AppTestSupport.makeHarness(groups: [], localMemberID: "foreground-person", callAccessNow: { now })
        let viewModel = harness.viewModel
        var transports: [RecordingCallSession] = []
        viewModel.contactSessionFactory = {
            let transport = RecordingCallSession(); transports.append(transport); return transport
        }
        defer { viewModel.disconnect() }
        viewModel.beginContactInvitationPresentation()
        guard case .person(let id) = viewModel.contactInvitationPresentation else {
            Issue.record("Expected person"); return
        }
        #expect(viewModel.saveContactPerson(id, name: "Partner"))
        let share = try viewModel.prepareContactPersonShare(id, expectedAccountAccessID: viewModel.accountAccessID)
        viewModel.completeContactInvitationSharing(share)
        let invitation = try #require(viewModel.contactInvitationID)
        viewModel.suspendContactInvitationForBackground()
        #expect(viewModel.contactInvitationID == nil)
        viewModel.resumeSuspendedContactInvitation()
        #expect(viewModel.contactInvitationID == invitation && transports.count == 2)
        #expect(viewModel.contactInvitationPresentation == .person(id))
        viewModel.resumeSuspendedContactInvitation()
        #expect(transports.count == 2, "Foreground consumes the suspension once")
        viewModel.suspendContactInvitationForBackground()
        now = now.addingTimeInterval(8 * 86400)
        viewModel.resumeSuspendedContactInvitation()
        #expect(viewModel.contactInvitationID == nil && transports.count == 2)
        viewModel.suspendedContactInvitation = (invitation, UUID())
        now = Date()
        viewModel.resumeSuspendedContactInvitation()
        #expect(viewModel.contactInvitationID == nil && transports.count == 2)
        #expect(harness.callSession.connectedGroup == nil)
    }

    @Test func failedExplicitSaveKeepsTheDraftPresentationForReloadAndRetry() throws {
        let harness = AppTestSupport.makeHarness(groups: [])
        let viewModel = harness.viewModel
        viewModel.beginContactInvitationPresentation()
        guard case .person(let id) = viewModel.contactInvitationPresentation else {
            Issue.record("Expected person"); return
        }
        harness.groupStore.failSaving = true
        #expect(!viewModel.saveContactPerson(id, name: "Retained Input"))
        #expect(viewModel.contactInvitationPresentation == .person(id) && viewModel.directoryUsers.isEmpty)
        #expect(viewModel.contactInvitationMessage != nil && !viewModel.canEditSavedGroups)
        harness.groupStore.failSaving = false
        viewModel.reloadSavedGroups()
        #expect(viewModel.saveContactPerson(id, name: "Retained Input"))
        #expect(viewModel.contactInvitationPresentation == .person(id))
        #expect(viewModel.contactPerson(id)?.resolvedDisplayName == "Retained Input")
        #expect(viewModel.pendingContactInvitations.isEmpty && viewModel.contactInvitationID == nil)
    }

    @Test(arguments: [false, true])
    func reInvitationPreservesAnExistingNameChoice(followSharedName: Bool) throws {
        let harness = AppTestSupport.makeHarness(groups: [], localMemberID: "name-choice-author")
        let repo = harness.viewModel.groupRepository, now = Date().timeIntervalSince1970
        let firstID = UUID()
        for (index, id) in [firstID, UUID()].enumerated() {
            try repo.saveContactPerson(id, name: index == 0 ? "Original alias" : "New invitation alias")
            let token = try ContactInvitationSession.makeToken(authority: harness.viewModel.invitationAuthority,
                signer: testIdentitySigner("name-choice-author"), displayName: "Author", now: now)
            try repo.stageContactInvitation(token, now: now, personID: id)
            let acceptance = try token.accept(signer: testIdentitySigner("name-choice-peer"), displayName: "Their Name",
                now: now, contactBootstrap: true)
            let verified = try #require(try harness.viewModel.invitationAuthority.verify(acceptance.receipt, now: now))
            try repo.confirmContactInvitation(verified, localDisplayName: "Author", now: now)
            if index == 0 {
                if followSharedName {
                    try repo.resetUserName(firstID)
                } else {
                    try repo.renameUser(firstID, displayName: "My chosen name")
                }
            }
        }
        #expect(repo.users.map(\.id) == [firstID])
        #expect(repo.users.first?.localName == (followSharedName ? nil : "My chosen name"))
        #expect(repo.users.first?.resolvedDisplayName == (followSharedName ? "Their Name" : "My chosen name"))
        #expect(harness.groupStore.snapshot.contactInvitations.count == 2)
    }

}
