import XCTest

extension RideIntercomUITests {
    @MainActor
    @objc
    func testAACBitrateChoicesSurviveCodecSwitches() {
        openSettingsTab()
        let scroll = app.descendants(matching: .any)["settingsScrollView"].firstMatch
        let codec = app.segmentedControls.containing(.button, identifier: "PCM 16-bit").firstMatch
        for _ in 0..<8 where !codec.buttons[aacELD].isHittable { scroll.swipeUp() }
        XCTAssertTrue(app.staticTexts["transmitCodecLabel"].exists)
        XCTAssertTrue(app.staticTexts["rtcAudioSampleRateLabel"].exists)
        codec.buttons[aacELD].tap()
        let format = app.segmentedControls.containing(.button, identifier: defaultSampleRate).firstMatch
        let rateOptions = [
            (defaultSampleRate, [32, 48, 64, 80, 96, 112, 128]),
            ("24 kHz", [16, 32, 48, 64]),
            ("16 kHz", [48])
        ]
        for (sampleRate, rates) in rateOptions {
            format.buttons[sampleRate].tap()
            for otherCodec in ["PCM 16-bit", "Opus", "PCM 16-bit"] {
                codec.buttons[otherCodec].tap()
                codec.buttons[aacELD].tap()
                let bitrate = app.buttons["aacELDBitRatePicker"].firstMatch
                XCTAssertTrue(bitrate.waitForExistence(timeout: 3))
                bitrate.tap()
                attachScreen("AAC menu \(sampleRate) after \(otherCodec)")
                func label(_ rate: Int) -> String {
                    let lowerQuality = (sampleRate == defaultSampleRate && rate == 32)
                            || (sampleRate == "24 kHz" && rate == 16)
                    return "\(rate) kbps" + (lowerQuality ? " (Lower Quality)" : "") + (rate == 48 ? " (Default)" : "")
                }
                for rate in [16, 32, 48, 64, 80, 96, 112, 128] {
                    XCTAssertEqual(app.buttons[label(rate)].firstMatch.exists, rates.contains(rate),
                                      "\(sampleRate): \(rate) kbps after \(otherCodec)")
                }
                guard let selectedRate = rates.first else {
                    XCTFail("Expected at least one AAC bitrate")
                    return
                }
                app.buttons[label(selectedRate)].firstMatch.tap()
                XCTAssertTrue(bitrate.label.contains(label(selectedRate))
                              || (bitrate.value as? String)?.contains(label(selectedRate)) == true)
            }
        }
        format.buttons[defaultSampleRate].tap()
    }

    @MainActor
    @objc
    func testOpusManualLowBandwidthChoicesSurviveFormatAndCodecChanges() {
        openSettingsTab()
        let scroll = app.descendants(matching: .any)["settingsScrollView"].firstMatch
        let codec = app.segmentedControls.containing(.button, identifier: "PCM 16-bit").firstMatch
        for _ in 0..<8 where !codec.buttons["Opus"].isHittable { scroll.swipeUp() }
        codec.buttons["Opus"].tap()
        let format = app.segmentedControls.containing(.button, identifier: defaultSampleRate).firstMatch
        let bitrate = app.steppers["opusBitRateStepper"].firstMatch
        revealSettingsControl(bitrate)
        XCTAssertTrue(bitrate.waitForExistence(timeout: 3))
        func expectRate(_ rate: Int, lowQuality: Bool) {
            let value = bitrate.value as? String ?? ""
            XCTAssertTrue(value.contains("\(rate) kbps"), value)
            XCTAssertEqual(value.contains("Lower Quality"), lowQuality)
        }
        for sampleRate in [defaultSampleRate, "24 kHz", "16 kHz"] {
            format.buttons[sampleRate].tap()
            for _ in 0..<53 where !(bitrate.value as? String ?? "").contains("24 kbps") {
                bitrate.buttons["opusBitRateStepper-Decrement"].tap()
            }
            expectRate(24, lowQuality: true)
            bitrate.buttons["opusBitRateStepper-Decrement"].tap()
            expectRate(24, lowQuality: true)
            bitrate.buttons["opusBitRateStepper-Increment"].tap()
            expectRate(32, lowQuality: true)
            codec.buttons["PCM 16-bit"].tap(); codec.buttons["Opus"].tap()
            expectRate(32, lowQuality: true)
            bitrate.buttons["opusBitRateStepper-Increment"].tap()
            expectRate(48, lowQuality: false)
            XCTAssertTrue(app.staticTexts["opusLowBandwidthExplanation"].exists)
            attachScreen("Opus manual choices \(sampleRate)")
        }
        format.buttons[defaultSampleRate].tap()
    }

    @MainActor
    @objc
    func testRegularCallDisconnectTimerPersists() {
        openSettingsTab()
        let regular = app.buttons["callDisconnectIntervalPicker"].firstMatch
        let watch = app.descendants(matching: .any)["watchCallDisconnectIntervalPicker"].firstMatch
        func expect(_ picker: XCUIElement, _ title: String) {
            revealSettingsControl(picker)
            XCTAssertTrue(picker.label.contains(title) || (picker.value as? String)?.contains(title) == true)
        }
        func select(_ picker: XCUIElement, _ title: String) {
            revealSettingsControl(picker)
            picker.tap()
            let option = app.buttons[title].firstMatch
            XCTAssertTrue(option.waitForExistence(timeout: 3))
            option.tap()
            expect(picker, title)
        }
        // Start from the marked defaults: a run that failed part-way leaves its choices saved.
        select(regular, "3 hours (Default)")
        #if os(iOS)
        let expectsWatch = UIDevice.current.userInterfaceIdiom == .phone
        #else
        let expectsWatch = false
        #endif
        XCTAssertEqual(watch.exists, expectsWatch)
        if expectsWatch { XCTAssertFalse(watch.isEnabled) }
        let watchValue = expectsWatch ? watch.value as? String : nil
        select(regular, "15 minutes")
        openGroupsTab(); openSettingsTab()
        expect(regular, "15 minutes")
        app.terminate(); app.launch(); app.activate()
        openSettingsTab()
        expect(regular, "15 minutes")
        XCTAssertEqual(watch.exists, expectsWatch)
        if expectsWatch {
            XCTAssertFalse(watch.isEnabled)
            XCTAssertEqual(watch.value as? String, watchValue)
        }
        attachScreen("Regular call disconnection timer")
        select(regular, "3 hours (Default)")
    }

    #if os(iOS)
    /// Layout/localization coverage only; native recording has separate acceptance.
    @MainActor
    @objc
    func testAudioCheckShowsOneStartButtonInBothLayoutsAndLanguages() {
        for (mode, japanese) in [("standard", false), ("advanced", false),
                                  ("standard", true), ("advanced", true)] {
            app.terminate()
            app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = mode
            app.launchArguments = ["-AppleLanguages", japanese ? "(ja)" : "(en)",
                                   "-AppleLocale", japanese ? "ja_JP" : "en_US"]
            app.launch()
            app.activate()
            let settings = app.tabBars.buttons[japanese ? "設定" : "Settings"].firstMatch
            XCTAssertTrue(settings.waitForExistence(timeout: 5))
            settings.tap()
            let button = app.buttons["audioCheckButton"].firstMatch
            revealSettingsControl(button)
            XCTAssertEqual(button.label, japanese ? "5秒録音して再生" : "Record 5s and Play")
            XCTAssertTrue(button.isEnabled)
            XCTAssertEqual(app.buttons.matching(identifier: "audioCheckButton").count, 1)
            XCTAssertFalse(app.buttons["stopAudioCheckButton"].exists)
            XCTAssertFalse(app.buttons[japanese ? "音声チェックを停止" : "Stop Audio Check"].exists)
            attachScreen("Single recording control \(mode) \(japanese ? "Japanese" : "English")")
        }
    }

    @MainActor
    @objc
    func testPhoneAudioCheckRecordsAndPlaysFromSettings() {
        let permissionMonitor = monitorMicrophonePermission()
        defer { removeUIInterruptionMonitor(permissionMonitor) }
        openSettingsTab()
        revealSettingsPanelIfNeeded(identifier: "audioIOPanel")
        let scroll = app.descendants(matching: .any)["settingsScrollView"].firstMatch
        let candidates = [app.buttons["audioCheckButton"].firstMatch,
                          app.descendants(matching: .any)["audioCheckButton"].firstMatch,
                          app.buttons["Record 5s and Play"].firstMatch]
        attachAudioCheckObservation("Audio Check before section navigation", scroll: scroll, candidates: candidates)
        revealSettingsControl(candidates[0])
        attachAudioCheckObservation("Audio Check after section navigation", scroll: scroll, candidates: candidates)
        let button = candidates.first { $0.exists && $0.isHittable && $0.isEnabled }
        guard let button else { XCTFail("Audio Check button unavailable after bounded observation"); return }
        let phase = app.staticTexts["audioCheckPhaseLabel"]
        let status = app.staticTexts["audioCheckStatusLabel"]
        let input = app.descendants(matching: .any)["audioCheckInputSource"].firstMatch
        let output = app.descendants(matching: .any)["audioCheckOutputDestination"].firstMatch
        let inputMeter = app.descendants(matching: .any)["audioCheckInputMeter"].firstMatch
        let outputMeter = app.descendants(matching: .any)["audioCheckOutputMeter"].firstMatch
        for cycle in 1...2 {
            button.tap()
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            if springboard.alerts.firstMatch.waitForExistence(timeout: 2) { app.tap() }
            for expected in ["Recording", "Playing Back", "Audio Check Complete"] {
                let predicate = NSPredicate(format: "label == %@ OR label == %@", expected, "Audio Check Failed")
                let reached = expectation(for: predicate, evaluatedWith: phase)
                let result = XCTWaiter.wait(for: [reached], timeout: 15)
                let actual = phase.exists ? phase.label : "unknown"
                let passed = result == .completed && actual == expected
                let details = "phase=\(actual) buttonValue=\(button.exists ? (button.value ?? "unknown") : "unknown")"
                    + " status=\(status.exists ? status.label : "unknown")"
                    + " input=\(input.exists ? input.label : "unknown") \(input.exists ? (input.value ?? "") : "")"
                    + " output=\(output.exists ? output.label : "unknown") \(output.exists ? (output.value ?? "") : "")"
                    + " inputMeter=\(inputMeter.exists ? (inputMeter.value ?? "") : "unknown")"
                    + " outputMeter=\(outputMeter.exists ? (outputMeter.value ?? "") : "unknown")"
                    + (passed ? "" : "\n" + app.debugDescription)
                let attachment = XCTAttachment(string: details)
                attachment.name = "Audio Check cycle \(cycle) \(expected)"
                attachment.lifetime = .keepAlways
                add(attachment)
                XCTAssertTrue(passed, "Expected \(expected): \(details)")
            }
            if cycle == 1 { assertAudioCheckCanStop(button: button, phase: phase) }
        }
    }

    @MainActor
    private func monitorMicrophonePermission() -> any NSObjectProtocol {
        addUIInterruptionMonitor(withDescription: "Microphone access") { alert in
            let microphone = NSPredicate(format: "label CONTAINS[c] 'microphone'")
            guard alert.staticTexts.matching(microphone).firstMatch.exists else { return false }
            let hasOKButton = alert.buttons["OK"].firstMatch.exists
            let allow = hasOKButton ? alert.buttons["OK"].firstMatch : alert.buttons["Allow"].firstMatch
            guard allow.exists else { return false }
            allow.tap()
            return true
        }
    }

    @MainActor
    private func assertAudioCheckCanStop(button: XCUIElement, phase: XCUIElement) {
        button.tap()
        let recording = expectation(for: NSPredicate(format: "label == %@", "Recording"), evaluatedWith: phase)
        XCTAssertEqual(XCTWaiter.wait(for: [recording], timeout: 5), .completed)
        XCTAssertEqual(button.label, "Stop Audio Check")
        button.tap()
        let stopped = expectation(for: NSPredicate(format: "label == %@", "Audio Check Idle"),
                                  evaluatedWith: phase)
        XCTAssertEqual(XCTWaiter.wait(for: [stopped], timeout: 5), .completed)
        XCTAssertEqual(button.label, "Record 5s and Play")
        XCTAssertTrue(button.isEnabled)
    }

    @MainActor
    private func attachAudioCheckObservation(
        _ name: String,
        scroll: XCUIElement,
        candidates: [XCUIElement]
    ) {
        let names = ["button/identifier", "any/identifier", "button/label"]
        var observations = ["viewport=\(scroll.exists ? String(describing: scroll.frame) : "unknown")"]
        for (name, element) in zip(names, candidates) {
            if element.exists {
                observations.append(
                    "\(name): exists=true enabled=\(element.isEnabled) hittable=\(element.isHittable)"
                        + " frame=\(element.frame) label=\(element.label)"
                )
            } else {
                observations.append(
                    "\(name): exists=false enabled=unknown hittable=unknown frame=unknown label=unknown"
                )
            }
        }
        for identifier in ["audioCheckStatusLabel", "audioCheckPhaseLabel", "liveAudioStateLabel"] {
            let element = app.descendants(matching: .any)[identifier].firstMatch
            observations.append(
                element.exists ? "\(identifier): label=\(element.label) value=\(element.value ?? "unknown")"
                    : "\(identifier): unknown"
            )
        }
        let details = XCTAttachment(string: observations.joined(separator: "\n") + "\n" + app.debugDescription)
        details.name = name
        details.lifetime = .keepAlways
        add(details)
    }
    #endif

    #if os(iOS)
    @MainActor
    @objc(testAdvancedCallMasterVolumeTracksSliderMovement)
    func testAdvancedCallOutputVolumeTracksSliderMovement() {
        createTalkGroupAndOpenCall()
        let slider = app.sliders["masterOutputSlider"].firstMatch
        let level = app.staticTexts["outputStateLabel"].firstMatch
        for _ in 0..<4 where !slider.isHittable { app.swipeUp() }
        XCTAssertTrue(slider.waitForExistence(timeout: 3))
        XCTAssertTrue(slider.isHittable)
        XCTAssertEqual(level.label, "Output 100%")
        slider.adjust(toNormalizedSliderPosition: 0.75)
        let raised = level.label
        XCTAssertNotEqual(raised, "Output 100%")
        slider.adjust(toNormalizedSliderPosition: 0.25)
        let lowered = level.label
        func percent(_ label: String) -> Int? { Int(label.dropFirst("Output ".count).dropLast()) }
        XCTAssertGreaterThan(percent(raised) ?? 0, 100)
        XCTAssertLessThan(percent(lowered) ?? 200, 100)
        XCTAssertTrue(app.buttons["disconnectButton"].exists)
    }
    #endif
}
