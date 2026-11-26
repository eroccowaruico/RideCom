#if os(iOS)
import XCTest

extension BackgroundCallLifecycleUITests {
    @MainActor
    @objc func testStartInvitedTrialGroupMuted() throws {
        try startInvitedTrialGroupMuted()
    }

    #if targetEnvironment(simulator)
    @MainActor
    @objc func testStartInvitedTrialGroupMutedInAdvanced() throws {
        let pairedMode = ProcessInfo.processInfo.environment["RIDEINTERCOM_PAIRED_DIAGNOSTICS"]
        try startInvitedTrialGroupMuted(advancedFixture: true, pairedMode: pairedMode)
    }
    #endif

    @MainActor
    private func startInvitedTrialGroupMuted(advancedFixture: Bool = false, pairedMode: String? = nil) throws {
        let app = XCUIApplication()
        let pairedReceiver = pairedMode == "1" || pairedMode == "late-join"
        #if targetEnvironment(simulator)
        // The paired runner owns and removes this Simulator after checking that the call outlives the UI test.
        defer { if !pairedReceiver { app.terminate() } }
        let trialID = UUID()
        if pairedReceiver {
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10), "The isolated receiver is not running")
            app.activate()
        } else {
            app.launchEnvironment = ["RIDEINTERCOM_LOCAL_TESTING": "1", "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in",
                "RIDEINTERCOM_INTERFACE_FIXTURE": advancedFixture ? "advanced" : "standard"]
            app.launch()
        }
        #else
        let suppliedID = ProcessInfo.processInfo.environment["RIDEINTERCOM_INSTALLED_TRIAL_ID"]
        try XCTSkipIf(suppliedID == nil, "No trial invitation was scheduled for this device run")
        let trialID = try XCTUnwrap(suppliedID.flatMap(UUID.init(uuidString:)), "Invalid trial identifier")
        app.activate()
        #endif

        let end = app.buttons.matching(
            NSPredicate(format: "identifier IN %@", ["standardEndCallButton", "disconnectButton"])
        ).firstMatch
        let activeCallAccessory = app.buttons["callAccessoryOpenButton"].firstMatch
        XCTAssertFalse(end.exists || activeCallAccessory.exists, "A call is already active")
        let groupName = pairedReceiver ? "Audio E2E" : "RideCom Trial " + trialID.uuidString.prefix(8)
        FileHandle.standardOutput.write(Data("RIDE_INSTALLED_INVITE_READY\n".utf8))
        #if targetEnvironment(simulator)
        if !pairedReceiver {
            let invitation = try InvitationURLFixture.make(inviter: "trial-host-" + trialID.uuidString, name: groupName)
            XCUIDevice.shared.system.open(invitation)
        }
        #endif
        waitForTrialCall(end)
        let advanced = end.identifier == "disconnectButton"
        #if targetEnvironment(simulator)
        XCTAssertEqual(advanced, advancedFixture, "The trial opened in a different interface")
        #endif
        let title = advanced ? app.navigationBars[groupName].firstMatch : app.staticTexts[groupName].firstMatch
        XCTAssertTrue(title.exists, "The active call is not the selected trial")
        let mute = app.buttons[advanced ? "localMicrophoneMuteButton" : "standardMuteButton"].firstMatch
        XCTAssertTrue(mute.waitForExistence(timeout: 5))
        if !mute.isSelected { mute.tap() }
        let muted = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: mute)
        XCTAssertEqual(XCTWaiter.wait(for: [muted], timeout: 5), .completed, "The microphone did not become muted")
        XCTAssertTrue(end.exists, "The trial call is no longer active")
        FileHandle.standardOutput.write(Data("RIDE_INSTALLED_GROUP_CALL_MUTED\n".utf8))
        #if targetEnvironment(simulator)
        if pairedMode == "1" { try verifyPairedReceiveDiagnostics(in: app) }
        #endif
    }

    @MainActor
    private func waitForTrialCall(_ end: XCUIElement) {
        let rideComAlert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts
            .containing(NSPredicate(format: "elementType == %@ AND label CONTAINS %@",
                NSNumber(value: XCUIElement.ElementType.staticText.rawValue), "RideCom"))
        let open = rideComAlert.buttons
            .matching(NSPredicate(format: "label IN %@", ["Open", "開く"])).firstMatch
        let deadline = ProcessInfo.processInfo.systemUptime + 30
        while ProcessInfo.processInfo.systemUptime < deadline {
            if end.waitForExistence(timeout: 1) { return }
            if open.exists {
                open.tap()
                break
            }
        }
        XCTAssertTrue(end.waitForExistence(timeout: max(0, deadline - ProcessInfo.processInfo.systemUptime)),
                      "The trial invitation did not start a call")
    }

    @MainActor func confirmExternalApplicationOpen(timeout: TimeInterval) {
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons
            .matching(NSPredicate(format: "label IN %@", ["Open", "開く"])).firstMatch
        if open.waitForExistence(timeout: timeout) { open.tap() }
    }

    #if targetEnvironment(simulator)
    @MainActor
    func verifyPairedReceiveDiagnostics(in app: XCUIApplication) throws {
        app.openDiagnosticsTab()
        let rxTab = app.segmentedControls["diagnosticsPagePicker"].buttons["RX"].firstMatch
        XCTAssertTrue(rxTab.exists)
        rxTab.tap()
        let rtc = app.descendants(matching: .any)["receive-pipeline-rtc-step"].firstMatch
        let decode = app.descendants(matching: .any)["receive-pipeline-codec-step"].firstMatch
        let output = app.descendants(matching: .any)["receive-pipeline-output-step"].firstMatch
        XCTAssertTrue(decode.waitForExistence(timeout: 8))
        XCTAssertTrue(rtc.isHittable && decode.isHittable)
        let scroll = app.descendants(matching: .any)["diagnosticsScrollView"].firstMatch
        for _ in 0..<6 where !output.isHittable { scroll.swipeUp() }
        XCTAssertTrue(output.isHittable)
        FileHandle.standardOutput.write(Data("AUDIO_E2E_DIAGNOSTICS_READY\n".utf8))

        for (marker, passing) in [("FIRST_AUDIO", true), ("AUDIO_IDLE", false), ("RESUMED", true)] {
            verifyReceiveStages(rtc: rtc, decode: decode, output: output, passing: passing)
            let value = try XCTUnwrap(output.value as? String)
            let observedAt = Date().timeIntervalSince1970
            let line = "AUDIO_E2E_DIAGNOSTICS_\(marker) \(observedAt) \(value)\n"
            FileHandle.standardOutput.write(Data(line.utf8))
        }
        XCTAssertTrue(rxTab.isSelected)
    }

    @MainActor
    private func verifyReceiveStages(rtc: XCUIElement, decode: XCUIElement, output: XCUIElement, passing: Bool) {
        let state = passing ? "Passing," : "Waiting,"
        let receipt = passing ? "Audio received" : "Audio RX idle"
        let matchesRTC = NSPredicate(format: "value BEGINSWITH %@ AND value CONTAINS %@ AND value CONTAINS %@",
                                     state, receipt, "1 authenticated")
        let matchesDecode = NSPredicate(format: "value BEGINSWITH %@ AND value CONTAINS %@", state, "Last PCM")
        let matchesOutput = NSPredicate(format: "value BEGINSWITH %@ AND value CONTAINS %@ AND value CONTAINS %@",
            state, "Last audible PCM", "Last render")
        let expectations = [XCTNSPredicateExpectation(predicate: matchesRTC, object: rtc),
                            XCTNSPredicateExpectation(predicate: matchesDecode, object: decode),
                            XCTNSPredicateExpectation(predicate: matchesOutput, object: output)]
        XCTAssertEqual(XCTWaiter.wait(for: expectations, timeout: 35), .completed,
                       "RTC RX, Decode, and Output must all show \(state) in the same authenticated call")
    }
    #endif
}
#endif
