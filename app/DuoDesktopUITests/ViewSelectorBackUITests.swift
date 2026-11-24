import XCTest

/// Project notes (view-selector-back). One test per view: it finds the views control and switches with it. a private
/// test script seeds one made-up computer, "Test Mac", with all three ways in: Screen Sharing at Glass Act's test host
/// on this Mac, a Terminal at a closed port, a JetKVM at a documentation address (nothing signs in to a real computer,
/// nothing reaches a JetKVM). The control is the session's own: the switch (`sessionView.<view>`) where it fits, else
/// its one-button menu form (`viewMenu`), as the session decides by width. Extra launch arguments come from DUO_VS_ARGS
/// (e.g. "--force-open-layout" on the folded Duo). The open Duo's width (669 pt) cannot be had headless: the simulator
/// cannot unfold, and an iPad runs this iPhone app in a phone-sized window.
@MainActor
final class ViewSelectorBackUITests: XCTestCase {
    private let app = XCUIApplication()
    private var env: [String: String] { ProcessInfo.processInfo.environment }

    override func setUp() async throws {
        continueAfterFailure = false
        guard env["DUO_VS_UI"] != nil else { throw XCTSkip("DUO_VS_UI not set") }
        XCUIDevice.shared.orientation = .portrait
    }

    private func launch(_ args: [String]) {
        app.launchArguments = ["--no-app-lock"] + args
            + (env["DUO_VS_ARGS"].map { $0.split(separator: " ").map(String.init) } ?? [])
        app.launchEnvironment["DUO_TEST_SIGNIN"] = "test:made-up-only"
        app.launch()
    }

    /// Waits for the views control; true when it is the switch, false when it is the menu form.
    private func control(_ what: String) -> Bool {
        let sw = app.buttons["sessionView.regular"], sw2 = app.buttons["sessionView.terminal"]
        let menu = app.buttons["viewMenu"]
        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if sw.exists || sw2.exists { return true }
            if menu.exists { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        shot("\(what)-no-control")
        XCTFail("\(what): no views control on the top bar")
        return false
    }

    /// Chooses `id` ("terminal") titled `title` ("Terminal") with the control, switch or menu.
    private func choose(_ id: String, _ title: String, isSwitch: Bool) {
        if isSwitch {
            app.buttons["sessionView.\(id)"].tap()
        } else {
            app.buttons["viewMenu"].tap()
            let item = app.buttons[title].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5), "menu item \(title)")
            item.tap()
        }
    }

    /// The control shows `id` chosen (within `timeout`).
    private func shows(_ id: String, _ title: String, timeout: TimeInterval = 20) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let sw = app.buttons["sessionView.\(id)"]
            if sw.exists, sw.isSelected { return true }
            let menu = app.buttons["viewMenu"]
            if menu.exists, (menu.value as? String) == title { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return false
    }

    private func shot(_ name: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let a = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
        a.name = name; a.lifetime = .keepAlways; add(a)
        if let dir = env["DUO_VS_SHOTS"] {
            try? png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("\(env["DUO_VS_LABEL"] ?? "run")-\(name).png"))
        }
    }

    /// (a) The Screen Sharing session: the control is there with the computer's views; Terminal is chosen with it.
    func testSessionHasTheControlAndSwitchesToTerminal() {
        launch(["--connect", "Test Mac"])
        let isSwitch = control("session")
        XCTAssertTrue(app.buttons["backToMacs"].firstMatch.exists, "back stays")
        shot("session")
        choose("terminal", "Terminal", isSwitch: isSwitch)
        XCTAssertTrue(shows("terminal", "Terminal"), "the session shows Terminal")
        shot("session-to-terminal")
    }

    /// (b) Terminal opened from the list's icon: the same control; JetKVM is chosen with it and its screen opens.
    func testTerminalHasTheControlAndSwitchesToJetKVM() {
        launch(["--open-computer", "Test Mac", "--open-way", "terminal"])
        let isSwitch = control("terminal")
        XCTAssertTrue(shows("terminal", "Terminal", timeout: 2), "Terminal is the chosen view")
        XCTAssertTrue(app.buttons["backToMacs"].firstMatch.exists, "back stays")
        XCTAssertTrue(app.descendants(matching: .any)["terminal"].exists, "the Terminal screen")
        shot("terminal")
        choose("jetkvm", "JetKVM", isSwitch: isSwitch)
        XCTAssertTrue(shows("jetkvm", "JetKVM"), "the JetKVM screen, its view chosen")
        XCTAssertFalse(app.descendants(matching: .any)["terminal"].exists, "the Terminal screen has gone")
        shot("terminal-to-jetkvm")
    }

    /// (c) JetKVM opened from the list's icon: the same control; the Mac's own screen is chosen with it, and the
    /// Screen Sharing session starts in that view (Whole Screen on the Duo; Follow Pointer, its only Mac view, on a
    /// normal iPhone).
    func testJetKVMHasTheControlAndSwitchesToScreenSharing() {
        launch(["--open-computer", "Test Mac", "--open-way", "jetkvm"])
        let isSwitch = control("jetkvm")
        XCTAssertTrue(shows("jetkvm", "JetKVM", timeout: 2), "JetKVM is the chosen view")
        XCTAssertTrue(app.buttons["backToMacs"].firstMatch.exists, "back stays")
        shot("jetkvm")
        let regular = isSwitch || app.buttons["viewMenu"].exists && phoneHasWholeScreen()
        if regular { choose("regular", "Whole Screen", isSwitch: isSwitch) } else { choose("centred", "Follow Pointer", isSwitch: isSwitch) }
        XCTAssertTrue(shows(regular ? "regular" : "centred", regular ? "Whole Screen" : "Follow Pointer", timeout: 30),
                      "the Screen Sharing session, in the chosen view")
        shot("jetkvm-to-screensharing")
    }

    /// The menu form offers Whole Screen (the Duo when narrow) or not (a normal iPhone, Follow Pointer only).
    private func phoneHasWholeScreen() -> Bool {
        app.buttons["viewMenu"].tap()
        let has = app.buttons["Whole Screen"].firstMatch.waitForExistence(timeout: 3)
        // Close the menu again without choosing.
        app.buttons["JetKVM"].firstMatch.tap()
        return has
    }
}
