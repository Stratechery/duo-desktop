import XCTest

/// M4 proof: the overview and the screen menu, screenshotted at each step. Needs a Host that lists screens; the
/// screenshots go to TEST_RUNNER_DUO_SHOTS.
/// - Fake four screens: `glassact-testhost --port 4533 --displays --sign-in-password duotest`, TEST_RUNNER_DUO_FAKE=1.
/// - a real Mac with two screens: TEST_RUNNER_DUO_REAL=<its name in the simulator's Mac list> (the simulator's key on
///   that Host's approved list). No Mac is named in the source.
@MainActor
final class MultiScreenUITests: XCTestCase {
    private var app: XCUIApplication!
    private var shots = ""

    override func setUp() async throws {
        continueAfterFailure = false
        guard let dir = ProcessInfo.processInfo.environment["DUO_SHOTS"] else { throw XCTSkip("DUO_SHOTS not set") }
        shots = dir
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() { app?.terminate() }

    private func launch(_ mac: String, signIn: Bool) {
        app = XCUIApplication()
        app.launchArguments = ["--no-app-lock", "--connect", mac]
        if signIn { app.launchEnvironment["DUO_TEST_SIGNIN"] = "test:duotest" }
        app.launch()
    }

    /// XCUIScreen shots of this simulator come back black, so the shot is taken on the Mac side: this writes
    /// `<name>.ready` and waits for a watcher (`xcrun simctl io <sim> screenshot`) to write `<name>.png`.
    private func shot(_ name: String) {
        let dir = URL(fileURLWithPath: shots)
        let png = dir.appendingPathComponent("\(name).png")
        try? FileManager.default.removeItem(at: png)
        try? Data().write(to: dir.appendingPathComponent("\(name).ready"))
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: png.path), Date() < deadline { usleep(200_000) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: png.path), "no screenshot for \(name)")
    }

    private var menu: XCUIElement { app.buttons["screenMenu"].firstMatch }

    /// A real Mac's screen names, as its Host lists them (TEST_RUNNER_DUO_REAL_SCREEN_1 = main, _2 = the other).
    private func realScreen(_ key: String) -> String {
        ProcessInfo.processInfo.environment[key] ?? (key.hasSuffix("1") ? "Main" : "Second")
    }

    private func pick(_ item: String) {
        menu.tap()
        let entry = app.buttons[item].firstMatch.exists ? app.buttons[item].firstMatch : app.switches[item].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 5), "menu item \(item)")
        entry.tap()
    }

    /// The menu's label names the Mac and the screen in use.
    private func waitForLabel(_ text: String, _ timeout: TimeInterval = 10) {
        let p = NSPredicate(format: "label CONTAINS %@", text)
        XCTAssertTrue(app.buttons.matching(identifier: "screenMenu").matching(p).firstMatch
            .waitForExistence(timeout: timeout), "menu label with \(text)")
    }

    func testFourFakeScreens() throws {
        guard ProcessInfo.processInfo.environment["DUO_FAKE"] != nil else { throw XCTSkip("DUO_FAKE not set") }
        launch("Test host", signIn: true)
        XCTAssertTrue(menu.waitForExistence(timeout: 30), "no screen menu: the Host's list did not arrive")
        // Opens on the screen last used with this Mac (Top, from the previous run), or Main the first time.
        waitForLabel("Top")
        sleep(2)
        shot("m4-fake-0-opened-on-remembered")
        pick("All Screens")
        XCTAssertTrue(app.buttons["screenTile.2"].waitForExistence(timeout: 5))
        sleep(2) // a refresh or two of the small pictures
        shot("m4-fake-1-overview")
        app.buttons["screenTile.2"].tap()
        waitForLabel("Left 16:10")
        XCTAssertFalse(app.buttons["screenTile.2"].exists, "overview still up after the answer")
        sleep(2)
        shot("m4-fake-2-screen2")
        pick("All Screens")
        XCTAssertTrue(app.buttons["screenTile.4"].waitForExistence(timeout: 5))
        sleep(2)
        shot("m4-fake-3-all-screens")
        pick("Top")
        waitForLabel("Top")
        sleep(2)
        shot("m4-fake-4-screen4-from-menu")
        menu.tap()
        sleep(1)
        shot("m4-fake-5-menu-open")
    }

    func testRealMacTwoScreens() throws {
        guard let real = ProcessInfo.processInfo.environment["DUO_REAL"], !real.isEmpty else { throw XCTSkip("DUO_REAL not set") }
        launch(real, signIn: false)
        XCTAssertTrue(menu.waitForExistence(timeout: 40), "no screen menu: the Host's list did not arrive")
        pick("All Screens")
        XCTAssertTrue(app.buttons["screenTile.2"].waitForExistence(timeout: 5))
        sleep(3)
        shot("m4-real-1-overview")
        app.buttons["screenTile.2"].tap()
        waitForLabel(realScreen("DUO_REAL_SCREEN_2"))
        sleep(3)
        shot("m4-real-2-second-screen")
        pick(realScreen("DUO_REAL_SCREEN_1"))
        waitForLabel(realScreen("DUO_REAL_SCREEN_1"))
        sleep(3)
        shot("m4-real-3-back-to-main")
    }

    /// my-mac, second screen: live (a pointer move between two shots), a trackpad move and a tap land on the
    /// second screen (the watcher logs the Mac's global pointer at each shot), then Follow Pointer on main.
    func testRealMacSecondScreenInputAndFollowPointer() throws {
        guard let real = ProcessInfo.processInfo.environment["DUO_REAL"], !real.isEmpty else { throw XCTSkip("DUO_REAL not set") }
        launch(real, signIn: false)
        XCTAssertTrue(menu.waitForExistence(timeout: 40), "no screen menu: the Host's list did not arrive")
        pick(realScreen("DUO_REAL_SCREEN_2"))
        waitForLabel(realScreen("DUO_REAL_SCREEN_2"))
        sleep(3)
        shot("m5-real-1-second-before")
        // Trackpad (blank area, bottom left): a one-finger drag moves the pointer, no click.
        let pad = app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.60))
        pad.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.62)))
        sleep(3)
        shot("m5-real-2-second-after-trackpad-move")
        // A tap on blank board space right of the last list line: picture (0.75, 0.6) = Mac (3360, 648).
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.3233)).tap()
        sleep(3)
        shot("m5-real-3-second-after-tap")
        pick(realScreen("DUO_REAL_SCREEN_1"))
        waitForLabel(realScreen("DUO_REAL_SCREEN_1"))
        sleep(2)
        // Control: the same trackpad move on main.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.15, dy: 0.60))
            .press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.62)))
        sleep(2)
        shot("m5-real-3b-main-after-trackpad-move")
        app.buttons["sessionView.centred"].firstMatch.tap()
        sleep(3)
        shot("m5-real-4-main-follow-pointer")
        app.buttons["sessionView.regular"].firstMatch.tap()
        sleep(1)
    }

    /// The pinch steps, fake four screens, upright. First settles whether the simulator's synthetic touches reach the
    /// picture: a tap must show up in the test host's log (DUO_HOST_LOG). Then: pinch out (Whole Screen -> Follow
    /// Pointer), pinch in (-> Whole Screen), pinch in (-> All Screens).
    func testPinchLadderFakeScreens() throws {
        guard ProcessInfo.processInfo.environment["DUO_FAKE"] != nil else { throw XCTSkip("DUO_FAKE not set") }
        guard let logPath = ProcessInfo.processInfo.environment["DUO_HOST_LOG"] else { throw XCTSkip("DUO_HOST_LOG") }
        let log = HostLog(path: logPath)
        launch("Test host", signIn: true)
        XCTAssertTrue(menu.waitForExistence(timeout: 30), "no screen menu: the Host's list did not arrive")
        let regular = app.buttons["sessionView.regular"].firstMatch
        let centred = app.buttons["sessionView.centred"].firstMatch
        if !regular.isSelected { regular.tap() }
        sleep(2)
        let picture = app.otherElements["Mac screen"].firstMatch
        XCTAssertTrue(picture.waitForExistence(timeout: 10), "no Mac picture")
        log.markNow()
        picture.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        let tap = log.wait { $0.contains { $0.contains("left up") } }
        print("DUO-UI tap on picture:\n" + tap.joined(separator: "\n"))
        XCTAssertTrue(tap.contains { $0.contains("left down") }, "the simulator's tap did not reach the picture")
        shot("pinch-0-whole-screen")
        picture.pinch(withScale: 2.0, velocity: 1.0)
        sleep(2)
        XCTAssertTrue(centred.isSelected, "pinch out on Whole Screen did not go to Follow Pointer")
        shot("pinch-1-out-to-follow-pointer")
        picture.pinch(withScale: 0.5, velocity: -1.0)
        sleep(2)
        XCTAssertTrue(regular.isSelected, "pinch in on Follow Pointer did not go to Whole Screen")
        XCTAssertFalse(app.buttons["screenTile.2"].exists, "one pinch took two steps")
        shot("pinch-2-in-to-whole-screen")
        picture.pinch(withScale: 0.5, velocity: -1.0)
        XCTAssertTrue(app.buttons["screenTile.2"].waitForExistence(timeout: 5), "pinch in did not open All Screens")
        sleep(2)
        shot("pinch-3-in-to-all-screens")
        app.buttons["screenTile.1"].tap()
        waitForLabel("Main")
        sleep(2)
        shot("pinch-4-tapped-main")
    }

    /// M5 (plan item 13), fake four screens, upright, Whole Screen: trackpad pushes right off Main stop at the edge
    /// (the 40-point gap to Portrait is a wall); pushes left off Main cross onto "Left 16:10" at the same height
    /// (the test host logs where it placed the pointer), the label and the name change.
    func testEdgeCrossingFakeScreens() throws {
        guard ProcessInfo.processInfo.environment["DUO_FAKE"] != nil else { throw XCTSkip("DUO_FAKE not set") }
        guard let logPath = ProcessInfo.processInfo.environment["DUO_HOST_LOG"] else { throw XCTSkip("DUO_HOST_LOG") }
        let log = HostLog(path: logPath)
        // The simulator's synthetic drags never reach the trackpad here, so `--edge-demo` drives the real trackpad
        // engine: from 6 s, 20 moves right (into Main's right wall), 3 s pause, then 30 moves left.
        app = XCUIApplication()
        app.launchArguments = ["--no-app-lock", "--connect", "Test host", "--edge-demo"]
        app.launchEnvironment["DUO_TEST_SIGNIN"] = "test:duotest"
        app.launch()
        XCTAssertTrue(menu.waitForExistence(timeout: 30), "no screen menu: the Host's list did not arrive")
        XCTAssertTrue(app.buttons["sessionView.regular"].firstMatch.isSelected,
                      "the open screen did not start in Whole Screen")
        waitForLabel("Main")
        shot("edge-0-main")
        sleep(6)   // the right pushes are done: still Main, pointer at the right edge (the gap to Portrait)
        waitForLabel("Main")
        shot("edge-1-right-wall-still-main")
        waitForLabel("Left 16:10", 15)
        shot("edge-2-crossed-to-left")
        let placed = log.all().filter { $0.contains("screen → 2") }
        print("DUO-UI crossing:\n" + placed.joined(separator: "\n"))
        XCTAssertTrue(placed.contains { $0.contains("pointer placed at -1,") }, "not placed just inside Left's right edge")
        sleep(3)
        shot("edge-3-left-after-label")
    }
}
