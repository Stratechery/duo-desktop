// Milestone 1 of project notes, proven without a PC: one test per claim. No connection is made.
import XCTest
@testable import DuoDesktop
#if DUO_RDP
import FreeRDP
#endif

final class RemoteDesktopM1Tests: XCTestCase {

    private func pc() -> MacEntry {
        var e = MacEntry(name: "Windows PC")
        e.screenSharing = false
        e.remoteDesktop = true
        e.rdpUser = "someone"
        e.set(.tailscale, "pc.example.ts.net")
        return e
    }

    /// Claim: the default session is 1920 x 1080 with text at 200% (the owner 2026-11-23: "yes 1080p at 200%"); 150% is
    /// still a choice; the device scale sent with 200% is the spec's 180 step.
    func testDefaultSessionIs1080pAt200() {
        let s = pc().rdpScreen
        XCTAssertEqual([s.width, s.height, s.desktopScale, s.deviceScale], [1920, 1080, 200, 180])
        XCTAssertTrue(RDPScreen.TextSize.allCases.contains(.p150))
    }

    /// Claim: a PC fills the Screen Sharing slot but never reaches Glass Act (`macs`), and its list check is a TCP
    /// connect to 3389 at its address.
    func testPCIsScreenSharingSlotButNotGlassAct() {
        let e = pc()
        XCTAssertTrue(e.waysIn.contains(.screenSharing))
        XCTAssertFalse(e.hasScreenSharing)
        let t = ComputerReach.target(e, .screenSharing)
        XCTAssertEqual(t?.host, "pc.example.ts.net")
        XCTAssertEqual(t?.port, 3389)
        XCTAssertNil(ComputerReach.target(MacEntry(name: "Mac"), .screenSharing))
    }

    /// Claim: trust on first use: ask the first time, connect to the same certificate, refuse a different one.
    func testCertificateTrustOnFirstUse() {
        XCTAssertEqual(RDPTrust.decide(saved: nil, presented: "AA:BB"), .askFirstTime(fingerprint: "AA:BB"))
        XCTAssertEqual(RDPTrust.decide(saved: "aa:bb", presented: "AA:BB"), .known)
        XCTAssertEqual(RDPTrust.decide(saved: "AA:BB", presented: "CC:DD"), .changed(fingerprint: "CC:DD"))
        // PEM is hashed over its DER bytes: the bytes 01 02 03 give SHA-256 039058C6...
        let pem = "-----BEGIN CERTIFICATE-----\nAQID\n-----END CERTIFICATE-----\n"
        XCTAssertTrue(RDPTrust.fingerprint(fromFreeRDP: pem, isPEM: true).hasPrefix("03:90:58:C6"))
    }

    #if DUO_RDP
    /// Claim: the session settings FreeRDP is given ask Windows for that size and scale, NLA, one monitor.
    func testFreeRDPSettingsCarryTheSession() throws {
        let inst = try XCTUnwrap(freerdp_new())
        defer { freerdp_context_free(inst); freerdp_free(inst) }
        inst.pointee.ContextSize = MemoryLayout<rdpContext>.size
        XCTAssertTrue(freerdp_context_new(inst))
        let st = inst.pointee.context.pointee.settings
        let e = pc()
        XCTAssertTrue(RemoteDesktopSession.apply(.init(host: "pc.example.ts.net", port: 3389, user: "someone",
                                                       password: "x", screen: e.rdpScreen, savedCertificate: nil),
                                                 to: st))
        XCTAssertEqual(freerdp_settings_get_uint32(st, FreeRDP_DesktopWidth), 1920)
        XCTAssertEqual(freerdp_settings_get_uint32(st, FreeRDP_DesktopHeight), 1080)
        XCTAssertEqual(freerdp_settings_get_uint32(st, FreeRDP_DesktopScaleFactor), 200)
        XCTAssertEqual(freerdp_settings_get_uint32(st, FreeRDP_DeviceScaleFactor), 180)
        XCTAssertEqual(freerdp_settings_get_uint32(st, FreeRDP_ServerPort), 3389)
        XCTAssertTrue(freerdp_settings_get_bool(st, FreeRDP_NlaSecurity))
        XCTAssertFalse(freerdp_settings_get_bool(st, FreeRDP_UseMultimon))
    }
    #endif
}
