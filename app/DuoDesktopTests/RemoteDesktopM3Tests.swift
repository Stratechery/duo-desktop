// Milestone 3 of the Remote Desktop plan (sign-in, trust, saved passwords, reconnect), proven without a PC:
// one test per claim, made-up PCs, passwords and certificates. No PC is contacted (the one network test connects to
// this simulator's own closed port and to a name that cannot exist). No password is ever printed.
import GlassActTransport
import LocalAuthentication
import Security
import XCTest
@testable import DuoDesktop

final class RemoteDesktopM3Tests: XCTestCase {

    final class Passwords: RDPPasswordKeeping {
        var items: [String: String] = [:]
        func save(_ password: String, pcID: String) -> Bool { items[pcID] = password; return true }
        func delete(pcID: String) { items[pcID] = nil }
        func deleteAll() { items = [:] }
        func read(pcID: String, context: LAContext) -> String? { items[pcID] }
    }

    private func pc(_ name: String = "Windows PC") -> MacEntry {
        var e = MacEntry(name: name)
        e.screenSharing = false
        e.remoteDesktop = true
        e.rdpUser = "someone"
        e.set(.tailscale, "pc.example.invalid")
        return e
    }

    @MainActor private func store() throws -> MacStore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let list = dir.appendingPathComponent("macs.json")
        try Data("[]".utf8).write(to: list)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "m3-\(UUID().uuidString)"))
        return MacStore(url: list, defaults: defaults, knownHosts: KnownHosts(url: dir.appendingPathComponent("kh")))
    }

    /// Claim: the saved password is a Keychain item of its own, this device only, never synced, behind user
    /// presence (read only with the app lock's context), and never in the stored list.
    func testPasswordItemIsThisDeviceOnlyBehindTheLock() throws {
        let q = try XCTUnwrap(RDPPasswordKeychain.addAttributes("made-up", pcID: "pc-1"))
        XCTAssertEqual(q[kSecAttrService as String] as? String, "com.example.duodesktop.rdp-password")
        XCTAssertNotEqual(RDPPasswordKeychain.service, MacPasswordKeychain.service)
        XCTAssertEqual(q[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertNotNil(q[kSecAttrAccessControl as String], "user presence access control")
        XCTAssertNil(q[kSecAttrAccessible as String], "accessibility is inside the access control")
        let json = String(data: try JSONEncoder().encode(pc()), encoding: .utf8) ?? ""
        XCTAssertFalse(json.lowercased().contains("password\":\""), "no password field in the stored list")
    }

    /// Claim: Remember Password is on by default; a password is saved only when it was typed, Windows accepted it,
    /// Remember Password is on and the app lock is on; with the lock off nothing is read.
    func testRememberPasswordRules() {
        var e = pc()
        XCTAssertTrue(RDPSignIn.rememberOn(e))
        XCTAssertTrue(RDPSignIn.shouldSave(typed: true, accepted: true, remember: true, appLockOn: true))
        XCTAssertFalse(RDPSignIn.shouldSave(typed: true, accepted: false, remember: true, appLockOn: true))
        XCTAssertFalse(RDPSignIn.shouldSave(typed: true, accepted: true, remember: false, appLockOn: true))
        XCTAssertFalse(RDPSignIn.shouldSave(typed: true, accepted: true, remember: true, appLockOn: false))
        let p = Passwords()
        p.items[e.id] = "made-up"
        XCTAssertEqual(RDPSignIn.saved(for: e, context: LAContext(), passwords: p), "made-up")
        XCTAssertNil(RDPSignIn.saved(for: e, context: nil, passwords: p), "no app lock context: not read")
        e.rdpRememberPassword = false
        XCTAssertNil(RDPSignIn.saved(for: e, context: LAContext(), passwords: p), "Remember Password off: not read")
    }

    /// Claim: removing the PC (or its Remote Desktop) deletes its saved password, and turning the app lock off
    /// deletes every PC's.
    @MainActor func testSavedPasswordGoesWithThePCAndTheLock() throws {
        let s = try store()
        let p = Passwords()
        s.rdpPasswords = p
        let a = pc("PC A"), b = pc("PC B")
        s.add(a); s.add(b)
        p.items = [a.id: "made-up-a", b.id: "made-up-b"]
        s.remove(a.id)
        XCTAssertNil(p.items[a.id])
        XCTAssertNotNil(p.items[b.id])
        AutoUnlockSetting.appLockTurnedOff(store: s)
        XCTAssertTrue(p.items.isEmpty)
    }

    /// Claim: the PIN rule: a wrong password says to use the account's password, not the Windows Hello PIN.
    func testWrongPasswordSaysThePINRule() {
        let w = RDPFailure.words(.wrongPassword, name: "Windows PC", port: 3389)
        XCTAssertTrue(w.contains("not the Windows Hello PIN"))
        XCTAssertTrue(w.contains("Microsoft account"))
    }

    /// Claim: plain failure words: wrong password, account not allowed, Remote Desktop off (the PC refuses the port),
    /// not reachable (no answer or unknown name).
    func testFailureKinds() {
        let c = { (t: UInt32) in (UInt32(2) << 16) | t }
        XCTAssertEqual(RDPFailure.kind(code: c(0x15), refusedChange: false) { .open }, .wrongPassword)
        XCTAssertEqual(RDPFailure.kind(code: c(0x14), refusedChange: false) { .open }, .wrongPassword)
        XCTAssertEqual(RDPFailure.kind(code: c(0x16), refusedChange: false) { .open }, .notAllowed)
        XCTAssertEqual(RDPFailure.kind(code: c(0x1A), refusedChange: false) { .open }, .notAllowed)
        XCTAssertEqual(RDPFailure.kind(code: c(0x0D), refusedChange: false) { .refused }, .remoteDesktopOff)
        XCTAssertEqual(RDPFailure.kind(code: c(0x06), refusedChange: false) { .unreachable }, .notReachable)
        XCTAssertEqual(RDPFailure.kind(code: c(0x05), refusedChange: false) { XCTFail("no probe"); return .open },
                       .notReachable)
        XCTAssertTrue(RDPFailure.words(.remoteDesktopOff, name: "Windows PC", port: 3389).contains("Remote Desktop is off"))
        XCTAssertTrue(RDPFailure.words(.notReachable, name: "Windows PC", port: 3389).contains("not reachable"))
        XCTAssertTrue(RDPFailure.words(.notAllowed, name: "Windows PC", port: 3389).contains("not allowed"))
    }

    /// Claim: the probe tells a refused port (Remote Desktop off) from a name that does not answer (not reachable).
    /// Only this simulator's own closed port and a reserved name that cannot exist are tried.
    func testReachProbe() {
        XCTAssertEqual(RDPReach.probe(host: "127.0.0.1", port: 1, timeout: 3), .refused)
        XCTAssertEqual(RDPReach.probe(host: "no-such-pc.invalid", port: 3389, timeout: 3), .unreachable)
    }

    /// Claim: the full trust prompt names the PC, its address and the fingerprint; a changed certificate is refused in
    /// plain words that point to Forget Certificate; after Forget Certificate the app asks again.
    func testTrustPromptChangedAndForget() {
        let fp = "AB:CD:EF"
        let t = RDPTrust.firstUseText(name: "Windows PC", address: "pc.example.invalid", fingerprint: fp)
        XCTAssertTrue(t.contains("Windows PC") && t.contains("pc.example.invalid") && t.contains("SHA-256\n" + fp))
        var e = pc()
        e.rdpCertificate = fp
        XCTAssertEqual(RDPTrust.decide(saved: e.rdpCertificate, presented: "11:22"), .changed(fingerprint: "11:22"))
        XCTAssertEqual(RDPFailure.kind(code: 0, refusedChange: true) { .open }, .certificateChanged)
        XCTAssertTrue(RDPFailure.words(.certificateChanged, name: "Windows PC", port: 3389).contains("Forget Certificate"))
        e.rdpCertificate = nil  // Forget Certificate
        XCTAssertEqual(RDPTrust.decide(saved: e.rdpCertificate, presented: "11:22"), .askFirstTime(fingerprint: "11:22"))
    }

    /// Claim: coming back from the background reconnects with no prompt (no password, no takeover notice) when the
    /// password is to hand, held by the open screen or saved; else it asks; nothing happens if nothing was live.
    func testReturnReconnectsWithoutPrompt() {
        XCTAssertEqual(RDPReturn.onReturn(wasLive: true, held: "made-up", saved: { nil }), .reconnect(password: "made-up"))
        XCTAssertEqual(RDPReturn.onReturn(wasLive: true, held: nil, saved: { "made-up-2" }), .reconnect(password: "made-up-2"))
        XCTAssertEqual(RDPReturn.onReturn(wasLive: true, held: nil, saved: { nil }), .askPassword)
        XCTAssertEqual(RDPReturn.onReturn(wasLive: false, held: "made-up", saved: { "x" }), .nothing)
        XCTAssertFalse(RDPSignIn.asksTakeover(skip: false, resuming: true))
        XCTAssertTrue(RDPSignIn.asksTakeover(skip: false, resuming: false))
        XCTAssertFalse(RDPSignIn.asksTakeover(skip: true, resuming: false))
    }
}
