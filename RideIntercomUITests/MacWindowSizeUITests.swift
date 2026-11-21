#if os(macOS)
import XCTest

/// The Mac window stops shrinking where the sidebar, a list and the call column still fit side by side.
final class MacWindowSizeUITests: XCTestCase {
    private var app: XCUIApplication?

    override func setUpWithError() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        self.app = app
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        app.launchEnvironment["RIDEINTERCOM_LOCAL_TESTING"] = "1"
        app.launchEnvironment["RIDEINTERCOM_ACCOUNT_FIXTURE"] = "signed-in"
        app.launchEnvironment["RIDEINTERCOM_INTERFACE_FIXTURE"] = "standard"
        app.launch(); app.activate()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        app = nil
    }

    @MainActor func testWindowDoesNotShrinkBelowItsMinimum() {
        guard let app else { preconditionFailure("The app must be launched before checking the window") }
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(window.frame.width, 880)
        XCTAssertGreaterThanOrEqual(window.frame.height, 520)
        // Bring the whole window on screen by its title bar, then drag the bottom-right corner far up and left.
        let title = window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0)).withOffset(
            CGVector(dx: 0, dy: 12))
        title.click(
            forDuration: 0.3,
            thenDragTo: title.withOffset(CGVector(dx: -window.frame.minX + 40, dy: -window.frame.minY + 40)))
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(
            CGVector(dx: -2, dy: -2))
        corner.click(forDuration: 0.3, thenDragTo: corner.withOffset(CGVector(dx: -2000, dy: -2000)))
        // The minimum is the content's 880×520; the title bar and toolbar sit above it (about 52pt).
        XCTAssertEqual(window.frame.width, 880, accuracy: 1, "\(window.frame)")
        XCTAssertGreaterThan(window.frame.height, 520, "\(window.frame)")
        XCTAssertLessThan(window.frame.height, 600, "\(window.frame)")
        // Grow it back so the next launch restores an ordinary size.
        let shrunk = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(
            CGVector(dx: -2, dy: -2))
        shrunk.click(forDuration: 0.3, thenDragTo: shrunk.withOffset(CGVector(dx: 220, dy: 200)))
        XCTAssertGreaterThan(window.frame.width, 880)
        XCTAssertGreaterThan(window.frame.height, 600)
    }
}
#endif
