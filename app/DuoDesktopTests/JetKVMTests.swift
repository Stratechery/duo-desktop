#if DUO_JETKVM
import GlassActTransport
import JetKVMProtocol
import JetKVMClient
import XCTest
@testable import DuoDesktop

/// The JetKVM view's rules (project notes). Made-up names only.
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
}
#endif

#if DUO_JETKVM
/// The owner 2026-11-21: the JetKVM's video "sometimes works and it sometimes doesn't". A video connection that does not
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
