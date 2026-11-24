import XCTest

/// The call is not a tab: it opens over the lists as a sheet (iPhone) or a column (iPad, Mac).
extension XCUIApplication {
    func openDiagnosticsTab() {
        closeCallIfOpen()
        let picker = descendants(matching: .any)["diagnosticsPagePicker"].firstMatch
        if picker.exists { return }
        let tab = tabBars.buttons["Diagnostics"].firstMatch
        let sidebarRadio = radioButtons["diagnosticsTab"].firstMatch
        let sidebarButton = buttons["diagnosticsTab"].firstMatch
        if tab.exists {
            tab.tap()
        } else if sidebarRadio.exists {
            sidebarRadio.tap()
        } else if sidebarButton.exists {
            sidebarButton.tap()
        } else {
            buttons["Diagnostics"].firstMatch.tap()
        }
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
    }

    /// The tab bar sits under the call sheet on iPhone, so close the call before switching tabs.
    func closeCallIfOpen() {
        let close = buttons["closeCallButton"].firstMatch
        guard close.exists, close.isHittable else { return }
        close.tap()
        _ = close.waitForNonExistence(timeout: 3)
    }

    /// Reopens the current call from the accessory above the tab bar (a toolbar button on Mac),
    /// or Advanced's Current Call row.
    func openCurrentCall() {
        if buttons["closeCallButton"].firstMatch.exists { return }
        let accessory = buttons["callAccessoryOpenButton"].firstMatch
        if accessory.waitForExistence(timeout: 3) { accessory.tap(); return }
        let current = buttons["standardCurrentCallButton"].firstMatch
        if current.waitForExistence(timeout: 3) { current.tap() }
    }

    /// Advanced: opens the call's More menu and returns one item. Standard has no menu: its settings
    /// button sits in the toolbar and Invite Members under the members, so the item is returned directly.
    @discardableResult
    func openCallMoreMenuItem(_ identifier: String) -> XCUIElement {
        let menu = buttons["callMoreMenu"].firstMatch
        if menu.waitForExistence(timeout: 2) { menu.tap() }
        let item = buttons[identifier].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 3), item.debugDescription)
        return item
    }

    /// A list row's Delete asks first; confirm it.
    func confirmDestinationDelete() {
        let confirm = alerts.firstMatch.buttons["confirmDeleteDestinationButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "Deleting a row asks first")
        confirm.tap()
    }

    /// An owner deletes from the shared swipe; a joined member leaves through settings.
    /// Both operations ask first and remove the group from this device.
    func removeGroupRow(_ row: XCUIElement) {
        let target = buttons[row.identifier].firstMatch
        let list = descendants(matching: .any)["standardGroupsList"].firstMatch
        let window = windows.firstMatch.frame
        // Rows beneath the call accessory/tab bar can still report isHittable. Bring the
        // whole row into the list's clear area so a swipe cannot switch the tab instead.
        let top = window.minY + 120
        let bottom = window.maxY - 170
        for _ in 0..<20 {
            if target.exists, target.isHittable, target.frame.minY >= top, target.frame.maxY <= bottom { break }
            if target.exists, target.frame.minY < top { list.swipeDown() } else { list.swipeUp() }
        }
        XCTAssertTrue(target.exists && target.isHittable)
        XCTAssertGreaterThanOrEqual(target.frame.minY, top)
        XCTAssertLessThanOrEqual(target.frame.maxY, bottom)
        target.swipeLeft()
        let delete = buttons["Delete"].firstMatch
        let settings = buttons["Group Settings"].firstMatch
        XCTAssertTrue(delete.waitForExistence(timeout: 3) || settings.exists, "The swipe shows an action")
        if delete.exists {
            delete.tap()
            confirmDestinationDelete()
            return
        }
        settings.tap()
        let leaveGroup = buttons["leaveGroupButton"].firstMatch
        XCTAssertTrue(leaveGroup.waitForExistence(timeout: 3))
        leaveGroup.tap()
        let confirm = alerts.firstMatch.buttons["confirmLeaveGroupButton"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 3), "Leaving a group asks first")
        confirm.tap()
    }
}
