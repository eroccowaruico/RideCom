//
//  RideIntercomUITestsLaunchTests.swift
//  RideIntercomUITests
//
//  Created by Naohito Sasao on 2026/04/18.
//

import XCTest

final class RideIntercomUITestsLaunchTests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-out"
        app.launch()
        app.activate()
        defer { app.terminate() }

        XCTAssertTrue(
            waitForVisibleRoot(in: app),
            "Expected the app to launch into a visible root screen"
        )
    }

    @MainActor
    func testValidationLaunchWithoutFixtureShowsInstructions() {
        let app = XCUIApplication()
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = ""
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = ""
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["validationLaunchInstructions"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["signInWithAppleButton"].exists)
    }

    private func waitForVisibleRoot(in app: XCUIApplication) -> Bool {
        app.buttons["signInWithAppleButton"].firstMatch.waitForExistence(timeout: 5)
    }
}
