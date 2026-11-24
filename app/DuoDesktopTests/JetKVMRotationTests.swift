#if DUO_JETKVM
import GlassActTransport
import JetKVMProtocol
import JetKVMClient
import XCTest
@testable import DuoDesktop

/// Turning the phone with the JetKVM open must not reconnect, a real reconnect must succeed, and keys typed before
/// the input channel opens must be said in the log. The fake link: `startSession` records the start and connects
/// nowhere; a recorder stands in for the JetKVM's input. Made-up names only.
@MainActor
final class JetKVMRotationTests: XCTestCase {
    private var access: AppAccess.State = .locked
    override func setUp() async throws { access = AppAccess.state; AppAccess.set(.open) }
    override func tearDown() async throws { AppAccess.set(access) }

    final class Recorder: JetKVMOutput {
        var log: [String] = []
        func sendKeyboard(modifiers: HIDRPC.Modifiers, keys: [UInt8]) { log.append("kb \(modifiers.rawValue) \(keys)") }
        func sendPointerDelta(dx: Int, dy: Int, buttons: HIDRPC.Buttons?) {}
        func sendScroll(dy: Int, dx: Int) {}
    }

    private func entry() throws -> MacEntry {
        try JSONDecoder().decode(MacEntry.self, from: Data(
            #"{"id":"TURN-\#(UUID().uuidString)","name":"Turn Test","port":4433,"layout":"standard","jetkvm":true,"jetkvmAddress":"jetkvm-turn.example.ts.net"}"#.utf8))
    }

    private func fakeLink(_ e: MacEntry) -> JetKVMLink {
        let link = JetKVMLink.for(mac: e.id)
        link.readPassword = { _ in "made-up" }
        link.retryDelay = .milliseconds(20)
        link.startSession = { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
        return link
    }

    private func wait(until ok: () -> Bool, _ s: Double = 3) async {
        let end = Date().addingTimeInterval(s)
        while !ok() && Date() < end { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// Claim: the JetKVM-only screen holds the link above the upright/sideways switch, so a turn in EITHER order
    /// (old picture view gone before the new one appears: the order that reconnected) neither closes nor reopens
    /// the link. Count of connects stays 1.
    func testTurnOnTheJetKVMScreenNeverReconnects() async throws {
        let e = try entry(), link = fakeLink(e)
        link.panelAppeared(entry: e)       // the screen (JetKVMOnlyScreen.onAppear)
        link.panelAppeared(entry: e)       // the upright picture
        await wait { link.starts == 1 }
        let first = link.session
        for _ in 0..<3 {                   // upright → sideways → upright → sideways, old view goes FIRST
            link.panelDisappeared()
            link.panelAppeared(entry: e)
        }
        try await Task.sleep(for: .milliseconds(1200))   // past the release grace
        XCTAssertTrue(link.session === first, "the same session goes on")
        XCTAssertEqual(link.starts, 1, "count of connects stays 1")
        link.panelDisappeared(); link.panelDisappeared()  // back to the list
        await wait { link.session == nil }
        XCTAssertNil(link.session, "leaving still lets go")
    }

    /// Claim: with no screen holding the link (a Mac session's JetKVM view), the old picture view going first only
    /// schedules the disconnect; the new view appearing within the grace cancels it. No reconnect.
    func testPictureSwapOldFirstKeepsTheSession() async throws {
        let e = try entry(), link = fakeLink(e)
        link.panelAppeared(entry: e)
        await wait { link.starts == 1 }
        let first = link.session
        link.panelDisappeared()            // old one goes first: count 0
        XCTAssertTrue(link.session === first, "not closed at once")
        link.panelAppeared(entry: e)       // the new one, same update
        try await Task.sleep(for: .milliseconds(1200))
        XCTAssertTrue(link.session === first)
        XCTAssertEqual(link.starts, 1)
        link.releaseGrace = .zero
        link.panelDisappeared()
        XCTAssertNil(link.session)
        link.releaseGrace = .milliseconds(800)
    }

    /// Claim: a forced drop (network gone, back from the background) reconnects once: the old session is closed
    /// first, the new start waits for the JetKVM to let the old one go, then runs once and does not fail.
    func testForcedDropReconnectsOnceAfterClosingTheOld() async throws {
        let e = try entry(), link = fakeLink(e)
        link.settleAfterClose = .milliseconds(300)
        link.panelAppeared(entry: e)
        await wait { link.starts == 1 }
        let old = try XCTUnwrap(link.session)
        var startedAt: ContinuousClock.Instant?
        link.startSession = { _ in startedAt = .now }   // the reconnect's start succeeds
        let dropped = ContinuousClock.now
        link.disconnect()                  // the drop (as the app going to the background)
        XCTAssertEqual(old.state, .disconnected, "the old session is closed before anything new starts")
        link.connect(entry: e)             // back (JetKVMPanel: scene active)
        XCTAssertFalse(link.session === old)
        await wait { link.starts == 2 }
        XCTAssertEqual(link.starts, 2, "one reconnect")
        XCTAssertEqual(link.settledStarts, 1, "it waited for the old session to be let go")
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(startedAt) - dropped, .milliseconds(290))
        try await Task.sleep(for: .milliseconds(100))
        if case .failed = link.status { XCTFail("the reconnect failed: \(link.status)") }
        XCTAssertTrue(link.log.joined().contains("waiting for the JetKVM to let go of the old session"))
        link.releaseGrace = .zero
        link.panelDisappeared()
        link.releaseGrace = .milliseconds(800)
    }

    /// Claim: a typed key reaches the link upright (the system keyboard's path: `MacTypingView.insertText`),
    /// sideways (our own keyboard: `TouchKeyboardModel`), and after a reconnect the link's input goes to the NEW
    /// session (the typing views never held the old one).
    func testTypedKeyReachesTheLinkInBothPosesAndAfterReconnect() async throws {
        let e = try entry(), link = fakeLink(e)
        link.settleAfterClose = .zero
        link.panelAppeared(entry: e)
        let rec = Recorder()
        link.input.output = rec

        // Upright, open Duo: the hidden typing field, as JetKVMOnlyScreen.duoLayout makes it.
        let field = MacTypingView(frame: .zero)
        field.engine = link.parts.keyboard.engine
        field.insertText("a")
        XCTAssertEqual(rec.log, ["kb 0 [4]", "kb 0 []"], "upright: the system keyboard's 'a' reaches the link")

        // Sideways: our own keyboard, as JetKVMOnlyScreen's TouchKeyboardModel.
        rec.log = []
        let own = TouchKeyboardModel(engine: link.parts.keyboard.engine)
        own.lifted(.char("b"))
        XCTAssertEqual(rec.log, ["kb 0 [5]", "kb 0 []"], "sideways: our keyboard's 'b' reaches the link")

        // A reconnect: the link's input now points at the new session; the same field and keyboard feed it.
        link.reconnect(entry: e)
        XCTAssertNotNil(link.session)
        XCTAssertTrue(link.input.output === link.session, "keys go to the new session")
        link.input.output = rec            // stand in for the new session to see the key arrive
        rec.log = []
        field.insertText("c")
        XCTAssertEqual(rec.log, ["kb 0 [6]", "kb 0 []"], "after a reconnect: the same typing field reaches the link")
        link.releaseGrace = .zero
        link.panelDisappeared()
        link.releaseGrace = .milliseconds(800)
    }
}
#endif
