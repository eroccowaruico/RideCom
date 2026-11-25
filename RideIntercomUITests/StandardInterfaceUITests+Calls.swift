import XCTest

extension StandardInterfaceUITests {
    #if os(iOS)
    @MainActor
    @objc
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
        assertAdvancedDirectCallControls(for: peerName)
        tab("Settings", id: "settingsTab")
        selectLayout("Standard")
        app.openCurrentCall()
        assertDirectCallHasNoMembers(peerName)
        app.buttons["standardEndCallButton"].firstMatch.tap()
        app.buttons["standardConfirmEndCallButton"].firstMatch.tap()

        assertOrdinaryGroupShowsMembers(for: peerName)
    }

    @MainActor
    private func assertOrdinaryGroupShowsMembers(for peerName: String) {
        // Two people in an ordinary group still get the members section.
        tab("Groups", id: "groupsTab")
        app.buttons["standardCreateGroupButton"].firstMatch.tap()
        let selection = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                  "selectUser-", peerName)).firstMatch
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

    @MainActor
    private func assertAdvancedDirectCallControls(for peerName: String) {
        tab("Settings", id: "settingsTab")
        selectLayout("Advanced")
        app.openCurrentCall()
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["directCallHelpLabel"].exists)
        let allVoiceIsolation = app.switches["masterVoiceIsolationToggle"].firstMatch
        for _ in 0..<4 where !allVoiceIsolation.isHittable { app.swipeUp() }
        XCTAssertTrue(allVoiceIsolation.isHittable, app.debugDescription)
        XCTAssertEqual(allVoiceIsolation.label, "Isolate All Received Voices")
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
    }

    @MainActor
    @objc
    func testJapaneseDirectCallKeepsAdvancedIsolationLabelsInEnglish() throws {
        launch(japanese: true)
        let suffix = String(UUID().uuidString.prefix(6))
        let peerName = "Direct " + suffix
        app.open(try InvitationURLFixture.make(inviter: "ui-direct-ja-" + suffix, sharedName: peerName, contact: true))
        let accept = app.buttons["acceptContactInvitationButton"].firstMatch
        XCTAssertTrue(accept.waitForExistence(timeout: 5))
        accept.tap()
        XCTAssertTrue(accept.waitForNonExistence(timeout: 5))
        let finish = app.buttons["closeContactInvitationButton"].firstMatch
        XCTAssertTrue(finish.waitForExistence(timeout: 5))
        finish.tap()
        let person = inviterRows(peerName).firstMatch
        XCTAssertTrue(person.waitForExistence(timeout: 5))
        person.tap()
        let receive = app.switches["standardReceiveVoiceIsolationToggle"].firstMatch
        XCTAssertTrue(receive.waitForExistence(timeout: 5))
        XCTAssertEqual(receive.label, "相手の声を分離")
        tab("設定", id: "settingsTab")
        selectLayout("詳細")
        app.openCurrentCall()
        let allVoiceIsolation = app.switches["masterVoiceIsolationToggle"].firstMatch
        XCTAssertTrue(allVoiceIsolation.waitForExistence(timeout: 5))
        XCTAssertEqual(allVoiceIsolation.label, "Isolate All Received Voices")
        let peer = app.switches["participantVoiceIsolationToggle0"].firstMatch
        for _ in 0..<4 where !peer.isHittable { app.swipeUp() }
        XCTAssertTrue(peer.isHittable, app.debugDescription)
        XCTAssertEqual(peer.label, "Isolate Voice From \(peerName)")
        XCTAssertTrue(peer.staticTexts["Isolate This Voice"].exists)
        screenshot("English Advanced receive controls in Japanese")
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

    /// User Settings: your name for them, their own name, receiving their calls, and deleting.
    @MainActor
    /// Choosing a person connects at once (an intercom: everyone joins together). A call notification is only a
    /// courtesy: the hero keeps the call's own state and no ringing controls appear.
    @objc
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
    @objc
    func testStandardUserSettingsShowTheNamesReceivingAndDelete() throws {
        launch()
        let suffix = String(UUID().uuidString.prefix(6))
        let inviterName = "Rider " + suffix
        app.open(
            try InvitationURLFixture.make(inviter: "ui-settings-" + suffix, sharedName: inviterName, contact: true)
        )
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

    @MainActor
    @objc
    func testJapaneseAdvancedUserDeleteNamesThePersonAndCancels() throws {
        launch(japanese: true)
        let suffix = String(UUID().uuidString.prefix(6))
        let person = "Rider " + suffix
        app.open(try InvitationURLFixture.make(inviter: "ui-settings-" + suffix, sharedName: person, contact: true))
        let accept = app.buttons["acceptContactInvitationButton"].firstMatch
        XCTAssertTrue(accept.waitForExistence(timeout: 5))
        accept.tap()
        XCTAssertTrue(accept.waitForNonExistence(timeout: 5))
        app.buttons["closeContactInvitationButton"].tap()
        tab("設定", id: "settingsTab")
        selectLayout("詳細")
        tab("ユーザー", id: "usersTab")
        let row = inviterRows(person).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        openUserSettings(from: row)
        let settings = app.descendants(matching: .any)["userSettingsView"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let delete = app.buttons["deleteUserButton"].firstMatch
        for _ in 0..<4 where !delete.isHittable { settings.swipeUp() }
        XCTAssertTrue(delete.isHittable)
        delete.tap()
        let alert = app.alerts.firstMatch
        let confirm = alert.buttons["confirmDeleteUserButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        XCTAssertTrue(alert.staticTexts["\(person)を削除しますか？"].exists)
        XCTAssertEqual(confirm.label, "削除")
        alert.buttons["キャンセル"].tap()
        XCTAssertTrue(alert.waitForNonExistence(timeout: 3))
        XCTAssertTrue(delete.exists)
        app.buttons["closeUserSettingsButton"].tap()
        XCTAssertTrue(row.waitForExistence(timeout: 3))
    }
    #endif

    /// Waiting alone is a normal wait: the implementation must not report a lost connection.
    @MainActor
    @objc
    func testAdvancedCallAloneReportsWaitingNotReconnecting() {
        launch()
        tab("Settings", id: "settingsTab")
        selectLayout("Advanced")
        tab("Groups", id: "groupsTab")
        app.buttons["standardCreateGroupButton"].firstMatch.tap()
        let name = app.textFields["savedUsersGroupNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        let entered = (name.value as? String)?.count ?? 0
        let deletion = String(repeating: XCUIKeyboardKey.delete.rawValue, count: entered)
        name.typeText(deletion + "Alone " + UUID().uuidString.prefix(6))
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
    @objc
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
        let entered = (name.value as? String)?.count ?? 0
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: entered) + groupName)
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
    @objc
    func testStandardHeroNamesTheDestinationWhenRotating() {
        #if os(iOS)
        launch()
        tab("Groups", id: "groupsTab")
        app.buttons["standardCreateGroupButton"].tap()
        let name = app.textFields["savedUsersGroupNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        let destination = "Weekend Riders " + UUID().uuidString.prefix(4)
        name.tap()
        let entered = (name.value as? String)?.count ?? 0
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: entered) + destination)
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
}
