// Project notes: one test per claim.
import XCTest
import GlassActCore
import GlassActWire
@testable import DuoDesktop

final class TypingFocusTests: XCTestCase {
    let main = CGRect(x: 0, y: 0, width: 1920, height: 1080)

    /// Claim: a text place reported after the user's click raises the keyboard; focus leaving text lowers it; a
    /// report with no recent click does not raise it.
    func testKeyboardComesUpAfterAClickIntoTextAndGoesDownWhenFocusLeaves() {
        var k = AutoKeyboard()
        k.focus(y: 500, at: 10)                 // no click: a dialog took focus on its own
        XCTAssertFalse(k.up)
        k.userClicked(at: 20)
        k.focus(y: 500, at: 20.3)
        XCTAssertTrue(k.up)
        XCTAssertEqual(k.aim, .field(y: 500))
        k.focus(y: nil, at: 30)
        XCTAssertFalse(k.up)
        k.userClicked(at: 40)
        k.focus(y: nil, at: 40.2)               // a click on the desktop
        XCTAssertFalse(k.up)
    }

    /// Claim: the Keyboard button always wins: raised by hand stays up when focus leaves text; lowered by hand stays
    /// down for later reports until the next click into a field.
    func testButtonOverrides() {
        var k = AutoKeyboard()
        k.button()
        XCTAssertTrue(k.up)
        k.focus(y: nil, at: 5)
        XCTAssertTrue(k.up, "raised by hand stays up")
        k.button()
        XCTAssertFalse(k.up)
        k.focus(y: 300, at: 50)                 // focus moves to text with no click
        XCTAssertFalse(k.up, "lowered by hand stays down")
        k.userClicked(at: 60)
        k.focus(y: 300, at: 60.1)
        XCTAssertTrue(k.up, "the next click into a field raises it")
    }

    /// Claim: while up the view follows the pointer only when the user moves it, and returns to the field on typing.
    func testPointerMoveThenTypingReturnsToTheField() {
        var k = AutoKeyboard()
        k.userClicked(at: 1); k.focus(y: 700, at: 1.1)
        k.pointerMoved()
        XCTAssertEqual(k.aim, .pointer)
        k.typed()
        XCTAssertEqual(k.aim, .field(y: 700))
    }

    /// Claim: locked = the measured lock-screen password field is where typing goes; the keyboard comes up; focus
    /// reports from behind the lock screen (often "none") do not lower it; unlocking lowers it.
    func testLockedUsesTheMeasuredPasswordPosition() {
        var k = AutoKeyboard()
        let y = TypingFocusMap.passwordField.y * 1080
        XCTAssertEqual(y, 981.5, accuracy: 0.01)
        k.lock(true, passwordY: y)
        XCTAssertTrue(k.up)
        XCTAssertEqual(k.aim, .field(y: y))
        k.focus(y: nil, at: 3)
        XCTAssertTrue(k.up)
        k.lock(false, passwordY: y)
        XCTAssertFalse(k.up)
    }

    /// Claim: the view centres on the reported frame: the caret (or a short field's middle) sits in the middle of the
    /// space above the key row, in global points mapped through the shown screen (here a second screen above main).
    func testTheViewCentresOnTheReportedFrame() throws {
        let f = WireTextFocus(hasText: true, fieldX: 800, fieldY: 960, fieldW: 300, fieldH: 30,
                              caretX: 810, caretY: 966, caretW: 1, caretH: 18)
        let y = try XCTUnwrap(TypingFocusMap.pictureY(f, screen: main, pictureHeight: 1080))
        XCTAssertEqual(y, 975)
        // A screen above main (global y -1080…0): the same field one screen up maps to the same picture height.
        var up = f; up.caretY -= 1080; up.fieldY -= 1080
        XCTAssertEqual(TypingFocusMap.pictureY(up, screen: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
                                               pictureHeight: 1080), 975)
        // Not on the shown screen, or not text: nothing to aim at.
        XCTAssertNil(TypingFocusMap.pictureY(up, screen: main, pictureHeight: 1080))
        XCTAssertNil(TypingFocusMap.pictureY(.none, screen: main, pictureHeight: 1080))
        // No caret, short field: its middle. No caret, tall text area: near its bottom line.
        let short = WireTextFocus(hasText: true, fieldX: 0, fieldY: 100, fieldW: 300, fieldH: 30)
        XCTAssertEqual(TypingFocusMap.pictureY(short, screen: main, pictureHeight: 1080), 115)
        let tall = WireTextFocus(hasText: true, fieldX: 0, fieldY: 100, fieldW: 600, fieldH: 600)
        XCTAssertEqual(TypingFocusMap.pictureY(tall, screen: main, pictureHeight: 1080), 670)
        // Horizontal at 1080 tall in a 932-point-wide view: the field ends in the middle of the space above the
        // keys (or the picture rests on the key row when the field is that low).
        let fit = CGRect(x: 0, y: 0, width: 932, height: 524.25)
        let visible: CGFloat = 371
        let mid = TypingFollow.offset(pointerY: 540, canvasHeight: 1080, fit: fit, visibleHeight: visible)
        XCTAssertEqual(fit.minY + 540 / 1080 * fit.height + mid, visible / 2, accuracy: 0.01)
        let low = TypingFollow.offset(pointerY: y, canvasHeight: 1080, fit: fit, visibleHeight: visible)
        XCTAssertEqual(fit.maxY + low, visible, accuracy: 0.01, "stops with the picture's bottom on the key row")
        XCTAssertLessThan(fit.minY + y / 1080 * fit.height + low, visible, "the field stays above the keys")
    }

    /// Claim: the outer screen opens on the password field with the keyboard up only when locked; unlocked opens at
    /// the dialog spot with the keyboard down; unknown (older Host) as before (password, keyboard up).
    func testOuterOpeningByLockState() {
        XCTAssertTrue(OuterSessionView.keyboardAtOpen(onPassword: true))
        XCTAssertFalse(OuterSessionView.keyboardAtOpen(onPassword: false))
        let display = CGSize(width: 466, height: 678), touchable = CGRect(x: 0, y: 0, width: 382, height: 644)
        func opened(onPassword: Bool) -> CGRect {
            let c = CanvasView(controller: nil, grid: TileGrid(width: 1920, height: 1080))
            c.frame = CGRect(origin: .zero, size: display)
            c.outerTouchable = touchable
            c.fullWidth = 1920
            c.outer = true
            c.outerMode = .vertical
            c.outerOpensOnPassword = onPassword
            c.layoutIfNeeded()
            return c.pictureFrame
        }
        let mac = CGSize(width: 1920, height: 1080)
        let dialog = OuterWindow.verticalClamp(OuterWindow.dialogSpot(mac: mac, display: display, touchable: touchable),
                                               mac: mac, display: display, touchable: touchable)
        XCTAssertEqual(opened(onPassword: false).minY, -dialog.y, accuracy: 0.34)
        let password = OuterWindow.passwordSpot(mac: mac, display: display, touchable: touchable, keyboardTop: nil)
        XCTAssertEqual(opened(onPassword: true).minY, -password.y, accuracy: 0.34)
        XCTAssertNotEqual(dialog.y, password.y)
    }

    // MARK: The outer strip (defects 1 and 2)

    let upright = CGSize(width: 466, height: 678)
    let sideways = CGSize(width: 678, height: 466)
    /// The system capsule's largest seen form: x 392.0–445.3, top to 189.3.
    let capsule = CGRect(x: 392, y: 0, width: 53.3, height: 189.3)

    /// Claim: after a rotation and back the layout equals the layout before, and the groups never meet the system
    /// strip's reserved area; they sit on its centre line 16 pt below its largest form.
    func testStripSameAfterRotateAndBackAndClearOfTheSystemCapsule() {
        let before = OuterStripLayout.place(display: upright, stripOnRight: true, keyboardTop: nil)
        _ = OuterStripLayout.place(display: sideways, stripOnRight: false, keyboardTop: nil)
        let after = OuterStripLayout.place(display: upright, stripOnRight: true, keyboardTop: nil)
        XCTAssertEqual(before, after)
        XCTAssertEqual(before.arrangement, .twoGroups)
        XCTAssertEqual(before.frame.midX, 418.7, accuracy: 0.01)
        XCTAssertEqual(before.frame.minY, 206)
        XCTAssertGreaterThanOrEqual(before.frame.minY - capsule.maxY, 16)
        XCTAssertFalse(before.frame.intersects(CGRect(x: capsule.minX, y: 0, width: capsule.width,
                                                      height: OuterStripLayout.reservedSystemBottom)))
    }

    /// Claim: with the keyboard's frame given, no control intersects it, in either orientation; sideways the
    /// controls are a row on the top edge (218 x 53), clear of the picture's middle where the password field sits.
    func testNoControlUnderTheKeyboardInEitherOrientation() {
        for (display, stripOnRight) in [(upright, true), (sideways, false), (sideways, true)] {
            for kbHeight: CGFloat in [0, 160, 193, 216, 260, 300] {
                let kbTop: CGFloat? = kbHeight == 0 ? nil : display.height - kbHeight
                let p = OuterStripLayout.place(display: display, stripOnRight: stripOnRight, keyboardTop: kbTop)
                if let kbTop {
                    let keyboard = CGRect(x: 0, y: kbTop, width: display.width, height: kbHeight)
                    XCTAssertFalse(p.frame.intersects(keyboard), "\(display) keyboard \(kbHeight): \(p)")
                }
                XCTAssertTrue(CGRect(origin: .zero, size: display).contains(p.frame), "\(display) \(kbHeight): \(p)")
                XCTAssertGreaterThanOrEqual(min(p.frame.width, p.frame.height), 44)
            }
        }
        let side = OuterStripLayout.place(display: sideways, stripOnRight: false, keyboardTop: 466 - 193)
        // On the strip's side the row's top-left would sit under the system area (the strip's column down to 190), so
        // it goes to the other side's top edge.
        XCTAssertEqual(side, .init(arrangement: .row, frame: CGRect(x: 678 - 8 - 218, y: 8, width: 218, height: 53)))
        // The password field sideways, the Mac's bottom resting on the keyboard: about 98 pt above it, centred.
        let field = CGRect(x: 339 - 79, y: 466 - 193 - 98 - 14, width: 158, height: 27)
        XCTAssertFalse(side.frame.intersects(field))
        // Upright with the owner's simulator keyboard top (414): one group of four fits (206 + 197 = 403).
        XCTAssertEqual(OuterStripLayout.place(display: upright, stripOnRight: true, keyboardTop: 414).arrangement,
                       .oneGroup)
    }
}
