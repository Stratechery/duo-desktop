import GlassActTransport
import XCTest
@testable import DuoDesktop

/// Project notes (name-opens-default) (the owner 2026-11-23: "Clicking the computer name should also go to the default view; setting
/// should go back inside the (i)", and the light: "We should add the green light at the beginning of the row if the
/// computer is reachable", "yellow light if reachable but not logged in", "red light if not reachable"). One test per
/// claim; the (i) and the name tap on the real list are in `NameOpensDefaultUITests`.
@MainActor
final class NameOpensDefaultTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("NameOpensDefault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        ComputerNav.shared.close()
        ComputerNav.shared.startScreenSharing = { _, _ in }
        ComputerNav.shared.endScreenSharing = {}
        try? FileManager.default.removeItem(at: dir)
    }

    private func store() -> MacStore {
        MacStore(url: dir.appendingPathComponent("macs.json"),
                 defaults: UserDefaults(suiteName: "NameOpensDefault.\(UUID().uuidString)")!,
                 knownHosts: KnownHosts(url: dir.appendingPathComponent("known_hosts")))
    }

    /// A computer with the given ways in (made-up addresses).
    private func computer(_ name: String, _ ways: Set<WayIn>) -> MacEntry {
        var e = MacEntry(name: name)
        e.set(.tailscale, "made-up-\(e.id.prefix(4))")
        e.screenSharing = ways.contains(.screenSharing)
        e.terminal = ways.contains(.terminal)
        e.sshUser = "me"
        e.jetkvm = ways.contains(.jetkvm)
        e.jetkvmAddress = ways.contains(.jetkvm) ? "kvm.example.invalid" : nil
        e.kind = e.hasScreenSharing ? nil : .terminal
        return e
    }

    /// Claim 1: a tap on the name opens the computer in its default way: Terminal and JetKVM on their own screens with
    /// no Glass Act session, Screen Sharing by starting the session in Whole Screen.
    func testNameOpensTheDefault() {
        var e = computer("Guest Mac Mini", [.screenSharing, .terminal, .jetkvm])
        var started: [(String, SessionView)] = []
        ComputerNav.shared.startScreenSharing = { e, v in started.append((e.id, v)) }
        for way in WayIn.inThisBuild where way != .screenSharing {
            e.opensIn = way
            ComputerNav.shared.openDefault(e)
            XCTAssertEqual(ComputerNav.shared.way, way)
            XCTAssertEqual(ComputerNav.shared.openID, e.id)
        }
        XCTAssertTrue(started.isEmpty, "no Glass Act session for Terminal or JetKVM")
        e.opensIn = .screenSharing
        ComputerNav.shared.openDefault(e)
        XCTAssertEqual(started.map(\.0), [e.id])
        XCTAssertEqual(started.first?.1, .regular, "Whole Screen, as from its icon")
        XCTAssertNil(ComputerNav.shared.openID)
    }

    /// Claim 2: Opens In starts as the Start With way, is kept on disk, and does not move when another way in is added
    /// to the computer later (JetKVM first, then Terminal, though Terminal comes first in the columns).
    func testDefaultFollowsStartWith() {
        let s = store()
        var kvm = computer("Guest PC", [.jetkvm])
        kvm.screenSharing = false
        s.addNew(kvm, startWith: .jetkvm)
        s.update(kvm.id) { $0.terminal = true; $0.sshUser = "guest" }
        let mac = computer("Studio Mac", [.screenSharing])
        s.addNew(mac, startWith: .screenSharing)
        let reloaded = store()
        XCTAssertEqual(reloaded.entry(kvm.id)?.opensIn, .jetkvm)
        XCTAssertEqual(reloaded.entry(mac.id)?.opensIn, .screenSharing)
        #if DUO_JETKVM
        XCTAssertEqual(reloaded.entry(kvm.id)?.defaultWay, .jetkvm)
        #endif
        XCTAssertEqual(reloaded.entry(mac.id)?.defaultWay, .screenSharing)
    }

    /// Claim 3: computers already in the list (no Opens In saved) get one: Screen Sharing if set up, else Terminal,
    /// else JetKVM. Read from the list's own file, as an older build wrote it.
    func testOldComputersGetADefault() throws {
        let json = """
        [{"id":"A1","name":"Old Mac","home":"192.0.2.1","port":4433,"layout":"standard","terminal":true,"sshUser":"m","jetkvm":true,"jetkvmAddress":"192.0.2.2"},
         {"id":"A2","name":"Old Server","tailscale":"192.0.2.3","port":22,"layout":"standard","kind":"terminal"},
         {"id":"A3","name":"Old PC","port":4433,"layout":"standard","kind":"terminal","screenSharing":false,"terminal":false,"jetkvm":true,"jetkvmAddress":"192.0.2.4"}]
        """
        try Data(json.utf8).write(to: dir.appendingPathComponent("macs.json"))
        let s = store()
        XCTAssertNil(s.entry("A1")?.opensIn, "nothing written for it")
        XCTAssertEqual(s.entry("A1")?.defaultWay, .screenSharing)
        #if DUO_TERMINAL
        XCTAssertEqual(s.entry("A2")?.defaultWay, .terminal)
        #endif
        #if DUO_JETKVM
        XCTAssertEqual(s.entry("A3")?.defaultWay, .jetkvm)
        #endif
    }

    /// Claim 4: removing the default way in falls to the next that exists (column order, wrapping round), and that
    /// stays when the removed way in is added back.
    func testRemovingTheDefaultWay() {
        let s = store()
        let e = computer("Guest Mac Mini", [.screenSharing, .terminal, .jetkvm])
        s.addNew(e, startWith: .terminal)
        s.removeWay(.terminal, from: e.id)
        XCTAssertEqual(s.entry(e.id)?.opensIn, .jetkvm, "the next after Terminal")
        s.update(e.id) { $0.terminal = true }
        XCTAssertEqual(s.entry(e.id)?.opensIn, .jetkvm, "adding Terminal back does not move it")
        s.removeWay(.jetkvm, from: e.id)
        XCTAssertEqual(s.entry(e.id)?.opensIn, .screenSharing, "wraps round to Screen Sharing")
        s.removeWay(.terminal, from: e.id)
        XCTAssertEqual(s.entry(e.id)?.opensIn, .screenSharing, "removing another way in leaves it")
        // In a build without the chosen way's code, the name opens the next it can (nothing is rewritten).
        XCTAssertEqual(MacEntry.next(from: .jetkvm, in: [.screenSharing, .terminal]), .screenSharing)
        XCTAssertEqual(MacEntry.next(from: .terminal, in: [.screenSharing, .jetkvm]), .jetkvm)
        XCTAssertEqual(MacEntry.next(from: nil, in: [.terminal, .jetkvm]), .terminal)
    }

    // MARK: The light: one test per state

    /// Green: any way in reachable, also when another needs a sign-in or does not answer.
    func testLightGreen() {
        XCTAssertEqual(ComputerLight.of(screenSharing: .ready), .reachable)
        XCTAssertEqual(ComputerLight.of(ComputerReach.State.ready), .reachable)
        XCTAssertEqual(ComputerLight.combined([.notReachable, .needsSignIn("sign in needed"), .reachable]), .reachable)
        XCTAssertEqual(ComputerLight.reachable.color, .green)
        XCTAssertEqual(ComputerLight.reachable.label, "Reachable")
    }

    /// Yellow: the Host answers but wants something first (a sign-in, someone at the Mac, or it takes no new viewers),
    /// and no way in is green. Terminal and JetKVM are never yellow (a TCP connect cannot tell).
    func testLightYellow() {
        XCTAssertEqual(ComputerLight.of(screenSharing: .signInNeeded), .needsSignIn("sign in needed"))
        XCTAssertEqual(ComputerLight.of(screenSharing: .askOnMac), .needsSignIn("asks on the Mac"))
        XCTAssertEqual(ComputerLight.of(screenSharing: .closed), .needsSignIn("not taking new viewers"))
        XCTAssertEqual(ComputerLight.combined([.notReachable, .needsSignIn("asks on the Mac")]),
                       .needsSignIn("asks on the Mac"))
        XCTAssertEqual(ComputerLight.combined([.notChecked, .needsSignIn("sign in needed")]),
                       .needsSignIn("sign in needed"))
        XCTAssertEqual(ComputerLight.needsSignIn("sign in needed").color, .yellow)
        XCTAssertEqual(ComputerLight.needsSignIn("sign in needed").label, "Reachable, sign in needed")
    }

    /// Red: every way in checked and none answers (a different Mac's key counts as not reachable).
    func testLightRed() {
        XCTAssertEqual(ComputerLight.of(screenSharing: .notReachable), .notReachable)
        XCTAssertEqual(ComputerLight.of(screenSharing: .wrongMac), .notReachable)
        XCTAssertEqual(ComputerLight.of(ComputerReach.State.notReachable), .notReachable)
        XCTAssertEqual(ComputerLight.combined([.notReachable, .notReachable]), .notReachable)
        XCTAssertEqual(ComputerLight.notReachable.color, .red)
        XCTAssertEqual(ComputerLight.notReachable.label, "Not reachable")
    }

    /// Gray: not checked yet (or never: the simulator's Glass Act check of other hosts). Never red while a way in is
    /// still being checked.
    func testLightGrayNotYetChecked() {
        XCTAssertEqual(ComputerLight.of(screenSharing: nil), .notChecked)
        XCTAssertEqual(ComputerLight.of(screenSharing: .checking), .notChecked)
        XCTAssertEqual(ComputerLight.of(screenSharing: .notChecked), .notChecked)
        XCTAssertEqual(ComputerLight.of(ComputerReach.State.checking), .notChecked)
        XCTAssertEqual(ComputerLight.combined([.notReachable, .notChecked]), .notChecked)
        XCTAssertEqual(ComputerLight.notChecked.color, .gray)
        XCTAssertEqual(ComputerLight.notChecked.label, "Not checked yet")
        // The row reads the same checks as the icons: a fresh ComputerReach has checked nothing.
        let e = computer("New Mac", [.screenSharing, .terminal])
        XCTAssertEqual(ComputerLight.of(e, mac: nil, reach: ComputerReach()), .notChecked)
    }
}
