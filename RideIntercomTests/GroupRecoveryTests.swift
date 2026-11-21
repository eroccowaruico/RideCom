import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct GroupRecoveryTests {
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
        let writes = harness.groupStore.saveCount
        viewModel.resetSavedGroups()
        #expect(harness.groupStore.saveCount == writes)
        #expect(harness.groupStore.snapshot.version == 99)
    }
}
