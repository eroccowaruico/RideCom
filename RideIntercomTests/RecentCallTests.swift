import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor
struct RecentCallTests {
    @Test func onlyVerifiedConnectedCallsUpdateHistoryAndGroupPeersStayPrivate() async throws {
        let settings = InMemoryAppSettingsStore()
        let harness = AppTestSupport.makeHarness(appSettingsStore: settings); let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let first = viewModel.groups[0], second = viewModel.groups[1]
        #expect(viewModel.startCall(to: .group(first.id), accountAccessID: viewModel.accountAccessID))
        #expect(viewModel.recentCallDestination == nil)
        harness.callSession.authenticate(["member-108"])
        #expect(viewModel.recentCallDestination == nil)
        try await prove("member-108", in: harness)
        #expect(viewModel.recentCallDestination == .group(first.id))
        #expect(settings.load().recentCallDestination == .group(first.id))
        #expect(viewModel.savedRemoteUsers.isEmpty)
        viewModel.selectGroup(second)
        #expect(viewModel.recentCallDestination == .group(first.id))
        #expect(viewModel.startCall(to: .group(second.id), accountAccessID: viewModel.accountAccessID))
        #expect(viewModel.recentCallDestination == .group(first.id))
        harness.callSession.authenticate(["member-215"]); try await prove("member-215", in: harness)
        #expect(viewModel.recentCallDestination == .group(second.id))
        #expect(viewModel.recentCallTitle == second.name && viewModel.savedRemoteUsers.isEmpty)
    }

    @Test func directCallRemembersTheSavedUserAndDeletionEndsTheCall() async throws {
        let settings = InMemoryAppSettingsStore()
        let harness = AppTestSupport.makeHarness(appSettingsStore: settings); let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let group = viewModel.groups[0]
        let token = try GroupInviteToken.make(
            authority: testInvitationAuthority(), signer: testIdentitySigner("friend"),
            credential: .init(groupID: group.id, secret: "group-key"), groupName: group.name, inviterMemberID: "friend")
        try viewModel.acceptInviteURL(GroupInviteTokenCodec.joinURL(for: token))
        let user = try #require(viewModel.savedRemoteUsers.first)
        #expect(viewModel.startCall(to: .user(user.id), accountAccessID: viewModel.accountAccessID))
        harness.callSession.authenticate(["friend"]); try await prove("friend", in: harness)
        #expect(viewModel.recentCallDestination == .user(user.id))
        #expect(viewModel.renameSavedUser(user.id, displayName: "Nickname"))
        #expect(viewModel.recentCallTitle == "Nickname")
        let call = viewModel.currentCallReference
        #expect(viewModel.removeSavedUser(user.id))
        #expect(viewModel.recentCallDestination == nil && settings.load().recentCallDestination == nil)
        let owner = AppCallOwner(account: viewModel.accountSession, viewModel: viewModel)
        await #expect(throws: CallIntentError.self) {
            try await owner.performCallSurfaceAction(.recent, reference: nil)
        }
        #expect(viewModel.activeGroupID == nil && !viewModel.endCall(call))
    }

    @Test func mediaFailureDoesNotRecordUntilTheVerifiedCallRecovers() async throws {
        let harness = AppTestSupport.makeHarness(); let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let group = viewModel.groups[0]
        harness.inputBackend.startError = NSError(domain: "RecentCallTest", code: 1)
        viewModel.selectGroup(group); harness.callSession.authenticate(["member-108"])
        let proof = try testPeerProfile(viewModel, peerID: "member-108", displayName: "Friend")
        viewModel.handleTransportEvent(.receivedApplicationData(peerID: "member-108",
            message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(proof))))
        #expect(viewModel.peerProfiles["member-108"]?.verified != nil)
        #expect(!viewModel.isAudioReady && viewModel.recentCallDestination == nil)
        await AppTestSupport.waitUntil { viewModel.audioErrorMessage != nil }
        harness.inputBackend.startError = nil
        viewModel.startAudioPipelineIfNeeded()
        await AppTestSupport.waitUntil { viewModel.isAudioReady }
        #expect(viewModel.isAudioReady)
        #expect(viewModel.recentCallDestination == .group(group.id))
    }

    @Test func unreadableGroupsAtLaunchDoNotEraseTheStoredDestination() {
        let group = IntercomSeedData.recentGroups[0]
        let settings = InMemoryAppSettingsStore(settings: .init(recentCallDestination: .group(group.id)))
        let groups = InMemoryGroupStore(groups: [group])
        groups.readError = IntercomGroupError.storageUnavailable
        let harness = AppTestSupport.makeHarness(groupStore: groups, appSettingsStore: settings)
        defer { harness.viewModel.disconnect() }
        #expect(harness.viewModel.recentCallDestination == nil)
        #expect(settings.load().recentCallDestination == .group(group.id))
        groups.readError = nil
        harness.viewModel.reloadSavedGroups()
        #expect(harness.viewModel.recentCallDestination == .group(group.id))
    }

    @Test func settingsChangesAndResetPreserveRecentCallAndRestartUsesItsDestination() async throws {
        let settings = InMemoryAppSettingsStore()
        let harness = AppTestSupport.makeHarness(appSettingsStore: settings); let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let group = viewModel.groups[0]
        viewModel.selectGroup(group); harness.callSession.authenticate(["member-108"])
        try await prove("member-108", in: harness)
        viewModel.setInterfaceMode(.advanced)
        #expect(settings.load().recentCallDestination == .group(group.id))
        viewModel.setVADSensitivity(.noisy)
        #expect(settings.load().interfaceMode == .advanced)
        viewModel.resetAllSettings()
        #expect(settings.load().interfaceMode == .advanced)
        #expect(settings.load().recentCallDestination == .group(group.id))
        let fresh = AppTestSupport.makeHarness(appSettingsStore: settings)
        defer { fresh.viewModel.disconnect() }
        #expect(fresh.viewModel.recentCallDestination == .group(group.id))
        #expect(fresh.viewModel.interfaceMode == .advanced)
        fresh.viewModel.selectGroup(fresh.viewModel.groups[1], connectIfIdle: false)
        let owner = AppCallOwner(account: fresh.viewModel.accountSession, viewModel: fresh.viewModel)
        try await owner.performCallSurfaceAction(.recent, reference: nil)
        #expect(fresh.viewModel.activeGroupID == group.id)
    }

    @Test func failedDeleteAndUnreadableGroupsPreserveHistoryUntilSuccessfulDeletion() async throws {
        let harness = AppTestSupport.makeHarness(); let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let group = viewModel.groups[0]
        viewModel.selectGroup(group); harness.callSession.authenticate(["member-108"])
        try await prove("member-108", in: harness)
        viewModel.disconnect()
        harness.groupStore.failSaving = true
        viewModel.deleteGroup(group.id)
        #expect(viewModel.appSettingsStore.load().recentCallDestination == .group(group.id))
        #expect(viewModel.recentCallDestination == nil)
        harness.groupStore.failSaving = false
        viewModel.reloadSavedGroups()
        #expect(viewModel.recentCallDestination == .group(group.id))
        viewModel.deleteGroup(group.id)
        #expect(
            viewModel.recentCallDestination == nil
                && viewModel.appSettingsStore.load().recentCallDestination == nil)
    }

    @Test func oldLoginCannotReadStartOrReplaceTheRecentDestination() async throws {
        let fixture = AccountFixture(); defer { fixture.remove() }; fixture.signIn()
        let harness = AppTestSupport.makeHarness(accountSession: fixture.session); let viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let first = viewModel.groups[0]
        viewModel.selectGroup(first); harness.callSession.authenticate(["member-108"])
        try await prove("member-108", in: harness)
        let owner = AppCallOwner(account: fixture.session, viewModel: viewModel)
        fixture.session.signOut(); fixture.signIn()
        #expect(viewModel.recentCallDestination == nil && viewModel.recentCallTitle == nil)
        await #expect(throws: CallIntentError.self) {
            try await owner.performCallSurfaceAction(.recent, reference: nil)
        }
        #expect(viewModel.appSettingsStore.load().recentCallDestination == .group(first.id))
    }

    @Test func historyRoundTripsIsAccountScopedAndIsRemovedByAccountErasure() throws {
        let base = "RideIntercom.RecentTests." + UUID().uuidString
        let alice = AppleAccountSession.storageNamespace(base: base, userID: "alice")
        let bob = AppleAccountSession.storageNamespace(base: base, userID: "bob")
        let aliceDefaults = try #require(UserDefaults(suiteName: alice))
        let bobDefaults = try #require(UserDefaults(suiteName: bob))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(base)
        defer {
            aliceDefaults.removePersistentDomain(forName: alice); bobDefaults.removePersistentDomain(forName: bob)
            try? FileManager.default.removeItem(at: root)
        }
        let first = CallDestination.user(UUID()), second = CallDestination.group(UUID())
        UserDefaultsAppSettingsStore(defaults: aliceDefaults).save(.init(recentCallDestination: first))
        UserDefaultsAppSettingsStore(defaults: bobDefaults).save(.init(recentCallDestination: second))
        #expect(UserDefaultsAppSettingsStore(defaults: aliceDefaults).load().recentCallDestination == first)
        #expect(UserDefaultsAppSettingsStore(defaults: bobDefaults).load().recentCallDestination == second)
        try AccountDataEraser(keychain: DictionaryKeychain(), namespace: base, applicationSupport: root).erase(
            userID: "alice")
        #expect(UserDefaultsAppSettingsStore(defaults: aliceDefaults).load().recentCallDestination == nil)
        #expect(UserDefaultsAppSettingsStore(defaults: bobDefaults).load().recentCallDestination == second)
        bobDefaults.set(Data("corrupted".utf8), forKey: "RideIntercom.history.recentCallDestination")
        #expect(UserDefaultsAppSettingsStore(defaults: bobDefaults).load().recentCallDestination == nil)
    }

    private func prove(_ peer: String, in harness: AppTestSupport.Harness) async throws {
        await AppTestSupport.waitUntil { harness.viewModel.isAudioReady }
        let value = try testPeerProfile(harness.viewModel, peerID: peer, displayName: "Friend")
        harness.viewModel.handleTransportEvent(.receivedApplicationData(peerID: peer,
            message: .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(value))))
        #expect(harness.viewModel.peerProfiles[peer]?.verified != nil)
        #expect(harness.viewModel.isAudioReady)
    }
}
