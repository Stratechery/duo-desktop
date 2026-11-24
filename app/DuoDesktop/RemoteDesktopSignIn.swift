// Remote Desktop milestone 3: the saved password, the trust words, the plain failure words and the
// return-from-background rule. In every build (no FreeRDP here), so a build without DUO_RDP still deletes a PC's saved
// password when the PC goes, and tests can run the rules.
//
// The password: one Keychain item per PC, this device only, never synchronized, behind user presence, read only with
// the app lock's own evaluated context (so no second prompt), as the Mac passwords for Unlock Automatically are. Never
// in the stored list, list sync, logs or tests' output.
import Foundation
import LocalAuthentication
import Network
import Security

/// Where PC passwords are kept (the real Keychain, or a test double).
protocol RDPPasswordKeeping: AnyObject {
    /// Replaces this PC's item. False when the Keychain refused it.
    func save(_ password: String, pcID: String) -> Bool
    func delete(pcID: String)
    /// Every PC's item (the app lock was turned off).
    func deleteAll()
    /// Read with the app lock's evaluated context; nil when there is none or the read fails (never asks again).
    func read(pcID: String, context: LAContext) -> String?
}

final class RDPPasswordKeychain: RDPPasswordKeeping {
    static let shared = RDPPasswordKeychain()
    static let service = "com.example.duodesktop.rdp-password"

    /// The query naming one PC's item (never synchronized); nil id: every PC's.
    static func baseQuery(pcID: String?) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrSynchronizable as String: kCFBooleanFalse as Any]
        if let pcID { q[kSecAttrAccount as String] = pcID }
        return q
    }

    /// The attributes a new item is added with: this device only, never synchronized, only after user presence (the
    /// Mac password's rule, `MacPasswordKeychain.accessibility`). Tests check these.
    static func addAttributes(_ password: String, pcID: String) -> [String: Any]? {
        guard let access = SecAccessControlCreateWithFlags(nil, MacPasswordKeychain.accessibility, .userPresence, nil)
        else { return nil }
        var q = baseQuery(pcID: pcID)
        q[kSecAttrAccessControl as String] = access
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrLabel as String] = "Duo Desktop PC password"
        return q
    }

    func save(_ password: String, pcID: String) -> Bool {
        delete(pcID: pcID)
        guard !password.isEmpty, let q = Self.addAttributes(password, pcID: pcID) else { return false }
        return SecItemAdd(q as CFDictionary, nil) == errSecSuccess
    }

    func delete(pcID: String) { SecItemDelete(Self.baseQuery(pcID: pcID) as CFDictionary) }

    func deleteAll() { SecItemDelete(Self.baseQuery(pcID: nil) as CFDictionary) }

    func read(pcID: String, context: LAContext) -> String? {
        context.interactionNotAllowed = true
        var q = Self.baseQuery(pcID: pcID)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationContext as String] = context
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

/// The sign-in rules, pure (tests).
enum RDPSignIn {
    /// The app lock's evaluated context while it is passed (`AppLock.autoUnlockContext`); nil when the lock is off or
    /// not passed. Set by the app at launch.
    nonisolated(unsafe) static var appLockContext: () -> LAContext? = { nil }
    nonisolated(unsafe) static var passwords: RDPPasswordKeeping = RDPPasswordKeychain.shared

    /// Remember Password: on by default, per PC.
    static func rememberOn(_ e: MacEntry) -> Bool { e.rdpRememberPassword ?? true }

    /// Whether a password may be kept at all: only behind the app lock.
    static func canRemember(appLockOn: Bool) -> Bool { appLockOn }

    /// Save the password that just signed in? Only a typed one that Windows accepted, with Remember Password on and the
    /// app lock on. A wrong password is never saved.
    static func shouldSave(typed: Bool, accepted: Bool, remember: Bool, appLockOn: Bool) -> Bool {
        typed && accepted && remember && canRemember(appLockOn: appLockOn)
    }

    /// The saved password, read with the app lock's context; nil when Remember Password is off or nothing is saved.
    static func saved(for e: MacEntry, context: LAContext?, passwords: RDPPasswordKeeping? = nil) -> String? {
        guard rememberOn(e), let context else { return nil }
        return (passwords ?? Self.passwords).read(pcID: e.id, context: context)
    }

    /// The PIN rule (plan §4): a Microsoft account signs in with its email and its account password, never the
    /// Windows Hello PIN.
    static let pinRule = "Use the account’s password, not the Windows Hello PIN. For a Microsoft account, the user name is its email."

    /// Remember Password's footer.
    static func rememberFooter(appLockOn: Bool, lockHint: String) -> String {
        appLockOn
            ? "The password is kept only in this iPhone’s Keychain, behind the app lock. It is never synced."
            : "\(lockHint) The password is then kept only in this iPhone’s Keychain, behind the app lock."
    }

    /// Whether the takeover notice is said before this connect: not when coming back to the same session, and not
    /// when the PC's settings skip it.
    static func asksTakeover(skip: Bool, resuming: Bool) -> Bool { !skip && !resuming }
}

/// What happens when the app comes back to the front with a PC's screen open (plan §3: "Coming back reconnects to the
/// same session ... with no new password prompt").
enum RDPReturn: Equatable {
    /// Connect again at once, no prompt: Windows gives back the same session (one session per user).
    case reconnect(password: String)
    /// The password is not to hand (not remembered, and this screen did not hold one): ask for it.
    case askPassword
    /// Nothing was live when the app left.
    case nothing

    /// `held`: the password this screen signed in with, kept in memory only while the screen is open.
    static func onReturn(wasLive: Bool, held: String?, saved: () -> String?) -> RDPReturn {
        guard wasLive else { return .nothing }
        if let held, !held.isEmpty { return .reconnect(password: held) }
        if let s = saved(), !s.isEmpty { return .reconnect(password: s) }
        return .askPassword
    }
}

/// What a TCP connect to the PC's port found after a failed connect (to tell "Remote Desktop off" from "not
/// reachable").
enum RDPReach: Equatable, Sendable {
    case open
    /// The PC answered and refused the port: it is there, Remote Desktop is not listening.
    case refused
    /// No answer, no route, or the name is not known.
    case unreachable

    /// A short TCP connect (on the caller's thread, which waits up to `timeout`).
    static func probe(host: String, port: UInt16, timeout: TimeInterval = 4) -> RDPReach {
        guard let p = NWEndpoint.Port(rawValue: port) else { return .unreachable }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        let done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        var result: RDPReach?
        func finish(_ r: RDPReach) {
            let first = lock.withLock { () -> Bool in
                guard result == nil else { return false }
                result = r
                return true
            }
            if first { done.signal() }
        }
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready: finish(.open)
            case let .waiting(err), let .failed(err):
                if case let .posix(code) = err, code == .ECONNREFUSED { finish(.refused) } else { finish(.unreachable) }
            default: break
            }
        }
        conn.start(queue: .global(qos: .userInitiated))
        if done.wait(timeout: .now() + timeout) == .timedOut { finish(.unreachable) }
        conn.cancel()
        return lock.withLock { result ?? .unreachable }
    }
}

/// Plain words for why a connect failed (milestone 3's list: wrong password, account not allowed, Remote Desktop off,
/// not reachable; and a changed certificate).
enum RDPFailure {
    enum Kind: Equatable {
        case wrongPassword, notAllowed, remoteDesktopOff, notReachable, certificateChanged, certificateNotTrusted
        case passwordExpired, lockedOut, other
    }

    // FreeRDP's error.h: MAKE_FREERDP_ERROR(CONNECT, ERRCONNECT_*) = (2 << 16) | type (macros Swift cannot import).
    private static func connect(_ type: UInt32) -> UInt32 { (UInt32(2) << 16) | type }

    /// What went wrong. `reach` is asked only for the transport failures (the probe after a failed connect).
    static func kind(code: UInt32, refusedChange: Bool, reach: () -> RDPReach) -> Kind {
        if refusedChange { return .certificateChanged }
        switch code {
        case connect(0x09), connect(0x14), connect(0x15), connect(0x1B): return .wrongPassword
        case connect(0x16), connect(0x0A), connect(0x17), connect(0x1A), connect(0x12), connect(0x19): return .notAllowed
        case connect(0x0E), connect(0x0F), connect(0x13): return .passwordExpired
        case connect(0x18): return .lockedOut
        case connect(0x04), connect(0x05): return .notReachable
        case connect(0x0B): return .certificateNotTrusted
        case connect(0x06), connect(0x0D), connect(0x07), connect(0x0C), connect(0x08), connect(0x02), 0:
            switch reach() {
            case .refused: return .remoteDesktopOff
            case .unreachable: return .notReachable
            case .open: return code == connect(0x08) ? .certificateNotTrusted : .other
            }
        default: return .other
        }
    }

    static func words(_ kind: Kind, name: String, port: UInt16, detail: String = "") -> String {
        switch kind {
        case .wrongPassword:
            "Windows did not accept the user name or password. \(RDPSignIn.pinRule)"
        case .notAllowed:
            "This account is not allowed to use Remote Desktop on \(name). An administrator can add it on the PC: Start > Settings > System > Remote Desktop > Remote Desktop users."
        case .remoteDesktopOff:
            "\(name) answered, but Remote Desktop is off (nothing on port \(port)). On the PC, an administrator opens Start > Settings > System > Remote Desktop and turns on Enable Remote Desktop."
        case .notReachable:
            "\(name) is not reachable. Check that it is on and awake, and that this iPhone and the PC are on the same tailnet or home network."
        case .certificateChanged:
            "\(name)’s certificate is not the one you trusted before, so the app did not connect. Someone may be pretending to be the PC. If Windows was reinstalled or the PC renamed, open its settings (ⓘ), choose Forget Certificate, and connect again."
        case .certificateNotTrusted:
            "You did not trust \(name)’s certificate, so the app did not connect."
        case .passwordExpired:
            "Windows says this password has expired. Sign in at the PC once to change it, then connect again."
        case .lockedOut:
            "Windows has locked this account after too many wrong passwords. Wait, or sign in at the PC."
        case .other:
            detail.isEmpty ? "Could not connect to \(name)." : "Could not connect to \(name) (\(detail))."
        }
    }
}

extension RDPTrust {
    /// The full first-use trust prompt (plan §4).
    static func firstUseText(name: String, address: String, fingerprint: String) -> String {
        "This is the first time this iPhone connects to \(name) (\(address)). Windows made its own certificate for Remote Desktop, so no one else vouches for it. If you can, check that this fingerprint matches the PC’s. After you trust it, the app connects only while the PC shows this same certificate.\n\nSHA-256\n\(fingerprint)"
    }

    static let forgetText = "The app will ask again the next time you connect, and show the PC’s certificate to trust."
}
