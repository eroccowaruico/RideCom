import Foundation
import Testing

@testable import RideIntercom

@MainActor
struct ContactNameChoiceTests {
  @Test func automaticNameProvenanceSurvivesTheExistingSaveFormat() throws {
    let user = SavedUser(displayName: "Maki", memberIDs: ["name-peer"], localName: "Blue Fox")
    var object = try #require(
      JSONSerialization.jsonObject(with: GroupSnapshot(users: [user]).encoded()) as? [String: Any])
    var users = try #require(object["users"] as? [[String: Any]])
    users[0]["usesProvisionalName"] = true
    object["users"] = users
    let restored = try GroupSnapshot.decode(JSONSerialization.data(withJSONObject: object))
    let encoded = try #require(JSONSerialization.jsonObject(with: restored.encoded()) as? [String: Any])
    let directory = try #require(encoded["users"] as? [[String: Any]])
    #expect(directory[0]["usesProvisionalName"] as? Bool == true)
  }
  private func registeredPerson(automatic: Bool = true) throws -> (AppTestSupport.Harness, UUID) {
    let harness = AppTestSupport.makeHarness(groups: [], localMemberID: "choice-author")
    let viewModel = harness.viewModel
    let id = UUID()
    let now = Date().timeIntervalSince1970
    try viewModel.groupRepository.saveContactPerson(id, name: "Blue Fox", usesProvisionalName: automatic)
    #expect(!viewModel.groupRepository.users[0].needsNameConfirmation)
    let token = try ContactInvitationSession.makeToken(
      authority: viewModel.invitationAuthority,
      signer: testIdentitySigner("choice-author"), displayName: "Author", now: now)
    try viewModel.groupRepository.stageContactInvitation(token, now: now, personID: id)
    let acceptance = try token.accept(
      signer: testIdentitySigner("choice-peer"), displayName: "Maki", now: now, contactBootstrap: true)
    let verified = try #require(try viewModel.invitationAuthority.verify(acceptance.receipt, now: now))
    try viewModel.groupRepository.confirmContactInvitation(verified, localDisplayName: "Author", now: now)
    viewModel.refreshGroupStorageStatus()
    return (harness, id)
  }

  @Test(arguments: [false, true])
  func choicePersistsWithoutChangingThePersonInvitationOrKeys(useSharedName: Bool) throws {
    let (harness, id) = try registeredPerson()
    let viewModel = harness.viewModel
    let person = try #require(viewModel.contactPerson(id))
    #expect(person.needsNameConfirmation)
    let records = harness.groupStore.snapshot.contactInvitations
    let groups = harness.groupStore.snapshot.groups
    viewModel.showContactPerson(id)
    #expect(viewModel.resolveContactPersonName(person, useSharedName: useSharedName))
    let current = try #require(viewModel.contactPerson(id))
    #expect(
      current.id == person.id && current.memberIDs == person.memberIDs
        && current.deviceKeys == person.deviceKeys)
    #expect(current.localName == (useSharedName ? nil : "Blue Fox"))
    #expect(!current.needsNameConfirmation && current.usesProvisionalName == false)
    #expect(viewModel.contactInvitationPresentation == .person(id))
    #expect(harness.groupStore.snapshot.contactInvitations == records)
    #expect(harness.groupStore.snapshot.groups.map(\.credentialReference) == groups.map(\.credentialReference))
    let restored = try GroupSnapshot.decode(harness.groupStore.snapshot.encoded())
    #expect(restored.users.first?.needsNameConfirmation == false)
    let saves = harness.groupStore.saveCount
    #expect(!viewModel.resolveContactPersonName(person, useSharedName: !useSharedName))
    #expect(harness.groupStore.saveCount == saves, "An old button cannot reverse an already saved choice")
  }

  @Test func manualAndLegacyNamesAreNeverInferredFromTheirSpelling() throws {
    let (harness, id) = try registeredPerson(automatic: false)
    #expect(harness.viewModel.contactPerson(id)?.needsNameConfirmation == false)
    let old = SavedUser(displayName: "Maki", memberIDs: ["legacy"], localName: "Blue Fox")
    let restored = try GroupSnapshot.decode(GroupSnapshot(users: [old]).encoded())
    #expect(
      restored.users.first?.usesProvisionalName == nil
        && restored.users.first?.needsNameConfirmation == false)
    #expect(old.resolvedDisplayName == "Blue Fox")
  }

  @Test func editingEvenTheSameNameMakesItAnExplicitChoice() throws {
    let (harness, id) = try registeredPerson()
    #expect(harness.viewModel.renameSavedUser(id, displayName: "Blue Fox"))
    #expect(harness.viewModel.contactPerson(id)?.needsNameConfirmation == false)
    #expect(harness.viewModel.contactPerson(id)?.usesProvisionalName == false)
  }

  @Test func failedChoiceAndStaleDisplayedNamesKeepTheSavedName() throws {
    let (harness, id) = try registeredPerson()
    let viewModel = harness.viewModel
    let person = try #require(viewModel.contactPerson(id))
    let before = harness.groupStore.snapshot
    harness.groupStore.failSaving = true
    #expect(!viewModel.resolveContactPersonName(person, useSharedName: true))
    #expect(harness.groupStore.snapshot == before && viewModel.contactPerson(id)?.needsNameConfirmation == true)
    harness.groupStore.failSaving = false
    viewModel.reloadSavedGroups()
    var stale = person
    stale.displayName = "An older name"
    #expect(!viewModel.resolveContactPersonName(stale, useSharedName: true))
    #expect(
      viewModel.contactPerson(id)?.localName == "Blue Fox" && viewModel.contactPerson(id)?.needsNameConfirmation == true
    )
    #expect(viewModel.resolveContactPersonName(person, useSharedName: true))
    #expect(viewModel.contactPerson(id)?.resolvedDisplayName == "Maki")
  }

  @Test func aProvisionalMarkerRequiresASavedLocalName() throws {
    let person = SavedUser(displayName: "Maki", memberIDs: [], usesProvisionalName: true)
    #expect(throws: (any Error).self) { try GroupSnapshot(users: [person]).encoded() }
  }

  @Test func uiFixtureIsAccountScopedAndNeverResetsAPersistedChoice() throws {
    let root = FileManager.default.temporaryDirectory.appending(path: "name-review-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let scope = "RideIntercom.Validation.NameChoice"
    #expect(throws: (any Error).self) {
      try AppleAccountFixture.processContactNameFixture(
        id.uuidString, namespace: "RideIntercom", applicationSupport: root)
    }
    #expect(!FileManager.default.fileExists(atPath: root.path))
    try AppleAccountFixture.processContactNameFixture(id.uuidString, namespace: scope, applicationSupport: root)
    let directory = root.appending(
      path: AppleAccountSession.storageNamespace(base: scope, userID: AppleAccountFixture.userID)
    ).appending(path: "Groups")
    let store = FileGroupStore(directory: directory)
    var saved = try #require(try store.read())
    #expect(saved.users.first?.needsNameConfirmation == true)
    saved.users[0].usesProvisionalName = false
    try store.lock()
    try store.commit(saved)
    store.unlock()
    try AppleAccountFixture.processContactNameFixture(id.uuidString, namespace: scope, applicationSupport: root)
    #expect(try store.read()?.users.first?.usesProvisionalName == false)
  }

}
