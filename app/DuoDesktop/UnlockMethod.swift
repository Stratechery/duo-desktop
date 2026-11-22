import Foundation
import LocalAuthentication

/// The phone's own way of unlocking, named the way Apple writes it (Face ID wording change; the owner:
/// "Duo Desktop on a regular phone makes references to Touch ID, but those phones have Face ID."). The iPhone Duo
/// has Touch ID; ordinary iPhones have Face ID. Every word people read about the app lock comes from here, so no
/// screen keeps its own copy. HIG Managing accounts
/// (https://developer.apple.com/design/human-interface-guidelines/managing-accounts): "Always identify the
/// authentication method you offer" and "Refer only to authentication methods that are available in the current
/// context. ... Check the device's capabilities and use the appropriate terminology" (`LABiometryType`).
enum UnlockMethod: String, CaseIterable, Sendable {
    case faceID, touchID, opticID
    /// No enrolled Face ID / Touch ID / Optic ID (or none on the device): the lock uses the device passcode.
    case passcode

    /// What this phone has now: the enrolled method, read from `LAContext.biometryType` after `canEvaluatePolicy`;
    /// `.passcode` when nothing is enrolled or there is no such hardware.
    static var current: UnlockMethod {
        #if targetEnvironment(simulator)
        if let forced = SimulatorSwitches.unlockMethod { return forced }
        #endif
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return .passcode }
        return from(context.biometryType)
    }

    /// The method the phone's hardware offers even when it is not set up (for "Set up … in Settings"); nil: none.
    static var hardware: UnlockMethod? {
        #if targetEnvironment(simulator)
        if let forced = SimulatorSwitches.unlockMethod { return forced == .passcode ? nil : forced }
        #endif
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) // sets biometryType
        let m = from(context.biometryType)
        return m == .passcode ? nil : m
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
