import XCTest

final class ContactNameChoiceUITests: XCTestCase {
    private var launchedApp: XCUIApplication?

    private var app: XCUIApplication {
        guard let launchedApp else { preconditionFailure("The app must be launched before interacting with it") }
        return launchedApp
    }

    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { launchedApp?.terminate(); launchedApp = nil }

    @MainActor private func launch(_ id: UUID, japanese: Bool = false, advanced: Bool = false) {
        let app = XCUIApplication()
        launchedApp = app
        app.launchEnvironment = [
            "RIDEINTERCOM_LOCAL_TESTING": "1",
            "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in",
            "RIDEINTERCOM_INTERFACE_FIXTURE": advanced ? "advanced" : "standard",
            "RIDEINTERCOM_CONTACT_NAME_FIXTURE": id.uuidString
        ]
        app.launchArguments = [
            "-AppleLanguages", japanese ? "(ja)" : "(en)", "-AppleLocale", japanese ? "ja_JP" : "en_US"
        ]
        app.launch(); app.activate()
    }
    @MainActor private func row(_ id: UUID) -> XCUIElement { app.buttons["standardUser-" + id.uuidString].firstMatch }
    @MainActor private func findRow(_ id: UUID) {
        let list = app.descendants(matching: .any)["standardUsersList"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 5))
        for _ in 0..<12 where !row(id).isHittable { list.swipeUp() }
        XCTAssertTrue(row(id).isHittable)
    }
    @MainActor private func settings(_ id: UUID) {
        findRow(id)
        let action = app.buttons.matching(NSPredicate(format: "label IN %@", ["User Settings", "相手の設定"])).firstMatch
        for _ in 0..<3 where !action.exists { row(id).swipeLeft(); _ = action.waitForExistence(timeout: 2) }
        XCTAssertTrue(action.exists); action.tap()
        XCTAssertTrue(app.textFields["savedUserNameField"].waitForExistence(timeout: 3))
    }
    @MainActor private func restart() {
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "RIDEINTERCOM_CONTACT_NAME_FIXTURE")
        app.launch(); app.activate()
    }
    @MainActor private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
    @MainActor func testUseTheirNameStaysSavedAfterSaveAndRestart() {
        let id = UUID(), peer = "Maki " + id.uuidString.prefix(6)
        launch(id); settings(id)
        let use = app.buttons["useContactPeerNameButton"].firstMatch
        XCTAssertTrue(use.waitForExistence(timeout: 3))
        use.tap()
        XCTAssertTrue(use.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.textFields["savedUserNameField"].value as? String, peer)
        XCTAssertEqual(app.buttons["closeUserSettingsButton"].label, "Done")
        XCTAssertFalse(app.buttons["saveUserNameButton"].exists, "The name choice is already saved")
        app.textFields["savedUserNameField"].tap()
        app.textFields["savedUserNameField"].typeText(peer)
        XCTAssertTrue(app.buttons["saveUserNameButton"].exists, "Only a new text edit needs Save")
        app.buttons["saveUserNameButton"].tap()
        XCTAssertTrue(app.buttons["saveUserNameButton"].waitForNonExistence(timeout: 3))
        findRow(id)
        XCTAssertTrue(row(id).label.contains(peer))
        restart(); settings(id)
        XCTAssertFalse(use.exists)
        XCTAssertTrue(app.staticTexts["savedUserOriginalName"].label.contains(peer))
        screenshot("Name choice remains resolved after Save and restart")
    }
    @MainActor func testJapaneseKeepChoiceCanBeDeferredAndPersists() {
        let id = UUID(), alias = "A Generated Name " + id.uuidString.prefix(6)
        launch(id, japanese: true); settings(id)
        let keep = app.buttons["keepContactLocalNameButton"].firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 3))
        app.buttons["closeUserSettingsButton"].tap()
        restart(); settings(id)
        XCTAssertTrue(keep.waitForExistence(timeout: 3), "Closing without choosing preserves the pending review")
        XCTAssertEqual(keep.label, "この呼び名を使う")
        screenshot("Japanese name choice explains the old and shared names")
        keep.tap()
        XCTAssertTrue(keep.waitForNonExistence(timeout: 3))
        XCTAssertEqual(app.textFields["savedUserNameField"].value as? String, alias)
        XCTAssertEqual(app.buttons["closeUserSettingsButton"].label, "完了")
        XCTAssertFalse(app.buttons["saveUserNameButton"].exists)
        app.buttons["closeUserSettingsButton"].tap()
        restart(); settings(id)
        XCTAssertFalse(keep.exists)
        XCTAssertEqual(app.textFields["savedUserNameField"].value as? String, alias)
    }
    @MainActor func testAdvancedUnsavedEditAndSharedNameChoiceKeepTheRealState() {
        let id = UUID(), peer = "Maki " + id.uuidString.prefix(6)
        launch(id, advanced: true); settings(id)
        let use = app.buttons["useContactPeerNameButton"].firstMatch
        XCTAssertTrue(use.waitForExistence(timeout: 3))
        let name = app.textFields["savedUserNameField"]
        let old = name.value as? String ?? ""
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + "My edited name")
        XCTAssertFalse(use.exists, "Review does not overwrite an unsaved edit")
        app.buttons["closeUserSettingsButton"].tap(); settings(id)
        XCTAssertTrue(use.waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["contactNameConfirmationNeeded"].label, "true")
        use.tap()
        XCTAssertTrue(use.waitForNonExistence(timeout: 3))
        XCTAssertFalse(app.buttons["resetUserNameButton"].exists, "Following the shared name needs no second reset")
        XCTAssertEqual(app.buttons["closeUserSettingsButton"].label, "Done")
        XCTAssertFalse(app.buttons["saveUserNameButton"].exists)
        name.tap()
        name.typeText(peer)
        app.buttons["saveUserNameButton"].tap()
        restart(); settings(id)
        XCTAssertFalse(use.exists)
        XCTAssertEqual(app.staticTexts["contactNameConfirmationNeeded"].label, "false")
        XCTAssertTrue(row(id).exists || app.staticTexts["savedUserOriginalName"].label.contains(peer))
        screenshot("Advanced name flags follow the persisted choice")
    }
}
