#if DUO_TERMINAL
import DuoTerminalKit
import GlassActTransport
import Network
import XCTest
@testable import DuoDesktop

/// project notes, terminal-only computers, milestones 1 and 2: one test per claim. Made-up names only.
@MainActor
final class TerminalComputersTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "TerminalComputersTests.\(UUID().uuidString)")
    }

    private func store() -> MacStore {
        MacStore(url: dir.appendingPathComponent("macs.json"), defaults: defaults,
                 knownHosts: KnownHosts(url: dir.appendingPathComponent("known_hosts")))
    }

    private func labServer() -> MacEntry {
        .terminalComputer(name: "Lab Server", address: "lab-server", port: 22, user: "lab",
                          signIn: .tailscale, opens: .tmux)
    }

    /// Claim (M1): entries saved before the kind existed read as Macs; a terminal entry is kept in the same file
    /// with its fields, and every Glass Act reader (`macs`) sees the Macs only.
    func testOldEntriesAreMacsAndTerminalsStayOutOfTheMacList() throws {
        // An entry as an earlier build wrote it: no "kind".
        let old = #"[{"id":"A","name":"my-mac","tailscale":"my-mac","port":4433,"layout":"standard"}]"#
        try Data(old.utf8).write(to: dir.appendingPathComponent("macs.json"))
        let s = store()
        XCTAssertEqual(s.macs.map(\.name), ["my-mac"])
        XCTAssertFalse(try XCTUnwrap(s.entry("A")).isTerminal)
        s.add(labServer())
        let again = store()
        XCTAssertEqual(again.macs.map(\.name), ["my-mac"], "the Mac list (probes, sessions, outer screen) is unchanged")
        let t = try XCTUnwrap(again.terminals.first)
        XCTAssertEqual(t.name, "Lab Server")
        XCTAssertEqual(t.kind, .terminal)
        XCTAssertEqual(t.port, 22)
        XCTAssertEqual(t.sshUser, "lab")
        XCTAssertEqual(t.signIn, .tailscale)
        XCTAssertEqual(t.opens, .tmux)
        again.remove(t.id)
        XCTAssertTrue(store().terminals.isEmpty)
    }

    /// Claim (M1): the address is filed by the Mac rule (a home name is Home, anything else Tailscale); the row's
    /// second line names what it opens and how it signs in.
    func testNewEntryAddressAndRowWords() {
        let t = labServer()
        XCTAssertEqual(t.tailscale, "lab-server")
        XCTAssertNil(t.home)
        XCTAssertEqual(t.terminalSecondLine, "tmux · Tailscale sign-in")
        var w = MacEntry.terminalComputer(name: "Windows PC", address: "windows-pc.local", port: 22, user: "me",
                                          signIn: .phoneKey, opens: .loginShell)
        XCTAssertEqual(w.home, "windows-pc.local")
        XCTAssertEqual(w.terminalSecondLine, "Login shell · This iPhone’s key")
        w.setTerminalAddress("windows-pc")
        XCTAssertEqual(w.tailscale, "windows-pc")
        XCTAssertNil(w.home)
    }

    /// Claim (M1): the Add sheet says in place what is missing.
    func testFormSaysWhatIsMissing() {
        XCTAssertNil(TerminalComputerForm.problem(name: "Lab Server", address: "lab-server", user: "lab", port: "22"))
        XCTAssertEqual(TerminalComputerForm.problem(name: " ", address: "a", user: "u", port: "22"), "Type a name.")
        XCTAssertEqual(TerminalComputerForm.problem(name: "n", address: "", user: "u", port: "22"), "Type the computer’s address.")
        XCTAssertEqual(TerminalComputerForm.problem(name: "n", address: "a", user: "", port: "22"), "Type the user name to sign in as.")
        XCTAssertNotNil(TerminalComputerForm.problem(name: "n", address: "a", user: "u", port: "0"))
        XCTAssertNotNil(TerminalComputerForm.problem(name: "n", address: "a", user: "u", port: "99999"))
    }

    /// Claim (M1): the list row's reach is a TCP check of the entry's own port: Ready when it connects, Not
    /// reachable when not; no SSH sign-in.
    func testReachUsesTheTCPCheckOnTheEntrysPort() {
        let reach = TerminalReach()
        var asked: [(String, UInt16)] = []
        reach.check = { host, port, _, done in asked.append((host, port)); done(host == "lab-server") }
        var off = labServer(); off.id = "B"; off.setTerminalAddress("gone-server")
        let on = labServer()
        reach.probeAll([on, off])
        XCTAssertEqual(asked.map(\.0), ["lab-server", "gone-server"])
        XCTAssertEqual(asked.map(\.1), [22, 22])
        let done = expectation(description: "answers")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(reach.state(on.id), .ready)
        XCTAssertEqual(reach.state("B"), .notReachable)
    }

    /// Claim (M1): the TCP check itself, against a port listening on this test machine and a closed one.
    func testTCPCheckAgainstALocalPort() throws {
        let listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { $0.start(queue: .main) }
        let up = expectation(description: "listening")
        listener.stateUpdateHandler = { if case .ready = $0 { up.fulfill() } }
        listener.start(queue: .main)
        wait(for: [up], timeout: 5)
        let port = try XCTUnwrap(listener.port?.rawValue)
        let open = expectation(description: "open")
        TCPCheck.check(host: "127.0.0.1", port: port, timeout: 2) { ok in XCTAssertTrue(ok); open.fulfill() }
        wait(for: [open], timeout: 5)
        listener.cancel()
        let closed = expectation(description: "closed")
        TCPCheck.check(host: "127.0.0.1", port: 1, timeout: 2) { ok in XCTAssertFalse(ok); closed.fulfill() }
        wait(for: [closed], timeout: 5)
    }

    /// Claim (M2): failures are said in plain words with no Host to help: Tailscale's refusal (its own words kept),
    /// a refused key, nothing on the port.
    func testFailuresInPlainWords() {
        let said = "tailscale: tailnet policy does not permit you to SSH as user \"root\""
        let p = TerminalComputerProblem.diagnose(SSHSignInRefused(reason: said), user: "root", host: "lab-server",
                                                 port: 22, tailscale: true)
        XCTAssertEqual(p, .tailscaleRefused(user: "root", said: said))
        XCTAssertTrue(p.text.hasPrefix("Tailscale refused “root” for this iPhone."))
        XCTAssertFalse(p.retries)
        XCTAssertEqual(TerminalComputerProblem.diagnose(SSHSignInRefused(), user: "me", host: "h", port: 22, tailscale: false),
                       .keyRefused(user: "me"))
        let refused = NSError(domain: NSPOSIXErrorDomain, code: Int(ECONNREFUSED))
        let q = TerminalComputerProblem.diagnose(refused, user: "me", host: "h", port: 2222, tailscale: true)
        XCTAssertEqual(q.text, "Nothing answers on port 2222. Check that the computer’s SSH server is on.")
        XCTAssertTrue(q.retries)
        XCTAssertEqual(TerminalComputerProblem.diagnose(SSHSignInTimedOut(), user: "me", host: "h", port: 22, tailscale: true),
                       .signInTimedOut)
    }

    /// Claim (M2): tmux opens the computer's tmux line (session `duo`, notice naming the computer); Login Shell
    /// sends no command at all.
    func testOpensPicksTheCommand() {
        XCTAssertEqual(TerminalOpens.tmux.command, ShellCommand.tmuxOrShellComputer)
        XCTAssertNil(TerminalOpens.loginShell.command)
    }

    /// Claim (M1 renames): the list's words cover both kinds.
    func testListWords() {
        XCTAssertEqual(ListWords.title, "Computers")
        XCTAssertEqual(ListWords.footer, "Tap a computer to connect. Tap ⓘ for its settings.")
        XCTAssertEqual(ListWords.emptyDescription, "Add a Mac running Glass Act Host, or a computer you reach over SSH.")
    }
}
#endif
