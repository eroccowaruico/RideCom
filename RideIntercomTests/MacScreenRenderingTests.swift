#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import RideIntercom

/// Draws the changed Mac screens in an offscreen window with the real AppKit controls.
/// The PNG attachments are the visual evidence for the Mac layout of each design change.
extension AppTests {
@MainActor
struct MacScreenRenderingTests {
    @Test(arguments: ["en", "ja"]) func usersList(language: String) async throws {
        try await render(.users, language: language)
    }
    @Test(arguments: ["en", "ja"]) func groupsList(language: String) async throws {
        try await render(.groups, language: language)
    }
    @Test(arguments: ["en", "ja"]) func settingsList(language: String) async throws {
        let harness = try AppTestSupport.makeHarnessWithSavedUser(), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        try await record(NavigationStack { SettingsView(viewModel: viewModel) },
                         size: .init(width: 900, height: 1900), language: language, named: "settings")
        try await record(Form {
            StandardInterfaceModeSection(viewModel: viewModel)
            StandardInternetConnectionSection(viewModel: viewModel, isEditing: .constant(false))
        }.formStyle(.grouped), size: .init(width: 600, height: 360), language: language, named: "settings-developer")
        // Standard Audio Check while recording and playing: the state word, the voice indicator, one sentence.
        viewModel.audioCheckPhase = .recording
        viewModel.audioCheckInputLevel = 0.2
        try await record(Form { StandardAudioCheckSection(viewModel: viewModel) }.formStyle(.grouped),
                         size: .init(width: 600, height: 260), language: language, named: "audio-check-recording")
        viewModel.audioCheckPhase = .playing
        viewModel.audioCheckOutputLevel = 0.05
        try await record(Form { StandardAudioCheckSection(viewModel: viewModel) }.formStyle(.grouped),
                         size: .init(width: 600, height: 260), language: language, named: "audio-check-playing")
        viewModel.audioCheckPhase = .idle
        viewModel.setInterfaceMode(.advanced)
        try await record(NavigationStack { SettingsView(viewModel: viewModel) },
                         size: .init(width: 900, height: 2600), language: "en", named: "settings-advanced")
    }
    /// The first screen shows the app icon itself, in each appearance.
    @Test func signIn() async throws {
        let fixture = AccountFixture()
        defer { fixture.remove() }
        for scheme in [ColorScheme.light, .dark] {
            try await record(AppleSignInView(account: fixture.session).environment(\.colorScheme, scheme),
                    size: .init(width: 480, height: 620), language: "ja",
                    named: "sign-in-\(scheme == .dark ? "dark" : "light")")
        }
    }
    @Test(arguments: ["en", "ja"]) func callColumn(language: String) async throws {
        try await render(.call, language: language)
    }

    @Test func diagnosticsOverview() async throws {
        let harness = try AppTestSupport.makeHarnessWithSavedUser(), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let group = try #require(viewModel.regularGroups.first)
        #expect(viewModel.openDestination(.group(group.id)) == .opened)
        try await record(NavigationStack { DiagnosticsView(viewModel: viewModel) },
                         size: .init(width: 520, height: 760), language: "en", named: "diagnostics-overview")
    }

    @Test func diagnosticsNetworkAndApplied() async throws {
        let harness = try AppTestSupport.makeHarnessWithSavedUser(), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
            try await record(
                ScrollView { DiagnosticsNetworkView(viewModel: viewModel).padding() },
                size: .init(width: 520, height: 640),
                         language: "en", named: "diagnostics-network")
            try await record(
                ScrollView { DiagnosticsAppliedView(viewModel: viewModel).padding() },
                size: .init(width: 520, height: 1100),
                         language: "en", named: "diagnostics-applied")
    }

    @Test(arguments: ["en", "ja"])
    func settingsSheets(language: String) async throws {
        let harness = try AppTestSupport.makeHarnessWithSavedUser(), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        let group = try #require(viewModel.regularGroups.first), user = try #require(viewModel.savedRemoteUsers.first)
        try await record(GroupSettingsView(viewModel: viewModel, groupID: group.id),
                         size: .init(width: 480, height: 620),
                         language: language, named: "group-settings")
        try await record(UserSettingsView(viewModel: viewModel, user: user), size: .init(width: 480, height: 560),
                         language: language, named: "user-settings")
        try await record(SavedUsersView(viewModel: viewModel), size: .init(width: 480, height: 560),
                         language: language, named: "new-group")
    }

    /// The lists and the call column as the window lays them out. The root `inspector` itself is
    /// not hosted here: outside a window scene it reports negative geometry even when empty.
    private func render(_ tab: AppTab, language: String) async throws {
        let harness = try AppTestSupport.makeHarnessWithSavedUser(), viewModel = harness.viewModel
        defer { viewModel.disconnect() }
        var selected = tab
        let binding = Binding(get: { selected }, set: { selected = $0 })
        switch tab {
        case .groups:
            try await record(NavigationStack { StandardGroupsView(viewModel: viewModel, selectedTab: binding) },
                             size: .init(width: 900, height: 680), language: language, named: "groups")
        case .call:
            let group = try #require(viewModel.regularGroups.first)
            #expect(viewModel.openDestination(.group(group.id)) == .opened)
            try await record(HStack(spacing: 0) {
                NavigationStack { StandardGroupsView(viewModel: viewModel, selectedTab: binding) }
                Divider()
                CallPanel(viewModel: viewModel, selectedTab: binding) { }.frame(width: 380)
            }, size: .init(width: 1100, height: 720), language: language, named: "call-column")
        default:
            try await record(NavigationStack { StandardUsersView(viewModel: viewModel, selectedTab: binding) },
                             size: .init(width: 900, height: 680), language: language, named: "users")
        }
    }

    private func record(_ view: some View, size: CGSize, language: String, named name: String) async throws {
        // Size the host before it joins the window, so the first layout is the window size
        // rather than zero (a zero-width pass reports negative geometry).
        // Like an app window: titled with a unified toolbar, which the inspector's split view expects.
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.toolbar = NSToolbar()
        window.toolbarStyle = .unified
        let host = NSHostingView(rootView: view.environment(\.locale, Locale(identifier: language)))
        host.frame = CGRect(origin: .zero, size: size)
        window.contentView = host
        window.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(400))
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds), "\(name) has no bitmap")
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0)
        Attachment.record(data, named: "mac-\(name)-\(language).png")
        window.close()
    }
}
}
#endif
