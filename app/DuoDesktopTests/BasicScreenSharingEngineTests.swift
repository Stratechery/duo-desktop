// Milestone 0 of project notes: our RoyalVNCKit copy is linked and runs in the DUO_VNC build, and About names it with
// its licences. No computer is contacted. (The library's own sign-in tests are in../royalvnc/Tests: `swift test`
// there.)
#if DUO_VNC
import XCTest
import RoyalVNCKit
@testable import DuoDesktop

final class BasicScreenSharingEngineTests: XCTestCase {

    /// A connection object can be made from our settings (no connect is called), with clipboard polling off.
    func testConnectionCanBeCreatedWithoutConnecting() {
        let settings = BasicScreenSharingEngine.settings(host: "mac.example.invalid")
        XCTAssertEqual(settings.port, 5900)
        XCTAssertFalse(settings.isClipboardRedirectionEnabled)
        let connection = VNCConnection(settings: settings)
        XCTAssertEqual(connection.connectionState.status, .disconnected)
    }

    func testAboutListsRoyalVNCKitAndCryptoSwift() {
        XCTAssertTrue(AboutView.files.contains { $0.title == "RoyalVNCKit and CryptoSwift (Basic Screen Sharing)" })
        let notice = AboutView.loadNotices().first { $0.id == "BasicScreenSharingNotice" }
        XCTAssertTrue(notice?.text.contains("== RoyalVNCKit (commit \(BasicScreenSharingEngine.royalVNCKitCommit)) ==") == true)
        XCTAssertTrue(notice?.text.contains("== CryptoSwift 1.9.0 ==") == true)
        XCTAssertTrue(notice?.text.contains("Copyright (c) 2025 Royal Apps") == true)
    }
}
#endif
