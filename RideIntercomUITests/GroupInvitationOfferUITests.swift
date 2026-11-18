#if os(iOS)
import XCTest

final class GroupInvitationOfferUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor func testHiddenGroupsAreOfferedAfterFinishingTheInvitation() throws {
        let app = XCUIApplication(); defer { app.terminate() }
        app.launchEnvironment = ["RIDEINTERCOM_LOCAL_TESTING": "1", "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in",
            "RIDEINTERCOM_INTERFACE_FIXTURE": "standard", "RIDEINTERCOM_GROUPS_TAB": "1"]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); app.activate()
        let groups = app.tabBars.buttons["Groups"]
        XCTAssertTrue(groups.waitForExistence(timeout: 5)); groups.tap()
        app.launchEnvironment["RIDEINTERCOM_GROUPS_TAB"] = "0"
        app.terminate(); app.launch(); app.activate()
        XCTAssertTrue(app.buttons["inviteContactButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Show the Groups tab?"].exists, "Groups already shown must not be offered again")
        let name = "Offered group " + String(UUID().uuidString.prefix(6))
        app.open(try InvitationURLFixture.make(inviter: "offer-author-" + UUID().uuidString, sharedName: "Group author", contact: true, invitedGroupName: name))
        XCTAssertTrue(app.buttons["acceptContactInvitationButton"].waitForExistence(timeout: 5)); app.buttons["acceptContactInvitationButton"].tap()
        XCTAssertTrue(app.buttons["closeContactInvitationButton"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.alerts["Show the Groups tab?"].exists, "The saved invitation detail stays uninterrupted")
        app.buttons["closeContactInvitationButton"].tap()
        let offer = app.alerts["Show the Groups tab?"]
        XCTAssertTrue(offer.waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Offer the hidden Groups tab after the invitation"; attachment.lifetime = .keepAlways; add(attachment)
        XCTAssertTrue(offer.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", name)).firstMatch.exists)
        offer.buttons["Not Now"].tap()
        XCTAssertFalse(app.tabBars.buttons["Groups"].exists)
        app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = nil
        app.launchEnvironment["RIDEINTERCOM_GROUPS_TAB"] = nil
        app.terminate(); app.launch(); app.activate()
        XCTAssertTrue(app.buttons["inviteContactButton"].waitForExistence(timeout: 5)); XCTAssertFalse(offer.exists)
        let next = "Next offered group " + String(UUID().uuidString.prefix(6))
        app.open(try InvitationURLFixture.make(inviter: "next-author-" + UUID().uuidString, sharedName: "Another author", contact: true, invitedGroupName: next))
        XCTAssertTrue(app.buttons["acceptContactInvitationButton"].waitForExistence(timeout: 5)); app.buttons["acceptContactInvitationButton"].tap()
        XCTAssertTrue(app.buttons["closeContactInvitationButton"].waitForExistence(timeout: 5)); app.buttons["closeContactInvitationButton"].tap()
        XCTAssertTrue(offer.waitForExistence(timeout: 5)); offer.buttons["Show"].tap()
        XCTAssertTrue(app.tabBars.buttons["Groups"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "standardGroup-", next)).firstMatch.exists)
        XCTAssertFalse(app.buttons["callGroupSettingsButton"].exists, "Showing the group list never starts a call")
        app.terminate(); app.launch(); app.activate()
        XCTAssertTrue(app.tabBars.buttons["Groups"].waitForExistence(timeout: 5)); XCTAssertFalse(offer.exists)
    }
}
#endif
