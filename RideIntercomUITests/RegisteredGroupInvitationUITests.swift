#if os(iOS)
import XCTest

final class RegisteredGroupInvitationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor func testStandardSavesRegisteredInvitationsWithoutOpeningSharing() throws { try save() }
    @MainActor func testAdvancedSavesRegisteredInvitationsWithoutOpeningSharing() throws { try save(advanced: true) }
    @MainActor func testStandardSavesLegacyInvitationsWithoutOpeningSharing() throws { try save(legacy: true) }
    @MainActor func testAdvancedSavesLegacyInvitationsWithoutOpeningSharing() throws { try save(advanced: true, legacy: true) }
    @MainActor func testStandardGroupSettingsKeepsTheSavedInvitationState() throws { try save(checkSettings: true) }
    @MainActor func testAdvancedGroupSettingsKeepsTheSavedInvitationState() throws { try save(advanced: true, checkSettings: true) }
    @MainActor func testJapaneseNewInvitationKeepsTheTargetAndRegistrationState() throws {
        let app = XCUIApplication(); defer { app.terminate() }
        app.launchEnvironment = ["RIDEINTERCOM_LOCAL_TESTING": "1", "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in", "RIDEINTERCOM_INTERFACE_FIXTURE": "standard"]
        app.launchArguments = ["-AppleLanguages", "(ja)", "-AppleLocale", "ja_JP"]
        app.launch(); app.activate()
        let groups = app.tabBars.buttons["グループ"]; XCTAssertTrue(groups.waitForExistence(timeout: 5)); groups.tap()
        app.buttons["standardCreateGroupButton"].tap()
        let name = try XCTUnwrap(app.textFields["savedUsersGroupNameField"].value as? String)
        let add = app.buttons["addNewGroupInviteeButton"]; XCTAssertTrue(add.waitForExistence(timeout: 5)); add.tap()
        let person = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "newGroupInviteName-")).firstMatch
        XCTAssertTrue(person.waitForExistence(timeout: 3)); person.tap(); person.typeText("JP Guest\n")
        app.buttons["saveUserSelectionButton"].tap()
        let target = app.staticTexts["savedInvitationGroupName"]; XCTAssertTrue(target.waitForExistence(timeout: 5)); XCTAssertEqual(target.label, name)
        XCTAssertTrue(app.navigationBars["招待"].exists)
        let state = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "groupInviteRegistrationState-")).firstMatch
        XCTAssertEqual(state.label, "未登録")
        app.buttons["finishAddingUsersButton"].tap()
        XCTAssertTrue(app.buttons["finishAddingUsersButton"].waitForNonExistence(timeout: 3))
    }
    @MainActor private func save(advanced: Bool = false, legacy: Bool = false, checkSettings: Bool = false) throws {
        let app = XCUIApplication(); defer { app.terminate() }
        let seed = UUID().uuidString
        app.launchEnvironment = ["RIDEINTERCOM_LOCAL_TESTING": "1", "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in",
            "RIDEINTERCOM_INTERFACE_FIXTURE": advanced ? "advanced" : "standard"]
        app.launchEnvironment[legacy ? "RIDEINTERCOM_CONTACT_NAME_FIXTURE" : "RIDEINTERCOM_MEMBER_SELECTION_FIXTURE"] = seed
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); app.activate()
        let groups = app.tabBars.buttons["Groups"]; XCTAssertTrue(groups.waitForExistence(timeout: 5)); groups.tap()
        app.buttons["standardCreateGroupButton"].firstMatch.tap()
        let groupName = try XCTUnwrap(app.textFields["savedUsersGroupNameField"].value as? String)
        let person = app.buttons["selectUser-" + seed]
        for _ in 0..<32 {
            let bottom = advanced ? app.frame.maxY - 36 : app.buttons["saveUserSelectionButton"].frame.minY
            if person.exists, person.isHittable, person.frame.minY > 130, person.frame.maxY < bottom - 12 { break }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)).press(forDuration: 0.05,
                thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.30)))
        }
        XCTAssertTrue(person.exists && person.isHittable); person.tap()
        XCTAssertTrue(person.isSelected, "The chosen person is selected before saving")
        app.buttons["saveUserSelectionButton"].tap()
        XCTAssertTrue(app.buttons["finishAddingUsersButton"].waitForExistence(timeout: 5))
        let targetName = app.staticTexts["savedInvitationGroupName"]
        XCTAssertTrue(targetName.waitForExistence(timeout: 5)); XCTAssertEqual(targetName.label, groupName)
        XCTAssertTrue(app.navigationBars["Invitation"].exists)
        if advanced {
            XCTAssertTrue(app.staticTexts["savedInvitationGroupID"].exists)
            let state = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "groupDeliveryState-")).firstMatch
            if legacy { XCTAssertFalse(state.exists) } else { XCTAssertTrue(state.exists) }
        } else { XCTAssertTrue(app.staticTexts["groupDeliverySelectionMessage"].exists) }
        if legacy {
            XCTAssertTrue(app.buttons["addedUsersInviteButton"].exists)
            if !advanced {
                let row = app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", "groupDeliveryPerson-")).firstMatch
                XCTAssertTrue(row.label.contains("Sharing required"))
            }
        }
        XCTAssertFalse(app.cells["Copy"].exists, "Saving does not force the OS sharing dialog")
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Registered invitations remain in the saved step"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["finishAddingUsersButton"].tap()
        XCTAssertTrue(app.buttons["finishAddingUsersButton"].waitForNonExistence(timeout: 3))
        if checkSettings {
            let entry = app.buttons[advanced ? "callMoreMenu" : "callGroupSettingsButton"]
            XCTAssertTrue(entry.waitForExistence(timeout: 5)); entry.tap()
            if advanced { app.buttons["callGroupSettingsButton"].tap() }
            let state = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", advanced ? "groupDeliveryState-" : "groupSettingsInvitationState-")).firstMatch
            XCTAssertTrue(state.waitForExistence(timeout: 3))
            XCTAssertEqual(state.label, advanced ? "pending" : "Invitation pending")
            let image = XCTAttachment(screenshot: app.screenshot()); image.name = "Group settings keeps saved invitation state"; image.lifetime = .keepAlways; add(image)
            app.buttons["closeGroupSettingsButton"].tap()
        }
    }
}
#endif
