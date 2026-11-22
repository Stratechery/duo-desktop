import GlassActCore
import GlassActWire
import XCTest
@testable import DuoDesktop

/// The outer screen's two views (project notes): vertical (the default) and free
/// (project notes). One claim per test.
@MainActor
final class OuterScreenTests: XCTestCase {
    /// The outer screen's safe area, upright (project notes §1): the fully
    /// touchable window.
    /// The whole outer display, upright (the picture fills it; project notes), and the
    /// safe area in its points (right strip 84, bottom inset 34).
    let display = CGSize(width: 466, height: 678)
    let touchable = CGRect(x: 0, y: 0, width: 382, height: 644)
    /// Sideways: the strip is on the left.
    let sideDisplay = CGSize(width: 678, height: 466)
    let sideTouchable = CGRect(x: 84, y: 0, width: 594, height: 432)

    private func canvas(_ w: Int, _ h: Int, full: Int? = nil, display d: CGSize? = nil,
                        touchable t: CGRect? = nil, recorder: Recorder? = nil,
                        mode: OuterMode = .free) -> CanvasView {
        let c = CanvasView(controller: nil, grid: TileGrid(width: w, height: h))
        c.frame = CGRect(origin: .zero, size: d ?? display)
        c.outerTouchable = t ?? touchable
        c.fullWidth = full ?? w
        if let recorder {
            let e = DirectTouchEngine(sink: recorder)
            e.setCanvas(width: w, height: h, fullWidth: full ?? w)
            c.touchEngine = e
        }
        c.outer = true
        c.outerMode = mode
        c.directTouch = true
        c.layoutIfNeeded()
        return c
    }

    /// The Mac pixel under view point `p`, at full size.
    private func mac(_ c: CanvasView, _ p: CGPoint, gridWidth: Int = 1920, gridHeight: Int = 1080,
                     full: Int = 1920) -> (Int, Int)? {
        guard let q = DirectTouchEngine.canvasPoint(p, picture: c.pictureFrame, canvasWidth: gridWidth,
                                                    canvasHeight: gridHeight) else { return nil }
        return (q.0 * full / gridWidth, q.1 * full / gridWidth)
    }

    /// The dialog spot at 1920x1080: the Mac's centre on the DISPLAY's centre (233), raised as built (Mac y 78 at
    /// the top). The measured real prompt and its buttons are wholly left of the strip (x 382), so nothing of it is
    /// under the indicators or our button: no shift needed.
    func testOpensAtTheDialogSpotCentredOnTheDisplay() {
        let c = canvas(1920, 1080)
        XCTAssertEqual(c.pictureFrame, CGRect(x: -727, y: -78, width: 1920, height: 1080))
        XCTAssertEqual(c.pictureFrame.minX + 960, display.width / 2)
        XCTAssertEqual(OuterWindow.shown(picture: c.pictureFrame, display: display),
                       CGRect(x: 727, y: 78, width: 466, height: 678))
        let prompt = CGRect(x: 830, y: 187, width: 260, height: 250).offsetBy(dx: -727, dy: -78)
        XCTAssertEqual(prompt, CGRect(x: 103, y: 109, width: 260, height: 250))
        XCTAssertTrue(touchable.contains(prompt))                 // x 103–363: clear of the strip at 382
        let allow = CGRect(x: 964, y: 394, width: 110, height: 27).offsetBy(dx: -727, dy: -78)
        XCTAssertEqual(allow, CGRect(x: 237, y: 316, width: 110, height: 27))
        let selector = CGRect(x: 466 - OuterStrip.edgeToCentre - OuterStrip.width / 2, y: OuterStrip.top,
                              width: OuterStrip.width, height: OuterStrip.height)
        XCTAssertFalse(prompt.intersects(selector))
        XCTAssertFalse(prompt.intersects(CGRect(x: 382, y: 0, width: 84, height: 150))) // the indicators
    }

    func testDialogSpotAtOtherSizesAndSideways() {
        // 1920 x 1200: x the same, the raised centre (444.4) at the touchable centre (322).
        let b = canvas(1920, 1200)
        XCTAssertEqual(b.pictureFrame.minX, -727)
        XCTAssertEqual(b.pictureFrame.minY + 1200 * 400 / 1080, touchable.midY, accuracy: 0.34)
        // Sideways (strip on the left): the Mac's centre on the display's centre (339), raised against the
        // touchable centre (216).
        let s = canvas(1920, 1080, display: sideDisplay, touchable: sideTouchable)
        XCTAssertEqual(s.pictureFrame, CGRect(x: -621, y: -184, width: 1920, height: 1080))
        // Half-size stream: drawn 2x, so the same place and the same Mac point under a finger.
        let h = canvas(960, 540, full: 1920)
        XCTAssertEqual(h.pictureFrame, CGRect(x: -727, y: -78, width: 1920, height: 1080))
        XCTAssertTrue(mac(h, CGPoint(x: 233, y: 322), gridWidth: 960, gridHeight: 540)! == (960, 400))
    }

    func testTapClicksUnderTheFingerAtTheCentreAndInTheStrip() {
        let r = Recorder()
        let c = canvas(1920, 1080, recorder: r)
        c.outerTap(at: CGPoint(x: 233, y: 322), time: 0)          // the display's centre
        XCTAssertEqual(r.events.map(\.kind), [InputKind.move, InputKind.buttonDown, InputKind.buttonUp])
        XCTAssertTrue(r.events.allSatisfy { $0.x == 960 && $0.y == 400 })
        r.events.removeAll()
        c.outerTap(at: CGPoint(x: 420, y: 300), time: 5)          // in the side strip (x 382–466)
        XCTAssertEqual(r.events.map(\.kind), [InputKind.move, InputKind.buttonDown, InputKind.buttonUp])
        XCTAssertTrue(r.events.allSatisfy { $0.x == 1147 && $0.y == 378 })
    }

    func testOneFingerDragPressesMovesAndReleasesUnderTheFinger() {
        let r = Recorder()
        let c = canvas(1920, 1080, recorder: r)
        c.outerDragBegan(at: CGPoint(x: 100, y: 100), now: CGPoint(x: 110, y: 100))
        c.outerDragMoved(to: CGPoint(x: 200, y: 150))
        c.outerDragEnded(at: CGPoint(x: 210, y: 160))
        XCTAssertEqual(r.events.map(\.kind), [InputKind.move, InputKind.buttonDown, InputKind.move, InputKind.move,
                                              InputKind.buttonUp])
        XCTAssertTrue(r.events[0].x == 827 && r.events[0].y == 178)  // press where the finger first touched
        XCTAssertTrue(r.events[1].x == 827 && r.events[1].y == 178)
        XCTAssertTrue(r.events[3].x == 927 && r.events[3].y == 228)  // follows the finger
        XCTAssertTrue(r.events[4].x == 937 && r.events[4].y == 238)  // lets go where it lifts
        XCTAssertEqual(c.pictureFrame.minX, -727, "a drag never moves the picture")
    }

    func testTwoFingerMoveClampsOnAllFourSidesAndSendsNothing() {
        let r = Recorder()
        let c = canvas(1920, 1080, recorder: r)
        c.moveOuterPicture(by: CGPoint(x: 40, y: -30))            // one Mac pixel per point, any direction
        XCTAssertEqual(c.pictureFrame.origin, CGPoint(x: -687, y: -108))
        c.moveOuterPicture(by: CGPoint(x: 5000, y: 5000))         // left and top edges
        XCTAssertEqual(c.pictureFrame.origin, CGPoint(x: 0, y: 0))
        c.moveOuterPicture(by: CGPoint(x: -5000, y: -5000))       // right and bottom edges
        XCTAssertEqual(c.pictureFrame.origin, CGPoint(x: -(1920 - 466), y: -(1080 - 678)))
        XCTAssertTrue(r.events.isEmpty, "moving the picture sends nothing to the Mac")
    }

    func testTheButtonReturnsToTheDialogSpot() {
        let c = canvas(1920, 1080)
        c.moveOuterPicture(by: CGPoint(x: -300, y: -200))
        XCTAssertNotEqual(c.pictureFrame.origin, CGPoint(x: -727, y: -78))
        c.returnToDialogSpot()
        XCTAssertEqual(c.pictureFrame.origin, CGPoint(x: -727, y: -78))
        // Leaving and coming back to the outer view also starts there.
        c.moveOuterPicture(by: CGPoint(x: -300, y: -200))
        c.outer = false
        c.outer = true
        XCTAssertEqual(c.pictureFrame.origin, CGPoint(x: -727, y: -78))
    }

    // MARK: Vertical (the primary view)

    func testVerticalIsTheDefaultAndOpensAtTheDialogSpot() {
        XCTAssertEqual(OuterMode.start, .vertical)
        XCTAssertEqual(OuterMode.allCases.first, .vertical, "vertical is the first choice")
        XCTAssertEqual(CanvasView(controller: nil, grid: TileGrid(width: 1920, height: 1080)).outerMode, .vertical)
        let c = canvas(1920, 1080, mode: .vertical)
        // Before the keyboard is up the password spot is as low as the picture goes (the field at 981.5 is below
        // the middle of 0–644): the Mac's bottom at the touchable bottom.
        XCTAssertEqual(c.pictureFrame, CGRect(x: -727, y: -436, width: 1920, height: 1080))
        // After a scroll, a return to the outer view (or the app) opens at the opening place again.
        c.moveOuterPicture(by: CGPoint(x: 0, y: 200))
        c.returnToDialogSpot()
        XCTAssertEqual(c.pictureFrame.origin, CGPoint(x: -727, y: -436))
    }

    func testVerticalNeverMovesSidewaysAndStopsAtTheMacsTopAndBottom() {
        let r = Recorder()
        let c = canvas(1920, 1080, recorder: r, mode: .vertical)
        c.moveOuterPicture(by: CGPoint(x: 0, y: 436 - 78))        // up to the dialog spot (Mac y 78 at the top)
        c.moveOuterPicture(by: CGPoint(x: 300, y: -50))           // the sideways part is ignored
        XCTAssertEqual(c.pictureFrame.origin, CGPoint(x: -727, y: -128))
        c.moveOuterPicture(by: CGPoint(x: -5000, y: 5000))        // top: Mac y 0 at the display's top
        XCTAssertEqual(c.pictureFrame.origin, CGPoint(x: -727, y: 0))
        c.moveOuterPicture(by: CGPoint(x: 5000, y: -5000))        // bottom: Mac's bottom at the touchable bottom
        XCTAssertEqual(c.pictureFrame.origin, CGPoint(x: -727, y: -(1080 - 644)))
        XCTAssertTrue(r.events.isEmpty, "scrolling sends nothing to the Mac")
    }

    func testVerticalTapClicksWhereItTouchesAlsoAfterAScroll() {
        let r = Recorder()
        let c = canvas(1920, 1080, recorder: r, mode: .vertical)
        c.moveOuterPicture(by: CGPoint(x: 0, y: 436 - 78))        // one scroll up: the dialog spot
        c.outerTap(at: CGPoint(x: 0.5, y: 0.5), time: 0)          // the display's top-left pixel
        XCTAssertEqual(r.events.map(\.kind), [InputKind.move, InputKind.buttonDown, InputKind.buttonUp])
        XCTAssertTrue(r.events.allSatisfy { $0.x == 727 && $0.y == 78 })
        r.events.removeAll()
        c.outerTap(at: CGPoint(x: 237 + 55, y: 316 + 13), time: 5) // the measured Allow button's centre
        XCTAssertTrue(r.events.allSatisfy { $0.x == 1019 && $0.y == 407 })
        r.events.removeAll()
        c.moveOuterPicture(by: CGPoint(x: 0, y: -100))            // finger up 100: shows 100 px further down
        c.outerTap(at: CGPoint(x: 233, y: 322), time: 10)
        XCTAssertTrue(r.events.allSatisfy { $0.x == 960 && $0.y == 500 })
    }

    func testChoosingVerticalFromFreePutsThePictureBackOnTheCentreLine() {
        let c = canvas(1920, 1080)
        c.moveOuterPicture(by: CGPoint(x: -300, y: -200))
        c.switchOuterMode(to: .vertical)                          // the sideways offset can't survive vertical
        XCTAssertEqual(c.pictureFrame.minX, -727)
        c.returnToDialogSpot()                                    // and the selector returns to the opening place
        XCTAssertEqual(c.pictureFrame.origin, CGPoint(x: -727, y: -436))
        c.switchOuterMode(to: .free)                              // free starts where vertical was, inside free's
        XCTAssertEqual(c.pictureFrame.origin, CGPoint(x: -727, y: -402)) // own limit (Mac bottom at the display's)
    }

    // MARK: Keyboard and the lock screen (project notes)

    /// A keyboard top for the tests: the outer display 678 tall, keyboard ~298 above the bottom.
    let keyboardTop: CGFloat = 380

    /// Claim (the owner 2026-11-21: "Yes, rest the [Mac's] bottom edge on the keyboard."): with the keyboard up, vertical
    /// opens with the Mac's bottom edge exactly on the keyboard's top (no black between), centred sideways, the
    /// password field fully visible above the keys at 1920x1080 and 1920x1200; scrolling down goes no further;
    /// one finger scrolls up to the dialog spot (Mac y 78 at the top) as before.
    func testOpensWithTheMacBottomRestingOnTheKeyboard() {
        for height in [1080, 1200] {
            let c = canvas(1920, height, mode: .vertical)
            c.outerKeyboardTop = keyboardTop
            let mac = CGFloat(height)
            XCTAssertEqual(c.pictureFrame.maxY, keyboardTop, accuracy: 0.34, "\(height)")
            let field = CGPoint(x: OuterWindow.passwordField.x * 1920, y: OuterWindow.passwordField.y * mac)
            XCTAssertEqual(field.x + c.pictureFrame.minX, display.width / 2)
            let fieldY = field.y + c.pictureFrame.minY
            // The field is about 27 pt tall: its bottom (centre + 14) above the keys, its top on screen.
            XCTAssertLessThan(fieldY + 14, keyboardTop, "\(height)")
            XCTAssertGreaterThan(fieldY - 14, 0, "\(height)")
            c.moveOuterPicture(by: CGPoint(x: 0, y: -200))        // a finger pushing up: no further down
            XCTAssertEqual(c.pictureFrame.maxY, keyboardTop, accuracy: 0.34)
            c.moveOuterPicture(by: CGPoint(x: 0, y: (mac - keyboardTop) - 78))
            XCTAssertEqual(c.pictureFrame.origin, CGPoint(x: -727, y: -78))
            // And back: tapping vertical returns to the password spot.
            c.returnToDialogSpot()
            XCTAssertEqual(c.pictureFrame.maxY, keyboardTop, accuracy: 0.34)
        }
    }

    /// Claim: when the keyboard comes up, the picture shifts just enough that the place last tapped stays visible
    /// above it (44 pt clear), and not at all when it already is.
    func testKeyboardKeepsTheTappedPlaceVisible() {
        let r = Recorder()
        let c = canvas(1920, 1080, recorder: r, mode: .vertical)
        c.moveOuterPicture(by: CGPoint(x: 0, y: 436 - 78))        // the dialog spot
        c.outerTap(at: CGPoint(x: 233, y: 600), time: 0)          // Mac y 678, low on the display
        c.outerKeyboardTop = keyboardTop
        XCTAssertEqual(678 + c.pictureFrame.minY, keyboardTop - OuterWindow.tapClearance, accuracy: 0.34)
        c.outerKeyboardTop = nil
        let d = canvas(1920, 1080, recorder: r, mode: .vertical)
        d.moveOuterPicture(by: CGPoint(x: 0, y: 436 - 78))
        d.outerTap(at: CGPoint(x: 233, y: 100), time: 0)          // already above the keyboard
        d.outerKeyboardTop = keyboardTop
        XCTAssertEqual(d.pictureFrame.origin, CGPoint(x: -727, y: -78))
        r.events.removeAll()
        d.outerTap(at: CGPoint(x: 233, y: 100), time: 5)          // taps still click under the finger
        XCTAssertTrue(r.events.allSatisfy { $0.x == 960 && $0.y == 178 })
    }

    /// Claim: the strip's controls sit on the system capsule's centre line (418.7 pt, measured), as wide as it
    /// (53), 16 pt below it (it ends at 166.7), four 44 pt targets in two groups, clear of the dialog spot's prompt.
    func testStripIsOnTheSystemCentreLineBelowItAndClearOfTheDialog() {
        let strip: CGFloat = 84
        let leftEdge = (display.width - strip) + OuterStrip.offset(strip: strip) - OuterStrip.width
        XCTAssertEqual(leftEdge + OuterStrip.width / 2, 418.7, accuracy: 0.01)
        XCTAssertEqual(OuterStrip.width, 53)
        XCTAssertGreaterThanOrEqual(OuterStrip.top - OuterStrip.systemBottom, 16)
        XCTAssertEqual(OuterStrip.button, 44)
        XCTAssertEqual(OuterStrip.height, 2 * 101 + 16)
        let frame = CGRect(x: leftEdge, y: OuterStrip.top, width: OuterStrip.width, height: OuterStrip.height)
        let prompt = CGRect(x: 103, y: 109, width: 260, height: 250)
        XCTAssertFalse(frame.intersects(prompt))
    }
}
