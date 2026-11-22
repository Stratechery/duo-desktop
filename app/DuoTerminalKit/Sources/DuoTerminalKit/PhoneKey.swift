import CryptoKit
import Foundation
import NIOSSH
import Security

/// The phone's own SSH key (P-256): in the Secure Enclave where there is one, otherwise a Keychain item; a plain
/// file for tests and the probe. Only the public half ever leaves the device.
public struct PhoneKey: @unchecked Sendable {
    public let sshKey: NIOSSHPrivateKey
    public let publicKeyText: String   // "ecdsa-sha2-nistp256 AAAA…" (no comment)
    public let kind: String            // "Secure Enclave", "Keychain", "file"

    init(software k: P256.Signing.PrivateKey, kind: String) {
        sshKey = NIOSSHPrivateKey(p256Key: k)
        publicKeyText = SSHKeyText.line(sshKey.publicKey)
        self.kind = kind
    }
    init(enclave k: SecureEnclave.P256.Signing.PrivateKey) {
        sshKey = NIOSSHPrivateKey(secureEnclaveP256Key: k)
        publicKeyText = SSHKeyText.line(sshKey.publicKey)
        kind = "Secure Enclave"
    }

    /// The line for `authorized_keys`.
    public func authorizedKeysLine(comment: String) -> String { "\(publicKeyText) \(comment)" }

    /// A throwaway key kept in a file (tests, the probe, the simulator).
    public static func file(_ url: URL) throws -> PhoneKey {
        if let d = try? Data(contentsOf: url) {
            return PhoneKey(software: try P256.Signing.PrivateKey(rawRepresentation: d), kind: "file")
        }
        let k = P256.Signing.PrivateKey()
        try k.rawRepresentation.write(to: url, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return PhoneKey(software: k, kind: "file")
    }

    /// The phone's key, made once and kept: Secure Enclave when available, else a Keychain item.
    public static func device(tag: String = "com.example.duodesktop.ssh-key") throws -> PhoneKey {
        if let d = keychainRead(tag) {
            if SecureEnclave.isAvailable, let k = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: d) {
                return PhoneKey(enclave: k)
            }
            if let k = try? P256.Signing.PrivateKey(rawRepresentation: d) { return PhoneKey(software: k, kind: "Keychain") }
        }
        if SecureEnclave.isAvailable, let k = try? SecureEnclave.P256.Signing.PrivateKey() {
            try keychainWrite(tag, k.dataRepresentation)   // an opaque handle; the key itself never leaves the enclave
            return PhoneKey(enclave: k)
        }
        let k = P256.Signing.PrivateKey()
        try keychainWrite(tag, k.rawRepresentation)
        return PhoneKey(software: k, kind: "Keychain")
    }

    struct KeychainError: Error { let status: OSStatus }
    static func keychainRead(_ tag: String) -> Data? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: tag,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
    }
    static func keychainWrite(_ tag: String, _ data: Data) throws {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: tag,
                                kSecValueData as String: data,
                                kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        let s = SecItemAdd(q as CFDictionary, nil)
        guard s == errSecSuccess else { throw KeychainError(status: s) }
    }
}
