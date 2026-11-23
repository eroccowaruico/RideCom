import AppIntents
import CallControl
import Foundation
import Testing

@testable import RideIntercom

@MainActor @Suite(.serialized)
struct WidgetDestinationTests {
  private func temporaryFile() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "WidgetDestinations-\(UUID())", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appending(path: "destinations.json")
  }

  @Test func snapshotQueryReadsOnlyValidCurrentProjectionAndRecoversAfterCorruption() async throws {
    let file = try temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = WidgetDestinationStore(fileURL: file)
    let item = WidgetCallDestination(id: "scope|user|\(UUID())", name: "Friend", kind: .user)
    try store.write([item])
    let query = WidgetCallDestinationQuery(store: store)
    #expect(try await query.suggestedEntities() == [item])
    #expect(try await query.entities(for: ["old"]).isEmpty)
    #expect(try await query.entities(matching: "friend") == [item])
    let renamed = WidgetCallDestination(id: item.id, name: "New name", kind: .user)
    try store.write([renamed])
    #expect(store.readSnapshot()?.destinations.first { $0.id == item.id } == renamed)
    try store.write([])
    #expect(store.readSnapshot()?.destinations.first { $0.id == item.id } == nil)
    try Data("broken".utf8).write(to: file)
    #expect(store.readSnapshot()?.destinations.first { $0.id == item.id } == nil)
    #expect(try await query.suggestedEntities().isEmpty)
    try store.write([item])
    #expect(try await query.entities(for: [item.id]) == [item])
    let json = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    #expect(Set(json.keys) == ["version", "destinations"])
    let entries = try #require(json["destinations"] as? [[String: Any]])
    #expect(Set(entries[0].keys) == ["id", "name", "kind"])
  }

  /// A Widget or Control added now starts on the previous destination; none when it is gone or unknown.
  @Test func newWidgetsDefaultToThePreviousDestination() async throws {
    let file = try temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = WidgetDestinationStore(fileURL: file)
    let user = WidgetCallDestination(id: "scope|user|\(UUID())", name: "Friend", kind: .user)
    let group = WidgetCallDestination(id: "scope|group|\(UUID())", name: "Riders", kind: .group)
    let query = WidgetCallDestinationQuery(store: store)
    try store.write(.init(destinations: [user, group], recentDestinationID: group.id))
    #expect(await query.defaultResult() == group)
    try store.write(.init(destinations: [user], recentDestinationID: group.id))
    #expect(await query.defaultResult() == nil, "A removed destination is not the default")
    // A snapshot written before the field existed still decodes, with no default.
    try Data(
      #"{"version":1,"destinations":[{"id":"\#(user.id)","name":"Friend","kind":"user"}]}"#.utf8
    ).write(to: file)
    #expect(store.readSnapshot()?.destinations == [user])
    #expect(await query.defaultResult() == nil)
  }

  @Test func ownerPublishesCurrentSavedTargetsAndClearsAfterSignOut() async throws {
    let file = try temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = WidgetDestinationStore(fileURL: file),
      account = AccountFixture()
    defer { account.remove() }
    account.signIn()
    let harness = AppTestSupport.makeHarness(accountSession: account.session),
      viewModel = harness.viewModel
    defer { viewModel.disconnect() }
    let owner = AppCallOwner(
      account: account.session, viewModel: viewModel, widgetDestinationStore: store)
    #expect(store.read().count == viewModel.regularGroups.count)
    let first = try #require(store.read().first)
    viewModel.deleteGroup(viewModel.regularGroups[0].id)
    await AppTestSupport.waitUntil { !store.read().contains(where: { $0.id == first.id }) }
    account.session.signOut()
    await AppTestSupport.waitUntil { store.read().isEmpty }
    #expect(store.read().isEmpty)
    account.signIn()
    #expect(owner.callTargets.isEmpty)
    #expect(throws: CallIntentError.self) { try owner.startWidgetCall(id: first.id) }
  }

  @Test func selectedIntentRechecksOwnerRejectsOldOrDeletedTargetAndDoesNotSwitchCalls()
    async throws {
    let harness = AppTestSupport.makeHarness(), viewModel = harness.viewModel
    defer { viewModel.disconnect() }
    let owner = AppCallOwner(account: viewModel.accountSession, viewModel: viewModel)
    let ids = owner.callTargets.map(\.entity.id)
    let start = OpenCallControlIntent(destinationID: ids[0])
    start.actions = owner
    _ = try await start.perform()
    let reference = viewModel.currentCallReference
    let other = OpenCallControlIntent(destinationID: ids[1])
    other.actions = owner
    await #expect(throws: CallIntentError.self) { _ = try await other.perform() }
    #expect(viewModel.currentCallReference == reference)
    viewModel.disconnect()
    viewModel.deleteGroup(viewModel.groups[0].id)
    await #expect(throws: CallIntentError.self) { _ = try await start.perform() }
    let foreign = AppTestSupport.makeHarness(localMemberID: "foreign")
    defer { foreign.viewModel.disconnect() }
    start.actions = AppCallOwner(
      account: foreign.viewModel.accountSession, viewModel: foreign.viewModel)
    await #expect(throws: CallIntentError.self) { _ = try await start.perform() }
  }

  @Test func projectionIncludesOnlySavedUsersAndDeletionEndsTheirCall() async throws {
    let file = try temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let harness = AppTestSupport.makeHarness(), viewModel = harness.viewModel
    defer { viewModel.disconnect() }
    let store = WidgetDestinationStore(fileURL: file)
    let owner = AppCallOwner(
      account: viewModel.accountSession, viewModel: viewModel, widgetDestinationStore: store)
    #expect(store.read().allSatisfy { $0.kind == .group })
    let group = viewModel.groups[0]
    let token = try GroupInviteToken.make(
      authority: testInvitationAuthority(), signer: testIdentitySigner("friend"),
      credential: .init(groupID: group.id, secret: "group-key"), groupName: group.name, inviterMemberID: "friend")
    try viewModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
    let user = try #require(viewModel.savedRemoteUsers.first)
    await AppTestSupport.waitUntil { store.read().contains(where: { $0.kind == .user }) }
    let selected = try #require(store.read().first(where: { $0.kind == .user }))
    #expect(store.read().filter { $0.kind == .user }.count == 1)
    viewModel.disconnect()
    try owner.startWidgetCall(id: selected.id)
    let reference = try #require(owner.currentLivePresentation?.reference)
    await AppTestSupport.waitUntil { store.readSnapshot()?.currentCall?.reference == reference }
    #expect(store.readSnapshot()?.currentDestinationID == selected.id)
    #expect(viewModel.removeSavedUser(user.id))
    await AppTestSupport.waitUntil { !store.read().contains(where: { $0.id == selected.id }) }
    #expect(store.readSnapshot()?.destinations.first { $0.id == selected.id } == nil)
    #expect(store.readSnapshot()?.currentDestinationID == nil)
    #expect(throws: CallIntentError.self) { try owner.startWidgetCall(id: selected.id) }
    #expect(viewModel.activeGroupID == nil)
    #expect(throws: (any Error).self) {
      try owner.performCallSurfaceAction(.end, reference: reference)
    }
  }

  @Test func failedPublicationCanRetryAndUnchangedSuccessDoesNotReload() throws {
    let file = try temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = WidgetDestinationStore(fileURL: file)
    var reloads: [CallSurfaceKind] = []
    var snapshotsAtReload: [WidgetDestinationSnapshot?] = []
    #if os(iOS)
    let expectedKinds: [CallSurfaceKind] = [.selectedWidget, .destinationControl]
    #else
    let expectedKinds: [CallSurfaceKind] = [.selectedWidget]
    #endif
    let publisher = WidgetDestinationPublisher(store: store) { kind in
      reloads.append(kind)
      snapshotsAtReload.append(store.readSnapshot())
    }
    let item = WidgetCallDestination(id: "scope|group|\(UUID())", name: "Ride", kind: .group)
    let recent = WidgetCallDestination(id: "scope|user|\(UUID())", name: "Friend", kind: .user)
    let call = CallLivePresentation(
      reference: .init(accountAccessID: UUID(), connectionGeneration: UUID(), groupID: UUID()),
      status: .inCall, isMuted: true)
    let snapshot = WidgetDestinationSnapshot(
      destinations: [item, recent], currentDestinationID: item.id, currentCall: call,
      recentDestinationID: recent.id)
    publisher.publish(snapshot)
    #expect(store.readSnapshot() == snapshot)
    publisher.publish(snapshot)
    #expect(reloads == expectedKinds)
    #expect(snapshotsAtReload == Array(repeating: snapshot, count: expectedKinds.count))
    try Data("broken".utf8).write(to: file)
    publisher.publish(snapshot)
    #expect(store.readSnapshot() == snapshot)
    #expect(reloads == expectedKinds + expectedKinds)
    #expect(snapshotsAtReload == Array(repeating: snapshot, count: reloads.count))
    let idle = WidgetDestinationSnapshot(destinations: [item, recent], recentDestinationID: recent.id)
    publisher.publish(idle)
    #expect(store.readSnapshot() == idle)
    #expect(Array(reloads.suffix(expectedKinds.count)) == expectedKinds)
    #expect(snapshotsAtReload.suffix(expectedKinds.count).allSatisfy { $0 == idle })
    reloads.removeAll()
    snapshotsAtReload.removeAll()
    let oversized = WidgetCallDestination(id: item.id, name: String(repeating: "X", count: 1_048_577), kind: .group)
    publisher.publish(.init(destinations: [oversized]))
    #expect(reloads == expectedKinds)
    #expect(snapshotsAtReload == Array(repeating: nil, count: expectedKinds.count))
    #expect(!FileManager.default.fileExists(atPath: file.path))
    let empty = WidgetDestinationSnapshot(destinations: [])
    publisher.publish(empty)
    #expect(store.readSnapshot() == empty)
    #expect(reloads == expectedKinds + expectedKinds)
    #expect(snapshotsAtReload.suffix(expectedKinds.count).allSatisfy { $0 == empty })
  }

  @Test func selectedWidgetShowsCurrentControlsOnlyForItsConfiguredDestination() throws {
    let file = try temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = WidgetDestinationStore(fileURL: file)
    let configured = WidgetCallDestination(id: "scope|group|\(UUID())", name: "Ride", kind: .group)
    let other = WidgetCallDestination(id: "scope|group|\(UUID())", name: "Other", kind: .group)
    let call = CallLivePresentation(
      reference: .init(accountAccessID: UUID(), connectionGeneration: UUID(), groupID: UUID()),
      status: .inCall, isMuted: false)
    try store.write(
      .init(
        destinations: [configured, other], currentDestinationID: configured.id, currentCall: call))
    #expect(store.readSnapshot()?.currentCall(for: configured) == call)
    #expect(store.readSnapshot()?.currentCall(for: other) == nil)
    #expect(store.readSnapshot()?.currentCall(for: nil) == nil)
    try store.write(
      .init(destinations: [other], currentDestinationID: configured.id, currentCall: call))
    #expect(store.readSnapshot()?.currentCall(for: configured) == nil)
    let foreign = WidgetCallDestination(
      id: "other-account|group|\(UUID())", name: "Ride", kind: .group)
    try store.write(
      .init(
        destinations: [configured, foreign], currentDestinationID: configured.id, currentCall: call)
    )
    #expect(store.readSnapshot()?.currentCall(for: foreign) == nil)

    let oldFileSnapshot =
      #"{"version":1,"destinations":[{"id":"scope|group|old","name":"Ride","kind":"group"}],"#
      + #""currentCall":{"reference":{"accountAccessID":"00000000-0000-0000-0000-000000000001","#
      + #""connectionGeneration":"00000000-0000-0000-0000-000000000002","#
      + #""groupID":"00000000-0000-0000-0000-000000000003"},"status":"inCall","isMuted":false}}"#
    try Data(oldFileSnapshot.utf8).write(to: file)
    let old = WidgetCallDestination(id: "scope|group|old", name: "Ride", kind: .group)
    #expect(store.readSnapshot()?.currentCall(for: old) == nil)
  }

}

extension WidgetDestinationTests {
  @Test func callProjectionCarriesCurrentReferenceAndExplicitMuteAndClearsAtSignOut() async throws {
    let file = try temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = WidgetDestinationStore(fileURL: file),
      account = AccountFixture()
    defer { account.remove() }
    account.signIn()
    let harness = AppTestSupport.makeHarness(accountSession: account.session),
      viewModel = harness.viewModel
    defer { viewModel.disconnect() }
    let owner = AppCallOwner(
      account: account.session, viewModel: viewModel, widgetDestinationStore: store)
    let selected = try #require(owner.callTargets.first)
    try owner.startWidgetCall(id: selected.entity.id)
    await AppTestSupport.waitUntil { store.readSnapshot()?.currentCall != nil }
    let call = try #require(store.readSnapshot()?.currentCall)
    #expect(call.reference == owner.currentLivePresentation?.reference)
    #expect(store.readSnapshot()?.currentDestinationID == selected.entity.id)
    #expect(call.status == viewModel.callStatus(for: viewModel.activeGroupID))
    #expect(owner.setCallSurfaceMuted(true, reference: call.reference))
    await AppTestSupport.waitUntil { store.readSnapshot()?.currentCall?.isMuted == true }
    #expect(store.readSnapshot()?.currentCall?.reference == call.reference)
    let json = try #require(
      JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    let projected = try #require(json["currentCall"] as? [String: Any])
    #expect(Set(projected.keys) == ["reference", "status", "isMuted", "canControlMicrophone"])
    account.session.signOut()
    await AppTestSupport.waitUntil {
      store.readSnapshot()?.currentCall == nil && store.read().isEmpty
    }
    #expect(store.readSnapshot()?.currentCall == nil)
  }

  @Test func currentTargetProjectionUsesOnlyCurrentTargetsAndOldSnapshotRemainsReadable()
    async throws {
    let file = try temporaryFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let store = WidgetDestinationStore(fileURL: file)
    let group = IntercomSeedData.recentGroups[0]
    let harness = AppTestSupport.makeHarness()
    let viewModel = harness.viewModel
    defer { viewModel.disconnect() }
    let owner = AppCallOwner(
      account: viewModel.accountSession, viewModel: viewModel, widgetDestinationStore: store)
    #expect(store.readSnapshot()?.currentDestinationID == nil)
    viewModel.deleteGroup(group.id)
    await AppTestSupport.waitUntil {
      store.readSnapshot()?.destinations.count == owner.callTargets.count
    }
    let oldFormat = #"{"version":1,"destinations":[]}"#
    try Data(oldFormat.utf8).write(to: file)
    #expect(store.readSnapshot()?.destinations == [])
    #expect(store.readSnapshot()?.currentCall == nil)
    #expect(store.readSnapshot()?.currentDestinationID == nil)
  }
}
