import Foundation
import LocalAuthentication
import Security
import SwiftUI
import UIKit

// Unlock a locked Mac automatically. — "Yes, let's do that." One Touch ID: "a single touch ID unlocks all of the Macs",
// so the app's own lock (`AppLock`) is the only gate.
//
// The Mac's password lives only in this iPhone's Keychain: one item per Mac, this device only, never synchronized,
// protected by access control (user presence) and read only with the LAContext the app lock just evaluated, so no
// second prompt. Never in the stored Mac list, logs, crash text, screenshots or tests' output.

/// Where the Macs' passwords are kept (the real Keychain, or a test double).
protocol MacPasswordKeeping: AnyObject {
    /// Replaces this Mac's item. False when the Keychain refused it.
    func save(_ password: Data, macID: String) -> Bool
    func delete(macID: String)
    /// Read with the app lock's evaluated context; nil when there is none, it was dropped, or the read fails.
    func read(macID: String, context: LAContext) -> Data?
    /// Whether this Mac has an item at all (asks nothing, reads no secret). A missing item (a restored or moved
    /// iPhone: the item is this-device-only, the Mac list is not) is told apart from a failed read.
    func has(macID: String) -> Bool
}

extension MacPasswordKeeping {
    func has(macID: String) -> Bool { true }
}

/// The real Keychain.
final class MacPasswordKeychain: MacPasswordKeeping {
    static let shared = MacPasswordKeychain()
    static let service = "com.example.duodesktop.mac-password"

    /// The item's protection: this device only, never synchronized, only after user presence. A device needs a
    /// passcode set (`WhenPasscodeSet`); the Simulator has no passcode, so there it is `WhenUnlocked` (still
    /// this device only, still behind user presence).
    static var accessibility: CFString {
        #if targetEnvironment(simulator)
        kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        #else
        kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly
        #endif
    }

    /// The query naming one Mac's item (never synchronized).
    static func baseQuery(macID: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: macID,
         kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
    }

    /// The attributes a new item is added with. Tests check these rules.
    static func addAttributes(_ password: Data, macID: String) -> [String: Any]? {
        guard let access = SecAccessControlCreateWithFlags(nil, accessibility, .userPresence, nil) else { return nil }
        var q = baseQuery(macID: macID)
        q[kSecAttrAccessControl as String] = access
        q[kSecValueData as String] = password
        q[kSecAttrLabel as String] = "Duo Desktop Mac password"
        return q
    }

    /// The last save's Keychain status (an error code only, for the log).
    private(set) var lastSaveStatus: OSStatus = errSecSuccess

    func save(_ password: Data, macID: String) -> Bool {
        delete(macID: macID)
        guard let q = Self.addAttributes(password, macID: macID) else { lastSaveStatus = errSecParam; return false }
        lastSaveStatus = SecItemAdd(q as CFDictionary, nil)
        return lastSaveStatus == errSecSuccess
    }

    func delete(macID: String) {
        SecItemDelete(Self.baseQuery(macID: macID) as CFDictionary)
    }

    func read(macID: String, context: LAContext) -> Data? {
        // The context was evaluated by the app lock; reading with it shows nothing. If it is no longer good, fail
        // rather than ask again.
        context.interactionNotAllowed = true
        var q = Self.baseQuery(macID: macID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationContext as String] = context
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess else { return nil }
        return out as? Data
    }

    func has(macID: String) -> Bool {
        // Attributes only, no data and no prompt: the item's protection does not apply to finding it.
        var q = Self.baseQuery(macID: macID)
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = true
        q[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(q as CFDictionary, nil)
        return status != errSecItemNotFound
    }
}

/// The rules, pure (tests). Per Mac: whether to send the password, and what an answer means.
enum AutoUnlockRules {
    /// How long to wait for the Host's "unlocked" after it typed (counted from the Host's "typed"; an older Host says
    /// "typed" at once).
    static let unlockWait: TimeInterval = 6
    /// A newer Host waits for the lock screen to be ready before typing (up to its own
    /// 10 s) and says "typed" only then. If no "typed" comes in this long after sending, the wait for "unlocked" starts
    /// anyway.
    static let typedWait: TimeInterval = 12

    /// What the setting row says when the feature cannot be used (nil: it can).
    static func unavailableReason(appLockOn: Bool, deviceCanAuthenticate: Bool) -> String? {
        if !deviceCanAuthenticate { return "\(UnlockMethod.noPasscodeSetup(hardware: UnlockMethod.hardware)) to use this." }
        if !appLockOn { return UnlockMethod.current.turnOnRequiredHint }
        return nil
    }

    /// Send the password now? Only when the Mac says it is locked, its Host can type it (a newer Host), the setting
    /// is on, the last try on this Mac did not fail (a wrong password is never tried twice in a row), none is in
    /// flight, and the app lock is passed (its context is held).
    static func shouldTry(locked: Bool?, hostCanUnlock: Bool, settingOn: Bool, lastTryFailed: Bool,
                          inFlight: Bool, appUnlocked: Bool) -> Bool {
        locked == true && hostCanUnlock && settingOn && !lastTryFailed && !inFlight && appUnlocked
    }

    /// Whether the outer screen should expect the Mac to unlock by itself (it then opens on the dialog spot with the
    /// keyboard down). Same as `shouldTry` without "locked" and "in flight".
    static func expected(hostCanUnlock: Bool, settingOn: Bool, lastTryFailed: Bool, appUnlocked: Bool) -> Bool {
        hostCanUnlock && settingOn && !lastTryFailed && appUnlocked
    }

    /// After the first miss (one more try comes on the next connection).
    static let failedNotice = "Could not unlock. Duo Desktop will try once more the next time you connect."
    /// After the second miss in a row (no more tries until the password is saved again).
    static let stoppedNotice = "Could not unlock twice in a row. Save the password again in this Mac’s settings."

    /// Why the password was NOT sent to a locked Mac whose Unlock Automatically is on. Each one is said in a notice;
    /// before, the app said nothing.
    enum NotSent: Equatable {
        /// The Host never said it can type (an older Host, or one without the unlock part).
        case hostCannotUnlock
        /// The last two tries did not unlock; the password is not typed again until it is saved again.
        case lastTryFailed
        /// The app lock (Require Touch ID / Face ID) is off, so the saved password cannot be read.
        case appLockOff
        /// The setting is on but this iPhone has no saved password for this Mac (a restored or new iPhone).
        case noSavedPassword
        /// The saved password is there but could not be read.
        case unreadable
    }

    static func notice(_ reason: NotSent) -> String {
        switch reason {
        case .hostCannotUnlock: "This Mac’s Host cannot unlock it. Update Glass Act Host on the Mac."
        case .lastTryFailed: "Not unlocking: the last two tries did not work. Save the password again in this Mac’s settings."
        case .appLockOff: "Not unlocking: \(UnlockMethod.current.settingOffText)"
        case .noSavedPassword: "No saved password for this Mac on this iPhone. Turn on Unlock Automatically again."
        case .unreadable: "Could not read this Mac’s saved password. Lock Duo Desktop, open it again, then reconnect."
        }
    }

    /// What to do about one Mac now. `quiet`: nothing to do or say (not locked, setting off, a try in flight);
    /// `wait`: not yet (the app lock is up and will try when passed; the Host has not said it can type yet).
    enum Decision: Equatable { case send, wait, quiet, notSent(NotSent) }

    /// `lastTryFailed`: two misses in a row (stopped). `missedThisConnection`: a try on this connection already missed;
    /// it is never tried again within the same connection (its notice is already up).
    static func decide(locked: Bool?, settingOn: Bool, inFlight: Bool, lastTryFailed: Bool,
                       missedThisConnection: Bool = false, appLockOn: Bool,
                       appUnlocked: Bool, hostCanUnlock: Bool) -> Decision {
        guard locked == true, settingOn, !inFlight else { return .quiet }
        if lastTryFailed { return .notSent(.lastTryFailed) }
        if missedThisConnection { return .quiet }
        if !appLockOn { return .notSent(.appLockOff) }
        if !appUnlocked { return .wait }
        if !hostCanUnlock { return .wait }
        return .send
    }

    /// How long a locked Mac's Host has to say it can type (it says so with the lock, on connect) before the app says
    /// it cannot.
    static let hostAnswerWait: TimeInterval = 3

    /// What stands in the way (Touch ID clarity): the phone has no passcode/Touch ID, or Require Touch ID is off.
    enum Blocker: Equatable { case noPasscode, appLockOff }

    static func blocker(appLockOn: Bool, deviceCanAuthenticate: Bool) -> Blocker? {
        if !deviceCanAuthenticate { return .noPasscode }
        if !appLockOn { return .appLockOff }
        return nil
    }

    /// The section's footer, saying the dependency before it matters. The words name this phone's own method
    /// (`UnlockMethod`, Face ID wording change).
    static var footer: String { UnlockMethod.current.autoUnlockFooter }
    static var noPasscodeText: String { UnlockMethod.noPasscodeText(hardware: UnlockMethod.hardware) }
    static var appLockOffText: String { UnlockMethod.current.settingOffText }

    /// The Mac list's Security footer: what depends on Require Touch ID.
    static var securityFooter: String { UnlockMethod.current.securityFooter }

    /// The Macs that stop unlocking automatically if Require Touch ID is turned off.
    static func macsUsing(_ macs: [MacEntry]) -> [MacEntry] { macs.filter { $0.autoUnlock == true } }

    /// The one warning before Require Touch ID goes off while Macs use Unlock Automatically (nil: no warning).
    static func lockOffWarning(_ macs: [MacEntry]) -> String? {
        let names = macsUsing(macs).map { "“\($0.name)”" }
        guard !names.isEmpty else { return nil }
        let list = ListFormatter.localizedString(byJoining: names)
        let them = names.count == 1 ? "its saved Mac password is" : "their saved Mac passwords are"
        return "\(list) will stop unlocking automatically, and \(them) deleted from this iPhone."
    }
}

/// One Mac's non-secret miss count: automatic tries in a row that did not unlock.
/// One miss is not proof the password is wrong (it may have been typed before the lock screen could take
/// it), so the next connection tries once more; after `stopAfter` misses in a row nothing is typed until the password
/// is saved again (macOS locks accounts out after repeated wrong passwords). A success, saving the password again, or
/// turning the setting off clears it. Build 90 and earlier kept a single "failed" flag; one that is still set counts
/// as one miss, so such a Mac gets one more try.
enum AutoUnlockFailures {
    static let stopAfter = 2
    static func key(_ macID: String) -> String { "autoUnlockFailed.\(macID)" }
    static func countKey(_ macID: String) -> String { "autoUnlockMisses.\(macID)" }
    static func misses(_ macID: String, in d: UserDefaults = .standard) -> Int {
        let n = d.integer(forKey: countKey(macID))
        return n > 0 ? n : (d.bool(forKey: key(macID)) ? 1 : 0)
    }
    /// Any miss on record (the next try is the last before stopping).
    static func failed(_ macID: String, in d: UserDefaults = .standard) -> Bool { misses(macID, in: d) > 0 }
    /// Two misses in a row: no more tries until the password is saved again.
    static func stopped(_ macID: String, in d: UserDefaults = .standard) -> Bool { misses(macID, in: d) >= stopAfter }
    /// One more miss; returns the new count.
    @discardableResult static func recordMiss(_ macID: String, in d: UserDefaults = .standard) -> Int {
        let n = misses(macID, in: d) + 1
        d.set(n, forKey: countKey(macID))
        d.removeObject(forKey: key(macID))
        return n
    }
    /// `failed: false` clears the count (success, password saved again, setting off). `failed: true` records a miss.
    static func set(_ macID: String, failed: Bool, in d: UserDefaults = .standard) {
        if failed { recordMiss(macID, in: d) } else {
            d.removeObject(forKey: key(macID))
            d.removeObject(forKey: countKey(macID))
        }
    }
}

/// The setting's actions, shared by the settings screen and Remove Mac.
enum AutoUnlockSetting {
    /// Turn on with a password: stored in the Keychain, the failure flag cleared. False if the Keychain refused.
    @MainActor static func turnOn(_ password: String, macID: String, store: MacStore,
                                  keychain: MacPasswordKeeping = MacPasswordKeychain.shared,
                                  defaults: UserDefaults = .standard) -> Bool {
        guard !password.isEmpty, keychain.save(Data(password.utf8), macID: macID) else { return false }
        AutoUnlockFailures.set(macID, failed: false, in: defaults)
        store.update(macID) { $0.autoUnlock = true }
        return true
    }

    /// Turn off: the password deleted.
    @MainActor static func turnOff(macID: String, store: MacStore,
                                   keychain: MacPasswordKeeping = MacPasswordKeychain.shared,
                                   defaults: UserDefaults = .standard) {
        keychain.delete(macID: macID)
        AutoUnlockFailures.set(macID, failed: false, in: defaults)
        store.update(macID) { $0.autoUnlock = nil }
    }

    /// Require Touch ID went off: no Mac can be unlocked automatically, so every saved Mac password is deleted and
    /// each switch goes off (the passwords are only ever read with the app lock's context; build 38's rule).
    @MainActor static func appLockTurnedOff(store: MacStore,
                                            keychain: MacPasswordKeeping = MacPasswordKeychain.shared,
                                            defaults: UserDefaults = .standard) {
        for mac in store.macs where mac.autoUnlock == true {
            turnOff(macID: mac.id, store: store, keychain: keychain, defaults: defaults)
        }
        // The PCs' Remote Desktop passwords are kept only behind the app lock too (milestone 3).
        store.rdpPasswords.deleteAll()
    }
}

/// The plain notice after a try that did not unlock (HIG: say what happened in plain words; one way to close it).
struct UnlockNoticeBanner: View {
    let text: String
    let close: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
            Button("Close", systemImage: "xmark", action: close)
                .labelStyle(.iconOnly)
                .frame(minWidth: 44, minHeight: 44)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .padding(16)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("unlockNotice")
    }
}

/// The Mac's "Unlock Automatically" row. HIG Toggles: a switch for an on/off setting; HIG Text fields: a secure field
/// for a password, with a clear label. Turning it on shows the secure field; the switch is on only once a password is
/// saved. Turning it off deletes the password at once. Touch ID clarity: the footer says it needs Require Touch ID;
/// when that is off, a button right here turns it on (HIG Buttons in a list: an action row; the system's Touch ID check
/// runs, `AppLock.setRequired`); when the phone has no passcode, a button opens Settings.
struct AutoUnlockSection: View {
    let store: MacStore
    let id: String
    /// The app lock, for its state and the "Turn On Require Touch ID" row; nil reads the stored setting only.
    let lock: AppLock?
    var deviceCanAuthenticate: Bool = AppLock.deviceCanAuthenticate()
    @Environment(\.openURL) private var openURL
    @State private var entering = false
    @State private var password = ""
    @State private var failed = false
    @FocusState private var focused: Bool

    private var on: Bool { store.entry(id)?.autoUnlock == true }
    private var blocker: AutoUnlockRules.Blocker? {
        AutoUnlockRules.blocker(appLockOn: lock?.required ?? AppLock.isOn(in: .standard),
                                deviceCanAuthenticate: deviceCanAuthenticate)
    }

    var body: some View {
        Section {
            Toggle("Unlock Automatically", isOn: Binding(get: { on || entering }, set: { new in
                if new {
                    entering = true
                    focused = true
                } else {
                    entering = false
                    password = ""
                    AutoUnlockSetting.turnOff(macID: id, store: store, keychain: store.passwords)
                }
            }))
            .disabled(blocker != nil && !on)
            .accessibilityIdentifier("autoUnlockSwitch")
            if !on, let blocker {
                switch blocker {
                case .noPasscode:
                    Text(AutoUnlockRules.noPasscodeText).foregroundStyle(.secondary)
                        .accessibilityIdentifier("autoUnlockNoPasscode")
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                case .appLockOff:
                    if let lock {
                        Button {
                            Task { await lock.setRequired(true) }
                        } label: {
                            Label(UnlockMethod.current.turnOnRow, systemImage: UnlockMethod.current.symbol)
                        }
                        .disabled(lock.busy)
                        .accessibilityIdentifier("autoUnlockTurnOnTouchID")
                        if let m = lock.message { Text(m).font(.footnote).foregroundStyle(.secondary) }
                    } else {
                        Text(UnlockMethod.current.turnOnInSecurityHint).foregroundStyle(.secondary)
                    }
                }
            }
            if entering {
                SecureField("Mac Password", text: $password)
                    .textContentType(nil)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit(savePassword)
                    .accessibilityIdentifier("autoUnlockPassword")
                Button("Save Password", action: savePassword)
                    .disabled(password.isEmpty)
            }
        } footer: {
            if failed {
                Text("The password could not be saved.")
            } else {
                Text(AutoUnlockRules.footer)
            }
        }
    }

    private func savePassword() {
        guard !password.isEmpty else { return }
        failed = !AutoUnlockSetting.turnOn(password, macID: id, store: store, keychain: store.passwords)
        password = ""
        if !failed { entering = false }
    }
}
