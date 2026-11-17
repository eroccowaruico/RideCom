import Foundation
import Testing
@testable import RideIntercom

@MainActor
struct ContactNameChoiceTests {
    @Test func automaticNameProvenanceSurvivesTheExistingSaveFormat() throws {
        let user = SavedUser(displayName: "Maki", memberIDs: ["name-peer"], localName: "Blue Fox")
        var object = try #require(JSONSerialization.jsonObject(with: GroupSnapshot(users: [user]).encoded()) as? [String: Any])
        var users = try #require(object["users"] as? [[String: Any]])
        users[0]["usesProvisionalName"] = true
        object["users"] = users
        let restored = try GroupSnapshot.decode(JSONSerialization.data(withJSONObject: object))
        let encoded = try #require(JSONSerialization.jsonObject(with: restored.encoded()) as? [String: Any])
        let directory = try #require(encoded["users"] as? [[String: Any]])
        #expect(directory[0]["usesProvisionalName"] as? Bool == true)
    }
    private func registeredPerson(automatic: Bool = true) throws -> (AppTestSupport.Harness, UUID) {
        let h = AppTestSupport.makeHarness(groups: [], localMemberID: "choice-author")
        let vm = h.viewModel, id = UUID(), now = Date().timeIntervalSince1970
        try vm.groupRepository.saveContactPerson(id, name: "Blue Fox", usesProvisionalName: automatic)
        #expect(!vm.groupRepository.users[0].needsNameConfirmation)
        let token = try ContactInvitationSession.makeToken(authority: vm.invitationAuthority,
            signer: testIdentitySigner("choice-author"), displayName: "Author", now: now)
        try vm.groupRepository.stageContactInvitation(token, now: now, personID: id)
        let acceptance = try token.accept(signer: testIdentitySigner("choice-peer"), displayName: "Maki", now: now, contactBootstrap: true)
        let verified = try #require(try vm.invitationAuthority.verify(acceptance.receipt, now: now))
        try vm.groupRepository.confirmContactInvitation(verified, localDisplayName: "Author", now: now)
        vm.refreshGroupStorageStatus()
        return (h, id)
    }

    @Test(arguments: [false, true])
    func choicePersistsWithoutChangingThePersonInvitationOrKeys(useSharedName: Bool) throws {
        let (h, id) = try registeredPerson(), vm = h.viewModel
        let person = try #require(vm.contactPerson(id))
        #expect(person.needsNameConfirmation)
        let records = h.groupStore.snapshot.contactInvitations, groups = h.groupStore.snapshot.groups
        vm.showContactPerson(id)
        #expect(vm.resolveContactPersonName(person, useSharedName: useSharedName))
        let current = try #require(vm.contactPerson(id))
        #expect(current.id == person.id && current.memberIDs == person.memberIDs && current.deviceKeys == person.deviceKeys)
        #expect(current.localName == (useSharedName ? nil : "Blue Fox"))
        #expect(!current.needsNameConfirmation && current.usesProvisionalName == false)
        #expect(vm.contactInvitationPresentation == .person(id))
        #expect(h.groupStore.snapshot.contactInvitations == records)
        #expect(h.groupStore.snapshot.groups.map(\.credentialReference) == groups.map(\.credentialReference))
        let restored = try GroupSnapshot.decode(h.groupStore.snapshot.encoded())
        #expect(restored.users.first?.needsNameConfirmation == false)
        let saves = h.groupStore.saveCount
        #expect(!vm.resolveContactPersonName(person, useSharedName: !useSharedName))
        #expect(h.groupStore.saveCount == saves, "An old button cannot reverse an already saved choice")
    }

    @Test func manualAndLegacyNamesAreNeverInferredFromTheirSpelling() throws {
        let (h, id) = try registeredPerson(automatic: false)
        #expect(h.viewModel.contactPerson(id)?.needsNameConfirmation == false)
        let old = SavedUser(displayName: "Maki", memberIDs: ["legacy"], localName: "Blue Fox")
        let restored = try GroupSnapshot.decode(GroupSnapshot(users: [old]).encoded())
        #expect(restored.users.first?.usesProvisionalName == nil && restored.users.first?.needsNameConfirmation == false)
        #expect(old.resolvedDisplayName == "Blue Fox")
    }

    @Test func editingEvenTheSameNameMakesItAnExplicitChoice() throws {
        let (h, id) = try registeredPerson()
        #expect(h.viewModel.renameSavedUser(id, displayName: "Blue Fox"))
        #expect(h.viewModel.contactPerson(id)?.needsNameConfirmation == false)
        #expect(h.viewModel.contactPerson(id)?.usesProvisionalName == false)
    }

    @Test func failedChoiceAndStaleDisplayedNamesKeepTheSavedName() throws {
        let (h, id) = try registeredPerson(), vm = h.viewModel
        let person = try #require(vm.contactPerson(id)), before = h.groupStore.snapshot
        h.groupStore.failSaving = true
        #expect(!vm.resolveContactPersonName(person, useSharedName: true))
        #expect(h.groupStore.snapshot == before && vm.contactPerson(id)?.needsNameConfirmation == true)
        h.groupStore.failSaving = false
        vm.reloadSavedGroups()
        var stale = person; stale.displayName = "An older name"
        #expect(!vm.resolveContactPersonName(stale, useSharedName: true))
        #expect(vm.contactPerson(id)?.localName == "Blue Fox" && vm.contactPerson(id)?.needsNameConfirmation == true)
        #expect(vm.resolveContactPersonName(person, useSharedName: true))
        #expect(vm.contactPerson(id)?.resolvedDisplayName == "Maki")
    }

    @Test func aProvisionalMarkerRequiresASavedLocalName() throws {
        let person = SavedUser(displayName: "Maki", memberIDs: [], usesProvisionalName: true)
        #expect(throws: (any Error).self) { try GroupSnapshot(users: [person]).encoded() }
    }

    @Test func uiFixtureIsAccountScopedAndNeverResetsAPersistedChoice() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "name-review-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = UUID(), scope = "RideIntercom.Validation.NameChoice"
        #expect(throws: (any Error).self) { try AppleAccountFixture.processContactNameFixture(id.uuidString, namespace: "RideIntercom", applicationSupport: root) }
        #expect(!FileManager.default.fileExists(atPath: root.path))
        try AppleAccountFixture.processContactNameFixture(id.uuidString, namespace: scope, applicationSupport: root)
        let directory = root.appending(path: AppleAccountSession.storageNamespace(base: scope, userID: AppleAccountFixture.userID)).appending(path: "Groups")
        let store = FileGroupStore(directory: directory)
        var saved = try #require(try store.read())
        #expect(saved.users.first?.needsNameConfirmation == true)
        saved.users[0].usesProvisionalName = false
        try store.lock(); try store.commit(saved); store.unlock()
        try AppleAccountFixture.processContactNameFixture(id.uuidString, namespace: scope, applicationSupport: root)
        #expect(try store.read()?.users.first?.usesProvisionalName == false)
    }

}
