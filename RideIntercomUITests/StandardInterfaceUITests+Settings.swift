import XCTest

extension StandardInterfaceUITests {
    @MainActor
    @objc
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

    #if os(iOS)
    @MainActor
    @objc
    func testStandardSettingsKeepsWatchControlsInDeveloperSettings() {
        launch()
        tab("Settings", id: "settingsTab")
        let regular = app.buttons["callDisconnectIntervalPicker"].firstMatch
        let watch = app.buttons["watchCallDisconnectIntervalPicker"].firstMatch
        revealStandardSettingsControl(regular)
        XCTAssertFalse(watch.exists, "The normal timer settings must not advertise Watch controls")

        func openDeveloperSettings() {
            let more = app.buttons["moreSettingsLink"].firstMatch
            revealStandardSettingsControl(more)
            more.tap()
            XCTAssertTrue(app.navigationBars["Advanced Settings for Developers"].waitForExistence(timeout: 3))
        }
        func selectWatchInterval(_ title: String) {
            watch.tap()
            let option = app.buttons[title].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 3))
            option.tap()
        }

        openDeveloperSettings()
        guard UIDevice.current.userInterfaceIdiom == .phone else {
            XCTAssertFalse(watch.exists)
            XCTAssertFalse(app.staticTexts["Apple Watch"].exists)
            return
        }
        revealStandardSettingsControl(watch)
        XCTAssertTrue(watch.label.contains("Calls Started from Watch"))
        XCTAssertTrue(watch.isEnabled)
        XCTAssertFalse(regular.exists)
        selectWatchInterval("1 minute")
        app.terminate(); app.launch(); app.activate()
        tab("Settings", id: "settingsTab")
        openDeveloperSettings()
        revealStandardSettingsControl(watch)
        XCTAssertTrue(watch.label.contains("1 minute") || (watch.value as? String) == "1 minute")
        screenshot("Watch timer separated into developer settings")
        selectWatchInterval("5 minutes (Default)")
    }

    @MainActor
    @objc
    func testAdvancedSettingsDisablesWatchTimerOnIPhoneOnly() {
        launch(interface: "advanced")
        tab("Settings", id: "settingsTab")
        let regular = app.buttons["callDisconnectIntervalPicker"].firstMatch
        revealStandardSettingsControl(regular)
        XCTAssertTrue(regular.isEnabled)
        let watch = app.buttons["watchCallDisconnectIntervalPicker"].firstMatch
        let expectsWatch = UIDevice.current.userInterfaceIdiom == .phone
        XCTAssertEqual(watch.exists, expectsWatch)
        if expectsWatch { XCTAssertFalse(watch.isEnabled) }
        screenshot("Watch timer availability in Advanced Settings")
    }
    #endif

    @MainActor
    @objc
    func testStandardSettingsSeparatesRoutineControlsAndConfirmsReset() {
        launch()
        tab("Settings", id: "settingsTab")
        XCTAssertFalse(app.descendants(matching: .any)["interfaceModePicker"].firstMatch.exists)

        checkEnglishCommunicationSettings()

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
        XCTAssertTrue(layout.buttons["Standard"].exists && layout.buttons["Advanced"].exists,
                      "Both layouts are visible at once")
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
        screenshot("Standard More Settings keeps experimental controls separate")
        app.navigationBars.buttons.element(boundBy: 0).tap()

        checkStandardSettingsReset(vad: vad, noisy: noisy, more: more, layout: layout)
    }

    @MainActor
    private func checkEnglishCommunicationSettings() {
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
    }

    @MainActor
    private func checkStandardSettingsReset(
        vad: XCUIElement,
        noisy: XCUIElement,
        more: XCUIElement,
        layout: XCUIElement
    ) {
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
    @objc
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
    @objc
    func testStandardCommunicationSummaryAndLayoutRoundTripInLandscape() {
        #if os(iOS)
        defer { XCUIDevice.shared.orientation = .portrait }
        for japanese in [false, true] {
            terminateAppIfLaunched()
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
            if internet.value as? String != "1" {
                XCTAssertTrue(internet.isEnabled)
                internet.switches.firstMatch.tap()
            }
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

    @MainActor func revealStandardSettingsControl(_ control: XCUIElement) {
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
    @objc
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
    @objc
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
}
