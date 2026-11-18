#if os(iOS)
import XCTest

final class RegisteredGroupInvitationUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor func testStandardSavesRegisteredInvitationsWithoutOpeningSharing() throws { try save() }
    @MainActor func testAdvancedSavesRegisteredInvitationsWithoutOpeningSharing() throws { try save(advanced: true) }
    @MainActor private func save(advanced: Bool = false) throws {
        let app = XCUIApplication(); defer { app.terminate() }
        let seed = UUID().uuidString
        app.launchEnvironment = ["RIDEINTERCOM_LOCAL_TESTING": "1", "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in",
            "RIDEINTERCOM_INTERFACE_FIXTURE": advanced ? "advanced" : "standard", "RIDEINTERCOM_MEMBER_SELECTION_FIXTURE": seed]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); app.activate()
        let groups = app.tabBars.buttons["Groups"]; XCTAssertTrue(groups.waitForExistence(timeout: 5)); groups.tap()
        app.buttons["standardCreateGroupButton"].firstMatch.tap()
        let person = app.buttons["selectUser-" + seed]
        for _ in 0..<24 where !person.exists || !person.isHittable { app.swipeUp() }
        XCTAssertTrue(person.exists); person.tap()
        app.buttons["saveUserSelectionButton"].tap()
        XCTAssertTrue(app.buttons["finishAddingUsersButton"].waitForExistence(timeout: 5))
        if advanced {
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@", "groupDeliveryState-")).firstMatch.exists)
        } else { XCTAssertTrue(app.staticTexts["groupDeliverySelectionMessage"].exists) }
        XCTAssertFalse(app.cells["Copy"].exists, "Saving does not force the OS sharing dialog")
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Registered invitations remain in the saved step"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["finishAddingUsersButton"].tap()
        XCTAssertTrue(app.buttons["finishAddingUsersButton"].waitForNonExistence(timeout: 3))
    }
}
#endif
