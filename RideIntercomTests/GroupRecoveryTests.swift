import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct GroupRecoveryTests {
    @Test func anotherProcessRecoveringAndSavingAGroupInvalidatesAnOldReset() throws {
        let fixture = try GroupStorageFixture()
        defer { fixture.remove() }
        let corrupt = Data("{".utf8)
        try corrupt.write(to: fixture.file.url)
        #expect(throws: DecodingError.self) { _ = try fixture.repository.load(localMemberID: "local") }

        let second = GroupRepository(store: FileGroupStore(directory: fixture.directory), credentials: fixture.keys)
        #expect(throws: DecodingError.self) { _ = try second.load(localMemberID: "local") }
        try second.reset()
        let group = try fixture.group()
        let credential = GroupAccessCredential(groupID: group.id, secret: "fixture")
        try second.save([group], credential: credential)
        let safe = try Data(contentsOf: fixture.file.url)
        let before = try Set(FileManager.default.contentsOfDirectory(atPath: fixture.directory.path))

        #expect(throws: GroupStorageError.changedByAnotherProcess) { try fixture.repository.reset() }
        #expect(try Data(contentsOf: fixture.file.url) == safe)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: fixture.directory.path)) == before)
        #expect(try second.credential(for: group.id) == credential)
    }

    @Test func commandOverflowShowsCallEntryErrorAfterDisconnect() throws {
        let harness = AppTestSupport.makeHarness()
        let viewModel = harness.viewModel
        viewModel.selectGroup(try #require(viewModel.groups.first))
        viewModel.handleTransportEvent(.commandQueueFailed)
        #expect(viewModel.activeGroupID == nil)
        #expect(viewModel.selectedGroup != nil)
        #expect(viewModel.groupErrorMessage?.contains("connect again") == true)
        viewModel.connectLocal()
        #expect(viewModel.groupErrorMessage == nil)
    }

    @Test func oldResetPromptsToReloadAndKeepsTheCurrentCallAndSavedGroups() throws {
        let harness = AppTestSupport.makeHarness()
        let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        viewModel.selectGroup(try #require(viewModel.groups.first))
        let current = try #require(viewModel.activeGroupID)
        let saved = harness.groupStore.snapshot
        viewModel.groupStorageIssue = .corrupted
        viewModel.resetSavedGroups()
        #expect(viewModel.activeGroupID == current)
        #expect(viewModel.groupStorageIssue == .unavailable)
        #expect(harness.groupStore.snapshot == saved)
        viewModel.disconnect()
        viewModel.reloadSavedGroups()
        #expect(viewModel.groupStorageIssue == nil)
        #expect(viewModel.groups.map(\.id) == saved.groups.map(\.id))
    }

    @Test func reloadPreservesActiveCallAndRecoversAfterTransientFailure() throws {
        let harness = AppTestSupport.makeHarness()
        let viewModel = harness.viewModel
        viewModel.selectGroup(try #require(viewModel.groups.first))
        let active = try #require(viewModel.activeGroupID)
        harness.groupStore.readError = IntercomGroupError.storageUnavailable
        viewModel.reloadSavedGroups()
        #expect(viewModel.activeGroupID == active)
        #expect(viewModel.groupStorageIssue == nil)
        viewModel.disconnect()
        viewModel.reloadSavedGroups()
        #expect(viewModel.groupStorageIssue == .unavailable)
        #expect(!viewModel.canEditSavedGroups)
        let original = harness.groupStore.snapshot
        viewModel.createTalkGroup()
        #expect(harness.groupStore.snapshot == original)
        harness.groupStore.readError = nil
        viewModel.reloadSavedGroups()
        #expect(viewModel.groupStorageIssue == nil)
        #expect(viewModel.canEditSavedGroups)
        #expect(viewModel.groups.map(\.id) == original.groups.map(\.id))
    }

    @Test func resetEndsCallAndClearsOnlyGroupsWhileFutureSchemaRefusesIt() throws {
        let settings = AppSettings(preferredTransmitCodec: .opus)
        let settingsStore = InMemoryAppSettingsStore(settings: settings)
        let keychain = InternetTestKeychain()
        let internetStore = InternetConnectionSettingsStore(keychain: keychain)
        let internet = RTC.CloudflareRealtimeConfiguration(
            workerURL: URL(string: "https://fixture.invalid")!, accessToken: "fixture")
        try internetStore.save(url: internet.workerURL.absoluteString, token: internet.accessToken)
        let harness = AppTestSupport.makeHarness(appSettingsStore: settingsStore, internetSettingsStore: internetStore)
        let viewModel = harness.viewModel
        let identity = viewModel.localMemberIdentity
        viewModel.selectGroup(try #require(viewModel.groups.first))
        harness.groupStore.snapshot.groups[0].lastSponsoredStart = -1
        viewModel.groupStorageIssue = .corrupted
        viewModel.resetSavedGroups()
        #expect(viewModel.activeGroupID == nil)
        #expect(viewModel.groups.isEmpty)
        #expect(harness.groupStore.snapshot.groups.isEmpty)
        #expect(viewModel.localMemberIdentity == identity)
        #expect(settingsStore.load() == settings)
        #expect(try internetStore.load() == internet)
        harness.groupStore.snapshot.version = 99
        viewModel.reloadSavedGroups()
        #expect(viewModel.groupStorageIssue == .unsupportedVersion)
        #expect(throws: GroupStorageError.unsupportedVersion) { try viewModel.groupRepository.reset() }
        let writes = harness.groupStore.saveCount
        viewModel.resetSavedGroups()
        #expect(harness.groupStore.saveCount == writes)
        #expect(harness.groupStore.snapshot.version == 99)
    }
}
