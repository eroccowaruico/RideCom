import XCTest

final class StandardInterfaceUITests: XCTestCase {
    private var launchedApp: XCUIApplication?

    var app: XCUIApplication {
        guard let launchedApp else { preconditionFailure("The UI test app has not been launched") }
        return launchedApp
    }

    func prepareApp() {
        launchedApp = XCUIApplication()
    }

    func terminateAppIfLaunched() {
        launchedApp?.terminate()
    }

    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws {
        terminateAppIfLaunched()
        launchedApp = nil
    }

    @MainActor func testStandardAccountWithEightDevicesUsesOneSelectionSlot() throws {
        try multiDeviceGroupSelection(advanced: false)
    }

    @MainActor func testAdvancedAccountWithEightDevicesUsesOneSelectionSlot() throws {
        try multiDeviceGroupSelection(advanced: true)
    }

    @MainActor private func multiDeviceGroupSelection(advanced: Bool) throws {
        let personID = UUID()
        prepareApp()
        app.launchEnvironment = ["RIDEINTERCOM_LOCAL_TESTING": "1", "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in",
            "RIDEINTERCOM_INTERFACE_FIXTURE": advanced ? "advanced" : "standard",
            "RIDEINTERCOM_MEMBER_SELECTION_FIXTURE": personID.uuidString]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); app.activate()
        tab("Groups", id: "groupsTab")
        app.buttons["standardCreateGroupButton"].firstMatch.tap()
        let name = app.textFields["savedUsersGroupNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let generated = try XCTUnwrap(name.value as? String)
        let groupName = "Two people " + String(personID.uuidString.prefix(6))
        name.tap()
        let deletion = String(repeating: XCUIKeyboardKey.delete.rawValue, count: generated.count)
        name.typeText(deletion + groupName + "\n")
        let row = app.buttons["selectUser-" + personID.uuidString].firstMatch
        let form = app.collectionViews.firstMatch
        for _ in 0..<20 where !row.exists || !row.isHittable { form.swipeUp() }
        XCTAssertTrue(row.exists); row.tap()
        let memberCount = NSPredicate(format: "label ENDSWITH %@", " of 8 members including you")
        let count = advanced ? app.staticTexts.matching(memberCount).firstMatch
            : app.staticTexts["memberSelectionCount"]
        for _ in 0..<6 where !count.exists { form.swipeUp() }
        XCTAssertEqual(count.label, advanced ? "2 of 8 members including you" : "2/8 people including you")
        let save = app.buttons["saveUserSelectionButton"]
        XCTAssertTrue(save.isEnabled)
        screenshot("One account with eight devices occupies one group slot")
        save.tap()
        XCTAssertTrue(app.buttons["finishAddingUsersButton"].waitForExistence(timeout: 5))
        app.buttons["finishAddingUsersButton"].tap()
        let settings = app.buttons[advanced ? "callMoreMenu" : "callGroupSettingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        if advanced { app.buttons["callGroupSettingsButton"].tap() }
        let selectedPerson = NSPredicate(format: "label CONTAINS %@", String(personID.uuidString.prefix(6)))
        XCTAssertTrue(app.staticTexts.containing(selectedPerson).firstMatch.exists)
        screenshot("Created group keeps the selected person once")
    }

    @MainActor
    func testInvitationFailureExplainsRecoveryInBothEnglishLayouts() {
        checkInvitationFailure(japanese: false)
    }

    @MainActor
    func testInvitationFailureExplainsRecoveryInBothJapaneseLayouts() {
        checkInvitationFailure(japanese: true)
    }

    @MainActor private func checkInvitationFailure(japanese: Bool) {
        #if os(iOS)
        launch(japanese: japanese)
        let message = japanese
            ? "この招待を確認できませんでした。送信者に新しい招待を依頼してください。"
            : "This invitation could not be verified. Ask the sender for a new invitation."
        let url = URL(string: "rideintercom://join?token=invalid")!
        app.open(url)
        XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 5))
        screenshot("Invitation recovery in Standard")
        tab(japanese ? "設定" : "Settings", id: "settingsTab")
        selectLayout(japanese ? "詳細" : "Advanced")
        // open(URL) may relaunch and reapply the Standard launch fixture.
        // Keep this process and verify the actual Advanced error surface.
        // Without a call, the reason stays on the list instead of an empty call screen.
        tab(japanese ? "ユーザー" : "Users", id: "usersTab")
        XCTAssertFalse(app.descendants(matching: .any)["standardCallScreen"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["groupErrorLabel"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 5))
        screenshot("Invitation recovery in Advanced")
        #endif
    }

    @MainActor
    func launch(
        japanese: Bool = false,
        throttled: Bool = false,
        interface: String = "standard",
        legacyContactInvitation: Bool = false,
        storeCatalog: String? = nil
    ) {
        prepareApp()
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-in"
        app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = interface
        if throttled { app.launchEnvironment["RIDEINTERCOM_INTERNET_ACCOUNT_FIXTURE"] = "throttled" }
        if legacyContactInvitation { app.launchEnvironment["RIDEINTERCOM_LEGACY_CONTACT_INVITATION_FIXTURE"] = "1" }
        if let storeCatalog { app.launchEnvironment["RIDEINTERCOM_STOREKIT_CATALOG_FIXTURE"] = storeCatalog }
        app.launchArguments = [
            "-AppleLanguages", japanese ? "(ja)" : "(en)",
            "-AppleLocale", japanese ? "ja_JP" : "en_US"
        ]
        app.launch(); app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["standardUsersList"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor func tab(_ title: String, id: String) {
        if id == "callTab" { app.openCurrentCall(); return }
        app.closeCallIfOpen()
        let identified = app.buttons[id].firstMatch
        if identified.exists {
            identified.tap()
        } else if app.radioButtons[id].exists {
            app.radioButtons[id].tap()
        } else {
            let button = app.tabBars.buttons[title].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 3)); button.tap()
        }
    }

    @MainActor func selectLayout(_ title: String) {
        let goingAdvanced = title == "Advanced" || title == "詳細"
        XCTAssertTrue(goingAdvanced || title == "Standard" || title == "標準", "Unknown layout: \(title)")
        if goingAdvanced && app.descendants(matching: .any)["settingsScrollView"].firstMatch.exists {
            let more = app.buttons["moreSettingsLink"].firstMatch
            revealStandardSettingsControl(more)
            more.tap()
        }
        let picker = app.descendants(matching: .any)["interfaceModePicker"].firstMatch
        for _ in 0..<6 where !picker.isHittable { app.swipeDown() }
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
        let settings = app.descendants(matching: .any)["settingsScrollView"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Switch returns to Settings")
        if goingAdvanced {
            let picker = app.descendants(matching: .any)["interfaceModePicker"].firstMatch
            XCTAssertTrue(picker.waitForExistence(timeout: 3))
            screenshot("Advanced Settings root after layout switch")
        } else {
            screenshot("Standard Settings root after layout switch")
            revealStandardSettingsControl(app.buttons["moreSettingsLink"].firstMatch)
        }
    }

    @MainActor private func assertPurchasesUnavailable(_ title: String) {
        let status = app.descendants(matching: .any)["purchaseStatus"].firstMatch
        for _ in 0..<5 where !status.exists { app.swipeUp() }
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertTrue(
            status.label.contains(title) || (status.value as? String)?.contains(title) == true
                || status.staticTexts[title].exists,
            status.debugDescription
        )
        XCTAssertFalse(app.buttons["restorePurchases"].exists)
    }

    @MainActor func screenshot(_ title: String) {
        #if os(iOS)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        #else
        let attachment = XCTAttachment(screenshot: app.screenshot())
        #endif
        attachment.name = title; attachment.lifetime = .keepAlways; add(attachment)
    }
}

extension StandardInterfaceUITests {
    @MainActor
    @objc
    func testStandardLayoutKeepsCallAcrossAdvancedSwitchAndPersistsChoice() throws {
        launch()
        XCTAssertFalse(app.tabBars.buttons["Diagnostics"].exists)
        tab("Groups", id: "groupsTab")
        app.buttons["standardCreateGroupButton"].tap()
        let name = app.textFields["savedUsersGroupNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        let entered = (name.value as? String)?.count ?? 0
        let deletion = String(repeating: XCUIKeyboardKey.delete.rawValue, count: entered)
        name.typeText(deletion + "Standard UI " + UUID().uuidString.prefix(6))
        app.buttons["saveUserSelectionButton"].tap()
        XCTAssertTrue(app.buttons["standardEndCallButton"].waitForExistence(timeout: 5))
        let mute = app.buttons["standardMuteButton"].firstMatch
        XCTAssertTrue(mute.waitForExistence(timeout: 3))
        mute.tap()
        XCTAssertTrue(app.staticTexts["standardMuteState"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["standardMuteState"].firstMatch.label, "Muted")
        tab("Settings", id: "settingsTab")
        assertPurchasesUnavailable("Not Available Yet")
        #if os(iOS)
        let liveActivity = app.switches["liveActivityToggle"].firstMatch
        for _ in 0..<6 where !liveActivity.isHittable { app.swipeUp() }
        XCTAssertTrue(liveActivity.waitForExistence(timeout: 3))
        XCTAssertEqual(liveActivity.value as? String, "0")
        liveActivity.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(liveActivity.value as? String, "1")
        liveActivity.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(liveActivity.value as? String, "0")
        #endif
        checkLayoutSwitchKeepsMutedCallAndEndIt()
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "RIDEINTERCOM_INTERFACE_FIXTURE")
        app.launch(); app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["standardUsersList"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["Diagnostics"].exists)
    }

    @MainActor
    private func checkLayoutSwitchKeepsMutedCallAndEndIt() {
        selectLayout("Advanced")
        XCTAssertTrue(app.tabBars.buttons["Diagnostics"].exists || app.buttons["diagnosticsTab"].exists)
        tab("Users", id: "usersTab")
        XCTAssertTrue(app.descendants(matching: .any)["standardUsersList"].firstMatch.waitForExistence(timeout: 3))
        tab("Groups", id: "groupsTab")
        XCTAssertTrue(app.descendants(matching: .any)["standardGroupsList"].firstMatch.waitForExistence(timeout: 3))
        tab("Call", id: "callTab")
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["localMicrophoneStateLabel"].label, "Muted")
        tab("Settings", id: "settingsTab")
        selectLayout("Standard")
        tab("Call", id: "callTab")
        XCTAssertTrue(app.buttons["standardEndCallButton"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["standardMuteState"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["standardMuteState"].firstMatch.label, "Muted")
        XCTAssertTrue(app.sliders["standardVolumeSlider"].exists)
        XCTAssertEqual(app.sliders["standardVolumeSlider"].label, "Volume")
        screenshot("Standard call after switching layouts")
        app.buttons["standardEndCallButton"].tap()
        app.alerts.firstMatch.buttons["standardConfirmEndCallButton"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["standardCallScreen"].firstMatch.waitForNonExistence(timeout: 3),
                      "Ending the call returns to the list")
    }

    @MainActor
    @objc
    func testStandardJapaneseNavigationAndUnconfiguredPurchases() {
        launch(japanese: true)
        // The people list is the first screen; the call is not a tab.
        XCTAssertTrue(app.tabBars.buttons["ユーザー"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.tabBars.buttons["通話"].exists)
        tab("ユーザー", id: "usersTab")
        XCTAssertTrue(app.descendants(matching: .any)["standardUsersList"].firstMatch.waitForExistence(timeout: 3))
        tab("グループ", id: "groupsTab")
        XCTAssertTrue(app.buttons["standardCreateGroupButton"].waitForExistence(timeout: 3))
        screenshot("Japanese groups")
        tab("設定", id: "settingsTab")
        assertPurchasesUnavailable("まだ利用できません")
        XCTAssertTrue(app.staticTexts["購入はまだ利用できません。"].exists)
        screenshot("Japanese settings and unavailable purchases")
    }

    #if os(iOS)
    /// New Group: pick from your users with a check mark, see "n/8", then one action at the bottom.
    @MainActor
    @objc
    func testStandardNewGroupPicksUsersWithOneActionBelow() throws {
        launch()
        let suffix = String(UUID().uuidString.prefix(6))
        let inviterName = "Pick " + suffix
        app.open(try InvitationURLFixture.make(inviter: "ui-pick-" + suffix, sharedName: inviterName, contact: true))
        let accept = app.buttons["acceptContactInvitationButton"].firstMatch
        XCTAssertTrue(accept.waitForExistence(timeout: 5))
        accept.tap()
        XCTAssertTrue(accept.waitForNonExistence(timeout: 5))
        app.buttons["closeContactInvitationButton"].tap()
        tab("Groups", id: "groupsTab")
        app.buttons["standardCreateGroupButton"].firstMatch.tap()
        let groupName = app.textFields["savedUsersGroupNameField"].firstMatch
        XCTAssertTrue(groupName.waitForExistence(timeout: 3))
        let generated = try XCTUnwrap(groupName.value as? String)
        XCTAssertNotNil(generated.range(of: "^Group [A-F0-9]{6}$", options: .regularExpression))
        let chosenName = "Chosen " + suffix
        groupName.tap()
        let deletion = String(repeating: XCUIKeyboardKey.delete.rawValue, count: generated.count)
        groupName.typeText(deletion + chosenName + "\n")
        let row = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                  "selectUser-", inviterName)).firstMatch
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(app.staticTexts["Your Users"].exists)
        for _ in 0..<15 where !row.exists || !row.isHittable { form.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        let editUser = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "editUser-")).firstMatch
        XCTAssertFalse(editUser.exists,
                       "Rows only select; renaming lives in the person's settings")
        let count = app.staticTexts["memberSelectionCount"].firstMatch
        XCTAssertEqual(count.label, "1/8 people including you")
        row.tap()
        XCTAssertEqual(count.label, "2/8 people including you")
        // Updating the selection can scroll the focused name field back into view.
        for _ in 0..<15 where !row.exists || !row.isHittable { form.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertTrue(row.isSelected)
        let action = app.buttons["saveUserSelectionButton"].firstMatch
        XCTAssertEqual(action.label, "Create and Connect")
        XCTAssertTrue(action.isHittable)
        // The primary action spans the sheet's width, not a capsule as wide as its words.
        XCTAssertGreaterThanOrEqual(action.frame.width, app.windows.firstMatch.frame.width - 2 * 16 - 1,
                                    "\(action.frame)")
        for _ in 0..<15 where !groupName.exists { form.swipeDown() }
        XCTAssertEqual(groupName.value as? String, chosenName, "Selecting a person keeps the edited group name")
        screenshot("Standard new group with a user picked")
        action.tap()
        // The same saved target remains visible; sharing is optional.
        XCTAssertTrue(app.staticTexts["groupDeliverySelectionMessage"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["savedInvitationGroupName"].label, chosenName)
        app.buttons["finishAddingUsersButton"].tap()
        XCTAssertTrue(app.buttons["standardEndCallButton"].waitForExistence(timeout: 5))
        checkGroupSettingsCanRemoveMember(inviterName)
    }

    @MainActor
    private func checkGroupSettingsCanRemoveMember(_ inviterName: String) {
        // Group Settings: tapping a member opens their settings, where Remove from Group asks first.
        // No long-press menus: the row's swipe offers Remove, and the settings carry it as a named button.
        app.buttons["callGroupSettingsButton"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["groupSettingsView"].firstMatch.waitForExistence(timeout: 3))
        let member = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                      "groupSettingsMember-", inviterName)).firstMatch
        XCTAssertTrue(member.waitForExistence(timeout: 3))
        let selfRow = app.descendants(matching: .any)["groupSettingsSelf"].firstMatch
        XCTAssertTrue(selfRow.exists, "You come first in the members, as in the call")
        XCTAssertLessThan(selfRow.frame.minY, member.frame.minY)
        XCTAssertFalse(app.staticTexts["Touch and hold a member to rename or remove them."].exists)

        member.swipeLeft()
        let rowRemove = app.buttons["Remove"].firstMatch
        XCTAssertTrue(rowRemove.waitForExistence(timeout: 3))
        let rowConfirmation = app.alerts.firstMatch
        XCTAssertFalse(rowConfirmation.exists)
        XCTAssertTrue(member.exists)
        rowRemove.tap()
        XCTAssertTrue(rowConfirmation.staticTexts["Remove \(inviterName) from the group?"].waitForExistence(timeout: 3))
        rowConfirmation.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(rowConfirmation.waitForNonExistence(timeout: 3))
        XCTAssertTrue(member.exists)

        member.tap()
        let remove = app.buttons["removeGroupMemberButton"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        XCTAssertEqual(remove.label, "Remove from Group")
        // As the design: titled with their name, only your name for them, then Remove from Group.
        XCTAssertTrue(app.navigationBars[inviterName].exists, app.debugDescription)
        XCTAssertEqual(app.textFields["groupMemberNameField"].firstMatch.placeholderValue, inviterName)
        XCTAssertFalse(app.buttons["resetGroupMemberNameButton"].exists, "No Use Shared Name: empty returns to it")
        screenshot("Standard group member settings")
        remove.tap()
        let removal = app.alerts.firstMatch
        XCTAssertTrue(removal.waitForExistence(timeout: 3))
        XCTAssertTrue(removal.staticTexts["Remove \(inviterName) from the group?"].exists, removal.debugDescription)
        removal.buttons["confirmRemoveMemberButton"].firstMatch.tap()
        XCTAssertTrue(member.waitForNonExistence(timeout: 3), "The member leaves the group")
        app.buttons["closeGroupSettingsButton"].tap()
        app.buttons["standardEndCallButton"].tap()
        app.alerts.firstMatch.buttons["standardConfirmEndCallButton"].firstMatch.tap()
    }
    #endif
}
