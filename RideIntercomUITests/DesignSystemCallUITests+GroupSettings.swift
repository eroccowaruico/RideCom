#if os(iOS)
import XCTest

extension DesignSystemCallUITests {
    /// Settings open from named, visible entries: the call's settings button (no "…" menu) and a row's swipe.
    /// Invite Members heads the member list. No long-press menus.
    @objc
    @MainActor
    func testGroupSettingsOpenFromTheCallMenuAndTheListRow() {
        defer { attachEvidence("Group settings entries") }
        startStandardCall()
        let renamed = renameGroupFromCall()
        let (row, settings) = openAndCloseSettingsFromGroupRow(named: renamed)
        verifyDeletionConfirmationForLiveGroup(row: row, settings: settings)
    }

    @MainActor private func renameGroupFromCall() -> String {
        XCTAssertFalse(app.buttons["callMoreMenu"].exists, "No More menu in Standard")
        XCTAssertFalse(app.buttons["inviteButton"].exists, "No bare link sharing in the call")
        let invite = app.buttons["addSavedUsersButton"].firstMatch
        XCTAssertTrue(invite.waitForExistence(timeout: 3))
        XCTAssertEqual(invite.label, "Invite Members", "Standard names the intent, not the saved-user mechanism")
        let settingsButton = app.buttons["callGroupSettingsButton"].firstMatch
        XCTAssertTrue(settingsButton.waitForExistence(timeout: 3), "The settings button sits in the toolbar")
        settingsButton.tap()
        XCTAssertTrue(app.descendants(matching: .any)["groupSettingsView"].firstMatch.waitForExistence(timeout: 3))
        // Standard uses the same invitation label in the call and settings. Delete Group comes last.
        XCTAssertEqual(app.buttons["groupSettingsAddMembersButton"].label, "Invite Members")
        XCTAssertEqual(app.buttons["deleteGroupButton"].label, "Delete Group")
        let name = app.textFields["groupSettingsNameField"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        let renamed = "Renamed " + UUID().uuidString.prefix(6)
        let deletion = String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String)?.count ?? 0)
        name.typeText(deletion + renamed)
        app.buttons["saveGroupSettingsButton"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 3))
        let hero = app.descendants(matching: .any)["standardCallHero"].firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 3))
        XCTAssertTrue(hero.label.contains(renamed), "The open call shows the new name: \(hero.label)")
        XCTAssertTrue(app.buttons["standardEndCallButton"].firstMatch.exists, "Renaming keeps the call")
        return renamed
    }

    @MainActor private func openAndCloseSettingsFromGroupRow(named renamed: String) -> (XCUIElement, XCUIElement) {
        openGroups()
        let row = app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "standardGroup-", renamed)
        ).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertTrue(
            row.descendants(matching: .any)["directoryRowCallStatus"].firstMatch.exists
                || app.descendants(matching: .any)["directoryRowCallStatus"].firstMatch.exists,
            "The live call shows on its row"
        )
        XCTAssertFalse(app.buttons["Edit Name"].exists)
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "manageGroup-")).firstMatch.exists
        )
        row.swipeLeft()
        let settings = app.buttons["Group Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Delete"].firstMatch.exists, "The owner's group offers the shared Delete action")
        settings.tap()
        XCTAssertTrue(app.descendants(matching: .any)["groupSettingsView"].firstMatch.waitForExistence(timeout: 3))
        attachEvidence("Group settings from the row")
        app.buttons["closeGroupSettingsButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["groupSettingsView"].firstMatch.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.buttons["callAccessoryOpenButton"].firstMatch.exists, "Settings do not end the call")
        return (row, settings)
    }

    @MainActor private func verifyDeletionConfirmationForLiveGroup(row: XCUIElement, settings: XCUIElement) {
        // The settings entry also asks first; Cancel keeps the group and its call.
        row.swipeLeft()
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()
        let deleteGroup = app.buttons["deleteGroupButton"].firstMatch
        XCTAssertTrue(deleteGroup.waitForExistence(timeout: 3))
        deleteGroup.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        attachEvidence("Delete a live group asks first")
        alert.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        app.buttons["closeGroupSettingsButton"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3), "Cancel keeps the group")
        XCTAssertTrue(app.buttons["callAccessoryOpenButton"].firstMatch.exists, "Cancel keeps the call")
        row.swipeLeft()
        let swipeDelete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(swipeDelete.waitForExistence(timeout: 3))
        swipeDelete.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(alert.staticTexts["The current connection ends."].exists)
        let confirm = alert.buttons["confirmDeleteDestinationButton"].firstMatch
        XCTAssertEqual(confirm.label, "Disconnect and Delete")
        attachEvidence("Swipe deletion of a live group asks first")
        alert.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        XCTAssertTrue(row.exists)
        XCTAssertTrue(app.buttons["callAccessoryOpenButton"].firstMatch.exists)
        row.swipeLeft()
        XCTAssertTrue(swipeDelete.waitForExistence(timeout: 3))
        swipeDelete.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["callAccessoryOpenButton"].firstMatch.exists)
        attachEvidence("Swipe deletion removes the group and ends its call")
    }
}
#endif
