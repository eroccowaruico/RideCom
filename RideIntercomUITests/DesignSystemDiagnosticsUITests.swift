#if os(iOS)
import XCTest

@MainActor
final class DesignSystemDiagnosticsUITests: XCTestCase {
    func testDiagnosticsPagesAreSegmentsAtTheStandardTextSize() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-in"
        app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = "advanced"
        app.launch()
        defer { app.terminate() }
        app.openDiagnosticsTab()
        let picker = app.segmentedControls["diagnosticsPagePicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3), app.debugDescription)
        // Every page is visible at once, without opening a menu.
        for page in ["Overview", "TX", "RX", "Network", "Applied"] {
            XCTAssertTrue(picker.buttons[page].isHittable, page)
        }
        XCTAssertTrue(picker.buttons["Overview"].isSelected)
        verifyOverviewUsesPagePicker(in: app)
        let flow = app.descendants(matching: .any)["diagnosticsStageDots-TX"].firstMatch
        XCTAssertTrue(flow.waitForExistence(timeout: 3))
        let txLabel = flow.label
        guard let input = txLabel.range(of: "Input "), let vadStage = txLabel.range(of: "VAD "),
              let bus = txLabel.range(of: "TX Bus ") else {
            return XCTFail("The transmit flow must include Input, VAD and TX Bus. \(txLabel)")
        }
        XCTAssertLessThan(input.lowerBound, vadStage.lowerBound)
        XCTAssertLessThan(vadStage.lowerBound, bus.lowerBound)
        attachScreen("Diagnostics pages as segments")
        picker.buttons["Network"].tap()
        XCTAssertTrue(
            app.descendants(matching: .any)["diagnosticsNetworkPaths"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(picker.buttons["Network"].isSelected)
        verifyIdleTransmitPage(in: app, picker: picker)
        verifyIdleReceivePage(in: app, picker: picker)
        picker.buttons["Applied"].tap()
        let call = app.staticTexts["Call"].firstMatch
        let invite = app.staticTexts["Invite"].firstMatch
        reveal(invite, app: app)
        XCTAssertTrue(call.exists)
        XCTAssertLessThan(call.frame.minY, invite.frame.minY)
    }

    private func verifyIdleTransmitPage(in app: XCUIApplication, picker: XCUIElement) {
        picker.buttons["TX"].tap()
        let vad = app.descendants(matching: .any)["pipeline-vad-step"].firstMatch
        XCTAssertTrue(vad.waitForExistence(timeout: 3), app.debugDescription)
        let bus = app.descendants(matching: .any)["pipeline-mixer-step"].firstMatch
        XCTAssertTrue((bus.value as? String)?.contains("Voice Isolation On · Not measured") == true)
        vad.tap()
        XCTAssertTrue(
            app.staticTexts["Microphone input before TX Bus Effects."].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Input level: Not measured"].firstMatch.exists)
        attachScreen("TX diagnostics before microphone analysis")
        let codec = app.descendants(matching: .any)["pipeline-codec-step"].firstMatch
        reveal(codec, app: app)
        XCTAssertEqual(codec.value as? String, "Idle, Not available")
        let rtc = app.descendants(matching: .any)["pipeline-rtc-step"].firstMatch
        reveal(rtc, app: app)
        rtc.tap()
        let local = app.descendants(matching: .any)["pipeline-rtc-route-multipeer"].firstMatch
        XCTAssertTrue(local.waitForExistence(timeout: 3), app.debugDescription)
        reveal(local, app: app)
        XCTAssertEqual(local.value as? String, "Idle, No audio dispatch observed")
        XCTAssertTrue(app.descendants(matching: .any)["pipeline-rtc-route-webRTC"].firstMatch.exists)
        attachScreen("TX diagnostics route branches before a call")
    }

    private func verifyIdleReceivePage(in app: XCUIApplication, picker: XCUIElement) {
        picker.buttons["RX"].tap()
        let receipt = app.descendants(matching: .any)["receive-pipeline-rtc-step"].firstMatch
        let decode = app.descendants(matching: .any)["receive-pipeline-codec-step"].firstMatch
        XCTAssertTrue(receipt.waitForExistence(timeout: 3))
        XCTAssertTrue(decode.exists)
        XCTAssertLessThan(receipt.frame.minY, decode.frame.minY)
        XCTAssertEqual(receipt.value as? String, "Idle, Media Idle")
        XCTAssertEqual(decode.value as? String, "Idle, Not available")
        let mix = app.descendants(matching: .any)["receive-pipeline-mix-step"].firstMatch
        reveal(mix, app: app)
        XCTAssertEqual(mix.value as? String, "Idle, Not available")
        XCTAssertTrue(app.staticTexts["No participants"].firstMatch.exists)
        let receiveMix = app.descendants(matching: .any)["receive-pipeline-master-bus-step-summary"].firstMatch
        reveal(receiveMix, app: app)
        XCTAssertTrue((receiveMix.value as? String)?.contains("Voice Isolation Off · Not measured") == true)
        attachScreen("RX diagnostics before a call")
        let output = app.descendants(matching: .any)["receive-pipeline-output-step"].firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 3))
        reveal(output, app: app)
        XCTAssertEqual(output.value as? String, "Idle, Not available")
        output.tap()
        let details = app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH %@", "Buffered: ")).firstMatch
        XCTAssertTrue(details.waitForExistence(timeout: 3))
    }

    func testDiagnosticsMenuAtAccessibilitySizeInLandscape() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-in"
        app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = "advanced"
        app.launch()
        addTeardownBlock { [weak self] in
            guard app.state == .runningForeground else { return }
            self?.attachScreen("Diagnostics landscape picker teardown")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Diagnostics landscape picker teardown AX"
            hierarchy.lifetime = .keepAlways
            self?.add(hierarchy)
        }
        let tab = app.tabBars.buttons["Diagnostics"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 8)); tab.tap()
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in app.frame.width > app.frame.height }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
        let picker = app.descendants(matching: .any)["diagnosticsPagePicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        choose("Applied", in: picker, app: app, capture: true)
        XCTAssertTrue(
            app.descendants(matching: .any)["diagnosticsAppliedCodec"].firstMatch.waitForExistence(timeout: 3))
        choose("Overview", in: picker, app: app, capture: true)
        verifyOverviewUsesPagePicker(in: app)
        XCTAssertFalse(
            app.descendants(matching: .any)["diagnosticsOverviewGrid"].firstMatch.exists,
            "The summary cards are retired")
        choose("Applied", in: picker, app: app, capture: true)
        XCTAssertTrue(
            app.descendants(matching: .any)["diagnosticsAppliedCodec"].firstMatch.waitForExistence(timeout: 3))
        XCUIDevice.shared.orientation = .portrait
        app.terminate()
    }

    func testTXShowsLiveIsolationWithEffectsClosed() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-in"
        app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = "advanced"
        app.launch()
        defer { app.terminate() }

        let groups = app.tabBars.buttons["Groups"].firstMatch
        XCTAssertTrue(groups.waitForExistence(timeout: 8))
        groups.tap()
        let create = app.buttons["standardCreateGroupButton"].firstMatch
        XCTAssertTrue(create.waitForExistence(timeout: 3))
        create.tap()
        let name = app.textFields["savedUsersGroupNameField"].firstMatch
        XCTAssertTrue(name.waitForExistence(timeout: 3))
        name.tap()
        name.typeText("TX Diagnostics")
        app.buttons["saveUserSelectionButton"].firstMatch.tap()
        let close = app.buttons["closeCallButton"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 8))
        app.closeCallIfOpen()

        let diagnostics = app.tabBars.buttons["Diagnostics"].firstMatch
        XCTAssertTrue(diagnostics.waitForExistence(timeout: 3))
        diagnostics.tap()
        let picker = app.segmentedControls["diagnosticsPagePicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        choose("TX", in: picker, app: app)
        let vad = app.descendants(matching: .any)["pipeline-vad-step"].firstMatch
        let bus = app.descendants(matching: .any)["pipeline-mixer-step"].firstMatch
        let active = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value CONTAINS %@", "Voice Isolation On · active"), object: bus)
        XCTAssertEqual(XCTWaiter.wait(for: [active], timeout: 15), .completed, app.debugDescription)
        XCTAssertLessThan(vad.frame.minY, bus.frame.minY)
        XCTAssertFalse(app.descendants(matching: .any)["pipeline-effects-step"].firstMatch.exists)
        attachScreen("VAD and TX Bus isolation with effects closed")
    }
}

extension DesignSystemDiagnosticsUITests {
    @objc
    func testDiagnosticsPagesPreserveExistingValuesAndActionsAcrossRotation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US",
                               "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-in"
        app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = "advanced"
        app.launch()
        defer {
            attachScreen("Diagnostics final state")
            XCUIDevice.shared.orientation = .portrait
            app.terminate()
        }
        let tab = app.tabBars.buttons["Diagnostics"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 8)); tab.tap()
        let picker = app.descendants(matching: .any)["diagnosticsPagePicker"].firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        verifyOverviewUsesPagePicker(in: app)
        XCTAssertFalse(
            app.descendants(matching: .any)["diagnosticsOverviewGrid"].firstMatch.exists,
            "The summary cards are retired")
        // Every stage of each direction on one wrapping line of state dots, then one row per participant.
        for direction in ["TX", "RX"] {
            let dots = app.descendants(matching: .any)["diagnosticsStageDots-\(direction)"].firstMatch
            XCTAssertTrue(dots.waitForExistence(timeout: 3))
            XCTAssertTrue(dots.label.hasPrefix("\(direction): "), dots.label)
        }
        XCTAssertTrue(app.descendants(matching: .any)["diagnosticsStageDots-TX"].firstMatch.label.contains("Session"))
        XCTAssertTrue(app.descendants(matching: .any)["diagnosticsOverviewParticipants"].firstMatch.exists)
        attachScreen("Diagnostics overview with stage dots")

        choose("TX", in: picker, app: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["liveTransmitPipelineView"].firstMatch.waitForExistence(timeout: 3))
        XCTAssertTrue(app.descendants(matching: .any)["pipeline-session-step"].firstMatch.exists)
        attachScreen("Diagnostics TX AX5 portrait")
        choose("RX", in: picker, app: app)
        XCTAssertTrue(
            app.descendants(matching: .any)["liveReceivePipelineView"].firstMatch.waitForExistence(timeout: 3))
        verifyNetworkValuesAcrossRotation(in: app, picker: picker)
        verifyAppliedValuesAndRemedies(in: app, picker: picker)
    }

    private func verifyNetworkValuesAcrossRotation(in app: XCUIApplication, picker: XCUIElement) {
        choose("Network", in: picker, app: app)
        let network = app.staticTexts["networkDiagnosticsSummary"].firstMatch
        XCTAssertTrue(network.waitForExistence(timeout: 3))
        let networkValue = network.label
        let localRoute = app.descendants(matching: .any)["diagnosticsNetworkLocal"].firstMatch
        let internetRoute = app.descendants(matching: .any)["diagnosticsNetworkInternet"].firstMatch
        reveal(localRoute, app: app)
        reveal(internetRoute, app: app)
        reveal(app.descendants(matching: .any)["diagnosticsNetworkPaths"].firstMatch, app: app)
        XCTAssertFalse(networkValue.isEmpty)
        XCUIDevice.shared.orientation = .landscapeLeft
        let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            app.frame.width > app.frame.height
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [rotated], timeout: 5), .completed)
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        XCTAssertTrue(network.waitForExistence(timeout: 3))
        XCTAssertEqual(network.label, networkValue, "Rotation must preserve the current diagnostic input")
        attachScreen("Diagnostics Network AX5 landscape")
    }

    private func verifyAppliedValuesAndRemedies(in app: XCUIApplication, picker: XCUIElement) {
        choose("Applied", in: picker, app: app)
        let codec = app.descendants(matching: .any)["diagnosticsAppliedCodec"].firstMatch
        XCTAssertTrue(codec.waitForExistence(timeout: 3))
        // One row: the label, the value, and the implementation's verdict.
        XCTAssertTrue(codec.label.hasPrefix("Codec"), codec.label)
        XCTAssertTrue(codec.label.contains("Same") || codec.label.contains("Differs"), codec.label)
        let vad = app.descendants(matching: .any)["diagnosticsAppliedVAD"].firstMatch
        reveal(vad, app: app)
        XCTAssertTrue(vad.label.contains("Not measured"), vad.label)
        let status = app.staticTexts["internetServiceCheckStatus"].firstMatch
        reveal(status, app: app)
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        let before = status.label
        let check = app.buttons["checkInternetService"].firstMatch
        reveal(check, app: app)
        XCTAssertTrue(check.exists)
        XCTAssertFalse(check.isEnabled, "Without credentials the existing service check remains disabled")
        choose("Overview", in: picker, app: app)
        verifyOverviewUsesPagePicker(in: app)
        choose("Applied", in: picker, app: app)
        reveal(status, app: app)
        XCTAssertTrue(status.waitForExistence(timeout: 3))
        XCTAssertEqual(status.label, before)
    }

    private func verifyOverviewUsesPagePicker(in app: XCUIApplication) {
        XCTAssertTrue(
            app.descendants(matching: .any)["diagnosticsStageDots-RX"].firstMatch.waitForExistence(timeout: 3))
        for label in [
            "Others can't hear me", "I can't hear someone", "Audio drops out", "Audio is delayed"
        ] {
            XCTAssertFalse(app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch.exists, label)
        }
    }
}

extension DesignSystemDiagnosticsUITests {
    private func choose(_ title: String, in picker: XCUIElement, app: XCUIApplication, capture: Bool = false) {
        XCTAssertTrue(picker.isHittable, picker.debugDescription)
        if capture { attachScreen("Diagnostics picker before \(title)") }
        if picker.buttons[title].exists { picker.buttons[title].tap(); return }
        picker.tap()
        if capture {
            attachScreen("Diagnostics picker choices for \(title)")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "Diagnostics picker choices AX \(title)"
            hierarchy.lifetime = .keepAlways
            add(hierarchy)
        }
        let choice = app.buttons[title].firstMatch
        let selection = app.descendants(matching: .any)["diagnosticsPageSelection"].firstMatch
        if selection.waitForExistence(timeout: 2) {
            for _ in 0..<8 where !choice.isHittable { selection.swipeUp() }
        }
        XCTAssertTrue(choice.waitForExistence(timeout: 3), app.debugDescription)
        for _ in 0..<5 where !choice.isHittable {
            let visible = ["Overview", "TX", "RX", "Network", "Applied"]
                .map { app.buttons[$0].firstMatch }
                .first { $0.exists && $0.isHittable && app.frame.intersection($0.frame).height > 30 }
            guard let visible else { XCTFail("No visible menu item: \(app.debugDescription)"); return }
            visible.swipeUp()
        }
        XCTAssertTrue(choice.isHittable, "Menu choice is outside the viewport: \(choice.debugDescription)")
        choice.tap()
    }

    private func attachScreen(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func reveal(_ target: XCUIElement, app: XCUIApplication) {
        let scroll = app.descendants(matching: .any)["diagnosticsScrollView"].firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 3))
        let frame = scroll.frame.intersection(app.frame)
        let picker = app.descendants(matching: .any)["diagnosticsPagePicker"].firstMatch
        let tabBar = app.tabBars.firstMatch
        let top = max(frame.minY, picker.frame.maxY) + 8
        let bottom = min(frame.maxY, tabBar.exists ? tabBar.frame.minY : frame.maxY) - 8
        XCTAssertGreaterThan(bottom - top, 20, app.debugDescription)
        let origin = app.coordinate(withNormalizedOffset: .zero)
        let lower = origin.withOffset(
            CGVector(dx: frame.midX - app.frame.minX, dy: top + (bottom - top) * 0.75 - app.frame.minY))
        let upper = origin.withOffset(
            CGVector(dx: frame.midX - app.frame.minX, dy: top + (bottom - top) * 0.25 - app.frame.minY))
        for _ in 0..<20 where !target.isHittable {
            lower.press(forDuration: 0.05, thenDragTo: upper)
            XCTAssertTrue(picker.exists, "Scrolling must remain on Diagnostics")
        }
        for _ in 0..<20 where !target.isHittable {
            upper.press(forDuration: 0.05, thenDragTo: lower)
            XCTAssertTrue(picker.exists, "Scrolling must remain on Diagnostics")
        }
        XCTAssertTrue(target.isHittable, target.debugDescription)
    }
}
#endif
