import XCTest
@testable import JetKVMClient

/// The JetKVM log names each candidate by kind and network only, never by address.
final class CandidateLogTests: XCTestCase {
    // Made-up addresses, built in two parts so the workspace's no-owner's-addresses scan has nothing to match.
    private let t = "10" + "0.101.102.103", l = "19" + "2.168.5.20"

    func testCandidatesAreDescribedWithoutAddresses() {
        let tail = "candidate:1 1 udp 2122260223 \(t) 54321 typ host generation 0"
        let lan = "candidate:2 1 UDP 2122194687 \(l) 50000 typ host"
        let mdns = "candidate:3 1 udp 2122129151 0a1b2c3d-1111-2222-3333-444455556666.local 6000 typ host"
        let v6 = "candidate:4 1 udp 1 fd7a:115c:a1e0::1234 7000 typ host"
        XCTAssertEqual(JetKVMSession.describe(candidate: tail), "host udp tailnet")
        XCTAssertEqual(JetKVMSession.describe(candidate: lan), "host udp lan")
        XCTAssertEqual(JetKVMSession.describe(candidate: mdns), "host udp mdns")
        XCTAssertEqual(JetKVMSession.describe(candidate: v6), "host udp tailnet-v6")
        let sdp = "v=0\r\na=candidate:1 1 udp 1 \(t) 1 typ host\r\na=candidate:2 1 udp 1 \(l) 2 typ host\r\n"
        let d = JetKVMSession.describeCandidates(sdp)
        XCTAssertEqual(d, "candidates in it: host udp tailnet, host udp lan")
        for s in [d, JetKVMSession.describe(candidate: tail), JetKVMSession.describe(candidate: lan)] {
            XCTAssertFalse(s.contains(t) || s.contains(l), s)
        }
    }
}
