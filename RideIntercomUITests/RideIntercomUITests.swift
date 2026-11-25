import XCTest

final class RideIntercomUITests: XCTestCase {
    private var launchedApp: XCUIApplication?

    var app: XCUIApplication {
        guard let launchedApp else { preconditionFailure("The UI test app has not been launched") }
        return launchedApp
    }

    override func setUpWithError() throws {
        continueAfterFailure = false

        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        launchApp()
    }

    private func launchApp(startOnDiagnostics: Bool = false) {
        launchedApp = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-in"
        app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = "advanced"
        if name.contains("CorruptGroupStoreRecovery") {
            app.launchEnvironment["RIDEINTERCOM_GROUP_RECOVERY_FIXTURE"] = "prepare:\(UUID())"
        }
        if name.contains("InternetEnrollmentThrottle") {
            app.launchEnvironment["RIDEINTERCOM_INTERNET_ACCOUNT_FIXTURE"] = "throttled"
        }
        if name.contains("InternetCredentialRecovery") {
            app.launchEnvironment["RIDEINTERCOM_INTERNET_ACCOUNT_FIXTURE"] = "credential-recovery"
            if name.contains("StandardInternetCredentialRecovery") {
                app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = "standard"
            }
        }
        if name.contains("AccountReplacement") {
            app.launchEnvironment["RIDEINTERCOM_ACCOUNT_REPLACEMENT_FIXTURE"] = UUID().uuidString
        }
        if name.contains("Adaptive") {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        app.activate()

        if name.contains("AccountReplacement") {
            let resetScreen = app.descendants(matching: .any)["accountDataResetScreen"].firstMatch
            XCTAssertTrue(resetScreen.waitForExistence(timeout: 5))
            return
        }
        XCTAssertTrue(waitForVisibleRoot(in: app), "Expected the app to launch into a visible root screen")
        removeExistingTalkGroups()
        removeExistingSavedUsers()

        if startOnDiagnostics {
            openDiagnosticsTab()
        }
    }

    override func tearDownWithError() throws {
        launchedApp?.terminate()
        launchedApp = nil
    }

    /// The simulator keeps saved riders between runs, and a rider ID seen again with a new
    /// key is an identity conflict. Each test run therefore uses its own rider IDs; within the
    /// run the same inviter keeps one ID and key, so restarts still find the saved rider.
    let inviterRun = UUID().uuidString.prefix(8).lowercased()

    /// Advanced marks the implementation's default in the option's own label.
    let aacELD = "AAC-ELD (Default)"
    let defaultSampleRate = "48 kHz (Default)"
}

extension RideIntercomUITests {
    func attachScreen(_ name: String) {
        #if os(iOS)
        // App-scoped screenshots can crop a rotated sheet using portrait bounds.
        // This is the dedicated test Simulator, so capture its complete screen.
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        #else
        let attachment = XCTAttachment(screenshot: app.screenshot())
        #endif
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = "\(name) accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }

    func showEmptyDiagnostics() {
        openGroupsTab()
        removeExistingTalkGroups()
        openDiagnosticsTab()
    }

    private func openDirectoryTab(_ title: String, identifier: String, root: String) {
        app.closeCallIfOpen()
        if app.descendants(matching: .any)[root].firstMatch.exists { return }
        let identified = app.buttons[identifier].firstMatch
        if identified.exists {
            identified.tap()
        } else if app.radioButtons[identifier].firstMatch.exists {
            app.radioButtons[identifier].firstMatch.tap()
        } else {
            let button = app.tabBars.buttons[title].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            button.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)[root].firstMatch.waitForExistence(timeout: 3))
    }

    /// The count in Advanced Groups' "Direct Groups N" header, scrolled into view.
    /// The section is left out when there are none.
    @MainActor
    func advancedDirectGroupCount() throws -> Int {
        let header = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "Direct Groups ")).firstMatch
        let list = app.descendants(matching: .any)["standardGroupsList"].firstMatch
        for _ in 0..<8 where !header.waitForExistence(timeout: 1) { list.swipeUp() }
        guard header.exists else { return 0 }
        return try XCTUnwrap(Int(header.label.dropFirst("Direct Groups ".count)))
    }

    func openGroupsTab() {
        openDirectoryTab("Groups", identifier: "groupsTab", root: "standardGroupsList")
    }

    func openUsersTab() {
        openDirectoryTab("Users", identifier: "usersTab", root: "standardUsersList")
    }

    func openDiagnosticsTab() {
        app.openDiagnosticsTab()
    }

    func selectDiagnosticsPage(_ title: String) {
        let picker = app.descendants(matching: .any)["diagnosticsPagePicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        XCTAssertTrue(picker.isHittable, picker.debugDescription)
        // Segments are tapped directly; the accessibility-size list opens first.
        let segment = picker.buttons[title].exists ? picker.buttons[title] : picker.radioButtons[title]
        if segment.exists { segment.tap(); return }
        picker.tap()
        let choice = app.buttons[title].firstMatch
        XCTAssertTrue(choice.waitForExistence(timeout: 3), app.debugDescription)
        choice.tap()
    }

    func openSettingsTab() {
        app.closeCallIfOpen()
        let scroll = app.descendants(matching: .any)["settingsScrollView"].firstMatch
        if !scroll.exists {
            #if os(iOS)
            let identified = app.tabBars.buttons["settingsTab"].firstMatch
            let button = identified.exists ? identified : app.tabBars.buttons["Settings"].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 3))
            button.tap()
            #else
            let radio = app.radioButtons["settingsTab"].firstMatch
            if radio.exists { radio.tap() } else {
                let identified = app.buttons["settingsTab"].firstMatch
                let button = identified.exists ? identified : app.tabBars.buttons["Settings"].firstMatch
                XCTAssertTrue(button.waitForExistence(timeout: 3))
                button.tap()
            }
            #endif
        }
        guard scroll.waitForExistence(timeout: 5) else {
            XCTFail("Settings tab did not open"); return
        }
    }

    func selectSettingsLayout(_ title: String) {
        XCTAssertTrue(title == "Standard" || title == "Advanced", "Unknown layout: \(title)")
        let advanced = app.tabBars.buttons["Diagnostics"].exists || app.buttons["diagnosticsTab"].exists
        if !advanced {
            let more = app.buttons["moreSettingsLink"].firstMatch
            revealSettingsControl(more)
            more.tap()
        }
        let picker = app.descendants(matching: .any)["interfaceModePicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        // A segmented picker shows each layout as its own button; a menu needs opening first.
        // Advanced spells the layouts in English only; Standard uses the localized words.
        let names = [title, ["標準": "Standard", "詳細": "Advanced"][title] ?? title]
        let choice = names.lazy.flatMap { [picker.buttons[$0], picker.radioButtons[$0]] }.first { $0.exists }
            ?? picker.buttons[title]
        if choice.exists { choice.tap() } else {
            picker.tap()
            let menu = app.menuItems[title].firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 3)); menu.tap()
        }
        XCTAssertTrue(app.descendants(matching: .any)["settingsScrollView"].firstMatch.waitForExistence(timeout: 5))
    }

    /// Settings is a lazy Form. Navigate to the requested row rather than assuming
    /// every target is near Local Network, or a fixed number of screens from the top.
    func revealSettingsControl(
        _ target: XCUIElement,
        fullyVisible: Bool = true,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let scroll = app.descendants(matching: .any)["settingsScrollView"].firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5), file: file, line: line)
        for attempt in 0..<36 {
            let viewport = scroll.frame.intersection(app.frame).insetBy(dx: 0, dy: 4)
            if target.exists && !target.frame.isEmpty {
                let visible = fullyVisible
                    ? target.isHittable && viewport.contains(target.frame)
                    : viewport.intersects(target.frame)
                if visible { return }
            }
            let hasFrame = target.exists && !target.frame.isEmpty
            let down = hasFrame ? target.frame.midY < viewport.midY : (attempt < 6 || attempt >= 30)
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.3 : 0.7))
            let end = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.7 : 0.3))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
        XCTFail("Settings control did not become reachable: \(target.debugDescription)", file: file, line: line)
    }

    func revealDiagnosticOverview() {
        let scroll = app.descendants(matching: .any)["diagnosticsScrollView"].firstMatch
        for _ in 0..<8 {
            if app.descendants(matching: .any)["diagnosticsStageDots-RX"].exists { return }
            scroll.swipeUp()
        }
    }

    func revealAudioCheckControlsIfNeeded() {
        revealSettingsControl(audioCheckButtonElement())
    }

    func revealSettingsPanelIfNeeded(identifier: String) {
        openSettingsTab()
        let panel = app.descendants(matching: .any)[identifier].firstMatch
        revealSettingsControl(panel, fullyVisible: false)
    }

    func audioCheckButtonElement() -> XCUIElement {
        let byIdentifier = app.descendants(matching: .any)["audioCheckButton"].firstMatch
        if byIdentifier.exists {
            return byIdentifier
        }

        let byLabel = app.buttons["Record 5s and Play"].firstMatch
        if byLabel.exists {
            return byLabel
        }

        return byIdentifier
    }

    func removeExistingTalkGroups() {
        openGroupsTab()

        let groupRows = talkGroupRows
        while groupRows.count > 0 {
            let groupRow = groupRows.firstMatch
            guard groupRow.waitForExistence(timeout: 1) else { return }
            // Rows are lazy: deleting one can load another, so check that this row went away.
            let deleted = groupRow.identifier

            app.removeGroupRow(groupRow)

            XCTAssertTrue(app.buttons[deleted].waitForNonExistence(timeout: 3))
        }
    }

    /// Saved users persist on the reused simulator; start each test from an empty Users list
    /// so queries for "the saved user" find the one this test invited.
    func removeExistingSavedUsers() {
        openUsersTab()
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardUser-"))
        while rows.count > 0 {
            let row = rows.firstMatch
            guard row.waitForExistence(timeout: 1) else { return }
            let deleted = row.identifier
            row.swipeLeft()
            let deleteButton = app.buttons["Delete"].firstMatch
            XCTAssertTrue(deleteButton.waitForExistence(timeout: 2))
            deleteButton.tap()
            app.confirmDestinationDelete()
            XCTAssertTrue(app.buttons[deleted].waitForNonExistence(timeout: 3))
        }
    }

    func waitForVisibleRoot(in app: XCUIApplication) -> Bool {
        app.descendants(matching: .any)["standardUsersList"].firstMatch.waitForExistence(timeout: 3)
            || app.descendants(matching: .any)["callScreen"].firstMatch.exists
            || app.descendants(matching: .any)["standardGroupsList"].firstMatch.exists
            || app.descendants(matching: .any)["standardCallScreen"].firstMatch.exists
    }
}
