#if os(iOS)
import XCTest

final class BackgroundCallLifecycleUITests: XCTestCase {
    private enum InvitationOpening { case cold, foreground, background }

    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor func testStandardWaitingReturnsFromBackgroundWithoutLosingItsCall() throws { try waitingRoundTrip() }
    @MainActor func testAdvancedWaitingReturnsFromBackgroundWithoutLosingItsCall() throws {
        try waitingRoundTrip(advanced: true)
    }

    @MainActor func testStandardMutedWaitingKeepsAudioInBackground() throws { try waitingRoundTrip(muted: true) }
    @MainActor func testAdvancedMutedWaitingKeepsAudioInBackground() throws {
        try waitingRoundTrip(advanced: true, muted: true)
    }

    @MainActor func testExternalGroupInvitationOpensColdAndPersists() throws {
        try verifyExternalGroupInvitation(from: .cold)
    }

    @MainActor func testExternalGroupInvitationOpensInRunningAppAndPersists() throws {
        try verifyExternalGroupInvitation(from: .foreground)
    }

    @MainActor func testExternalGroupInvitationOpensFromBackgroundAndPersists() throws {
        try verifyExternalGroupInvitation(from: .background)
    }

    @MainActor func testSavedGroupStartsLocalAfterColdOfflineLaunch() throws {
        let app = XCUIApplication(); defer { app.terminate() }
        app.launchEnvironment = ["RIDEINTERCOM_LOCAL_TESTING": "1", "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in",
            "RIDEINTERCOM_INTERFACE_FIXTURE": "standard"]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        let peerGroup = ProcessInfo.processInfo.environment["RIDEINTERCOM_COLD_START_PEER_GROUP"]
        let name: String, groupID: String
        if let peerGroup {
            groupID = try XCTUnwrap(UUID(uuidString: peerGroup)).uuidString
            name = "Audio E2E"
            app.launch()
            FileHandle.standardOutput.write(Data("AUDIO_E2E_RECEIVER_WAITING_FOR_INVITE\n".utf8))
            confirmExternalApplicationOpen(timeout: 15)
        } else {
            let suffix = UUID().uuidString.prefix(8)
            name = "Offline " + suffix
            let invitation = try InvitationURLFixture.make(inviter: "offline-" + suffix, name: name)
            groupID = try XCTUnwrap(InvitationURLFixture.fields(from: invitation)["groupID"] as? String)
            app.open(invitation)
        }
        let end = app.buttons["standardEndCallButton"].firstMatch
        XCTAssertTrue(end.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[name].firstMatch.exists)
        end.tap()
        app.alerts.buttons["standardConfirmEndCallButton"].firstMatch.tap()
        XCTAssertTrue(end.waitForNonExistence(timeout: 5))

        relaunchWithSavedLocalOnlySettings(app)

        startSavedLocalGroup(in: app, groupID: groupID, name: name, end: end)
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Saved group awaiting riders after offline relaunch"; image.lifetime = .keepAlways; add(image)
        if peerGroup != nil {
            FileHandle.standardOutput.write(Data("AUDIO_E2E_RECEIVER_WAITING_AFTER_RESTART\n".utf8))
            XCTAssertTrue(app.staticTexts["In a call"].firstMatch.waitForExistence(timeout: 45))
            let joined = XCTAttachment(screenshot: app.screenshot())
            joined.name = "Rider joined the saved group after offline relaunch"
            joined.lifetime = .keepAlways
            add(joined)
            XCTAssertTrue(app.staticTexts["Waiting for others"].firstMatch.waitForExistence(timeout: 30))
        }
        end.tap()
        app.alerts.buttons["standardConfirmEndCallButton"].firstMatch.tap()
        XCTAssertTrue(end.waitForNonExistence(timeout: 5))
    }

    @MainActor private func startSavedLocalGroup(
        in app: XCUIApplication,
        groupID: String,
        name: String,
        end: XCUIElement
    ) {
        let groups = app.tabBars.buttons["Groups"]
        XCTAssertTrue(groups.waitForExistence(timeout: 5))
        groups.tap()
        XCTAssertFalse(end.exists, "Relaunch must wait for an explicit choice of group")
        let row = app.buttons["standardGroup-" + groupID].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        for _ in 0..<6 where !row.isHittable { app.collectionViews.firstMatch.swipeUp() }
        row.tap()
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts[name].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["Waiting for others"].firstMatch.waitForExistence(timeout: 5))
    }

    @MainActor private func relaunchWithSavedLocalOnlySettings(_ app: XCUIApplication) {
        openCommunication(in: app)
        let local = app.switches["localNetworkRouteToggle"].firstMatch
        let internet = app.switches["internetRouteToggle"].firstMatch
        XCTAssertTrue(local.waitForExistence(timeout: 5))
        if local.value as? String == "0" {
            local.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        if internet.value as? String == "1" {
            internet.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        }
        XCTAssertEqual(local.value as? String, "1")
        XCTAssertEqual(internet.value as? String, "0")

        app.terminate()
        XCTAssertEqual(app.state, .notRunning)
        app.launchEnvironment = ["RIDEINTERCOM_LOCAL_TESTING": "1", "RIDEINTERCOM_ACCOUNT_FIXTURE": "restored-offline",
            "RIDEINTERCOM_BACKGROUND_OBSERVATION": "1"]
        app.launch()
        openCommunication(in: app)
        XCTAssertEqual(local.value as? String, "1")
        XCTAssertEqual(internet.value as? String, "0")
    }

    @MainActor private func openCommunication(in app: XCUIApplication) {
        let settings = app.tabBars.buttons["Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        settings.tap()
        let link = app.buttons["communicationSettingsLink"].firstMatch
        for _ in 0..<8 where !link.isHittable { app.collectionViews.firstMatch.swipeUp() }
        XCTAssertTrue(link.isHittable)
        link.tap()
    }

    @MainActor func testStandardResumeWhileWaitingContinuesInBackground() throws {
        try waitingRoundTrip(resuming: true)
    }
    @MainActor func testAdvancedResumeWhileWaitingContinuesInBackground() throws {
        try waitingRoundTrip(advanced: true, resuming: true)
    }

    @MainActor func testStandardFirstMicrophonePermissionContinuesInBackground() throws {
        try waitingRoundTrip(firstPermission: true)
    }
    @MainActor func testAdvancedFirstMicrophonePermissionContinuesInBackground() throws {
        try waitingRoundTrip(advanced: true, firstPermission: true)
    }

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

    @MainActor private func waitingRoundTrip(
        advanced: Bool = false,
        muted: Bool = false,
        resuming: Bool = false,
        firstPermission: Bool = false
    ) throws {
        let app = XCUIApplication(); defer { app.terminate() }
        let waitsForInvitation = muted && !advanced
            && ProcessInfo.processInfo.environment["RIDEINTERCOM_WAIT_FOR_AUDIO_E2E_INVITATION"] == "1"
        if firstPermission { app.resetAuthorizationStatus(for: .microphone) }
        app.launchEnvironment = ["RIDEINTERCOM_LOCAL_TESTING": "1", "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in",
            "RIDEINTERCOM_INTERFACE_FIXTURE": advanced ? "advanced" : "standard",
            "RIDEINTERCOM_BACKGROUND_OBSERVATION": "1", "RIDEINTERCOM_BACKGROUND_MUTED": muted ? "1" : "0",
            "RIDEINTERCOM_BACKGROUND_RESUME": resuming ? "1" : "0",
            "RIDEINTERCOM_BACKGROUND_FIRST_PERMISSION": firstPermission ? "1" : "0"]
        #if targetEnvironment(simulator)
        if !waitsForInvitation { app.launchEnvironment["RIDEINTERCOM_BACKGROUND_WAITING_ASSERTIONS"] = "1" }
        #endif
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); app.activate()
        let name = try prepareWaitingCall(in: app, waitsForInvitation: waitsForInvitation)
        if firstPermission { allowFirstMicrophonePermission() }
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
        let backgrounded = app.wait(for: .runningBackground, timeout: 5)
            || app.wait(for: .runningBackgroundSuspended, timeout: 5)
        XCTAssertTrue(backgrounded, "State after Home: \(app.state.rawValue)")
        // This exercises a real app transition; Simulator does not prove physical iOS suspension.
        Thread.sleep(forTimeInterval: 35)
        app.activate()
        XCTAssertTrue(end.waitForExistence(timeout: 5))
        if resuming { XCTAssertFalse(app.buttons["resumeAudioButton"].firstMatch.exists) }
        XCTAssertTrue(app.staticTexts[name].firstMatch.exists)
        #if targetEnvironment(simulator)
        if !waitsForInvitation { try assertWaitingMeasurements(on: end) }
        #endif
        let image = XCTAttachment(screenshot: app.screenshot())
        image.name = "Waiting after background return"
        image.lifetime = .keepAlways
        add(image)
        end.tap()
        if !advanced { app.alerts.buttons["standardConfirmEndCallButton"].firstMatch.tap() }
        XCTAssertTrue(end.waitForNonExistence(timeout: 5))
    }

    @MainActor private func prepareWaitingCall(in app: XCUIApplication, waitsForInvitation: Bool) throws -> String {
        let name: String
        if waitsForInvitation {
            name = "Audio E2E"
            FileHandle.standardOutput.write(Data("AUDIO_E2E_RECEIVER_WAITING_FOR_INVITE\n".utf8))
            confirmExternalApplicationOpen(timeout: 10)
            XCTAssertTrue(app.buttons["standardEndCallButton"].firstMatch.waitForExistence(timeout: 45))
        } else {
            let groups = app.tabBars.buttons["Groups"]
            XCTAssertTrue(groups.waitForExistence(timeout: 5))
            groups.tap()
            app.buttons["standardCreateGroupButton"].tap()
            let field = app.textFields["savedUsersGroupNameField"]
            let original = try XCTUnwrap(field.value as? String)
            name = "Background " + UUID().uuidString.prefix(6)
            field.tap()
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count) + name + "\n")
            app.buttons["saveUserSelectionButton"].tap()
        }
        return name
    }

    @MainActor private func allowFirstMicrophonePermission() {
        let alert = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            .alerts["kTCCServiceMicrophone-alert"].firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 8), "A fresh microphone permission must present the OS prompt")
        let permission = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        permission.name = "First microphone permission"; permission.lifetime = .keepAlways; add(permission)
        let allow = alert.buttons["kTCCServiceMicrophone-allow-button"].firstMatch
        XCTAssertTrue(allow.exists); allow.tap()
    }

    @MainActor private func confirmExternalApplicationOpen(timeout: TimeInterval) {
        let open = XCUIApplication(bundleIdentifier: "com.apple.springboard").alerts.buttons
            .matching(NSPredicate(format: "label IN %@", ["Open", "開く"])).firstMatch
        if open.waitForExistence(timeout: timeout) { open.tap() }
    }
}

#if targetEnvironment(simulator)
private extension BackgroundCallLifecycleUITests {
    struct WaitingMeasurements: Decodable {
        let sampleCount: Int
        let span: TimeInterval
        let largestSampleGap: TimeInterval?
        let validSimulatorContext: Bool
        let sameCall: Bool
        let sameDeadline: Bool
        let deadlineUnexpired: Bool
        let audioRunningWithExpectedMute: Bool
        let waitingWithoutRemoteAudio: Bool
        let silentNativeOutput: Bool
    }

    @MainActor func assertWaitingMeasurements(on end: XCUIElement) throws {
        let valueIsReady = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value BEGINSWITH %@", "{"),
                                                     object: end)
        XCTAssertEqual(XCTWaiter.wait(for: [valueIsReady], timeout: 5), .completed,
                       "No background audio measurements returned")
        let value = try XCTUnwrap(end.value as? String)
        let report = try JSONDecoder().decode(WaitingMeasurements.self, from: Data(value.utf8))
        XCTAssertTrue(report.validSimulatorContext)
        XCTAssertGreaterThanOrEqual(report.sampleCount, 20)
        XCTAssertGreaterThanOrEqual(report.span, 29)
        XCTAssertLessThanOrEqual(try XCTUnwrap(report.largestSampleGap), 2.5)
        XCTAssertTrue(report.sameCall)
        XCTAssertTrue(report.sameDeadline)
        XCTAssertTrue(report.deadlineUnexpired)
        XCTAssertTrue(report.audioRunningWithExpectedMute)
        XCTAssertTrue(report.waitingWithoutRemoteAudio)
        XCTAssertTrue(report.silentNativeOutput)
    }
}
#endif

extension BackgroundCallLifecycleUITests {
    @MainActor
    @objc func testValidationLaunchStartsInvitedGroupWithMicrophoneMuted() throws {
        let app = XCUIApplication()
        defer { app.terminate() }
        let suffix = UUID().uuidString.prefix(8)
        let groupName = "Muted waiting " + suffix
        let invitation = try InvitationURLFixture.make(inviter: "muted-waiting-" + suffix, name: groupName)
        app.launchEnvironment = [
            "RIDEINTERCOM_LOCAL_TESTING": "1", "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in",
            "RIDEINTERCOM_INTERFACE_FIXTURE": "standard", "RIDEINTERCOM_BACKGROUND_OBSERVATION": "1",
            "RIDEINTERCOM_BACKGROUND_MUTED": "1", "RIDEINTERCOM_BACKGROUND_GROUP_INVITATION": invitation.absoluteString
        ]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch()

        XCTAssertTrue(app.buttons["standardEndCallButton"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts[groupName].firstMatch.exists)
        let mute = app.buttons["standardMuteButton"].firstMatch
        XCTAssertTrue(mute.waitForExistence(timeout: 5))
        XCTAssertEqual(mute.value as? String, "Muted")
    }
}
#endif
