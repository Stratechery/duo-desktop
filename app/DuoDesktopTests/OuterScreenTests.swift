import GlassActCore
import GlassActWire
import XCTest
@testable import DuoDesktop

/// The outer screen's two views: vertical (the default) and free. One claim per test.
@MainActor
final class OuterScreenTests: XCTestCase {
    /// The outer screen's safe area, upright: the fully touchable window. The whole outer display, upright, and the
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

    // MARK: Keyboard and the lock screen

    /// A keyboard top for the tests: the outer display 678 tall, keyboard ~298 above the bottom.
    let keyboardTop: CGFloat = 380

    /// Claim: with the keyboard up, vertical opens with the Mac's bottom edge exactly on the keyboard's top (no black
    /// between), centred sideways, the password field fully visible above the keys at 1920x1080 and 1920x1200;
    /// scrolling down goes no further; one finger scrolls up to the dialog spot (Mac y 78 at the top) as before.
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

/// The outer strip starts 16 pt below where Apple's occlusion region ends, both ways; 190 only when there is no
/// reading; nothing is ever placed under the system area.
@MainActor
final class OuterSystemAreaTests: XCTestCase {
    let upright = CGSize(width: 466, height: 678)
    let sideways = CGSize(width: 678, height: 466)

    private func system(_ d: CGSize, _ right: Bool, _ end: CGFloat) -> CGRect {
        OuterStripLayout.systemArea(display: d, stripOnRight: right, systemEnd: end)
    }

    /// Claim: with the region's end at 174 (nothing running), 264 (a Live Activity) and 300 (keyboard down,
    /// upright), the first group starts 16 pt below it, higher than the old 206 when the area is small, as two groups
    /// on the capsule's centre line, clear of the system area.
    func testFirstGroupSixteenBelowTheMeasuredEnd() {
        for (end, top) in [(174, 190), (264, 280), (300, 316), (253, 269)] as [(CGFloat, CGFloat)] {
            let p = OuterStripLayout.place(display: upright, stripOnRight: true, keyboardTop: nil, systemEnd: end)
            XCTAssertEqual(p.arrangement, .twoGroups, "end \(end)")
            XCTAssertEqual(p.frame.minY, top, "end \(end)")
            XCTAssertEqual(p.frame.midX, 418.7, accuracy: 0.01)
            XCTAssertFalse(p.frame.intersects(system(upright, true, end)), "end \(end)")
        }
        // The owner's phone (two activities and the hotspot indicator end about 253): the first button is whole below it.
        let phone = OuterStripLayout.place(display: upright, stripOnRight: true, keyboardTop: nil, systemEnd: 253)
        XCTAssertGreaterThanOrEqual(phone.frame.minY, 253 + 16)
    }

    /// Claim: the ladder steps down as the system area grows over the room above the keyboard, and at "no room" the row
    /// goes to the other side, never under the system area.
    func testLadderAndNoRoom() {
        let kb: CGFloat = 414
        XCTAssertEqual(OuterStripLayout.place(display: upright, stripOnRight: true, keyboardTop: kb, systemEnd: 190)
            .arrangement, .oneGroup) // 206 + 197 = 403 <= 406
        let at253 = OuterStripLayout.place(display: upright, stripOnRight: true, keyboardTop: kb, systemEnd: 253)
        XCTAssertEqual(at253.arrangement, .row) // 269 + 197 > 406: a row just above the keyboard
        XCTAssertEqual(at253.frame.minY, 406 - 53)
        XCTAssertGreaterThan(at253.frame.minX, 200, "below the system area there is room on the strip's side")
        // A Live Activity (264) with the keyboard up: a row just above the keyboard, clear of both.
        let at264 = OuterStripLayout.place(display: upright, stripOnRight: true, keyboardTop: kb, systemEnd: 264)
        XCTAssertEqual(at264.arrangement, .row)
        XCTAssertEqual(at264.frame.maxY, kb - 8)
        XCTAssertFalse(at264.frame.intersects(system(upright, true, 264)))
        // Nothing running (174) with the keyboard up: one group of four fits from 190.
        let at174 = OuterStripLayout.place(display: upright, stripOnRight: true, keyboardTop: kb, systemEnd: 174)
        XCTAssertEqual(at174.arrangement, .oneGroup)
        XCTAssertEqual(at174.frame.minY, 190)
        // No room: the system area reaches down to the keyboard row's height on the strip's side.
        for (d, right, end, top) in [(upright, true, CGFloat(320), CGFloat(360)), (upright, true, 400, 420),
                                     (sideways, false, 320, 300), (sideways, true, 253, 273)] {
            let p = OuterStripLayout.place(display: d, stripOnRight: right, keyboardTop: top, systemEnd: end)
            XCTAssertEqual(p.arrangement, .row, "\(d) \(end)")
            XCTAssertFalse(p.frame.intersects(system(d, right, end)), "\(d) \(end): \(p)")
            XCTAssertLessThanOrEqual(p.frame.maxY, top - 8, "\(d) \(end): above the keyboard")
            XCTAssertTrue(CGRect(origin: .zero, size: d).contains(p.frame))
        }
    }

    /// Claim: no arrangement meets the system area or the keyboard, upright and sideways, over a range of ends
    /// and keyboard heights.
    func testNeverUnderTheSystemAreaOrTheKeyboard() {
        for (d, right) in [(upright, true), (sideways, false), (sideways, true)] {
            for end: CGFloat in [0, 150, 190, 206, 230, 253, 300, 320] {
                for kb: CGFloat in [0, 193, 216, 260, 300] {
                    let top: CGFloat? = kb == 0 ? nil : d.height - kb
                    let p = OuterStripLayout.place(display: d, stripOnRight: right, keyboardTop: top, systemEnd: end)
                    let what = "\(d) right \(right) end \(end) kb \(kb): \(p)"
                    XCTAssertFalse(p.frame.intersects(system(d, right, end)), what)
                    if let top { XCTAssertLessThanOrEqual(p.frame.maxY, top, what) }
                    XCTAssertTrue(CGRect(origin: .zero, size: d).contains(p.frame), what)
                }
            }
        }
    }

    /// Claim: the end is the lowest region bottom in the strip's column (the simulator's 174 and 264; the camera
    /// and regions on the other side are ignored); no region or a nonsense one gives 190.
    func testSystemEndFromRegions() {
        let camera = CGRect(x: 214, y: 29.3, width: 37, height: 37)
        for end: CGFloat in [174, 264.3] {
            let column = CGRect(x: 382, y: 0, width: 84, height: end)
            XCTAssertEqual(OuterStripLayout.systemEnd(regions: [camera, column], display: upright, stripOnRight: true), end)
            XCTAssertEqual(OuterStripLayout.systemEnd(regions: [column], display: upright, stripOnRight: false), 190,
                           "a region on the other side is not the strip's")
        }
        let left = CGRect(x: 0, y: 0, width: 84, height: 300)
        XCTAssertEqual(OuterStripLayout.systemEnd(regions: [left], display: sideways, stripOnRight: false), 300)
        XCTAssertEqual(OuterStripLayout.systemEnd(regions: [], display: upright, stripOnRight: true), 190)
        XCTAssertEqual(OuterStripLayout.systemEnd(regions: [CGRect(x: 382, y: 0, width: 84, height: 600)],
                                                  display: upright, stripOnRight: true), 190, "beyond 3/4: nonsense")
    }
}

/// The controls keep clear of every occlusion region in the strip's column, the camera wherever it is, with the
/// simulator's real regions (`screenshots/outer-system-area-2/probe-log.txt`; sideways the 37 x 37 camera turns with
/// the display).
@MainActor
final class OuterCameraSidewaysTests: XCTestCase {
    let upright = CGSize(width: 466, height: 678)
    let sideways = CGSize(width: 678, height: 466)
    /// Upright: the system column (to 174, or 264.3 with a Live Activity) and the camera at the top right.
    func uprightRegions(_ end: CGFloat) -> [CGRect] {
        [CGRect(x: 399.7, y: 29.3, width: 37, height: 37), CGRect(x: 382, y: 0, width: 84, height: end)]
    }
    let cameraTopLeft = CGRect(x: 29.3, y: 29.3, width: 37, height: 37)
    let cameraBottomRight = CGRect(x: 611.7, y: 399.7, width: 37, height: 37)
    /// The owner's simulator keyboard: top at 414 upright, 466 - 193 sideways.
    let uprightKeyboard: CGFloat = 414
    let sidewaysKeyboard: CGFloat = 466 - 193

    private func place(_ d: CGSize, _ right: Bool, _ regions: [CGRect], _ kb: CGFloat?) -> OuterStripLayout.Placement {
        let run = OuterStripLayout.run(regions: regions, display: d, stripOnRight: right)
        return OuterStripLayout.place(display: d, stripOnRight: right, keyboardTop: kb, systemEnd: run.systemEnd,
                                      bottomRegionTop: run.bottomRegionTop)
    }

    /// Claim: upright is unchanged from commit 7d178ae94: two groups from 190 and 280 with the keyboard down; one
    /// group of four from 190, or a row resting 8 pt above the keyboard, with it up. The camera is not a bottom region.
    func testUprightUnchanged() {
        for (end, top) in [(CGFloat(174), CGFloat(190)), (264.3, 280.3)] {
            XCTAssertNil(OuterStripLayout.run(regions: uprightRegions(end), display: upright, stripOnRight: true)
                .bottomRegionTop)
            let down = place(upright, true, uprightRegions(end), nil)
            XCTAssertEqual(down, OuterStripLayout.place(display: upright, stripOnRight: true, keyboardTop: nil,
                                                        systemEnd: end))
            XCTAssertEqual(down.arrangement, .twoGroups)
            XCTAssertEqual(down.frame.minY, top, accuracy: 0.01)
            XCTAssertEqual(down.frame.midX, 418.7, accuracy: 0.01)
        }
        let up174 = place(upright, true, uprightRegions(174), uprightKeyboard)
        XCTAssertEqual(up174.arrangement, .oneGroup)
        XCTAssertEqual(up174.frame.minY, 190)
        let up264 = place(upright, true, uprightRegions(264.3), uprightKeyboard)
        XCTAssertEqual(up264.arrangement, .row)
        XCTAssertEqual(up264.frame.maxY, uprightKeyboard - 8)
    }

    /// Claim: sideways with the camera top-left (strip on the left), the controls start 16 pt below the camera with
    /// the keyboard down, and sit in a row at the top on the far side with it up: as before.
    func testSidewaysCameraTopLeft() {
        XCTAssertEqual(OuterStripLayout.run(regions: [cameraTopLeft], display: sideways, stripOnRight: false),
                       OuterStripLayout.Run(systemEnd: 66.3, bottomRegionTop: nil))
        let down = place(sideways, false, [cameraTopLeft], nil)
        XCTAssertEqual(down.arrangement, .twoGroups)
        XCTAssertEqual(down.frame.minY, 82.3, accuracy: 0.01)
        XCTAssertFalse(down.frame.intersects(cameraTopLeft))
        let up = place(sideways, false, [cameraTopLeft], sidewaysKeyboard)
        XCTAssertEqual(up.arrangement, .row)
        XCTAssertEqual(up.frame, CGRect(x: 678 - 8 - 218, y: 8, width: 218, height: 53))
    }

    /// Claim (the failing case, `5b-sideways-other-way-during.png`): sideways with the camera bottom-right (strip on
    /// the right), no control meets the camera. Keyboard down: the run 206 to 383.7 (16 pt above the camera) is too
    /// short for a column (218 or 197), so the ladder gives a row just above it on the strip's side. Keyboard up: a
    /// row at the top, as before.
    func testSidewaysCameraBottomRightClearOfTheCamera() {
        XCTAssertEqual(OuterStripLayout.run(regions: [cameraBottomRight], display: sideways, stripOnRight: true),
                       OuterStripLayout.Run(systemEnd: 190, bottomRegionTop: 399.7))
        let down = place(sideways, true, [cameraBottomRight], nil)
        XCTAssertEqual(down.arrangement, .row)
        XCTAssertEqual(down.frame.minX, 452, accuracy: 0.01)
        XCTAssertEqual(down.frame.maxY, 399.7 - 16, accuracy: 0.01)
        XCTAssertFalse(down.frame.intersects(cameraBottomRight))
        let up = place(sideways, true, [cameraBottomRight], sidewaysKeyboard)
        XCTAssertEqual(up.arrangement, .row)
        XCTAssertLessThanOrEqual(up.frame.maxY, sidewaysKeyboard)
        XCTAssertFalse(up.frame.intersects(cameraBottomRight))
        // Before this change the column ran 206 to 424, over the camera (399.7 to 436.7).
        let old = OuterStripLayout.place(display: sideways, stripOnRight: true, keyboardTop: nil)
        XCTAssertTrue(old.frame.intersects(cameraBottomRight))
    }

    /// Claim: no arrangement meets any region (each with its 16 pt gap where the column runs into it) or the
    /// keyboard: upright with and without a Live Activity, sideways both ways, a camera at the bottom on either
    /// side, keyboard down and at several heights; and a bottom region never leaves the column under it.
    func testNoArrangementMeetsAnyRegionOrTheKeyboard() {
        let cases: [(CGSize, Bool, [CGRect])] = [
            (upright, true, uprightRegions(174)), (upright, true, uprightRegions(264.3)),
            (sideways, false, [cameraTopLeft]), (sideways, true, [cameraBottomRight]),
            (sideways, false, [CGRect(x: 29.3, y: 399.7, width: 37, height: 37)]),
            (sideways, true, [CGRect(x: 611.7, y: 29.3, width: 37, height: 37)]),
            (upright, true, uprightRegions(174) + [CGRect(x: 399.7, y: 611.7, width: 37, height: 37)]),
            (sideways, true, [CGRect(x: 600, y: 0, width: 78, height: 120), cameraBottomRight]),
        ]
        for (d, right, regions) in cases {
            for kb: CGFloat in [0, 193, 216, 260, 300] {
                let top: CGFloat? = kb == 0 ? nil : d.height - kb
                let p = place(d, right, regions, top)
                let what = "\(d) right \(right) \(regions) kb \(kb): \(p)"
                for r in regions { XCTAssertFalse(p.frame.intersects(r), what) }
                if let top { XCTAssertLessThanOrEqual(p.frame.maxY, top, what) }
                XCTAssertTrue(CGRect(origin: .zero, size: d).contains(p.frame), what)
                if p.arrangement != .row, let low = regions.filter({ $0.minY >= d.height / 2 }).map(\.minY).min() {
                    XCTAssertLessThanOrEqual(p.frame.maxY, low - 16, what)
                }
            }
        }
    }
}
