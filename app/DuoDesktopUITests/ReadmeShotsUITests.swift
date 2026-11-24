import XCTest

/// README pictures that need a finger: a SwiftUI menu cannot be opened from code. tools/readme-shots.sh seeds the
/// made-up list (Studio Mac = Glass Act's test host on this Mac; Office PC = a made-up PC shown by `--rdp-demo`,
/// nothing connects) and runs one test per picture with DUO_README_UI set. Each test leaves its picture, the whole
/// screen at full resolution, at DUO_README_SHOTS/<name>.png. Nothing is typed or sent.
@MainActor
final class ReadmeShotsUITests: XCTestCase {
    private let app = XCUIApplication()
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() async throws {
        continueAfterFailure = false
        guard env["DUO_README_UI"] != nil else { throw XCTSkip("DUO_README_UI not set") }
    }

    private func launch(_ args: [String]) {
        app.launchArguments = ["--no-app-lock", "-trackpadSide", "right"] + args
        app.launchEnvironment["DUO_TEST_SIGNIN"] = "test:made-up-only"
        app.launch()
    }

    private func shot(_ name: String) {
        // The open Duo has two screens and XCUIScreen.main can be the dark outside one: keep the larger picture.
        let png = XCUIScreen.screens.map { $0.screenshot() }
            .max { $0.image.size.width * $0.image.size.height < $1.image.size.width * $1.image.size.height }!
            .pngRepresentation
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = env["DUO_README_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(name).png"))
        }
    }

    /// The top bar on a normal iPhone, a Mac session, with the views drop-down open.
    func testViewsMenuOpen() {
        launch(["--connect", "Studio Mac", "--choose-screen", "1"])
        let menu = app.buttons["viewMenu"]
        XCTAssertTrue(menu.waitForExistence(timeout: 25), "the views drop-down button")
        sleep(6)   // the picture arrives and the screen is chosen
        menu.tap()
        XCTAssertTrue(app.buttons["Follow Pointer"].firstMatch.waitForExistence(timeout: 5), "the menu is open")
        sleep(1)
        shot("views-menu")
    }

    /// The Windows key band with Ctrl Alt Del's choice open (touch and hold).
    func testCtrlAltDelChoice() {
        launch(["--rdp-demo", "--open-computer", "Office PC", "--open-way", "screenSharing"])
        let key = app.buttons["ctrlAltDel"].firstMatch
        XCTAssertTrue(key.waitForExistence(timeout: 25), "the Ctrl Alt Del key")
        sleep(3)
        key.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Send Ctrl Alt End"].firstMatch.waitForExistence(timeout: 5), "the choice is open")
        sleep(1)
        shot("ctrl-alt-del")
    }
}
