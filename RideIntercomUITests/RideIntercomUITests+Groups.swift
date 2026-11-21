import CryptoKit
import XCTest

extension RideIntercomUITests {
    @MainActor
    @objc
    func testInvitationShareUsesSystemSheetAndReturnsToCall() throws {
        createTalkGroupAndOpenCall()
        assertAdvancedCallHasNoManagementControls()
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 3))
        openTalkGroupManagement()
        XCTAssertTrue(app.buttons["groupSettingsAddMembersButton"].exists)
        copyManagementInvitation()
        attachScreen("Advanced group management after native invitation sharing")
        closeManagementAndReturnToCall()
        let emptyParticipants = app.descendants(matching: .any)["emptyRemoteParticipantsLabel"].firstMatch
        XCTAssertTrue(emptyParticipants.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 3))
        assertAdvancedCallHasNoManagementControls()
        XCTAssertFalse(app.staticTexts["groupErrorLabel"].exists)
    }

    #if os(iOS)
    @MainActor
    @objc
    func testStandardHasNoBareGroupLinkAndKeepsPeople() throws {
        let suffix = UUID().uuidString
        let existingRider = "Existing Rider \(suffix)"
        try openSavedUserInvitation(inviter: "ui-share-\(suffix)", sharedName: existingRider)
        XCTAssertTrue(app.staticTexts[existingRider].firstMatch.waitForExistence(timeout: 3))
        openSettingsTab()
        selectSettingsLayout("Standard")
        app.tabBars.buttons["Users"].tap()
        XCTAssertTrue(app.staticTexts[existingRider].firstMatch.waitForExistence(timeout: 3))
        let savedUsers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardUser-"))
        let savedUserCount = savedUsers.count
        app.openCurrentCall()
        XCTAssertTrue(app.descendants(matching: .any)["standardCallScreen"].firstMatch.waitForExistence(timeout: 5))
        revealStandardCallElement(app.staticTexts[existingRider].firstMatch)
        XCTAssertTrue(app.staticTexts[existingRider].firstMatch.exists)
        // Standard shares no bare group link: not in the call, not in Group Settings (Advanced keeps it).
        XCTAssertFalse(app.buttons["inviteButton"].exists)
        XCTAssertFalse(app.buttons["callMoreMenu"].exists)
        app.buttons["callGroupSettingsButton"].firstMatch.tap()
        let close = app.buttons["closeGroupSettingsButton"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["groupSettingsInviteButton"].exists, "No link without a recipient in Standard")
        // This group came from someone's invitation: only its maker deletes it, everyone else leaves.
        XCTAssertTrue(app.buttons["leaveGroupButton"].exists, app.debugDescription)
        XCTAssertFalse(app.buttons["deleteGroupButton"].exists)
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 3))
        revealStandardCallElement(app.staticTexts[existingRider].firstMatch)
        XCTAssertTrue(app.staticTexts[existingRider].firstMatch.exists)
        app.closeCallIfOpen()
        app.tabBars.buttons["Users"].tap()
        XCTAssertTrue(app.staticTexts[existingRider].firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(savedUsers.count, savedUserCount)
        XCTAssertFalse(app.staticTexts["Invited Rider 2"].exists)
        XCTAssertFalse(app.staticTexts["Invited Rider 3"].exists)
        app.terminate(); app.launch(); app.activate()
        openSettingsTab()
        selectSettingsLayout("Standard")
        app.tabBars.buttons["Groups"].tap()
        let group = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                  "standardGroup-", "Talk Group")).firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 5))
        group.tap()
        revealStandardCallElement(app.staticTexts[existingRider].firstMatch)
        XCTAssertTrue(app.staticTexts[existingRider].firstMatch.exists)
        XCTAssertFalse(app.staticTexts["Invited Rider 2"].exists)
        XCTAssertFalse(app.staticTexts["Invited Rider 3"].exists)
    }

    @MainActor
    private func revealStandardCallElement(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let list = app.collectionViews["standardCallScreen"]
        XCTAssertTrue(list.waitForExistence(timeout: 3), file: file, line: line)
        for down in [false, true] {
            for _ in 0..<6 {
                if element.exists && element.isHittable { return }
                let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.3 : 0.7))
                let end = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: down ? 0.7 : 0.3))
                start.press(forDuration: 0.05, thenDragTo: end)
            }
        }
        XCTAssertTrue(element.isHittable, "Expected the Call control after scrolling", file: file, line: line)
    }

    #endif

    @MainActor
    func openSavedUserInvitation(inviter: String, sharedName: String? = nil) throws {
        let memberID = inviter + "-" + inviterRun
        let signingKey = try P256.Signing.PrivateKey(rawRepresentation: Data(SHA256.hash(data: Data(memberID.utf8))))
        app.open(try InvitationURLFixture.make(inviter: memberID, sharedName: sharedName, signingKey: signingKey))
        XCTAssertTrue(app.descendants(matching: .any)["remoteParticipantRow0"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    @objc
    func testDirectCallsReuseUserDestinationWithoutAddingParticipants() throws {
        try openSavedUserInvitation(inviter: "ui-direct-rider")
        openUsersTab()
        let user = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardUser-")).firstMatch
        XCTAssertTrue(user.waitForExistence(timeout: 3))
        user.tap()
        // The invitation's group is still connected: choosing the person only shows that call, so end it first.
        XCTAssertFalse(app.alerts.firstMatch.waitForExistence(timeout: 1), "No switch confirmation")
        let disconnect = app.buttons["disconnectButton"].firstMatch
        XCTAssertTrue(disconnect.waitForExistence(timeout: 3))
        XCTAssertFalse(app.staticTexts["directCallHelpLabel"].exists)
        disconnect.tap()
        openUsersTab()
        XCTAssertTrue(user.waitForExistence(timeout: 3))
        user.tap()
        XCTAssertTrue(app.staticTexts["directCallHelpLabel"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["addSavedUsersButton"].exists)
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 3))
        assertAdvancedCallHasNoManagementControls()
        openUsersTab()
        let userID = String(user.identifier.dropFirst("standardUser-".count))
        let userRow = app.buttons["standardUser-" + userID].firstMatch
        openRowSettings(userRow, "User Settings", view: "userSettingsView")
        XCTAssertFalse(app.buttons["groupSettingsAddMembersButton"].exists)
        copyManagementInvitation(identifier: "userSettingsInviteButton", view: "userSettingsView")
        closeManagementAndReturnToCall()
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 3))
        attachScreen("Individual Call with Saved User")
        openGroupsTab()
        XCTAssertTrue(app.buttons["standardCurrentCallButton"].waitForExistence(timeout: 3))
        let groupRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardGroup-"))
        XCTAssertFalse(groupRows.containing(.staticText, identifier: "Direct Call").firstMatch.exists)
        attachScreen("Users and Groups with Current Individual Call")
        app.terminate(); app.launch(); app.activate()
        openUsersTab()
        XCTAssertTrue(user.waitForExistence(timeout: 3))
        user.tap()
        XCTAssertTrue(app.staticTexts["directCallHelpLabel"].waitForExistence(timeout: 3))
        if app.buttons["connectButton"].exists { app.buttons["connectButton"].tap() }
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 3))
        try deleteConnectedUser(user, row: userRow)
    }

    @MainActor
    private func deleteConnectedUser(_ user: XCUIElement, row: XCUIElement) throws {
        // Deleting the person you are talking with asks to disconnect, then removes
        // the person, their direct group and the call together.
        openGroupsTab()
        let directGroupCount = try advancedDirectGroupCount()
        XCTAssertGreaterThan(directGroupCount, 0)
        openUsersTab()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.swipeLeft()
        app.buttons["Delete"].firstMatch.tap()
        let confirmDelete = app.buttons["confirmDeleteDestinationButton"].firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 3))
        XCTAssertEqual(confirmDelete.label, "Disconnect and Delete")
        XCTAssertTrue(app.alerts.staticTexts["The current connection ends."].exists)
        attachScreen("Deleting the Connected User Asks to Disconnect")
        confirmDelete.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 3))
        XCTAssertFalse(user.exists)
        openGroupsTab()
        XCTAssertFalse(app.buttons["standardCurrentCallButton"].exists, "The call with the deleted person ended")
        XCTAssertEqual(try advancedDirectGroupCount(), directGroupCount - 1,
                       "The person's direct group is deleted with them")
        attachScreen("User and Direct Group Removed Together")
        try checkGroupDeletionCanBeExercisedFromUI()
    }

    /// The saved target stays visible; sharing is optional and Done closes the sheet.
    @MainActor
    private func finishSavingGroupInvitations(_ screen: String) {
        XCTAssertTrue(app.staticTexts["savedInvitationGroupID"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["addedUsersInviteButton"].exists)
        attachScreen(screen)
        app.buttons["finishAddingUsersButton"].tap()
        XCTAssertTrue(app.buttons["finishAddingUsersButton"].waitForNonExistence(timeout: 3))
    }

    @MainActor
    @objc
    func testSavedUsersSurviveGroupDeletionAndCanBeReused() throws {
        try openSavedUserInvitation(inviter: "ui-saved-rider")
        try checkGroupDeletionCanBeExercisedFromUI()
        // Restart only here: this case explicitly verifies persisted users.
        app.terminate(); app.launch(); app.activate()
        openUsersTab()
        let savedUserRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardUser-"))
            .firstMatch
        openRowSettings(savedUserRow, "User Settings", view: "userSettingsView")
        let field = app.textFields["savedUserNameField"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        let enteredName = field.value as? String ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: enteredName.count) + "Alex")
        app.buttons["saveUserNameButton"].tap()
        XCTAssertTrue(field.waitForNonExistence(timeout: 3))
        let toggle = try createGroupWithSavedUser()
        addSavedUserToExistingGroup(toggle)
        try deleteSavedUserAndManageRemainingGroup(toggle)
    }

    @MainActor
    private func createGroupWithSavedUser() throws -> XCUIElement {
        openGroupsTab()
        app.buttons["standardCreateGroupButton"].tap()
        // A row only selects: a checkmark and the selected state, no pencil or delete.
        let firstUser = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "selectUser-")).firstMatch
        XCTAssertTrue(firstUser.waitForExistence(timeout: 3))
        let toggle = app.buttons[firstUser.identifier]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        XCTAssertTrue(toggle.label.contains("Alex"))
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "editUser-")).firstMatch.exists
        )
        toggle.tap()
        XCTAssertTrue(toggle.isSelected)
        XCTAssertTrue(app.navigationBars["New Group"].exists, "The sheet is titled New Group")
        // The editable generated name stays when people are selected.
        let groupName = app.textFields["savedUsersGroupNameField"]
        let generated = groupName.value as? String ?? ""
        XCTAssertNotNil(generated.range(of: "^Group [A-F0-9]{6}$", options: .regularExpression))
        groupName.tap()
        groupName.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: generated.count) + "Talk Group")
        attachScreen("Saved Users Selection")
        app.buttons["saveUserSelectionButton"].tap()
        finishSavingGroupInvitations("New Group with Saved User invitation step")
        XCTAssertTrue(app.descendants(matching: .any)["remoteParticipantRow0"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Alex"].firstMatch.exists)
        assertAdvancedCallHasNoManagementControls()
        openTalkGroupManagement()
        XCTAssertTrue(app.buttons["groupSettingsInviteButton"].exists)
        attachScreen("Group Created from Saved User management")
        closeManagementAndReturnToCall()
        try checkGroupDeletionCanBeExercisedFromUI()
        return toggle
    }

    @MainActor
    private func deleteSavedUserAndManageRemainingGroup(_ toggle: XCUIElement) throws {
        // Deleting the saved user from the Users list (it asks first) keeps the group and its member.
        openUsersTab()
        let alexRow = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                  "standardUser-", "Alex")).firstMatch
        XCTAssertTrue(alexRow.waitForExistence(timeout: 3))
        let alexEntry = app.buttons[alexRow.identifier].firstMatch
        alexEntry.swipeLeft()
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        delete.tap()
        let confirmDelete = app.buttons["confirmDeleteDestinationButton"].firstMatch
        XCTAssertTrue(confirmDelete.waitForExistence(timeout: 3)); confirmDelete.tap()
        XCTAssertTrue(alexEntry.waitForNonExistence(timeout: 3))
        attachScreen("Saved User Removed while Group Remains")
        openGroupsTab()
        talkGroupRows.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Alex"].firstMatch.waitForExistence(timeout: 3))
        assertAdvancedCallHasNoManagementControls()
        openTalkGroupManagement()
        renameAndRemoveGroupMember()
        try checkGroupDeletionCanBeExercisedFromUI()
        app.terminate(); app.launch(); app.activate()
        openGroupsTab()
        app.buttons["standardCreateGroupButton"].tap()
        XCTAssertFalse(toggle.exists)
        app.buttons["closeSavedUsersButton"].tap()
    }

    @MainActor
    private func renameAndRemoveGroupMember() {
        // Member names change from the row's swipe or menu in Group Settings.
        let participant = app.staticTexts["Alex"].firstMatch
        XCTAssertTrue(participant.waitForExistence(timeout: 3))
        participant.swipeLeft()
        app.buttons["Edit Name"].firstMatch.tap()
        let memberName = app.textFields["groupMemberNameField"]
        XCTAssertTrue(memberName.waitForExistence(timeout: 3))
        memberName.tap()
        let enteredMemberName = (memberName.value as? String)?.count ?? 0
        memberName.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: enteredMemberName) + "Group Alex")
        app.buttons["saveGroupMemberNameButton"].tap()
        let renamed = app.staticTexts["Group Alex"].firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 3))
        attachScreen("Advanced group participant name edited in management")
        renamed.swipeLeft()
        let removeMember = app.buttons["Remove"].firstMatch
        XCTAssertTrue(removeMember.waitForExistence(timeout: 3))
        removeMember.tap()
        // Removing a member asks first, naming the member.
        let removal = app.alerts.firstMatch
        XCTAssertTrue(removal.waitForExistence(timeout: 3))
        XCTAssertTrue(removal.staticTexts["Remove Group Alex from the group?"].exists, removal.debugDescription)
        attachScreen("Remove member asks first")
        removal.buttons["confirmRemoveMemberButton"].firstMatch.tap()
        XCTAssertTrue(renamed.waitForNonExistence(timeout: 3))
        closeManagementAndReturnToCall()
        let emptyParticipants = app.descendants(matching: .any)["emptyRemoteParticipantsLabel"].firstMatch
        XCTAssertTrue(emptyParticipants.waitForExistence(timeout: 3))
    }

    @MainActor
    private func addSavedUserToExistingGroup(_ toggle: XCUIElement) {
        createTalkGroupAndOpenCall()
        assertAdvancedCallHasNoManagementControls()
        openTalkGroupManagement()
        let add = app.buttons["groupSettingsAddMembersButton"]
        for _ in 0..<4 where !add.isHittable { app.swipeUp() }
        XCTAssertTrue(add.isEnabled)
        add.tap()
        XCTAssertTrue(toggle.waitForExistence(timeout: 3))
        toggle.tap()
        XCTAssertTrue(toggle.isSelected)
        app.buttons["saveUserSelectionButton"].tap()
        finishSavingGroupInvitations("Saved User Added invitation step")
        XCTAssertTrue(app.staticTexts["Alex"].firstMatch.waitForExistence(timeout: 3))
        attachScreen("Saved User Added to Existing Group management")
        closeManagementAndReturnToCall()
        XCTAssertTrue(app.staticTexts["Alex"].firstMatch.waitForExistence(timeout: 3))
        assertAdvancedCallHasNoManagementControls()
    }
}
