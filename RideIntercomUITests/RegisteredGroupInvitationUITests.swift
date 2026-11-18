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
