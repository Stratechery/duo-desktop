import XCTest

/// Project notes (computers-m3), tapped on the real list (a private test script seeds two made-up computers at documentation
/// addresses where nothing answers, so nothing signs in anywhere):
///   "Gray Test Mac"   Screen Sharing only
///   "Both Test Mac"   Screen Sharing and Terminal
/// Run: TEST_RUNNER_DUO_M3_UI=1 xcodebuild … -only-testing:DuoDesktopUITests/ComputersM3UITests test
@MainActor
final class ComputersM3UITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["DUO_M3_UI"] != nil else { throw XCTSkip("DUO_M3_UI not set") }
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--no-app-lock"]
        app.launch()
    }

    /// Claim (1): a gray icon opens that way in's Add sheet for that computer.
    func testGrayIconOpensItsAddSheet() {
        let gray = app.buttons["way.terminal.Gray Test Mac"]
        XCTAssertTrue(gray.waitForExistence(timeout: 10), "the row's Terminal icon")
        XCTAssertEqual(gray.label, "Add Terminal to Gray Test Mac")
        gray.tap()
        XCTAssertTrue(app.navigationBars["Add Terminal"].waitForExistence(timeout: 5), "Add Terminal sheet")
    }

    /// Claim (2): the Terminal icon on a computer that has Screen Sharing opens its terminal with no Glass Act
    /// attempt; when it does not answer, the screen offers Screen Sharing instead.
    func testTerminalIconOpensTerminalWithNoGlassActAndOffersTheOthers() {
        let icon = app.buttons["way.terminal.Both Test Mac"]
        XCTAssertTrue(icon.waitForExistence(timeout: 10))
        XCTAssertEqual(icon.label, "Open Both Test Mac in Terminal")
        icon.tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminal"].waitForExistence(timeout: 5), "the Terminal screen")
        XCTAssertFalse(app.buttons["Cancel"].exists, "no Glass Act connecting row")
        XCTAssertTrue(app.buttons["openInstead.screenSharing"].waitForExistence(timeout: 15), "offers Screen Sharing")
        // Project notes (view-selector-back): the session's own views control (the switch, or its one-button menu form).
        XCTAssertTrue(app.buttons["sessionView.terminal"].exists || app.buttons["viewMenu"].exists,
                      "the views control (two ways in)")
    }

    /// Claim (2): while Screen Sharing is still trying, the list offers the computer's other way in, and choosing
    /// it ends the attempt and opens the terminal.
    func testScreenSharingWaitingOffersTerminal() {
        let icon = app.buttons["way.screenSharing.Both Test Mac"]
        XCTAssertTrue(icon.waitForExistence(timeout: 10))
        icon.tap()
        let instead = app.buttons["openInstead.terminal"]
        XCTAssertTrue(instead.waitForExistence(timeout: 10), "offered while connecting")
        instead.tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminal"].waitForExistence(timeout: 5), "the Terminal screen")
        app.buttons["backToMacs"].firstMatch.tap()
        XCTAssertTrue(app.buttons["way.terminal.Both Test Mac"].waitForExistence(timeout: 5), "back on the list")
        XCTAssertFalse(app.buttons["Cancel"].exists, "the Screen Sharing attempt was ended")
    }
}
