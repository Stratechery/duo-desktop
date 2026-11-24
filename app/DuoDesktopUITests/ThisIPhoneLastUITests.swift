import XCTest

/// On the Computers list, the "This iPhone" section comes after Keyboard Haptics, the last section on the screen. Run:
/// TEST_RUNNER_DUO_THIS_IPHONE_LAST=1 [TEST_RUNNER_DUO_SHOT=/path/to.png] xcodebuild …
///      -only-testing:DuoDesktopUITests/ThisIPhoneLastUITests test
@MainActor
final class ThisIPhoneLastUITests: XCTestCase {
    private let app = XCUIApplication()

    override func setUp() async throws {
        continueAfterFailure = false
        guard ProcessInfo.processInfo.environment["DUO_THIS_IPHONE_LAST"] != nil else {
            throw XCTSkip("DUO_THIS_IPHONE_LAST not set")
        }
        XCUIDevice.shared.orientation = .portrait
        // The folded Duo simulator (the only model this Mac runs) shows its outer-screen list; this switch shows the
        // open-screen list, the one a normal iPhone shows (the screen with the settings sections).
        app.launchArguments = ["--no-app-lock", "--force-open-layout"]
        app.launch()
    }

    func testThisIPhoneIsTheLastSection() throws {
        let haptics = app.descendants(matching: .any)["keyboardHaptics"].firstMatch
        let key = app.descendants(matching: .any)["viewerKey"].firstMatch
        XCTAssertTrue(app.navigationBars.firstMatch.waitForExistence(timeout: 15), "the Computers list\n\(app.debugDescription)")
        for _ in 0..<8 { app.swipeUp(velocity: .fast) }
        sleep(1)
        if let path = ProcessInfo.processInfo.environment["DUO_SHOT"] {
            try XCUIScreen.main.screenshot().pngRepresentation.write(to: URL(fileURLWithPath: path))
        }
        XCTAssertTrue(haptics.exists, "Keyboard Haptics\n\(app.debugDescription)")
        XCTAssertTrue(key.exists, "This iPhone's Key row")
        XCTAssertTrue(app.staticTexts["This iPhone"].exists, "the This iPhone header")
        XCTAssertGreaterThan(key.frame.minY, haptics.frame.maxY, "This iPhone comes after Keyboard Haptics")
        XCTAssertGreaterThan(app.staticTexts["This iPhone"].frame.minY, haptics.frame.maxY)
    }
}
