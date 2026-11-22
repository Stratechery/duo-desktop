#if DUO_TERMINAL
import GlassActTransport
import GlassActWire
import XCTest
@testable import DuoDesktop

/// The Host adds the phone's terminal key (project notes): one test per claim.
@MainActor
final class TerminalKeyByHostTests: XCTestCase {
    /// A channel standing in for the Glass Act session: answers with `answer`, or never (an older Host).
    final class FakeChannel: TerminalKeyChannel {
        var onTerminalKeyResult: ((WireTerminalKeyResult) -> Void)?
        var answer: ((UInt32) -> WireTerminalKeyResult)?
        var running = true
        var sentLines: [String] = []
        func installTerminalKey(requestID: UInt32, keyLine: String, sent: @escaping @Sendable (Bool) -> Void) {
            sentLines.append(keyLine)
            sent(running)
            guard running, let answer else { return }
            let r = answer(requestID)
            DispatchQueue.main.async { self.onTerminalKeyResult?(r) }
        }
    }

    private func store() throws -> MacStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "TerminalKeyByHostTests.\(UUID().uuidString)")!
        try Data(#"[{"id":"M1","name":"Test Mac","home":"192.0.2.10","port":4433,"layout":"standard","terminal":true}]"#.utf8)
            .write(to: dir.appendingPathComponent("macs.json"))
        return MacStore(url: dir.appendingPathComponent("macs.json"), defaults: defaults,
                        knownHosts: KnownHosts(url: dir.appendingPathComponent("known_hosts")))
    }

    override func setUp() {
        TerminalKeyByHost.states = TerminalKeyStates(defaults: UserDefaults(suiteName: "TKS.\(UUID().uuidString)")!)
    }

    private func outcome(_ ch: FakeChannel) -> TerminalKeyByHost.Outcome? {
        let done = expectation(description: "answer")
        var got: TerminalKeyByHost.Outcome?
        TerminalKeyByHost.send(controller: ch, keyLine: "ssh-ed25519 AAAA duo-desktop") { got = $0; done.fulfill() }
        wait(for: [done], timeout: 5)
        return got
    }

    /// Review fixes 2: an approval from before the Host recorded SSH-key permission. The Host first says it is asking
    /// its user; the app shows "Approve on the Mac", waits past the short older-Host wait, and takes the real answer.
    func testAskingOnTheMacWaitsForTheRealAnswer() throws {
        let saved = (TerminalKeyByHost.waitSeconds, TerminalKeyByHost.askingWaitSeconds)
        defer { (TerminalKeyByHost.waitSeconds, TerminalKeyByHost.askingWaitSeconds) = saved }
        TerminalKeyByHost.waitSeconds = 0.2
        TerminalKeyByHost.askingWaitSeconds = 5
        final class AskingChannel: TerminalKeyChannel {
            var onTerminalKeyResult: ((WireTerminalKeyResult) -> Void)?
            func installTerminalKey(requestID: UInt32, keyLine: String, sent: @escaping @Sendable (Bool) -> Void) {
                sent(true)
                DispatchQueue.main.async {
                    self.onTerminalKeyResult?(WireTerminalKeyResult(requestID: requestID, status: .askingOnMac,
                                                                    remoteLoginOn: false, tmuxPresent: false, userName: "someone"))
                }
                // The person answers on the Mac after the older-Host wait would have ended.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    self.onTerminalKeyResult?(WireTerminalKeyResult(requestID: requestID, status: .refused,
                                                                    remoteLoginOn: true, tmuxPresent: true, userName: "someone",
                                                                    reason: "this Mac's user did not allow this device to add SSH keys"))
                }
            }
        }
        let ch = AskingChannel()
        let done = expectation(description: "answer")
        var asked = 0
        var got: TerminalKeyByHost.Outcome?
        TerminalKeyByHost.send(controller: ch, keyLine: "ssh-ed25519 AAAA duo-desktop", asking: { asked += 1 }) {
            got = $0; done.fulfill()
        }
        wait(for: [done], timeout: 5)
        XCTAssertEqual(asked, 1)
        guard case let .answered(r) = try XCTUnwrap(got) else { return XCTFail("\(String(describing: got))") }
        XCTAssertEqual(r.status, .refused)
        XCTAssertEqual(TerminalKeyByHost.settingsLine(TerminalKeyState(r)),
                       "The Mac did not add the key: this Mac's user did not allow this device to add SSH keys.")
    }

    /// Claim: the Host's answer comes back as the outcome; the user name it reports fills an empty SSH user name
    /// (and an already-set one is kept, as it stays editable).
    func testInstalledAnswerFillsTheUserName() throws {
        let ch = FakeChannel()
        ch.answer = { WireTerminalKeyResult(requestID: $0, status: .installed, remoteLoginOn: true, tmuxPresent: true,
                                            userName: "someone") }
        let o = try XCTUnwrap(outcome(ch))
        guard case let .answered(r) = o else { return XCTFail("\(o)") }
        XCTAssertEqual(r.status, .installed)
        let s = try store()
        TerminalKeyByHost.record(o, macID: "M1", store: s)
        XCTAssertEqual(s.entry("M1")?.sshUser, "someone")
        XCTAssertEqual(TerminalKeyByHost.states.state(for: "M1")?.keyOnMac, true)

        s.update("M1") { $0.sshUser = "mine" }
        TerminalKeyByHost.record(o, macID: "M1", store: s)
        XCTAssertEqual(s.entry("M1")?.sshUser, "mine")
    }

    /// Claim: an older Host (it skips the unknown request and never answers) leads to the fallback: the outcome is
    /// `olderHost`, nothing is filled in, and the settings say to use the password or copy the key.
    func testOlderHostFallsBack() throws {
        TerminalKeyByHost.waitSeconds = 0.2
        defer { TerminalKeyByHost.waitSeconds = 4 }
        let ch = FakeChannel() // no answer
        let o = try XCTUnwrap(outcome(ch))
        XCTAssertEqual(o, .olderHost)
        let s = try store()
        TerminalKeyByHost.record(o, macID: "M1", store: s)
        XCTAssertNil(s.entry("M1")?.sshUser)
        let line = try XCTUnwrap(TerminalKeyByHost.settingsLine(TerminalKeyByHost.states.state(for: "M1")))
        XCTAssertTrue(line.contains("password") && line.contains("copy"), line)
    }

    /// Claim: with no running session the request is not sent anywhere and nothing is recorded.
    func testNoSessionRecordsNothing() throws {
        let ch = FakeChannel()
        ch.running = false
        XCTAssertEqual(outcome(ch), .noSession)
        TerminalKeyByHost.record(.noSession, macID: "M1", store: try store())
        XCTAssertNil(TerminalKeyByHost.states.state(for: "M1"))
    }

    /// Claim: the settings line says "Key installed on this Mac", or what is missing.
    func testSettingsLine() {
        typealias S = TerminalKeyState
        XCTAssertNil(TerminalKeyByHost.settingsLine(nil))
        XCTAssertEqual(TerminalKeyByHost.settingsLine(S(answer: .installed)), "Key installed on this Mac")
        XCTAssertEqual(TerminalKeyByHost.settingsLine(S(answer: .alreadyThere)), "Key installed on this Mac")
        XCTAssertEqual(TerminalKeyByHost.settingsLine(S(answer: .installed, remoteLoginOn: false)),
                       "Key installed on this Mac. This Mac's SSH port is not listening (turn on Remote Login).")
        XCTAssertEqual(TerminalKeyByHost.settingsLine(S(answer: .installed, tmuxPresent: false)),
                       "Key installed on this Mac. tmux is not installed.")
        XCTAssertEqual(TerminalKeyByHost.settingsLine(S(answer: .refused, reason: "the key type is not known")),
                       "The Mac did not add the key: the key type is not known.")
    }

    /// Claim: turning Terminal on asks the Host of that Mac's running session, sending the phone's own public key
    /// line (one line); a different Mac's session is not asked.
    func testAskSendsThePhonesKeyLineOverThatMacsSession() throws {
        let ch = FakeChannel()
        ch.answer = { WireTerminalKeyResult(requestID: $0, status: .alreadyThere, remoteLoginOn: true, tmuxPresent: false,
                                            userName: "someone") }
        let s = try store()
        TerminalKeyByHost.live = .init(macID: "OTHER", controller: ch)
        defer { TerminalKeyByHost.live = nil }
        let other = expectation(description: "other")
        TerminalKeyByHost.ask(macID: "M1", store: s) { XCTAssertEqual($0, .noSession); other.fulfill() }
        wait(for: [other], timeout: 2)
        XCTAssertTrue(ch.sentLines.isEmpty)

        TerminalKeyByHost.live = .init(macID: "M1", controller: ch)
        let done = expectation(description: "done")
        TerminalKeyByHost.ask(macID: "M1", store: s) { _ in done.fulfill() }
        wait(for: [done], timeout: 5)
        let line = try TerminalKeys.phoneKey().authorizedKeysLine(comment: "duo-desktop")
        XCTAssertEqual(ch.sentLines, [line])
        XCTAssertFalse(line.contains("\n"))
        XCTAssertEqual(TerminalKeyByHost.settingsLine(TerminalKeyByHost.states.state(for: "M1")),
                       "Key installed on this Mac. tmux is not installed.")
        XCTAssertEqual(s.entry("M1")?.sshUser, "someone")
    }
}
#endif
