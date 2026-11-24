import Foundation
import LocalAuthentication

/// The phone's own way of unlocking, named the way Apple writes it. The iPhone Duo has Touch ID; ordinary iPhones have
/// Face ID. Every word people read about the app lock comes from here, so no screen keeps its own copy. HIG Managing
/// accounts (https://developer.apple.com/design/human-interface-guidelines/managing-accounts): "Always identify the
/// authentication method you offer" and "Refer only to authentication methods that are available in the current
/// context.... Check the device's capabilities and use the appropriate terminology" (`LABiometryType`).
enum UnlockMethod: String, CaseIterable, Sendable {
    case faceID, touchID, opticID
    /// No enrolled Face ID / Touch ID / Optic ID (or none on the device): the lock uses the device passcode.
    case passcode

    /// What this phone has now: the enrolled method, read from `LAContext.biometryType` after `canEvaluatePolicy`;
    /// `.passcode` when nothing is enrolled or there is no such hardware.
    /// Read from the cache (`Device`), never from LocalAuthentication in a view's body.
    static var current: UnlockMethod {
        #if targetEnvironment(simulator)
        if let forced = SimulatorSwitches.unlockMethod { return forced }
        #endif
        return Device.now.current
    }

    // MARK: The device read, kept

    /// What LocalAuthentication said about this phone, read once and kept. `canEvaluatePolicy` is a synchronous call
    /// to the system's authentication service; it used to run in view bodies (the lock screen, the Mac list, about
    /// five per redraw), and a system alert redraws the app. While the app's first-time Face ID question is up, that
    /// service is busy with this app's own request; the reads now happen only when no request is pending: at launch
    /// before the first one, after each one finishes, and on a real return (`AppLock` calls `refresh`).
    struct Device: Sendable, Equatable {
        var current: UnlockMethod
        var hardware: UnlockMethod?
        var refused: UnlockMethod?
        var canAuthenticate: Bool

        /// How many times LocalAuthentication was asked (tests).
        nonisolated(unsafe) static var readCount = 0

        static func read() -> Device {
            readCount += 1
            let bio = LAContext()
            var error: NSError?
            let ok = bio.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            let type = from(bio.biometryType)
            let code = error.map { LAError.Code(rawValue: $0.code) } ?? nil
            return Device(current: ok ? type : .passcode,
                          hardware: type == .passcode ? nil : type,
                          refused: ok ? nil : UnlockMethod.refused(code: code, type: bio.biometryType),
                          canAuthenticate: LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil))
        }

        private static let kept = NSLock()
        nonisolated(unsafe) private static var value: Device?

        /// The kept read (made now if there is none yet).
        static var now: Device {
            kept.lock(); let v = value; kept.unlock()
            return v ?? refresh()
        }

        /// Read again and keep it. Only when no Face ID / passcode request is pending.
        @discardableResult static func refresh() -> Device {
            let v = read()
            kept.lock(); value = v; kept.unlock()
            return v
        }
    }

    /// The method the phone's hardware offers even when it is not set up (for "Set up … in Settings"); nil: none.
    static var hardware: UnlockMethod? {
        #if targetEnvironment(simulator)
        if let forced = SimulatorSwitches.unlockMethod { return forced == .passcode ? nil : forced }
        #endif
        return Device.now.hardware
    }

    /// The phone has Face ID (or Touch ID / Optic ID) set up, but this app was refused it: "Don't Allow" at the
    /// first-use question, or turned off later in Settings > Duo Desktop. LocalAuthentication then reports
    /// `biometryNotAvailable` for the biometrics policy while `biometryType` still names the hardware; the lock goes on
    /// with the device passcode (`.deviceOwnerAuthentication`). nil: not refused (or no such hardware).
    static var refused: UnlockMethod? {
        #if targetEnvironment(simulator)
        if SimulatorSwitches.biometryDenied { return .faceID }
        #endif
        return Device.now.refused
    }

    /// The rule behind `refused`, testable.
    static func refused(code: LAError.Code?, type: LABiometryType) -> UnlockMethod? {
        guard code == .biometryNotAvailable else { return nil }
        let m = from(type)
        return m == .passcode ? nil : m
    }

    /// What the lock screen says when the app was refused Face ID, with the way to turn it on.
    var refusedText: String {
        "\(name) is off for Duo Desktop, so it uses your passcode. To use \(name), turn it on in Settings > Duo Desktop."
    }

    static func from(_ type: LABiometryType) -> UnlockMethod {
        switch type {
        case .faceID: .faceID
        case .touchID: .touchID
        case .opticID: .opticID
        default: .passcode
        }
    }

    /// The method's name as Apple writes it; "Passcode" when there is none.
    var name: String {
        switch self {
        case .faceID: "Face ID"
        case .touchID: "Touch ID"
        case .opticID: "Optic ID"
        case .passcode: "Passcode"
        }
    }

    /// The SF Symbol for the method.
    var symbol: String {
        switch self {
        case .faceID: "faceid"
        case .touchID: "touchid"
        case .opticID: "opticid"
        case .passcode: "lock.fill"
        }
    }

    // MARK: Sentences (every one people read about the app lock)

    /// The setting's name: "Require Face ID", "Require Touch ID", "Require Passcode".
    var settingName: String { "Require \(name)" }
    var unlockButton: String { "Unlock with \(name)" }
    var turnOffAlertTitle: String { "Turn Off \(settingName)?" }
    var turnOnRow: String { "Turn On \(settingName)" }
    var turnOnRequiredHint: String { "Turn on \(settingName) to use this." }
    var turnOnInSecurityHint: String { "Turn on \(settingName) in the Mac list’s Security section." }
    var settingOffText: String { "\(settingName) is off." }
    /// The system prompt's reason when the setting is turned on or off.
    func setRequiredReason(_ on: Bool) -> String { "\(on ? "Turn on" : "Turn off") \(settingName) for Duo Desktop." }

    /// "Face ID" / "your passcode", for the middle of a sentence.
    var inSentence: String { self == .passcode ? "your passcode" : name }

    var securityFooter: String {
        "Asks for \(inSentence) when Duo Desktop opens and after 5 minutes away. Unlock Automatically and the saved Mac passwords need it, and Terminal and JetKVM wait for it after 5 minutes away."
    }

    var autoUnlockFooter: String {
        let once = self == .passcode ? "Entering your passcode once" : "One \(name)"
        return "Needs \(settingName), which locks Duo Desktop itself. \(once) then unlocks every Mac. When this Mac is locked, Duo Desktop types its password for you; the password stays in this iPhone’s Keychain."
    }

    var keyInfoAutoUnlock: String {
        "With Unlock Automatically on in a Mac’s settings (it needs \(settingName)), a locked Mac unlocks by itself"
    }

    /// No passcode on the phone. `hardware`: what the phone could set up as well (nil: passcode only).
    static func noPasscodeSetup(hardware: UnlockMethod?) -> String {
        if let h = hardware { return "Set up a passcode and \(h.name) in Settings" }
        return "Set up a passcode in Settings"
    }
    static func noPasscodeText(hardware: UnlockMethod?) -> String {
        "This iPhone has no passcode, so \(hardware?.name ?? "the lock") can’t be used. \(noPasscodeSetup(hardware: hardware))."
    }
    static func notEnrolledText(hardware: UnlockMethod?) -> String {
        if let h = hardware { return "Set up \(h.name) in Settings, or use the passcode." }
        return "Use the passcode."
    }
    static func lockoutText(hardware: UnlockMethod?) -> String {
        if let h = hardware { return "\(h.name) is locked. Use the passcode." }
        return "Use the passcode."
    }
}
