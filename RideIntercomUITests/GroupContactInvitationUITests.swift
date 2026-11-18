#if os(iOS)
import CryptoKit
import XCTest

final class GroupContactInvitationUITests: XCTestCase {
    private var app: XCUIApplication!
    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { app?.terminate(); app = nil }

    func testReplyFixtureUsesTheSameFractionalTimestampSpellingAsCodable() throws {
        struct Fields: Encodable { let expiresAt: Double; let contactBootstrap: Bool }
        let value = Fields(expiresAt: 1795596316.992827, contactBootstrap: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(try InvitationURLFixture.canonicalData(object), data)
    }

    @MainActor func testStandardPreparesANewPersonsGroupInvitation() throws { try prepare() }
    @MainActor func testAdvancedPreparesANewPersonsGroupInvitation() throws { try prepare(advanced: true) }
    @MainActor func testStandardGroupSettingsPreparesANewPersonsInvitation() throws { try prepare(entry: "settings") }
    @MainActor func testStandardCallReopensASavedGroupInvitation() throws { try prepare(entry: "call") }
    @MainActor func testAdvancedCallPreparesANewPersonsInvitation() throws { try prepare(advanced: true, entry: "call") }
    @MainActor func testAdvancedGroupSettingsShowsTheStoredInvitationState() throws {
        try prepare(advanced: true, reopenInSettings: true)
    }
    @MainActor func testJapaneseReceiverRegistersAndJoinsTogether() throws { try receive(japanese: true) }
    @MainActor func testAdvancedReceiverRegistersAndJoinsTogether() throws { try receive(advanced: true) }
    @MainActor func testStandardLeavingAReceivedGroupKeepsThePersonAndRejectsTheOldInvitation() throws { try receive(leaves: true) }
    @MainActor func testAdvancedLeavingAReceivedGroupKeepsThePersonAndRejectsTheOldInvitation() throws { try receive(advanced: true, leaves: true) }


    @MainActor private func prepare(advanced: Bool = false, entry: String = "new", reopenInSettings: Bool = false) throws {
        app = XCUIApplication()
        app.launchEnvironment = ["RIDEINTERCOM_LOCAL_TESTING": "1", "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in", "RIDEINTERCOM_INTERFACE_FIXTURE": advanced ? "advanced" : "standard"]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); app.activate()
        let groups = app.tabBars.buttons["Groups"]
        XCTAssertTrue(groups.waitForExistence(timeout: 5)); groups.tap()
        app.buttons["standardCreateGroupButton"].firstMatch.tap()
        let groupName = try XCTUnwrap(app.textFields["savedUsersGroupNameField"].value as? String)
        let fromStandardCall = !advanced && entry == "call"
        if entry != "new" {
            app.buttons["saveUserSelectionButton"].tap()
            if fromStandardCall {
                let invite = app.buttons["addSavedUsersButton"]
                XCTAssertTrue(app.staticTexts["standardCallParticipantsHeading"].waitForExistence(timeout: 5))
                for _ in 0..<6 where !invite.isHittable { app.swipeUp() }
                XCTAssertTrue(invite.isHittable)
                invite.tap()
            } else {
                let more = app.buttons[advanced ? "callMoreMenu" : "callGroupSettingsButton"]
                XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
                if entry == "settings" {
                    if advanced { app.buttons["callGroupSettingsButton"].tap() }
                    let invite = app.buttons["groupSettingsAddMembersButton"]
                    XCTAssertTrue(invite.waitForExistence(timeout: 3)); XCTAssertTrue(invite.isEnabled); invite.tap()
                } else { app.buttons["callAddMembersButton"].tap() }
            }
        }
        let add = app.buttons["addNewGroupInviteeButton"]
        for _ in 0..<24 where !add.exists || !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.waitForExistence(timeout: 3)); add.tap()
        let name = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "newGroupInviteName-")).firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let nickname = "New rider " + String(UUID().uuidString.prefix(6))
        let callInvitee = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "standardCallInvitee-", nickname)).firstMatch
        name.tap(); name.typeText(nickname + "\n")
        app.buttons["saveUserSelectionButton"].tap()
        let finish = app.buttons["finishAddingUsersButton"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        let person = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "groupInvitePerson-", nickname)).firstMatch
        XCTAssertTrue(person.waitForExistence(timeout: 3))
        let settingsInvitee = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
            "groupSettingsMember-invite-pending-contact-", nickname)).firstMatch
        if reopenInSettings {
            finish.tap()
            openSavedGroupSettings(groupName, advanced: advanced)
            XCTAssertTrue(settingsInvitee.waitForExistence(timeout: 5))
            XCTAssertTrue(settingsInvitee.label.contains("outgoing · pending · sent false"), settingsInvitee.label)
            XCTAssertTrue(settingsInvitee.label.contains("expiresAt "), settingsInvitee.label)
            settingsInvitee.tap()
        } else if fromStandardCall {
            finish.tap()
            XCTAssertTrue(callInvitee.waitForExistence(timeout: 5))
            for _ in 0..<4 where !callInvitee.isHittable { app.swipeUp() }
            XCTAssertTrue(callInvitee.isHittable, "The group offers the saved invitation before the other person joins")
            XCTAssertTrue(callInvitee.label.contains("Not sent yet"))
            XCTAssertLessThan(app.buttons["addSavedUsersButton"].frame.minY, callInvitee.frame.minY)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Group shows a saved unsent invitation"; attachment.lifetime = .keepAlways; self.add(attachment)
            callInvitee.tap()
        } else {
            person.tap()
        }
        let share = app.buttons["shareContactInvitationButton"]
        XCTAssertTrue(share.waitForExistence(timeout: 3))
        if reopenInSettings {
            XCTAssertTrue(app.staticTexts["contactPersonSavedName"].firstMatch.label.hasSuffix(nickname))
        }
        share.tap()
        let copy = app.cells.matching(NSPredicate(format: "label IN %@", ["Copy", "Copy Link"])).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        let closeShare = app.buttons["Close"].firstMatch
        if closeShare.exists && closeShare.isHittable { closeShare.tap() }
        else { app.swipeDown() }
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        XCTAssertTrue(share.waitForExistence(timeout: 5)); XCTAssertTrue(share.isHittable)
        if reopenInSettings {
            app.buttons["closeContactInvitationButton"].tap()
            XCTAssertTrue(settingsInvitee.waitForExistence(timeout: 5))
            XCTAssertTrue(settingsInvitee.label.contains("outgoing · pending · sent false"), settingsInvitee.label)
            settingsInvitee.tap()
            XCTAssertTrue(share.waitForExistence(timeout: 3))
            XCTAssertTrue(app.staticTexts["contactPersonSavedName"].firstMatch.label.hasSuffix(nickname))
        } else if fromStandardCall {
            app.buttons["closeContactInvitationButton"].tap()
            XCTAssertTrue(callInvitee.waitForExistence(timeout: 5))
            XCTAssertTrue(callInvitee.label.contains("Not sent yet"), "Closing the share sheet leaves the invitation unsent")
            callInvitee.tap()
            XCTAssertTrue(share.waitForExistence(timeout: 3))
        }
        share.tap(); XCTAssertTrue(copy.waitForExistence(timeout: 5)); copy.tap()
        XCTAssertTrue(app.buttons["shareContactInvitationButton"].waitForExistence(timeout: 5), "Sharing keeps the same saved detail")
        let invitation = try copiedURL()
        // Finish explicitly before opening the reply: XCUIApplication.open relaunches this test app.
        if reopenInSettings {
            app.buttons["closeContactInvitationButton"].tap()
            XCTAssertTrue(settingsInvitee.waitForExistence(timeout: 5))
            XCTAssertTrue(settingsInvitee.label.contains("outgoing · pending · sent true"), settingsInvitee.label)
            app.buttons["closeGroupSettingsButton"].tap()
        } else if fromStandardCall {
            let done = app.buttons["closeContactInvitationButton"]
            XCTAssertTrue(done.waitForExistence(timeout: 3)); done.tap()
            XCTAssertTrue(callInvitee.waitForExistence(timeout: 5))
            XCTAssertTrue(callInvitee.label.contains("Waiting to be accepted"))
            app.buttons["callGroupSettingsButton"].tap()
            let state = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@",
                "groupSettingsInvitationState-")).firstMatch
            XCTAssertTrue(state.waitForExistence(timeout: 3))
            XCTAssertEqual(state.label, "Waiting to be accepted")
            app.buttons["closeGroupSettingsButton"].tap()
        } else {
            if !finish.exists || !finish.isHittable { app.navigationBars.buttons.element(boundBy: 0).tap() }
            XCTAssertTrue(finish.waitForExistence(timeout: 3)); finish.tap()
        }
        let suffix = String(UUID().uuidString.prefix(6)), peer = "group-peer-" + suffix
        app.open(try InvitationURLFixture.acceptance(invitation, invitee: peer, sharedName: "Remote " + suffix))
        openSavedGroupSettings(groupName, advanced: advanced)
        if !advanced {
            XCTAssertTrue(app.buttons["groupSettingsMember-" + peer].waitForExistence(timeout: 5))
        }
        XCTAssertFalse(settingsInvitee.exists, "The signed reply replaces the invitation row")
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", nickname)).firstMatch.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot()); attachment.name = "Signed reply replaces only its saved group invitation slot"; attachment.lifetime = .keepAlways; self.add(attachment)
    }

    @MainActor private func openSavedGroupSettings(_ groupName: String, advanced: Bool) {
        app.closeCallIfOpen()
        let groupsTab = app.tabBars.buttons["Groups"]
        XCTAssertTrue(groupsTab.waitForExistence(timeout: 5)); groupsTab.tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "standardGroup-", groupName)).firstMatch
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

    @MainActor private func receive(advanced: Bool = false, japanese: Bool = false, leaves: Bool = false) throws {
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
        if leaves {
            app.removeGroupRow(row)
            XCTAssertTrue(row.waitForNonExistence(timeout: 5))
            app.open(url)
            XCTAssertTrue(app.buttons["acceptContactInvitationButton"].waitForExistence(timeout: 5))
            app.buttons["acceptContactInvitationButton"].tap()
            XCTAssertTrue(app.staticTexts["This invitation could not be accepted. Ask the sender for a new invitation."].waitForExistence(timeout: 3))
            XCTAssertFalse(app.staticTexts["contactPersonSavedName"].exists, "An old link cannot report a deleted group as saved")
            app.buttons["cancelContactInvitationButton"].tap()
            app.terminate(); app.launch(); app.activate()
            let users = app.tabBars.buttons["Users"]
            XCTAssertTrue(users.waitForExistence(timeout: 5)); users.tap()
            let person = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "standardUser-", name)).firstMatch
            for _ in 0..<20 where !person.exists || !person.isHittable { app.swipeUp() }
            XCTAssertTrue(person.exists, "Leaving only the group keeps the registered contact")
            app.tabBars.buttons["Groups"].tap()
            XCTAssertFalse(row.exists, "An old link must not recreate a group after leaving")
            let evidence = XCTAttachment(screenshot: app.screenshot()); evidence.name = "Leaving the group cancels only its invitation"; evidence.lifetime = .keepAlways; self.add(evidence)
        }
    }
}
#endif
