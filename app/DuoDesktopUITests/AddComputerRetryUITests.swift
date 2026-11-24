import XCTest

/// Project notes item 2. Adds a computer by JetKVM at an address where nothing answers (192.0.2.10, a documentation
/// address), waits for the check to fail, then reports the sheet's state, corrects the address in the same sheet and
/// tries again. Passes only when the fields stay editable, the button reads Try Again, and the list then has ONE
/// computer of that name. Run: TEST_RUNNER_DUO_ADD_RETRY=1 xcodebuild …
/// -only-testing:DuoDesktopUITests/AddComputerRetryUITests test
@MainActor
final class AddComputerRetryUITests: XCTestCase {
    override func setUp() async throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["DUO_ADD_RETRY"] != nil else { throw XCTSkip("DUO_ADD_RETRY not set") }
        XCUIDevice.shared.orientation = .portrait
    }

    func testFailedCheckCanBeCorrectedInPlace() {
        let name = "Retry \(Int(Date().timeIntervalSince1970) % 100000)"
        let app = XCUIApplication()
        app.launchArguments = ["--no-app-lock", "--add-computer", "jetkvm", "--add-fields", "\(name)|||192.0.2.10"]
        app.launch()

        let address = app.textFields["addJetKVMAddress"]
        XCTAssertTrue(address.waitForExistence(timeout: 15), "the sheet opened")
        app.buttons["addConfirm"].tap()
        let check = app.staticTexts["addCheck"]
        XCTAssertTrue(check.waitForExistence(timeout: 30), "the check reported")
        // The state the sheet is left in after a failed check.
        let state = "after the failed check: check=\"\(check.label)\" addressEnabled=\(address.isEnabled) "
            + "addButton=\(app.buttons["addConfirm"].exists ? app.buttons["addConfirm"].label : "gone") "
            + "doneButton=\(app.buttons["addDone"].exists) doneEnabled=\(app.buttons["addDone"].exists && app.buttons["addDone"].isEnabled)"
        print("ADD-RETRY STATE: \(state)")
        XCTContext.runActivity(named: state) { _ in }

        XCTAssertTrue(address.isEnabled, "the address can be corrected")
        let again = app.buttons["addConfirm"]
        XCTAssertTrue(again.exists, "a button to try again")
        XCTAssertEqual(again.label, "Try Again")

        // Correct the address and try again in the same sheet.
        address.tap()
        address.press(forDuration: 1.2)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        address.typeText(XCUIKeyboardKey.delete.rawValue)
        address.typeText("192.0.2.20")
        again.tap()
        let second = NSPredicate(format: "label CONTAINS %@", "192.0.2.20")
        XCTAssertTrue(app.staticTexts.matching(identifier: "addCheck").matching(second).firstMatch.waitForExistence(timeout: 30),
                      "the second check used the corrected address")
        app.buttons["addDone"].tap()

        // One computer of that name, not two.
        let rows = app.buttons.matching(identifier: "macSettings.\(name)")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10), "listed")
        XCTAssertEqual(rows.count, 1, "the corrected try updated the same computer")
        print("ADD-RETRY ROWS: \(rows.count)")
    }
}
