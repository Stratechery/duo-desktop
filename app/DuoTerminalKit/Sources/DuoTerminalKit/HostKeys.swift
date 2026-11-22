import Foundation
import NIOCore
import NIOSSH

/// Where the Macs' SSH host keys are kept: one per Mac on port 22, separate from the Mac's Glass Act key.
public protocol HostKeyStore: AnyObject, Sendable {
    func hostKey(for id: String) -> String?
    func setHostKey(_ key: String, for id: String)
}

/// The rule (Reviewer correction 1 to the plan): the first key seen for a Mac is trusted and stored; a later key that
/// differs is refused before any shell opens, and the stored key stays. Replacing it is a separate, deliberate step.
public enum HostKeyDecision: Equatable, Sendable {
    case trustFirstUse, matches, refuseChanged
    public static func check(stored: String?, offered: String) -> HostKeyDecision {
        guard let stored else { return .trustFirstUse }
        return stored == offered ? .matches : .refuseChanged
    }
}

public struct HostKeyChanged: Error, CustomStringConvertible, Sendable {
    public let id: String
    public let storedFingerprint: String
    public let offeredFingerprint: String
    public var description: String {
        "This Mac's SSH key has changed (stored \(storedFingerprint), offered \(offeredFingerprint)). Not connecting."
    }
}

public enum SSHKeyText {
    /// "ecdsa-sha2-nistp256 AAAA…" for a key.
    public static func line(_ key: NIOSSHPublicKey) -> String { String(openSSHPublicKey: key) }
    /// The SHA-256 fingerprint as `ssh-keygen -l` prints it ("SHA256:…", no padding).
    public static func fingerprint(_ line: String) -> String {
        let parts = line.split(separator: " ")
        guard parts.count >= 2, let blob = Data(base64Encoded: String(parts[1])) else { return "unknown" }
        return "SHA256:" + SHA256Digest.base64(blob).replacingOccurrences(of: "=", with: "")
    }
}

import CryptoKit
enum SHA256Digest {
    static func base64(_ d: Data) -> String { Data(SHA256.hash(data: d)).base64EncodedString() }
}

/// Checks the Mac's host key against the store during the SSH handshake.
public final class TOFUHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    let store: HostKeyStore
    let id: String
    public init(store: HostKeyStore, id: String) { self.store = store; self.id = id }

    public func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        let offered = SSHKeyText.line(hostKey)
        let stored = store.hostKey(for: id)
        switch HostKeyDecision.check(stored: stored, offered: offered) {
        case .trustFirstUse:
            store.setHostKey(offered, for: id)
            validationCompletePromise.succeed(())
        case .matches:
            validationCompletePromise.succeed(())
        case .refuseChanged:
            validationCompletePromise.fail(HostKeyChanged(id: id, storedFingerprint: SSHKeyText.fingerprint(stored!),
                                                          offeredFingerprint: SSHKeyText.fingerprint(offered)))
        }
    }
}

/// A store in one JSON file (the probe, tests). The app keeps its own in the app's settings.
public final class FileHostKeyStore: HostKeyStore, @unchecked Sendable {
    let url: URL
    private let lock = NSLock()
    public init(url: URL) { self.url = url }
    private func load() -> [String: String] {
        (try? JSONDecoder().decode([String: String].self, from: Data(contentsOf: url))) ?? [:]
    }
    public func hostKey(for id: String) -> String? { lock.withLock { load()[id] } }
    public func setHostKey(_ key: String, for id: String) {
        lock.withLock {
            var all = load(); all[id] = key
            try? JSONEncoder().encode(all).write(to: url, options: .atomic)
        }
    }
}

/// The store id for a Mac: its own id, port 22 (separate from the Glass Act key, which is per Glass Act port).
public func sshHostKeyID(mac: String, port: Int = 22) -> String { "ssh:\(mac):\(port)" }
