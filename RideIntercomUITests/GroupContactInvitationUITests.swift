#if os(iOS)
import XCTest

final class GroupContactInvitationUITests: XCTestCase {
    private var appForTeardown: XCUIApplication?

    override func setUpWithError() throws { continueAfterFailure = false }

    override func tearDownWithError() throws {
        appForTeardown?.terminate()
        appForTeardown = nil
    }

    func testReplyFixtureUsesTheSameFractionalTimestampSpellingAsCodable() throws {
        struct Fields: Encodable {
            let expiresAt: Double
            let contactBootstrap: Bool
        }
        let value = Fields(expiresAt: 1795596316.992827, contactBootstrap: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(try InvitationURLFixture.canonicalData(object), data)
    }

    @MainActor func testStandardPreparesANewPersonsGroupInvitation() throws { try prepare() }
    @MainActor func testAdvancedPreparesANewPersonsGroupInvitation() throws { try prepare(advanced: true) }
    @MainActor func testStandardGroupSettingsPreparesANewPersonsInvitation() throws { try prepare(entry: "settings") }
    @MainActor func testStandardCallReopensASavedGroupInvitation() throws { try prepare(entry: "call") }
    @MainActor func testStandardGroupSettingsReopensASavedGroupInvitation() throws {
        try prepare(reopenInSettings: true)
    }

    @MainActor func testAdvancedCallPreparesANewPersonsInvitation() throws {
        try prepare(advanced: true, entry: "call")
    }
    @MainActor func testAdvancedGroupSettingsShowsTheStoredInvitationState() throws {
        try prepare(advanced: true, reopenInSettings: true)
    }

    @MainActor func testJapaneseReceiverRegistersAndJoinsTogether() throws { try receive(japanese: true) }
    @MainActor func testAdvancedReceiverRegistersAndJoinsTogether() throws { try receive(advanced: true) }
    @MainActor func testStandardLeavingAReceivedGroupKeepsThePersonAndRejectsTheOldInvitation() throws {
        try receive(leaves: true)
    }

    @MainActor func testAdvancedLeavingAReceivedGroupKeepsThePersonAndRejectsTheOldInvitation() throws {
        try receive(advanced: true, leaves: true)
    }

    @MainActor func testStandardRenewsAnExpiredGroupInvitationInTheSamePersonDetail() throws {
        let app = makeApp()
        let timeFixture = "RIDEINTERCOM_PAST_GROUP_INVITATION_FIXTURE"
        app.launchEnvironment = [
            "RIDEINTERCOM_LOCAL_TESTING": "1", "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in",
            "RIDEINTERCOM_INTERFACE_FIXTURE": "standard", timeFixture: "1"
        ]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()
        let group = try createGroup(in: app)
        let nickname = "Renew rider " + String(UUID().uuidString.prefix(6))
        saveNewGroupInvitee(in: app, named: nickname)
        let finish = app.buttons["finishAddingUsersButton"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        finish.tap()
        app.terminate()
        app.launchEnvironment.removeValue(forKey: timeFixture)
        app.launch()

        openSavedGroupSettings(in: app, groupName: group, advanced: false)
        let memberRows = buttons(
            in: app, identifierPrefix: "groupSettingsMember-invite-pending-contact-", label: nickname
        )
        let member = memberRows.firstMatch
        XCTAssertTrue(member.waitForExistence(timeout: 5))
        XCTAssertTrue(member.label.contains("Expired"), member.label)
        let oldSlot = member.identifier
        member.tap()
        let name = app.staticTexts["contactPersonSavedName"]
        let state = app.staticTexts["contactPersonOutgoingInvitationState"]
        let destination = app.staticTexts["Group invitation: \(group)"]
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertEqual(state.label, "Expired")
        XCTAssertEqual(name.label, nickname)
        XCTAssertTrue(destination.exists)

        app.buttons["shareContactInvitationButton"].tap()
        cancelInvitationSharing(in: app)
        XCTAssertEqual(state.label, "Not sent yet")
        XCTAssertEqual(name.label, nickname)
        XCTAssertTrue(destination.exists)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Renewed group invitation after cancelling sharing"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        app.buttons["closeContactInvitationButton"].tap()
        XCTAssertTrue(member.waitForExistence(timeout: 5))
        XCTAssertEqual(memberRows.count, 1)
        XCTAssertNotEqual(member.identifier, oldSlot)
        XCTAssertTrue(member.label.contains("Not sent yet"), member.label)
    }

    @MainActor private func makeApp() -> XCUIApplication {
        let app = XCUIApplication()
        appForTeardown = app
        return app
    }

    @MainActor func launchApp(advanced: Bool, japanese: Bool = false) -> XCUIApplication {
        let app = makeApp()
        app.launchEnvironment = [
            "RIDEINTERCOM_LOCAL_TESTING": "1", "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in",
            "RIDEINTERCOM_INTERFACE_FIXTURE": advanced ? "advanced" : "standard"
        ]
        app.launchArguments = [
            "-AppleLanguages", japanese ? "(ja)" : "(en)", "-AppleLocale", japanese ? "ja_JP" : "en_US"
        ]
        app.launch()
        app.activate()
        return app
    }

    @MainActor func buttons(in app: XCUIApplication, identifierPrefix: String, label: String) -> XCUIElementQuery {
        app.buttons.matching(
            NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", identifierPrefix, label)
        )
    }

    @MainActor func createGroup(in app: XCUIApplication) throws -> String {
        let groups = app.tabBars.buttons["Groups"]
        XCTAssertTrue(groups.waitForExistence(timeout: 5))
        groups.tap()
        app.buttons["standardCreateGroupButton"].firstMatch.tap()
        return try XCTUnwrap(app.textFields["savedUsersGroupNameField"].value as? String)
    }

    @MainActor func saveNewGroupInvitee(in app: XCUIApplication, named nickname: String) {
        let add = app.buttons["addNewGroupInviteeButton"]
        for _ in 0..<24 where !add.exists || !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.waitForExistence(timeout: 3))
        add.tap()
        let name = app.textFields.matching(
            NSPredicate(format: "identifier BEGINSWITH %@", "newGroupInviteName-")
        ).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText(nickname + "\n")
        app.buttons["saveUserSelectionButton"].tap()
    }

    @discardableResult
    @MainActor func cancelInvitationSharing(in app: XCUIApplication) -> XCUIElement {
        let copy = app.cells.matching(NSPredicate(format: "label IN %@", ["Copy", "Copy Link"])).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        let close = app.buttons["Close"].firstMatch
        if close.exists && close.isHittable { close.tap() } else { app.swipeDown() }
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        return copy
    }

    @MainActor func openSavedGroupSettings(in app: XCUIApplication, groupName: String, advanced: Bool) {
        app.closeCallIfOpen()
        let groupsTab = app.tabBars.buttons["Groups"]
        XCTAssertTrue(groupsTab.waitForExistence(timeout: 5))
        groupsTab.tap()
        let row = buttons(in: app, identifierPrefix: "standardGroup-", label: groupName).firstMatch
        for _ in 0..<20 where !row.exists || !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.exists)
        if advanced {
            row.swipeLeft()
            let settings = app.buttons["Group Settings"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
        } else {
            row.tap()
            let settings = app.buttons["callGroupSettingsButton"]
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
        }
        XCTAssertTrue(app.textFields["groupSettingsNameField"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["groupSettingsNameField"].value as? String, groupName)
    }
}

private extension GroupContactInvitationUITests {
    @MainActor func receive(advanced: Bool = false, japanese: Bool = false, leaves: Bool = false) throws {
        let app = launchApp(advanced: advanced, japanese: japanese)
        let suffix = String(UUID().uuidString.prefix(6))
        let name = "Group author " + suffix
        let groupName = "Joined group " + suffix
        let url = try InvitationURLFixture.make(
            inviter: "join-author-" + suffix, sharedName: name, contact: true, invitedGroupName: groupName
        )
        app.open(url)
        XCTAssertTrue(app.staticTexts["invitedGroupPreview"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["invitedGroupPreview"].label.contains(groupName))
        app.buttons["cancelContactInvitationButton"].tap()
        app.open(url)
        app.buttons["acceptContactInvitationButton"].tap()
        XCTAssertTrue(app.staticTexts["contactPersonSavedName"].waitForExistence(timeout: 5))
        let done = app.buttons["closeContactInvitationButton"]
        XCTAssertTrue(done.exists, "Registration keeps the saved detail open")
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "One consent saves the person and group"
        attachment.lifetime = .keepAlways
        self.add(attachment)
        done.tap()
        app.terminate()
        app.launch()
        app.activate()
        let groups = app.tabBars.buttons[japanese ? "グループ" : "Groups"]
        XCTAssertTrue(groups.waitForExistence(timeout: 5))
        groups.tap()
        let row = buttons(in: app, identifierPrefix: "standardGroup-", label: groupName).firstMatch
        for _ in 0..<20 where !row.exists || !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.exists, "The received group survives restart without starting a call")
        if leaves {
            verifyLeaving(in: app, group: row, invitation: url, authorName: name)
        }
    }

    @MainActor func verifyLeaving(
        in app: XCUIApplication, group: XCUIElement, invitation: URL, authorName: String
    ) {
        app.removeGroupRow(group)
        XCTAssertTrue(group.waitForNonExistence(timeout: 5))
        app.open(invitation)
        XCTAssertTrue(app.buttons["acceptContactInvitationButton"].waitForExistence(timeout: 5))
        app.buttons["acceptContactInvitationButton"].tap()
        let error = app.staticTexts["This invitation could not be accepted. Ask the sender for a new invitation."]
        XCTAssertTrue(error.waitForExistence(timeout: 3))
        XCTAssertFalse(
            app.staticTexts["contactPersonSavedName"].exists, "An old link cannot report a deleted group as saved"
        )
        app.buttons["cancelContactInvitationButton"].tap()
        app.terminate()
        app.launch()
        app.activate()
        let users = app.tabBars.buttons["Users"]
        XCTAssertTrue(users.waitForExistence(timeout: 5))
        users.tap()
        let person = buttons(in: app, identifierPrefix: "standardUser-", label: authorName).firstMatch
        for _ in 0..<20 where !person.exists || !person.isHittable { app.swipeUp() }
        XCTAssertTrue(person.exists, "Leaving only the group keeps the registered contact")
        app.tabBars.buttons["Groups"].tap()
        XCTAssertFalse(group.exists, "An old link must not recreate a group after leaving")
        let evidence = XCTAttachment(screenshot: app.screenshot())
        evidence.name = "Leaving the group cancels only its invitation"
        evidence.lifetime = .keepAlways
        self.add(evidence)
    }
}
#endif
