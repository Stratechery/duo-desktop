import Foundation
import LocalAuthentication
import Observation

/// The app lock (plan §8, M4). The iPhone Duo has Touch ID, not Face ID. Behind the "Require Touch ID" setting,
/// ON by default (the owner 2026-11-20: "Yes on Touch ID."). When on: locked at launch and after 5 minutes in the
/// background; unlocked with Touch ID, the device passcode as the fallback (`.deviceOwnerAuthentication`).
/// Turning it off asks for Touch ID first. Tests skip it only through `bypass` (Simulator-only `--no-app-lock`).
@MainActor @Observable
final class AppLock {
    static let settingKey = "requireTouchID"
    nonisolated static let relockAfter: TimeInterval = 5 * 60
    static let reason = "Unlock Duo Desktop to use your Macs."

    /// Whether the lock is on. Stored in UserDefaults; no stored value means on.
    private(set) var required: Bool
    private(set) var locked: Bool
    private(set) var busy = false
    var message: String?
    @ObservationIgnored private var backgroundedAt: Date?
    /// An automatic request for Face ID / Touch ID is due: once at launch, and once after each real return from the
    /// background while locked. Spent when it is made. First-launch Face ID fix (project notes): the system's own
    /// Face ID alerts (the first-use "Allow … to use Face ID?" question, "Face Not Recognized", the passcode pad)
    /// make the app inactive and then active again; that is not a return, so it must never start another request.
    @ObservationIgnored private(set) var autoAskDue: Bool
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let authenticate: (String) async -> Result<LAContext?, Error>
    /// The context the last successful unlock evaluated (project notes, "One Touch ID"): the saved Mac passwords
    /// are read with it, so no second prompt. Dropped (invalidated) the moment the app locks again.
    @ObservationIgnored private(set) var authContext: LAContext?

    /// `bypass`: this run only, the lock is off and nothing is stored. Passed only from
    /// `SimulatorSwitches.noAppLock`, which is `false` in device builds.
    /// `passedForPicture`: this run only, the lock is on and already passed (no context, so no Mac password is ever
    /// read). Passed only from `SimulatorSwitches.appLockPassed` (`--app-lock-passed`), `false` in device builds.
    init(defaults: UserDefaults = .standard, bypass: Bool = false, passedForPicture: Bool = false,
         authenticate: @escaping (String) async -> Result<LAContext?, Error> = AppLock.deviceOwnerAuthentication) {
        self.defaults = defaults
        self.authenticate = authenticate
        let on = passedForPicture || (!bypass && Self.isOn(in: defaults))
        required = on
        let startsLocked = passedForPicture ? false : on
        locked = startsLocked
        autoAskDue = startsLocked
        UnlockMethod.Device.refresh() // before any request
    }

    /// The stored setting, on when never set.
    nonisolated static func isOn(in defaults: UserDefaults) -> Bool {
        (defaults.object(forKey: settingKey) as? Bool) ?? true
    }

    /// The rule: lock again only if the setting is on and the app was away at least `relockAfter`.
    nonisolated static func shouldLock(required: Bool, backgroundedAt: Date?, now: Date) -> Bool {
        guard required, let backgroundedAt else { return false }
        return now.timeIntervalSince(backgroundedAt) >= relockAfter
    }

    func didEnterBackground(now: Date = Date()) {
        if backgroundedAt == nil { backgroundedAt = now }
        accessMayHaveChanged()
    }

    /// The scene is active again. Only a real return (after `didEnterBackground`) can lock or make a request due;
    /// active after inactive alone (a system alert, Control Center) changes nothing.
    func willEnterForeground(now: Date = Date()) {
        guard backgroundedAt != nil else { return }
        if !busy { UnlockMethod.Device.refresh() } // Settings may have changed while away
        if Self.shouldLock(required: required, backgroundedAt: backgroundedAt, now: now) { lockNow() }
        if locked { autoAskDue = true }
        backgroundedAt = nil
        accessMayHaveChanged()
    }

    /// Whether to put up the system's request now, by itself: the scene is active (the window is on screen), one is
    /// due, none is pending. Spends the due request, so a cancelled or failed one leaves the lock screen and its
    /// button, and is never asked again until the next launch or real return.
    func takeAutoAsk(sceneActive: Bool) -> Bool {
        guard sceneActive, autoAskDue, locked, !busy else { return false }
        autoAskDue = false
        return true
    }

    /// Asks by itself when due (`takeAutoAsk`).
    func autoUnlockIfDue(sceneActive: Bool) async {
        guard takeAutoAsk(sceneActive: sceneActive) else { return }
        await unlock()
    }

    /// Lock, dropping the context the saved passwords are read with.
    func lockNow() {
        locked = true
        authContext?.invalidate()
        authContext = nil
        accessMayHaveChanged()
    }

    /// Review fixes (review finding 3): what the Terminal and JetKVM links may do (`AppAccess`). Away (backgrounded,
    /// or back before `willEnterForeground` decided) counts as not open, so a view's own return-to-front handler
    /// cannot start a link before the lock has had its say.
    var access: AppAccess.State {
        if locked { return .locked }
        return backgroundedAt == nil ? .open : .away
    }

    /// Called with `access` whenever it may have changed (`RootView` passes it to `AppAccess.set`).
    @ObservationIgnored var onAccessChange: ((AppAccess.State) -> Void)?
    private func accessMayHaveChanged() { onAccessChange?(access) }

    /// Automatic unlock may read the Mac passwords: the lock is on and passed this time.
    var autoUnlockContext: LAContext? { required && !locked ? authContext : nil }

    /// The device can do the app lock at all (passcode set, so Touch ID or the passcode).
    nonisolated static func deviceCanAuthenticate() -> Bool {
        UnlockMethod.Device.now.canAuthenticate
    }

    func unlock() async {
        guard locked, !busy else { return }
        busy = true
        defer { busy = false }
        message = nil // the last answer's words go while the new request is up
        let answer = await authenticate(Self.reason)
        UnlockMethod.Device.refresh() // the request is over: the first-time answer may have changed what is allowed
        switch answer {
        case let .success(context):
            authContext = context
            locked = false
            message = nil
            accessMayHaveChanged()
        case let .failure(error):
            message = Self.describe(error)
        }
    }

    /// Turning the lock on asks for Touch ID first, so it is known to work before it can lock the owner out. Turning
    /// it off asks too: the setting is part of what the lock protects.
    func setRequired(_ on: Bool) async {
        guard on != required, !busy else { return }
        busy = true
        defer { busy = false }
        let answer = await authenticate(UnlockMethod.current.setRequiredReason(on))
        UnlockMethod.Device.refresh()
        switch answer {
        case let .success(context):
            if on, !locked { authContext = context }
            if !on { authContext?.invalidate(); authContext = nil }
            required = on
            defaults.set(on, forKey: Self.settingKey)
            message = nil
        case let .failure(error):
            message = Self.describe(error)
        }
    }

    /// `hardware`: the phone's Face ID / Touch ID / Optic ID, set up or not (`UnlockMethod.hardware`).
    nonisolated static func describe(_ error: Error, hardware: UnlockMethod? = UnlockMethod.hardware) -> String {
        switch (error as? LAError)?.code {
        case .userCancel?, .systemCancel?, .appCancel?: "Unlock was cancelled."
        case .passcodeNotSet?: "\(UnlockMethod.noPasscodeSetup(hardware: hardware)) to use the lock."
        case .biometryNotEnrolled?: UnlockMethod.notEnrolledText(hardware: hardware)
        case .biometryLockout?: UnlockMethod.lockoutText(hardware: hardware)
        default: "Couldn’t unlock: \(error.localizedDescription)"
        }
    }

    nonisolated static func deviceOwnerAuthentication(_ reason: String) async -> Result<LAContext?, Error> {
        let context = LAContext()
        context.localizedFallbackTitle = "Use Passcode"
        do {
            _ = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return .success(context)
        } catch {
            return .failure(error)
        }
    }
}
