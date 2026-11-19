#if os(iOS)
import XCTest

final class BackgroundCallLifecycleUITests: XCTestCase {
    private enum InvitationOpening { case cold, foreground, background }

    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor func testStandardWaitingReturnsFromBackgroundWithoutLosingItsCall() throws { try waitingRoundTrip() }
    @MainActor func testAdvancedWaitingReturnsFromBackgroundWithoutLosingItsCall() throws { try waitingRoundTrip(advanced: true) }

    @MainActor func testStandardMutedWaitingKeepsAudioInBackground() throws { try waitingRoundTrip(muted: true) }
    @MainActor func testAdvancedMutedWaitingKeepsAudioInBackground() throws { try waitingRoundTrip(advanced: true, muted: true) }

    @MainActor func testExternalGroupInvitationOpensColdAndPersists() throws {
        try verifyExternalGroupInvitation(from: .cold)
    }

    @MainActor func testExternalGroupInvitationOpensInRunningAppAndPersists() throws {
        try verifyExternalGroupInvitation(from: .foreground)
    }

    @MainActor func testExternalGroupInvitationOpensFromBackgroundAndPersists() throws {
        try verifyExternalGroupInvitation(from: .background)
    }

    @MainActor func testStandardResumeWhileWaitingContinuesInBackground() throws { try waitingRoundTrip(resuming: true) }
    @MainActor func testAdvancedResumeWhileWaitingContinuesInBackground() throws { try waitingRoundTrip(advanced: true, resuming: true) }

    @MainActor func testStandardFirstMicrophonePermissionContinuesInBackground() throws { try waitingRoundTrip(firstPermission: true) }
    @MainActor func testAdvancedFirstMicrophonePermissionContinuesInBackground() throws { try waitingRoundTrip(advanced: true, firstPermission: true) }

    @MainActor private func verifyExternalGroupInvitation(from opening: InvitationOpening) throws {
        let app = XCUIApplication(); defer { app.terminate() }
        app.launchEnvironment = ["RIDEINTERCOM_LOCAL_TESTING": "1", "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in",
            "RIDEINTERCOM_INTERFACE_FIXTURE": "standard"]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        let suffix = UUID().uuidString.prefix(8)
        let name = "External " + suffix
        let invitation = try InvitationURLFixture.make(inviter: "external-" + suffix, name: name)
        switch opening {
        case .cold:
            app.terminate()
            XCTAssertEqual(app.state, .notRunning)
            app.open(invitation)
        case .foreground, .background:
            app.launch()
            XCTAssertTrue(app.tabBars.buttons["Users"].waitForExistence(timeout: 5))
            if opening == .background {
                XCUIDevice.shared.press(.home)
                XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5)
                    || app.wait(for: .runningBackgroundSuspended, timeout: 5))
            }
            XCUIDevice.shared.system.open(invitation)
            confirmExternalApplicationOpen(timeout: 3)
        }
        let end = app.buttons["standardEndCallButton"].firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[name].firstMatch.exists)
        end.tap()
        app.alerts.buttons["standardConfirmEndCallButton"].firstMatch.tap()
        XCTAssertTrue(end.waitForNonExistence(timeout: 5))
        app.terminate()
        app.launch()
        app.tabBars.buttons["Groups"].tap()
        let row = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label CONTAINS %@",
                                                   "standardGroup-", name)).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    @MainActor private func waitingRoundTrip(advanced: Bool = false, muted: Bool = false, resuming: Bool = false, firstPermission: Bool = false) throws {
        let app = XCUIApplication(); defer { app.terminate() }
        if firstPermission { app.resetAuthorizationStatus(for: .microphone) }
        app.launchEnvironment = ["RIDEINTERCOM_LOCAL_TESTING": "1", "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in",
            "RIDEINTERCOM_INTERFACE_FIXTURE": advanced ? "advanced" : "standard",
            "RIDEINTERCOM_BACKGROUND_OBSERVATION": "1", "RIDEINTERCOM_BACKGROUND_MUTED": muted ? "1" : "0",
            "RIDEINTERCOM_BACKGROUND_RESUME": resuming ? "1" : "0",
            "RIDEINTERCOM_BACKGROUND_FIRST_PERMISSION": firstPermission ? "1" : "0"]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); app.activate()
        let waitsForInvitation = muted && !advanced
            && ProcessInfo.processInfo.environment["RIDEINTERCOM_WAIT_FOR_AUDIO_E2E_INVITATION"] == "1"
        let name: String
        if waitsForInvitation {
            name = "Audio E2E"
            FileHandle.standardOutput.write(Data("AUDIO_E2E_RECEIVER_WAITING_FOR_INVITE\n".utf8))
            confirmExternalApplicationOpen(timeout: 10)
            XCTAssertTrue(app.buttons["standardEndCallButton"].firstMatch.waitForExistence(timeout: 45))
        } else {
            let groups = app.tabBars.buttons["Groups"]; XCTAssertTrue(groups.waitForExistence(timeout: 5)); groups.tap()
            app.buttons["standardCreateGroupButton"].tap()
            let field = app.textFields["savedUsersGroupNameField"]
            let original = try XCTUnwrap(field.value as? String)
            name = "Background " + UUID().uuidString.prefix(6)
            field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count) + name + "\n")
            app.buttons["saveUserSelectionButton"].tap()
        }
        if firstPermission {
            let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts["kTCCServiceMicrophone-alert"].firstMatch
            XCTAssertTrue(alert.waitForExistence(timeout: 8), "A fresh microphone permission must present the OS prompt")
            let permission = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            permission.name = "First microphone permission"; permission.lifetime = .keepAlways; add(permission)
            let allow = alert.buttons["kTCCServiceMicrophone-allow-button"].firstMatch
            XCTAssertTrue(allow.exists); allow.tap()
        }
        if muted {
            let mute = app.buttons[advanced ? "localMicrophoneMuteButton" : "standardMuteButton"].firstMatch
            XCTAssertTrue(mute.waitForExistence(timeout: 5)); mute.tap()
        }
        if resuming {
            let resume = app.buttons["resumeAudioButton"].firstMatch
            XCTAssertTrue(resume.waitForExistence(timeout: 5))
            XCTAssertTrue(resume.isEnabled)
            if advanced { XCTAssertEqual(app.staticTexts["callPresenceLabel"].firstMatch.label, "Audio paused") }
            resume.tap()
        }
        // No foreground wait for audio readiness or peer arrival after the operation.
        XCUIDevice.shared.press(.home)
        let end = app.buttons[advanced ? "disconnectButton" : "standardEndCallButton"].firstMatch
        let backgrounded = app.wait(for: .runningBackground, timeout: 5) || app.wait(for: .runningBackgroundSuspended, timeout: 5)
        XCTAssertTrue(backgrounded, "State after Home: \(app.state.rawValue)")
        // This exercises a real app transition; Simulator does not prove physical iOS suspension.
        Thread.sleep(forTimeInterval: 35)
        app.activate()
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        if resuming { XCTAssertFalse(app.buttons["resumeAudioButton"].firstMatch.exists) }
        XCTAssertTrue(app.staticTexts[name].firstMatch.exists)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "Waiting after background return"; image.lifetime = .keepAlways; add(image)
        end.tap()
        if !advanced { app.alerts.buttons["standardConfirmEndCallButton"].firstMatch.tap() }
        XCTAssertTrue(end.waitForNonExistence(timeout: 5))
    }

    @MainActor private func confirmExternalApplicationOpen(timeout: TimeInterval) {
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons
            .matching(NSPredicate(format: "label IN %@", ["Open", "開く"])).firstMatch
        if open.waitForExistence(timeout: timeout) { open.tap() }
    }
}
#endif
