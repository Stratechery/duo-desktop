import XCTest

/// Project notes (name-opens-default), tapped on the real list (a private test script seeds made-up computers at
/// documentation addresses where nothing answers, so nothing signs in anywhere):
///   "Default Test Mac"  Screen Sharing and Terminal, Opens In: Terminal
///   "Red Test PC"       Terminal only
/// Run: TEST_RUNNER_DUO_NOD_UI=1 xcodebuild … -only-testing:DuoDesktopUITests/NameOpensDefaultUITests test
@MainActor
final class NameOpensDefaultUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["DUO_NOD_UI"] != nil else { throw XCTSkip("DUO_NOD_UI not set") }
        XCUIDevice.shared.orientation = .portrait
        // On the folded Duo the open-screen list is forced (the outer screen's own list is on hold, unchanged).
        app.launchArguments = ["--no-app-lock", "--force-open-layout"]
        app.launch()
    }

    /// Claim 1: tapping the name opens the computer in its default way (here Terminal), with no Glass Act attempt.
    func test1NameOpensTheDefault() {
        let name = app.buttons["computerName.Default Test Mac"]
        XCTAssertTrue(name.waitForExistence(timeout: 10), "the row's name")
        name.tap()
        XCTAssertTrue(app.descendants(matching: .any)["terminal"].waitForExistence(timeout: 5), "the Terminal screen")
        XCTAssertFalse(app.buttons["Cancel"].exists, "no Glass Act connecting row")
    }

    /// Claim 1 and 2: the (i) opens the settings page, which has Opens In; choosing Screen Sharing there makes the
    /// name start Screen Sharing instead.
    func test2InfoOpensSettingsWithOpensIn() {
        let info = app.buttons["macSettings.Default Test Mac"]
        XCTAssertTrue(info.waitForExistence(timeout: 10), "the row's (i)")
        XCTAssertEqual(info.label, "Settings for Default Test Mac")
        info.tap()
        XCTAssertTrue(app.navigationBars["Default Test Mac"].waitForExistence(timeout: 5), "its settings page")
        let opensIn = app.buttons["settingsOpensIn"]
        XCTAssertTrue(opensIn.waitForExistence(timeout: 5), "Opens In")
        XCTAssertTrue(opensIn.label.contains("Terminal") || (opensIn.value as? String) == "Terminal",
                      "starts as Terminal: \(opensIn.label) / \(String(describing: opensIn.value))")
        opensIn.tap()
        let ss = app.buttons["Screen Sharing"].firstMatch
        XCTAssertTrue(ss.waitForExistence(timeout: 5), "Screen Sharing in the menu")
        ss.tap()
        app.buttons["BackButton"].firstMatch.tap()
        let name = app.buttons["computerName.Default Test Mac"]
        XCTAssertTrue(name.waitForExistence(timeout: 5), "back on the list")
        name.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5), "the Screen Sharing connecting row")
        app.buttons["Cancel"].tap()
        // Put Opens In back, so the other tests start from the seeded list.
        app.buttons["macSettings.Default Test Mac"].tap()
        XCTAssertTrue(opensIn.waitForExistence(timeout: 5))
        opensIn.tap()
        let terminal = app.buttons["Terminal"].firstMatch
        XCTAssertTrue(terminal.waitForExistence(timeout: 5))
        terminal.tap()
    }

    /// The light: a computer whose only way in does not answer shows red, labelled for VoiceOver; one whose Screen
    /// Sharing the simulator never checks stays gray ("not checked"), never red.
    func test3LightLabels() {
        let red = app.descendants(matching: .any)["light.Red Test PC"]
        XCTAssertTrue(red.waitForExistence(timeout: 10), "the light")
        let deadline = Date().addingTimeInterval(10)
        while red.label != "Not reachable", Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.5)) }
        XCTAssertEqual(red.label, "Not reachable")
        XCTAssertEqual(app.descendants(matching: .any)["light.Default Test Mac"].label, "Not checked yet")
    }
}
