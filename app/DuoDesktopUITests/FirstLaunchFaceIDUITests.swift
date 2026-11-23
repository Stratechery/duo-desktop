import notify
import XCTest

/// First-launch Face ID fix (project notes): the app lock's first minute on a Face ID iPhone, driven through the
/// system's own Face ID alerts. The simulator's Face ID is worked from here with the simulator's BiometricKit
/// notifications (posted from inside the simulator, where this runner lives): enrolled, matching face, non-matching
/// face. Run by a private picture script on a fresh install; skipped unless DUO_FACEID_RUN is set. Pictures
/// go to DUO_SHOTS as <device prefix>-<scenario>-<step>.png.
@MainActor
final class FirstLaunchFaceIDUITests: XCTestCase {
    private var app: XCUIApplication!
    private let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    private var shots = ""
    private var prefix = ""

    override func setUp() async throws {
        continueAfterFailure = false
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["DUO_SHOTS"], env["DUO_FACEID_RUN"] != nil else { throw XCTSkip("DUO_FACEID_RUN not set") }
        shots = dir
        prefix = env["DUO_PREFIX"] ?? "F"
        XCUIDevice.shared.orientation = .portrait
        post("com.apple.BiometricKit.enrollmentChanged", state: 1)
    }

    override func tearDown() { app?.terminate() }

    // MARK: Helpers

    private func post(_ name: String, state: UInt64? = nil) {
        if let state {
            var token: Int32 = 0
            notify_register_check(name, &token)
            notify_set_state(token, state)
            notify_cancel(token)
        }
        notify_post(name)
    }
    private func matchFace() { post("com.apple.BiometricKit_Sim.pearl.match") }
    private func wrongFace() { post("com.apple.BiometricKit_Sim.pearl.nomatch") }

    private func shot(_ scenario: String, _ step: String) {
        let png = XCUIScreen.main.screenshot().pngRepresentation
        let url = URL(fileURLWithPath: shots).appendingPathComponent("\(prefix)-\(scenario)-\(step).png")
        try? png.write(to: url)
    }

    private func launch(_ scenario: String, _ args: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = args
        app.launch()
        XCTAssertTrue(app.staticTexts["Duo Desktop is Locked"].waitForExistence(timeout: 15), "\(scenario): no lock screen")
    }

    private var unlockButton: XCUIElement { app.buttons["unlockButton"].firstMatch }
    private var lockedTitle: XCUIElement { app.staticTexts["Duo Desktop is Locked"] }

    /// The Mac list shows: unlocked.
    private func waitUnlocked(_ what: String) {
        let gone = NSPredicate(format: "exists == false")
        expectation(for: gone, evaluatedWith: lockedTitle)
        waitForExpectations(timeout: 10)
        XCTAssertFalse(lockedTitle.exists, what)
    }

    /// The system's Face ID prompt (the scanning badge, or an alert of it) is NOT up, for `seconds`.
    private func noPromptFor(_ seconds: Double, _ what: String) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            XCTAssertFalse(springboard.buttons["Try Face ID Again"].exists, "\(what): a new Face ID prompt came up")
            usleep(250_000)
        }
    }

    // MARK: Scenarios

    /// First launch, the face matches: the app opens to its own lock screen, the system asks, it unlocks once.
    func testMatch() {
        launch("match")
        sleep(2)
        shot("match", "1-asking")
        matchFace()
        waitUnlocked("match: still locked after a matching face")
        sleep(1)
        shot("match", "2-unlocked")
    }

    /// The face does not match and the person taps Cancel: the lock screen stays, says so, offers the button, and the
    /// app does NOT ask again by itself (it used to: Cancel brings the app back to the front, and coming back while
    /// locked started a new request, so Cancel could never be chosen).
    func testCancel() {
        launch("cancel")
        sleep(2)
        wrongFace()
        let cancel = springboard.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancel.waitForExistence(timeout: 10), "cancel: no Face Not Recognized alert")
        shot("cancel", "1-not-recognized")
        cancel.tap()
        sleep(2)
        shot("cancel", "2-after-cancel")
        noPromptFor(4, "cancel")
        XCTAssertTrue(lockedTitle.exists, "cancel: lock screen gone")
        XCTAssertTrue(unlockButton.isEnabled, "cancel: the Unlock button stays dimmed (an unlock still pending)")
        // The button still works.
        unlockButton.tap()
        sleep(2)
        matchFace()
        waitUnlocked("cancel: the button did not unlock")
        shot("cancel", "3-unlocked-by-button")
    }

    /// The app goes to the background while the system prompt is up, then comes back: one prompt, no pile-up, and it
    /// unlocks with a matching face.
    func testBackgroundWhileAsking() {
        launch("background")
        sleep(2)
        shot("background", "1-asking")
        XCUIDevice.shared.press(.home)
        sleep(2)
        shot("background", "2-home")
        app.activate()
        XCTAssertTrue(lockedTitle.waitForExistence(timeout: 10), "background: no lock screen on return")
        sleep(2)
        shot("background", "3-back")
        matchFace()
        waitUnlocked("background: still locked after a matching face")
        shot("background", "4-unlocked")
    }

    /// Face ID refused for the app ("Don't Allow", which the simulator cannot ask): the lock screen says so, offers
    /// Settings, and unlocks with the passcode. Picture only (`--biometry-denied`, `--lock-no-prompt`).
    func testRefusedPicture() {
        launch("refused", ["--biometry-denied", "--lock-no-prompt", "--unlock-method", "passcode"])
        XCTAssertTrue(app.staticTexts["biometryRefused"].waitForExistence(timeout: 5), "refused: not said")
        XCTAssertTrue(app.buttons["Open Settings"].exists)
        sleep(1)
        shot("refused", "1-lock-screen")
    }
}
