#if DUO_TERMINAL
import GlassActTransport
import XCTest
@testable import DuoDesktop

/// project notes, M1: one test per claim.
@MainActor
final class TerminalTests: XCTestCase {
    /// Claim: a Mac list saved before the Terminal switch existed loads unchanged, every Mac with Terminal off,
    /// and the new fields are kept on the next load.
    func testStoredListFromBeforeTerminalLoadsUnchanged() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("macs.json")
        // The file as build 33 wrote it (no "terminal", no "sshUser").
        let old = """
        [{"id":"A1","name":"Test Mac","tailscale":"test-mac.example.ts.net","port":4433,"view":"centred",\
        "layout":"standard","key":"abc"}]
        """
        try Data(old.utf8).write(to: url)
        let defaults = UserDefaults(suiteName: "TerminalTests.\(UUID().uuidString)")!
        let kh = KnownHosts(url: dir.appendingPathComponent("known_hosts"))
        let s = MacStore(url: url, defaults: defaults, knownHosts: kh)
        XCTAssertEqual(s.macs.count, 1, "the stored list is read, not replaced by the built-in one")
        let e = try XCTUnwrap(s.entry("A1"))
        XCTAssertEqual(e.name, "Test Mac")
        XCTAssertEqual(e.view, "centred")
        XCTAssertEqual(e.key, "abc")
        XCTAssertFalse(e.terminalOn)
        XCTAssertNil(e.sshUser)

        s.update("A1") { $0.terminalOn = true; $0.sshUser = "someone" }
        let again = MacStore(url: url, defaults: defaults, knownHosts: kh)
        XCTAssertEqual(again.entry("A1")?.terminalOn, true)
        XCTAssertEqual(again.entry("A1")?.sshUser, "someone")
    }

    /// Claim: Terminal is a choice only for a Mac with Terminal on; a remembered Terminal falls back to Whole
    /// Screen once Terminal is turned off.
    func testTerminalChoiceOnlyWhenOn() {
        XCTAssertEqual(SessionView.choices(terminal: false), [.regular, .centred])
        XCTAssertEqual(SessionView.choices(terminal: true), [.regular, .centred, .terminal])
        XCTAssertEqual(SessionView.resolve(stored: "terminal", terminal: true), .terminal)
        XCTAssertEqual(SessionView.resolve(stored: "terminal", terminal: false), .regular)
        XCTAssertEqual(SessionView.resolve(stored: "centred", terminal: false), .centred)
        XCTAssertEqual(SessionView.resolve(stored: nil, terminal: true), .regular)
    }

    /// Claim: the local echo shows typed text, and esc and the arrows as visible escape codes; Paste never ends
    /// with Return.
    func testEchoAndPaste() {
        func shown(_ b: [UInt8]) -> String { String(decoding: TerminalEcho.display(b), as: UTF8.self) }
        XCTAssertEqual(shown(Array("hello".utf8)), "hello")
        XCTAssertEqual(shown(TerminalKey.esc.bytes()!), "^[")
        XCTAssertEqual(shown(TerminalKey.up.bytes()!), "^[[A")
        XCTAssertEqual(shown(TerminalKey.left.bytes(applicationCursor: true)!), "^[OD")
        XCTAssertEqual(shown([0x0d]), "\r\n")
        XCTAssertEqual(TerminalPaste.prepare("printf 'duo-paste\\n'\n"), "printf 'duo-paste\\n'")
    }

    /// Claim: the band is one row of the nine chosen keys in the owner's order (the owner 2026-11-21: "make it only one
    /// row"), 44 pt tall, and the terminal takes the rest of the band.
    func testOneRowOfKeys() {
        XCTAssertEqual(TerminalKey.row, [.esc, .tab, .ctrl, .left, .up, .down, .right, .ctrlC, .paste])
        XCTAssertEqual(TerminalKey.row.map(\.label), ["esc", "tab", "ctrl", "←", "↑", "↓", "→", "⌃C", "Paste"])
        XCTAssertEqual(TerminalKeysBand.height, 44)
        XCTAssertEqual(TerminalKeysBand.terminalExtra(bandHeight: 200), 156)
        XCTAssertEqual(TerminalKeysBand.terminalExtra(bandHeight: 30), 0)
    }
}
#endif
