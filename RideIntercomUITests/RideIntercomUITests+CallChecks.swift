import XCTest

extension RideIntercomUITests {
    @MainActor
    func checkGroupSelectionOpensCallScreen() throws {

        XCTAssertTrue(app.staticTexts["Participants"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["localMicrophonePanel"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["localMicrophoneMeter"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Unmuted"].exists)
        XCTAssertTrue(app.staticTexts["callPresenceLabel"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["routeLabel"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["localMicrophoneMuteButton"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.sliders.firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Mute Output"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["Mute"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.buttons["inviteButton"].exists)
        XCTAssertFalse(app.buttons["addSavedUsersButton"].exists)
        XCTAssertTrue(app.buttons["disconnectButton"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["emptyRemoteParticipantsLabel"].waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["callAudioOutputPicker"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["callAudioInputPicker"].exists)
    }

    @MainActor
    func checkManualAddRiderButtonIsNotShownInCallUI() throws {

        XCTAssertFalse(app.buttons["Add Rider"].exists)
        XCTAssertFalse(app.buttons["inviteButton"].exists)
        XCTAssertFalse(app.buttons["addSavedUsersButton"].exists)
    }

    @MainActor
    func checkMuteControlLivesWithHeaderMicrophoneMeter() throws {

        XCTAssertTrue(app.descendants(matching: .any)["localMicrophoneMeter"].waitForExistence(timeout: 3))
        let muteButton = app.buttons["localMicrophoneMuteButton"]
        XCTAssertTrue(muteButton.waitForExistence(timeout: 3))
        muteButton.tap()
        XCTAssertTrue(app.staticTexts["Muted"].waitForExistence(timeout: 2))
    }

    @MainActor
    func checkParticipantDeletionIsNotShownForLocalMemberOnly() throws {

        XCTAssertFalse(app.buttons["Add Rider"].exists)
        XCTAssertFalse(app.buttons["removeParticipantButton0"].exists)
        XCTAssertFalse(app.buttons["inviteButton"].exists)
        XCTAssertFalse(app.buttons["addSavedUsersButton"].exists)
    }

    @MainActor
    func checkDiagnosticsShowRealDeviceSetupIdentifiers() throws {
        showEmptyDiagnostics()
        selectDiagnosticsPage("Network")
        XCTAssertTrue(app.staticTexts["networkDiagnosticsSummary"].waitForExistence(timeout: 3))
        selectDiagnosticsPage("TX")
        XCTAssertTrue(app.descendants(matching: .any)["liveTransmitPipelineView"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["pipeline-session-step"].exists)
        let mixer = app.descendants(matching: .any)["pipeline-mixer-step"].firstMatch
        XCTAssertTrue(mixer.exists)
        mixer.tap()
        XCTAssertTrue(app.descendants(matching: .any)["pipeline-effects-step"].waitForExistence(timeout: 3))
        selectDiagnosticsPage("RX")
        XCTAssertTrue(app.descendants(matching: .any)["liveReceivePipelineView"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["receive-pipeline-mix-step"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["receive-mix-topology"].exists)
        XCTAssertTrue(app.descendants(matching: .any)["receive-pipeline-output-step"].exists)
        selectDiagnosticsPage("Overview")
        revealDiagnosticOverview()
        XCTAssertTrue(app.descendants(matching: .any)["diagnosticsStageDots-RX"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["audioIOPanel"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["audioCheckPanel"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["callAudioOutputPicker"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["callAudioInputPicker"].exists)
    }

    @MainActor
    func checkAudioCheckControlsAreAvailableFromSettings() throws {
        openSettingsTab()

        revealSettingsPanelIfNeeded(identifier: "audioIOPanel")
        XCTAssertTrue(app.descendants(matching: .any)["audioIOPanel"].firstMatch.waitForExistence(timeout: 3))

        revealAudioCheckControlsIfNeeded()

        XCTAssertTrue(audioCheckButtonElement().waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["audioCheckPanel"].firstMatch.waitForExistence(timeout: 3))
    }

    @MainActor
    func checkVoiceActivityAndHandoverCanBeExercisedFromUI() throws {

        XCTAssertTrue(app.buttons["disconnectButton"].exists)
        XCTAssertFalse(app.buttons["Refresh"].exists)
        XCTAssertFalse(app.buttons["Simulate Handover"].exists)
        XCTAssertFalse(app.staticTexts["Silent"].exists)
    }

    @MainActor
    func checkCallKeepsDiagnosticsOutOfPrimaryExperience() throws {

        XCTAssertFalse(app.descendants(matching: .any)["realDeviceCallDebugSummaryLabel"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["transportDebugSummaryLabel"].exists)
        XCTAssertFalse(app.descendants(matching: .any)["groupHashDebugSummaryLabel"].exists)
        XCTAssertFalse(app.staticTexts["Live TX Pipeline"].exists)
    }

    @MainActor
    func checkGroupDeletionCanBeExercisedFromUI() throws {
        openGroupsTab()

        let groupRows = talkGroupRows
        let initialCount = groupRows.count
        let groupRow = groupRows.firstMatch
        XCTAssertTrue(groupRow.waitForExistence(timeout: 3))
        app.removeGroupRow(groupRow)
        XCTAssertLessThan(talkGroupRows.count, initialCount)
    }

    @MainActor
    func checkDiagnosticsKeepsMicrophoneIndicatorVisibleWithoutGroup() throws {
        showEmptyDiagnostics()
        selectDiagnosticsPage("TX")
        XCTAssertTrue(app.descendants(matching: .any)["liveTransmitPipelineView"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["pipeline-input-step"].exists)
        // No invented idle Mixer effects.
        XCTAssertFalse(app.descendants(matching: .any)["pipeline-effect-stage-vad-gate"].exists)
        selectDiagnosticsPage("RX")
        XCTAssertTrue(app.descendants(matching: .any)["liveReceivePipelineView"].waitForExistence(timeout: 3))
    }

    @MainActor
    func checkTabNavigationShowsExpectedRootSections() throws {
        openGroupsTab()
        XCTAssertTrue(app.descendants(matching: .any)["standardGroupsList"].firstMatch.waitForExistence(timeout: 3))

        openDiagnosticsTab()
        XCTAssertTrue(app.descendants(matching: .any)["diagnosticsScrollView"].firstMatch.waitForExistence(timeout: 3))
        selectDiagnosticsPage("TX")
        XCTAssertTrue(app.descendants(matching: .any)["pipeline-session-step"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["pipeline-input-step"].firstMatch.waitForExistence(timeout: 3))

        openSettingsTab()
        XCTAssertTrue(app.descendants(matching: .any)["settingsScrollView"].firstMatch.waitForExistence(timeout: 3))
        revealSettingsPanelIfNeeded(identifier: "audioSessionPanel")
        XCTAssertTrue(app.descendants(matching: .any)["audioSessionPanel"].firstMatch.waitForExistence(timeout: 3))
        revealSettingsPanelIfNeeded(identifier: "transmitCodecPanel")
        XCTAssertTrue(app.descendants(matching: .any)["transmitCodecPanel"].firstMatch.waitForExistence(timeout: 3))
        revealSettingsPanelIfNeeded(identifier: "voiceActivityPanel")
        XCTAssertTrue(app.descendants(matching: .any)["voiceActivityPanel"].firstMatch.waitForExistence(timeout: 3))

        openGroupsTab()
        XCTAssertTrue(waitForVisibleRoot(in: app))
    }

    @MainActor
    func checkGroupsTabReturnsFromCallToGroupDirectory() throws {
        let call = app.descendants(matching: .any)["callScreen"].firstMatch
        XCTAssertTrue(call.waitForExistence(timeout: 3))
        XCTAssertFalse(call.buttons["showGroupsButton"].exists)
        XCTAssertFalse(call.buttons["createGroupButton"].exists)
        XCTAssertFalse(call.buttons["standardCreateGroupButton"].exists)
        openGroupsTab()
        XCTAssertTrue(app.descendants(matching: .any)["standardGroupsList"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.buttons["standardCreateGroupButton"].firstMatch.exists)
    }

    @MainActor
    func checkDisconnectAndReconnectButtonsTransitionInCall() throws {

        let disconnectButton = app.buttons["disconnectButton"].firstMatch
        XCTAssertTrue(disconnectButton.waitForExistence(timeout: 3))
        disconnectButton.tap()

        // Ending closes the call; choosing the group again reconnects at once.
        XCTAssertTrue(app.descendants(matching: .any)["callScreen"].firstMatch.waitForNonExistence(timeout: 5))
        openGroupsTab()
        let group = talkGroupRows.firstMatch
        XCTAssertTrue(group.waitForExistence(timeout: 3))
        group.tap()

        XCTAssertTrue(app.buttons["disconnectButton"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor
    func checkSettingsShowsConfigPanelsWithoutDiagnosticsRows() throws {
        openSettingsTab()

        revealSettingsPanelIfNeeded(identifier: "audioSessionPanel")
        XCTAssertTrue(app.descendants(matching: .any)["audioSessionPanel"].firstMatch.waitForExistence(timeout: 3))
        let explanation = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] %@", "mode uses")).firstMatch
        revealSettingsControl(explanation, fullyVisible: false)
        XCTAssertTrue(explanation.exists)
        XCTAssertFalse(app.descendants(matching: .any)["audioSessionProfileStatus"].firstMatch.exists)
        revealSettingsPanelIfNeeded(identifier: "audioIOPanel")
        XCTAssertTrue(app.descendants(matching: .any)["audioIOPanel"].firstMatch.waitForExistence(timeout: 3))
        revealAudioCheckControlsIfNeeded()
        XCTAssertTrue(app.descendants(matching: .any)["audioCheckPanel"].firstMatch.waitForExistence(timeout: 3))
        revealSettingsPanelIfNeeded(identifier: "transmitCodecPanel")
        XCTAssertTrue(app.descendants(matching: .any)["transmitCodecPanel"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["transmitCodecStatus"].firstMatch.exists)
        revealSettingsPanelIfNeeded(identifier: "voiceActivityPanel")
        XCTAssertTrue(app.descendants(matching: .any)["voiceActivityPanel"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertFalse(app.descendants(matching: .any)["vadAnalysisStatus"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["audioIOApplyStateLabel"].firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any)["audioInputProcessingSummaryLabel"].firstMatch.exists)
    }

    func assertAdvancedCallHasNoManagementControls() {
        let call = app.descendants(matching: .any)["callScreen"].firstMatch
        XCTAssertTrue(call.waitForExistence(timeout: 3))
        // The lists stay underneath the call sheet; only the call itself must not offer management.
        for identifier in ["inviteButton", "addSavedUsersButton", "showGroupsButton", "createGroupButton",
                           "standardCreateGroupButton", "editParticipantNameButton0", "removeParticipantButton0"] {
            XCTAssertFalse(call.buttons[identifier].exists,
                               "Management control remains in Advanced Call: \(identifier)")
        }
        XCTAssertFalse(call.buttons["Edit Name"].exists)
        XCTAssertFalse(call.buttons.containing(.staticText, identifier: "participantName0").firstMatch.exists)
        XCTAssertFalse(call.buttons["Delete"].exists)
    }

    /// Group Settings opens from the row's swipe (or context menu); the row tap only connects.
    func openTalkGroupManagement() {
        openGroupsTab()
        openRowSettings(talkGroupRows.firstMatch, "Group Settings", view: "groupSettingsView")
    }

    func openRowSettings(_ row: XCUIElement, _ title: String, view: String) {
        XCTAssertTrue(row.waitForExistence(timeout: 3))
        row.swipeLeft()
        let settings = app.buttons[title].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 3))
        settings.tap()
        XCTAssertTrue(app.descendants(matching: .any)[view].firstMatch.waitForExistence(timeout: 3))
    }

    func copyManagementInvitation(
        identifier: String = "groupSettingsInviteButton",
        view: String = "groupSettingsView"
    ) {
        let invite = app.buttons[identifier].firstMatch
        XCTAssertTrue(invite.waitForExistence(timeout: 3))
        invite.tap()
        let copy = app.cells.matching(NSPredicate(format: "label == 'Copy' OR label == 'Copy Link'")).firstMatch
        XCTAssertTrue(copy.waitForExistence(timeout: 5), "Native sharing offers the invitation URL")
        attachScreen("Directory management invitation native share sheet")
        copy.tap()
        XCTAssertTrue(copy.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any)[view].firstMatch.exists)
        XCTAssertTrue(invite.exists)
    }

    func closeManagementAndReturnToCall() {
        let close = ["closeGroupSettingsButton", "closeUserSettingsButton"].map { app.buttons[$0].firstMatch }
            .first { $0.exists } ?? app.buttons["closeGroupSettingsButton"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 3))
        app.openCurrentCall()
        XCTAssertTrue(app.descendants(matching: .any)["callScreen"].firstMatch.waitForExistence(timeout: 3))
    }

    var talkGroupRows: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "standardGroup-"))
            .containing(.staticText, identifier: "Talk Group")
    }

    func createTalkGroupAndOpenCall(advanced: Bool = true, handlesMicrophonePrompt: Bool = false) {
        openGroupsTab()
        removeExistingTalkGroups()
        let createButton = app.buttons["standardCreateGroupButton"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 3))
        createButton.tap()
        let name = app.textFields["savedUsersGroupNameField"]
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        let enteredName = (name.value as? String)?.count ?? 0
        name.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: enteredName) + "Talk Group")
        app.buttons["saveUserSelectionButton"].tap()
        #if os(iOS)
        if handlesMicrophonePrompt {
            let allow = XCUIApplication(bundleIdentifier: "com.apple.springboard")
                .alerts["kTCCServiceMicrophone-alert"].firstMatch
                .buttons["kTCCServiceMicrophone-allow-button"].firstMatch
            if allow.waitForExistence(timeout: 2) { allow.tap() }
        }
        #endif
        let callScreen = advanced ? "callScreen" : "standardCallScreen"
        XCTAssertTrue(app.descendants(matching: .any)[callScreen].waitForExistence(timeout: 3))
        let participants = advanced ? "Participants" : "standardCallParticipantsHeading"
        XCTAssertTrue(app.staticTexts[participants].waitForExistence(timeout: 3))
    }
}
