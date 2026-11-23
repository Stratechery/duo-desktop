// Remote Desktop milestone 0 (project notes): the FreeRDP engine is linked and runs in the DUO_RDP build,
// and About names it with its licences. No PC is contacted.
#if DUO_RDP
import XCTest
import FreeRDP
@testable import DuoDesktop

final class RemoteDesktopEngineTests: XCTestCase {

    func testPinnedFreeRDPIsLinked() {
        XCTAssertEqual(RemoteDesktopEngine.freeRDPVersion, "3.33.1")
    }

    /// The engine's own objects can be made and freed (no connection is attempted).
    func testEngineInstanceCanBeCreated() {
        let instance = freerdp_new()
        XCTAssertNotNil(instance)
        freerdp_free(instance)
    }

    func testAboutListsFreeRDPAndOpenSSL() {
        let notice = AboutView.loadNotices().first { $0.id == "RemoteDesktopNotice" }
        XCTAssertEqual(AboutView.files.last?.title, "FreeRDP 3.33.1 and OpenSSL (Remote Desktop)")
        XCTAssertTrue(notice?.text.contains("== FreeRDP 3.33.1 ==") == true)
        XCTAssertTrue(notice?.text.contains("== OpenSSL 3.6.5 ==") == true)
        XCTAssertTrue(notice?.text.contains("Apache License") == true)
    }
}
#endif
