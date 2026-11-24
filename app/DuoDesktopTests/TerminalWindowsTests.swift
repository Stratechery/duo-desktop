#if DUO_TERMINAL
import DuoTerminalKit
import GlassActTransport
import XCTest
@testable import DuoDesktop

/// One test per claim; made-up computers only.
@MainActor
final class TerminalWindowsTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private var access: AppAccess.State = .locked
    static let windowsLine = "SSH-2.0-OpenSSH_for_Windows_9.5"
    static let linuxLine = "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5"

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("TerminalWindowsTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "TerminalWindowsTests.\(UUID().uuidString)")
        access = AppAccess.state
        AppAccess.set(.open)
    }

    override func tearDown() async throws { AppAccess.set(access) }

    private func store() -> MacStore {
        MacStore(url: dir.appendingPathComponent("macs.json"), defaults: defaults,
                 knownHosts: KnownHosts(url: dir.appendingPathComponent("known_hosts")))
    }

    /// A terminal-only computer as the Add sheet saves one, with the old defaults (Tailscale, tmux).
    private func computer(_ name: String = "Lab Box", remoteDesktop: Bool = false) -> MacEntry {
        var e = MacEntry.terminalComputer(name: name, address: "lab-box", port: 22, user: "pat",
                                          signIn: .tailscale, opens: .tmux)
        if remoteDesktop { e.remoteDesktop = true }
        return e
    }

    /// A pretend server: says `line` first, then refuses the sign-in; records how each attempt signed in.
    final class Server: @unchecked Sendable {
        let line: String
        private let lock = NSLock()
        private var _signIns: [String] = []
        init(_ line: String) { self.line = line }
        var signIns: [String] { lock.withLock { _signIns } }
        var connector: TerminalComputerCheck.Connector {
            { [self] _, _, _, signIn, _, _, serverLine in
                serverLine(line)
                let how: String = { if case .tailscale = signIn { return "tailscale" }; return "key" }()
                lock.withLock { _signIns.append(how) }
                throw SSHSignInRefused(offersPassword: true)
            }
        }
    }

    // MARK: Each sign marks the entry as a PC

    func testRemoteDesktopMarksAPC() {
        XCTAssertTrue(computer(remoteDesktop: true).isPC)
        XCTAssertFalse(computer().isPC)
    }

    func testWindowsServerLineMarksAPCAtTheCheck() async {
        let s = store()
        let e = computer()
        s.addNew(e, startWith: .terminal)
        let server = Server(Self.windowsLine)
        _ = await TerminalComputerCheck.check(e, store: s, connector: server.connector)
        XCTAssertEqual(s.entry(e.id)?.terminalSystem, .windows)
        XCTAssertEqual(s.entry(e.id)?.isPC, true)
    }

    /// A wrong guess corrects itself: a Linux server's own line wins over the Remote Desktop sign.
    func testNonWindowsServerLineOverridesRemoteDesktop() async {
        let s = store()
        let e = computer(remoteDesktop: true)
        s.addNew(e, startWith: .terminal)
        XCTAssertTrue(e.isPC)
        _ = await TerminalComputerCheck.check(e, store: s, connector: Server(Self.linuxLine).connector)
        XCTAssertEqual(s.entry(e.id)?.terminalSystem, .other)
        XCTAssertEqual(s.entry(e.id)?.isPC, false)
    }

    // MARK: A PC's choices: no tmux, no Tailscale

    func testAPCOffersOnlyThisIPhonesKeyAndItsOwnShell() {
        let pc = computer(remoteDesktop: true)
        XCTAssertEqual(pc.signIn, .phoneKey)
        XCTAssertEqual(pc.opens, .loginShell)
        XCTAssertEqual(PCTerminalRows.shell, "PowerShell")
        for word in ["tmux", "Login Shell", "Tailscale"] {
            XCTAssertFalse(PCTerminalRows.footer.contains(word), "PC footer says \(word)")
        }
        XCTAssertTrue(PCTerminalRows.footer.contains("PC") && PCTerminalRows.footer.contains("PowerShell"))
        XCTAssertEqual(TerminalTopBar.subtitle(pc), "PowerShell")
    }

    // MARK: A saved Tailscale/tmux entry is corrected

    func testSavedTailscaleAndTmuxAreCorrectedForAPC() {
        var pc = computer(remoteDesktop: true)
        XCTAssertTrue(pc.correctForPC())
        XCTAssertEqual(pc.terminalSignIn, .phoneKey)
        XCTAssertEqual(pc.terminalOpens, .loginShell)
        XCTAssertFalse(pc.correctForPC(), "already corrected")
    }

    /// At the check: a PC found while Tailscale was saved is saved with the PC's choices, and checked again at once
    /// with this iPhone's key.
    func testCheckCorrectsTheSavedEntryAndRetriesWithTheKey() async {
        let s = store()
        let e = computer()
        s.addNew(e, startWith: .terminal)
        let server = Server(Self.windowsLine)
        _ = await TerminalComputerCheck.check(e, store: s, connector: server.connector)
        XCTAssertEqual(s.entry(e.id)?.terminalSignIn, .phoneKey)
        XCTAssertEqual(s.entry(e.id)?.terminalOpens, .loginShell)
        XCTAssertEqual(server.signIns, ["tailscale", "key"])
    }

    // MARK: No tmux line to a PC (the link's own guard is DuoTerminalKit's ServerLineTests)

    func testAPCsTerminalRunsNoCommand() {
        XCTAssertNil(computer(remoteDesktop: true).opens.command)
        var known = computer()
        known.terminalSystem = .windows
        XCTAssertNil(known.opens.command)
    }

    // MARK: A Mac's and a Linux box's are unchanged

    func testMacAndLinuxAreUnchanged() async {
        let linux = computer()
        XCTAssertEqual(linux.signIn, .tailscale)
        XCTAssertEqual(linux.opens, .tmux)
        XCTAssertEqual(linux.opens.command, ShellCommand.tmuxOrShellComputer)
        XCTAssertEqual(TerminalTopBar.subtitle(linux), "Terminal")
        var l = linux
        XCTAssertFalse(l.correctForPC())
        let s = store()
        s.addNew(linux, startWith: .terminal)
        let server = Server(Self.linuxLine)
        _ = await TerminalComputerCheck.check(linux, store: s, connector: server.connector)
        XCTAssertEqual(s.entry(linux.id)?.terminalSignIn, .tailscale)
        XCTAssertEqual(s.entry(linux.id)?.terminalOpens, .tmux)
        XCTAssertEqual(server.signIns, ["tailscale"])
        // A Mac with Glass Act Host is never a PC, whatever its fields say.
        var mac = MacEntry(name: "Studio")
        mac.screenSharing = true
        mac.terminalSystem = .windows
        XCTAssertFalse(mac.isPC)
    }

    // MARK: Synced, and older builds do not lose it

    func testSyncKeepsItInItsOwnField() throws {
        var e = computer()
        e.terminalSystem = .windows
        let c = CloudComputer(editedAt: Date(timeIntervalSince1970: 1), computer: SyncedComputer(e))
        let fields = try XCTUnwrap(CloudComputerSync.fields(c))
        XCTAssertNotNil(fields[CloudComputerSync.terminalSystemField])
        XCTAssertFalse(String(decoding: fields[CloudComputerSync.payloadField]!, as: UTF8.self).contains("terminalSystem"),
                       "in payload, an older build would drop it")
        let back = try XCTUnwrap(CloudComputerSync.decode(fields.mapValues { Optional($0) }))
        var other = computer()
        back.computer?.apply(to: &other)
        XCTAssertEqual(other.terminalSystem, .windows)
        // A record only an older build saved (no field): this iPhone's own value stays.
        var older = fields; older[CloudComputerSync.terminalSystemField] = nil
        var mine = computer(); mine.terminalSystem = .windows
        CloudComputerSync.decode(older.mapValues { Optional($0) })?.computer?.apply(to: &mine)
        XCTAssertEqual(mine.terminalSystem, .windows)
    }
}
#endif
