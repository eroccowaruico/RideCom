import XCTest

extension StandardInterfaceUITests {
    #if os(iOS)
    @MainActor
    @objc
    func testGeneratedGroupNamesCreateRenameAndPersistInBothLayouts() throws {
        for mode in ["standard", "advanced"] {
            terminateAppIfLaunched()
            launch(interface: mode)
            tab("Groups", id: "groupsTab")
            app.buttons["standardCreateGroupButton"].firstMatch.tap()
            let name = app.textFields["savedUsersGroupNameField"].firstMatch
            XCTAssertTrue(name.waitForExistence(timeout: 3))
            let generated = try XCTUnwrap(name.value as? String)
            XCTAssertNotNil(generated.range(of: "^Group [A-F0-9]{6}$", options: .regularExpression))
            let save = app.buttons["saveUserSelectionButton"].firstMatch
            XCTAssertTrue(save.isEnabled, "A new group needs no typed name or selected members")
            screenshot("Generated group name in \(mode)")
            save.tap()
            let end = app.buttons[mode == "standard" ? "standardEndCallButton" : "disconnectButton"].firstMatch
            XCTAssertTrue(end.waitForExistence(timeout: 5))
            app.openCallMoreMenuItem("callGroupSettingsButton").tap()
            let savedName = app.textFields["groupSettingsNameField"].firstMatch
            XCTAssertTrue(savedName.waitForExistence(timeout: 3))
            XCTAssertEqual(savedName.value as? String, generated)
            let renamed = "Renamed " + UUID().uuidString.prefix(6)
            savedName.tap()
            savedName.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: generated.count) + renamed)
            app.buttons["saveGroupSettingsButton"].firstMatch.tap()
            XCTAssertTrue(savedName.waitForNonExistence(timeout: 3))
            end.tap()
            if mode == "standard" { app.buttons["standardConfirmEndCallButton"].firstMatch.tap() }
            tab("Groups", id: "groupsTab")
            app.buttons["standardCreateGroupButton"].firstMatch.tap()
            XCTAssertTrue(name.waitForExistence(timeout: 3))
            let second = try XCTUnwrap(name.value as? String)
            XCTAssertNotNil(second.range(of: "^Group [A-F0-9]{6}$", options: .regularExpression))
            XCTAssertNotEqual(second, generated)
            let manual = "Manual " + UUID().uuidString.prefix(6)
            name.tap()
            name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: second.count) + manual)
            save.tap()
            XCTAssertTrue(end.waitForExistence(timeout: 5))
            end.tap()
            if mode == "standard" { app.buttons["standardConfirmEndCallButton"].firstMatch.tap() }
            app.terminate(); app.launch(); app.activate()
            tab("Groups", id: "groupsTab")
            for title in [renamed, manual] {
                let row = app.buttons
                    .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                          "standardGroup-", title)).firstMatch
                let list = app.descendants(matching: .any)["standardGroupsList"].firstMatch
                for _ in 0..<15 where !row.exists { list.swipeUp() }
                XCTAssertTrue(row.exists, "The saved name survives relaunch: \(title)")
            }
        }
    }

    @MainActor
    @objc
    func testJapaneseNewGroupStartsWithAnEditableGeneratedName() throws {
        launch(japanese: true)
        tab("グループ", id: "groupsTab")
        app.buttons["standardCreateGroupButton"].firstMatch.tap()
        let name = app.textFields["savedUsersGroupNameField"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let generated = try XCTUnwrap(name.value as? String)
        XCTAssertNotNil(generated.range(of: "^グループ [A-F0-9]{6}$", options: .regularExpression))
        screenshot("Japanese generated group name")
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: generated.count))
        XCTAssertEqual(name.placeholderValue, generated)
        let save = app.buttons["saveUserSelectionButton"].firstMatch
        XCTAssertTrue(save.isEnabled)
        save.tap()
        XCTAssertTrue(app.buttons["standardEndCallButton"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)["standardCallHero"].firstMatch.label.contains(generated))
    }

    @MainActor
    @objc
    func testJoinedGroupHasNoSwipeDeleteInEitherLayout() throws {
        launch()
        let groupName = "Joined " + UUID().uuidString.prefix(6)
        app.open(try InvitationURLFixture.make(inviter: "ui-joined-" + UUID().uuidString, name: groupName))
        XCTAssertTrue(app.buttons["standardEndCallButton"].firstMatch.waitForExistence(timeout: 5))
        for mode in ["Standard", "Advanced"] {
            if mode == "Advanced" {
                tab("Settings", id: "settingsTab")
                selectLayout(mode)
            }
            tab("Groups", id: "groupsTab")
            let row = app.buttons
                .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                      "standardGroup-", groupName)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 3))
            row.swipeLeft()
            XCTAssertTrue(app.buttons["Group Settings"].firstMatch.waitForExistence(timeout: 3))
            XCTAssertFalse(app.buttons["Delete"].firstMatch.exists, "Only the owner deletes a group in \(mode)")
            screenshot("Joined group's shared row actions in \(mode)")
            app.buttons["Group Settings"].firstMatch.tap()
            let leave = app.buttons["leaveGroupButton"].firstMatch
            XCTAssertTrue(leave.waitForExistence(timeout: 3), "A joined group offers Leave Group in \(mode)")
            XCTAssertFalse(app.buttons["deleteGroupButton"].exists)
            leave.tap()
            let alert = app.alerts.firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 3))
            XCTAssertTrue(alert.staticTexts["Leave \(groupName)?"].exists)
            XCTAssertTrue(alert.staticTexts["The current connection ends."].exists)
            let confirm = alert.buttons["confirmLeaveGroupButton"].firstMatch
            XCTAssertEqual(confirm.label, "Disconnect and Leave")
            screenshot("Joined group leave confirmation in \(mode)")
            alert.buttons["Cancel"].firstMatch.tap()
            XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
            if mode == "Advanced" {
                leave.tap()
                XCTAssertTrue(confirm.waitForExistence(timeout: 3))
                confirm.tap()
                XCTAssertTrue(row.waitForNonExistence(timeout: 5))
                XCTAssertFalse(app.buttons["callAccessoryOpenButton"].exists)
            } else {
                app.buttons["closeGroupSettingsButton"].firstMatch.tap()
                XCTAssertTrue(row.waitForExistence(timeout: 3))
                XCTAssertTrue(app.buttons["callAccessoryOpenButton"].firstMatch.exists)
            }
        }
    }

    @MainActor
    @objc
    func testMemberRemovalRequiresAnActivePassInBothLayouts() throws {
        launch(storeCatalog: "unavailable")
        let suffix = UUID().uuidString
        let inviter = "ui-member-access-" + suffix
        let groupName = "Joined " + suffix.prefix(6)
        let riderName = "Rider " + suffix.prefix(6)
        app.open(try InvitationURLFixture.make(inviter: inviter, sharedName: riderName, name: groupName))
        for mode in ["Standard", "Advanced"] {
            if mode == "Advanced" {
                tab("Settings", id: "settingsTab")
                selectLayout(mode)
            }
            tab("Groups", id: "groupsTab")
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                       "standardGroup-", groupName)).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5))
            row.swipeLeft()
            let settings = app.buttons["Group Settings"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 3))
            settings.tap()

            let rider = app.staticTexts[riderName].firstMatch
            XCTAssertTrue(rider.waitForExistence(timeout: 3))
            rider.swipeLeft()
            let editName = app.buttons["Edit Name"].firstMatch
            if mode == "Advanced" { XCTAssertTrue(editName.waitForExistence(timeout: 3)) }
            XCTAssertFalse(app.buttons["Remove"].firstMatch.exists, "The swipe hides Remove in \(mode)")
            if mode == "Standard" {
                app.buttons["groupSettingsMember-" + inviter].firstMatch.tap()
                let name = app.textFields["groupMemberNameField"].firstMatch
                XCTAssertTrue(name.waitForExistence(timeout: 3))
                XCTAssertFalse(app.buttons["removeGroupMemberButton"].firstMatch.exists)
                app.navigationBars.buttons["Cancel"].firstMatch.tap()
            } else {
                editName.tap()
                XCTAssertTrue(app.textFields["groupMemberNameField"].firstMatch.waitForExistence(timeout: 3))
                app.navigationBars.buttons["Cancel"].firstMatch.tap()
            }
            let close = app.buttons["closeGroupSettingsButton"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 3))
            close.tap()
        }
    }

    @MainActor
    @objc
    func testInviteEntrancesRequireAnActivePassInBothLayouts() throws {
        launch(storeCatalog: "unavailable")
        let groupName = "Joined " + UUID().uuidString.prefix(6)
        app.open(try InvitationURLFixture.make(inviter: "ui-invite-access-" + UUID().uuidString, name: groupName))
        XCTAssertTrue(app.buttons["standardEndCallButton"].firstMatch.waitForExistence(timeout: 5))
        for advanced in [false, true] {
            if advanced {
                tab("Settings", id: "settingsTab")
                selectLayout("Advanced")
                app.openCurrentCall()
                let more = app.buttons["callMoreMenu"].firstMatch
                XCTAssertTrue(more.waitForExistence(timeout: 3))
                more.tap()
                XCTAssertFalse(app.buttons["callAddMembersButton"].firstMatch.exists)
            } else {
                XCTAssertFalse(app.buttons["addSavedUsersButton"].firstMatch.exists)
            }
            let settings = app.buttons["callGroupSettingsButton"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 3))
            settings.tap()
            let close = app.buttons["closeGroupSettingsButton"].firstMatch
            XCTAssertTrue(close.waitForExistence(timeout: 3))
            XCTAssertFalse(app.buttons["groupSettingsAddMembersButton"].firstMatch.exists)
            close.tap()
            XCTAssertTrue(close.waitForNonExistence(timeout: 3))
        }
        for mode in ["Advanced", "Standard"] {
            if mode == "Standard" {
                tab("Settings", id: "settingsTab")
                selectLayout("Standard")
            }
            tab("Groups", id: "groupsTab")
            let create = app.buttons["standardCreateGroupButton"].firstMatch
            XCTAssertTrue(create.waitForExistence(timeout: 3))
            XCTAssertFalse(create.isEnabled)
        }
    }

    @MainActor
    @objc
    func testAdvancedOwnerCanDeleteFromGroupSettings() {
        launch(interface: "advanced")
        tab("Groups", id: "groupsTab")
        app.buttons["standardCreateGroupButton"].firstMatch.tap()
        let name = app.textFields["savedUsersGroupNameField"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let groupName = "Owned " + UUID().uuidString.prefix(6)
        name.tap()
        let entered = (name.value as? String)?.count ?? 0
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: entered) + groupName)
        app.buttons["saveUserSelectionButton"].firstMatch.tap()
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 5))
        tab("Groups", id: "groupsTab")
        let row = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                  "standardGroup-", groupName)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.swipeLeft()
        let settings = app.buttons["Group Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()
        let delete = app.buttons["deleteGroupButton"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["leaveGroupButton"].exists)
        delete.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(alert.staticTexts["Delete \(groupName)?"].exists)
        let confirm = alert.buttons["confirmDeleteGroupButton"].firstMatch
        XCTAssertEqual(confirm.label, "Disconnect and Delete")
        alert.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        delete.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["callAccessoryOpenButton"].exists)
        screenshot("Advanced owner's group deleted through settings")
    }

    @MainActor
    @objc
    func testStandardGroupDeleteSaveFailureKeepsSettingsAndCall() throws {
        try checkGroupRemovalSaveFailure(advanced: false)
    }

    @MainActor
    @objc
    func testAdvancedGroupLeaveSaveFailureKeepsSettingsAndCall() throws {
        try checkGroupRemovalSaveFailure(advanced: true)
    }

    @MainActor
    private func checkGroupRemovalSaveFailure(advanced: Bool) throws {
        let personID = UUID()
        prepareApp()
        app.launchEnvironment = ["RIDEINTERCOM_LOCAL_TESTING": "1", "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in",
            "RIDEINTERCOM_INTERFACE_FIXTURE": advanced ? "advanced" : "standard",
            "RIDEINTERCOM_FAIL_GROUP_REMOVAL": "1",
            "RIDEINTERCOM_CONTACT_NAME_FIXTURE": personID.uuidString]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        let groupName: String
        if advanced {
            groupName = "Joined " + UUID().uuidString.prefix(6)
            app.open(try InvitationURLFixture.make(inviter: "ui-failed-leave-" + UUID().uuidString, name: groupName))
        } else {
            tab("Groups", id: "groupsTab")
            app.buttons["standardCreateGroupButton"].firstMatch.tap()
            let name = app.textFields["savedUsersGroupNameField"].firstMatch
            XCTAssertTrue(name.waitForExistence(timeout: 3))
            groupName = try XCTUnwrap(name.value as? String)
            app.buttons["saveUserSelectionButton"].firstMatch.tap()
        }
        let end = app.buttons[advanced ? "disconnectButton" : "standardEndCallButton"].firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        app.openCallMoreMenuItem("callGroupSettingsButton").tap()
        let remove = app.buttons[advanced ? "leaveGroupButton" : "deleteGroupButton"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        remove.tap()
        let confirmationID = advanced ? "confirmLeaveGroupButton" : "confirmDeleteGroupButton"
        let confirm = app.alerts.firstMatch.buttons[confirmationID].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()

        let error = app.staticTexts["groupSettingsError"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5), "A failed save must explain recovery in the same settings")
        XCTAssertEqual(app.textFields["groupSettingsNameField"].firstMatch.value as? String, groupName)
        app.buttons["closeGroupSettingsButton"].firstMatch.tap()
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        tab("Users", id: "usersTab")
        XCTAssertTrue(app.descendants(matching: .any)["groupStorageStatus"].firstMatch.waitForExistence(timeout: 3))
        let user = app.buttons["standardUser-" + personID.uuidString].firstMatch
        let list = app.descendants(matching: .any)["standardUsersList"].firstMatch
        for _ in 0..<8 where !user.isHittable { list.swipeUp() }
        XCTAssertTrue(user.isHittable)
        user.swipeLeft()
        let userSettings = app.buttons["User Settings"].firstMatch
        XCTAssertTrue(userSettings.waitForExistence(timeout: 3))
        screenshot("Saved user actions while storage needs recovery")
        XCTAssertFalse(app.buttons["Delete"].firstMatch.exists, "Read-only storage must not offer deletion")
        userSettings.tap()
        let deleteUser = app.buttons["deleteUserButton"].firstMatch
        XCTAssertTrue(deleteUser.waitForExistence(timeout: 3))
        XCTAssertFalse(deleteUser.isEnabled)
    }

    @MainActor
    @objc
    func testJapaneseAdvancedJoinedGroupCanLeaveWithSharedConfirmation() throws {
        launch(japanese: true, interface: "advanced")
        let groupName = "招待 " + UUID().uuidString.prefix(6)
        app.open(try InvitationURLFixture.make(inviter: "ui-joined-ja-" + UUID().uuidString, name: groupName))
        XCTAssertTrue(app.buttons["disconnectButton"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["callMoreMenu"].firstMatch.tap()
        let settings = app.buttons["callGroupSettingsButton"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()
        let leave = app.buttons["leaveGroupButton"].firstMatch
        XCTAssertTrue(leave.waitForExistence(timeout: 3))
        XCTAssertEqual(leave.label, "グループから抜ける")
        leave.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 3))
        XCTAssertTrue(alert.staticTexts["\(groupName)から抜けますか？"].exists)
        let confirm = alert.buttons["confirmLeaveGroupButton"].firstMatch
        XCTAssertEqual(confirm.label, "切断して抜ける")
        screenshot("Japanese shared group leave confirmation")
        alert.buttons["キャンセル"].firstMatch.tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        XCTAssertTrue(leave.exists)
        leave.tap()
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertTrue(app.descendants(matching: .any)["groupSettingsView"].firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.buttons["callAccessoryOpenButton"].exists)
    }
    #endif
}
