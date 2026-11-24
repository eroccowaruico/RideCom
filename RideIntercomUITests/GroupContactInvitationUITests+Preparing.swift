#if os(iOS)
import XCTest

extension GroupContactInvitationUITests {
    private struct SavedInvitee {
        let groupName: String
        let nickname: String
        let finish: XCUIElement
        let person: XCUIElement
        let callInvitee: XCUIElement
        let settingsInvitee: XCUIElement
        let personState: XCUIElement
    }

    private enum SavedInvitationEntry {
        case person, call, settings
    }

    @MainActor func prepare(advanced: Bool = false, entry: String = "new", reopenInSettings: Bool = false) throws {
        let app = launchApp(advanced: advanced)
        let groupName = try createGroup(in: app)
        let fromStandardCall = !advanced && entry == "call"
        openInviteeSelection(in: app, entry: entry, advanced: advanced, fromStandardCall: fromStandardCall)
        let saved = saveInvitee(in: app, groupName: groupName)
        if !advanced {
            XCTAssertEqual(app.staticTexts["groupDeliverySelectionMessage"].label,
                           "Invitations saved. You can close this screen and share them later.")
        }
        let unsent = advanced ? "outgoing · pending · sent false" : "Not sent yet"
        let shared = advanced ? "outgoing · pending · sent true" : "Waiting to be accepted"
        let savedEntry: SavedInvitationEntry = reopenInSettings ? .settings : (fromStandardCall ? .call : .person)
        openInvitation(in: app, saved: saved, entry: savedEntry, advanced: advanced, unsent: unsent)
        let invitation = try copyInvitation(
            in: app, saved: saved, entry: savedEntry, advanced: advanced, labels: (unsent, shared)
        )
        // Finish explicitly before opening the reply: XCUIApplication.open relaunches this test app.
        finishSharing(in: app, saved: saved, entry: savedEntry, shared: shared)
        try openSignedReply(in: app, invitation: invitation, groupName: groupName, advanced: advanced)
        XCTAssertFalse(saved.settingsInvitee.exists, "The signed reply replaces the invitation row")
        let savedName = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", saved.nickname)).firstMatch
        XCTAssertTrue(savedName.exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Signed reply replaces only its saved group invitation slot"
        attachment.lifetime = .keepAlways
        self.add(attachment)
    }

    @MainActor private func saveInvitee(in app: XCUIApplication, groupName: String) -> SavedInvitee {
        let nickname = "New rider " + String(UUID().uuidString.prefix(6))
        let callInvitee = buttons(in: app, identifierPrefix: "standardCallInvitee-", label: nickname).firstMatch
        saveNewGroupInvitee(in: app, named: nickname)
        let finish = app.buttons["finishAddingUsersButton"]
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        let person = buttons(in: app, identifierPrefix: "groupInvitePerson-", label: nickname).firstMatch
        XCTAssertTrue(person.waitForExistence(timeout: 3))
        let settingsInvitee = buttons(
            in: app, identifierPrefix: "groupSettingsMember-invite-pending-contact-", label: nickname
        ).firstMatch
        let personState = app.staticTexts["contactPersonOutgoingInvitationState"]
        return SavedInvitee(
            groupName: groupName, nickname: nickname, finish: finish, person: person, callInvitee: callInvitee,
            settingsInvitee: settingsInvitee, personState: personState
        )
    }

    @MainActor private func openInvitation(
        in app: XCUIApplication, saved: SavedInvitee, entry: SavedInvitationEntry, advanced: Bool, unsent: String
    ) {
        switch entry {
        case .settings:
            let settingsInvitee = saved.settingsInvitee
            saved.finish.tap()
            openSavedGroupSettings(in: app, groupName: saved.groupName, advanced: advanced)
            XCTAssertTrue(settingsInvitee.waitForExistence(timeout: 5))
            XCTAssertTrue(settingsInvitee.label.contains(unsent), settingsInvitee.label)
            if advanced { XCTAssertTrue(settingsInvitee.label.contains("expiresAt "), settingsInvitee.label) }
            settingsInvitee.tap()
        case .call:
            let callInvitee = saved.callInvitee
            saved.finish.tap()
            XCTAssertTrue(callInvitee.waitForExistence(timeout: 5))
            for _ in 0..<4 where !callInvitee.isHittable { app.swipeUp() }
            XCTAssertTrue(callInvitee.isHittable, "The group offers the saved invitation before the other person joins")
            XCTAssertTrue(callInvitee.label.contains("Not sent yet"))
            XCTAssertLessThan(app.buttons["addSavedUsersButton"].frame.minY, callInvitee.frame.minY)
            let attachment = XCTAttachment(screenshot: app.screenshot())
            attachment.name = "Group shows a saved unsent invitation"
            attachment.lifetime = .keepAlways
            self.add(attachment)
            callInvitee.tap()
        case .person:
            saved.person.tap()
        }
    }

    @MainActor private func copyInvitation(
        in app: XCUIApplication, saved: SavedInvitee, entry: SavedInvitationEntry,
        advanced: Bool, labels: (unsent: String, shared: String)
    ) throws -> URL {
        let share = app.buttons["shareContactInvitationButton"]
        XCTAssertTrue(share.waitForExistence(timeout: 3))
        if entry == .settings {
            XCTAssertTrue(app.staticTexts["contactPersonSavedName"].firstMatch.label.hasSuffix(saved.nickname))
        }
        if !advanced {
            XCTAssertTrue(saved.personState.waitForExistence(timeout: 3))
            XCTAssertEqual(saved.personState.label, labels.unsent)
        }
        share.tap()
        let copy = cancelInvitationSharing(in: app)
        XCTAssertTrue(share.waitForExistence(timeout: 5))
        XCTAssertTrue(share.isHittable)
        if !advanced { XCTAssertEqual(saved.personState.label, labels.unsent) }
        switch entry {
        case .settings:
            let settingsInvitee = saved.settingsInvitee
            app.buttons["closeContactInvitationButton"].tap()
            XCTAssertTrue(settingsInvitee.waitForExistence(timeout: 5))
            XCTAssertTrue(settingsInvitee.label.contains(labels.unsent), settingsInvitee.label)
            settingsInvitee.tap()
            XCTAssertTrue(share.waitForExistence(timeout: 3))
            XCTAssertTrue(app.staticTexts["contactPersonSavedName"].firstMatch.label.hasSuffix(saved.nickname))
        case .call:
            let callInvitee = saved.callInvitee
            app.buttons["closeContactInvitationButton"].tap()
            XCTAssertTrue(callInvitee.waitForExistence(timeout: 5))
            XCTAssertTrue(
                callInvitee.label.contains("Not sent yet"), "Closing the share sheet leaves the invitation unsent"
            )
            callInvitee.tap()
            XCTAssertTrue(share.waitForExistence(timeout: 3))
        case .person:
            break
        }
        share.tap()
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        XCTAssertTrue(
            app.buttons["shareContactInvitationButton"].waitForExistence(timeout: 5),
            "Sharing keeps the same saved detail"
        )
        if !advanced {
            let updated = XCTNSPredicateExpectation(
                predicate: NSPredicate(format: "label == %@", labels.shared), object: saved.personState
            )
            XCTAssertEqual(XCTWaiter.wait(for: [updated], timeout: 5), .completed)
        }
        return try copiedURL(in: app)
    }

    @MainActor private func openInviteeSelection(
        in app: XCUIApplication, entry: String, advanced: Bool, fromStandardCall: Bool
    ) {
        guard entry != "new" else { return }
        app.buttons["saveUserSelectionButton"].tap()
        if fromStandardCall {
            let invite = app.buttons["addSavedUsersButton"]
            XCTAssertTrue(app.staticTexts["standardCallParticipantsHeading"].waitForExistence(timeout: 5))
            for _ in 0..<6 where !invite.isHittable { app.swipeUp() }
            XCTAssertTrue(invite.isHittable)
            invite.tap()
        } else {
            let more = app.buttons[advanced ? "callMoreMenu" : "callGroupSettingsButton"]
            XCTAssertTrue(more.waitForExistence(timeout: 5))
            more.tap()
            if entry == "settings" {
                if advanced { app.buttons["callGroupSettingsButton"].tap() }
                let invite = app.buttons["groupSettingsAddMembersButton"]
                XCTAssertTrue(invite.waitForExistence(timeout: 3))
                XCTAssertTrue(invite.isEnabled)
                invite.tap()
            } else {
                app.buttons["callAddMembersButton"].tap()
            }
        }
    }

    @MainActor private func finishSharing(
        in app: XCUIApplication, saved: SavedInvitee, entry: SavedInvitationEntry, shared: String
    ) {
        switch entry {
        case .settings:
            let settingsInvitee = saved.settingsInvitee
            app.buttons["closeContactInvitationButton"].tap()
            XCTAssertTrue(settingsInvitee.waitForExistence(timeout: 5))
            XCTAssertTrue(settingsInvitee.label.contains(shared), settingsInvitee.label)
            app.buttons["closeGroupSettingsButton"].tap()
        case .call:
            let callInvitee = saved.callInvitee
            let done = app.buttons["closeContactInvitationButton"]
            XCTAssertTrue(done.waitForExistence(timeout: 3))
            done.tap()
            XCTAssertTrue(callInvitee.waitForExistence(timeout: 5))
            XCTAssertTrue(callInvitee.label.contains("Waiting to be accepted"))
            app.buttons["callGroupSettingsButton"].tap()
            let state = app.staticTexts.matching(
                NSPredicate(format: "identifier BEGINSWITH %@", "groupSettingsInvitationState-")
            ).firstMatch
            XCTAssertTrue(state.waitForExistence(timeout: 3))
            XCTAssertEqual(state.label, "Waiting to be accepted")
            app.buttons["closeGroupSettingsButton"].tap()
        case .person:
            let finish = saved.finish
            if !finish.exists || !finish.isHittable { app.navigationBars.buttons.element(boundBy: 0).tap() }
            XCTAssertTrue(finish.waitForExistence(timeout: 3))
            finish.tap()
        }
    }

    @MainActor private func openSignedReply(
        in app: XCUIApplication, invitation: URL, groupName: String, advanced: Bool
    ) throws {
        let suffix = String(UUID().uuidString.prefix(6))
        let peer = "group-peer-" + suffix
        app.open(try InvitationURLFixture.acceptance(invitation, invitee: peer, sharedName: "Remote " + suffix))
        openSavedGroupSettings(in: app, groupName: groupName, advanced: advanced)
        let member = app.descendants(matching: .any)["groupSettingsMember-" + peer].firstMatch
        XCTAssertTrue(member.waitForExistence(timeout: 5), "The signed reply adds its member to this group")
    }

    @MainActor private func copiedURL(in app: XCUIApplication) throws -> URL {
        let edit = app.buttons["editContactPersonNameButton"]
        for _ in 0..<8 where !edit.exists || !edit.isHittable { app.swipeDown() }
        XCTAssertTrue(edit.exists)
        edit.tap()
        let field = app.textFields["savedUserNameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (field.value as? String ?? "").count))
        field.press(forDuration: 1)
        let menu = app.menuItems["Paste"]
        let button = app.buttons["Paste"]
        if menu.waitForExistence(timeout: 2) {
            menu.tap()
        } else {
            XCTAssertTrue(button.waitForExistence(timeout: 2))
            button.tap()
        }
        let value = try XCTUnwrap(field.value as? String)
        app.buttons["closeUserSettingsButton"].tap()
        let match = try XCTUnwrap(value.range(of: #"rideintercom://[^\s]+"#, options: .regularExpression))
        return try XCTUnwrap(URL(string: String(value[match])))
    }
}
#endif
