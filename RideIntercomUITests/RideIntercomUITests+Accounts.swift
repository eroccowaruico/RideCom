import XCTest

extension RideIntercomUITests {
    @MainActor
    @objc
    func testInternetEnrollmentThrottleKeepsAccountAndShowsRetryInstruction() throws {
        openInternetSettings()
        let prepare = app.buttons["prepareInternetAppleSignIn"]
        prepare.tap()
        let status = app.staticTexts["internetAppleSignInStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertTrue(status.label.contains("Too many sign-in attempts"))
        XCTAssertTrue(status.label.contains("Set Up Internet Calling again"))
        XCTAssertFalse(app.buttons["internetAppleSignInButton"].isEnabled)
        prepare.tap()
        XCTAssertTrue(status.label.contains("Wait"))
        attachScreen("Internet Enrollment Retry Instruction")
        app.buttons["closeInternetConnection"].tap()
        for _ in 0..<6 where !app.buttons["signOutButton"].exists { app.swipeDown() }
        XCTAssertTrue(app.buttons["signOutButton"].exists)
        XCTAssertFalse(app.otherElements["appleSignInScreen"].exists)
    }

    @MainActor
    @objc
    func testInternetAppleSetupKeepsLocalLoginWhenRegistrationIsUnavailable() throws {
        openInternetSettings()
        app.buttons["prepareInternetAppleSignIn"].tap()
        let status = app.staticTexts["internetAppleSignInStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertTrue(status.label.contains("unavailable"))
        attachScreen("Internet Apple Setup Unavailable with Local Login Retained")
        app.buttons["closeInternetConnection"].tap()
        for _ in 0..<6 where !app.buttons["signOutButton"].exists { app.swipeDown() }
        XCTAssertFalse(app.otherElements["appleSignInScreen"].exists)
        XCTAssertTrue(app.buttons["signOutButton"].exists)
    }

    @MainActor
    @objc
    func testPersonalAndReceivedNamesCanBeEditedAndRestored() throws {
        openSettingsTab()
        // Advanced keeps the name inline with Save Name.
        let ownName = app.textFields["localDisplayNameField"]
        revealSettingsControl(ownName)
        ownName.tap()
        let currentOwnName = ownName.value as? String ?? ""
        ownName.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: currentOwnName.count) + "Snow Cat")
        app.buttons["saveLocalDisplayNameButton"].tap()
        XCTAssertTrue(app.staticTexts["localDisplayNameSaved"].waitForExistence(timeout: 3))
        try openSavedUserInvitation(inviter: "ui-name-rider", sharedName: "Mountain Rider")
        // The name is changed from the user's own settings in the Users list, not from group selection.
        openUsersTab()
        let row = app.buttons
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                  "standardUser-", "Mountain Rider")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        let userRow = app.buttons[row.identifier].firstMatch
        let openSettings = {
            userRow.swipeLeft()
            let settings = self.app.buttons["User Settings"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 3)); settings.tap()
        }
        openSettings()
        let original = app.descendants(matching: .any)["savedUserOriginalName"].firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 3))
        let name = app.textFields["savedUserNameField"]
        name.tap()
        let enteredName = name.value as? String ?? ""
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: enteredName.count) + "Ski Friend")
        app.buttons["saveUserNameButton"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 3))
        openSettings()
        XCTAssertEqual(app.textFields["savedUserNameField"].value as? String, "Ski Friend")
        XCTAssertTrue(original.waitForExistence(timeout: 3))
        attachScreen("Local Alias and Original Shared Name")
        let originalText = original.label + (original.value as? String ?? "")
            + original.staticTexts.allElementsBoundByIndex.map(\.label).joined()
        XCTAssertTrue(originalText.contains("Mountain Rider"))
        app.buttons["resetUserNameButton"].tap()
        XCTAssertTrue(name.waitForNonExistence(timeout: 3))
        XCTAssertTrue(userRow.waitForExistence(timeout: 3))
        XCTAssertTrue(userRow.label.contains("Mountain Rider"), userRow.label)
        app.terminate(); app.launch(); app.activate()
        openSettingsTab()
        revealSettingsControl(ownName)
        XCTAssertEqual(ownName.value as? String, "Snow Cat")
    }

    @MainActor
    @objc
    func testAccountReplacementCanRemoveOldDataAndSetUpAgainWithoutAppleVerification() throws {
        let reset = app.descendants(matching: .any)["accountDataResetScreen"].firstMatch
        let remove = app.buttons["removePreviousAccountDataButton"]
        XCTAssertTrue(reset.exists)
        XCTAssertFalse(app.buttons["standardCreateGroupButton"].exists)
        remove.tap()
        let confirm = app.buttons["confirmAccountDataResetButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3))
        let cancel = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        cancel.tap()
        XCTAssertTrue(confirm.waitForNonExistence(timeout: 3))
        XCTAssertTrue(reset.exists)
        app.terminate(); app.launch(); app.activate()
        XCTAssertTrue(reset.waitForExistence(timeout: 5))
        attachScreen("Previous Account Data Cleanup")
        remove.tap()
        confirm.tap()
        let finish = app.buttons["finishAccountDeletionButton"]
        XCTAssertTrue(finish.waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["verifyAppleDeletionButton"].exists)
        XCTAssertFalse(app.links["Open Apple Account"].exists)
        attachScreen("Previous Data Removed New Account Kept")
        finish.tap()
        XCTAssertTrue(app.descendants(matching: .any)["appleSignInScreen"].firstMatch.waitForExistence(timeout: 3))
        app.terminate(); app.launch(); app.activate()
        XCTAssertTrue(waitForVisibleRoot(in: app))
        XCTAssertFalse(reset.exists)
        createTalkGroupAndOpenCall()
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 3))
    }

    @MainActor
    @objc
    func testAccountDeletionConfirmsScopeEndsCallAndReturnsToSignIn() throws {
        createTalkGroupAndOpenCall()
        openSettingsTab()
        let deletion = app.buttons["deleteAccountButton"]
        for _ in 0..<6 where !deletion.isHittable { app.swipeDown() }
        XCTAssertTrue(deletion.waitForExistence(timeout: 3)); deletion.tap()
        let erase = app.buttons["deleteWithoutAppleButton"]
        XCTAssertTrue(erase.waitForExistence(timeout: 3))
        // Cancelling the sheet preserves the live account and groups.
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(deletion.waitForExistence(timeout: 3)); deletion.tap()
        for _ in 0..<6 where !erase.isHittable { app.swipeUp() }
        erase.tap()
        let confirmation = app.buttons["Delete"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3)); confirmation.tap()
        let finish = app.buttons["finishAccountDeletionButton"]
        XCTAssertTrue(finish.waitForExistence(timeout: 10))
        let explanation = NSPredicate(format: "label CONTAINS %@", "Apple authorization has not been removed")
        XCTAssertTrue(app.staticTexts.containing(explanation).firstMatch.exists)
        XCTAssertFalse(app.buttons["disconnectButton"].exists)
        attachScreen("Local Account Deletion with Explicit Apple Removal")
        finish.tap()
        XCTAssertTrue(app.buttons["signInWithAppleButton"].firstMatch.waitForExistence(timeout: 5))
        app.terminate(); app.launch(); app.activate() // The isolated native-login fixture signs in again.
        openGroupsTab()
        XCTAssertFalse(app.buttons["disconnectButton"].exists)
        XCTAssertFalse(
            app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardGroup-")).firstMatch.exists
        )
    }

    @MainActor
    @objc
    func testSignOutEndsCallAndReturnsToAppleSignIn() throws {
        createTalkGroupAndOpenCall()
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 3))
        openSettingsTab()
        let signOut = app.buttons["signOutButton"]
        for _ in 0..<6 where !signOut.isHittable { app.swipeDown() }
        XCTAssertTrue(signOut.waitForExistence(timeout: 3))
        signOut.tap()
        let confirmation = app.buttons["confirmSignOutButton"].firstMatch
        XCTAssertTrue(confirmation.waitForExistence(timeout: 3))
        confirmation.tap()
        XCTAssertTrue(app.buttons["signInWithAppleButton"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["disconnectButton"].exists)
        XCTAssertFalse(app.buttons["standardCreateGroupButton"].exists)
        attachScreen("Signed Out Apple Login")
    }

    @MainActor
    @objc
    func testCorruptGroupStoreRecovery() throws {
        // The compile-isolated fixture seeds the actual manifest before launch.
        // Cmd-U uses the same recovery UI and checks the resulting disk files.
        // The app opens on Users; the group list holds the create button this checks.
        openGroupsTab()
        let status = app.descendants(matching: .any)["groupStorageStatus"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["standardCreateGroupButton"].isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["groupErrorLabel"].exists)
        app.buttons["reloadSavedGroupsButton"].tap()
        XCTAssertTrue(status.exists)
        attachScreen("Saved Groups Recovery")
        app.buttons["resetSavedGroupsButton"].tap()
        let cancel = app.alerts.buttons["cancelResetSavedGroupsButton"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 3))
        attachScreen("Confirm Saved Groups Reset")
        cancel.tap()
        XCTAssertTrue(status.exists)
        XCTAssertFalse(app.buttons["standardCreateGroupButton"].isEnabled)
        app.buttons["resetSavedGroupsButton"].tap()
        app.alerts.buttons["confirmResetSavedGroupsButton"].firstMatch.tap()
        XCTAssertTrue(status.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["standardCreateGroupButton"].isEnabled)
        app.terminate()
        app.launchEnvironment["RIDEINTERCOM_GROUP_RECOVERY_FIXTURE"] =
            try XCTUnwrap(app.launchEnvironment["RIDEINTERCOM_GROUP_RECOVERY_FIXTURE"])
            .replacingOccurrences(of: "prepare:", with: "verify:")
        app.launch()
        XCTAssertTrue(waitForVisibleRoot(in: app),
                      "Expected the empty manifest and exact archived corrupt bytes to pass verification")
        XCTAssertFalse(app.descendants(matching: .any)["groupStorageStatus"].exists)
        createTalkGroupAndOpenCall()
        try checkGroupDeletionCanBeExercisedFromUI()
        attachScreen("Saved Groups Recovered")
    }

    @MainActor
    @objc
    func testRecoveryWorkflowInOneLaunch() throws {
        // Restore the required route through UI even if a previous run stopped
        // halfway through changing settings. Do not erase application data.
        openSettingsTab()
        let localRoute = app.switches["Local Network"].firstMatch
        revealSettingsControl(localRoute)
        if localRoute.value as? String == "0" {
            localRoute.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let internetRoute = app.switches["Internet"].firstMatch
        if internetRoute.value as? String == "1" {
            internetRoute.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        openGroupsTab()
        createTalkGroupAndOpenCall()
        try checkGroupSelectionOpensCallScreen()
        try checkManualAddRiderButtonIsNotShownInCallUI()
        try checkParticipantDeletionIsNotShownForLocalMemberOnly()
        try checkCallKeepsDiagnosticsOutOfPrimaryExperience()
        try checkMuteControlLivesWithHeaderMicrophoneMeter()
        let isolation = app.switches["masterVoiceIsolationToggle"].firstMatch
        XCTAssertTrue(isolation.waitForExistence(timeout: 3))
        let originalIsolation = isolation.value as? String
        isolation.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertNotEqual(isolation.value as? String, originalIsolation)
        isolation.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(isolation.value as? String, originalIsolation)
        try checkVoiceActivityAndHandoverCanBeExercisedFromUI()
        for _ in 0..<3 { try checkDisconnectAndReconnectButtonsTransitionInCall() }
        attachScreen("Call")
        try checkGroupsTabReturnsFromCallToGroupDirectory()
        talkGroupRows.firstMatch.tap()
        try checkGroupDeletionCanBeExercisedFromUI()
        try checkDiagnosticsKeepsMicrophoneIndicatorVisibleWithoutGroup()
        try checkDiagnosticsShowRealDeviceSetupIdentifiers()
        attachScreen("Diagnostics")
        try checkTabNavigationShowsExpectedRootSections()
        try checkSettingsShowsConfigPanelsWithoutDiagnosticsRows()
        try checkAudioCheckControlsAreAvailableFromSettings()
        checkSettingsChangesPersistAcrossTabs()
        attachScreen("Settings")
    }
}
