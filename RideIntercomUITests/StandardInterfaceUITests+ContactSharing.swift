import XCTest

extension StandardInterfaceUITests {
    #if os(iOS)
    @MainActor
    @objc
    func testLegacyContactInvitationWaitsForShareCompletionAndRetainsItsRow() throws {
        launch(legacyContactInvitation: true)
        tab("Users", id: "usersTab")
        let rowID = try XCTUnwrap(contactPendingIDs().first)
        let row = app.buttons[rowID].firstMatch
        row.tap()
        let state = app.descendants(matching: .any)["contactInvitationState"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertEqual(state.label, "Not sent yet")
        XCTAssertTrue(app.staticTexts["Contact Invitation"].exists)
        let share = app.buttons["shareContactInvitationButton"].firstMatch
        let copy = nativeInvitationCopyAction()
        share.tap()
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        app.swipeDown()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        XCTAssertTrue(state.waitForExistence(timeout: 5), "Dismissing OS sharing keeps the invitation detail open")
        XCTAssertEqual(state.label, "Not sent yet", "Opening and dismissing the share preview leaves the link unsent")
        XCTAssertEqual(share.label, "Share Invitation")
        share.tap()
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        XCTAssertEqual(state.label, "Waiting to be accepted")
        XCTAssertEqual(share.label, "Share Again")
        app.buttons["closeContactInvitationButton"].firstMatch.tap()
        XCTAssertEqual(contactPendingIDs(), [rowID])
        app.launchEnvironment.removeValue(forKey: "RIDEINTERCOM_LEGACY_CONTACT_INVITATION_FIXTURE")
        app.terminate(); app.launch(); app.activate()
        tab("Users", id: "usersTab")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(contactPendingIDs(), [rowID])
        row.tap()
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertEqual(state.label, "Waiting to be accepted")
    }

    @MainActor
    @objc
    func testContactPersonSaveShareCancelCopyAndRestartKeepOnePerson() throws {
        launch()
        tab("Users", id: "usersTab")
        let before = contactSavedUserIDs(), pending = contactPendingIDs()
        app.buttons["inviteContactButton"].tap()
        let save = app.buttons["saveContactPersonButton"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 3), "Saving a name is separate from sharing")
        XCTAssertFalse(app.buttons["shareContactInvitationButton"].exists)
        let name = app.textFields["contactInvitationNameField"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let nickname = "Saved Partner " + UUID().uuidString.prefix(6)
        name.typeText(nickname)
        app.buttons["closeContactInvitationButton"].tap()
        XCTAssertEqual(contactSavedUserIDs(), before, "Cancel before Save writes nothing")
        app.buttons["inviteContactButton"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.typeText(nickname)
        save.tap()
        let savedName = app.staticTexts["contactPersonSavedName"].firstMatch
        XCTAssertTrue(savedName.waitForExistence(timeout: 3))
        XCTAssertEqual(savedName.label, nickname)
        XCTAssertFalse(name.exists, "Saving confirms the name instead of leaving an implicit editing state")
        let done = app.buttons["closeContactInvitationButton"].firstMatch
        XCTAssertEqual(done.label, "Done")
        let state = app.staticTexts["contactPersonRegistrationState"].firstMatch
        XCTAssertEqual(state.label, "Not registered")
        let share = app.buttons["shareContactInvitationButton"].firstMatch
        checkSavedContactSharing(nickname, name: savedName, done: done, share: share, state: state)
        let added = contactSavedUserIDs().subtracting(before)
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(contactPendingIDs(), pending, "No separate invitation row for the same person")
        let rowID = try XCTUnwrap(added.first)
        app.terminate(); app.launch(); app.activate()
        tab("Users", id: "usersTab")
        revealUser(nickname)
        let row = app.buttons[rowID].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Not registered"), row.label)
        row.tap()
        XCTAssertEqual(savedName.label, nickname)
        XCTAssertTrue(share.exists)
        done.tap()
    }

    @MainActor
    private func checkSavedContactSharing(
        _ nickname: String,
        name: XCUIElement,
        done: XCUIElement,
        share: XCUIElement,
        state: XCUIElement
    ) {
        share.tap()
        let copy = nativeInvitationCopyAction()
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        app.swipeDown()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        XCTAssertEqual(name.label, nickname)
        XCTAssertEqual(done.label, "Done")
        share.tap()
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        XCTAssertEqual(state.label, "Not registered", "Copy is not delivery or registration")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(name.waitForExistence(timeout: 5), "Returning keeps the same saved detail open")
        XCTAssertEqual(name.label, nickname)
        screenshot("Saved person stays after share cancel copy and foreground return")
        done.tap()
    }

    @MainActor
    @objc
    func testContactPersonCanBeSavedAndFinishedWithoutSharing() throws {
        launch()
        tab("Users", id: "usersTab")
        let before = contactSavedUserIDs(), pending = contactPendingIDs()
        app.buttons["inviteContactButton"].tap()
        let name = app.textFields["contactInvitationNameField"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let candidate = try XCTUnwrap(name.placeholderValue)
        app.buttons["saveContactPersonButton"].tap()
        let saved = app.staticTexts["contactPersonSavedName"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 3))
        XCTAssertEqual(saved.label, candidate)
        let done = app.buttons["closeContactInvitationButton"].firstMatch
        XCTAssertEqual(done.label, "Done")
        done.tap()
        let added = contactSavedUserIDs().subtracting(before)
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(contactPendingIDs(), pending)
        revealUser(candidate)
        app.buttons[try XCTUnwrap(added.first)].tap()
        XCTAssertEqual(saved.label, candidate)
        XCTAssertTrue(app.buttons["shareContactInvitationButton"].exists)
        done.tap()
    }

    @MainActor
    @objc
    func testJapaneseContactCreationKeepsSaveReachableWithLargestTextAndKeyboard() {
        launch(japanese: true)
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        tab("ユーザー", id: "usersTab")
        app.buttons["inviteContactButton"].tap()
        let name = app.textFields["contactInvitationNameField"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 4))
        let save = app.buttons["saveContactPersonButton"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        XCTAssertTrue(save.isHittable)
        name.typeText("雪山の仲間")
        XCTAssertTrue(save.isHittable, "Save stays above the keyboard at the largest text size")
        screenshot("Japanese explicit save largest text with keyboard")
        save.tap()
        let share = app.buttons["shareContactInvitationButton"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 4))
        XCTAssertTrue(share.isHittable)
        share.tap()
        let copy = nativeInvitationCopyAction()
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["closeContactInvitationButton"].label, "完了")
        screenshot("Japanese saved detail after copying invitation largest text")
        app.buttons["closeContactInvitationButton"].tap()
    }

    @MainActor
    @objc
    func testAdvancedInvitationShowsTheStoredRecordAndItsOperations() throws {
        launch(interface: "advanced")
        tab("Users", id: "usersTab")
        app.buttons["inviteContactButton"].tap()
        let name = app.textFields["contactInvitationNameField"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.typeText("Advanced Partner")
        app.buttons["saveContactPersonButton"].tap()
        XCTAssertTrue(app.staticTexts["SavedUser"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["memberIDs"].exists)
        XCTAssertFalse(app.staticTexts["ContactInvitationRecord"].exists, "Saving alone issues no invitation")
        app.buttons["shareContactInvitationButton"].tap()
        let copy = nativeInvitationCopyAction()
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        let header = app.staticTexts["ContactInvitationRecord"].firstMatch
        for _ in 0..<5 where !header.isHittable { app.swipeUp() }
        XCTAssertTrue(header.exists)
        let state = app.staticTexts["contactInvitationField-state"].firstMatch
        for _ in 0..<5 where !state.isHittable { app.swipeUp() }
        XCTAssertEqual(state.label, "pending")
        let session = app.staticTexts["contactInvitationField-session"].firstMatch
        for _ in 0..<5 where !session.isHittable { app.swipeUp() }
        XCTAssertEqual(session.label, "running")
        XCTAssertFalse(app.descendants(matching: .any)["contactInvitationState"].exists)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "running"),
                                                object: session)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 5), .completed,
                       "The same exchange resumes on foreground return")
        screenshot("Advanced person and its exchange remain together after foreground return")
        app.buttons["closeContactInvitationButton"].tap()
    }

    @MainActor private func nativeInvitationCopyAction() -> XCUIElement {
        app.cells.matching(NSPredicate(format: "label IN %@", ["Copy", "Copy Link", "コピー", "リンクをコピー"])).firstMatch
    }
    #endif
}
