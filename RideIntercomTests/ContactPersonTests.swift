import CoreTransferable
import Foundation
import UniformTypeIdentifiers
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
        let h = AppTestSupport.makeHarness(groups: [], credentialStore: keys)
        let id = UUID(), before = h.groupStore.snapshot
        h.groupStore.failSaving = true
        #expect(throws: (any Error).self) { try h.viewModel.groupRepository.saveContactPerson(id, name: "Maki") }
        #expect(h.groupStore.snapshot == before)
        h.groupStore.failSaving = false
        h.viewModel.reloadSavedGroups()
        try h.viewModel.groupRepository.saveContactPerson(id, name: "Maki")
        h.viewModel.reloadSavedGroups()
        #expect(h.viewModel.savedRemoteUsers.isEmpty, "A name is not a verified call destination")
        #expect(h.viewModel.directoryUsers.map(\.id) == [id])
        #expect(h.viewModel.groupRepository.contactInvitations.isEmpty && keys.values.isEmpty)
        #expect(h.callSession.connectedGroup == nil)
        #expect(throws: (any Error).self) { try h.viewModel.groupRepository.saveContactPerson(id, name: "Duplicate") }
    }

    @Test func confirmationUpgradesTheSamePersonAndCancellationDoesNotResurrectThem() throws {
        let h = AppTestSupport.makeHarness(groups: [], localMemberID: "person-author")
        let id = UUID(), vm = h.viewModel
        try vm.groupRepository.saveContactPerson(id, name: "My Maki")
        let token = try ContactInvitationSession.makeToken(authority: vm.invitationAuthority,
            signer: testIdentitySigner("person-author"), displayName: "Author", now: Date().timeIntervalSince1970)
        try vm.groupRepository.stageContactInvitation(token, now: Date().timeIntervalSince1970, personID: id)
        let acceptance = try token.accept(signer: testIdentitySigner("person-peer"), displayName: "Peer Name",
            trust: nil, now: Date().timeIntervalSince1970, contactBootstrap: true)
        let verified = try #require(try vm.invitationAuthority.verify(acceptance.receipt, trust: nil, now: Date().timeIntervalSince1970))
        try vm.groupRepository.confirmContactInvitation(verified, localDisplayName: "Author", now: Date().timeIntervalSince1970)
        vm.reloadSavedGroups()
        let person = try #require(vm.directoryUsers.first)
        #expect(person.id == id && person.displayName == "Peer Name" && person.localName == "My Maki")
        #expect(person.memberIDs == ["person-peer"] && vm.directoryUsers.count == 1)
        #expect(vm.savedRemoteUsers.map(\.id) == [id])
        _ = try vm.groupRepository.removeUser(id)
        try vm.groupRepository.confirmContactInvitation(verified, localDisplayName: "Author", now: Date().timeIntervalSince1970)
        #expect(vm.groupRepository.users.isEmpty, "Duplicate receipts only ACK; a deleted person stays deleted")
    }

    @Test func versionNineMigrationRetainsInvitationsAndAssignsSeparatePeopleEvenWithTheSameName() throws {
        let h = AppTestSupport.makeHarness(groups: [], localMemberID: "migration-author")
        h.viewModel.contactSessionFactory = { RecordingCallSession() }
        defer { h.viewModel.disconnect() }
        _ = try #require(h.viewModel.makeContactInviteURL())
        _ = try #require(h.viewModel.makeContactInviteURL())
        for record in h.viewModel.groupRepository.contactInvitations {
            try h.viewModel.groupRepository.setContactInvitationNickname(record.id, nickname: "Maki")
        }
        var old = h.groupStore.snapshot
        old.version = 9
        let upgraded = try GroupSnapshot.decode(old.encoded()).upgraded()
        #expect(upgraded.version == 10 && upgraded.contactInvitations.count == 2)
        #expect(upgraded.users.count == 2 && Set(upgraded.users.map(\.id)).count == 2)
        #expect(upgraded.contactInvitations.allSatisfy { $0.personID != nil })
        _ = try upgraded.encoded()
    }

    @Test func expiredLinkReplacementKeepsThePersonAndDeletingThemCancelsTheExchange() throws {
        let keys = InMemoryGroupCredentialStore()
        let h = AppTestSupport.makeHarness(groups: [], credentialStore: keys, localMemberID: "link-author")
        let repo = h.viewModel.groupRepository, id = UUID(), now = Date().timeIntervalSince1970
        try repo.saveContactPerson(id, name: "Maki")
        func token(at time: TimeInterval) throws -> GroupInviteToken {
            try ContactInvitationSession.makeToken(authority: h.viewModel.invitationAuthority,
                signer: testIdentitySigner("link-author"), displayName: "Author", now: time)
        }
        let first = try token(at: now), second = try token(at: now + 8 * 86400)
        try repo.stageContactInvitation(first, now: now, personID: id)
        let oldID = try #require(first.directInvitation?.context.id)
        let before = h.groupStore.snapshot
        #expect(throws: (any Error).self) { try repo.stageContactInvitation(first, now: now, personID: UUID()) }
        #expect(h.groupStore.snapshot == before)
        try repo.stageContactInvitation(second, now: now + 8 * 86400, replacingExpiredInvitation: oldID, personID: id)
        #expect(repo.users.map(\.id) == [id] && repo.users.first?.localName == "Maki")
        #expect(repo.contactInvitations.count == 1 && repo.contactInvitations.first?.personID == id)
        _ = try repo.removeUser(id)
        #expect(repo.users.isEmpty && repo.contactInvitations.first?.state == .cancelled)
        #expect(keys.values.isEmpty)
    }

    @Test func alreadyKnownIdentityKeepsItsIDWithoutDuplicatingThePersonOrOverwritingTheirName() throws {
        let h = AppTestSupport.makeHarness(groups: [], localMemberID: "known-author")
        let repo = h.viewModel.groupRepository, now = Date().timeIntervalSince1970
        var retainedID: UUID?
        for name in ["First name", "Second name"] {
            let id = UUID()
            try repo.saveContactPerson(id, name: name)
            let token = try ContactInvitationSession.makeToken(authority: h.viewModel.invitationAuthority,
                signer: testIdentitySigner("known-author"), displayName: "Author", now: now)
            try repo.stageContactInvitation(token, now: now, personID: id)
            let acceptance = try token.accept(signer: testIdentitySigner("known-peer"), displayName: "Peer",
                now: now, contactBootstrap: true)
            let verified = try #require(try h.viewModel.invitationAuthority.verify(acceptance.receipt, now: now))
            try repo.confirmContactInvitation(verified, localDisplayName: "Author", now: now)
            retainedID = retainedID ?? id
            #expect(repo.users.map(\.id) == [retainedID!])
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

    @Test func saveAndShareKeepOnePresentationAndCompletionDoesNotCloseIt() async throws {
        let h = AppTestSupport.makeHarness(groups: [], localMemberID: "presentation-person")
        let vm = h.viewModel
        vm.contactSessionFactory = { RecordingCallSession() }
        defer { vm.disconnect() }
        let before = h.groupStore.snapshot
        vm.beginContactInvitationPresentation()
        guard case .person = vm.contactInvitationPresentation else { Issue.record("Expected an unsaved person"); return }
        #expect(h.groupStore.snapshot == before && vm.contactInvitationID == nil)
        vm.dismissContactInvitationPresentation()
        #expect(h.groupStore.snapshot == before)
        vm.beginContactInvitationPresentation()
        guard case .person(let id) = vm.contactInvitationPresentation else { Issue.record("Expected the reopened draft"); return }
        #expect(vm.saveContactPerson(id, name: "My Partner"))
        #expect(vm.contactInvitationPresentation == .person(id) && vm.pendingContactInvitations.isEmpty)
        let share = InvitationShare(viewModel: vm, contactPersonID: id)
        vm.contactInvitationMessage = "Could not prepare this invitation. Try again."
        let first = try await share.exported(as: .url), second = try await share.exported(as: .url)
        #expect(first == second && vm.directoryUsers.map(\.id) == [id])
        #expect(vm.contactInvitationMessage == nil, "A successful retry clears the earlier preparation failure")
        #expect(vm.unlinkedContactInvitations.isEmpty && vm.contactInvitationPresentation == .person(id))
        let url = try await URL(importing: first, contentType: .url)
        let token = try GroupInviteTokenCodec.decodeJoinURL(url, contactBootstrap: true)
        let acceptance = try token.accept(signer: testIdentitySigner("person-response"), displayName: "Peer Name", contactBootstrap: true)
        let verified = try #require(try vm.invitationAuthority.verify(acceptance.receipt))
        try vm.groupRepository.confirmContactInvitation(verified, localDisplayName: "Author", now: Date().timeIntervalSince1970)
        vm.refreshGroupStorageStatus()
        #expect(vm.contactInvitationPresentation == .person(id), "Registration updates the same detail instead of closing it")
        #expect(vm.contactPerson(id)?.isRegistered == true && vm.directoryUsers.count == 1)
        #expect(vm.unlinkedContactInvitations.isEmpty)
        await #expect(throws: (any Error).self) { _ = try await share.exported(as: .url) }
    }

    @Test func foregroundResumesOnlyTheSuspendedExchangeInTheSameAccount() async throws {
        var now = Date()
        let h = AppTestSupport.makeHarness(groups: [], localMemberID: "foreground-person", callAccessNow: { now })
        let vm = h.viewModel
        var transports: [RecordingCallSession] = []
        vm.contactSessionFactory = { let transport = RecordingCallSession(); transports.append(transport); return transport }
        defer { vm.disconnect() }
        vm.beginContactInvitationPresentation()
        guard case .person(let id) = vm.contactInvitationPresentation else { Issue.record("Expected person"); return }
        #expect(vm.saveContactPerson(id, name: "Partner"))
        _ = try await InvitationShare(viewModel: vm, contactPersonID: id).exported(as: .url)
        let invitation = try #require(vm.contactInvitationID)
        vm.suspendContactInvitationForBackground()
        #expect(vm.contactInvitationID == nil)
        vm.resumeSuspendedContactInvitation()
        #expect(vm.contactInvitationID == invitation && transports.count == 2)
        #expect(vm.contactInvitationPresentation == .person(id))
        vm.resumeSuspendedContactInvitation()
        #expect(transports.count == 2, "Foreground consumes the suspension once")
        vm.suspendContactInvitationForBackground()
        now = now.addingTimeInterval(8 * 86400)
        vm.resumeSuspendedContactInvitation()
        #expect(vm.contactInvitationID == nil && transports.count == 2)
        vm.suspendedContactInvitation = (invitation, UUID())
        now = Date()
        vm.resumeSuspendedContactInvitation()
        #expect(vm.contactInvitationID == nil && transports.count == 2)
        #expect(h.callSession.connectedGroup == nil)
    }

    @Test func failedExplicitSaveKeepsTheDraftPresentationForReloadAndRetry() throws {
        let h = AppTestSupport.makeHarness(groups: [])
        let vm = h.viewModel
        vm.beginContactInvitationPresentation()
        guard case .person(let id) = vm.contactInvitationPresentation else { Issue.record("Expected person"); return }
        h.groupStore.failSaving = true
        #expect(!vm.saveContactPerson(id, name: "Retained Input"))
        #expect(vm.contactInvitationPresentation == .person(id) && vm.directoryUsers.isEmpty)
        #expect(vm.contactInvitationMessage != nil && !vm.canEditSavedGroups)
        h.groupStore.failSaving = false
        vm.reloadSavedGroups()
        #expect(vm.saveContactPerson(id, name: "Retained Input"))
        #expect(vm.contactInvitationPresentation == .person(id))
        #expect(vm.contactPerson(id)?.resolvedDisplayName == "Retained Input")
        #expect(vm.pendingContactInvitations.isEmpty && vm.contactInvitationID == nil)
    }

}
