import XCTest

extension StandardInterfaceUITests {
    #if os(iOS)
    @MainActor
    @objc
    func testJapaneseContactPreviewCancelThenAcceptPersistsOnlyTheInviter() throws {
        launch(japanese: true)
        tab("グループ", id: "groupsTab")
        let originalGroups = contactGroupRows().count
        tab("ユーザー", id: "usersTab")
        let originalUsers = contactUserRows().count
        let originalPending = contactPendingIDs()
        let suffix = String(UUID().uuidString.prefix(8))
        let inviterName = "招待者 " + suffix
        let url = try InvitationURLFixture.make(inviter: "ui-contact-" + suffix, sharedName: inviterName, contact: true)
        app.open(url)
        let preview = app.descendants(matching: .any)["contactInvitationPreview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[inviterName].firstMatch.exists)
        let accept = app.buttons["acceptContactInvitationButton"].firstMatch
        let cancel = app.buttons["cancelContactInvitationButton"].firstMatch
        XCTAssertEqual(accept.label, "登録")
        XCTAssertEqual(cancel.label, "拒否")
        screenshot("Japanese signed contact invitation preview")
        cancel.tap()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 3))
        tab("ユーザー", id: "usersTab")
        XCTAssertEqual(contactUserRows().count, originalUsers)
        XCTAssertEqual(contactPendingIDs(), originalPending)
        XCTAssertFalse(app.staticTexts[inviterName].exists)
        app.open(url)
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        accept.tap()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
        app.buttons["closeContactInvitationButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["standardUsersList"].firstMatch.waitForExistence(timeout: 3))
        revealUser(inviterName)
        // Rows are lazy and earlier runs leave users, so count the inviter's rows rather than all rows.
        XCTAssertEqual(inviterRows(inviterName).count, 1, "Accepting saves exactly the inviter")
        screenshot("Japanese accepted contact saved while notification remains separate")
        let directory = contactDirectorySnapshot()
        XCTAssertFalse(directory.contains {
            $0.key.hasPrefix("pendingContactInvitation-") && $0.value.contains(inviterName)
        },
                       "A saved person has no duplicate pending row")
        checkJapaneseInviterSettings(inviterName)
        tab("グループ", id: "groupsTab")
        XCTAssertEqual(contactGroupRows().count, originalGroups)
        app.terminate(); app.launch(); app.activate()
        tab("ユーザー", id: "usersTab")
        revealUser(inviterName)
        XCTAssertEqual(inviterRows(inviterName).count, 1)
    }

    @MainActor
    private func checkJapaneseInviterSettings(_ inviterName: String) {
        openUserSettings(from: inviterRows(inviterName).firstMatch)
        XCTAssertTrue(app.staticTexts["savedUserOriginalName"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["savedUserOriginalName"].firstMatch.label, inviterName)
        let reply = app.descendants(matching: .any)["contactInvitationState"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 3))
        XCTAssertTrue(reply.label.contains("返信を届けています") || reply.label.contains("返信が届いていません"), reply.label)
        screenshot("Japanese registered inviter and reply in the same person's settings")
        app.buttons["closeUserSettingsButton"].tap()
    }

    /// A swipe made while the invitation sheet is still closing is lost, so swipe again until the action shows.
    @MainActor
    func openUserSettings(from row: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let settings = app.buttons.matching(NSPredicate(format: "label IN %@", ["User Settings", "相手の設定"])).firstMatch
        for _ in 0..<3 where !settings.exists {
            row.swipeLeft()
            _ = settings.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(settings.exists, file: file, line: line)
        settings.tap()
    }

    /// The saved user's own row (the pending invitation row shows the same name), scrolled into view.
    @MainActor func inviterRows(_ name: String) -> XCUIElementQuery {
        let rows = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                  "standardUser-", name))
        let list = app.descendants(matching: .any)["standardUsersList"].firstMatch
        for _ in 0..<10 where rows.count == 0 { list.swipeUp() }
        return rows
    }

    /// Pending invitations left by earlier runs can push saved users below the fold.
    func revealUser(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let users = app.descendants(matching: .any)["standardUsersList"].firstMatch
        XCTAssertTrue(users.waitForExistence(timeout: 5), file: file, line: line)
        for _ in 0..<10 where !app.staticTexts[name].firstMatch.exists { users.swipeUp() }
        XCTAssertTrue(app.staticTexts[name].firstMatch.waitForExistence(timeout: 5), file: file, line: line)
    }

    @MainActor
    @objc
    func testContactPendingRetryAndLocalCancellationKeepAnExistingCall() throws {
        launch()
        tab("Groups", id: "groupsTab")
        app.buttons["standardCreateGroupButton"].tap()
        let name = app.textFields["savedUsersGroupNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let groupName = "Contact waiting " + UUID().uuidString.prefix(6)
        name.tap()
        let entered = (name.value as? String)?.count ?? 0
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: entered) + groupName)
        app.buttons["saveUserSelectionButton"].tap()
        XCTAssertTrue(app.buttons["standardEndCallButton"].waitForExistence(timeout: 5))
        let mute = app.buttons["standardMuteButton"].firstMatch
        if mute.value as? String != "Muted" { mute.tap() }
        tab("Users", id: "usersTab")
        let originalUsers = contactSavedUserIDs()
        app.buttons["inviteContactButton"].tap()
        XCTAssertTrue(app.buttons["saveContactPersonButton"].waitForExistence(timeout: 3))
        app.textFields["contactInvitationNameField"].typeText("Not invited during call")
        app.buttons["saveContactPersonButton"].tap()
        XCTAssertEqual(app.staticTexts["contactPersonRegistrationState"].firstMatch.label, "Not registered")
        app.buttons["closeContactInvitationButton"].tap()
        let added = try XCTUnwrap(contactSavedUserIDs().subtracting(originalUsers).first)
        let row = app.buttons[added].firstMatch
        revealUser("Not invited during call")
        openUserSettings(from: row)
        app.buttons["deleteUserButton"].tap()
        app.alerts.buttons["confirmDeleteUserButton"].firstMatch.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        XCTAssertEqual(contactSavedUserIDs(), originalUsers)
        tab("Call", id: "callTab")
        XCTAssertTrue(app.buttons["standardEndCallButton"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts[groupName].firstMatch.exists)
        XCTAssertEqual(mute.value as? String, "Muted")
        app.buttons["standardEndCallButton"].tap()
        app.alerts.firstMatch.buttons["standardConfirmEndCallButton"].firstMatch.tap()
    }

    @MainActor
    @objc
    func testReceivedContactReplyExplainsWaitingForCurrentCallWhenNearRangeIsOff() throws {
        try receiveContactDuringCall(nearRange: false)
    }

    @MainActor
    @objc
    func testReceivedContactShowsActiveNearRangeReplyDuringCall() throws {
        try receiveContactDuringCall(nearRange: true)
    }

    @MainActor
    private func receiveContactDuringCall(nearRange: Bool) throws {
        launch()
        configureRoutesForContactReply(nearRange: nearRange)
        let suffix = String(UUID().uuidString.prefix(6)), inviter = "Reply during call " + suffix
        app.open(
            try InvitationURLFixture.make(inviter: "ui-active-reply-" + suffix, sharedName: inviter, contact: true)
        )
        let register = app.buttons["acceptContactInvitationButton"].firstMatch
        XCTAssertTrue(register.waitForExistence(timeout: 5))
        register.tap()
        app.buttons["closeContactInvitationButton"].tap()
        tab("Groups", id: "groupsTab")
        app.buttons["standardCreateGroupButton"].tap()
        let name = app.textFields["savedUsersGroupNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let groupName = "Receive while talking " + UUID().uuidString.prefix(6)
        name.tap()
        let entered = (name.value as? String)?.count ?? 0
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: entered) + groupName)
        app.buttons["saveUserSelectionButton"].tap()
        XCTAssertTrue(app.buttons["standardEndCallButton"].waitForExistence(timeout: 5))
        let mute = app.buttons["standardMuteButton"].firstMatch
        if mute.value as? String != "Muted" { mute.tap() }
        tab("Users", id: "usersTab")
        revealUser(inviter)
        openUserSettings(from: inviterRows(inviter).firstMatch)
        let state = app.descendants(matching: .any)["contactInvitationState"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 3))
        let retry = app.buttons["retryContactInvitationButton"]
        if nearRange && state.label == "Reply not delivered" {
            // This fixture has no sender. A stopped attempt must be retryable in the same call.
            XCTAssertTrue(retry.waitForExistence(timeout: 3))
            retry.tap()
        }
        XCTAssertEqual(state.label, nearRange ? "Sending a reply" : "Waiting for the current call to end.")
        XCTAssertFalse(retry.exists)
        XCTAssertTrue(app.buttons["shareContactReplyButton"].exists)
        screenshot(nearRange ? "Near-range reply during the call" : "Internet-only reply waits for the call to end")
        app.buttons["closeUserSettingsButton"].tap()
        tab("Call", id: "callTab")
        XCTAssertTrue(app.staticTexts[groupName].firstMatch.exists)
        XCTAssertEqual(mute.value as? String, "Muted")
        app.buttons["standardEndCallButton"].tap()
        app.alerts.buttons["standardConfirmEndCallButton"].firstMatch.tap()
    }

    @MainActor
    private func configureRoutesForContactReply(nearRange: Bool) {
        tab("Settings", id: "settingsTab")
        let communication = app.buttons["communicationSettingsLink"].firstMatch
        revealStandardSettingsControl(communication)
        communication.tap()
        let internet = app.switches["internetRouteToggle"].firstMatch
        XCTAssertTrue(internet.waitForExistence(timeout: 5))
        if internet.value as? String == "0" {
            internet.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        let local = app.switches["localNetworkRouteToggle"].firstMatch
        let expectedLocal = nearRange ? "1" : "0"
        if local.value as? String != expectedLocal {
            local.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertEqual(local.value as? String, expectedLocal)
    }

    @MainActor private func contactUserRows() -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardUser-"))
    }
    /// SwiftUI lazily exposes rows. Compare identities over the whole list, then return to its top.
    @MainActor func contactSavedUserIDs() -> Set<String> {
        Set(contactDirectorySnapshot().keys.filter { $0.hasPrefix("standardUser-") })
    }

    @MainActor private func contactDirectorySnapshot() -> [String: String] {
        let list = app.descendants(matching: .any)["standardUsersList"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 3))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@",
                                                  "standardUser-", "pendingContactInvitation-"))
        var top: Set<String>?
        for _ in 0..<20 {
            let visible = Set(rows.allElementsBoundByIndex.filter(\.isHittable).map(\.identifier))
            if visible == top { break }
            top = visible
            list.swipeDown()
        }
        var result: [String: String] = [:]
        var previous: Set<String>?, bottomReached = false, swipes = 0
        for _ in 0..<20 {
            for row in rows.allElementsBoundByIndex { result[row.identifier] = row.label }
            let visible = Set(rows.allElementsBoundByIndex.filter(\.isHittable).map(\.identifier))
            if visible == previous { bottomReached = true; break }
            previous = visible
            list.swipeUp(); swipes += 1
        }
        XCTAssertTrue(bottomReached, "The comparison must cover the whole directory")
        for _ in 0...swipes { list.swipeDown() }
        return result
    }

    @MainActor private func contactGroupRows() -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardGroup-"))
    }
    @MainActor func contactPendingIDs() -> Set<String> {
        let pending = NSPredicate(format: "identifier BEGINSWITH %@", "pendingContactInvitation-")
        let pendingRows = app.buttons.matching(pending)
        return Set(pendingRows.allElementsBoundByIndex.map(\.identifier))
    }

    #endif
}
