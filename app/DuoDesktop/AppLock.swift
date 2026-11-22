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
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let authenticate: (String) async -> Result<LAContext?, Error>
    /// The context the last successful unlock evaluated (project notes, "One Touch ID"): the saved Mac passwords
    /// are read with it, so no second prompt. Dropped (invalidated) the moment the app locks again.
    @ObservationIgnored private(set) var authContext: LAContext?

    /// `bypass`: this run only, the lock is off and nothing is stored. Passed only from
    /// `SimulatorSwitches.noAppLock`, which is `false` in device builds.
    init(defaults: UserDefaults = .standard, bypass: Bool = false,
         authenticate: @escaping (String) async -> Result<LAContext?, Error> = AppLock.deviceOwnerAuthentication) {
        self.defaults = defaults
        self.authenticate = authenticate
        let on = !bypass && Self.isOn(in: defaults)
        required = on
        locked = on
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

    func willEnterForeground(now: Date = Date()) {
        if Self.shouldLock(required: required, backgroundedAt: backgroundedAt, now: now) { lockNow() }
        backgroundedAt = nil
        accessMayHaveChanged()
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
        LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    func unlock() async {
        guard locked, !busy else { return }
        busy = true
        defer { busy = false }
        switch await authenticate(Self.reason) {
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
        switch await authenticate(on ? "Turn on Touch ID for Duo Desktop." : "Turn off Touch ID for Duo Desktop.") {
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

    nonisolated static func describe(_ error: Error) -> String {
        switch (error as? LAError)?.code {
        case .userCancel?, .systemCancel?, .appCancel?: "Unlock was cancelled."
        case .passcodeNotSet?: "Set up a passcode and Touch ID in Settings to use the lock."
        case .biometryNotEnrolled?: "Set up Touch ID in Settings to use the lock."
        case .biometryLockout?: "Touch ID is locked. Use the passcode."
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
