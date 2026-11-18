#if os(iOS)
import XCTest

final class BackgroundCallLifecycleUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor func testStandardWaitingReturnsFromBackgroundWithoutLosingItsCall() throws { try waitingRoundTrip() }
    @MainActor func testAdvancedWaitingReturnsFromBackgroundWithoutLosingItsCall() throws { try waitingRoundTrip(advanced: true) }

    @MainActor func testStandardMutedWaitingKeepsAudioInBackground() throws { try waitingRoundTrip(muted: true) }
    @MainActor func testAdvancedMutedWaitingKeepsAudioInBackground() throws { try waitingRoundTrip(advanced: true, muted: true) }

    @MainActor private func waitingRoundTrip(advanced: Bool = false, muted: Bool = false) throws {
        let app = XCUIApplication(); defer { app.terminate() }
        app.launchEnvironment = ["RIDEINTERCOM_LOCAL_TESTING": "1", "RIDEINTERCOM_ACCOUNT_FIXTURE": "signed-in",
            "RIDEINTERCOM_INTERFACE_FIXTURE": advanced ? "advanced" : "standard",
            "RIDEINTERCOM_BACKGROUND_OBSERVATION": "1", "RIDEINTERCOM_BACKGROUND_MUTED": muted ? "1" : "0"]
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launch(); app.activate()
        let groups = app.tabBars.buttons["Groups"]; XCTAssertTrue(groups.waitForExistence(timeout: 5)); groups.tap()
        app.buttons["standardCreateGroupButton"].tap()
        let field = app.textFields["savedUsersGroupNameField"]
        let original = try XCTUnwrap(field.value as? String), name = "Background " + UUID().uuidString.prefix(6)
        field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: original.count) + name + "\n")
        app.buttons["saveUserSelectionButton"].tap()
        if muted {
            let mute = app.buttons[advanced ? "localMicrophoneMuteButton" : "standardMuteButton"].firstMatch
            XCTAssertTrue(mute.waitForExistence(timeout: 5)); mute.tap()
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
        XCTAssertTrue(app.staticTexts[name].firstMatch.exists)
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = "Waiting after background return"; image.lifetime = .keepAlways; add(image)
        end.tap()
        if !advanced { app.alerts.buttons["standardConfirmEndCallButton"].firstMatch.tap() }
        XCTAssertTrue(end.waitForNonExistence(timeout: 5))
    }
}
#endif
