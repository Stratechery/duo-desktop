#if DUO_TERMINAL
import DuoTerminalKit
#endif
import GlassActTransport
import LocalAuthentication
import XCTest
@testable import DuoDesktop

/// Project notes, one computer with any connection, milestone 1: one entry with optional ways in. One test per claim;
/// made-up names only. Entries are written as earlier builds wrote them (raw JSON), then read by today's store.
@MainActor
final class ComputersTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "ComputersTests.\(UUID().uuidString)")
    }

    private var file: URL { dir.appendingPathComponent("macs.json") }

    private func store() -> MacStore {
        MacStore(url: file, defaults: defaults, knownHosts: KnownHosts(url: dir.appendingPathComponent("known_hosts")))
    }

    private func write(_ json: String) throws { try Data(json.utf8).write(to: file) }

    /// Claim: a Mac saved by build 59 (no kind; Terminal and JetKVM switches on) carries over as a computer with
    /// Screen Sharing (same id, address, Glass Act port and key) plus Terminal and JetKVM; its Terminal keeps SSH
    /// port 22, this iPhone's key and tmux (review finding 1). The carried-over list is saved back, and reading it
    /// again changes nothing.
    func testOldMacCarriesOverWithItsSwitches() throws {
        try write(#"[{"id":"M1","name":"my-mac","tailscale":"my-mac","port":4433,"key":"AB12","layout":"standard","terminal":true,"sshUser":"me","jetkvm":true,"jetkvmAddress":"my-kvm"}]"#)
        let e = try XCTUnwrap(store().entry("M1"))
        XCTAssertEqual(e.screenSharing, true)
        XCTAssertEqual(e.tailscale, "my-mac")
        XCTAssertEqual(e.port, 4433)
        XCTAssertEqual(e.key, "AB12")
        XCTAssertEqual(e.terminal, true)
        XCTAssertEqual(e.sshUser, "me")
        XCTAssertEqual(e.sshPortValue, 22)
        XCTAssertEqual(e.terminalSignIn, .phoneKey)
        XCTAssertEqual(e.terminalOpens, .tmux)
        XCTAssertEqual(e.jetkvm, true)
        XCTAssertEqual(e.jetkvmAddress, "my-kvm")
        XCTAssertNil(e.kind)
        XCTAssertEqual(e.waysIn, [.screenSharing, .terminal, .jetkvm])
        let saved = try String(contentsOf: file, encoding: .utf8)
        XCTAssertTrue(saved.contains(#""screenSharing":true"#), "saved back in today's shape")
        XCTAssertEqual(store().entry("M1"), e, "a second read changes nothing")

        // A Mac with neither switch (or one saved before the switches existed) has Screen Sharing only.
        try write(#"[{"id":"M2","name":"plain-mac","home":"plain-mac.local","port":4433,"layout":"standard"}]"#)
        XCTAssertEqual(try XCTUnwrap(store().entry("M2")).waysIn, [.screenSharing])
    }

    /// Claim: a terminal computer saved by build 59 carries over as a computer with Terminal only, keeping its own
    /// address, SSH port, user name, sign-in and Opens; Glass Act's port goes back to its default, so the SSH
    /// port no longer shares that field. Its host-key id (`ssh:<id>:<port>`) is the same as before. An absent
    /// sign-in still reads as Tailscale. `kind` stays written, so an older build still reads it as terminal only.
    func testOldTerminalComputerCarriesOverAsTerminal() throws {
        try write(#"[{"id":"T1","name":"Lab Server","tailscale":"lab-server","port":2222,"layout":"standard","kind":"terminal","sshUser":"lab","terminalSignIn":"phoneKey","terminalOpens":"loginShell"},{"id":"T2","name":"Old Server","tailscale":"old-server","port":22,"layout":"standard","kind":"terminal","sshUser":"me"}]"#)
        let s = store()
        let t = try XCTUnwrap(s.entry("T1"))
        XCTAssertEqual(t.screenSharing, false)
        XCTAssertEqual(t.terminal, true)
        XCTAssertEqual(t.tailscale, "lab-server")
        XCTAssertEqual(t.sshPort, 2222)
        XCTAssertEqual(t.port, 4433)
        XCTAssertEqual(t.sshUser, "lab")
        XCTAssertEqual(t.terminalSignIn, .phoneKey)
        XCTAssertEqual(t.terminalOpens, .loginShell)
        XCTAssertEqual(t.waysIn, [.terminal])
        XCTAssertEqual(t.kind, .terminal)
        #if DUO_TERMINAL
        XCTAssertEqual(sshHostKeyID(mac: t.id, port: Int(t.sshPortValue)), "ssh:T1:2222")
        #endif
        let old = try XCTUnwrap(s.entry("T2"))
        XCTAssertEqual(old.terminalSignIn, .tailscale)
        XCTAssertEqual(old.terminalOpens, .tmux)
        XCTAssertEqual(old.sshPort, 22)
    }

    /// Claim: one list, in the order added, every computer in it; each row's second line names what it has, in
    /// order. A JetKVM-only computer (milestone 2 adds them) is listed with "JetKVM" and its dot checks the
    /// JetKVM's web port, never its viewer.
    func testOneListAndRowWords() throws {
        try write(#"""
        [{"id":"T1","name":"Lab Server","tailscale":"lab-server","port":22,"layout":"standard","kind":"terminal","sshUser":"lab"},
         {"id":"M1","name":"my-mac","tailscale":"my-mac","port":4433,"layout":"standard","terminal":true,"jetkvm":true,"jetkvmAddress":"http://my-kvm/"},
         {"id":"M2","name":"plain-mac","tailscale":"plain-mac","port":4433,"layout":"standard","jetkvm":true},
         {"id":"K1","name":"Side Mac","port":4433,"layout":"standard","screenSharing":false,"jetkvm":true,"jetkvmAddress":"https://side-kvm"}]
        """#)
        let s = store()
        var expected: [(String, String)] = [("Lab Server", "Terminal"),
                                            ("my-mac", "Screen Sharing · Terminal · JetKVM"),
                                            ("plain-mac", "Screen Sharing"), // JetKVM switch on but no address
                                            ("Side Mac", "JetKVM")]
        // A build without a way in leaves it out of the line, and a computer with nothing this build shows out of
        // the list (its settings stay saved).
        if !WayIn.inThisBuild.contains(.terminal) {
            expected = expected.compactMap { $0.0 == "Lab Server" ? nil : ($0.0, $0.1.replacingOccurrences(of: " · Terminal", with: "")) }
        }
        if !WayIn.inThisBuild.contains(.jetkvm) {
            expected = expected.compactMap { $0.0 == "Side Mac" ? nil : ($0.0, $0.1.replacingOccurrences(of: " · JetKVM", with: "")) }
        }
        XCTAssertEqual(s.computers.map(\.name), expected.map(\.0))
        XCTAssertEqual(s.computers.map { $0.waysInThisBuild.map(\.label).joined(separator: " · ") }, expected.map(\.1))
        XCTAssertEqual(s.entries.count, 4, "nothing dropped")

        let side = try XCTUnwrap(s.entry("K1"))
        if WayIn.inThisBuild.contains(.jetkvm) {
            XCTAssertEqual(ComputerReach.target(side, .jetkvm)?.host, "side-kvm")
            XCTAssertEqual(ComputerReach.target(side, .jetkvm)?.port, 443)
        }
        XCTAssertNil(ComputerReach.target(side, .screenSharing), "Screen Sharing has Glass Act's own check")
        XCTAssertEqual(ComputerReach.target(try XCTUnwrap(s.entry("T1")), .terminal)?.port, 22)
    }

    /// Claim: no Glass Act reader sees a computer without Screen Sharing: the Mac list (`macs`), the Glass Act
    /// check (`MacList.probeAll`), key matching, the cold outer-screen target and Turn Off Touch ID's password sweep
    /// all see the Screen Sharing computers only, even when another computer has a key or is the last one used.
    func testGlassActReadersSeeOnlyScreenSharing() throws {
        try write(#"""
        [{"id":"M1","name":"my-mac","tailscale":"my-mac","port":4433,"key":"K-MAC","layout":"standard"},
         {"id":"T1","name":"Lab Server","tailscale":"lab-server","port":22,"key":"K-T","layout":"standard","kind":"terminal","sshUser":"lab","autoUnlock":true},
         {"id":"K1","name":"Side Mac","port":4433,"key":"K-K","layout":"standard","screenSharing":false,"jetkvm":true,"jetkvmAddress":"side-kvm","autoUnlock":true}]
        """#)
        let s = store()
        XCTAssertEqual(s.macs.map(\.id), ["M1"])
        XCTAssertNil(s.entry(withKey: "K-T"))
        XCTAssertNil(s.entry(withKey: "K-K"))
        XCTAssertEqual(s.entry(withKey: "K-MAC")?.id, "M1")

        let list = MacList(store: s)
        list.probeAll(identity: nil)
        XCTAssertNotNil(list.reach["M1"])
        XCTAssertNil(list.reach["T1"])
        XCTAssertNil(list.reach["K1"])

        LastMac.store(try XCTUnwrap(s.entry("K1")), in: defaults)
        XCTAssertNil(LastMac.find(in: s.macs, d: defaults), "the last one used has no Screen Sharing: no cold connect")

        let keychain = MemoryPasswords()
        AutoUnlockSetting.appLockTurnedOff(store: s, keychain: keychain, defaults: defaults)
        XCTAssertTrue(keychain.deleted.isEmpty, "only Screen Sharing computers are swept, and none has a password")
    }
}

/// A password store in memory that records deletions.
private final class MemoryPasswords: MacPasswordKeeping {
    var deleted: [String] = []
    func save(_ password: Data, macID: String) -> Bool { true }
    func delete(macID: String) { deleted.append(macID) }
    func read(macID: String, context: LAContext) -> Data? { nil }
}
