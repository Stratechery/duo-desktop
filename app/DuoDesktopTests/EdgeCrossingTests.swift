import CoreGraphics
import XCTest
@testable import DuoDesktop

/// M5, plan item 13: crossing an edge with the trackpad goes to the next screen, as at the Mac.
final class EdgeCrossingTests: XCTestCase {
    /// The test host's four fake screens (glassact-testhost --displays), in global points.
    private let four = [
        MacScreen(id: 1, name: "Main", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), isMain: true),
        MacScreen(id: 2, name: "Left 16:10", frame: CGRect(x: -1680, y: 30, width: 1680, height: 1050), isMain: false),
        MacScreen(id: 3, name: "Portrait", frame: CGRect(x: 1960, y: -420, width: 1080, height: 1920), isMain: false),
        MacScreen(id: 4, name: "Top", frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080), isMain: false),
    ]

    /// Claim: a push past Main's left edge lands on Left at the same height, just inside its right edge.
    func testPushLeftLandsOnTheNeighbourAtTheSameHeight() throws {
        let t = try XCTUnwrap(EdgeCrossing.target(from: four[0], in: four, px: -5, py: 540, width: 1920, height: 1080))
        XCTAssertEqual(t.screen.id, 2)
        XCTAssertEqual(t.x, -1)
        XCTAssertEqual(t.y, 540)
        // Half-size picture (slow link): same place on the Mac.
        let h = try XCTUnwrap(EdgeCrossing.target(from: four[0], in: four, px: -2, py: 270, width: 960, height: 540))
        XCTAssertEqual(h.y, 540)
        // Up off Main: Top, same x, just above Main.
        let up = try XCTUnwrap(EdgeCrossing.target(from: four[0], in: four, px: 700, py: -3, width: 1920, height: 1080))
        XCTAssertEqual(up.screen.id, 4)
        XCTAssertEqual(up.x, 700)
        XCTAssertEqual(up.y, -1)
    }

    /// Claim: a wall where the Mac has no screen at that spot: the gap to Portrait, the outside edges, and the
    /// part of Main's left edge above Left (Left starts 30 points lower).
    func testWallsWhereThereIsNoScreen() {
        XCTAssertNil(EdgeCrossing.target(from: four[0], in: four, px: 1925, py: 540, width: 1920, height: 1080))
        XCTAssertNil(EdgeCrossing.target(from: four[0], in: four, px: 900, py: 1085, width: 1920, height: 1080))
        XCTAssertNil(EdgeCrossing.target(from: four[0], in: four, px: -4, py: 10, width: 1920, height: 1080))
        XCTAssertNil(EdgeCrossing.target(from: four[1], in: four, px: -4, py: 500, width: 1680, height: 1050))
    }

    /// Claim: with no neighbour (wall) the trackpad stops at the edge and moves are sent as before.
    func testWallKeepsMoving() {
        let r = Recorder()
        let pad = TrackpadEngine(sink: r)
        pad.onPushPastEdge = { _, _, _, _ in false }
        pad.adopt(x: 1910, y: 500)
        pad.move(dx: 50, dy: 0, dt: 0.1)
        XCTAssertFalse(pad.switching)
        XCTAssertEqual(r.events.last, InputEvent(kind: InputKind.move, x: 1919, y: 500, a: 0, b: 0))
    }

    /// Claim: during the switch moves pause; after it the pad carries on from where the Host put the pointer.
    func testMovesPauseDuringTheSwitchThenCarryOn() {
        let r = Recorder()
        let pad = TrackpadEngine(sink: r)
        var pushed: (Double, Double)?
        pad.onPushPastEdge = { x, y, _, _ in pushed = (x, y); return true }
        pad.adopt(x: 5, y: 540)
        pad.move(dx: -50, dy: 0, dt: 0.1)
        XCTAssertTrue(pad.switching)
        XCTAssertLessThan(pushed!.0, 0)
        XCTAssertTrue(r.events.isEmpty, "the push itself sends nothing: the Host places the pointer")
        pad.move(dx: -10, dy: 0, dt: 0.1)
        XCTAssertTrue(r.events.isEmpty, "moves paused")
        pad.switchEnded(at: (x: 1679, y: 510, width: 1680, height: 1050))
        XCTAssertFalse(pad.switching)
        XCTAssertEqual(pad.canvasWidth, 1680)
        pad.move(dx: -1, dy: 0, dt: 1)
        XCTAssertEqual(r.events.last?.kind, InputKind.move)
        XCTAssertEqual(r.events.last?.y, 510)
        XCTAssertLessThan(r.events.last!.x, 1679)
    }

    /// Claim (review finding 2): a button released during the switch is kept and sent once, at the Host's
    /// confirmed pointer on the new screen; no button is left held.
    func testReleaseDuringSwitchIsOneUpAtTheNewScreen() {
        let r = Recorder()
        let pad = TrackpadEngine(sink: r)
        pad.onPushPastEdge = { _, _, _, _ in true }
        pad.adopt(x: 5, y: 540)
        pad.pressButton(0, time: 0)                   // holding a window's title bar
        pad.move(dx: -50, dy: 0, dt: 0.1)             // drag pushed off the left edge
        pad.releaseButton(0)                          // let go while the Mac switches
        XCTAssertFalse(r.events.contains { $0.kind == InputKind.buttonUp }, "held back")
        pad.switchEnded(at: (x: 1679, y: 510, width: 1680, height: 1050))
        let ups = r.events.filter { $0.kind == InputKind.buttonUp }
        XCTAssertEqual(ups, [InputEvent(kind: InputKind.buttonUp, x: 1679, y: 510, a: 1, b: 0)])
        XCTAssertTrue(pad.heldButtons.isEmpty)
        pad.switchEnded(at: (x: 1, y: 1, width: 1680, height: 1050))   // a late repeat sends nothing more
        XCTAssertEqual(r.events.filter { $0.kind == InputKind.buttonUp }.count, 1)
    }

    /// Claim: a failed switch or a disconnect lets go: the held-back up goes at the old edge, nothing stays held.
    func testFailedSwitchOrDisconnectReleases() {
        let r = Recorder()
        let pad = TrackpadEngine(sink: r)
        pad.onPushPastEdge = { _, _, _, _ in true }
        pad.adopt(x: 5, y: 540)
        pad.pressButton(0, time: 0)
        pad.move(dx: -50, dy: 0, dt: 0.1)
        pad.releaseButton(0)
        pad.switchEnded(at: nil)                      // refused
        XCTAssertEqual(r.events.filter { $0.kind == InputKind.buttonUp },
                       [InputEvent(kind: InputKind.buttonUp, x: 0, y: 540, a: 1, b: 0)])
        // A disconnect during a switch with the button still down: one up, nothing held, not paused.
        let r2 = Recorder()
        let pad2 = TrackpadEngine(sink: r2)
        pad2.onPushPastEdge = { _, _, _, _ in true }
        pad2.adopt(x: 5, y: 540)
        pad2.pressButton(0, time: 0)
        pad2.move(dx: -50, dy: 0, dt: 0.1)
        pad2.releaseAll()
        XCTAssertEqual(r2.events.filter { $0.kind == InputKind.buttonUp }.count, 1)
        XCTAssertFalse(pad2.switching)
        XCTAssertTrue(pad2.heldButtons.isEmpty)
    }
}
