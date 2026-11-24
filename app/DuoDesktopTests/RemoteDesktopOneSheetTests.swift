// -11-23: one test per claim. Made-up computers; no connection. (A PC added through the one sheet is saved by
// `RDPForm.add`, the call the sheet makes: RemoteDesktopAddTests.testAddSavesPCWithDefaults. The sync claims are in
// ListSyncTests.)
import GlassActTransport
import XCTest
@testable import DuoDesktop

@MainActor
final class RemoteDesktopOneSheetTests: XCTestCase {
    private var dir: URL!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("RemoteDesktopOneSheet-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    private func store() -> MacStore {
        MacStore(url: dir.appendingPathComponent("macs.json"),
                 defaults: UserDefaults(suiteName: "RemoteDesktopOneSheet.\(UUID().uuidString)")!,
                 knownHosts: KnownHosts(url: dir.appendingPathComponent("known_hosts")))
    }

    /// Claim: Start With lists Remote Desktop, beside Screen Sharing, only in a Remote Desktop build; otherwise it lists
    /// exactly the ways in the build has, as before.
    func testStartWithListsRemoteDesktopOnlyInRemoteDesktopBuilds() {
        let ways = WayIn.inThisBuild.map(AddWay.init)
        #if DUO_RDP
        XCTAssertTrue(RDPScreen.inThisBuild)
        XCTAssertEqual(AddWay.inThisBuild, [ways[0], .remoteDesktop] + ways.dropFirst())
        #else
        XCTAssertEqual(AddWay.inThisBuild, ways)
        XCTAssertFalse(AddWay.inThisBuild.contains(.remoteDesktop))
        #endif
        XCTAssertEqual(AddWay.remoteDesktop.label, "Remote Desktop")
        XCTAssertEqual(AddWay.remoteDesktop.slot, .screenSharing)
    }

    /// Claim: Remote Desktop can be added to an existing computer (here one with a JetKVM) as one more way in; its
    /// name, other ways in and Opens In stay. A PC can gain the other ways in. The slot is one or the other: a Mac with
    /// Glass Act's Screen Sharing is never also read as a PC. A PC's slot is called Remote Desktop on its ⓘ page.
    func testRemoteDesktopAddedToExistingComputer() throws {
        let s = store()
        var kvm = MacEntry(name: "Tower")
        kvm.screenSharing = false
        kvm.terminal = false
        kvm.jetkvm = true
        kvm.jetkvmAddress = "tower-kvm.example.invalid"
        s.addNew(kvm, startWith: .jetkvm)

        var f = RDPForm(try XCTUnwrap(s.entry(kvm.id)))
        f.address = "tower"
        f.user = "someone"
        f.name = "Tower"
        XCTAssertNil(f.problem)
        s.update(kvm.id) { f.addWay(to: &$0) }
        var e = try XCTUnwrap(s.entry(kvm.id))
        XCTAssertEqual(e.name, "Tower")
        XCTAssertTrue(e.hasRemoteDesktop)
        XCTAssertFalse(e.hasScreenSharing)
        XCTAssertEqual(e.setUpWays, [.screenSharing, .jetkvm])
        XCTAssertEqual(e.opensIn, .jetkvm, "adding a way in does not change Opens In")
        XCTAssertEqual([e.tailscale, e.rdpUser, e.jetkvmAddress], ["tower", "someone", "tower-kvm.example.invalid"])
        XCTAssertEqual(e.rdpScreen, RDPScreen(size: .hd1080, textSize: .p200))
        XCTAssertFalse(s.macs.contains { $0.id == kvm.id }, "never in Glass Act's list")
        XCTAssertEqual(e.label(.screenSharing), "Remote Desktop")
        XCTAssertEqual(e.label(.jetkvm), "JetKVM")

        // A PC gains the Terminal.
        s.update(kvm.id) { $0.terminal = true; $0.sshUser = "someone" }
        e = try XCTUnwrap(s.entry(kvm.id))
        XCTAssertEqual(e.setUpWays, [.screenSharing, .terminal, .jetkvm])
        XCTAssertTrue(e.hasRemoteDesktop)

        // One or the other: Glass Act's Screen Sharing on the same slot is a Mac, not a PC.
        var mac = e
        mac.screenSharing = true
        XCTAssertFalse(mac.hasRemoteDesktop)
        XCTAssertEqual(mac.label(.screenSharing), "Screen Sharing")
    }
}
