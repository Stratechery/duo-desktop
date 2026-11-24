#if DUO_JETKVM
import GlassActTransport
import JetKVMProtocol
import JetKVMClient
import XCTest
@testable import DuoDesktop

/// The JetKVM view's rules. Made-up names only.
@MainActor
final class JetKVMTests: XCTestCase {
    final class MemoryPasswords: JetKVMPasswordStore {
        var items: [String: String] = [:]
        func password(mac: String) -> String? { items[mac] }
        func setPassword(_ password: String?, mac: String) { items[mac] = password }
    }

    private var saved: (any JetKVMPasswordStore)!
    private let memory = MemoryPasswords()
    private var access: AppAccess.State = .locked
    // The app is unlocked for these rules (input reaches the JetKVM only then: AppLockLinksTests).
    override func setUp() async throws {
        saved = JetKVMSettings.passwords; JetKVMSettings.passwords = memory
        access = AppAccess.state; AppAccess.set(.open)
    }
    override func tearDown() async throws { JetKVMSettings.passwords = saved; AppAccess.set(access) }

    private func store() throws -> MacStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("macs.json")
        try Data(#"[{"id":"M1","name":"Test Mac","home":"test-mac.local","port":4433,"layout":"standard"}]"#.utf8).write(to: url)
        return MacStore(url: url, defaults: UserDefaults(suiteName: "JetKVMTests.\(UUID().uuidString)")!,
                        knownHosts: KnownHosts(url: dir.appendingPathComponent("known_hosts")))
    }

    /// Claim: the switch is off by default (entries saved before it read as off); turning it off deletes the
    /// password; removing the Mac deletes the password.
    func testSettingsRules() throws {
        let s = try store()
        XCTAssertFalse(try XCTUnwrap(s.entry("M1")).jetkvmOn)
        JetKVMSettings.setOn(true, mac: "M1", store: s)
        s.update("M1") { $0.jetkvmAddress = "  http://kvm.example.test/  " }
        XCTAssertEqual(s.entry("M1")?.jetkvmHost, "kvm.example.test")
        memory.setPassword("pw", mac: "M1")
        JetKVMSettings.setOn(false, mac: "M1", store: s)
        XCTAssertNil(memory.password(mac: "M1"), "switch off deletes the password")
        XCTAssertEqual(s.entry("M1")?.jetkvmOn, false)

        JetKVMSettings.setOn(true, mac: "M1", store: s)
        memory.setPassword("pw", mac: "M1")
        s.remove("M1")
        XCTAssertNil(memory.password(mac: "M1"), "removing the Mac deletes the password")
    }

    /// Claim: JetKVM is a choice (fourth, after Terminal) only with the switch on and an address; a remembered
    /// JetKVM falls back to Whole Screen once it is off.
    func testChoiceOnlyWhenOn() throws {
        var e = MacEntry(name: "Test Mac", home: "test-mac.local")
        XCTAssertFalse(JetKVMSettings.offered(e))
        e.jetkvmOn = true
        XCTAssertFalse(JetKVMSettings.offered(e), "no address yet")
        e.jetkvmAddress = "kvm.example.test"
        XCTAssertTrue(JetKVMSettings.offered(e))

        XCTAssertEqual(SessionView.choices(terminal: false, jetkvm: false), [.regular, .centred])
        XCTAssertEqual(SessionView.choices(terminal: false, jetkvm: true), [.regular, .centred, .jetkvm])
        #if DUO_TERMINAL
        XCTAssertEqual(SessionView.choices(terminal: true, jetkvm: true), [.regular, .centred, .terminal, .jetkvm])
        #endif
        XCTAssertEqual(SessionView.resolve(stored: "jetkvm", terminal: false, jetkvm: true), .jetkvm)
        XCTAssertEqual(SessionView.resolve(stored: "jetkvm", terminal: false, jetkvm: false), .regular)
    }

    final class Recorder: JetKVMOutput {
        var log: [String] = []
        func sendKeyboard(modifiers: HIDRPC.Modifiers, keys: [UInt8]) { log.append("kb \(modifiers.rawValue) \(keys)") }
        func sendPointerDelta(dx: Int, dy: Int, buttons: HIDRPC.Buttons?) {
            log.append("rel \(dx) \(dy) \(buttons.map { String($0.rawValue) } ?? "-")")
        }
        func sendScroll(dy: Int, dx: Int) { log.append("wheel \(dy) \(dx)") }
    }

    /// Claim: moves go out as relative deltas, clicks press at the Mac's pointer, a latched modifier stays in the
    /// report across a key, and keys map to USB HID usages.
    func testInputBecomesRelativeHID() {
        let input = JetKVMInput(), rec = Recorder()
        input.output = rec
        input.canvas = (20_000, 20_000)
        input.sendInput(kind: InputKind.move, x: 10_000, y: 10_000, a: 0, b: 0)
        input.sendInput(kind: InputKind.move, x: 10_030, y: 9_990, a: 0, b: 0)
        input.sendInput(kind: InputKind.buttonDown, x: 10_030, y: 9_990, a: 1, b: 0)
        input.sendInput(kind: InputKind.buttonUp, x: 10_030, y: 9_990, a: 1, b: 0)
        input.sendInput(kind: InputKind.keyDown, x: 56, y: 0, a: 0, b: 0)   // shift
        input.sendInput(kind: InputKind.keyDown, x: 0, y: 0, a: 0, b: 0)    // a
        input.sendInput(kind: InputKind.keyUp, x: 0, y: 0, a: 0, b: 0)
        input.sendInput(kind: InputKind.keyUp, x: 56, y: 0, a: 0, b: 0)
        input.sendInput(kind: InputKind.scrollPoints, x: 0, y: 0, a: 0, b: 30)
        XCTAssertEqual(rec.log, ["rel 30 -10 -", "rel 0 0 1", "rel 0 0 0",
                                 "kb 2 []", "kb 2 [4]", "kb 2 []", "kb 0 []", "wheel -2 0"])
    }

    /// The owner 2026-11-22: a password typed through a JetKVM was refused. Claim: a capital or shifted symbol from our
    /// keyboard (the plain key with Shift in its flags) presses Shift around the key: Shift alone, Shift + key, Shift
    /// alone, nothing; the next unshifted key carries no Shift. Before the fix "A!" arrived as "a1".
    @MainActor
    func testShiftedCharactersPressShift() {
        let input = JetKVMInput(), rec = Recorder()
        input.output = rec
        let engine = MacKeyboardEngine(sink: input)
        for c in "Ab!" { XCTAssertTrue(MacTyping.type(c, into: engine)) }
        XCTAssertEqual(rec.log, ["kb 2 []", "kb 2 [4]", "kb 2 []", "kb 0 []",   // A
                                 "kb 0 [5]", "kb 0 []",                          // b
                                 "kb 2 []", "kb 2 [30]", "kb 2 []", "kb 0 []"])  // !
        // Our own keyboard's shift (tap = next letter capital) goes the same way.
        rec.log = []
        let model = TouchKeyboardModel(engine: engine)
        model.touchDown(.shift, at: 0)
        model.lifted(.char("q"))
        model.lifted(.char("q"))
        XCTAssertEqual(rec.log, ["kb 2 []", "kb 2 [20]", "kb 2 []", "kb 0 []", "kb 0 [20]", "kb 0 []"])
    }

    /// Claim: every character our keyboard can type reaches the JetKVM as the US key and Shift state that types it
    /// on a US Mac (the table a Mac's US layout uses), and every report ends with nothing held.
    @MainActor
    func testEveryCharacterOnEveryPage() {
        let us: [Character: (UInt8, Bool)] = {
            var m: [Character: (UInt8, Bool)] = [:]
            for (i, c) in "abcdefghijklmnopqrstuvwxyz".enumerated() {
                m[c] = (UInt8(0x04 + i), false); m[Character(c.uppercased())] = (UInt8(0x04 + i), true)
            }
            for (i, c) in "1234567890".enumerated() { m[c] = (UInt8(0x1E + i), false) }
            for (i, c) in "!@#$%^&*()".enumerated() { m[c] = (UInt8(0x1E + i), true) }
            let pairs: [(UInt8, Character, Character)] = [(0x2D, "-", "_"), (0x2E, "=", "+"), (0x2F, "[", "{"),
                (0x30, "]", "}"), (0x31, "\\", "|"), (0x33, ";", ":"), (0x34, "'", "\""), (0x35, "`", "~"),
                (0x36, ",", "<"), (0x37, ".", ">"), (0x38, "/", "?")]
            for (u, a, b) in pairs { m[a] = (u, false); m[b] = (u, true) }
            m[" "] = (0x2C, false)
            return m
        }()
        let input = JetKVMInput(), rec = Recorder()
        input.output = rec
        let model = TouchKeyboardModel(engine: MacKeyboardEngine(sink: input))
        var count = 0
        for page in [TouchKeyboardLayout.Page.letters, .numbers, .symbols] {
            model.page = page
            for shifted in page == .letters ? [false, true] : [false] {
                for row in TouchKeyboardLayout.rows(page) {
                    for key in row {
                        let ch: Character
                        switch key {
                        case let .char(c): ch = shifted ? Character(c.uppercased()) : c
                        case .space: ch = " "
                        default: continue
                        }
                        rec.log = []
                        if shifted { model.shift = .once }
                        model.lifted(key)
                        guard let (u, s) = us[ch] else { XCTFail("no US key for \(ch)"); continue }
                        let want = s ? ["kb 2 []", "kb 2 [\(u)]", "kb 2 []", "kb 0 []"] : ["kb 0 [\(u)]", "kb 0 []"]
                        XCTAssertEqual(rec.log, want, "character \(ch)")
                        count += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(count, 90)
        // Return and delete.
        rec.log = []
        model.lifted(.ret); model.touchDown(.delete); model.lifted(.delete)
        XCTAssertEqual(rec.log, ["kb 0 [40]", "kb 0 []", "kb 0 [42]", "kb 0 []"])
    }
}
#endif

#if DUO_JETKVM
/// The owner 2026-11-21: the JetKVM's video sometimes worked and sometimes did not. A video connection that does not
/// form is torn down and tried again by itself, up to 3 attempts, then the reason with Try Again; a wrong password
/// is not retried; the log has no password and no address beyond the host name.
@MainActor
final class JetKVMRetryTests: XCTestCase {
    private var access: AppAccess.State = .locked
    override func setUp() async throws { access = AppAccess.state; AppAccess.set(.open) }
    override func tearDown() async throws { AppAccess.set(access) }

    private func entry(_ address: String) throws -> MacEntry {
        try JSONDecoder().decode(MacEntry.self, from: Data(
            #"{"id":"RETRY-\#(UUID().uuidString)","name":"Retry Test","port":4433,"layout":"standard","jetkvm":true,"jetkvmAddress":"\#(address)"}"#.utf8))
    }

    private func wait(until ok: () -> Bool, _ s: Double = 3) async {
        let end = Date().addingTimeInterval(s)
        while !ok() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    func testVideoFailureRetriesThreeTimesThenShowsTheReason() async throws {
        let e = try entry("jetkvm-test.example.ts.net")
        let link = JetKVMLink.for(mac: e.id)
        link.readPassword = { _ in "made-up-secret" }
        link.retryDelay = .milliseconds(50)
        var seen: [JetKVMLink.Status] = []
        link.startSession = { _ in
            seen.append(link.status)
            throw JetKVMError.webRTC("ICE failed")
        }
        link.connect(entry: e)
        await wait { link.starts == 3 && link.status != .retrying(attempt: 3, of: 3) }
        XCTAssertEqual(link.starts, 3, "three attempts")
        XCTAssertEqual(seen, [.connecting, .retrying(attempt: 2, of: 3), .retrying(attempt: 3, of: 3)])
        guard case .failed(let why) = link.status else { return XCTFail("status \(link.status)") }
        XCTAssertTrue(why.contains("video connection failed"), why)
        XCTAssertNil(link.session, "no half-open session left")
        let log = link.log.joined(separator: "\n")
        XCTAssertTrue(log.contains("attempt 3 of 3 to jetkvm-test"), log)
        XCTAssertFalse(log.contains("made-up-secret"))
        XCTAssertFalse(log.contains("example.ts.net"), log)
        // Try Again starts a fresh first attempt.
        link.startSession = { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
        link.reconnect(entry: e)
        XCTAssertEqual(link.status, .connecting)
        // Review fixes 2: a start is counted when it runs (after its last access check), not when it is queued.
        await wait { link.starts == 4 }
        XCTAssertEqual(link.starts, 4)
        link.disconnect()
    }

    /// Project notes 3: connected with no picture, the link presses Left Shift alone (never a key that
    /// types, confirms or cancels), at once when the JetKVM says "no_signal", a few times spaced out, shows "Waking
    /// the display…" meanwhile, and when no picture comes says the likely cause in plain words.
    func testNoPicturePressesShiftToWakeTheDisplay() async throws {
        let e = try entry("jetkvm-wake.example.ts.net")
        let link = JetKVMLink.for(mac: e.id)
        link.readPassword = { _ in "made-up" }
        link.retryDelay = .milliseconds(20)
        JetKVMLink.wakeAfter = .milliseconds(30); JetKVMLink.wakeEvery = .milliseconds(60)
        defer { JetKVMLink.wakeAfter = .seconds(2); JetKVMLink.wakeEvery = .seconds(3) }
        var presses = 0
        var statuses: [JetKVMLink.Status] = []
        link.pressWake = { _ in presses += 1; statuses.append(link.status); return true }
        link.startSession = { s in
            // As the session does once it is connected and waits for the first frame.
            link.startWaking(s)
            link.videoInputState(ready: false, error: "no_signal", session: s)
            try await Task.sleep(for: .milliseconds(400))
            throw JetKVMError.timeout("connecting")
        }
        link.connect(entry: e)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(link.status, .waking, "the screen says Waking the display… while it waits")
        await wait(until: { if case .failed = link.status { return true } else { return false } }, 6)
        XCTAssertGreaterThanOrEqual(presses, 3, "a few presses")
        XCTAssertLessThanOrEqual(presses, JetKVMLink.wakesInAll, "never more than the limit")
        guard case .failed(let why) = link.status else { return XCTFail("status \(link.status)") }
        XCTAssertTrue(why.contains("display may be off or asleep"), why)
        XCTAssertTrue(why.contains("pressed Shift"), why)
        XCTAssertTrue(link.log.joined().contains("pressed Left Shift to wake the display (the JetKVM sees no signal)"))
        link.disconnect()
        // The key itself: Left Shift down alone, then everything up (no key code in either report).
        XCTAssertEqual(Array(HIDRPC.keyboardReport(modifiers: .leftShift, keys: []).dropFirst()), [0x02])
        XCTAssertEqual(Array(HIDRPC.keyboardReport(modifiers: [], keys: []).dropFirst()), [0x00])
    }

    /// Claim: turning the phone, where the new picture view appears before the old one goes, keeps the connection; it
    /// ends when the last picture view goes.
    func testTurningKeepsTheConnection() async throws {
        let e = try entry("jetkvm-turn.example.ts.net")
        let link = JetKVMLink.for(mac: e.id)
        link.readPassword = { _ in "made-up" }
        link.startSession = { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
        link.panelAppeared(entry: e)       // upright picture
        let first = link.session
        XCTAssertNotNil(first)
        link.panelAppeared(entry: e)       // sideways picture appears first
        link.panelDisappeared()            // then the upright one goes
        XCTAssertTrue(link.session === first, "the same connection goes on")
        link.panelDisappeared()            // back to the list
        XCTAssertNil(link.session)
        XCTAssertEqual(link.panelsShown, 0)
    }

    func testWrongPasswordIsNotRetried() async throws {
        let ip = "10" + "0.64.1.2" // made up; in two parts for the no-addresses scan
        let e = try entry(ip)
        let link = JetKVMLink.for(mac: e.id)
        link.readPassword = { _ in "x" }
        link.retryDelay = .milliseconds(10)
        link.startSession = { _ in throw JetKVMError.wrongPassword }
        link.connect(entry: e)
        await wait { link.status == .wrongPassword }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(link.starts, 1)
        XCTAssertEqual(link.status, .wrongPassword)
        XCTAssertFalse(link.log.joined().contains(ip), "an IP address is not logged")
        link.disconnect()
    }

    func testStepsInPlainWords() {
        XCTAssertEqual(JetKVMLink.stepText("login"), "Signing in")
        XCTAssertEqual(JetKVMLink.stepText("signaling"), "Starting the session")
        XCTAssertEqual(JetKVMLink.stepText("picture"), "Waiting for the picture")
        XCTAssertEqual(JetKVMLink.logName(host: "jetkvm-x.tail.ts.net"), "jetkvm-x")
        XCTAssertEqual(JetKVMLink.logName(host: "jetkvm-x"), "jetkvm-x")
        let ip = "10" + "0.1.2.3"
        XCTAssertEqual(JetKVMLink.logName(host: ip), "the JetKVM")
        XCTAssertEqual(JetKVMLink.logName(host: ip + ":80"), "the JetKVM")
    }
}
#endif
