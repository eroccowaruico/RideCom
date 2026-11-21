#if os(iOS)
import XCTest

final class RegisteredGroupInvitationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testStandardSavesRegisteredInvitationsWithoutOpeningSharing() throws { try save() }
    @MainActor func testAdvancedSavesRegisteredInvitationsWithoutOpeningSharing() throws { try save(advanced: true) }
    @MainActor func testStandardSavesLegacyInvitationsWithoutOpeningSharing() throws { try save(legacy: true) }
    @MainActor func testAdvancedSavesLegacyInvitationsWithoutOpeningSharing() throws {
        try save(advanced: true, legacy: true)
    }

    @MainActor func testStandardGroupSettingsKeepsTheSavedInvitationState() throws { try save(checkSettings: true) }
    @MainActor func testAdvancedGroupSettingsKeepsTheSavedInvitationState() throws {
        try save(advanced: true, checkSettings: true)
    }

    @MainActor func testStandardSharingAndReceiptUpdateTheSameRegisteredInvitation() throws {
        try save(checkSettings: true, verifyReceipt: true)
    }

    @MainActor func testAdvancedSharingAndReceiptUpdateTheSameDeliveryRecord() throws {
        try save(advanced: true, checkSettings: true, verifyReceipt: true)
    }

    @MainActor func testJapaneseNewInvitationKeepsTheTargetAndRegistrationState() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        app.launchEnvironment = [
            "RIDEINTERCOM_LOCAL_TESTING": "1",
            "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in",
            "RIDEINTERCOM_INTERFACE_FIXTURE": "standard"
        ]
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch()
        app.activate()
        let groups = app.tabBars.buttons["グループ"]
        XCTAssertTrue(groups.waitForExistence(timeout: 5))
        groups.tap()
        app.buttons["standardCreateGroupButton"].tap()
        let name = try XCTUnwrap(app.textFields["savedUsersGroupNameField"].value as? String)
        let add = app.buttons["addNewGroupInviteeButton"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        add.tap()
        let person = app.textFields.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "newGroupInviteName-")
        ).firstMatch
        XCTAssertTrue(person.waitForExistence(timeout: 3))
        person.tap()
        person.typeText("JP Guest\n")
        app.buttons["saveUserSelectionButton"].tap()
        let target = app.staticTexts["savedInvitationGroupName"]
        XCTAssertTrue(target.waitForExistence(timeout: 5))
        XCTAssertEqual(target.label, name)
        XCTAssertTrue(app.navigationBars["招待"].exists)
        let state = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "groupInviteRegistrationState-")
        ).firstMatch
        XCTAssertEqual(state.label, "未登録")
        app.buttons["finishAddingUsersButton"].tap()
        XCTAssertTrue(app.buttons["finishAddingUsersButton"].waitForNonExistence(timeout: 3))
    }

    @MainActor private func save(
        advanced: Bool = false, legacy: Bool = false, checkSettings: Bool = false, verifyReceipt: Bool = false
    ) throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        let seed = UUID().uuidString
        app.launchEnvironment = [
            "RIDEINTERCOM_LOCAL_TESTING": "1",
            "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in",
            "RIDEINTERCOM_INTERFACE_FIXTURE": advanced ? "advanced" : "standard"
        ]
        let fixtureKey = legacy ? "RIDEINTERCOM_CONTACT_NAME_FIXTURE" : "RIDEINTERCOM_MEMBER_SELECTION_FIXTURE"
        app.launchEnvironment[fixtureKey] = seed
        if verifyReceipt { app.launchEnvironment["RIDEINTERCOM_GROUP_DELIVERY_RECEIPT_FIXTURE"] = "1" }
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        app.activate()
        let groups = app.tabBars.buttons["Groups"]
        XCTAssertTrue(groups.waitForExistence(timeout: 5))
        groups.tap()
        app.buttons["standardCreateGroupButton"].firstMatch.tap()
        let groupName = try XCTUnwrap(app.textFields["savedUsersGroupNameField"].value as? String)
        selectRegisteredInvitee(in: app, personID: seed, advanced: advanced)
        app.buttons["saveUserSelectionButton"].tap()
        assertSavedInvitation(in: app, groupName: groupName, advanced: advanced, legacy: legacy)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Registered invitations remain in the saved step"
        attachment.lifetime = .keepAlways
        add(attachment)
        let updatedRowID = verifyReceipt
            ? verifySharingAndReceipt(in: app, personID: seed, group: groupName, advanced: advanced)
            : nil
        app.buttons["finishAddingUsersButton"].tap()
        XCTAssertTrue(app.buttons["finishAddingUsersButton"].waitForNonExistence(timeout: 3))
        if checkSettings {
            assertGroupSettings(in: app, advanced: advanced, updatedRowID: updatedRowID, verifyReceipt: verifyReceipt)
        }
    }

    @MainActor private func selectRegisteredInvitee(in app: XCUIApplication, personID: String, advanced: Bool) {
        let person = app.buttons["selectUser-" + personID]
        for _ in 0..<32 {
            let bottom = advanced ? app.frame.maxY - 36 : app.buttons["saveUserSelectionButton"].frame.minY
            if person.exists, person.isHittable, person.frame.minY > 130, person.frame.maxY < bottom - 12 { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).press(
                forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30))
            )
        }
        XCTAssertTrue(person.exists && person.isHittable)
        person.tap()
        XCTAssertTrue(person.isSelected, "The chosen person is selected before saving")
    }

    @MainActor private func assertSavedInvitation(
        in app: XCUIApplication, groupName: String, advanced: Bool, legacy: Bool
    ) {
        XCTAssertTrue(app.buttons["finishAddingUsersButton"].waitForExistence(timeout: 5))
        let targetName = app.staticTexts["savedInvitationGroupName"]
        XCTAssertTrue(targetName.waitForExistence(timeout: 5))
        XCTAssertEqual(targetName.label, groupName)
        XCTAssertTrue(app.navigationBars["Invitation"].exists)
        if advanced {
            XCTAssertTrue(app.staticTexts["savedInvitationGroupID"].exists)
            let state = app.staticTexts.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "groupDeliveryState-")
            ).firstMatch
            if legacy { XCTAssertFalse(state.exists) } else { XCTAssertTrue(state.exists) }
        } else {
            XCTAssertTrue(app.staticTexts["groupDeliverySelectionMessage"].exists)
        }
        if legacy {
            XCTAssertTrue(app.buttons["addedUsersInviteButton"].exists)
            if !advanced {
                let row = app.descendants(matching: .any).matching(
                    NSPredicate(format: "identifier BEGINSWITH %@", "groupDeliveryPerson-")
                ).firstMatch
                XCTAssertTrue(row.label.contains("Sharing required"))
            }
        }
        XCTAssertFalse(app.cells["Copy"].exists, "Saving does not force the OS sharing dialog")
    }

    @MainActor private func assertGroupSettings(
        in app: XCUIApplication, advanced: Bool, updatedRowID: String?, verifyReceipt: Bool
    ) {
        let entry = app.buttons[advanced ? "callMoreMenu" : "callGroupSettingsButton"]
        XCTAssertTrue(entry.waitForExistence(timeout: 5))
        entry.tap()
        if advanced {
            app.buttons["callGroupSettingsButton"].tap()
            if verifyReceipt { XCTAssertTrue(app.buttons["groupSettingsInviteButton"].isHittable) }
        }
        let state: XCUIElement
        if advanced, let updatedRowID {
            state = app.staticTexts[updatedRowID]
        } else {
            let prefix = advanced ? "groupDeliveryState-" : "groupSettingsInvitationState-"
            state = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix)).firstMatch
        }
        for _ in 0..<4 where !state.exists { app.swipeUp() }
        XCTAssertTrue(state.waitForExistence(timeout: 3))
        let expected = verifyReceipt
            ? (advanced ? "received" : "Invitation received")
            : (advanced ? "pending" : "Invitation pending")
        XCTAssertEqual(state.label, expected)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Group settings keeps saved invitation state"
        image.lifetime = .keepAlways
        add(image)
        app.buttons["closeGroupSettingsButton"].tap()
    }

    @MainActor private func verifySharingAndReceipt(
        in app: XCUIApplication, personID: String, group: String, advanced: Bool
    ) -> String {
        let firstRecord = app.staticTexts.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "groupDeliveryState-")
        ).firstMatch
        let person = app.descendants(matching: .any)["groupDeliveryPerson-" + personID].firstMatch
        let initialState = advanced ? firstRecord : person
        let share = app.buttons["addedUsersInviteButton"]
        XCTAssertTrue(share.isHittable, "Sharing is reachable before scrolling through delivery records")
        let pending = advanced ? "pending" : "Invitation pending"
        let received = advanced ? "received" : "Invitation received"
        for _ in 0..<4 where !initialState.exists { app.swipeUp() }
        XCTAssertTrue(initialState.waitForExistence(timeout: 5))
        XCTAssertTrue(initialState.label.contains(pending), initialState.label)
        let rowID = initialState.identifier
        for _ in 0..<4 where !share.isHittable { app.swipeDown() }
        XCTAssertTrue(share.isHittable)
        share.tap()
        let copy = app.cells.matching(NSPredicate(format: "label IN %@", ["Copy", "Copy Link"])).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        let close = app.buttons["Close"].firstMatch
        if close.exists && close.isHittable { close.tap() } else { app.swipeDown() }
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))

        let sameRow = app.descendants(matching: .any)[rowID].firstMatch
        for _ in 0..<4 where !sameRow.exists { app.swipeUp() }
        XCTAssertTrue(sameRow.exists)
        XCTAssertTrue(sameRow.label.contains(pending), "Dismissing sharing keeps the existing delivery pending")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()

        let changed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "label CONTAINS %@", received), object: sameRow
        )
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 5), .completed)
        XCTAssertTrue(app.navigationBars["Invitation"].exists)
        if advanced {
            let pendingRecord = app.staticTexts.matching(
                NSPredicate(format: "identifier BEGINSWITH %@ AND label == %@", "groupDeliveryState-", pending)
            ).firstMatch
            for _ in 0..<4 where !pendingRecord.exists { app.swipeUp() }
            XCTAssertTrue(pendingRecord.exists)
        }
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "One confirmed delivery updates the open invitation"
        image.lifetime = .keepAlways
        add(image)
        let groupName = app.staticTexts["savedInvitationGroupName"]
        for _ in 0..<4 where !groupName.exists { app.swipeDown() }
        XCTAssertEqual(groupName.label, group)
        return rowID
    }
}
#endif
