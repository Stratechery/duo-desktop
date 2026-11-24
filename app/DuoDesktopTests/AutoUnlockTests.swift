import GlassActTransport
import GlassActWire
import LocalAuthentication
import Security
import XCTest
@testable import DuoDesktop

/// Project notes. Every password here is a made-up word; no real password is used or printed.
@MainActor
final class AutoUnlockTests: XCTestCase {
    /// A made-up word, never a real password.
    private let word = "pretend-word-42"
    private var dir: URL!
    private var defaults: UserDefaults!

    /// The Keychain stand-in: what was stored per Mac.
    final class FakeKeychain: MacPasswordKeeping {
        var items: [String: Data] = [:]
        var reads = 0
        var readFails = false
        func save(_ password: Data, macID: String) -> Bool { items[macID] = password; return true }
        func delete(macID: String) { items[macID] = nil }
        func read(macID: String, context: LAContext) -> Data? { reads += 1; return readFails ? nil : items[macID] }
        func has(macID: String) -> Bool { items[macID] != nil }
    }

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "AutoUnlockTests.\(UUID().uuidString)")
    }

    private func store(_ keychain: FakeKeychain) -> (MacStore, MacEntry) {
        let s = MacStore(url: dir.appendingPathComponent("macs.json"), defaults: defaults,
                         knownHosts: KnownHosts(url: dir.appendingPathComponent("known_hosts")))
        s.passwords = keychain
        s.add(MacEntry(name: "my-mac", tailscale: "my-mac.example-tailnet.ts.net"))
        return (s, s.macs.first { $0.name == "my-mac" }!)
    }

    // MARK: Keychain item rules

    /// Claim: the item is this device only, never synchronized, behind user presence, one per Mac.
    func testKeychainItemRules() throws {
        let q = try XCTUnwrap(MacPasswordKeychain.addAttributes(Data(word.utf8), macID: "mac-1"))
        XCTAssertEqual(q[kSecClass as String] as! CFString, kSecClassGenericPassword)
        XCTAssertEqual(q[kSecAttrAccount as String] as? String, "mac-1", "one item per Mac")
        XCTAssertEqual(q[kSecAttrSynchronizable as String] as? Bool, false, "never synchronized")
        XCTAssertNotNil(q[kSecAttrAccessControl as String], "behind access control")
        XCTAssertNil(q[kSecAttrAccessible as String], "protection comes only from the access control")
        let access = MacPasswordKeychain.accessibility as String
        XCTAssertTrue(access.hasSuffix("ThisDeviceOnly") || access == (kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly as String)
                      || access == (kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String), "this device only")
    }

    /// Claim: turning the setting on stores the password (and only the flag goes in the Mac list); off deletes it;
    /// removing the Mac deletes it.
    func testStoredDeletedOnOffAndRemove() throws {
        let k = FakeKeychain()
        let (s, mac) = store(k)
        XCTAssertTrue(AutoUnlockSetting.turnOn(word, macID: mac.id, store: s, keychain: k, defaults: defaults))
        XCTAssertEqual(k.items[mac.id], Data(word.utf8))
        XCTAssertEqual(s.entry(mac.id)?.autoUnlock, true)
        let file = try String(contentsOf: dir.appendingPathComponent("macs.json"), encoding: .utf8)
        XCTAssertFalse(file.contains(word), "the password is never in the stored Mac list")
        AutoUnlockSetting.turnOff(macID: mac.id, store: s, keychain: k, defaults: defaults)
        XCTAssertNil(k.items[mac.id])
        XCTAssertNil(s.entry(mac.id)?.autoUnlock)
        XCTAssertTrue(AutoUnlockSetting.turnOn(word, macID: mac.id, store: s, keychain: k, defaults: defaults))
        s.remove(mac.id)
        XCTAssertNil(k.items[mac.id], "removing the Mac deletes its password")
    }

    // MARK: The rules

    /// Claim: only locked + newer Host + setting on + no failed try + none in flight + app lock passed.
    func testShouldTryRules() {
        func t(_ locked: Bool?, host: Bool = true, on: Bool = true, failed: Bool = false, flight: Bool = false,
               app: Bool = true) -> Bool {
            AutoUnlockRules.shouldTry(locked: locked, hostCanUnlock: host, settingOn: on, lastTryFailed: failed,
                                      inFlight: flight, appUnlocked: app)
        }
        XCTAssertTrue(t(true))
        XCTAssertFalse(t(false), "not locked")
        XCTAssertFalse(t(nil), "older Host that does not say")
        XCTAssertFalse(t(true, host: false), "older Host that cannot type")
        XCTAssertFalse(t(true, on: false), "setting off")
        XCTAssertFalse(t(true, failed: true), "no second try after a failure")
        XCTAssertFalse(t(true, flight: true), "one at a time")
        XCTAssertFalse(t(true, app: false), "app lock not passed")
        XCTAssertNotNil(AutoUnlockRules.unavailableReason(appLockOn: false, deviceCanAuthenticate: true))
        XCTAssertNotNil(AutoUnlockRules.unavailableReason(appLockOn: true, deviceCanAuthenticate: false))
        XCTAssertNil(AutoUnlockRules.unavailableReason(appLockOn: true, deviceCanAuthenticate: true))
    }

    // MARK: The session

    private func session(_ k: FakeKeychain, appUnlocked: Bool = true,
                         appLockOn: Bool = true) -> (SessionModel, MacEntry, () -> [[UInt8]]) {
        let (s, mac) = store(k)
        XCTAssertTrue(AutoUnlockSetting.turnOn(word, macID: mac.id, store: s, keychain: k, defaults: defaults))
        let model = SessionModel(store: s)
        model.lastMacDefaults = defaults
        model.unlockDefaults = defaults
        model.passwords = k
        var sent: [[UInt8]] = []
        model.sendUnlock = { sent.append($0) }
        model.autoUnlockContext = { appUnlocked ? LAContext() : nil }
        model.appLockOn = { appLockOn }
        model.connect(to: s.entry(mac.id)!)
        return (model, mac, { sent })
    }

    /// Claim: a locked Mac whose Host can type gets the password once, with no prompt; unlocking clears it.
    func testLockedSendsOnceAndUnlockFinishes() {
        let k = FakeKeychain()
        let (model, _, sent) = session(k)
        model.noteScreenLock(true)
        XCTAssertTrue(sent().isEmpty, "the Host has not said it can type yet")
        XCTAssertTrue(model.outerOpensOnPassword, "until the Host says it can type, the password field")
        model.noteUnlockState(UnlockState.available)
        XCTAssertEqual(sent().count, 1)
        XCTAssertEqual(sent().first, Array(word.utf8))
        XCTAssertFalse(model.outerOpensOnPassword, "unlocking by itself: the dialog spot, keyboard down")
        model.noteScreenLock(true)
        XCTAssertEqual(sent().count, 1, "one in flight: not sent again")
        model.noteScreenLock(false)
        XCTAssertFalse(model.unlockInFlight)
        XCTAssertNil(model.unlockNotice)
        model.disconnect()
    }

    /// Claim: no unlock within the wait → the plain notice, and the next lock is NOT tried (never twice in a row),
    /// until the password is saved again.
    func testNoSecondTry() {
        let k = FakeKeychain()
        let (model, mac, sent) = session(k)
        model.noteUnlockState(UnlockState.available)
        model.noteScreenLock(true)
        XCTAssertEqual(sent().count, 1)
        model.unlockWaitEnded(macID: mac.id)
        XCTAssertEqual(model.unlockNotice, "Could not unlock. The saved password may be wrong.")
        XCTAssertTrue(model.outerOpensOnPassword, "failed: back to the password field with the keyboard up")
        model.noteScreenLock(false)
        model.noteScreenLock(true)
        XCTAssertEqual(sent().count, 1, "a wrong password is never tried twice in a row")
        model.disconnect()
        XCTAssertTrue(AutoUnlockSetting.turnOn(word, macID: mac.id, store: model.store, keychain: k, defaults: defaults))
        XCTAssertFalse(AutoUnlockFailures.failed(mac.id, in: defaults), "saving the password again clears it")
    }

    /// Claim: an older Host (never says it can type) gets nothing; today's opening stays.
    func testOlderHostFallback() {
        let k = FakeKeychain()
        let (model, _, sent) = session(k)
        model.noteScreenLock(true)
        XCTAssertTrue(sent().isEmpty)
        XCTAssertTrue(model.outerOpensOnPassword)
        XCTAssertEqual(k.reads, 0, "the password is not even read")
        model.disconnect()
    }

    /// Claim: app lock not passed (no context) → nothing read, nothing sent, today's opening.
    func testAppLockNotPassed() {
        let k = FakeKeychain()
        let (model, _, sent) = session(k, appUnlocked: false)
        model.noteUnlockState(UnlockState.available)
        model.noteScreenLock(true)
        XCTAssertTrue(sent().isEmpty)
        XCTAssertEqual(k.reads, 0)
        XCTAssertTrue(model.outerOpensOnPassword)
        model.disconnect()
    }

    /// Claim: the Host found the Mac not locked when it re-checked: nothing typed, no failure, no notice.
    func testHostNotLockedIsNotAFailure() {
        let k = FakeKeychain()
        let (model, mac, sent) = session(k)
        model.noteUnlockState(UnlockState.available)
        model.noteScreenLock(true)
        XCTAssertEqual(sent().count, 1)
        model.noteUnlockState(UnlockState.notLocked)
        XCTAssertFalse(model.unlockInFlight)
        model.unlockWaitEnded(macID: mac.id)
        XCTAssertNil(model.unlockNotice)
        XCTAssertFalse(AutoUnlockFailures.failed(mac.id, in: defaults))
        model.disconnect()
    }

    /// Claim: the unlocked Mac's outer screen opens on the dialog spot (keyboard down).
    func testUnlockedOpensOnDialogSpot() {
        let k = FakeKeychain()
        let (model, _, _) = session(k)
        model.noteScreenLock(false)
        XCTAssertFalse(model.outerOpensOnPassword)
        model.disconnect()
    }

    // MARK: Not sent, and why

    /// Claim: the Host's "locked" and "available" in either order send the password exactly once, with no notice.
    func testLockedAndAvailableEitherOrderSendOnce() {
        for lockFirst in [true, false] {
            let k = FakeKeychain()
            let (model, _, sent) = session(k)
            if lockFirst { model.noteScreenLock(true); model.noteUnlockState(UnlockState.available) }
            else { model.noteUnlockState(UnlockState.available); model.noteScreenLock(true) }
            XCTAssertEqual(sent().count, 1, "lock first: \(lockFirst)")
            XCTAssertNil(model.unlockNotice)
            model.disconnect()
        }
    }

    /// Claim: after a failed try, the next connection to the locked Mac sends nothing and SAYS so (it was silent).
    func testLastTryFailedIsSaid() {
        let k = FakeKeychain()
        let (model, mac, sent) = session(k)
        AutoUnlockFailures.set(mac.id, failed: true, in: defaults)
        model.noteUnlockState(UnlockState.available)
        model.noteScreenLock(true)
        XCTAssertTrue(sent().isEmpty)
        XCTAssertEqual(k.reads, 0, "not even read")
        XCTAssertEqual(model.unlockNotice, AutoUnlockRules.notice(.lastTryFailed))
        model.dismissUnlockNotice()
        model.noteScreenLock(false); model.noteScreenLock(true)
        XCTAssertNil(model.unlockNotice, "said once per connection")
        model.disconnect()
    }

    /// Claim: Require Touch ID / Face ID off → nothing sent, and said.
    func testAppLockOffIsSaid() {
        let k = FakeKeychain()
        let (model, _, sent) = session(k, appUnlocked: false, appLockOn: false)
        model.noteUnlockState(UnlockState.available)
        model.noteScreenLock(true)
        XCTAssertTrue(sent().isEmpty)
        XCTAssertEqual(model.unlockNotice, AutoUnlockRules.notice(.appLockOff))
        model.disconnect()
    }

    /// Claim: the app lock is on but not yet passed → quiet (it tries once passed); no notice.
    func testBehindAppLockIsQuiet() {
        let k = FakeKeychain()
        let (model, _, sent) = session(k, appUnlocked: false)
        model.noteUnlockState(UnlockState.available)
        model.noteScreenLock(true)
        XCTAssertTrue(sent().isEmpty)
        XCTAssertNil(model.unlockNotice)
        model.disconnect()
    }

    /// Claim: the switch is on but this iPhone has no saved password for the Mac (a restored or new iPhone): the
    /// switch goes off so its settings ask for the password once, and the notice says so.
    func testNoSavedPasswordIsSaidAndAsksAgain() {
        let k = FakeKeychain()
        let (model, mac, sent) = session(k)
        k.items = [:]
        model.noteUnlockState(UnlockState.available)
        model.noteScreenLock(true)
        XCTAssertTrue(sent().isEmpty)
        XCTAssertEqual(k.reads, 0)
        XCTAssertEqual(model.unlockNotice, AutoUnlockRules.notice(.noSavedPassword))
        XCTAssertNil(model.store.entry(mac.id)?.autoUnlock, "the switch is off: turning it on asks for the password")
        model.disconnect()
    }

    /// Claim: a saved password that cannot be read → nothing sent, said.
    func testUnreadableIsSaid() {
        let k = FakeKeychain()
        let (model, mac, sent) = session(k)
        k.readFails = true
        model.noteUnlockState(UnlockState.available)
        model.noteScreenLock(true)
        XCTAssertTrue(sent().isEmpty)
        XCTAssertEqual(model.unlockNotice, AutoUnlockRules.notice(.unreadable))
        XCTAssertEqual(model.store.entry(mac.id)?.autoUnlock, true, "kept: the item is there")
        model.disconnect()
    }

    /// Claim: a Host that never says it can type → after its wait, the notice says the Host cannot unlock.
    func testHostCannotUnlockIsSaid() {
        let k = FakeKeychain()
        let (model, mac, sent) = session(k)
        model.noteScreenLock(true)
        XCTAssertNil(model.unlockNotice, "not before the Host had its time")
        model.hostAnswerWaitEnded(macID: mac.id)
        XCTAssertTrue(sent().isEmpty)
        XCTAssertEqual(model.unlockNotice, AutoUnlockRules.notice(.hostCannotUnlock))
        model.disconnect()
    }

    /// Claim: setting off → nothing sent and nothing said.
    func testSettingOffIsQuiet() {
        let k = FakeKeychain()
        let (model, mac, sent) = session(k)
        AutoUnlockSetting.turnOff(macID: mac.id, store: model.store, keychain: k, defaults: defaults)
        model.noteUnlockState(UnlockState.available)
        model.noteScreenLock(true)
        model.hostAnswerWaitEnded(macID: mac.id)
        XCTAssertTrue(sent().isEmpty)
        XCTAssertNil(model.unlockNotice)
        model.disconnect()
    }

    /// Claim: no notice text carries the password or its length.
    func testNoticesCarryNoPassword() {
        for r in [AutoUnlockRules.NotSent.hostCannotUnlock, .lastTryFailed, .appLockOff, .noSavedPassword, .unreadable] {
            let t = AutoUnlockRules.notice(r)
            XCTAssertFalse(t.contains(word)); XCTAssertFalse(t.contains(String(word.count)))
        }
    }
}
