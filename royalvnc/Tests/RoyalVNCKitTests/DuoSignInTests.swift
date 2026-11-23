// Duo Desktop's tests for its changes to RoyalVNCKit: the three sign-in fixes (#41 to #43, modelled on the tests
// described in upstream's unmerged #48) and the Mac-account-only security choice (review finding 1).
// No network: the Diffie-Hellman exchange is played out in memory, and the encrypted fields are opened with Apple's
// own MD5 and AES (CryptoKit, CommonCrypto), not with the library's.
import XCTest
import CommonCrypto
import CryptoKit
@testable import RoyalVNCKit

final class DuoSignInTests: XCTestCase {
    typealias Agreement = VNCProtocol.ARDAuthentication.DiffieHellmanKeyAgreement
    typealias Authentication = VNCProtocol.ARDAuthentication.Authentication

    // RFC 2409 Oakley group 2: a 1024-bit prime, generator 2 (the size a Mac sends).
    static let prime1024 = Data(hex: """
        FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E088A67CC74020BBEA63B139B22514A08798E3404DD\
        EF9519B3CD3A431B302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9A637ED6B0BFF5CB6F406B7ED\
        EE386BFB5A899FA5AE9F24117C4B1FE649286651ECE65381FFFFFFFFFFFFFFFF
        """)
    static let generator2 = Data([0x00, 0x02])

    /// The server's side: a private number and its public value g^b mod p, at full width.
    struct Server {
        let b: BigNum
        let publicKey: Data
        init(prime: Data, generator: Data) {
            let p = BigNum(data: prime)!
            var b: BigNum
            repeat { b = BigNum.randomNumber(lessThan: p) } while b.isLessThan(2)
            self.b = b
            publicKey = BigNum(data: generator)!.power(exponent: b, modulus: p)
                .fixedWidthBigEndianData(length: prime.count)!
        }
        func sharedSecret(clientPublicKey: Data, prime: Data) -> Data {
            BigNum(data: clientPublicKey)!.power(exponent: b, modulus: BigNum(data: prime)!)
                .fixedWidthBigEndianData(length: prime.count)!
        }
    }

    /// What the Mac reads: AES-128-ECB with MD5(shared secret) as the key, opened, then split into the two
    /// NUL-terminated 64-byte fields.
    func openCredentials(_ auth: Authentication, server: Server, prime: Data) -> (name: Data, password: Data) {
        let secret = server.sharedSecret(clientPublicKey: auth.publicKey, prime: prime)
        let key = Data(Insecure.MD5.hash(data: secret))
        XCTAssertEqual(auth.cipherText.count, 128)
        var plain = Data(count: 128)
        var moved = 0
        let status = plain.withUnsafeMutableBytes { out in
            auth.cipherText.withUnsafeBytes { inp in
                key.withUnsafeBytes { k in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionECBMode),
                            k.baseAddress, 16, nil, inp.baseAddress, 128, out.baseAddress, 128, &moved)
                }
            }
        }
        XCTAssertEqual(status, CCCryptorStatus(kCCSuccess))
        func field(_ start: Int) -> Data {
            let f = plain[start..<(start + 64)]
            return Data(f.prefix(while: { $0 != 0 }))
        }
        return (field(0), field(64))
    }

    func agreement(_ server: Server) -> Agreement {
        Agreement(prime: Self.prime1024, generator: Self.generator2, peerKey: server.publicKey, keyLength: 128)!
    }

    // #41: 63 UTF-8 bytes fit and arrive whole; 64 are refused (not cut, not run into the password field).
    func testCredentialBoundary63And64Bytes() {
        let server = Server(prime: Self.prime1024, generator: Self.generator2)
        let name63 = String(repeating: "n", count: 63), password63 = String(repeating: "p", count: 63)
        let auth = Authentication(agreement: agreement(server), username: name63, password: password63)!
        let opened = openCredentials(auth, server: server, prime: Self.prime1024)
        XCTAssertEqual(opened.name, Data(name63.utf8))
        XCTAssertEqual(opened.password, Data(password63.utf8))

        XCTAssertNil(Authentication(agreement: agreement(server), username: name63 + "n", password: "pw"))
        XCTAssertNil(Authentication(agreement: agreement(server), username: "me", password: password63 + "p"))
        XCTAssertNil(Authentication(agreement: agreement(server), username: "a\u{0}b", password: "pw"))
    }

    // #41: multi-byte names and passwords are measured in UTF-8 bytes. Upstream cut 63 *characters*, so 40 "é"
    // (80 bytes) ran past the 64-byte name field into the password.
    func testMultiByteNameAndPasswordStayInTheirFields() {
        let server = Server(prime: Self.prime1024, generator: Self.generator2)
        let name = "Zoë Ångström", password = "pässwörd ✓"
        let auth = Authentication(agreement: agreement(server), username: name, password: password)!
        let opened = openCredentials(auth, server: server, prime: Self.prime1024)
        XCTAssertEqual(String(data: opened.name, encoding: .utf8), name)
        XCTAssertEqual(String(data: opened.password, encoding: .utf8), password)

        let thirtyOne = String(repeating: "é", count: 31) // 62 bytes: fits
        XCTAssertNotNil(Authentication(agreement: agreement(server), username: thirtyOne, password: "pw"))
        let forty = String(repeating: "é", count: 40) // 40 characters but 80 bytes: refused
        XCTAssertNil(Authentication(agreement: agreement(server), username: forty, password: "pw"))
        XCTAssertNil(Authentication(agreement: agreement(server), username: "me", password: forty))
    }

    // #42: values with a leading zero byte keep the server's width, and both sides reach the same secret. The
    // modulus here starts with 0x01, so about half of all values have a leading zero byte; upstream refused those.
    func testLeadingZeroKeysKeepFullWidth() {
        var prime = Data([0x01]) + Data((0..<15).map { _ in UInt8.random(in: 0...255) })
        prime[15] |= 1 // odd, as the check requires
        var sawLeadingZero = false
        for _ in 0..<64 {
            let server = Server(prime: prime, generator: Data([0x02]))
            guard let a = Agreement(prime: prime, generator: Data([0x02]), peerKey: server.publicKey,
                                    keyLength: 16) else { return XCTFail("agreement refused") }
            XCTAssertEqual(a.publicKey.count, 16)
            XCTAssertEqual(a.secretKey.count, 16)
            XCTAssertEqual(a.secretKey, server.sharedSecret(clientPublicKey: a.publicKey, prime: prime))
            if a.publicKey.first == 0 || a.secretKey.first == 0 { sawLeadingZero = true }
        }
        XCTAssertTrue(sawLeadingZero)
    }

    // #43: bad values from the server are refused before any arithmetic.
    func testBadServerValuesAreRefused() {
        let p = Self.prime1024, g = Self.generator2
        let good = Server(prime: p, generator: g).publicKey
        var pm1 = p; pm1[127] -= 1 // p - 1 (p ends in 0xFF)
        func accepts(_ prime: Data, _ gen: Data, _ peer: Data, _ len: Int) -> Bool {
            Agreement.acceptsParameters(prime: prime, generator: gen, peerKey: peer, keyLength: len)
        }
        XCTAssertTrue(accepts(p, g, good, 128))
        XCTAssertFalse(accepts(p, g, good, 0), "key size 0")
        XCTAssertFalse(accepts(Data(count: 600), g, Data(count: 600), 600), "key size over 512")
        XCTAssertFalse(accepts(p, g, good.dropFirst(), 128), "peer key shorter than the key size")
        XCTAssertFalse(accepts(Data(count: 128), g, good, 128), "zero modulus")
        var even = p; even[127] = 0xFE
        XCTAssertFalse(accepts(even, g, good, 128), "even modulus")
        XCTAssertFalse(accepts(p, Data([0, 0]), good, 128), "generator 0")
        XCTAssertFalse(accepts(p, Data([0, 1]), good, 128), "generator 1")
        XCTAssertFalse(accepts(p, Data([0, 0, 2]), good, 128), "3-byte generator")
        XCTAssertFalse(accepts(p, g, Data(count: 127) + Data([1]), 128), "peer key 1")
        XCTAssertFalse(accepts(p, g, pm1, 128), "peer key p - 1")
        XCTAssertFalse(accepts(p, g, p, 128), "peer key p")
        XCTAssertNil(Agreement(prime: p, generator: g, peerKey: pm1, keyLength: 128))
    }

    // Review finding 1: only type 30 (the Mac's own account) is chosen; "none" (1) and the VNC password (2) never are, and a
    // server without 30 is refused.
    func testOnlyMacAccountSignInIsChosen() {
        XCTAssertEqual(VNCConnection.duoSecurityType(offered: [1, 2, 30]), .diffieHellman)
        XCTAssertEqual(VNCConnection.duoSecurityType(offered: [30, 1]), .diffieHellman)
        XCTAssertNil(VNCConnection.duoSecurityType(offered: [1, 2, 16, 113]))
        XCTAssertNil(VNCConnection.duoSecurityType(offered: []))
        let error = VNCError.AuthenticationError.macAccountSignInNotOffered(offered: [1, 2])
        XCTAssertEqual(error.errorDescription,
                       "This computer does not offer sign-in with a Mac account (it offered: 1, 2).")
    }
}

private extension Data {
    init(hex: String) {
        let chars = Array(hex.filter { !$0.isWhitespace })
        self.init(stride(from: 0, to: chars.count, by: 2).map { UInt8(String(chars[$0...$0 + 1]), radix: 16)! })
    }
}
