import XCTest

/// Project notes item 4. On a real JetKVM (the test computer's own; only connect, picture and turning, no clicks and no
/// keys): open the JetKVM-only computer upright, wait for the picture, turn sideways, turn back. Screenshots at each
/// step go to DUO_SHOTS, taken on the Mac side (as `NormalPhoneMenuUITests`). The connection must not restart: the
/// run's log is checked on the Mac side for one "connecting, attempt 1" only. Run: tools/jetkvm-sideways-proof.sh <sim>
/// <prefix> [--force-open-layout]
@MainActor
final class JetKVMSidewaysUITests: XCTestCase {
    private var shots = ""
    private var prefix = ""

    override func setUp() async throws {
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["DUO_SHOTS"], env["DUO_KVM_SIDEWAYS"] != nil else { throw XCTSkip("DUO_KVM_SIDEWAYS not set") }
        shots = dir
        prefix = env["DUO_PREFIX"] ?? "S"
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() { XCUIDevice.shared.orientation = .portrait }

    private func shot(_ name: String) {
        let dir = URL(fileURLWithPath: shots)
        let png = dir.appendingPathComponent("\(prefix)-\(name).png")
        try? FileManager.default.removeItem(at: png)
        try? Data().write(to: dir.appendingPathComponent("\(prefix)-\(name).ready"))
        let deadline = Date().addingTimeInterval(15)
        while !FileManager.default.fileExists(atPath: png.path), Date() < deadline { usleep(200_000) }
    }

    /// No "Connecting…" / "Waiting…" / failure text over the picture.
    private func assertPicture(_ app: XCUIApplication, _ when: String) {
        for word in ["Connecting", "Waiting for the picture", "Could not connect", "Lost the connection", "Trying again"] {
            let p = NSPredicate(format: "label CONTAINS %@", word)
            XCTAssertFalse(app.staticTexts.matching(p).firstMatch.exists, "\(when): shows “\(word)”")
        }
    }

    func testTurningKeepsThePicture() {
        let app = XCUIApplication()
        let extra = ProcessInfo.processInfo.environment["DUO_EXTRA"].map { $0.split(separator: " ").map(String.init) } ?? []
        app.launchArguments = ["--no-app-lock", "--open-computer", "Agents Mini"] + extra
        app.launch()
        sleep(14)
        assertPicture(app, "upright")
        shot("1-upright")
        XCUIDevice.shared.orientation = .landscapeLeft
        sleep(6)
        let w = app.windows.firstMatch.frame
        XCTAssertGreaterThan(w.width, w.height, "the screen really turned (the folded Duo's outer screen does not)")
        assertPicture(app, "sideways")
        XCTAssertTrue(app.buttons["backToMacs"].firstMatch.exists, "sideways: the back control is there")
        shot("2-sideways")
        XCUIDevice.shared.orientation = .portrait
        sleep(6)
        assertPicture(app, "upright again")
        shot("3-upright-again")
    }
}
