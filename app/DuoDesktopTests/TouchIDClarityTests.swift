import GlassActSession
import GlassActTransport
import LocalAuthentication
import XCTest
@testable import DuoDesktop
#if DUO_TERMINAL
import DuoTerminalKit
#endif

/// the Touch ID clarity change. Made-up Macs, keys, user names and words only.
@MainActor
final class TouchIDClarityTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "TouchIDClarityTests.\(UUID().uuidString)")
    }

    private func store(_ k: AutoUnlockTests.FakeKeychain) -> MacStore {
        let s = MacStore(url: dir.appendingPathComponent("macs.json"), defaults: defaults,
                         knownHosts: KnownHosts(url: dir.appendingPathComponent("known_hosts")))
        s.passwords = k
        s.add(MacEntry(name: "Studio Mac", tailscale: "studio.example-tailnet.ts.net"))
        s.add(MacEntry(name: "Office Mac", tailscale: "office.example-tailnet.ts.net"))
        s.add(MacEntry(name: "Laptop", tailscale: "laptop.example-tailnet.ts.net"))
        return s
    }

    // MARK: 1. Touch ID and automatic unlock

    /// Claim: what blocks Unlock Automatically, in order: no passcode first, then Require Touch ID off.
    func testBlocker() {
        XCTAssertEqual(AutoUnlockRules.blocker(appLockOn: true, deviceCanAuthenticate: false), .noPasscode)
        XCTAssertEqual(AutoUnlockRules.blocker(appLockOn: false, deviceCanAuthenticate: false), .noPasscode)
        XCTAssertEqual(AutoUnlockRules.blocker(appLockOn: false, deviceCanAuthenticate: true), .appLockOff)
        XCTAssertNil(AutoUnlockRules.blocker(appLockOn: true, deviceCanAuthenticate: true))
        XCTAssertTrue(AutoUnlockRules.footer.hasPrefix("Needs Require Touch ID"))
        XCTAssertTrue(AutoUnlockRules.securityFooter.contains("Terminal and JetKVM wait for it after 5 minutes away"))
    }

    /// Claim: turning Require Touch ID off warns only when a Mac uses Unlock Automatically, names those Macs, and
    /// then deletes every saved Mac password and turns each switch off; other Macs are untouched.
    func testLockOffWarnsAndDeletesPasswords() {
        let k = AutoUnlockTests.FakeKeychain()
        let s = store(k)
        XCTAssertNil(AutoUnlockRules.lockOffWarning(s.macs), "no Mac uses it: no warning")
        let studio = s.macs.first { $0.name == "Studio Mac" }!.id, office = s.macs.first { $0.name == "Office Mac" }!.id
        XCTAssertTrue(AutoUnlockSetting.turnOn("made-up-1", macID: studio, store: s, keychain: k, defaults: defaults))
        XCTAssertTrue(AutoUnlockSetting.turnOn("made-up-2", macID: office, store: s, keychain: k, defaults: defaults))
        let w = AutoUnlockRules.lockOffWarning(s.macs) ?? ""
        XCTAssertTrue(w.contains("“Studio Mac”") && w.contains("“Office Mac”") && !w.contains("Laptop"), w)
        XCTAssertTrue(w.contains("stop unlocking automatically") && w.contains("deleted"), w)

        AutoUnlockSetting.appLockTurnedOff(store: s, keychain: k, defaults: defaults)
        XCTAssertTrue(k.items.isEmpty, "every saved Mac password deleted")
        XCTAssertTrue(s.macs.allSatisfy { $0.autoUnlock == nil }, "every switch off")
        XCTAssertNil(AutoUnlockRules.lockOffWarning(s.macs))
    }

    /// Claim: the app lock's own switch. Off → on runs the system's check; success turns it on and stores it.
    func testTurnOnRequireTouchIDRunsTheCheck() async {
        var asked: [String] = []
        defaults.set(false, forKey: AppLock.settingKey)
        let lock = AppLock(defaults: defaults) { reason in asked.append(reason); return .success(nil) }
        XCTAssertFalse(lock.required)
        await lock.setRequired(true)
        XCTAssertTrue(lock.required)
        XCTAssertEqual(asked.count, 1, "the system's Touch ID check ran once")
        XCTAssertTrue(AppLock.isOn(in: defaults))
    }

    // MARK: A. Home network address

    private func host(_ name: String, _ h: String) -> NearbyHost { NearbyHost(name: name, host: h, port: 4433, isLaptop: false) }

    /// Claim: the Mac whose key matches is marked and listed first; a different key is never saved; an unknown key
    /// (still checking, or the entry has none yet) may be saved.
    func testHomeAddressMatchAndOrder() {
        let a = host("Alpha", "Alpha.local"), b = host("Bravo", "Bravo.local"), c = host("Charlie", "Charlie.local")
        let keys = ["Alpha": "key-a", "Charlie": "key-c"]
        XCTAssertEqual(HomeAddressRules.ordered([a, b, c], keys: keys, entryKey: "key-c").map(\.name),
                       ["Charlie", "Alpha", "Bravo"])
        XCTAssertEqual(HomeAddressRules.ordered([c, b, a], keys: keys, entryKey: nil).map(\.name),
                       ["Alpha", "Bravo", "Charlie"])
        XCTAssertEqual(HomeAddressRules.match(entryKey: "key-c", foundKey: "key-c"), .thisMac)
        XCTAssertEqual(HomeAddressRules.match(entryKey: "key-c", foundKey: "key-a"), .otherMac)
        XCTAssertEqual(HomeAddressRules.match(entryKey: "key-c", foundKey: nil), .unknown)
        XCTAssertFalse(HomeAddressRules.maySave(entryKey: "key-c", foundKey: "key-a"))
        XCTAssertTrue(HomeAddressRules.maySave(entryKey: "key-c", foundKey: "key-c"))
        XCTAssertTrue(HomeAddressRules.maySave(entryKey: nil, foundKey: "key-a"))
        XCTAssertTrue(HomeAddressRules.otherMacText(found: "Alpha", entry: "Charlie").contains("not saved"))
    }

    /// Claim: placeholders and help name no real Mac (the made-up "My-Mac" only).
    func testPlaceholdersAreMadeUp() {
        XCTAssertEqual(HomeAddressRules.homePlaceholder, "My-Mac.local")
        XCTAssertTrue(HomeAddressRules.typeFooter.contains("System Settings › General › Sharing › Local hostname"))
        XCTAssertTrue(HomeAddressRules.nothingNearby.contains("same Wi"))
    }

    #if DUO_TERMINAL
    // MARK: B. SSH user name

    /// Claim: a typed name different from the Host's account warns, in place, with the order's words; same or empty
    /// does not; no Host report, no warning.
    func testSSHUserWarning() {
        XCTAssertEqual(SSHUserRules.warning(typed: "someone-else", hostUser: "studio"),
                       "The Host on this Mac runs as studio. Terminal signs in as that user unless Remote Login allows someone-else.")
        XCTAssertNil(SSHUserRules.warning(typed: "studio", hostUser: "studio"))
        XCTAssertNil(SSHUserRules.warning(typed: nil, hostUser: "studio"))
        XCTAssertNil(SSHUserRules.warning(typed: "someone-else", hostUser: ""))
    }

    /// Claim: a failed sign-in is told apart: wrong user name, key not installed, key refused, Remote Login off,
    /// not reachable.
    func testTerminalProblemDiagnosis() {
        let installed = TerminalKeyState(answer: .installed, user: "studio")
        XCTAssertEqual(TerminalProblem.diagnose(.signInRefused, user: "someone-else", host: "h", keyState: installed),
                       .wrongUser(typed: "someone-else", hostUser: "studio"))
        XCTAssertEqual(TerminalProblem.diagnose(.signInRefused, user: "studio", host: "h", keyState: installed),
                       .keyRefused(user: "studio"))
        XCTAssertEqual(TerminalProblem.diagnose(.signInRefused, user: "studio", host: "h", keyState: nil), .keyNotInstalled)
        XCTAssertEqual(TerminalProblem.diagnose(.signInRefused, user: "studio", host: "h",
                                                keyState: TerminalKeyState(answer: .olderHost)), .keyNotInstalled)
        XCTAssertEqual(TerminalProblem.diagnose(.connectionRefused, user: "studio", host: "h", keyState: installed),
                       .remoteLoginOff)
        XCTAssertEqual(TerminalProblem.diagnose(.notReachable, user: "studio", host: "h",
                                                keyState: TerminalKeyState(answer: .installed, remoteLoginOn: false)),
                       .remoteLoginOff)
        XCTAssertEqual(TerminalProblem.diagnose(.notReachable, user: "studio", host: "h", keyState: installed),
                       .notReachable(host: "h"))
        let wrong = TerminalProblem.wrongUser(typed: "someone-else", hostUser: "studio")
        XCTAssertTrue(wrong.text.hasPrefix("Wrong user name"))
        XCTAssertTrue(wrong.opensSettings && !wrong.retries)
        XCTAssertTrue(TerminalProblem.remoteLoginOff.retries && !TerminalProblem.remoteLoginOff.opensSettings)
    }
    #endif
}
