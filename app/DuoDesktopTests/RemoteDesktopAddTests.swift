// -11-23: one test per claim. Made-up PC; no connection is made.
import GlassActTransport
import XCTest
@testable import DuoDesktop

@MainActor
final class RemoteDesktopAddTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteDesktopAddTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func store() -> MacStore {
        MacStore(url: dir.appendingPathComponent("macs.json"),
                 defaults: UserDefaults(suiteName: "RemoteDesktopAddTests.\(UUID().uuidString)")!,
                 knownHosts: KnownHosts(url: dir.appendingPathComponent("known_hosts")))
    }

    private func filled() -> RDPForm {
        var f = RDPForm()
        f.name = "Windows PC"
        f.address = "windows-pc"
        f.user = "someone"
        return f
    }

    /// Claim: a PC added through the sheet's model is saved as a Remote Desktop PC (the Screen Sharing slot's
    /// `remoteDesktop`, never Glass Act) with the defaults: port 3389, 1920 x 1080, text at 200%, the notice asked.
    func testAddSavesPCWithDefaults() throws {
        let s = store()
        let id = try XCTUnwrap(filled().add(to: s))
        let e = try XCTUnwrap(s.entry(id))
        XCTAssertTrue(e.hasRemoteDesktop)
        XCTAssertFalse(e.hasScreenSharing)
        XCTAssertFalse(s.macs.contains { $0.id == id })  // never reaches Glass Act
        XCTAssertEqual(s.computers.contains { $0.id == id }, RDPScreen.inThisBuild)
        XCTAssertEqual(e.opensIn, .screenSharing)
        XCTAssertEqual(e.waysIn, [.screenSharing])
        XCTAssertEqual([e.name, e.tailscale, e.rdpUser], ["Windows PC", "windows-pc", "someone"])
        XCTAssertEqual(e.rdpPortValue, 3389)
        XCTAssertEqual(e.rdpScreen, RDPScreen(size: .hd1080, textSize: .p200))
        XCTAssertNotEqual(e.rdpSkipTakeover, true)
        // And it is still there after the app starts again.
        XCTAssertEqual(store().entry(id)?.rdpUser, "someone")
    }

    /// Claim: edits (as the ⓘ page saves them) change the fields, and Remove takes the PC out of the list.
    func testEditAndRemove() throws {
        let s = store()
        let id = try XCTUnwrap(filled().add(to: s))
        var f = RDPForm(try XCTUnwrap(s.entry(id)))
        f.address = "pc.local"
        f.port = "3390"
        f.user = "other"
        f.size = .qhd1440
        f.textSize = .p125
        s.update(id) { f.apply(to: &$0) }
        s.update(id) { $0.rdpSkipTakeover = true }
        let e = try XCTUnwrap(s.entry(id))
        XCTAssertNil(e.tailscale)
        XCTAssertEqual(e.home, "pc.local")
        XCTAssertEqual(e.rdpPortValue, 3390)
        XCTAssertEqual(e.rdpUser, "other")
        XCTAssertEqual(e.rdpScreen, RDPScreen(size: .qhd1440, textSize: .p125))
        XCTAssertEqual(e.rdpSkipTakeover, true)
        XCTAssertTrue(e.hasRemoteDesktop)
        s.remove(id)
        XCTAssertNil(s.entry(id))
        XCTAssertNil(store().entry(id))
    }

    /// Claim: a missing address or user name (or name) cannot be saved, and nothing is added.
    func testMissingAddressOrUserCannotBeSaved() {
        let s = store()
        var noAddress = filled(); noAddress.address = "  "
        var noUser = filled(); noUser.user = ""
        var noName = filled(); noName.name = ""
        XCTAssertEqual(noAddress.problem, "Type the PC’s address.")
        XCTAssertEqual(noUser.problem, "Type the user name to sign in as.")
        XCTAssertEqual(noName.problem, "Type a name.")
        let before = s.entries.count
        XCTAssertNil(noAddress.add(to: s))
        XCTAssertNil(noUser.add(to: s))
        XCTAssertEqual(s.entries.count, before)
        XCTAssertNil(filled().problem)
    }

    #if DUO_RDP
    /// Claim: the PC's settings reach the session's connect request: port, user, Size and Text Size (desktop and
    /// device scale), read from the saved PC at connect time, so a change applies at the next connect.
    func testSettingsReachConnectRequest() throws {
        let s = store()
        let id = try XCTUnwrap(filled().add(to: s))
        let first = RemoteDesktopSession.Target(try XCTUnwrap(s.entry(id)), host: "windows-pc", password: "x")
        XCTAssertEqual([first.screen.width, first.screen.height, first.screen.desktopScale, first.screen.deviceScale],
                       [1920, 1080, 200, 180])
        s.update(id) { $0.rdpSize = .hd720; $0.rdpTextSize = .p150; $0.rdpPort = 3390; $0.rdpUser = "other" }
        let next = RemoteDesktopSession.Target(try XCTUnwrap(s.entry(id)), host: "windows-pc", password: "x")
        XCTAssertEqual([next.screen.width, next.screen.height, next.screen.desktopScale, next.screen.deviceScale],
                       [1280, 720, 150, 140])
        XCTAssertEqual(next.port, 3390)
        XCTAssertEqual(next.user, "other")
    }
    #endif
}
