import GlassActTransport
import XCTest
@testable import DuoDesktop

/// The owner 2026-11-21: "The outside screen should be connected to the same Mac as the inside screen."
@MainActor
final class WrongMacTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "WrongMacTests.\(UUID().uuidString)")
    }

    private func store() -> MacStore {
        let s = MacStore(url: dir.appendingPathComponent("macs.json"), defaults: defaults,
                         knownHosts: KnownHosts(url: dir.appendingPathComponent("known_hosts")))
        // Made-up Macs: the app starts with none (no Mac is built in).
        for name in ["my-mac", "other-mac"] where !s.macs.contains(where: { $0.name == name }) {
            s.add(MacEntry(name: name, tailscale: "\(name).example-tailnet.ts.net"))
        }
        return s
    }

    /// Claim: "last Mac" follows every successful connect: Mac A then Mac B reads back B, whoever started it.
    func testConnectAThenBRemembersB() throws {
        let s = store()
        let a = try XCTUnwrap(s.macs.first { $0.name == "my-mac" })
        let b = try XCTUnwrap(s.macs.first { $0.name == "other-mac" })
        let model = SessionModel(store: s)
        model.lastMacDefaults = defaults
        model.connect(to: a)
        model.phase = .inSession
        XCTAssertEqual(defaults.string(forKey: LastMac.key), a.id)
        model.disconnect()
        model.connect(to: b)
        XCTAssertEqual(defaults.string(forKey: LastMac.key), a.id, "not stored until the connect succeeds")
        model.phase = .inSession
        XCTAssertEqual(LastMac.find(in: s.macs, d: defaults)?.id, b.id)
        model.disconnect()
    }

    /// Claim: the outer screen's cold open never replaces the Mac the session holds (kept picture after the fold,
    /// phase idle) with a remembered one; with no Mac in the session it goes to the remembered Mac.
    func testColdOpenNeverReplacesTheSessionsMac() throws {
        let s = store()
        let agents = try XCTUnwrap(s.macs.first { $0.name == "my-mac" })
        let otherMac = try XCTUnwrap(s.macs.first { $0.name == "other-mac" })
        LastMac.store(agents, in: defaults)
        XCTAssertNil(LastMac.coldTarget(sessionMac: otherMac, idle: true, macs: s.macs, d: defaults))
        XCTAssertNil(LastMac.coldTarget(sessionMac: nil, idle: false, macs: s.macs, d: defaults))
        // More than one Mac: no guess (the outer screen shows the list). One Mac: that one.
        XCTAssertNil(LastMac.coldTarget(sessionMac: nil, idle: true, macs: s.macs, d: defaults))
        XCTAssertEqual(LastMac.coldTarget(sessionMac: nil, idle: true, macs: [otherMac], d: defaults)?.id,
                       otherMac.id)
    }

    /// Claim: the app has one session, so every window (either screen) shows the same Mac.
    func testOneSessionForTheApp() {
        XCTAssertTrue(SessionModel.app === SessionModel.app)
    }
}
