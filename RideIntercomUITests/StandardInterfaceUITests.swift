import XCTest

final class StandardInterfaceUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws { continueAfterFailure = false }
    override func tearDownWithError() throws { app?.terminate(); app = nil }

    @MainActor func testStandardAccountWithEightDevicesUsesOneSelectionSlot() throws {
        try multiDeviceGroupSelection(advanced: false)
    }

    @MainActor func testAdvancedAccountWithEightDevicesUsesOneSelectionSlot() throws {
        try multiDeviceGroupSelection(advanced: true)
    }

    @MainActor private func multiDeviceGroupSelection(advanced: Bool) throws {
        let personID = UUID()
        app = XCUIApplication()
        app.launchEnvironment = ["RIDEINTERCOM_LOCAL_TESTING": "1", "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in",
            "RIDEINTERCOM_INTERFACE_FIXTURE": advanced ? "advanced" : "standard",
            "RIDEINTERCOM_MEMBER_SELECTION_FIXTURE": personID.uuidString]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); app.activate()
        tab("Groups", id: "groupsTab")
        app.buttons["standardCreateGroupButton"].firstMatch.tap()
        let name = app.textFields["savedUsersGroupNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        let generated = try XCTUnwrap(name.value as? String), groupName = "Two people " + String(personID.uuidString.prefix(6))
        name.tap(); name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: generated.count) + groupName + "\n")
        let row = app.buttons["selectUser-" + personID.uuidString].firstMatch
        let form = app.collectionViews.firstMatch
        for _ in 0..<20 where !row.exists || !row.isHittable { form.swipeUp() }
        XCTAssertTrue(row.exists); row.tap()
        let count = advanced ? app.staticTexts.matching(NSPredicate(format: "label ENDSWITH %@", " of 8 members including you")).firstMatch : app.staticTexts["memberSelectionCount"]
        for _ in 0..<6 where !count.exists { form.swipeUp() }
        XCTAssertEqual(count.label, advanced ? "2 of 8 members including you" : "2/8 people including you")
        let save = app.buttons["saveUserSelectionButton"]
        XCTAssertTrue(save.isEnabled)
        screenshot("One account with eight devices occupies one group slot")
        save.tap()
        XCTAssertTrue(app.buttons["finishAddingUsersButton"].waitForExistence(timeout: 5))
        app.buttons["finishAddingUsersButton"].tap()
        let settings = app.buttons[advanced ? "callMoreMenu" : "callGroupSettingsButton"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        if advanced { app.buttons["callGroupSettingsButton"].tap() }
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", String(personID.uuidString.prefix(6)))).firstMatch.exists)
        screenshot("Created group keeps the selected person once")
    }

    @MainActor
    func testInvitationFailureExplainsRecoveryInBothEnglishLayouts() {
        checkInvitationFailure(japanese: false)
    }

    @MainActor
    func testInvitationFailureExplainsRecoveryInBothJapaneseLayouts() {
        checkInvitationFailure(japanese: true)
    }

    @MainActor private func checkInvitationFailure(japanese: Bool) {
        #if os(iOS)
        launch(japanese: japanese)
        let message = japanese
            ? "この招待を確認できませんでした。送信者に新しい招待を依頼してください。"
            : "This invitation could not be verified. Ask the sender for a new invitation."
        let url = URL(string: "rideintercom://join?token=invalid")!
        app.open(url)
        XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 5))
        screenshot("Invitation recovery in Standard")
        tab(japanese ? "設定" : "Settings", id: "settingsTab")
        selectLayout(japanese ? "詳細" : "Advanced")
        // open(URL) may relaunch and reapply the Standard launch fixture.
        // Keep this process and verify the actual Advanced error surface.
        // Without a call, the reason stays on the list instead of an empty call screen.
        tab(japanese ? "ユーザー" : "Users", id: "usersTab")
        XCTAssertFalse(app.descendants(matching: .any)["standardCallScreen"].firstMatch.exists)
        XCTAssertTrue(app.descendants(matching: .any)["groupErrorLabel"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 5))
        screenshot("Invitation recovery in Advanced")
        #endif
    }

    #if os(iOS)
    @MainActor
    func testGeneratedGroupNamesCreateRenameAndPersistInBothLayouts() throws {
        for mode in ["standard", "advanced"] {
            app?.terminate()
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
                let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "standardGroup-", title)).firstMatch
                let list = app.descendants(matching: .any)["standardGroupsList"].firstMatch
                for _ in 0..<15 where !row.exists { list.swipeUp() }
                XCTAssertTrue(row.exists, "The saved name survives relaunch: \(title)")
            }
        }
    }

    @MainActor
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
            let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "standardGroup-", groupName)).firstMatch
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
    func testAdvancedOwnerCanDeleteFromGroupSettings() {
        launch(interface: "advanced")
        tab("Groups", id: "groupsTab")
        app.buttons["standardCreateGroupButton"].firstMatch.tap()
        let name = app.textFields["savedUsersGroupNameField"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let groupName = "Owned " + UUID().uuidString.prefix(6)
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String)?.count ?? 0) + groupName)
        app.buttons["saveUserSelectionButton"].firstMatch.tap()
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 5))
        tab("Groups", id: "groupsTab")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "standardGroup-", groupName)).firstMatch
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
    func testStandardGroupDeleteSaveFailureKeepsSettingsAndCall() throws {
        try checkGroupRemovalSaveFailure(advanced: false)
    }

    @MainActor
    func testAdvancedGroupLeaveSaveFailureKeepsSettingsAndCall() throws {
        try checkGroupRemovalSaveFailure(advanced: true)
    }

    @MainActor
    private func checkGroupRemovalSaveFailure(advanced: Bool) throws {
        app = XCUIApplication()
        app.launchEnvironment = ["RIDEINTERCOM_LOCAL_TESTING": "1", "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in",
            "RIDEINTERCOM_INTERFACE_FIXTURE": advanced ? "advanced" : "standard", "RIDEINTERCOM_FAIL_GROUP_REMOVAL": "1"]
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
        let confirm = app.alerts.firstMatch.buttons[advanced ? "confirmLeaveGroupButton" : "confirmDeleteGroupButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()

        let error = app.staticTexts["groupSettingsError"].firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 5), "A failed save must explain recovery in the same settings")
        XCTAssertEqual(app.textFields["groupSettingsNameField"].firstMatch.value as? String, groupName)
        app.buttons["closeGroupSettingsButton"].firstMatch.tap()
        XCTAssertTrue(end.waitForExistence(timeout: 5))
    }

    @MainActor
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

    @MainActor
    func testDirectCallHidesMembersAcrossReopeningAndLayoutSwitch() throws {
        launch()
        let suffix = String(UUID().uuidString.prefix(6))
        let peerName = "Direct " + suffix
        app.open(try InvitationURLFixture.make(inviter: "ui-direct-" + suffix, sharedName: peerName, contact: true))
        let accept = app.buttons["acceptContactInvitationButton"].firstMatch
        XCTAssertTrue(accept.waitForExistence(timeout: 5))
        accept.tap()
        XCTAssertTrue(accept.waitForNonExistence(timeout: 5))
        app.buttons["closeContactInvitationButton"].tap()
        let row = inviterRows(peerName).firstMatch
        XCTAssertTrue(row.exists)
        row.tap()
        assertDirectCallHasNoMembers(peerName)
        let receiveIsolation = app.switches.matching(NSPredicate(format: "identifier == %@ OR label == %@",
            "standardReceiveVoiceIsolationToggle", "Voice Isolation")).firstMatch
        for _ in 0..<4 where !receiveIsolation.isHittable { app.swipeUp() }
        XCTAssertTrue(receiveIsolation.isHittable, app.debugDescription)
        XCTAssertEqual(receiveIsolation.label, "Isolate the Other Person’s Voice")
        let initialIsolation = receiveIsolation.value as? String
        receiveIsolation.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertNotEqual(receiveIsolation.value as? String, initialIsolation)
        screenshot("Standard direct call names the received voice")
        app.closeCallIfOpen()
        app.openCurrentCall()
        assertDirectCallHasNoMembers(peerName)
        tab("Settings", id: "settingsTab")
        selectLayout("Advanced")
        app.openCurrentCall()
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["directCallHelpLabel"].exists)
        let masterIsolation = app.switches["masterVoiceIsolationToggle"].firstMatch
        for _ in 0..<4 where !masterIsolation.isHittable { app.swipeUp() }
        XCTAssertTrue(masterIsolation.isHittable, app.debugDescription)
        XCTAssertEqual(masterIsolation.label, "Isolate All Received Voices")
        screenshot("Advanced names all received voices")
        let peerIsolation = app.switches["participantVoiceIsolationToggle0"].firstMatch
        for _ in 0..<5 where !peerIsolation.isHittable { app.swipeUp() }
        XCTAssertTrue(peerIsolation.isHittable, app.debugDescription)
        XCTAssertEqual(peerIsolation.label, "Isolate Voice From \(peerName)")
        XCTAssertTrue(peerIsolation.staticTexts["Isolate This Voice"].exists)
        XCTAssertEqual(peerIsolation.value as? String, "Bypassed")
        peerIsolation.switches.firstMatch.tap()
        XCTAssertEqual(peerIsolation.value as? String, "Enabled")
        screenshot("Advanced names the selected received voice")
        screenshot("Advanced retains direct call details")
        let userSettings = app.openCallMoreMenuItem("callUserSettingsButton")
        XCTAssertFalse(app.buttons["callAddMembersButton"].exists)
        userSettings.tap()
        let closeSettings = app.buttons["closeUserSettingsButton"].firstMatch
        XCTAssertTrue(closeSettings.waitForExistence(timeout: 5))
        closeSettings.tap()
        tab("Settings", id: "settingsTab")
        selectLayout("Standard")
        app.openCurrentCall()
        assertDirectCallHasNoMembers(peerName)
        app.buttons["standardEndCallButton"].firstMatch.tap()
        app.buttons["standardConfirmEndCallButton"].firstMatch.tap()

        // Two people in an ordinary group still get the members section.
        tab("Groups", id: "groupsTab")
        app.buttons["standardCreateGroupButton"].firstMatch.tap()
        let selection = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "selectUser-", peerName)).firstMatch
        XCTAssertTrue(selection.waitForExistence(timeout: 3))
        selection.tap()
        app.buttons["saveUserSelectionButton"].firstMatch.tap()
        let finish = app.buttons["finishAddingUsersButton"].firstMatch
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        finish.tap()
        XCTAssertTrue(app.buttons["standardEndCallButton"].firstMatch.waitForExistence(timeout: 5))
        let groupIsolation = app.switches["standardReceiveVoiceIsolationToggle"].firstMatch
        for _ in 0..<4 where !groupIsolation.isHittable { app.swipeUp() }
        XCTAssertTrue(groupIsolation.isHittable, app.debugDescription)
        XCTAssertEqual(groupIsolation.label, "Isolate Incoming Voices")
        let heading = app.staticTexts["standardCallParticipantsHeading"].firstMatch
        for _ in 0..<3 where !heading.exists { app.swipeUp() }
        XCTAssertTrue(heading.exists, "An ordinary two-person group keeps its members")
        screenshot("Two-person ordinary group retains members")
    }

    @MainActor private func assertDirectCallHasNoMembers(_ name: String) {
        XCTAssertTrue(app.buttons["standardEndCallButton"].firstMatch.waitForExistence(timeout: 5))
        let hero = app.descendants(matching: .any)["standardCallHero"].firstMatch
        XCTAssertTrue(hero.label.contains(name), hero.label)
        for _ in 0..<2 { app.swipeUp() }
        XCTAssertFalse(app.staticTexts["standardCallParticipantsHeading"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["standardVoiceIndicatorSelf"].exists)
        XCTAssertFalse(app.buttons["addSavedUsersButton"].exists)
        screenshot("Standard direct call without members")
    }

    @MainActor
    func testLegacyContactInvitationWaitsForShareCompletionAndRetainsItsRow() throws {
        launch(legacyContactInvitation: true)
        tab("Users", id: "usersTab")
        let rowID = try XCTUnwrap(contactPendingIDs().first)
        let row = app.buttons[rowID].firstMatch
        row.tap()
        let state = app.descendants(matching: .any)["contactInvitationState"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertEqual(state.label, "Not sent yet")
        XCTAssertTrue(app.staticTexts["Contact Invitation"].exists)
        let share = app.buttons["shareContactInvitationButton"].firstMatch
        let copy = nativeInvitationCopyAction()
        share.tap()
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        app.swipeDown()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        XCTAssertTrue(state.waitForExistence(timeout: 5), "Dismissing OS sharing keeps the invitation detail open")
        XCTAssertEqual(state.label, "Not sent yet", "Opening and dismissing the share preview leaves the link unsent")
        XCTAssertEqual(share.label, "Share Invitation")
        share.tap()
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        XCTAssertEqual(state.label, "Waiting to be accepted")
        XCTAssertEqual(share.label, "Share Again")
        app.buttons["closeContactInvitationButton"].firstMatch.tap()
        XCTAssertEqual(contactPendingIDs(), [rowID])
        app.launchEnvironment.removeValue(forKey: "RIDEINTERCOM_LEGACY_CONTACT_INVITATION_FIXTURE")
        app.terminate(); app.launch(); app.activate()
        tab("Users", id: "usersTab")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertEqual(contactPendingIDs(), [rowID])
        row.tap()
        XCTAssertTrue(state.waitForExistence(timeout: 5))
        XCTAssertEqual(state.label, "Waiting to be accepted")
    }

    @MainActor
    func testContactPersonSaveShareCancelCopyAndRestartKeepOnePerson() throws {
        launch()
        tab("Users", id: "usersTab")
        let before = contactSavedUserIDs(), pending = contactPendingIDs()
        app.buttons["inviteContactButton"].tap()
        let save = app.buttons["saveContactPersonButton"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 3), "Saving a name is separate from sharing")
        XCTAssertFalse(app.buttons["shareContactInvitationButton"].exists)
        let name = app.textFields["contactInvitationNameField"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let nickname = "Saved Partner " + UUID().uuidString.prefix(6)
        name.typeText(nickname)
        app.buttons["closeContactInvitationButton"].tap()
        XCTAssertEqual(contactSavedUserIDs(), before, "Cancel before Save writes nothing")
        app.buttons["inviteContactButton"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.typeText(nickname)
        save.tap()
        let savedName = app.staticTexts["contactPersonSavedName"].firstMatch
        XCTAssertTrue(savedName.waitForExistence(timeout: 3))
        XCTAssertEqual(savedName.label, nickname)
        XCTAssertFalse(name.exists, "Saving confirms the name instead of leaving an implicit editing state")
        let done = app.buttons["closeContactInvitationButton"].firstMatch
        XCTAssertEqual(done.label, "Done")
        let state = app.staticTexts["contactPersonRegistrationState"].firstMatch
        XCTAssertEqual(state.label, "Not registered")
        let share = app.buttons["shareContactInvitationButton"].firstMatch
        share.tap()
        let copy = nativeInvitationCopyAction()
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        app.swipeDown()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        XCTAssertTrue(savedName.waitForExistence(timeout: 3))
        XCTAssertEqual(savedName.label, nickname)
        XCTAssertEqual(done.label, "Done")
        share.tap()
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        XCTAssertEqual(state.label, "Not registered", "Copy is not delivery or registration")
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(savedName.waitForExistence(timeout: 5), "Returning keeps the same saved detail open")
        XCTAssertEqual(savedName.label, nickname)
        screenshot("Saved person stays after share cancel copy and foreground return")
        done.tap()
        let added = contactSavedUserIDs().subtracting(before)
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(contactPendingIDs(), pending, "No separate invitation row for the same person")
        let rowID = try XCTUnwrap(added.first)
        app.terminate(); app.launch(); app.activate()
        tab("Users", id: "usersTab")
        revealUser(nickname)
        let row = app.buttons[rowID].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        XCTAssertTrue(row.label.contains("Not registered"), row.label)
        row.tap()
        XCTAssertEqual(savedName.label, nickname)
        XCTAssertTrue(share.exists)
        done.tap()
    }

    @MainActor
    func testContactPersonCanBeSavedAndFinishedWithoutSharing() throws {
        launch()
        tab("Users", id: "usersTab")
        let before = contactSavedUserIDs(), pending = contactPendingIDs()
        app.buttons["inviteContactButton"].tap()
        let name = app.textFields["contactInvitationNameField"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let candidate = try XCTUnwrap(name.placeholderValue)
        app.buttons["saveContactPersonButton"].tap()
        let saved = app.staticTexts["contactPersonSavedName"].firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 3))
        XCTAssertEqual(saved.label, candidate)
        let done = app.buttons["closeContactInvitationButton"].firstMatch
        XCTAssertEqual(done.label, "Done")
        done.tap()
        let added = contactSavedUserIDs().subtracting(before)
        XCTAssertEqual(added.count, 1)
        XCTAssertEqual(contactPendingIDs(), pending)
        revealUser(candidate)
        app.buttons[try XCTUnwrap(added.first)].tap()
        XCTAssertEqual(saved.label, candidate)
        XCTAssertTrue(app.buttons["shareContactInvitationButton"].exists)
        done.tap()
    }

    @MainActor
    func testJapaneseContactCreationKeepsSaveReachableWithLargestTextAndKeyboard() {
        launch(japanese: true)
        app.terminate()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        tab("ユーザー", id: "usersTab")
        app.buttons["inviteContactButton"].tap()
        let name = app.textFields["contactInvitationNameField"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 4))
        let save = app.buttons["saveContactPersonButton"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 3))
        XCTAssertTrue(save.isHittable)
        name.typeText("雪山の仲間")
        XCTAssertTrue(save.isHittable, "Save stays above the keyboard at the largest text size")
        screenshot("Japanese explicit save largest text with keyboard")
        save.tap()
        let share = app.buttons["shareContactInvitationButton"].firstMatch
        XCTAssertTrue(share.waitForExistence(timeout: 4))
        XCTAssertTrue(share.isHittable)
        share.tap()
        let copy = nativeInvitationCopyAction()
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.buttons["closeContactInvitationButton"].label, "完了")
        screenshot("Japanese saved detail after copying invitation largest text")
        app.buttons["closeContactInvitationButton"].tap()
    }

    @MainActor
    func testJapaneseContactPreviewCancelThenAcceptPersistsOnlyTheInviter() throws {
        launch(japanese: true)
        tab("グループ", id: "groupsTab")
        let originalGroups = contactGroupRows().count
        tab("ユーザー", id: "usersTab")
        let originalUsers = contactUserRows().count
        let originalPending = contactPendingIDs()
        let suffix = String(UUID().uuidString.prefix(8))
        let inviterName = "招待者 " + suffix
        let url = try InvitationURLFixture.make(inviter: "ui-contact-" + suffix, sharedName: inviterName, contact: true)
        app.open(url)
        let preview = app.descendants(matching: .any)["contactInvitationPreview"].firstMatch
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[inviterName].firstMatch.exists)
        let accept = app.buttons["acceptContactInvitationButton"].firstMatch
        let cancel = app.buttons["cancelContactInvitationButton"].firstMatch
        XCTAssertEqual(accept.label, "登録")
        XCTAssertEqual(cancel.label, "拒否")
        screenshot("Japanese signed contact invitation preview")
        cancel.tap()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 3))
        tab("ユーザー", id: "usersTab")
        XCTAssertEqual(contactUserRows().count, originalUsers)
        XCTAssertEqual(contactPendingIDs(), originalPending)
        XCTAssertFalse(app.staticTexts[inviterName].exists)
        app.open(url)
        XCTAssertTrue(preview.waitForExistence(timeout: 5))
        accept.tap()
        XCTAssertTrue(preview.waitForNonExistence(timeout: 5))
        app.buttons["closeContactInvitationButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["standardUsersList"].firstMatch.waitForExistence(timeout: 3))
        revealUser(inviterName)
        // Rows are lazy and earlier runs leave users, so count the inviter's rows rather than all rows.
        XCTAssertEqual(inviterRows(inviterName).count, 1, "Accepting saves exactly the inviter")
        screenshot("Japanese accepted contact saved while notification remains separate")
        let directory = contactDirectorySnapshot()
        XCTAssertFalse(directory.contains { $0.key.hasPrefix("pendingContactInvitation-") && $0.value.contains(inviterName) },
                       "A saved person has no duplicate pending row")
        openUserSettings(from: inviterRows(inviterName).firstMatch)
        XCTAssertTrue(app.staticTexts["savedUserOriginalName"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["savedUserOriginalName"].firstMatch.label, inviterName)
        let reply = app.descendants(matching: .any)["contactInvitationState"].firstMatch
        XCTAssertTrue(reply.waitForExistence(timeout: 3))
        XCTAssertTrue(reply.label.contains("返信を届けています") || reply.label.contains("返信が届いていません"), reply.label)
        screenshot("Japanese registered inviter and reply in the same person's settings")
        app.buttons["closeUserSettingsButton"].tap()
        tab("グループ", id: "groupsTab")
        XCTAssertEqual(contactGroupRows().count, originalGroups)
        app.terminate(); app.launch(); app.activate()
        tab("ユーザー", id: "usersTab")
        revealUser(inviterName)
        XCTAssertEqual(inviterRows(inviterName).count, 1)
    }

    /// A swipe made while the invitation sheet is still closing is lost, so swipe again until the action shows.
    @MainActor private func openUserSettings(from row: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let settings = app.buttons.matching(NSPredicate(format: "label IN %@", ["User Settings", "相手の設定"])).firstMatch
        for _ in 0..<3 where !settings.exists {
            row.swipeLeft()
            _ = settings.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(settings.exists, file: file, line: line)
        settings.tap()
    }

    /// The saved user's own row (the pending invitation row shows the same name), scrolled into view.
    @MainActor private func inviterRows(_ name: String) -> XCUIElementQuery {
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "standardUser-", name))
        let list = app.descendants(matching: .any)["standardUsersList"].firstMatch
        for _ in 0..<10 where rows.count == 0 { list.swipeUp() }
        return rows
    }

    /// Pending invitations left by earlier runs can push saved users below the fold.
    private func revealUser(_ name: String, file: StaticString = #filePath, line: UInt = #line) {
        let users = app.descendants(matching: .any)["standardUsersList"].firstMatch
        XCTAssertTrue(users.waitForExistence(timeout: 5), file: file, line: line)
        for _ in 0..<10 where !app.staticTexts[name].firstMatch.exists { users.swipeUp() }
        XCTAssertTrue(app.staticTexts[name].firstMatch.waitForExistence(timeout: 5), file: file, line: line)
    }

    @MainActor
    func testContactPendingRetryAndLocalCancellationKeepAnExistingCall() throws {
        launch()
        tab("Groups", id: "groupsTab")
        app.buttons["standardCreateGroupButton"].tap()
        let name = app.textFields["savedUsersGroupNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let groupName = "Contact waiting " + UUID().uuidString.prefix(6)
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String)?.count ?? 0) + groupName)
        app.buttons["saveUserSelectionButton"].tap()
        XCTAssertTrue(app.buttons["standardEndCallButton"].waitForExistence(timeout: 5))
        let mute = app.buttons["standardMuteButton"].firstMatch
        if mute.value as? String != "Muted" { mute.tap() }
        tab("Users", id: "usersTab")
        let originalUsers = contactSavedUserIDs()
        app.buttons["inviteContactButton"].tap()
        XCTAssertTrue(app.buttons["saveContactPersonButton"].waitForExistence(timeout: 3))
        app.textFields["contactInvitationNameField"].typeText("Not invited during call")
        app.buttons["saveContactPersonButton"].tap()
        XCTAssertEqual(app.staticTexts["contactPersonRegistrationState"].firstMatch.label, "Not registered")
        app.buttons["closeContactInvitationButton"].tap()
        let added = try XCTUnwrap(contactSavedUserIDs().subtracting(originalUsers).first)
        let row = app.buttons[added].firstMatch
        revealUser("Not invited during call")
        openUserSettings(from: row)
        app.buttons["deleteUserButton"].tap()
        app.alerts.buttons["confirmDeleteUserButton"].firstMatch.tap()
        XCTAssertTrue(row.waitForNonExistence(timeout: 5))
        XCTAssertEqual(contactSavedUserIDs(), originalUsers)
        tab("Call", id: "callTab")
        XCTAssertTrue(app.buttons["standardEndCallButton"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts[groupName].firstMatch.exists)
        XCTAssertEqual(mute.value as? String, "Muted")
        app.buttons["standardEndCallButton"].tap()
        app.alerts.firstMatch.buttons["standardConfirmEndCallButton"].firstMatch.tap()
    }

    @MainActor
    func testReceivedContactReplyExplainsWaitingForCurrentCall() throws {
        launch()
        let suffix = String(UUID().uuidString.prefix(6)), inviter = "Reply during call " + suffix
        app.open(try InvitationURLFixture.make(inviter: "ui-active-reply-" + suffix, sharedName: inviter, contact: true))
        let register = app.buttons["acceptContactInvitationButton"].firstMatch
        XCTAssertTrue(register.waitForExistence(timeout: 5))
        register.tap()
        app.buttons["closeContactInvitationButton"].tap()
        tab("Groups", id: "groupsTab")
        app.buttons["standardCreateGroupButton"].tap()
        let name = app.textFields["savedUsersGroupNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let groupName = "Receive while talking " + UUID().uuidString.prefix(6)
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String)?.count ?? 0) + groupName)
        app.buttons["saveUserSelectionButton"].tap()
        XCTAssertTrue(app.buttons["standardEndCallButton"].waitForExistence(timeout: 5))
        let mute = app.buttons["standardMuteButton"].firstMatch
        if mute.value as? String != "Muted" { mute.tap() }
        tab("Users", id: "usersTab")
        revealUser(inviter)
        openUserSettings(from: inviterRows(inviter).firstMatch)
        let state = app.descendants(matching: .any)["contactInvitationState"].firstMatch
        XCTAssertTrue(state.waitForExistence(timeout: 3))
        XCTAssertEqual(state.label, "Waiting for the current call to end.")
        XCTAssertFalse(app.buttons["retryContactInvitationButton"].exists, "Do not offer a retry that cannot run during a call")
        screenshot("Received contact waits inside the same person's settings without interrupting a call")
        app.buttons["closeUserSettingsButton"].tap()
        tab("Call", id: "callTab")
        XCTAssertTrue(app.staticTexts[groupName].firstMatch.exists)
        XCTAssertEqual(mute.value as? String, "Muted")
        app.buttons["standardEndCallButton"].tap()
        app.alerts.buttons["standardConfirmEndCallButton"].firstMatch.tap()
    }

    @MainActor private func contactUserRows() -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardUser-"))
    }
    /// SwiftUI lazily exposes rows. Compare identities over the whole list, then return to its top.
    @MainActor private func contactSavedUserIDs() -> Set<String> {
        Set(contactDirectorySnapshot().keys.filter { $0.hasPrefix("standardUser-") })
    }

    @MainActor private func contactDirectorySnapshot() -> [String: String] {
        let list = app.descendants(matching: .any)["standardUsersList"].firstMatch
        XCTAssertTrue(list.waitForExistence(timeout: 3))
        let rows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ OR identifier BEGINSWITH %@",
                                                  "standardUser-", "pendingContactInvitation-"))
        var top: Set<String>?
        for _ in 0..<20 {
            let visible = Set(rows.allElementsBoundByIndex.filter(\.isHittable).map(\.identifier))
            if visible == top { break }
            top = visible
            list.swipeDown()
        }
        var result: [String: String] = [:]
        var previous: Set<String>?, bottomReached = false, swipes = 0
        for _ in 0..<20 {
            for row in rows.allElementsBoundByIndex { result[row.identifier] = row.label }
            let visible = Set(rows.allElementsBoundByIndex.filter(\.isHittable).map(\.identifier))
            if visible == previous { bottomReached = true; break }
            previous = visible
            list.swipeUp(); swipes += 1
        }
        XCTAssertTrue(bottomReached, "The comparison must cover the whole directory")
        for _ in 0...swipes { list.swipeDown() }
        return result
    }

    @MainActor private func contactGroupRows() -> XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardGroup-"))
    }
    @MainActor private func contactPendingIDs() -> Set<String> {
        Set(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "pendingContactInvitation-")).allElementsBoundByIndex.map(\.identifier))
    }
    @MainActor private func nativeInvitationCopyAction() -> XCUIElement {
        app.cells.matching(NSPredicate(format: "label IN %@", ["Copy", "Copy Link", "コピー", "リンクをコピー"])).firstMatch
    }
    #endif

    @MainActor
    func testStandardLayoutKeepsCallAcrossAdvancedSwitchAndPersistsChoice() throws {
        launch()
        XCTAssertFalse(app.tabBars.buttons["Diagnostics"].exists)
        tab("Groups", id: "groupsTab")
        app.buttons["standardCreateGroupButton"].tap()
        let name = app.textFields["savedUsersGroupNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String)?.count ?? 0) + "Standard UI " + UUID().uuidString.prefix(6))
        app.buttons["saveUserSelectionButton"].tap()
        XCTAssertTrue(app.buttons["standardEndCallButton"].waitForExistence(timeout: 5))
        let mute = app.buttons["standardMuteButton"].firstMatch
        XCTAssertTrue(mute.waitForExistence(timeout: 3))
        mute.tap()
        XCTAssertTrue(app.staticTexts["standardMuteState"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["standardMuteState"].firstMatch.label, "Muted")
        tab("Settings", id: "settingsTab")
        assertPurchasesUnavailable("Not Available Yet")
        #if os(iOS)
        let liveActivity = app.switches["liveActivityToggle"].firstMatch
        for _ in 0..<6 where !liveActivity.isHittable { app.swipeUp() }
        XCTAssertTrue(liveActivity.waitForExistence(timeout: 3))
        XCTAssertEqual(liveActivity.value as? String, "0")
        liveActivity.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(liveActivity.value as? String, "1")
        liveActivity.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        XCTAssertEqual(liveActivity.value as? String, "0")
        #endif
        selectLayout("Advanced")
        XCTAssertTrue(app.tabBars.buttons["Diagnostics"].exists || app.buttons["diagnosticsTab"].exists)
        tab("Users", id: "usersTab")
        XCTAssertTrue(app.descendants(matching: .any)["standardUsersList"].firstMatch.waitForExistence(timeout: 3))
        tab("Groups", id: "groupsTab")
        XCTAssertTrue(app.descendants(matching: .any)["standardGroupsList"].firstMatch.waitForExistence(timeout: 3))
        tab("Call", id: "callTab")
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["localMicrophoneStateLabel"].label, "Muted")
        tab("Settings", id: "settingsTab")
        selectLayout("Standard")
        tab("Call", id: "callTab")
        XCTAssertTrue(app.buttons["standardEndCallButton"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["standardMuteState"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertEqual(app.staticTexts["standardMuteState"].firstMatch.label, "Muted")
        XCTAssertTrue(app.sliders["standardVolumeSlider"].exists)
        XCTAssertEqual(app.sliders["standardVolumeSlider"].label, "Volume")
        screenshot("Standard call after switching layouts")
        app.buttons["standardEndCallButton"].tap()
        app.alerts.firstMatch.buttons["standardConfirmEndCallButton"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["standardCallScreen"].firstMatch.waitForNonExistence(timeout: 3),
                      "Ending the call returns to the list")
        app.terminate()
        app.launchEnvironment.removeValue(forKey: "RIDEINTERCOM_INTERFACE_FIXTURE")
        app.launch(); app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["standardUsersList"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.tabBars.buttons["Diagnostics"].exists)
    }

    @MainActor
    func testStandardJapaneseNavigationAndUnconfiguredPurchases() {
        launch(japanese: true)
        // The people list is the first screen; the call is not a tab.
        XCTAssertTrue(app.tabBars.buttons["ユーザー"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.tabBars.buttons["通話"].exists)
        tab("ユーザー", id: "usersTab")
        XCTAssertTrue(app.descendants(matching: .any)["standardUsersList"].firstMatch.waitForExistence(timeout: 3))
        tab("グループ", id: "groupsTab")
        XCTAssertTrue(app.buttons["standardCreateGroupButton"].waitForExistence(timeout: 3))
        screenshot("Japanese groups")
        tab("設定", id: "settingsTab")
        assertPurchasesUnavailable("まだ利用できません")
        XCTAssertTrue(app.staticTexts["購入はまだ利用できません。"].exists)
        screenshot("Japanese settings and unavailable purchases")
    }

    #if os(iOS)
    @MainActor
    func testAdvancedInvitationShowsTheStoredRecordAndItsOperations() throws {
        launch(interface: "advanced")
        tab("Users", id: "usersTab")
        app.buttons["inviteContactButton"].tap()
        let name = app.textFields["contactInvitationNameField"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.typeText("Advanced Partner")
        app.buttons["saveContactPersonButton"].tap()
        XCTAssertTrue(app.staticTexts["SavedUser"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["memberIDs"].exists)
        XCTAssertFalse(app.staticTexts["ContactInvitationRecord"].exists, "Saving alone issues no invitation")
        app.buttons["shareContactInvitationButton"].tap()
        let copy = nativeInvitationCopyAction()
        XCTAssertTrue(copy.waitForExistence(timeout: 5))
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        let header = app.staticTexts["ContactInvitationRecord"].firstMatch
        for _ in 0..<5 where !header.isHittable { app.swipeUp() }
        XCTAssertTrue(header.exists)
        let state = app.staticTexts["contactInvitationField-state"].firstMatch
        for _ in 0..<5 where !state.isHittable { app.swipeUp() }
        XCTAssertEqual(state.label, "pending")
        let session = app.staticTexts["contactInvitationField-session"].firstMatch
        for _ in 0..<5 where !session.isHittable { app.swipeUp() }
        XCTAssertEqual(session.label, "running")
        XCTAssertFalse(app.descendants(matching: .any)["contactInvitationState"].exists)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        let resumed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "running"), object: session)
        XCTAssertEqual(XCTWaiter.wait(for: [resumed], timeout: 5), .completed, "The same exchange resumes on foreground return")
        screenshot("Advanced person and its exchange remain together after foreground return")
        app.buttons["closeContactInvitationButton"].tap()
    }
    #endif

    #if os(iOS)
    /// New Group: pick from your users with a check mark, see "n/8", then one action at the bottom.
    @MainActor
    func testStandardNewGroupPicksUsersWithOneActionBelow() throws {
        launch()
        let suffix = String(UUID().uuidString.prefix(6))
        let inviterName = "Pick " + suffix
        app.open(try InvitationURLFixture.make(inviter: "ui-pick-" + suffix, sharedName: inviterName, contact: true))
        let accept = app.buttons["acceptContactInvitationButton"].firstMatch
        XCTAssertTrue(accept.waitForExistence(timeout: 5))
        accept.tap()
        XCTAssertTrue(accept.waitForNonExistence(timeout: 5))
        app.buttons["closeContactInvitationButton"].tap()
        tab("Groups", id: "groupsTab")
        app.buttons["standardCreateGroupButton"].firstMatch.tap()
        let groupName = app.textFields["savedUsersGroupNameField"].firstMatch
        XCTAssertTrue(groupName.waitForExistence(timeout: 3))
        let generated = try XCTUnwrap(groupName.value as? String)
        XCTAssertNotNil(generated.range(of: "^Group [A-F0-9]{6}$", options: .regularExpression))
        let chosenName = "Chosen " + suffix
        groupName.tap()
        groupName.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: generated.count) + chosenName + "\n")
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "selectUser-", inviterName)).firstMatch
        let form = app.collectionViews.firstMatch
        XCTAssertTrue(app.staticTexts["Your Users"].exists)
        for _ in 0..<15 where !row.exists || !row.isHittable { form.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "editUser-")).firstMatch.exists,
                       "Rows only select; renaming lives in the person's settings")
        let count = app.staticTexts["memberSelectionCount"].firstMatch
        XCTAssertEqual(count.label, "1/8 people including you")
        row.tap()
        XCTAssertEqual(count.label, "2/8 people including you")
        // Updating the selection can scroll the focused name field back into view.
        for _ in 0..<15 where !row.exists || !row.isHittable { form.swipeUp() }
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        XCTAssertTrue(row.isSelected)
        let action = app.buttons["saveUserSelectionButton"].firstMatch
        XCTAssertEqual(action.label, "Create and Connect")
        XCTAssertTrue(action.isHittable)
        // The primary action spans the sheet's width, not a capsule as wide as its words.
        XCTAssertGreaterThanOrEqual(action.frame.width, app.windows.firstMatch.frame.width - 2 * 16 - 1, "\(action.frame)")
        for _ in 0..<15 where !groupName.exists { form.swipeDown() }
        XCTAssertEqual(groupName.value as? String, chosenName, "Selecting a person keeps the edited group name")
        screenshot("Standard new group with a user picked")
        action.tap()
        // The same saved target remains visible; sharing is optional.
        XCTAssertTrue(app.staticTexts["groupDeliverySelectionMessage"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["savedInvitationGroupName"].label, chosenName)
        app.buttons["finishAddingUsersButton"].tap()
        XCTAssertTrue(app.buttons["standardEndCallButton"].waitForExistence(timeout: 5))
        // Group Settings: tapping a member opens their settings, where Remove from Group asks first.
        // No long-press menus: the row's swipe offers Remove, and the settings carry it as a named button.
        app.buttons["callGroupSettingsButton"].firstMatch.tap()
        XCTAssertTrue(app.descendants(matching: .any)["groupSettingsView"].firstMatch.waitForExistence(timeout: 3))
        let member = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                      "groupSettingsMember-", inviterName)).firstMatch
        XCTAssertTrue(member.waitForExistence(timeout: 3))
        let me = app.descendants(matching: .any)["groupSettingsSelf"].firstMatch
        XCTAssertTrue(me.exists, "You come first in the members, as in the call")
        XCTAssertLessThan(me.frame.minY, member.frame.minY)
        XCTAssertFalse(app.staticTexts["Touch and hold a member to rename or remove them."].exists)
        member.tap()
        let remove = app.buttons["removeGroupMemberButton"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 3))
        XCTAssertEqual(remove.label, "Remove from Group")
        // As the design: titled with their name, only your name for them, then Remove from Group.
        XCTAssertTrue(app.navigationBars[inviterName].exists, app.debugDescription)
        XCTAssertEqual(app.textFields["groupMemberNameField"].firstMatch.placeholderValue, inviterName)
        XCTAssertFalse(app.buttons["resetGroupMemberNameButton"].exists, "No Use Shared Name: empty returns to it")
        screenshot("Standard group member settings")
        remove.tap()
        let removal = app.alerts.firstMatch
        XCTAssertTrue(removal.waitForExistence(timeout: 3))
        XCTAssertTrue(removal.staticTexts["Remove \(inviterName) from the group?"].exists, removal.debugDescription)
        removal.buttons["confirmRemoveMemberButton"].firstMatch.tap()
        XCTAssertTrue(member.waitForNonExistence(timeout: 3), "The member leaves the group")
        app.buttons["closeGroupSettingsButton"].tap()
        app.buttons["standardEndCallButton"].tap()
        app.alerts.firstMatch.buttons["standardConfirmEndCallButton"].firstMatch.tap()
    }
    #endif

    #if os(iOS)
    /// User Settings: your name for them, their own name, receiving their calls, and deleting.
    @MainActor
    /// Choosing a person connects at once (an intercom: everyone joins together). A call notification is only a
    /// courtesy: the hero keeps the call's own state and no ringing controls appear.
    func testChoosingAPersonConnectsWithoutRingingControls() throws {
        launch()
        let suffix = String(UUID().uuidString.prefix(6))
        let inviterName = "Rider " + suffix
        app.open(try InvitationURLFixture.make(inviter: "ui-ring-" + suffix, sharedName: inviterName, contact: true))
        let accept = app.buttons["acceptContactInvitationButton"].firstMatch
        XCTAssertTrue(accept.waitForExistence(timeout: 5))
        accept.tap()
        XCTAssertTrue(accept.waitForNonExistence(timeout: 5))
        app.buttons["closeContactInvitationButton"].tap()
        let row = inviterRows(inviterName).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.tap()
        let hero = app.descendants(matching: .any)["standardCallHero"].firstMatch
        XCTAssertTrue(hero.waitForExistence(timeout: 5))
        XCTAssertTrue((hero.value as? String ?? "").hasPrefix("Connecting"), String(describing: hero.value))
        for id in ["shareDirectCallButton", "cancelDirectRingButton", "ringAgainButton"] {
            XCTAssertFalse(app.buttons[id].exists, id)
        }
        screenshot("One-to-one call without ringing controls")
        app.buttons["standardEndCallButton"].firstMatch.tap()
        app.alerts.firstMatch.buttons["standardConfirmEndCallButton"].firstMatch.tap()
    }

    @MainActor
    func testStandardUserSettingsShowTheNamesReceivingAndDelete() throws {
        launch()
        let suffix = String(UUID().uuidString.prefix(6))
        let inviterName = "Rider " + suffix
        app.open(try InvitationURLFixture.make(inviter: "ui-settings-" + suffix, sharedName: inviterName, contact: true))
        let accept = app.buttons["acceptContactInvitationButton"].firstMatch
        XCTAssertTrue(accept.waitForExistence(timeout: 5))
        accept.tap()
        XCTAssertTrue(accept.waitForNonExistence(timeout: 5))
        app.buttons["closeContactInvitationButton"].tap()
        let row = inviterRows(inviterName).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        openUserSettings(from: row)
        XCTAssertTrue(app.descendants(matching: .any)["userSettingsView"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["userSettingsInviteButton"].exists, "No invitation sharing in a person's settings")
        let name = app.textFields["savedUserNameField"].firstMatch
        XCTAssertEqual(name.placeholderValue, inviterName, "Empty shows their own name")
        XCTAssertEqual(app.switches.count, 0, "No notification switch per person: notifications are set in the OS")
        XCTAssertTrue(app.staticTexts["Their Own Name"].exists)
        screenshot("Standard user settings")
        name.tap()
        name.typeText("Trail " + suffix)
        app.buttons["saveUserNameButton"].tap()
        let renamed = inviterRows("Trail " + suffix).firstMatch
        XCTAssertTrue(renamed.waitForExistence(timeout: 3))
        openUserSettings(from: renamed)
        app.buttons["deleteUserButton"].firstMatch.tap()
        let confirm = app.alerts.buttons["confirmDeleteUserButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        XCTAssertTrue(app.alerts.staticTexts["Delete Trail \(suffix)?"].exists)
        confirm.tap()
        XCTAssertTrue(renamed.waitForNonExistence(timeout: 3))
    }
    #endif

    /// Waiting alone is a normal wait: the implementation must not report a lost connection.
    @MainActor
    func testAdvancedCallAloneReportsWaitingNotReconnecting() {
        launch()
        tab("Settings", id: "settingsTab")
        selectLayout("Advanced")
        tab("Groups", id: "groupsTab")
        app.buttons["standardCreateGroupButton"].firstMatch.tap()
        let name = app.textFields["savedUsersGroupNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String)?.count ?? 0) + "Alone " + UUID().uuidString.prefix(6))
        app.buttons["saveUserSelectionButton"].tap()
        let presence = app.staticTexts["callPresenceLabel"].firstMatch
        XCTAssertTrue(presence.waitForExistence(timeout: 5))
        var seen: [String] = []
        for _ in 0..<12 {
            if seen.last != presence.label { seen.append(presence.label) }
            Thread.sleep(forTimeInterval: 1)
        }
        screenshot("Advanced call waiting alone")
        XCTAssertFalse(seen.contains("Reconnecting / Offline"), "States while alone: \(seen)")
        app.buttons["disconnectButton"].firstMatch.tap()
    }

    @MainActor
    func testAdvancedCallLeavesGroupCreationInGroups() {
        launch()
        tab("Settings", id: "settingsTab")
        selectLayout("Advanced")
        // The call is not a tab, so the lists never expose group management through a call screen.
        for identifier in ["callTab", "advancedCallEmptyState", "chooseUserButton", "chooseGroupButton"] {
            XCTAssertFalse(app.descendants(matching: .any)[identifier].firstMatch.exists,
                           "The call opens from a chosen destination, not from a tab: \(identifier)")
        }
        tab("Groups", id: "groupsTab")
        let groups = app.descendants(matching: .any)["standardGroupsList"].firstMatch
        XCTAssertTrue(groups.waitForExistence(timeout: 3))
        let groupRows = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardGroup-"))
        let previousCount = groupRows.count
        let create = app.buttons["standardCreateGroupButton"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        create.tap()
        let name = app.textFields["savedUsersGroupNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        screenshot("Advanced Groups new group form")
        app.buttons["closeSavedUsersButton"].tap()
        XCTAssertTrue(groups.waitForExistence(timeout: 3))
        XCTAssertFalse(name.exists)
        XCTAssertEqual(groupRows.count, previousCount, "Cancel keeps the saved groups unchanged")

        create.tap()
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let groupName = "Advanced Groups " + UUID().uuidString.prefix(6)
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String)?.count ?? 0) + groupName)
        app.buttons["saveUserSelectionButton"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["callScreen"].firstMatch.waitForExistence(timeout: 5))
        let disconnect = app.buttons["disconnectButton"].firstMatch
        XCTAssertTrue(disconnect.waitForExistence(timeout: 5))
        // The list stays underneath the call sheet; only the call itself must not offer management.
        let callScreen = app.descendants(matching: .any)["callScreen"].firstMatch
        for identifier in ["createGroupButton", "standardCreateGroupButton", "showGroupsButton", "groupSelectionList"] {
            XCTAssertFalse(callScreen.descendants(matching: .any)[identifier].firstMatch.exists,
                           "Creating from Groups must return to Call without management entries: \(identifier)")
        }
        screenshot("Advanced Call after creating a named group from Groups")
        disconnect.tap()
        XCTAssertTrue(app.descendants(matching: .any)["callScreen"].firstMatch.waitForNonExistence(timeout: 5),
                      "Ending the call returns to the list")
        tab("Groups", id: "groupsTab")
        let created = app.buttons.containing(.staticText, identifier: groupName).firstMatch
        XCTAssertTrue(created.waitForExistence(timeout: 3))
        app.removeGroupRow(created)
        XCTAssertTrue(created.waitForNonExistence(timeout: 3))
    }

    @MainActor
    func testStandardHeroNamesTheDestinationWhenRotating() {
        #if os(iOS)
        launch()
        tab("Groups", id: "groupsTab")
        app.buttons["standardCreateGroupButton"].tap()
        let name = app.textFields["savedUsersGroupNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let destination = "Weekend Riders " + UUID().uuidString.prefix(4)
        name.tap()
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: (name.value as? String)?.count ?? 0) + destination)
        app.buttons["saveUserSelectionButton"].tap()
        XCTAssertTrue(app.buttons["standardEndCallButton"].waitForExistence(timeout: 5))
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft, .landscapeRight] {
            XCUIDevice.shared.orientation = orientation
            let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = self.app.frame
                return orientation.isLandscape ? frame.width > frame.height : frame.height > frame.width
            }, object: app)
            XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
            // The hero is one element; its label names the destination after rotating.
            let hero = app.descendants(matching: .any)["standardCallHero"].firstMatch
            XCTAssertTrue(hero.waitForExistence(timeout: 3), app.debugDescription)
            XCTAssertTrue(hero.label.contains(destination), hero.label)
            XCTAssertTrue(app.frame.contains(hero.frame), "The hero stays on screen")
            if orientation.isLandscape {
                let details = app.descendants(matching: .any)["standardCallDetailsScroll"].firstMatch
                XCTAssertTrue(details.waitForExistence(timeout: 3))
                XCTAssertLessThanOrEqual(hero.frame.maxX, details.frame.minX + 1,
                                         "The hero belongs to the fixed left column")
            }
            screenshot("Standard hero after rotation \(orientation.rawValue)")
        }
        XCUIDevice.shared.orientation = .portrait
        app.buttons["standardEndCallButton"].tap()
        app.alerts.firstMatch.buttons["standardConfirmEndCallButton"].firstMatch.tap()
        XCTAssertTrue(app.buttons["standardEndCallButton"].waitForNonExistence(timeout: 3))
        tab("Groups", id: "groupsTab")
        let row = app.buttons.containing(.staticText, identifier: destination).firstMatch
        app.removeGroupRow(row)
        XCTAssertTrue(row.waitForNonExistence(timeout: 3))
        #endif
    }

    @MainActor
    func testAdvancedMarksBurstAsDefaultAndResetReturnsToIt() {
        #if os(iOS)
        launch(interface: "advanced")
        tab("Settings", id: "settingsTab")
        let form = app.collectionViews.firstMatch
        let audioSession = form.staticTexts["Audio Session"].firstMatch
        revealStandardSettingsControl(audioSession)
        let mode = form.buttons["audioSessionProfilePicker"].firstMatch
        XCTAssertTrue(mode.isHittable, form.debugDescription)
        XCTAssertEqual(mode.label, "Mode, Burst mode (Default)")
        mode.tap()
        let stream = app.buttons["Stream mode"].firstMatch
        XCTAssertTrue(stream.waitForExistence(timeout: 3))
        stream.tap()
        XCTAssertEqual(mode.label, "Mode, Stream mode")

        let reset = app.buttons["resetAllSettingsButton"].firstMatch
        revealStandardSettingsControl(reset)
        reset.tap()
        let confirm = app.alerts.buttons["confirmResetAllSettingsButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        revealStandardSettingsControl(audioSession)
        XCTAssertEqual(mode.label, "Mode, Burst mode (Default)")
        #endif
    }

    @MainActor
    func testStandardSettingsSeparatesRoutineControlsAndConfirmsReset() {
        launch()
        tab("Settings", id: "settingsTab")
        XCTAssertFalse(app.descendants(matching: .any)["interfaceModePicker"].firstMatch.exists)

        let communication = app.buttons["communicationSettingsLink"].firstMatch
        revealStandardSettingsControl(communication)
        communication.tap()
        XCTAssertTrue(app.navigationBars["Communication"].waitForExistence(timeout: 3))
        screenshot("English Communication after navigation")
        let communicationTree = XCTAttachment(string: app.debugDescription)
        communicationTree.name = "English Communication accessibility tree"
        communicationTree.lifetime = .keepAlways
        add(communicationTree)
        XCTAssertTrue(app.switches["Local Network"].firstMatch.exists)
        XCTAssertTrue(app.switches["Internet"].firstMatch.exists)
        screenshot("Standard Communication settings in English")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let vad = app.descendants(matching: .any)["vadSensitivityPicker"].firstMatch
        revealStandardSettingsControl(vad)
        let noisy = vad.buttons["Noisy"].firstMatch
        XCTAssertTrue(noisy.waitForExistence(timeout: 3))
        noisy.tap()
        XCTAssertTrue(noisy.isSelected)
        screenshot("Standard routine settings with Noisy selected")

        // Audio Check is one action; ports, mute and meters belong to Advanced.
        let check = app.buttons["audioCheckButton"].firstMatch
        revealStandardSettingsControl(check)
        XCTAssertEqual(check.label, "Record 5s and Play")
        for identifier in ["audioCheckInputSource", "audioCheckOutputDestination", "audioCheckMuteState",
                           "audioCheckInputMeter", "audioCheckPhaseLabel", "audioCheckStatusLabel"] {
            XCTAssertFalse(app.descendants(matching: .any)[identifier].firstMatch.exists,
                           "Advanced detail in Standard Audio Check: \(identifier)")
        }
        screenshot("Standard Audio Check is one action")

        let more = app.buttons["moreSettingsLink"].firstMatch
        revealStandardSettingsControl(more)
        more.tap()
        XCTAssertTrue(app.navigationBars["Advanced Settings for Developers"].waitForExistence(timeout: 3))
        let layout = app.descendants(matching: .any)["interfaceModePicker"].firstMatch
        XCTAssertTrue(layout.waitForExistence(timeout: 3))
        XCTAssertTrue(layout.buttons["Standard"].exists && layout.buttons["Advanced"].exists, "Both layouts are visible at once")
        XCTAssertTrue(layout.buttons["Standard"].isSelected)
        let internet = app.buttons["configureInternetConnection"].firstMatch
        revealStandardSettingsControl(internet)
        XCTAssertEqual(internet.label, "Set Up Internet Connection")
        // Specialist audio settings belong to Advanced Settings only.
        for identifier in ["audioSessionPanel", "transmitCodecPanel",
                           "vadSensitivityPicker", "resetAllSettingsButton", "communicationSettingsLink",
                           "communicationPanel", "localNetworkRouteToggle", "internetRouteToggle"] {
            XCTAssertFalse(app.descendants(matching: .any)[identifier].firstMatch.exists,
                           "Routine control duplicated in More Settings: \(identifier)")
        }
        screenshot("Standard More Settings has display and Internet only")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        let reset = app.buttons["resetAllSettingsButton"].firstMatch
        revealStandardSettingsControl(reset)
        reset.tap()
        let cancel = app.alerts.buttons["cancelResetAllSettingsButton"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        screenshot("Standard reset confirmation in English")
        cancel.tap()
        revealStandardSettingsControl(vad)
        XCTAssertTrue(noisy.isSelected, "Cancel keeps the selected VAD sensitivity")
        revealStandardSettingsControl(reset)
        reset.tap()
        let confirm = app.alerts.buttons["confirmResetAllSettingsButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        confirm.tap()
        XCTAssertFalse(app.alerts.firstMatch.exists)
        revealStandardSettingsControl(more)
        more.tap()
        XCTAssertTrue(layout.waitForExistence(timeout: 3))
        XCTAssertTrue(layout.buttons["Standard"].isSelected, "Reset keeps the selected layout")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        revealStandardSettingsControl(vad)
        XCTAssertTrue(vad.buttons["Standard"].firstMatch.isSelected,
                       "Confirmed reset restores the default VAD sensitivity")
        let recording = app.buttons["audioCheckButton"].firstMatch
        revealStandardSettingsControl(recording)
        XCTAssertTrue(recording.exists)
        screenshot("Standard Settings after confirmed reset")
    }

    @MainActor
    func testStandardJapaneseCommunicationAndResetCancellation() {
        launch(japanese: true)
        tab("設定", id: "settingsTab")
        let communication = app.buttons["communicationSettingsLink"].firstMatch
        revealStandardSettingsControl(communication)
        XCTAssertTrue(communication.label.contains("通信経路"))
        communication.tap()
        XCTAssertTrue(app.navigationBars["通信経路"].waitForExistence(timeout: 3))
        screenshot("Japanese Communication after navigation")
        let communicationTree = XCTAttachment(string: app.debugDescription)
        communicationTree.name = "Japanese Communication accessibility tree"
        communicationTree.lifetime = .keepAlways
        add(communicationTree)
        let local = app.switches["近距離"].firstMatch
        let internet = app.switches["インターネット"].firstMatch
        XCTAssertTrue(local.exists)
        XCTAssertTrue(internet.exists)
        XCTAssertEqual(local.label, "近距離")
        XCTAssertEqual(internet.label, "インターネット")
        screenshot("Japanese Standard Communication settings")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let reset = app.buttons["resetAllSettingsButton"].firstMatch
        revealStandardSettingsControl(reset)
        XCTAssertEqual(reset.label, "すべての設定をリセット")
        reset.tap()
        XCTAssertTrue(app.alerts.staticTexts["すべての設定をリセットしますか？"].firstMatch.waitForExistence(timeout: 3))
        let cancel = app.alerts.buttons["cancelResetAllSettingsButton"].firstMatch
        XCTAssertEqual(cancel.label, "キャンセル")
        XCTAssertEqual(app.alerts.buttons["confirmResetAllSettingsButton"].firstMatch.label, "すべての設定をリセット")
        screenshot("Japanese Standard reset confirmation")
        cancel.tap()
        XCTAssertFalse(app.alerts.firstMatch.exists)
        let recording = app.buttons["audioCheckButton"].firstMatch
        revealStandardSettingsControl(recording)
        XCTAssertEqual(recording.label, "5秒録音して再生")
    }

    @MainActor
    func testStandardCommunicationSummaryAndLayoutRoundTripInLandscape() {
        #if os(iOS)
        defer { XCUIDevice.shared.orientation = .portrait }
        for japanese in [false, true] {
            if app != nil { app.terminate() }
            launch(japanese: japanese)
            XCUIDevice.shared.orientation = .landscapeLeft
            tab(japanese ? "設定" : "Settings", id: "settingsTab")
            let link = app.buttons["communicationSettingsLink"].firstMatch
            revealStandardSettingsControl(link)
            link.tap()
            let localName = japanese ? "近距離" : "Local Network"
            let internetName = japanese ? "インターネット" : "Internet"
            let local = app.switches[localName].firstMatch
            let internet = app.switches[internetName].firstMatch
            XCTAssertTrue(local.waitForExistence(timeout: 3))
            XCTAssertTrue(internet.waitForExistence(timeout: 3))
            if internet.value as? String != "1" { XCTAssertTrue(internet.isEnabled); internet.switches.firstMatch.tap() }
            if local.value as? String != "1" { XCTAssertTrue(local.isEnabled); local.switches.firstMatch.tap() }
            XCTAssertEqual(local.value as? String, "1")
            XCTAssertEqual(internet.value as? String, "1")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            revealStandardSettingsControl(link)
            XCTAssertTrue(link.label.contains(localName), link.debugDescription)
            XCTAssertTrue(link.label.contains(internetName), link.debugDescription)
            screenshot("Standard communication both routes landscape")
            link.tap()
            XCTAssertTrue(local.isEnabled)
            local.switches.firstMatch.tap()
            XCTAssertEqual(local.value as? String, "0")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            revealStandardSettingsControl(link)
            XCTAssertFalse(link.label.contains(localName), link.debugDescription)
            XCTAssertTrue(link.label.contains(internetName), link.debugDescription)
            screenshot("Standard communication Internet only landscape")
            link.tap()
            local.switches.firstMatch.tap()
            XCTAssertEqual(local.value as? String, "1")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            selectLayout(japanese ? "詳細" : "Advanced")
            selectLayout(japanese ? "標準" : "Standard")
            revealStandardSettingsControl(link)
            XCTAssertTrue(link.label.contains(localName), link.debugDescription)
            XCTAssertTrue(link.label.contains(internetName), link.debugDescription)
        }
        #endif
    }

    @MainActor private func revealStandardSettingsControl(_ control: XCUIElement) {
        #if os(iOS)
        let form = app.collectionViews.firstMatch
        #else
        let form = app.scrollViews.firstMatch
        #endif
        XCTAssertTrue(form.waitForExistence(timeout: 3))
        // Stay above the call accessory that sits over the tab bar in landscape.
        let lower = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.6))
        let upper = form.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        // Keep the gesture inside the Form, clear of landscape system edges.
        for _ in 0..<20 where !control.isHittable { lower.press(forDuration: 0.05, thenDragTo: upper) }
        for _ in 0..<20 where !control.isHittable { upper.press(forDuration: 0.05, thenDragTo: lower) }
        XCTAssertTrue(control.waitForExistence(timeout: 3))
        XCTAssertTrue(control.isHittable, control.debugDescription)
    }

    @MainActor
    func testStandardInternetSetupKeepsManualCredentialsInAdvanced() {
        launch()
        tab("Settings", id: "settingsTab")
        openInternetSettings()
        XCTAssertTrue(app.textFields["internetWorkerURL"].waitForExistence(timeout: 3))
        XCTAssertEqual(app.textFields["internetWorkerURL"].placeholderValue, "Address starting with https://")
        XCTAssertFalse(app.secureTextFields["internetDeviceToken"].exists)
        XCTAssertFalse(app.buttons["saveInternetConnection"].exists)
        XCTAssertTrue(app.buttons["prepareInternetAppleSignIn"].exists)
        app.buttons["closeInternetConnection"].tap()
        selectLayout("Advanced")
        openInternetSettings()
        XCTAssertTrue(app.secureTextFields["internetDeviceToken"].waitForExistence(timeout: 3))
        // Advanced shows the form of the value as the field's prompt.
        XCTAssertEqual(app.textFields["internetWorkerURL"].placeholderValue, "https://example.workers.dev")
        XCTAssertTrue(app.buttons["saveInternetConnection"].exists)
    }

    @MainActor private func openInternetSettings() {
        if app.descendants(matching: .any)["settingsScrollView"].firstMatch.exists,
           !app.tabBars.buttons["Diagnostics"].exists && !app.buttons["diagnosticsTab"].exists {
            let more = app.buttons["moreSettingsLink"].firstMatch
            revealStandardSettingsControl(more)
            more.tap()
        }
        let button = app.buttons["configureInternetConnection"].firstMatch
        revealStandardSettingsControl(button)
        XCTAssertTrue(button.waitForExistence(timeout: 3)); button.tap()
    }

    @MainActor
    func testJapaneseInternetRetryShowsDelayAndKeepsAccount() {
        launch(japanese: true, throttled: true)
        tab("設定", id: "settingsTab")
        openInternetSettings()
        let address = app.textFields["internetWorkerURL"]
        XCTAssertTrue(address.waitForExistence(timeout: 3))
        address.tap(); address.typeText("https://account.test")
        let prepare = app.buttons["prepareInternetAppleSignIn"]
        XCTAssertEqual(prepare.label, "インターネット通話を設定")
        prepare.tap()
        let status = app.staticTexts["internetAppleSignInStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertTrue(status.label.contains("ログインの試行が多すぎます。60秒待ってから"))
        XCTAssertTrue(status.label.contains("「インターネット通話を設定」を選び直してください。"))
        XCTAssertFalse(app.buttons["internetAppleSignInButton"].isEnabled)
        prepare.tap()
        XCTAssertTrue(status.label.contains("秒待ってから"))
        screenshot("Japanese Internet retry instruction")
        app.buttons["closeInternetConnection"].tap()
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let signOut = app.buttons["signOutButton"]
        revealStandardSettingsControl(signOut)
        XCTAssertTrue(signOut.exists)
        XCTAssertFalse(app.otherElements["appleSignInScreen"].exists)
    }

    @MainActor private func launch(japanese: Bool = false, throttled: Bool = false, interface: String = "standard",
                                  legacyContactInvitation: Bool = false, storeCatalog: String? = nil) {
        app = XCUIApplication()
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-in"
        app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = interface
        if throttled { app.launchEnvironment["RIDEINTERCOM_INTERNET_ACCOUNT_FIXTURE"] = "throttled" }
        if legacyContactInvitation { app.launchEnvironment["RIDEINTERCOM_LEGACY_CONTACT_INVITATION_FIXTURE"] = "1" }
        if let storeCatalog { app.launchEnvironment["RIDEINTERCOM_STOREKIT_CATALOG_FIXTURE"] = storeCatalog }
        app.launchArguments = ["-AppleLanguages", japanese ? "(ja)" : "(en)", "-AppleLocale", japanese ? "ja_JP" : "en_US"]
        app.launch(); app.activate()
        XCTAssertTrue(app.descendants(matching: .any)["standardUsersList"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor private func tab(_ title: String, id: String) {
        if id == "callTab" { app.openCurrentCall(); return }
        app.closeCallIfOpen()
        let identified = app.buttons[id].firstMatch
        if identified.exists { identified.tap() }
        else if app.radioButtons[id].exists { app.radioButtons[id].tap() }
        else {
            let button = app.tabBars.buttons[title].firstMatch
            XCTAssertTrue(button.waitForExistence(timeout: 3)); button.tap()
        }
    }

    @MainActor private func selectLayout(_ title: String) {
        let goingAdvanced = title == "Advanced" || title == "詳細"
        XCTAssertTrue(goingAdvanced || title == "Standard" || title == "標準", "Unknown layout: \(title)")
        if goingAdvanced && app.descendants(matching: .any)["settingsScrollView"].firstMatch.exists {
            let more = app.buttons["moreSettingsLink"].firstMatch
            revealStandardSettingsControl(more)
            more.tap()
        }
        let picker = app.descendants(matching: .any)["interfaceModePicker"].firstMatch
        for _ in 0..<6 where !picker.isHittable { app.swipeDown() }
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        // A segmented picker shows each layout as its own button; a menu needs opening first.
        // Advanced spells the layouts in English only; Standard uses the localized words.
        let names = [title, ["標準": "Standard", "詳細": "Advanced"][title] ?? title]
        let choice = names.lazy.flatMap { [picker.buttons[$0], picker.radioButtons[$0]] }.first { $0.exists } ?? picker.buttons[title]
        if choice.exists { choice.tap() } else {
            picker.tap()
            let menu = app.menuItems[title].firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 3)); menu.tap()
        }
        let settings = app.descendants(matching: .any)["settingsScrollView"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Switch returns to Settings")
        if goingAdvanced {
            XCTAssertTrue(app.descendants(matching: .any)["interfaceModePicker"].firstMatch.waitForExistence(timeout: 3))
            screenshot("Advanced Settings root after layout switch")
        } else {
            screenshot("Standard Settings root after layout switch")
            revealStandardSettingsControl(app.buttons["moreSettingsLink"].firstMatch)
        }
    }

    @MainActor private func assertPurchasesUnavailable(_ title: String) {
        let status = app.descendants(matching: .any)["purchaseStatus"].firstMatch
        for _ in 0..<5 where !status.exists { app.swipeUp() }
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertTrue(status.label.contains(title) || (status.value as? String)?.contains(title) == true || status.staticTexts[title].exists, status.debugDescription)
        XCTAssertFalse(app.buttons["restorePurchases"].exists)
    }

    @MainActor private func screenshot(_ title: String) {
        #if os(iOS)
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        #else
        let attachment = XCTAttachment(screenshot: app.screenshot())
        #endif
        attachment.name = title; attachment.lifetime = .keepAlways; add(attachment)
    }
}
