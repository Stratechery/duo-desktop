// Milestone 2 of the Remote Desktop plan (pointer and keys), proven without a PC: one test per claim. The
// events come from the same engines a Mac's session uses (trackpad, keys, typing) through `RDPInput`; a recorder
// stands in for the session. No connection is made.
import XCTest
@testable import DuoDesktop
import GlassActSession

@MainActor
final class RemoteDesktopM2Tests: XCTestCase {
    private final class Recorder: RDPOutput {
        var events: [RDPEvent] = []
        func send(_ event: RDPEvent) { events.append(event) }
    }

    private var rec = Recorder()
    private var input = RDPInput()
    private var parts: SessionParts!

    override func setUp() {
        rec = Recorder()
        input = RDPInput()
        input.isOpen = { true }
        input.output = rec
        input.canvas = (1920, 1080)
        parts = SessionParts(sink: input)
        parts.setCanvas(width: 1920, height: 1080, fullWidth: 1920)
        parts.trackpad.adopt(x: 960, y: 540)
        let i = input
        parts.keyboard.engine.typeText = { c in i.type(c) }
    }

    private func mouse(_ f: UInt16, _ x: UInt16, _ y: UInt16) -> RDPEvent { .mouse(flags: f, x: x, y: y) }

    /// Claim: a trackpad move becomes a pointer MOVE to the pointer's place in the session's 1920 x 1080 desktop.
    func testMoveIsPointerMove() {
        parts.trackpad.move(dx: 10, dy: -5, dt: 1)
        guard case let .mouse(f, x, y)? = rec.events.last else { return XCTFail("\(rec.events)") }
        XCTAssertEqual(f, RDPFlags.move)
        XCTAssertGreaterThan(x, 960)
        XCTAssertLessThan(y, 540)
    }

    /// Claim: a one-finger tap is a left click: move, BUTTON1 down, BUTTON1 up, at the pointer.
    func testTapIsLeftClick() {
        parts.trackpad.tap(button: 0, at: .zero, time: 0)
        XCTAssertEqual(rec.events, [mouse(0x0800, 960, 540), mouse(0x9000, 960, 540), mouse(0x1000, 960, 540)])
    }

    /// Claim: a two-finger tap (and the Right click button) is a right click: BUTTON2 down and up.
    func testTwoFingerTapIsRightClick() {
        parts.trackpad.tap(button: 1, at: .zero, time: 0)
        XCTAssertEqual(rec.events, [mouse(0x0800, 960, 540), mouse(0xA000, 960, 540), mouse(0x2000, 960, 540)])
        rec.events = []
        parts.trackpad.pressButton(1, time: 5)
        parts.trackpad.releaseButton(1)
        XCTAssertEqual(rec.events.filter { if case .mouse(let f, _, _) = $0 { return f & 0x2000 != 0 }; return false },
                       [mouse(0xA000, 960, 540), mouse(0x2000, 960, 540)])
    }

    /// Claim: a drag is press, moves, release: BUTTON1 down, MOVE with the button held, BUTTON1 up where it ended.
    func testDragIsPressMoveRelease() {
        parts.trackpad.beginDrag()
        parts.trackpad.move(dx: 40, dy: 0, dt: 1)
        parts.trackpad.endDrag()
        XCTAssertEqual(rec.events.count, 3)
        XCTAssertEqual(rec.events.first, mouse(0x9000, 960, 540))
        guard case let .mouse(f, x, _) = rec.events[1], case let .mouse(f2, x2, _) = rec.events[2] else {
            return XCTFail("\(rec.events)")
        }
        XCTAssertEqual(f, RDPFlags.move)
        XCTAssertGreaterThan(x, 960)
        XCTAssertEqual(f2, RDPFlags.left)
        XCTAssertEqual(x2, x)
    }

    /// Claim: scroll goes as wheel turns with the Mac view's direction (content follows the fingers): fingers down
    /// is the wheel forward (positive, 120 a notch), fingers up negative (9-bit, WHEEL_NEGATIVE), fingers right the
    /// horizontal wheel negative.
    func testScrollDirection() {
        parts.trackpad.scroll(dx: 0, dy: 12)
        XCTAssertEqual(rec.events, [mouse(0x0200 | 120, 960, 540)])
        rec.events = []
        parts.trackpad.scroll(dx: 0, dy: -12)
        XCTAssertEqual(rec.events, [mouse(0x0200 | 0x0100 | UInt16(0x100 - 120), 960, 540)])
        rec.events = []
        parts.trackpad.scroll(dx: 12, dy: 0)
        XCTAssertEqual(rec.events, [mouse(0x0400 | 0x0100 | UInt16(0x100 - 120), 960, 540)])
    }

    /// Claim: typed text goes as Unicode key events (press, release), capitals and symbols as their characters,
    /// and a character no US key types (é) too.
    func testTypedTextIsUnicode() {
        let engine = parts.keyboard.engine
        for c in "Hi!é" { MacTyping.type(c, into: engine) }
        let want: [RDPEvent] = "Hi!é".utf16.flatMap { [RDPEvent.unicode(flags: 0, code: $0),
                                                       .unicode(flags: RDPFlags.keyRelease, code: $0)] }
        XCTAssertEqual(rec.events, want)
    }

    /// Claim: ⌃ ⌥ ⌘ become Ctrl (1D), Alt (38) and the Windows key (E0 5B), pressed before the key and released
    /// after it; the key itself then goes as its scan code (C = 2E), not as text.
    func testModifiersAreCtrlAltWindows() {
        let engine = parts.keyboard.engine
        let c = MacTyping.keys["c"]!
        for (m, scan) in [(KeyMap.Modifier.control, RDPKeys.ctrl), (.option, RDPKeys.alt), (.command, RDPKeys.windows)] {
            rec.events = []
            engine.tapModifier(m)
            engine.keyDown(c)
            engine.keyUp(c)
            let ext: UInt16 = scan.extended ? 0x0100 : 0
            XCTAssertEqual(rec.events, [.key(flags: ext, code: scan.code), .key(flags: 0, code: 0x2E),
                                        .key(flags: 0x8000, code: 0x2E), .key(flags: ext | 0x8000, code: scan.code)],
                           "\(m)")
        }
        XCTAssertEqual(RDPKeys.windows, RDPKeys.Scan(code: 0x5B, extended: true))
        // Named keys go as scan codes: ← is E0 4B.
        rec.events = []
        engine.keyDown(MacKeyboardLayout.left)
        engine.keyUp(MacKeyboardLayout.left)
        XCTAssertEqual(rec.events, [.key(flags: 0x0100, code: 0x4B), .key(flags: 0x8100, code: 0x4B)])
    }

    /// Claim: Follow Pointer follows the pointer position the session reports: the zoomed picture moves so that
    /// point is in the middle of the view, and stops at the desktop's edges; Whole Screen fits the whole desktop.
    func testFollowPointerFollowsReportedPointer() {
        var reported: (Int, Int)?
        input.onPointer = { reported = ($0, $1) }
        parts.trackpad.move(dx: 100, dy: 50, dt: 1)
        let p = try! XCTUnwrap(reported)
        let bounds = CGSize(width: 400, height: 225)
        let f = RDPFollow.pictureFrame(canvasWidth: 1920, canvasHeight: 1080, in: bounds, screenScale: 1,
                                       follow: true, pointer: (p.0, p.1))
        let k = f.width / 1920
        XCTAssertEqual(f.width, 800, accuracy: 0.5) // zoom 2
        XCTAssertEqual(f.minX + CGFloat(p.0) * k, 200, accuracy: 1)
        XCTAssertEqual(f.minY + CGFloat(p.1) * k, 112.5, accuracy: 1)
        // A pointer at the corner: the picture stops at the edge (no black shown), the pointer leaves the middle.
        let corner = RDPFollow.pictureFrame(canvasWidth: 1920, canvasHeight: 1080, in: bounds, screenScale: 1,
                                            follow: true, pointer: (0, 0))
        XCTAssertEqual(corner.origin, .zero)
        let whole = RDPFollow.pictureFrame(canvasWidth: 1920, canvasHeight: 1080, in: bounds, screenScale: 1,
                                           follow: false, pointer: (p.0, p.1))
        XCTAssertEqual(whole, CGRect(x: 0, y: 0, width: 400, height: 225))
    }

    /// Claim (safety): nothing reaches the PC while the app is locked.
    func testNothingWhileLocked() {
        input.isOpen = { false }
        parts.trackpad.tap(button: 0, at: .zero, time: 0)
        MacTyping.type("a", into: parts.keyboard.engine)
        XCTAssertTrue(rec.events.isEmpty)
    }
}
