import XCTest
@testable import DuoDesktop

/// The pinch steps between the views (project notes; the owner's words in
/// project notes). One test per claim.
final class PinchLadderTests: XCTestCase {
    private func next(_ v: SessionView, _ s: PinchStep, multi: Bool = true, overview: Bool = false,
                      upright: Bool = true) -> PinchLadder.Outcome {
        PinchLadder.next(from: v, step: s, multiScreen: multi, overview: overview, followPointerOffered: upright)
    }

    /// Claim: Follow Pointer --pinch in--> Whole Screen (one screen or several); pinch out there does nothing.
    func testFollowPointerPinchInGoesToWholeScreen() {
        XCTAssertEqual(next(.centred, .pinchIn), .view(.regular))
        XCTAssertEqual(next(.centred, .pinchIn, multi: false), .view(.regular))
        XCTAssertEqual(next(.centred, .pinchOut), .nothing)
    }

    /// Claim: Whole Screen --pinch in--> All Screens on a Mac with several screens; nothing on a one-screen Mac.
    func testWholeScreenPinchInGoesToAllScreensOnlyWithSeveral() {
        XCTAssertEqual(next(.regular, .pinchIn), .allScreens)
        XCTAssertEqual(next(.regular, .pinchIn, multi: false), .nothing)
        XCTAssertEqual(next(.regular, .pinchIn, upright: false), .allScreens) // horizontal too
    }

    /// Claim: Whole Screen --pinch out--> Follow Pointer (upright and 16:10); horizontal has no Follow Pointer.
    func testWholeScreenPinchOutGoesToFollowPointer() {
        XCTAssertEqual(next(.regular, .pinchOut), .view(.centred))
        XCTAssertEqual(next(.regular, .pinchOut, multi: false), .view(.centred))
        XCTAssertEqual(next(.regular, .pinchOut, upright: false), .nothing)
    }

    /// Claim: no pinch in All Screens (the owner: "You just tap to select a screen.").
    func testNoPinchInAllScreens() {
        for v in SessionView.allCases {
            XCTAssertEqual(next(v, .pinchIn, overview: true), .nothing)
            XCTAssertEqual(next(v, .pinchOut, overview: true), .nothing)
        }
    }

    /// Claim: one step per pinch, however far the fingers go; the next pinch steps again.
    func testOneStepPerPinch() {
        var t = PinchTracker()
        XCTAssertNil(t.scaled(0.95))                        // not yet past the 8% that decides a pinch
        XCTAssertNil(t.scaled(0.85))                        // a pinch, not yet a step
        XCTAssertEqual(t.scaled(0.74), .pinchIn)            // the step
        XCTAssertNil(t.scaled(0.4))                         // fingers keep closing: no second step
        XCTAssertNil(t.scaled(1.6))                         // or opening again in the same gesture
        t.reset()                                           // fingers lifted
        XCTAssertEqual(t.scaled(1.4), .pinchOut)            // a new pinch steps
    }

    /// Claim: a two-finger scroll does not change the view, even when the fingers drift apart or together on the
    /// way (scroll decided first by travel), and the scroll still starts.
    func testTwoFingerScrollDoesNotStep() {
        var t = PinchTracker()
        XCTAssertFalse(t.moved(CGPoint(x: 0, y: 8)))        // under 12 pt: undecided
        XCTAssertNil(t.scaled(1.03))
        XCTAssertTrue(t.moved(CGPoint(x: 0, y: 14)))        // a scroll: start scrolling
        XCTAssertEqual(t.mode, .scroll)
        XCTAssertNil(t.scaled(0.5))                         // the gap changes a lot afterwards: still no step
        XCTAssertNil(t.scaled(2.0))
        XCTAssertFalse(t.moved(CGPoint(x: 0, y: 200)))      // decided once
        // And a pinch whose centre drifts is not turned into a scroll.
        var p = PinchTracker()
        XCTAssertNil(p.scaled(0.9))
        XCTAssertFalse(p.moved(CGPoint(x: 30, y: 30)))
        XCTAssertEqual(p.scaled(0.7), .pinchIn)
    }
}
