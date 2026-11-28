import GlassActCore
import UIKit
import XCTest
@testable import DuoDesktop

/// Duo Desktop runs cooler, app-only, no loss of smoothness. One test per claim.
@MainActor
final class HeatAppOnlyTests: XCTestCase {
    // MARK: 1. Pause while hidden

    /// Claim: the Terminal and JetKVM views cover the picture upright; the Mac views and anything sideways do not.
    func testCoverRule() {
        XCTAssertFalse(PictureCover.covers(.regular, wide: false))
        XCTAssertFalse(PictureCover.covers(.centred, wide: false))
        #if DUO_TERMINAL
        XCTAssertTrue(PictureCover.covers(.terminal, wide: false))
        XCTAssertFalse(PictureCover.covers(.terminal, wide: true))
        #endif
        #if DUO_JETKVM
        XCTAssertTrue(PictureCover.covers(.jetkvm, wide: false))
        XCTAssertFalse(PictureCover.covers(.jetkvm, wide: true))
        #endif
    }

    /// Claim: the library is told visible only when the app is on screen and the picture is not covered.
    func testHostVisibleCombinesAppAndCover() {
        XCTAssertTrue(PictureCover.hostVisible(appVisible: true, covered: false))
        XCTAssertFalse(PictureCover.hostVisible(appVisible: true, covered: true))
        XCTAssertFalse(PictureCover.hostVisible(appVisible: false, covered: false))
        XCTAssertFalse(PictureCover.hostVisible(appVisible: false, covered: true))
    }

    /// Claim: the model records the cover and its reversal (it calls the library's windowVisibilityChanged).
    func testModelCoverRoundTrip() {
        let model = SessionModel()
        model.setPictureCovered(true)
        XCTAssertTrue(model.pictureCovered)
        model.setPictureCovered(false)
        XCTAssertFalse(model.pictureCovered)
    }

    /// Claim: a covered picture view stops presenting, and starts again the moment it is uncovered.
    func testCanvasStopsWhileCoveredAndResumesAtOnce() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let canvas = CanvasView(controller: nil, grid: TileGrid(width: 1920, height: 1080))
        window.addSubview(canvas)
        XCTAssertTrue(canvas.isPresenting)
        canvas.pictureCovered = true
        XCTAssertFalse(canvas.isPresenting)
        canvas.pictureCovered = false
        XCTAssertTrue(canvas.isPresenting)
        canvas.removeFromSuperview()
        XCTAssertFalse(canvas.isPresenting)
    }

    // MARK: 2. Frame timer rests only when idle

    /// Claim: the timer stays at full rate for a second after the last new frame or touch, then may rest.
    func testRestsOnlyAfterASecondOfNothing() {
        var pacer = PresentPacer(nowUS: 10_000_000)
        XCTAssertFalse(pacer.shouldRest(nowUS: 10_500_000, fingersDown: false, animating: false))
        XCTAssertFalse(pacer.shouldRest(nowUS: 10_999_999, fingersDown: false, animating: false))
        XCTAssertTrue(pacer.shouldRest(nowUS: 11_000_000, fingersDown: false, animating: false))
        // New data (or a touch, or input sent) at 10.9 s: full rate again until 11.9 s.
        pacer.activity(atUS: 10_900_000)
        XCTAssertFalse(pacer.shouldRest(nowUS: 11_500_000, fingersDown: false, animating: false))
        XCTAssertTrue(pacer.shouldRest(nowUS: 11_900_000, fingersDown: false, animating: false))
    }

    /// Claim: never rests with a finger on the picture or while a glide or slide runs.
    func testNeverRestsWhileTouchingOrAnimating() {
        let pacer = PresentPacer(nowUS: 0)
        XCTAssertFalse(pacer.shouldRest(nowUS: 60_000_000, fingersDown: true, animating: false))
        XCTAssertFalse(pacer.shouldRest(nowUS: 60_000_000, fingersDown: false, animating: true))
    }

    /// Claim: an older timestamp never pulls the activity back (no early rest).
    func testActivityNeverMovesBack() {
        var pacer = PresentPacer(nowUS: 5_000_000)
        pacer.activity(atUS: 1_000_000)
        XCTAssertEqual(pacer.lastActivityUS, 5_000_000)
    }

    /// Claim: the rest watch notices new data within one 60 Hz frame.
    func testWatchIsOneFrame() {
        XCTAssertLessThanOrEqual(PresentPacer.watchIntervalNS, 16_700_000)
    }

    /// Claim: the timer's requested rate is unchanged (no cap): it presents at once in a window, and a wake from
    /// input keeps it presenting.
    func testWakeAllKeepsPresenting() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let canvas = CanvasView(controller: nil, grid: TileGrid(width: 1920, height: 1080))
        window.addSubview(canvas)
        CanvasView.wakeAll()
        XCTAssertTrue(canvas.isPresenting)
        XCTAssertFalse(canvas.isResting)
        canvas.removeFromSuperview()
    }

    // MARK: 3. The app's own background checks

    /// Claim: the speed readout does not run without About showing (and not without a live session).
    func testSpeedReadoutOnlyWithAbout() {
        let model = SessionModel()
        XCTAssertFalse(model.throughputRunning)
        model.aboutAppeared()
        XCTAssertFalse(model.throughputRunning, "no live session: nothing to read")
        model.aboutDisappeared()
        model.aboutDisappeared() // an extra disappear never goes below zero
        XCTAssertFalse(model.throughputRunning)
    }

    /// Claim: the link check keeps its 4 Hz beat (the reconnect bound is unchanged) but lets the system fold it in.
    func testLinkCheckKeepsRateWithTolerance() {
        XCTAssertEqual(SessionModel.paceInterval, 0.25)
        XCTAssertGreaterThan(SessionModel.paceTolerance, 0)
        XCTAssertLessThan(SessionModel.paceTolerance, SessionModel.paceInterval)
    }
}
