import XCTest

/// normal iPhone view menu (change) proof: on a normal iPhone the one view button opens the menu of views;
/// each choice is made through it. Run by `tools/normal-phone-shots.sh ... menu` (made-up Macs, the test host); the
/// screenshots go to TEST_RUNNER_DUO_SHOTS, taken on the Mac side as in `MultiScreenUITests`.
@MainActor
final class NormalPhoneMenuUITests: XCTestCase {
    private var app: XCUIApplication!
    private var shots = ""
    private var prefix = ""

    override func setUp() async throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["DUO_SHOTS"], env["DUO_NORMAL_MENU"] != nil else { throw XCTSkip("DUO_NORMAL_MENU not set") }
        shots = dir
        prefix = env["DUO_PREFIX"] ?? "M"
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() { app?.terminate() }

    private func shot(_ name: String) {
        let dir = URL(fileURLWithPath: shots)
        let png = dir.appendingPathComponent("\(prefix)-\(name).png")
        try? FileManager.default.removeItem(at: png)
        try? Data().write(to: dir.appendingPathComponent("\(prefix)-\(name).ready"))
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: png.path), Date() < deadline { usleep(200_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path), "no screenshot for \(name)")
    }

    private var button: XCUIElement { app.buttons["viewMenu"].firstMatch }

    private func choose(_ title: String, shotName: String) {
        button.tap()
        let item = app.buttons[title].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "menu item \(title)")
        item.tap()
        let p = NSPredicate(format: "value == %@", title)
        XCTAssertTrue(app.buttons.matching(identifier: "viewMenu").matching(p).firstMatch.waitForExistence(timeout: 5),
                      "button shows \(title)")
        sleep(4)
        shot(shotName)
    }

    func testViewMenu() {
        app = XCUIApplication()
        app.launchArguments = ["--no-app-lock", "--connect", "Studio Mac", "--choose-screen", "1"]
        app.launchEnvironment["DUO_TEST_SIGNIN"] = "test:made-up-only"
        app.launch()
        XCTAssertTrue(button.waitForExistence(timeout: 30), "no view button")
        sleep(6)
        button.tap()
        for title in ["Follow Pointer", "Terminal", "JetKVM"] {
            XCTAssertTrue(app.buttons[title].firstMatch.waitForExistence(timeout: 5), "menu lists \(title)")
        }
        XCTAssertFalse(app.buttons["Whole Screen"].exists)
        sleep(1)
        shot("menu-open")
        // Close it without choosing (tap the same button again would reopen: tap outside, on the top of the picture).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3)).tap()
        sleep(1)
        choose("Terminal", shotName: "chose-terminal")
        button.tap(); sleep(1); shot("menu-open-terminal")
        app.buttons["JetKVM"].firstMatch.tap()
        sleep(4); shot("chose-jetkvm")
        choose("Follow Pointer", shotName: "chose-follow")
    }
}
