#if os(iOS)
import CryptoKit
import XCTest

final class GroupContactInvitationUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { app?.terminate(); app = nil }

    @MainActor func testStandardPreparesANewPersonsGroupInvitation() throws { try prepare() }
    @MainActor func testAdvancedPreparesANewPersonsGroupInvitation() throws { try prepare(advanced: true) }
    @MainActor func testStandardGroupSettingsPreparesANewPersonsInvitation() throws { try prepare(entry: "settings") }
    @MainActor func testAdvancedCallPreparesANewPersonsInvitation() throws { try prepare(advanced: true, entry: "call") }
    @MainActor func testJapaneseReceiverRegistersAndJoinsTogether() throws { try receive(japanese: true) }
    @MainActor func testAdvancedReceiverRegistersAndJoinsTogether() throws { try receive(advanced: true) }


    @MainActor private func prepare(advanced: Bool = false, entry: String = "new") throws {
        app = XCUIApplication()
        app.launchEnvironment = ["RIDEINTERCOM_LOCAL_TESTING": "1", "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in", "RIDEINTERCOM_INTERFACE_FIXTURE": advanced ? "advanced" : "standard"]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); app.activate()
        let groups = app.tabBars.buttons["Groups"]
        XCTAssertTrue(groups.waitForExistence(timeout: 5)); groups.tap()
        app.buttons["standardCreateGroupButton"].firstMatch.tap()
        let groupName = try XCTUnwrap(app.textFields["savedUsersGroupNameField"].value as? String)
        if entry != "new" {
            app.buttons["saveUserSelectionButton"].tap()
            let more = app.buttons[advanced ? "callMoreMenu" : "callGroupSettingsButton"]
            XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
            if entry == "settings" {
                if advanced { app.buttons["callGroupSettingsButton"].tap() }
                let invite = app.buttons["groupSettingsAddMembersButton"]
                XCTAssertTrue(invite.waitForExistence(timeout: 3)); XCTAssertTrue(invite.isEnabled); invite.tap()
            } else { app.buttons["callAddMembersButton"].tap() }
        }
        let add = app.buttons["addNewGroupInviteeButton"]
        for _ in 0..<24 where !add.exists || !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.waitForExistence(timeout: 3)); add.tap()
        let name = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "newGroupInviteName-")).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let nickname = "New rider " + String(UUID().uuidString.prefix(6))
        name.tap(); name.typeText(nickname + "\n")
        app.buttons["saveUserSelectionButton"].tap()
        XCTAssertTrue(app.buttons["finishAddingUsersButton"].waitForExistence(timeout: 5))
        let person = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "groupInvitePerson-", nickname)).firstMatch
        XCTAssertTrue(person.waitForExistence(timeout: 3)); person.tap()
        let share = app.buttons["shareContactInvitationButton"]
        XCTAssertTrue(share.waitForExistence(timeout: 3)); share.tap()
        let copy = app.cells.matching(NSPredicate(format: "label IN %@", ["Copy", "Copy Link"])).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        let dismissRegion = app.otherElements["PopoverDismissRegion"].firstMatch
        if dismissRegion.exists { dismissRegion.tap() }
        else {
            let close = app.buttons.matching(NSPredicate(format: "label IN %@", ["Close", "Cancel", "Dismiss", "閉じる", "キャンセル"])).allElementsBoundByIndex.first { $0.isHittable }
            XCTAssertNotNil(close); close?.tap()
        }
        XCTAssertTrue(share.waitForExistence(timeout: 5)); XCTAssertTrue(share.isHittable)
        share.tap(); XCTAssertTrue(copy.waitForExistence(timeout: 5)); copy.tap()
        XCTAssertTrue(app.buttons["shareContactInvitationButton"].waitForExistence(timeout: 5), "Sharing keeps the same saved detail")
        let invitation = try copiedURL()
        // Finish explicitly before opening the reply: XCUIApplication.open relaunches this test app.
        let finish = app.buttons["finishAddingUsersButton"]
        if !finish.exists || !finish.isHittable { app.navigationBars.buttons.element(boundBy: 0).tap() }
        XCTAssertTrue(finish.waitForExistence(timeout: 3)); finish.tap()
        let suffix = String(UUID().uuidString.prefix(6)), peer = "group-peer-" + suffix
        app.open(try InvitationURLFixture.acceptance(invitation, invitee: peer, sharedName: "Remote " + suffix))
        app.closeCallIfOpen()
        let groupsTab = app.tabBars.buttons["Groups"]
        XCTAssertTrue(groupsTab.waitForExistence(timeout: 5)); groupsTab.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "standardGroup-", groupName)).firstMatch
        for _ in 0..<20 where !row.exists || !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.exists); row.tap()
        let menu = app.buttons[advanced ? "callMoreMenu" : "callGroupSettingsButton"]
        XCTAssertTrue(menu.waitForExistence(timeout: 5)); menu.tap()
        if advanced { app.buttons["callGroupSettingsButton"].tap() }
        XCTAssertTrue(app.textFields["groupSettingsNameField"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["groupSettingsNameField"].value as? String, groupName)
        if !advanced { XCTAssertTrue(app.buttons["groupSettingsMember-" + peer].exists) }
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", nickname)).firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Signed reply replaces only its saved group invitation slot"; attachment.lifetime = .keepAlways; self.add(attachment)

    }

    @MainActor private func copiedURL() throws -> URL {
        let edit = app.buttons["editContactPersonNameButton"]
        for _ in 0..<8 where !edit.exists || !edit.isHittable { app.swipeDown() }
        XCTAssertTrue(edit.exists); edit.tap()
        let field = app.textFields["savedUserNameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3)); field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count))
        field.press(forDuration: 1)
        let menu = app.menuItems["Paste"], button = app.buttons["Paste"]
        if menu.waitForExistence(timeout: 2) { menu.tap() } else { XCTAssertTrue(button.waitForExistence(timeout: 2)); button.tap() }
        let value = try XCTUnwrap(field.value as? String)
        app.buttons["closeUserSettingsButton"].tap()
        let match = try XCTUnwrap(value.range(of: #"rideintercom://[^\s]+"#, options: .regularExpression))
        return try XCTUnwrap(URL(string: String(value[match])))
    }

    @MainActor private func receive(advanced: Bool = false, japanese: Bool = false) throws {
        app = XCUIApplication()
        app.launchEnvironment = ["RIDEINTERCOM_LOCAL_TESTING": "1", "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in", "RIDEINTERCOM_INTERFACE_FIXTURE": advanced ? "advanced" : "standard"]
        app.launchArguments = ["-AppleLanguages", japanese ? "(ja)" : "(en)", "-AppleLocale", japanese ? "ja_JP" : "en_US"]
        app.launch(); app.activate()
        let suffix = String(UUID().uuidString.prefix(6)), name = "Group author " + suffix, groupName = "Joined group " + suffix
        let url = try InvitationURLFixture.make(inviter: "join-author-" + suffix, sharedName: name, contact: true, invitedGroupName: groupName)
        app.open(url)
        XCTAssertTrue(app.staticTexts["invitedGroupPreview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["invitedGroupPreview"].label.contains(groupName))
        app.buttons["cancelContactInvitationButton"].tap()
        app.open(url)
        app.buttons["acceptContactInvitationButton"].tap()
        XCTAssertTrue(app.staticTexts["contactPersonSavedName"].waitForExistence(timeout: 5))
        let done = app.buttons["closeContactInvitationButton"]
        XCTAssertTrue(done.exists, "Registration keeps the saved detail open")
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "One consent saves the person and group"; attachment.lifetime = .keepAlways; self.add(attachment)
        done.tap(); app.terminate(); app.launch(); app.activate()
        let groups = app.tabBars.buttons[japanese ? "グループ" : "Groups"]
        XCTAssertTrue(groups.waitForExistence(timeout: 5)); groups.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "standardGroup-", groupName)).firstMatch
        for _ in 0..<20 where !row.exists || !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.exists, "The received group survives restart without starting a call")
    }
}
#endif
