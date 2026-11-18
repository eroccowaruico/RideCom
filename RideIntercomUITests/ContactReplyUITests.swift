#if os(iOS)
import CryptoKit
import XCTest

final class ContactReplyUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { app?.terminate(); app = nil }

    @MainActor private func launch(advanced: Bool = false, japanese: Bool = false) {
        app = XCUIApplication()
        app.launchEnvironment = ["RIDEINTERCOM_LOCAL_TESTING": "1", "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in", "RIDEINTERCOM_INTERFACE_FIXTURE": advanced ? "advanced" : "standard"]
        app.launchArguments = ["-AppleLanguages", japanese ? "(ja)" : "(en)", "-AppleLocale", japanese ? "ja_JP" : "en_US"]
        app.launch(); app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["standardUsersList"].firstMatch.waitForExistence(timeout: 5))
    }
    @MainActor private func settings(_ name: String) {
        let list = app.descendants(matching: .any)["standardUsersList"].firstMatch
        let search = app.searchFields.firstMatch
        if search.exists {
            search.tap()
            let old = search.value as? String ?? ""
            search.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count) + name + "\n")
        }
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "standardUser-", name)).firstMatch
        for _ in 0..<16 {
            if row.exists && row.isHittable && row.frame.maxY < list.frame.maxY - 80 { break }
            list.swipeUp()
        }
        XCTAssertTrue(row.isHittable)
        let action = app.buttons.matching(NSPredicate(format: "label IN %@", ["User Settings", "相手の設定"])).firstMatch
        for _ in 0..<3 where !action.exists { row.swipeLeft(); _ = action.waitForExistence(timeout: 2) }
        XCTAssertTrue(action.exists); action.tap()
        XCTAssertTrue(app.textFields["savedUserNameField"].waitForExistence(timeout: 3))
    }
    @MainActor private func reveal(_ element: XCUIElement, down: Bool = false) {
        for _ in 0..<8 where !element.exists || !element.isHittable {
            if down { app.swipeDown() } else { app.swipeUp() }
        }
        XCTAssertTrue(element.exists)
    }
    @MainActor private func copy() -> XCUIElement {
        app.cells.matching(NSPredicate(format: "label IN %@", ["Copy", "Copy Link", "コピー", "リンクをコピー"])).firstMatch
    }
    @MainActor private func copiedURL() throws -> URL {
        // Use an explicit native Paste action; iOS rejects programmatic clipboard access by a UI-test runner.
        // This is an unsaved input in the isolated validation app and is always cancelled.
        let edit = app.buttons["editContactPersonNameButton"]
        reveal(edit, down: true); edit.tap()
        let field = app.textFields["savedUserNameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        let old = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        field.press(forDuration: 1)
        let predicate = NSPredicate(format: "label IN %@", ["Paste", "ペースト"])
        let menu = app.menuItems.matching(predicate).firstMatch
        let button = app.buttons.matching(predicate).firstMatch
        if menu.waitForExistence(timeout: 2) { menu.tap() }
        else { XCTAssertTrue(button.waitForExistence(timeout: 2)); button.tap() }
        let value = try XCTUnwrap(field.value as? String)
        app.buttons["closeUserSettingsButton"].tap()
        let match = try XCTUnwrap(value.range(of: #"rideintercom://[^\s]+"#, options: .regularExpression))
        return try XCTUnwrap(URL(string: String(value[match])))
    }
    @MainActor private func screenshot(_ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a)
    }
    @MainActor func testJapaneseReplyShareReturnsToSettingsAndConfirmationClearsPending() throws {
        try incoming(japanese: true)
    }
    @MainActor func testAdvancedReplyShareReturnsToSettingsAndConfirmationClearsPending() throws {
        try incoming(advanced: true)
    }
    @MainActor private func incoming(advanced: Bool = false, japanese: Bool = false) throws {
        launch(advanced: advanced, japanese: japanese)
        let suffix = String(UUID().uuidString.prefix(6)), name = "Reply Author " + suffix
        let key = P256.Signing.PrivateKey()
        let invitation = try InvitationURLFixture.make(inviter: "reply-author-" + suffix, sharedName: name, contact: true, signingKey: key)
        app.open(invitation)
        let register = app.buttons["acceptContactInvitationButton"]
        XCTAssertTrue(register.waitForExistence(timeout: 5)); register.tap()
        XCTAssertTrue(app.staticTexts["contactPersonSavedName"].waitForExistence(timeout: 4), "Registration keeps the same sheet open")
        let share = app.buttons["shareContactReplyButton"].firstMatch
        if advanced { reveal(share) }
        XCTAssertTrue(share.waitForExistence(timeout: 4))
        share.tap()
        XCTAssertTrue(copy().waitForExistence(timeout: 5)); copy().tap()
        XCTAssertTrue(copy().waitForNonExistence(timeout: 5))
        let reply = try copiedURL()
        XCTAssertEqual(reply.host, "contact-reply")
        XCTAssertTrue(app.buttons["closeContactInvitationButton"].exists)
        if advanced { reveal(share) }
        XCTAssertTrue(share.exists, "Copying does not claim delivery or close the settings")
        screenshot("Pending reply after native copy in the same settings")
        app.buttons["closeContactInvitationButton"].tap()
        app.terminate(); app.launch(); app.activate(); settings(name)
        if advanced { reveal(share) }
        XCTAssertTrue(share.waitForExistence(timeout: 4))
        let confirmation = try InvitationURLFixture.acknowledgement(reply, signingKey: key)
        app.open(confirmation)
        XCTAssertTrue(share.waitForNonExistence(timeout: 5))
        // URL activation may rebuild the test scene. Verify durable state and avoid opening a second settings sheet.
        let settingsView = app.descendants(matching: .any)["userSettingsView"].firstMatch
        if !settingsView.waitForExistence(timeout: 3) { settings(name) }
        XCTAssertTrue(settingsView.exists)
        if advanced {
            let state = app.staticTexts["contactInvitationField-state"]
            reveal(state)
            XCTAssertEqual(state.label, "delivered")
        }
        XCTAssertFalse(share.exists)
        screenshot("Confirmation clears only the pending delivery")
        app.open(confirmation)
        if !settingsView.waitForExistence(timeout: 3) { settings(name) }
        XCTAssertFalse(share.exists)
    }
    @MainActor func testSharedReplyRegistersTheSameSenderDetailAndOffersConfirmation() throws {
        try outgoing()
    }
    @MainActor func testAdvancedSharedReplyRegistersTheSameSenderDetailAndOffersConfirmation() throws {
        try outgoing(advanced: true)
    }
    @MainActor private func outgoing(advanced: Bool = false) throws {
        launch(advanced: advanced)
        let suffix = String(UUID().uuidString.prefix(6)), alias = "Reply Friend " + suffix
        app.buttons["inviteContactButton"].tap()
        let name = app.textFields["contactInvitationNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 3)); name.tap(); name.typeText(alias)
        app.buttons["saveContactPersonButton"].tap()
        let share = app.buttons["shareContactInvitationButton"]
        XCTAssertTrue(share.waitForExistence(timeout: 3)); share.tap()
        XCTAssertTrue(copy().waitForExistence(timeout: 5)); copy().tap()
        XCTAssertTrue(copy().waitForNonExistence(timeout: 5))
        let invitation = try copiedURL()
        let reply = try InvitationURLFixture.acceptance(invitation, invitee: "shared-peer-" + suffix, sharedName: "Their Name " + suffix)
        app.open(reply)
        XCTAssertTrue(app.descendants(matching: .any)["standardUsersList"].firstMatch.waitForExistence(timeout: 5))
        settings(alias)
        XCTAssertEqual(app.textFields["savedUserNameField"].value as? String, alias)
        let confirm = app.buttons["shareContactConfirmationButton"].firstMatch
        if advanced { reveal(confirm) }
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "A verified reply updates the same detail")
        confirm.tap()
        XCTAssertTrue(copy().waitForExistence(timeout: 5)); copy().tap()
        XCTAssertTrue(copy().waitForNonExistence(timeout: 5))
        XCTAssertTrue(confirm.exists)
        XCTAssertTrue(app.buttons["closeUserSettingsButton"].exists)
        screenshot("Shared acceptance preserves the sender name and provides confirmation")
        app.buttons["closeUserSettingsButton"].tap()
        app.terminate(); app.launch(); app.activate(); settings(alias)
        if advanced { reveal(confirm) }
        XCTAssertTrue(confirm.waitForExistence(timeout: 4), "The manual receipt origin survives restart")
    }

    @MainActor func testJapaneseExpiredReplyExplainsRecoveryAfterRestart() async throws {
        try await expiredReply(japanese: true)
    }
    @MainActor func testAdvancedExpiredReplyShowsTheDeadlineWithoutRetry() async throws {
        try await expiredReply(advanced: true)
    }
    @MainActor private func expiredReply(advanced: Bool = false, japanese: Bool = false) async throws {
        launch(advanced: advanced, japanese: japanese)
        let suffix = String(UUID().uuidString.prefix(6)), name = "Expiry Author " + suffix
        let started = Date()
        let url = try InvitationURLFixture.make(inviter: "expired-reply-" + suffix, sharedName: name, contact: true, expiresAfter: 45)
        app.open(url)
        let register = app.buttons["acceptContactInvitationButton"]
        XCTAssertTrue(register.waitForExistence(timeout: 5)); register.tap()
        let done = app.buttons["closeContactInvitationButton"]
        XCTAssertTrue(done.waitForExistence(timeout: 4)); done.tap()
        app.terminate()
        // End the owning process before the deadline so the real persisted checkpoint expires while stopped.
        let remaining = max(0, started.addingTimeInterval(47).timeIntervalSinceNow)
        if remaining > 0 { try await Task.sleep(for: .seconds(remaining)) }
        app.launch(); app.activate(); settings(name)
        let ownName = app.descendants(matching: .any)["savedUserOriginalName"].firstMatch
        XCTAssertTrue((ownName.label + (ownName.value as? String ?? "")).contains(name))
        if advanced {
            let expired = app.staticTexts["contactInvitationField-hasExpired"]
            reveal(expired)
            XCTAssertEqual(expired.label, "true")
        } else {
            let state = app.descendants(matching: .any)["contactInvitationState"].firstMatch
            XCTAssertTrue(state.waitForExistence(timeout: 4))
            XCTAssertEqual(state.label, "返信の有効期限が切れました")
            XCTAssertTrue(app.staticTexts["新しい招待を送ってもらってください。"].exists)
        }
        XCTAssertFalse(app.buttons["retryContactInvitationButton"].exists)
        XCTAssertFalse(app.buttons["shareContactReplyButton"].exists)
        screenshot("Expired checkpoint keeps the person and offers a valid next step")
    }
}
#endif
