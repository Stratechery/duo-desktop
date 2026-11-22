import LocalAuthentication
import XCTest
@testable import DuoDesktop

/// Face ID wording change: the app names the phone's own unlock, as Apple writes it.
final class UnlockMethodTests: XCTestCase {
    /// Claim: each biometry type maps to its method; none maps to the passcode.
    func testMapsBiometryType() {
        XCTAssertEqual(UnlockMethod.from(.faceID), .faceID)
        XCTAssertEqual(UnlockMethod.from(.touchID), .touchID)
        XCTAssertEqual(UnlockMethod.from(.opticID), .opticID)
        XCTAssertEqual(UnlockMethod.from(.none), .passcode)
    }

    /// Claim: the wording for each type — Apple's exact names and symbols, never a generic word.
    func testWordingForEachType() {
        let expected: [(UnlockMethod, String, String)] = [
            (.faceID, "Face ID", "faceid"), (.touchID, "Touch ID", "touchid"),
            (.opticID, "Optic ID", "opticid"), (.passcode, "Passcode", "lock.fill"),
        ]
        for (m, name, symbol) in expected {
            XCTAssertEqual(m.name, name)
            XCTAssertEqual(m.symbol, symbol)
            XCTAssertEqual(m.settingName, "Require \(name)")
            XCTAssertEqual(m.unlockButton, "Unlock with \(name)")
            XCTAssertEqual(m.turnOffAlertTitle, "Turn Off Require \(name)?")
            XCTAssertEqual(m.turnOnRow, "Turn On Require \(name)")
            XCTAssertEqual(m.setRequiredReason(true), "Turn on Require \(name) for Duo Desktop.")
            XCTAssertTrue(m.autoUnlockFooter.hasPrefix("Needs Require \(name),"))
            XCTAssertTrue(m.keyInfoAutoUnlock.contains("(it needs Require \(name))"))
            let all = [m.securityFooter, m.autoUnlockFooter, m.keyInfoAutoUnlock, m.turnOnInSecurityHint]
            for s in all { XCTAssertFalse(s.lowercased().contains("biometr"), s) }
            for other in UnlockMethod.allCases where other != m && other != .passcode {
                for s in all { XCTAssertFalse(s.contains(other.name), "\(m): \(s)") }
            }
        }
        // The Duo keeps its build 53 words exactly.
        XCTAssertEqual(UnlockMethod.touchID.autoUnlockFooter,
                       "Needs Require Touch ID, which locks Duo Desktop itself. One Touch ID then unlocks every Mac. When this Mac is locked, Duo Desktop types its password for you; the password stays in this iPhone’s Keychain.")
        XCTAssertEqual(UnlockMethod.touchID.securityFooter,
                       "Asks for Touch ID when Duo Desktop opens and after 5 minutes away. Unlock Automatically and the saved Mac passwords need it, and Terminal and JetKVM wait for it after 5 minutes away.")
        XCTAssertEqual(UnlockMethod.faceID.securityFooter.prefix(22), "Asks for Face ID when ")
        XCTAssertTrue(UnlockMethod.passcode.securityFooter.hasPrefix("Asks for your passcode when"))
        XCTAssertTrue(UnlockMethod.passcode.autoUnlockFooter.contains("Entering your passcode once then unlocks"))
    }

    /// Claim: the setup and error texts follow the phone's hardware, with a true passcode-only form.
    func testSetupAndErrorTexts() {
        XCTAssertEqual(UnlockMethod.noPasscodeText(hardware: .touchID),
                       "This iPhone has no passcode, so Touch ID can’t be used. Set up a passcode and Touch ID in Settings.")
        XCTAssertEqual(UnlockMethod.noPasscodeText(hardware: .faceID),
                       "This iPhone has no passcode, so Face ID can’t be used. Set up a passcode and Face ID in Settings.")
        XCTAssertEqual(UnlockMethod.noPasscodeText(hardware: nil),
                       "This iPhone has no passcode, so the lock can’t be used. Set up a passcode in Settings.")
        XCTAssertEqual(AppLock.describe(LAError(.biometryLockout), hardware: .faceID), "Face ID is locked. Use the passcode.")
        XCTAssertEqual(AppLock.describe(LAError(.biometryNotEnrolled), hardware: .faceID),
                       "Set up Face ID in Settings, or use the passcode.")
        XCTAssertEqual(AppLock.describe(LAError(.passcodeNotSet), hardware: .touchID),
                       "Set up a passcode and Touch ID in Settings to use the lock.")
    }
}
