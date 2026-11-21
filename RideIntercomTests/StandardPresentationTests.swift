import Foundation
import RTC
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct StandardPresentationTests {
    /// Choosing a person connects and the hero keeps the call's own state: a call notification is a courtesy
    /// that never adds a ringing state.
    @Test func choosingAPersonKeepsTheHeroOnTheCallsOwnState() throws {
        let harness = try AppTestSupport.makeHarnessWithSavedUser(), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let user = try #require(viewModel.savedRemoteUsers.first)
        #expect(viewModel.openDestination(.user(user.id)) == .opened)
        #expect(viewModel.selectedGroup?.kind == .direct)
        #expect(viewModel.standardCallStatus == .connecting)
    }

    /// Standard hides Groups until turned on; the choice survives a restart; Advanced always shows Groups.
    @Test func groupsTabStartsHiddenInStandardAndTheChoiceIsSaved() throws {
        let namespace = "RideIntercom.GroupsTab." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: namespace))
        defer { defaults.removePersistentDomain(forName: namespace) }
        let store = UserDefaultsAppSettingsStore(defaults: defaults)
        let harness = AppTestSupport.makeHarness(appSettingsStore: store)
        defer { harness.viewModel.disconnect() }
        #expect(!harness.viewModel.showsGroupsTab && !harness.viewModel.isGroupsTabVisible)
        let groups = harness.viewModel.groups
        harness.viewModel.setShowsGroupsTab(true)
        #expect(harness.viewModel.isGroupsTabVisible && store.load().showsGroupsTab)
        #expect(harness.viewModel.groups == groups, "Showing the tab changes no groups")
        let restarted = AppTestSupport.makeHarness(appSettingsStore: UserDefaultsAppSettingsStore(defaults: defaults))
        defer { restarted.viewModel.disconnect() }
        #expect(restarted.viewModel.isGroupsTabVisible)
        harness.viewModel.setShowsGroupsTab(false)
        harness.viewModel.setInterfaceMode(.advanced)
        #expect(harness.viewModel.isGroupsTabVisible, "Advanced always shows Groups")
    }

    @Test func interfaceChoiceSurvivesRestartAndAudioEditsWithoutChangingCall() throws {
        let namespace = "RideIntercom.StandardUI." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: namespace))
        defer { defaults.removePersistentDomain(forName: namespace) }
        let store = UserDefaultsAppSettingsStore(defaults: defaults)
        let harness = AppTestSupport.makeHarness(appSettingsStore: store)
        defer { harness.viewModel.disconnect() }
        #expect(harness.viewModel.interfaceMode == .standard)
        harness.viewModel.selectGroup(harness.viewModel.groups[0])
        harness.viewModel.setCallMuted(true, for: harness.viewModel.currentCallReference)
        let call = harness.viewModel.currentCallReference
        let selected = harness.viewModel.selectedGroup
        let groups = harness.viewModel.groups
        let users = harness.viewModel.savedUsers
        harness.viewModel.setInterfaceMode(.advanced)
        #expect(harness.viewModel.currentCallReference == call)
        #expect(
            harness.viewModel.selectedGroup == selected && harness.viewModel.groups == groups
                && harness.viewModel.savedUsers == users)
        #expect(harness.viewModel.isMuted)
        harness.viewModel.setVADSensitivity(.noisy)
        #expect(UserDefaultsAppSettingsStore(defaults: defaults).load().interfaceMode == .advanced)
        let restarted = AppTestSupport.makeHarness(appSettingsStore: UserDefaultsAppSettingsStore(defaults: defaults))
        defer { restarted.viewModel.disconnect() }
        #expect(restarted.viewModel.interfaceMode == .advanced)
        harness.viewModel.setInterfaceMode(.standard)
        #expect(harness.viewModel.currentCallReference == call && harness.viewModel.isMuted)
        #expect(store.load().interfaceMode == .standard)
    }

    @Test func invalidPreferenceUsesStandardAndOldAccountCannotChangeIt() throws {
        let namespace = "RideIntercom.StandardUI." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: namespace))
        defer { defaults.removePersistentDomain(forName: namespace) }
        defaults.set("unknown", forKey: "RideIntercom.settings.interfaceMode")
        let store = UserDefaultsAppSettingsStore(defaults: defaults)
        let harness = AppTestSupport.makeHarness(appSettingsStore: store)
        #expect(harness.viewModel.interfaceMode == .standard)
        harness.viewModel.accountSession.signOut()
        harness.viewModel.setInterfaceMode(.advanced)
        #expect(harness.viewModel.interfaceMode == .standard && store.load().interfaceMode == .standard)
    }

    @Test func japaneseResourcesAreBundledWithoutTranslatingPersonalNames() throws {
        let path = try #require(Bundle.main.path(forResource: "ja", ofType: "lproj"))
        let japanese = try #require(Bundle(path: path))
        #expect(japanese.localizedString(forKey: "Choose a User", value: nil, table: nil) == "ユーザーを選ぶ")
        #expect(
            japanese.localizedString(forKey: "Purchases are not available yet.", value: nil, table: nil)
                == "購入はまだ利用できません。")
        let harness = AppTestSupport.makeHarness()
        let group = harness.viewModel.groups[0]
        #expect(harness.viewModel.callTitle(for: group) == group.name)
    }

    @Test func layoutSwitchOnlyRemapsUnavailableTabs() {
        #expect(AppTab.diagnostics.available(in: .standard) == .users)
        #expect(AppTab.users.available(in: .advanced) == .users)
        #expect(AppTab.groups.available(in: .advanced) == .groups)
        #expect(AppTab.users.available(in: .standard) == .users)
        #expect(AppTab.groups.available(in: .standard) == .groups)
        #expect(AppTab.diagnostics.available(in: .advanced) == .diagnostics)
        #expect(AppTab.call.available(in: .standard) == .call)
        #expect(AppTab.call.available(in: .advanced) == .call)
        #expect(AppTab.settings.available(in: .standard) == .settings)
        #expect(AppTab.settings.available(in: .advanced) == .settings)
    }

    @Test func simpleStatusSeparatesSelectionConnectionAndAudioReadiness() throws {
        let harness = AppTestSupport.makeHarness(); defer { harness.viewModel.disconnect() }
        #expect(harness.viewModel.standardCallStatus == .chooseDestination)
        let group = harness.viewModel.groups[0]
        harness.viewModel.selectGroup(group, connectIfIdle: false)
        #expect(harness.viewModel.standardCallStatus == .ready)
        harness.viewModel.startCall(to: .group(group.id), accountAccessID: harness.viewModel.accountAccessID)
        #expect(harness.viewModel.standardCallStatus == .connecting)
        harness.viewModel.authenticatedPeerIDs = ["member-108"]
        #expect(harness.viewModel.standardCallStatus == .connecting)
        harness.viewModel.isAudioReady = true
        #expect(harness.viewModel.standardCallStatus == .connecting)
        harness.callSession.authenticate(["member-108"])
        let profile = try testPeerProfile(harness.viewModel, peerID: "member-108", displayName: "Rider")
        harness.viewModel.receiveSharedDisplayName(peerID: "member-108", message:
            .init(namespace: SharedDisplayName.namespace, payload: try JSONEncoder().encode(profile)))
        #expect(harness.viewModel.standardCallStatus == .inCall)
        harness.viewModel.isAudioPausedForDeviceChange = true
        #expect(harness.viewModel.standardCallStatus == .audioPaused)
        harness.viewModel.isAudioPausedForDeviceChange = false
        harness.viewModel.isAudioReady = false
        harness.viewModel.audioErrorMessage = "Microphone capture failed"
        #expect(harness.viewModel.standardCallStatus == .audioUnavailable)
        harness.viewModel.selectGroup(harness.viewModel.groups[1], connectIfIdle: false)
        #expect(harness.viewModel.standardCallStatus == .ready)
        #expect(harness.viewModel.activeGroupID == group.id)
    }
}
