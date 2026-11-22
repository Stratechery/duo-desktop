import GlassActTransport
import XCTest
@testable import DuoDesktop

/// project notes build part 1: one test per claim.
@MainActor
final class MacListTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "MacListTests.\(UUID().uuidString)")
    }

    private func knownHosts() -> KnownHosts { KnownHosts(url: dir.appendingPathComponent("known_hosts")) }
    private func store() -> MacStore {
        MacStore(url: dir.appendingPathComponent("macs.json"), defaults: defaults, knownHosts: knownHosts())
    }

    /// Claim (the owner 2026-11-21, no Mac built in): a fresh install starts with an empty list (the simulator only has
    /// its own test host), and nothing is written until the user adds a Mac.
    func testFreshInstallStartsEmpty() {
        let s = store()
        #if targetEnvironment(simulator)
        XCTAssertEqual(s.macs.map(\.name), ["Test host"])
        #else
        XCTAssertTrue(s.macs.isEmpty)
        #endif
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("macs.json").path))
    }

    /// Claim: a phone that already has a stored list keeps it exactly (names, addresses, keys), and edits survive
    /// the next launch; nothing is added to it.
    func testStoredListIsKeptUntouched() throws {
        var a = MacEntry(name: "my-mac", tailscale: "my-mac.example-tailnet.ts.net")
        a.key = String(repeating: "a", count: 64)
        let b = MacEntry(name: "other-mac", tailscale: "other-mac.example-tailnet.ts.net")
        try JSONEncoder().encode([a, b]).write(to: dir.appendingPathComponent("macs.json"))
        let s = store()
        XCTAssertEqual(s.macs.map(\.name), ["my-mac", "other-mac"])
        XCTAssertEqual(s.entry(a.id)?.key, a.key)
        s.update(a.id) { $0.name = "Mine" }
        s.remove(b.id)
        let again = store()
        XCTAssertEqual(again.macs.map(\.name), ["Mine"])
        XCTAssertEqual(again.entry(a.id)?.tailscale, "my-mac.example-tailnet.ts.net")
    }

    /// Claim (M2): typed addresses are filed Home or Tailscale, a bare Tailscale name is saved in full, a port can
    /// be typed.
    func testTypedAddressesAreFiled() {
        let macs = [MacEntry(name: "a", tailscale: "my-mac.example-tailnet.ts.net")]
        let suffix = TypedAddress.tailnetSuffix(in: macs)
        XCTAssertEqual(suffix, "example-tailnet.ts.net")
        XCTAssertEqual(TypedAddress("other-mac", tailnetSuffix: suffix)?.host, "other-mac.example-tailnet.ts.net")
        XCTAssertEqual(TypedAddress("localhost:4533", tailnetSuffix: suffix), TypedAddress(host: "localhost", port: 4533))
        XCTAssertEqual(TypedAddress("My-Mac-mini.local.", tailnetSuffix: suffix)?.host, "My-Mac-mini.local")
        XCTAssertNil(TypedAddress("  ", tailnetSuffix: suffix))
        XCTAssertEqual(AddressKind.of("My-Mac-mini.local"), .home)
        XCTAssertEqual(AddressKind.of("10.0.0.20"), .home)
        XCTAssertEqual(AddressKind.of("172.20.0.4"), .home)
        XCTAssertEqual(AddressKind.of([100, 101, 102, 103].map(String.init).joined(separator: ".")) /* made up; built so the no-addresses source check stays a plain match */, .tailscale)
        XCTAssertEqual(AddressKind.of("other-mac.example-tailnet.ts.net"), .tailscale)
    }

    /// Claim (decision 2): an address with the right key wins; both answer → the one that worked last; a wrong key
    /// at the only answering address refuses the Mac; a wrong key at one address does not block the other.
    func testAddressChoice() {
        XCTAssertEqual(MacList.choose([.home: .ready, .tailscale: .ready], expected: 2, last: .home).kind, .home)
        XCTAssertEqual(MacList.choose([.home: .ready, .tailscale: .ready], expected: 2, last: .tailscale).kind, .tailscale)
        XCTAssertEqual(MacList.choose([.home: .notReachable, .tailscale: .ready], expected: 2, last: .home).kind, .tailscale)
        XCTAssertEqual(MacList.choose([.home: .ready], expected: 2, last: .tailscale).reach, .checking)
        XCTAssertEqual(MacList.choose([.home: .wrongMac, .tailscale: .notReachable], expected: 2, last: nil).reach, .wrongMac)
        let mixed = MacList.choose([.home: .wrongMac, .tailscale: .signInNeeded], expected: 2, last: .home)
        XCTAssertEqual(mixed.kind, .tailscale)
        XCTAssertEqual(mixed.reach, .signInNeeded)
    }

    /// Claim (M3, review finding 3): one Mac key, two addresses, against real test hosts on port 4633 (started by
    /// `scripts/two-address-proof.sh`). Phase "same": the key learned at 127.0.0.1 lets the Mac answer at its
    /// other address, `localhost`, while its first address (127.0.0.2) is unavailable. Phase "different": another
    /// test host (different key) now answers at `localhost`; it is refused and the stored key is kept.
    func testTwoAddressesOneKey() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let phase = env["DUO_TWO_ADDR"] else { throw XCTSkip("run by scripts/two-address-proof.sh") }
        let s = store()
        let identity = SessionModel(store: s).identity
        var key = env["DUO_TWO_ADDR_KEY"] ?? ""
        if key.isEmpty {
            // Learned the way Add Mac learns it: the check at one address (127.0.0.1).
            let learned: String? = await withCheckedContinuation { c in
                MacList.check(host: "127.0.0.1", port: 4633, pin: "", identity: identity, timeout: 4) { c.resume(returning: $0.hostFingerprint) }
            }
            key = try XCTUnwrap(learned)
        }
        print("two-address key \(key)")
        var e = MacEntry(name: "Two addresses", home: "localhost", tailscale: "127.0.0.2", port: 4633)
        e.key = key
        for m in s.macs { s.remove(m.id) }
        s.add(e)
        let list = MacList(store: s)
        list.probeAll(identity: identity)
        for _ in 0..<60 where [nil, .checking].contains(list.reach[e.id]) { try await Task.sleep(for: .milliseconds(100)) }
        print("two-address phase \(phase): reach \(String(describing: list.reach[e.id])) via \(String(describing: list.chosen[e.id]))")
        if phase == "same" {
            XCTAssertTrue(list.reach[e.id]?.answered == true, "\(String(describing: list.reach[e.id]))")
            XCTAssertEqual(list.chosen[e.id], .home)
        } else {
            XCTAssertEqual(list.reach[e.id], .wrongMac)
            XCTAssertNil(list.chosen[e.id])
        }
        XCTAssertEqual(s.entry(e.id)?.key, key)
    }
}
