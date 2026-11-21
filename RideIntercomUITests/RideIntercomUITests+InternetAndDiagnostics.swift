import XCTest

extension RideIntercomUITests {
    @MainActor
    @objc
    func testInternetCredentialValidationKeepsTabsUsable() {
        #if os(iOS)
        app.open(URL(string: "rideintercom://join?token=invalid")!)
        XCTAssertTrue(app.descendants(matching: .any)["groupErrorLabel"].firstMatch.waitForExistence(timeout: 5))
        #endif
        checkInternetSettingsRejectUnsecuredURL()
        openGroupsTab()
        openSettingsTab()
        revealSettingsControl(app.buttons["configureInternetConnection"])
        let internet = app.switches["Internet"].firstMatch
        revealSettingsControl(internet)
        if internet.value as? String == "0" {
            internet.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let local = app.switches["Local Network"].firstMatch
        let original = local.value as? String
        if original == "1" {
            local.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertEqual(local.value as? String, "0")
        // Internet-only uses the same controls, even before credentials are configured.
        openGroupsTab()
        createTalkGroupAndOpenCall()
        XCTAssertTrue(app.sliders["masterOutputSlider"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["localMicrophoneMeter"].exists)
        XCTAssertFalse(app.staticTexts["Native audio — meter unavailable"].exists)
        attachScreen("Internet Shared Audio Controls")
        openSettingsTab()
        revealSettingsControl(local)
        if original == "1" {
            local.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        XCTAssertEqual(local.value as? String, original)
    }

    @MainActor
    @objc
    func testAdaptivePipelineStateIsReadableWithoutColor() {
        openDiagnosticsTab()
        selectDiagnosticsPage("TX")
        let row = app.descendants(matching: .any)["pipeline-session-step"].firstMatch
        for _ in 0..<30 where !row.isHittable { app.swipeUp() }
        XCTAssertTrue(row.isHittable)
        XCTAssertTrue(row.label.contains("Session"))
        let value = row.value as? String ?? ""
        XCTAssertTrue(["Idle, ", "Waiting, ", "Passing, ", "Blocked, "].contains { value.hasPrefix($0) }, value)
        XCTAssertGreaterThan(value.split(separator: ",", maxSplits: 1).last?.count ?? 0, 0)
        attachScreen("Pipeline state at accessibility text size")
    }

    @MainActor
    @objc
    func testAdaptiveDiagnosticsAndConfigurationRemainReachable() {
        openDiagnosticsTab()
        selectDiagnosticsPage("Applied")
        let status = app.staticTexts["internetServiceCheckStatus"]
        for _ in 0..<8 where !status.isHittable { app.swipeUp() }
        XCTAssertTrue(status.exists)
        XCTAssertTrue(app.buttons["checkInternetService"].exists)
        XCTAssertFalse(app.buttons["checkInternetService"].isEnabled)
        selectDiagnosticsPage("Network")
        let network = app.staticTexts["networkDiagnosticsSummary"]
        XCTAssertTrue(network.waitForExistence(timeout: 3))
        XCTAssertTrue(network.isHittable, network.debugDescription)
        XCTAssertTrue(network.label.contains("Not measured"))
        attachScreen("Diagnostics Large Text Dark")
        openSettingsTab()
        let configure = app.buttons["configureInternetConnection"]
        revealSettingsControl(configure)
        configure.tap()
        XCTAssertTrue(app.textFields["internetWorkerURL"].waitForExistence(timeout: 3))
        #if os(iOS)
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            self.app.frame.width > self.app.frame.height && self.app.buttons["closeInternetConnection"].isHittable
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 5), .completed)
        #endif
        XCTAssertTrue(app.buttons["closeInternetConnection"].waitForExistence(timeout: 3))
        let save = app.buttons["saveInternetConnection"]
        let form = app.collectionViews.containing(.textField, identifier: "internetWorkerURL").firstMatch
        XCTAssertTrue(form.exists)
        for _ in 0..<20 where !save.exists || save.frame.maxY > app.frame.maxY - 20 { form.swipeUp() }
        XCTAssertTrue(save.exists)
        attachScreen("Internet Settings Landscape Large Text")
        XCTAssertLessThanOrEqual(save.frame.maxY, app.frame.maxY - 20)
        app.buttons["closeInternetConnection"].tap()
        #if os(iOS)
        XCUIDevice.shared.orientation = .portrait
        #endif
        openGroupsTab()
        XCTAssertTrue(waitForVisibleRoot(in: app))
    }

    func openInternetSettings() {
        openSettingsTab()
        let configure = app.buttons["configureInternetConnection"]
        revealSettingsControl(configure)
        XCTAssertTrue(configure.isHittable)
        configure.tap()
    }

    private func checkInternetSettingsRejectUnsecuredURL() {
        openInternetSettings()
        let url = app.textFields["internetWorkerURL"]
        XCTAssertTrue(url.waitForExistence(timeout: 3))
        url.tap(); url.typeText("http://example.com")
        let token = app.secureTextFields["internetDeviceToken"]
        let fixtureToken = "invalid-test-token"
        token.tap(); token.typeText(fixtureToken)
        let save = app.buttons["saveInternetConnection"]
        save.tap()
        let message = "Could not save. Check the HTTPS URL, device token, and Keychain access."
        XCTAssertTrue(app.staticTexts[message].waitForExistence(timeout: 3))
        #if os(iOS)
        // The rejected fixture is not a password to offer to the system store.
        token.tap()
        token.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: fixtureToken.count))
        #endif
        app.buttons["closeInternetConnection"].tap()
        XCTAssertTrue(url.waitForNonExistence(timeout: 5))
    }

    func checkSettingsChangesPersistAcrossTabs() {
        openSettingsTab()
        attachScreen("Settings before edits")
        let local = app.switches["Local Network"].firstMatch
        let internet = app.switches["Internet"].firstMatch
        revealSettingsControl(local)
        revealSettingsControl(internet)
        if internet.value as? String == "0" {
            internet.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        let original = local.value as? String
        local.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertNotEqual(local.value as? String, original)
        XCTAssertFalse(internet.isEnabled) // The remaining route cannot be disabled.
        openGroupsTab()
        openSettingsTab()
        XCTAssertNotEqual(local.value as? String, original)
        local.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(local.value as? String, original)
        let isolation = revealTransmitIsolationToggle()
        XCTAssertTrue(isolation.waitForExistence(timeout: 3))
        let originalIsolation = isolation.value as? String
        isolation.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertNotEqual(isolation.value as? String, originalIsolation)
        openGroupsTab()
        openSettingsTab()
        let retainedIsolation = revealTransmitIsolationToggle()
        XCTAssertNotEqual(retainedIsolation.value as? String, originalIsolation)
        retainedIsolation.switches.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertEqual(retainedIsolation.value as? String, originalIsolation)
        revealSettingsPanelIfNeeded(identifier: "transmitCodecPanel")
        let codec = app.segmentedControls.containing(.button, identifier: "PCM 16-bit").firstMatch
        for _ in 0..<6 where !codec.buttons["Opus"].isHittable {
            app.descendants(matching: .any)["settingsScrollView"].firstMatch.swipeUp()
        }
        codec.buttons["Opus"].tap()
        XCTAssertTrue(codec.buttons["Opus"].isSelected)
        codec.buttons["PCM 16-bit"].tap()
        XCTAssertTrue(codec.buttons["PCM 16-bit"].isSelected)
    }

    private func revealTransmitIsolationToggle() -> XCUIElement {
        let toggle = app.switches["Transmit Voice Isolation Effect"].firstMatch
        revealSettingsControl(toggle)
        return toggle
    }
}
