import Foundation
import RTC
import Testing

@testable import RideIntercom

@MainActor @Suite(.serialized)
struct DisplayNameTests {
  @Test func groupMembershipAloneCannotRenameASavedContact() throws {
    let harness = AppTestSupport.makeHarness(groups: [], localMemberID: "local")
    let viewModel = harness.viewModel
    defer { viewModel.disconnect() }
    let token = try GroupInviteToken.make(
      authority: testInvitationAuthority(), signer: testIdentitySigner("friend"),
      groupID: UUID(), groupName: "Friends", groupSecret: "shared-group-key",
      inviterMemberID: "friend", inviterDisplayName: "Friend")
    try viewModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
    harness.callSession.authenticate(["friend"])
    let before = viewModel.savedUsers
    let forged = SharedDisplayName(
      groupID: token.groupID, memberID: "friend", recipientMemberID: "local",
      challenge: try #require(viewModel.peerProfiles["friend"]).challenge, revision: 1,
      displayName: "Impostor")
    viewModel.receiveSharedDisplayName(
      peerID: "friend",
      message: .init(
        namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(forged)))
    #expect(viewModel.savedUsers == before)
    #expect(viewModel.groupStorageIssue == nil)
  }

  @Test func anInvitationWithoutANameKeepsTheKnownNameOfItsAuthor() throws {
    let harness = AppTestSupport.makeHarness(groups: [], localMemberID: "local")
    let viewModel = harness.viewModel
    defer { viewModel.disconnect() }
    viewModel.contactSessionFactory = { RecordingCallSession() }
    func invitation(_ group: String, name: String?, contact: Bool = false) throws -> URL {
      let secret = Data(repeating: UInt8(group.count), count: 32).base64EncodedString()
      let token = try GroupInviteToken.make(
        authority: testInvitationAuthority(), signer: testIdentitySigner("friend"),
        groupID: UUID(), groupName: group, groupSecret: secret, inviterMemberID: "friend",
        inviterDisplayName: name,
        contactBootstrap: contact ? true : nil)
      return try GroupInviteTokenCodec.joinURL(for: token, contactBootstrap: contact ? true : nil)
    }
    try viewModel.acceptInviteURL(invitation("Friends", name: "Friend"))
    viewModel.disconnect()

    try viewModel.acceptInviteURL(invitation("Club", name: nil))
    viewModel.disconnect()
    #expect(viewModel.savedUsers.map(\.displayName) == ["Friend"])
    #expect(
      viewModel.groups.first { $0.name == "Club" }?.members.map(\.displayName).last == "Friend")

    let contact = try invitation("Contact Invitation", name: nil, contact: true)
    #expect(viewModel.previewContactInvitation(contact))
    guard case .some(.accepting(let preview)) = viewModel.contactInvitationPresentation else {
      Issue.record("No preview")
      return
    }
    #expect(preview.inviterName == "Friend")
    #expect(viewModel.acceptPresentedContactInvitation())
    #expect(viewModel.savedUsers.map(\.displayName) == ["Friend"])
  }

  @Test func aNameThatCannotBeSavedAfterSignOutSaysSoInsteadOfBlamingTheName() throws {
    let harness = AppTestSupport.makeHarness(groups: [], localMemberID: "local")
    let viewModel = harness.viewModel
    defer { viewModel.disconnect() }
    let token = try GroupInviteToken.make(
      authority: testInvitationAuthority(), signer: testIdentitySigner("friend"),
      groupID: UUID(), groupName: "Friends", groupSecret: "shared-group-key",
      inviterMemberID: "friend", inviterDisplayName: "Friend")
    try viewModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
    let user = try #require(viewModel.savedUsers.first)
    viewModel.accountSession.signOut()
    let ended = "This sign-in has ended. Open your current account to continue."
    #expect(!viewModel.setLocalDisplayName("Valid Name"))
    #expect(viewModel.groupErrorMessage == ended)
    viewModel.groupErrorMessage = nil
    #expect(!viewModel.renameSavedUser(user.id, displayName: "Valid Name"))
    #expect(viewModel.groupErrorMessage == ended)
  }

  @Test func localNamePersistsAndIsSharedWithoutEndingTheCall() throws {
    let harness = AppTestSupport.makeHarness()
    let viewModel = harness.viewModel
    defer { viewModel.disconnect() }
    viewModel.selectGroup(try #require(viewModel.groups.first))
    harness.callSession.authenticate(["member-108"])
    try receiveTestProfileChallenge(viewModel, peerID: "member-108")
    let stops = harness.callSession.disconnectCallCount
    #expect(viewModel.setLocalDisplayName("  やまねこ ⛷  "))
    #expect(viewModel.localMemberIdentity.displayName == "やまねこ ⛷")
    #expect(viewModel.groups.allSatisfy { $0.members.first?.displayName == "やまねこ ⛷" })
    #expect(harness.callSession.disconnectCallCount == stops)
    let sent = try #require(
      harness.callSession.sentApplicationDataMessages.last {
        $0.namespace == SharedDisplayName.namespace
      })
    #expect(
      try JSONDecoder().decode(SharedDisplayName.self, from: sent.payload).displayName == "やまねこ ⛷")
    #expect(!viewModel.setLocalDisplayName("\n"))
    #expect(!viewModel.setLocalDisplayName(String(repeating: "あ", count: 110)))
    #expect(viewModel.localMemberIdentity.displayName == "やまねこ ⛷")
    let suite = "RideIntercom.Tests.Name." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = UserDefaultsLocalMemberIdentityStore(defaults: defaults)
    let id = store.loadOrCreate().memberID
    store.saveDisplayName("山ねこ")
    let restored = UserDefaultsLocalMemberIdentityStore(defaults: defaults).loadOrCreate()
    #expect(restored.memberID == id && restored.displayName == "山ねこ")
  }

  @Test func choosingANameIsRememberedApartFromTheDefaultName() throws {
    let suite = "RideIntercom.Tests.NameChoice." + UUID().uuidString
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let fresh = UserDefaultsLocalMemberIdentityStore(defaults: defaults).loadOrCreate()
    #expect(fresh.displayName == "You" && !fresh.hasChosenName, "The default name is not a choice")
    #expect(!UserDefaultsLocalMemberIdentityStore(defaults: defaults).loadOrCreate().hasChosenName)
    UserDefaultsLocalMemberIdentityStore(defaults: defaults).saveDisplayName("ナオ")
    #expect(UserDefaultsLocalMemberIdentityStore(defaults: defaults).loadOrCreate().hasChosenName)

    let legacySuite = suite + ".Legacy"
    let legacy = try #require(UserDefaults(suiteName: legacySuite))
    defer { legacy.removePersistentDomain(forName: legacySuite) }
    legacy.set("member-legacy", forKey: "RideIntercom.localMemberID")
    legacy.set("やまねこ", forKey: "RideIntercom.localDisplayName")
    #expect(
      UserDefaultsLocalMemberIdentityStore(defaults: legacy).loadOrCreate().hasChosenName,
      "A name saved before this flag existed counts as chosen")
  }

  @Test func viewModelAsksForANameUntilOneIsSaved() {
    let harness = AppTestSupport.makeHarness()
    let viewModel = harness.viewModel
    #expect(viewModel.needsDisplayNameChoice)
    #expect(!viewModel.setLocalDisplayName(" "))
    #expect(viewModel.needsDisplayNameChoice)
    #expect(viewModel.setLocalDisplayName("ナオ"))
    #expect(!viewModel.needsDisplayNameChoice)
  }

  @Test func personalNameAndLocalOverrideSurviveRestartAndResetFollowsLatestName() throws {
    let fixture = try GroupStorageFixture()
    defer { fixture.remove() }
    let group = try IntercomGroup(
      name: "Friends",
      members: [.init(id: "local", displayName: "You"), .init(id: "rider", displayName: "山田")])
    try fixture.repository.save(
      [group], credential: .init(groupID: group.id, secret: "key"),
      acceptedInvitation: testAcceptedInvitation(groupID: group.id, inviter: group.members[1]))
    let id = try #require(fixture.repository.users.first).id
    try fixture.repository.renameUser(id, displayName: "スキー仲間")
    try fixture.repository.receiveProfile(
      testVerifiedPeerProfile(groupID: group.id, memberID: "rider", displayName: "やまだ"))
    let restarted = fixture.restart()
    _ = try restarted.load(localMemberID: "local")
    #expect(restarted.users.first?.displayName == "やまだ")
    #expect(restarted.users.first?.resolvedDisplayName == "スキー仲間")
    try restarted.resetUserName(id)
    #expect(restarted.users.first?.resolvedDisplayName == "やまだ")
    try restarted.receiveProfile(
      testVerifiedPeerProfile(groupID: group.id, memberID: "rider", displayName: "やまちゃん"))
    #expect(restarted.users.first?.resolvedDisplayName == "やまちゃん")
    #expect(
      try fixture.restart().load(localMemberID: "local").first?.members.last?.resolvedDisplayName
        == "やまちゃん")
  }

  @Test func groupOnlyNamesStayInTheirGroupAndNeverBecomeContacts() throws {
    let harness = AppTestSupport.makeHarness(groups: [])
    let viewModel = harness.viewModel
    #expect(viewModel.createTalkGroup())
    defer { viewModel.disconnect() }
    let group = try #require(viewModel.groups.first)
    viewModel.selectGroup(group)
    harness.callSession.authenticate(["stranger"])
    let profile = try testPeerProfile(viewModel, peerID: "stranger", displayName: "さくら")
    viewModel.receiveSharedDisplayName(
      peerID: "stranger",
      message: .init(
        namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(profile)))
    #expect(viewModel.renameGroupMember("stranger", in: group.id, displayName: "今日の仲間"))
    let member = try #require(
      viewModel.groups.first { $0.id == group.id }?.members.first { $0.id == "stranger" })
    #expect(member.displayName == "さくら" && member.resolvedDisplayName == "今日の仲間")
    #expect(viewModel.savedUsers.isEmpty)
    #expect(viewModel.resetGroupMemberName("stranger", in: group.id))
    #expect(
      viewModel.groups.first { $0.id == group.id }?.members.first { $0.id == "stranger" }?
        .resolvedDisplayName == "さくら")
  }

  @Test func unauthenticatedWrongGroupAndInvalidNamesCannotChangeSavedNames() throws {
    let harness = AppTestSupport.makeHarness()
    let viewModel = harness.viewModel
    defer { viewModel.disconnect() }
    let group = try #require(viewModel.groups.first)
    viewModel.selectGroup(group)
    func deliver(groupID: UUID, name: String) throws {
      let profile = try SharedDisplayName.make(
        groupID: groupID, recipientMemberID: viewModel.localMemberIdentity.memberID,
        challenge: viewModel.peerProfiles["member-108"]?.challenge ?? UUID(), revision: 1,
        displayName: name, signer: testIdentitySigner("member-108"))
      viewModel.receiveSharedDisplayName(
        peerID: "member-108",
        message: .init(
          namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(profile)))
    }
    try deliver(groupID: group.id, name: "unauthenticated")
    harness.callSession.authenticate(["member-108"])
    let before = viewModel.groups
    try deliver(groupID: UUID(), name: "wrong-group")
    try deliver(groupID: group.id, name: "bad\u{0001}name")
    #expect(viewModel.groups == before)
    #expect(!viewModel.groups.flatMap(\.members).contains { $0.displayName == "unauthenticated" })
  }

  @Test func invitationCarriesOnlyTheAuthorsNameAndProtectsItAgainstEditing() throws {
    let harness = AppTestSupport.makeHarness()
    let viewModel = harness.viewModel
    defer { viewModel.disconnect() }
    viewModel.selectGroup(try #require(viewModel.groups.first))
    #expect(viewModel.setLocalDisplayName("雪 | ねこ"))
    let url = try #require(viewModel.makeSelectedGroupInviteURL())
    let invite = try GroupInviteTokenCodec.decodeJoinURL(url)
    #expect(invite.inviterDisplayName == "雪 | ねこ")
    let receiver = AppTestSupport.makeHarness(groups: [])
    defer { receiver.viewModel.disconnect() }
    try receiver.viewModel.acceptInviteURL(url)
    #expect(receiver.viewModel.savedUsers.first?.displayName == "雪 | ねこ")
    let data = try JSONEncoder().encode(invite)
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["inviterDisplayName"] = "spoofed"
    let changed = try JSONDecoder().decode(
      GroupInviteToken.self, from: JSONSerialization.data(withJSONObject: object))
    #expect(!changed.verifySignature())
  }

  @Test func nameWriteFailurePreservesBothNamesAndExistingGroup() throws {
    let fixture = try GroupStorageFixture()
    defer { fixture.remove() }
    let group = try IntercomGroup(
      name: "Friends",
      members: [.init(id: "local", displayName: "You"), .init(id: "rider", displayName: "Rider")])
    try fixture.repository.save(
      [group], credential: .init(groupID: group.id, secret: "key"),
      acceptedInvitation: testAcceptedInvitation(groupID: group.id, inviter: group.members[1]))
    let before = try Data(contentsOf: fixture.file.url)
    let users = fixture.repository.users
    fixture.store.failCommit = true
    #expect(throws: (any Error).self) {
      try fixture.repository.renameUser(users[0].id, displayName: "Alias")
    }
    #expect(fixture.repository.users == users)
    #expect(try Data(contentsOf: fixture.file.url) == before)
  }
}
