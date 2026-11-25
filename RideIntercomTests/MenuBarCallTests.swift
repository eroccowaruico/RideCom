#if os(macOS)
import CallControl
import Foundation
import Testing
@testable import RideIntercom

@MainActor @Suite(.serialized)
struct MenuBarCallTests {
    @Test func compiledMenuCopyIncludesJapaneseControls() throws {
        let path = try #require(Bundle.main.path(forResource: "ja", ofType: "lproj"))
        let japanese = try #require(Bundle(path: path))
        #expect(japanese.localizedString(
            forKey: "Show call status in the menu bar", value: nil, table: nil) == "メニューバーに通話状態を表示")
        #expect(japanese.localizedString(forKey: "Mute", value: nil, table: nil) == "ミュート")
        #expect(japanese.localizedString(forKey: "Unmute", value: nil, table: nil) == "ミュートを解除")
        #expect(japanese.localizedString(forKey: "No active call", value: nil, table: nil) == "通話していません")
        #expect(japanese.localizedString(forKey: "Open RideCom", value: nil, table: nil) == "RideComを開く")
    }

    @Test func preferenceDefaultsOffAndRoundTripsAlongsideOtherDisplayAndHistory() throws {
        let suite = "RideIntercom.MenuBar.Tests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsAppSettingsStore(defaults: defaults)
        #expect(!store.load().menuBarEnabled)
        var settings = AppSettings(recentCallDestination: .user(UUID()))
        settings.menuBarEnabled = true; settings.liveActivityEnabled = true
        store.save(settings)
        #expect(store.load().menuBarEnabled)
        #expect(store.load().liveActivityEnabled)
        #expect(store.load().recentCallDestination == settings.recentCallDestination)
        settings.menuBarEnabled = false; store.save(settings)
        #expect(!store.load().menuBarEnabled)
    }

    @Test func disablingMenuOrResettingAudioDoesNotEndCallOrErasePreference() throws {
        let store = InMemoryAppSettingsStore()
        let harness = AppTestSupport.makeHarness(appSettingsStore: store), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let owner = AppCallOwner(account: viewModel.accountSession, viewModel: viewModel)
        #expect(!owner.isMenuBarInserted)
        viewModel.setMenuBarEnabled(true)
        #expect(owner.isMenuBarInserted)
        viewModel.selectGroup(viewModel.groups[0])
        let reference = viewModel.currentCallReference
        viewModel.resetAllSettings()
        #expect(store.load().menuBarEnabled)
        #expect(AppTestSupport.makeHarness(appSettingsStore: store).viewModel.menuBarEnabled)
        #expect(viewModel.currentCallReference == reference)
        viewModel.setMenuBarEnabled(false)
        #expect(!owner.isMenuBarInserted)
        #expect(viewModel.currentCallReference == reference)
        #expect(viewModel.hasAnyActiveGroupConnection)
    }

    @Test func capturedMenuActionsUseExplicitMuteAndCannotChangeAnotherCall() async throws {
        let harness = AppTestSupport.makeHarness(), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let owner = AppCallOwner(account: viewModel.accountSession, viewModel: viewModel)
        viewModel.setMenuBarEnabled(true); viewModel.selectGroup(viewModel.groups[0])
        let first = try #require(owner.currentLivePresentation)
        #expect(owner.setCallSurfaceMuted(true, reference: first.reference))
        #expect(owner.setCallSurfaceMuted(true, reference: first.reference))
        #expect(viewModel.isMuted)
        viewModel.selectGroup(viewModel.groups[1]); viewModel.connectLocal()
        let second = try #require(owner.currentLivePresentation)
        #expect(first.reference != second.reference)
        #expect(!owner.setCallSurfaceMuted(false, reference: first.reference))
        #expect(viewModel.isMuted)
        await #expect(throws: CallIntentError.self) {
            try await owner.performCallSurfaceAction(.end, reference: first.reference)
        }
        #expect(owner.currentLivePresentation?.reference == second.reference)
        try await owner.performCallSurfaceAction(.end, reference: second.reference)
        #expect(viewModel.activeGroupID == nil)
        #expect(owner.isMenuBarInserted)
    }

    @Test func signOutRemovesMenuAndOldActionsCannotControlReplacementModel() async throws {
        let account = AccountFixture(); defer { account.remove() }; account.signIn()
        let harness = AppTestSupport.makeHarness(accountSession: account.session), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let owner = AppCallOwner(account: account.session, viewModel: viewModel)
        viewModel.setMenuBarEnabled(true); viewModel.selectGroup(viewModel.groups[0])
        let old = try #require(owner.currentLivePresentation)
        account.session.signOut()
        #expect(!owner.isMenuBarInserted)
        #expect(owner.currentLivePresentation == nil)
        #expect(!owner.setCallSurfaceMuted(true, reference: old.reference))
        account.signIn()
        let next = AppTestSupport.makeHarness(accountSession: account.session).viewModel
        defer { next.disconnect() }
        owner.viewModel = next; next.setMenuBarEnabled(true); next.selectGroup(next.groups[0])
        #expect(owner.isMenuBarInserted)
        #expect(!owner.setCallSurfaceMuted(true, reference: old.reference))
        #expect(!next.isMuted)
        await #expect(throws: CallIntentError.self) {
            try await owner.performCallSurfaceAction(.end, reference: old.reference)
        }
        #expect(next.hasAnyActiveGroupConnection)
    }

    @Test func menuUsesCurrentActiveCallStatusAndDoesNotClaimMediaPreparationIsEstablished() throws {
        let harness = AppTestSupport.makeHarness(
            enforceCallAccess: true, callAccessEvaluation: { _ in .init(status: .active) })
        let viewModel = harness.viewModel; defer { viewModel.disconnect() }
        let owner = AppCallOwner(account: viewModel.accountSession, viewModel: viewModel)
        viewModel.setMenuBarEnabled(true); viewModel.selectGroup(viewModel.groups[0])
        harness.callSession.authenticate(["member-108"])
        viewModel.isAudioReady = true
        #expect(!viewModel.callAccessState.isEstablished)
        #expect(owner.currentLivePresentation?.status == .connecting)
        viewModel.selectGroup(viewModel.groups[1], connectIfIdle: false)
        #expect(owner.currentLivePresentation?.status == viewModel.callStatus(for: viewModel.activeGroupID))
        #expect(owner.currentLivePresentation?.reference.groupID == viewModel.activeGroupID)
    }
}
#endif
