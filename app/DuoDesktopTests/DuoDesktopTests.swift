import Foundation
import GlassActSession
import LocalAuthentication
import GlassActWire
import SwiftUI
import UIKit
import XCTest
@testable import DuoDesktop

final class Recorder: InputSink, GeometrySink {
    var events: [InputEvent] = []
    var geometry: [(mode: UInt8, w: Int, h: Int, scale: Int)] = []
    func sendInput(kind: UInt8, x: Int, y: Int, a: Int, b: Int) {
        events.append(InputEvent(kind: kind, x: x, y: y, a: a, b: b))
    }
    func setRequestedGeometry(mode: UInt8, widthPoints: Int, heightPoints: Int, scale: Int) {
        geometry.append((mode, widthPoints, heightPoints, scale))
    }
}

private let cmd = 0x0010_0000, shift = 0x0002_0000

private func key(_ id: String, in rows: [[MacKey]] = MacKeyboardLayout.letters) -> MacKey {
    rows.joined().first { $0.id == id }!
}

// MARK: - Geometry guard

final class GeometryGuardTests: XCTestCase {
    func testOnlyScaleAndNativeAreAllowed() {
        for mode: UInt8 in 0...255 {
            XCTAssertEqual(GeometryGuard.isAllowed(mode), mode == GeometryMode.scale || mode == GeometryMode.native,
                           "mode \(mode)")
        }
    }

    func testClientResolutionAndVirtualDisplayAreRefused() {
        let r = Recorder()
        XCTAssertFalse(GeometryGuard.request(mode: GeometryMode.clientResolution, on: r))
        XCTAssertFalse(GeometryGuard.request(mode: GeometryMode.virtualDisplay, on: r))
        XCTAssertTrue(r.geometry.isEmpty, "nothing may be sent for modes 1 and 4")
    }

    func testStandardRequestIsScaleAt1920x1080() {
        let r = Recorder()
        GeometryGuard.requestStandard(on: r)
        XCTAssertEqual(r.geometry.count, 1)
        XCTAssertEqual(r.geometry[0].mode, GeometryMode.scale)
        XCTAssertEqual(r.geometry[0].w, 1920)
        XCTAssertEqual(r.geometry[0].h, 1080)
        XCTAssertEqual(r.geometry[0].scale, 1)
    }

    /// The app's source makes geometry requests only through the guard and never resizes or picks windows.
    func testSourceNeverBypassesTheGuard() throws {
        let appDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("DuoDesktop")
        let files = try FileManager.default.contentsOfDirectory(at: appDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            let name = file.lastPathComponent
            for banned in ["requestResize(", "virtualDisplay", "clientResolution", "selectWindow(", "windowControl("] {
                XCTAssertFalse(text.contains(banned), "\(name) uses \(banned)")
            }
            if name != "GeometryGuard.swift" {
                XCTAssertFalse(text.contains(".setRequestedGeometry("), "\(name) requests geometry outside the guard")
            }
        }
    }
}

// MARK: - Keyboard

final class KeyboardTests: XCTestCase {
    func testLetterSendsKeyCodeInXAndNoFlags() {
        let r = Recorder()
        let k = MacKeyboardEngine(sink: r)
        k.keyDown(key("h"))
        k.keyUp(key("h"))
        XCTAssertEqual(r.events, [InputEvent(kind: 5, x: 4, y: 0, a: 0, b: 0), InputEvent(kind: 6, x: 4, y: 0, a: 0, b: 0)])
    }

    /// "Hi!": a latched Shift for H, then i, then ! from the symbols layer (Shift-1).
    func testTypingHiBang() {
        let r = Recorder()
        let k = MacKeyboardEngine(sink: r)
        k.tapModifier(.shift)
        k.keyDown(key("h")); k.keyUp(key("h"))
        k.keyDown(key("i")); k.keyUp(key("i"))
        let bang = key("!", in: MacKeyboardLayout.symbols)
        k.keyDown(bang); k.keyUp(bang)
        XCTAssertEqual(r.events, [
            InputEvent(kind: 5, x: 56, y: 0, a: shift, b: 0), // Shift down
            InputEvent(kind: 5, x: 4, y: 0, a: shift, b: 0),
            InputEvent(kind: 6, x: 4, y: 0, a: shift, b: 0),
            InputEvent(kind: 6, x: 56, y: 0, a: 0, b: 0), // Shift up after the key's up
            InputEvent(kind: 5, x: 34, y: 0, a: 0, b: 0),
            InputEvent(kind: 6, x: 34, y: 0, a: 0, b: 0),
            InputEvent(kind: 5, x: 18, y: 0, a: shift, b: 0), // ! = Shift-1, its own flag
            InputEvent(kind: 6, x: 18, y: 0, a: shift, b: 0),
        ])
        XCTAssertEqual(k.latch(of: .shift), .off)
    }

    func testOnceLatchAppliesToOneKeyThenReleases() {
        let r = Recorder()
        let k = MacKeyboardEngine(sink: r)
        k.tapModifier(.command)
        XCTAssertEqual(k.latch(of: .command), .once)
        k.keyDown(key("c")); k.keyUp(key("c"))
        XCTAssertEqual(r.events.map(\.a), [cmd, cmd, cmd, 0])
        XCTAssertEqual(r.events.map(\.x), [55, 8, 8, 55])
        XCTAssertEqual(k.latch(of: .command), .off)
    }

    /// No double-tap lock (the owner 2026-11-20): two quick taps leave the modifier released, and nothing is sent.
    func testTwoQuickTapsLetTheModifierGo() {
        let r = Recorder()
        let k = MacKeyboardEngine(sink: r)
        k.tapModifier(.command)
        k.tapModifier(.command)
        XCTAssertEqual(k.latch(of: .command), .off)
        k.keyDown(key("a")); k.keyUp(key("a"))
        XCTAssertEqual(r.events.map(\.a), [0, 0], "a goes alone")
    }

    func testSlowSecondTapUnlatches() {
        let k = MacKeyboardEngine(sink: Recorder())
        k.tapModifier(.option)
        k.tapModifier(.option)
        XCTAssertEqual(k.latch(of: .option), .off)
    }

    func testTwoLatchedModifiersPressInKeyboardOrder() {
        let r = Recorder()
        let k = MacKeyboardEngine(sink: r)
        k.tapModifier(.command)
        k.tapModifier(.shift)
        k.keyDown(key("z")); k.keyUp(key("z"))
        XCTAssertEqual(r.events.map(\.x), [56, 55, 6, 6, 55, 56])
        XCTAssertEqual(r.events[2].a, cmd | shift)
    }

    func testArrowsCarryFunctionAndNumericPadFlags() {
        let r = Recorder()
        let k = MacKeyboardEngine(sink: r)
        k.keyDown(MacKeyboardLayout.left)
        XCTAssertEqual(r.events, [InputEvent(kind: 5, x: 123, y: 0, a: Int(MacKeyFlags.arrow), b: 0)])
    }

    func testEscapeTabAndLayerKeys() {
        XCTAssertEqual(MacKeyboardLayout.escape.code, 53)
        XCTAssertEqual(MacKeyboardLayout.tab.code, 48)
        let r = Recorder()
        let k = MacKeyboardEngine(sink: r)
        k.keyDown(MacKeyboardLayout.layerKey)
        XCTAssertTrue(r.events.isEmpty, "the layer key sends nothing to the Mac")
    }

    func testRepeatTiming() {
        XCTAssertEqual(MacKeyboardEngine.repeatCount(heldFor: 0.49), 0)
        XCTAssertEqual(MacKeyboardEngine.repeatCount(heldFor: 0.5), 1)
        XCTAssertEqual(MacKeyboardEngine.repeatCount(heldFor: 1.0), 11)
    }

    func testRepeatSendsDownsOnlyAndModifiersNeverRepeat() {
        let r = Recorder()
        let k = MacKeyboardEngine(sink: r)
        k.keyDown(key("a")); k.keyRepeat(key("a")); k.keyRepeat(key("a")); k.keyUp(key("a"))
        XCTAssertEqual(r.events.map(\.kind), [5, 5, 5, 6])
        XCTAssertFalse(MacKeyboardLayout.shiftKey.repeats)
        XCTAssertFalse(MacKeyboardLayout.commandKey.repeats)
    }

    func testReleaseAllLiftsHeldKeysAndLatches() {
        let r = Recorder()
        let k = MacKeyboardEngine(sink: r)
        k.tapModifier(.control)
        k.keyDown(key("a"))
        k.releaseAll()
        XCTAssertTrue(k.held.isEmpty)
        XCTAssertEqual(k.latch(of: .control), .off)
        XCTAssertEqual(r.events.filter { $0.kind == 6 }.map(\.x), [0, 59])
    }

    func testEveryKeyHasAUniqueCodeAndAllRowsAreFilled() {
        for layer in [MacKeyboardLayout.letters, MacKeyboardLayout.symbols] {
            XCTAssertEqual(layer.count, 5)
            let keys = layer.joined().filter { $0.role == .key }
            for k in keys { XCTAssertTrue(k.code <= 127, k.label) }
        }
        // Letters: the 26 letters' ANSI codes (Carbon kVK_ANSI_*).
        let expected: [String: UInt16] = ["a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8,
                                          "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
                                          "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45,
                                          "m": 46]
        for (id, code) in expected { XCTAssertEqual(key(id).code, code, id) }
    }
}

// MARK: - Trackpad

final class TrackpadTests: XCTestCase {
    func testGainCurve() {
        XCTAssertEqual(TrackpadEngine.gain(speed: 0), 2, accuracy: 1e-9)
        XCTAssertEqual(TrackpadEngine.gain(speed: 1000), 6, accuracy: 1e-9)
        XCTAssertEqual(TrackpadEngine.gain(speed: 5000), 6, accuracy: 1e-9)
        XCTAssertEqual(TrackpadEngine.gain(speed: 500), 4, accuracy: 1e-9)
        XCTAssertLessThan(TrackpadEngine.gain(speed: 200), TrackpadEngine.gain(speed: 400))
    }

    func testMoveSendsAbsoluteClampedPosition() {
        let r = Recorder()
        let t = TrackpadEngine(sink: r)
        t.setCanvas(width: 1920, height: 1080)
        t.hostPointer(x: 100, y: 100)
        t.move(dx: 10, dy: 5, dt: 1) // slow: gain 2
        XCTAssertEqual(r.events.last, InputEvent(kind: 1, x: 120, y: 110, a: 0, b: 0))
        t.move(dx: -10_000, dy: 10_000, dt: 1)
        XCTAssertEqual(r.events.last, InputEvent(kind: 1, x: 0, y: 1079, a: 0, b: 0))
    }

    func testHostPointerIgnoredOnceThePadIsUsed() {
        let t = TrackpadEngine(sink: Recorder())
        t.hostPointer(x: 10, y: 10)
        t.move(dx: 0, dy: 0, dt: 1)
        t.hostPointer(x: 500, y: 500)
        XCTAssertEqual(t.pixel.0, 10)
    }

    func testTapIsALeftClickAtThePointer() {
        let r = Recorder()
        let t = TrackpadEngine(sink: r)
        t.hostPointer(x: 300, y: 200)
        t.tap(button: 0, at: .zero, time: 1)
        XCTAssertEqual(r.events, [InputEvent(kind: 1, x: 300, y: 200, a: 0, b: 0),
                                  InputEvent(kind: 2, x: 300, y: 200, a: 1, b: 0),
                                  InputEvent(kind: 3, x: 300, y: 200, a: 1, b: 0)])
    }

    func testDoubleAndTripleClick() {
        let r = Recorder()
        let t = TrackpadEngine(sink: r)
        t.tap(button: 0, at: .zero, time: 1)
        t.tap(button: 0, at: CGPoint(x: 3, y: 3), time: 1.2)
        t.tap(button: 0, at: CGPoint(x: 3, y: 3), time: 1.4)
        t.tap(button: 0, at: CGPoint(x: 3, y: 3), time: 3)
        XCTAssertEqual(r.events.filter { $0.kind == 2 }.map(\.a), [1, 2, 3, 1])
    }

    func testTwoFingerTapIsARightClick() {
        let r = Recorder()
        let t = TrackpadEngine(sink: r)
        t.tap(button: 1, at: .zero, time: 1)
        XCTAssertEqual(r.events.filter { $0.kind == 2 || $0.kind == 3 }.map(\.b), [1, 1])
    }

    func testCommandClickWrapsTheClickInTheLatchedModifier() {
        let r = Recorder()
        let k = MacKeyboardEngine(sink: r)
        let t = TrackpadEngine(sink: r)
        t.modifierWrap = { k.withModifiers($0) }
        k.tapModifier(.command)
        t.tap(button: 0, at: .zero, time: 1)
        XCTAssertEqual(r.events.map(\.kind), [5, 1, 2, 3, 6])
        XCTAssertEqual(r.events.first?.x, 55)
        XCTAssertEqual(k.latch(of: .command), .off)
    }

    func testTapThenHoldThenMoveDrags() {
        let r = Recorder()
        let t = TrackpadEngine(sink: r)
        t.hostPointer(x: 100, y: 100)
        t.tap(button: 0, at: .zero, time: 1)
        XCTAssertTrue(t.touchStartsDrag(at: 1.2))
        XCTAssertFalse(t.touchStartsDrag(at: 2))
        r.events.removeAll()
        t.beginDrag()
        t.move(dx: 10, dy: 0, dt: 1)
        t.endDrag()
        XCTAssertEqual(r.events, [InputEvent(kind: 2, x: 100, y: 100, a: 1, b: 0),
                                  InputEvent(kind: 1, x: 120, y: 100, a: 0, b: 0),
                                  InputEvent(kind: 3, x: 120, y: 100, a: 1, b: 0)])
    }

    func testTwoFingerScrollSendsPointsNaturalDirection() {
        let r = Recorder()
        let t = TrackpadEngine(sink: r)
        t.hostPointer(x: 50, y: 60)
        t.scroll(dx: 0.4, dy: 0.4)
        XCTAssertTrue(r.events.isEmpty, "sub-point remainders wait")
        t.scroll(dx: 0.7, dy: -12.3)
        // a = horizontal, b = vertical; fingers down = content down = positive, as the iPad viewer.
        XCTAssertEqual(r.events, [InputEvent(kind: 7, x: 50, y: 60, a: 1, b: -11)])
    }

    func testReleaseAllLiftsAHeldButton() {
        let r = Recorder()
        let t = TrackpadEngine(sink: r)
        t.beginDrag()
        t.releaseAll()
        XCTAssertEqual(r.events.map(\.kind), [2, 3])
        XCTAssertFalse(t.dragging)
    }

    // MARK: Click buttons (the owner 2026-11-20: "There should be a button under the left thumb for click.")

    /// Left click: down while the thumb is down, at the pointer; moves meanwhile are drags; up where it lifts.
    func testLeftClickButtonHeldWhileMovingDrags() {
        let r = Recorder()
        let t = TrackpadEngine(sink: r)
        t.hostPointer(x: 100, y: 100)
        t.pressButton(0, time: 1)
        XCTAssertEqual(r.events, [InputEvent(kind: 1, x: 100, y: 100, a: 0, b: 0),
                                  InputEvent(kind: 2, x: 100, y: 100, a: 1, b: 0)])
        t.move(dx: 10, dy: 0, dt: 1)
        t.move(dx: 0, dy: 10, dt: 1)
        t.releaseButton(0)
        XCTAssertEqual(Array(r.events.dropFirst(2)), [InputEvent(kind: 1, x: 120, y: 100, a: 0, b: 0),
                                                      InputEvent(kind: 1, x: 120, y: 120, a: 0, b: 0),
                                                      InputEvent(kind: 3, x: 120, y: 120, a: 1, b: 0)])
        XCTAssertTrue(t.heldButtons.isEmpty)
        // A second down of the same press, or an up with nothing held, sends nothing.
        r.events.removeAll()
        t.releaseButton(0)
        XCTAssertTrue(r.events.isEmpty)
    }

    /// Quick presses in place are a double, then a triple click; slow ones, or after the pointer moved, single.
    func testQuickPressesAreDoubleAndTripleClicks() {
        let r = Recorder()
        let t = TrackpadEngine(sink: r)
        t.hostPointer(x: 300, y: 300)
        for time in [1.0, 1.3, 1.6, 3.0] { t.pressButton(0, time: time); t.releaseButton(0) }
        XCTAssertEqual(r.events.filter { $0.kind == 2 }.map(\.a), [1, 2, 3, 1])
        XCTAssertEqual(r.events.filter { $0.kind == 3 }.map(\.a), [1, 2, 3, 1])
        r.events.removeAll()
        t.pressButton(0, time: 10); t.releaseButton(0)
        t.move(dx: 20, dy: 0, dt: 1)
        t.pressButton(0, time: 10.2); t.releaseButton(0)
        XCTAssertEqual(r.events.filter { $0.kind == 2 }.map(\.a), [1, 1], "moved away: a new click")
        XCTAssertEqual(TrackpadEngine.buttonMultiClickInterval, 0.5)
    }

    /// Right click: a right button down and up the same way.
    func testRightClickButtonSendsARightClick() {
        let r = Recorder()
        let t = TrackpadEngine(sink: r)
        t.hostPointer(x: 40, y: 50)
        t.pressButton(1, time: 1)
        t.releaseButton(1)
        XCTAssertEqual(r.events, [InputEvent(kind: 1, x: 40, y: 50, a: 0, b: 0),
                                  InputEvent(kind: 2, x: 40, y: 50, a: 1, b: 1),
                                  InputEvent(kind: 3, x: 40, y: 50, a: 1, b: 1)])
    }

    /// A held modifier applies as to a trackpad click: pressed around the button's down, then let go.
    func testHeldModifierAppliesToTheClickButton() {
        let r = Recorder()
        let k = MacKeyboardEngine(sink: r)
        let t = TrackpadEngine(sink: r)
        t.modifierWrap = { k.withModifiers($0) }
        k.tapModifier(.command)
        t.pressButton(0, time: 1)
        t.releaseButton(0)
        XCTAssertEqual(r.events.map(\.kind), [5, 1, 2, 6, 3])
        XCTAssertEqual(r.events.first?.x, 55)
        XCTAssertEqual(k.latch(of: .command), .off)
    }

    /// The held-input release (leaving the app, session end, turning the phone) lifts held click buttons once.
    @MainActor
    func testReleaseLiftsHeldClickButtons() {
        let r = Recorder()
        let parts = SessionParts(sink: r)
        parts.trackpad.pressButton(0, time: 1)
        parts.trackpad.pressButton(1, time: 1)
        r.events.removeAll()
        parts.releaseAll()
        XCTAssertEqual(r.events.filter { $0.kind == 3 }.map(\.b), [0, 1])
        XCTAssertTrue(parts.trackpad.heldButtons.isEmpty)
        r.events.removeAll()
        parts.layoutChanged()
        parts.trackpad.releaseButton(0)   // the thumb lifts afterwards: nothing more
        XCTAssertTrue(r.events.filter { $0.kind == 3 }.isEmpty)
    }

    // MARK: Scroll button (the owner 2026-11-20: "If you press that button and scroll on the trackpad, then it scrolls.")

    /// Held + one finger moving: scroll events at the pointer, the same as two fingers (content follows the finger),
    /// and the pointer stays put. Lifted: the finger moves the pointer again.
    func testScrollButtonHeldTurnsOneFingerIntoScroll() {
        let r = Recorder()
        let t = TrackpadEngine(sink: r)
        t.hostPointer(x: 500, y: 400)
        t.pressScroll()
        t.move(dx: 0, dy: -12, dt: 0.016)
        t.move(dx: 3.5, dy: 0, dt: 0.016)
        t.move(dx: 0.5, dy: 0, dt: 0.016)
        XCTAssertEqual(r.events, [InputEvent(kind: InputKind.scrollPoints, x: 500, y: 400, a: 0, b: -12),
                                  InputEvent(kind: InputKind.scrollPoints, x: 500, y: 400, a: 3, b: 0),
                                  InputEvent(kind: InputKind.scrollPoints, x: 500, y: 400, a: 1, b: 0)])
        XCTAssertEqual(t.pixel.0, 500)
        // The same movement as a two-finger scroll sends the same events.
        let r2 = Recorder()
        let t2 = TrackpadEngine(sink: r2)
        t2.hostPointer(x: 500, y: 400)
        t2.scroll(dx: 0, dy: -12); t2.scroll(dx: 3.5, dy: 0); t2.scroll(dx: 0.5, dy: 0)
        XCTAssertEqual(r2.events, r.events)
        r.events.removeAll()
        t.releaseScroll()
        XCTAssertFalse(t.scrollHeld)
        t.move(dx: 10, dy: 0, dt: 1)
        XCTAssertEqual(r.events, [InputEvent(kind: InputKind.move, x: 520, y: 400, a: 0, b: 0)])
    }

    /// A press of the Scroll button alone sends nothing, and the button comes up with nothing to undo.
    func testScrollButtonTapAloneDoesNothing() {
        let r = Recorder()
        let t = TrackpadEngine(sink: r)
        t.pressScroll()
        t.releaseScroll()
        t.releaseScroll()
        XCTAssertTrue(r.events.isEmpty)
    }

    /// With Left click also held: the Mac's left button stays down while the finger scrolls; it comes up once.
    func testScrollButtonWithLeftClickHeld() {
        let r = Recorder()
        let t = TrackpadEngine(sink: r)
        t.hostPointer(x: 100, y: 100)
        t.pressButton(0, time: 1)
        t.pressScroll()
        t.move(dx: 0, dy: 20, dt: 0.016)
        t.releaseScroll()
        t.move(dx: 5, dy: 0, dt: 1)
        t.releaseButton(0)
        XCTAssertEqual(r.events.map(\.kind), [InputKind.move, InputKind.buttonDown, InputKind.scrollPoints,
                                              InputKind.move, InputKind.buttonUp])
        XCTAssertEqual(r.events[2].b, 20)
    }

    /// The held-input release (leaving, turning, flipping the band) lets go of Scroll too.
    @MainActor
    func testReleaseLetsGoOfScroll() {
        let r = Recorder()
        let parts = SessionParts(sink: r)
        parts.trackpad.pressScroll()
        parts.releaseAll()
        XCTAssertFalse(parts.trackpad.scrollHeld)
        parts.trackpad.move(dx: 10, dy: 0, dt: 1)
        XCTAssertEqual(r.events.last?.kind, InputKind.move)
    }

    /// The click button and a trackpad tap-and-drag share the left button: one down, one up.
    func testClickButtonAndTrackpadDragShareTheLeftButton() {
        let r = Recorder()
        let t = TrackpadEngine(sink: r)
        t.pressButton(0, time: 1)
        t.beginDrag()
        t.endDrag()
        t.releaseButton(0)
        XCTAssertEqual(r.events.filter { $0.kind == 2 || $0.kind == 3 }.map(\.kind), [2, 3])
    }
}

// MARK: - Negotiated canvas (reviewer plan review, finding 1)

final class CanvasGeometryTests: XCTestCase {
    /// A 1600 x 1000 display stays 1600 x 1000 in Scale mode: the pointer stops at its last pixel, not 1919.
    func testPointerBoundsComeFromA1600x1000Canvas() {
        let r = Recorder()
        let t = TrackpadEngine(sink: r)
        t.setCanvas(width: 1600, height: 1000)
        t.hostPointer(x: 800, y: 500)
        t.move(dx: 10_000, dy: 10_000, dt: 1)
        XCTAssertEqual(r.events.last, InputEvent(kind: 1, x: 1599, y: 999, a: 0, b: 0))
        t.tap(button: 0, at: .zero, time: 1)
        XCTAssertEqual(r.events.last, InputEvent(kind: 3, x: 1599, y: 999, a: 1, b: 0))
        t.hostPointer(x: 5000, y: 5000) // a Host report past the edge is clamped too (pad already used: ignored)
        XCTAssertEqual(t.pixel.0, 1599)
    }

    /// The canvas changes mid-session (1920 x 1080 → 1728 x 1080, a large 16:10 display): the pointer keeps its
    /// place in proportion and is clamped to the new canvas.
    func testGeometryChangeRemapsAndClampsThePointer() {
        let r = Recorder()
        let t = TrackpadEngine(sink: r)
        t.setCanvas(width: 1920, height: 1080)
        t.hostPointer(x: 960, y: 540)
        t.move(dx: 10_000, dy: 0, dt: 1) // to the right edge, 1919
        t.setCanvas(width: 1728, height: 1080)
        XCTAssertEqual(t.pixel.0, 1727)
        XCTAssertEqual(t.pixel.1, 540)
        t.move(dx: 10_000, dy: 10_000, dt: 1)
        XCTAssertEqual(r.events.last, InputEvent(kind: 1, x: 1727, y: 1079, a: 0, b: 0))
        t.setCanvas(width: 1600, height: 1000)
        XCTAssertEqual(t.pixel.0, 1599)
        XCTAssertEqual(t.pixel.1, 999)
    }

    /// The frame stays 16:9; a 16:10 picture is fitted inside it, not stretched (pillarboxed), and centred.
    func testPictureIsAspectFittedInThe16x9Frame() {
        let frame = CGSize(width: 640, height: 360) // 16:9
        let f = PictureFit.frame(canvasWidth: 1600, canvasHeight: 1000, in: frame, screenScale: 3)
        XCTAssertEqual(f.height, 360, accuracy: 1e-9)
        XCTAssertEqual(f.width, 576, accuracy: 1e-9) // 360 * 1.6
        XCTAssertEqual(f.minX, 32, accuracy: 1e-9)   // (640 - 576) / 2
        XCTAssertEqual(f.minY, 0, accuracy: 1e-9)
        XCTAssertEqual(f.width / f.height, 1.6, accuracy: 1e-9, "aspect ratio kept")
        let g = PictureFit.frame(canvasWidth: 1728, canvasHeight: 1080, in: frame, screenScale: 3)
        XCTAssertEqual(g.width / g.height, 1.6, accuracy: 1e-9)
        // A 16:9 canvas fills the frame exactly.
        XCTAssertEqual(PictureFit.frame(canvasWidth: 1920, canvasHeight: 1080, in: frame, screenScale: 3),
                       CGRect(x: 0, y: 0, width: 640, height: 360))
    }

    /// The pointer is drawn where the canvas pixel lands inside the fitted picture.
    func testPointerDrawnInsideTheFittedPicture() {
        let frame = CGSize(width: 640, height: 360)
        let last = PictureFit.point(canvasX: 1600, canvasY: 1000, canvasWidth: 1600, canvasHeight: 1000,
                                    in: frame, screenScale: 3)
        XCTAssertEqual(last.x, 608, accuracy: 1e-9) // right edge of the picture, not of the frame
        XCTAssertEqual(last.y, 360, accuracy: 1e-9)
        let origin = PictureFit.point(canvasX: 0, canvasY: 0, canvasWidth: 1600, canvasHeight: 1000,
                                      in: frame, screenScale: 3)
        XCTAssertEqual(origin.x, 32, accuracy: 1e-9)
    }
}

// MARK: - Held input released when hidden or disconnected

@MainActor
final class HeldInputReleaseTests: XCTestCase {
    /// Everything held (a key, a held modifier, a dragging button) is let go by one release, and nothing
    /// further is sent by a second release.
    func testSessionPartsReleaseEverythingOnce() {
        let r = Recorder()
        let parts = SessionParts(sink: r)
        let k = parts.keyboard.engine
        k.tapModifier(.shift)
        k.keyDown(key("a"))
        parts.trackpad.beginDrag()
        r.events.removeAll()
        parts.releaseAll()
        XCTAssertEqual(r.events.filter { $0.kind == InputKind.keyUp }.map(\.x).sorted(), [0, 56],
                       "A and Shift lifted")
        XCTAssertEqual(r.events.filter { $0.kind == InputKind.buttonUp }.count, 1, "button lifted")
        XCTAssertFalse(parts.trackpad.dragging)
        XCTAssertEqual(k.latch(of: .shift), .off)
        r.events.removeAll()
        parts.releaseAll()
        XCTAssertTrue(r.events.isEmpty)
    }

    /// The trackpad view's glide is stopped by a release (its hook runs).
    func testReleaseStopsTheGlide() {
        let t = TrackpadEngine(sink: Recorder())
        var stopped = false
        t.onReleaseAll = { stopped = true }
        t.releaseAll()
        XCTAssertTrue(stopped)
    }
}

// MARK: - M4: Touch ID lock (behind a setting) and About

@MainActor
final class AppLockTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "duo-lock-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    func testFiveMinuteRule() {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertFalse(AppLock.shouldLock(required: true, backgroundedAt: t0, now: t0.addingTimeInterval(299)))
        XCTAssertTrue(AppLock.shouldLock(required: true, backgroundedAt: t0, now: t0.addingTimeInterval(300)))
        XCTAssertFalse(AppLock.shouldLock(required: false, backgroundedAt: t0, now: t0.addingTimeInterval(3600)),
                       "setting off: never locks")
        XCTAssertFalse(AppLock.shouldLock(required: true, backgroundedAt: nil, now: t0))
    }

    func testOnByDefaultLocksAtLaunchAndAfterFiveMinutes() async {
        let d = defaults()
        XCTAssertNil(d.object(forKey: AppLock.settingKey), "fresh install: nothing stored")
        let lock = AppLock(defaults: d) { _ in .success(nil) }
        XCTAssertTrue(lock.required, "on by default (the owner 2026-11-20)")
        XCTAssertTrue(lock.locked, "asks when the app opens")
        await lock.unlock()
        XCTAssertFalse(lock.locked)
        let t0 = Date(timeIntervalSince1970: 0)
        lock.didEnterBackground(now: t0)
        lock.willEnterForeground(now: t0.addingTimeInterval(299))
        XCTAssertFalse(lock.locked)
        lock.didEnterBackground(now: t0)
        lock.willEnterForeground(now: t0.addingTimeInterval(300))
        XCTAssertTrue(lock.locked, "5 minutes away: locked again")
    }

    func testTurningOffAsksFirstAndStaysOff() async {
        let d = defaults()
        var asked = 0
        var answer: Result<LAContext?, Error> = .failure(LAErrorStub.cancel)
        let lock = AppLock(defaults: d) { _ in asked += 1; return answer }
        await lock.setRequired(false)
        XCTAssertTrue(lock.required, "a failed Touch ID leaves the lock on")
        answer = .success(nil)
        await lock.setRequired(false)
        XCTAssertFalse(lock.required)
        XCTAssertEqual(asked, 2)
        let next = AppLock(defaults: d) { _ in .success(nil) }
        XCTAssertFalse(next.required, "off stays off at the next launch")
        XCTAssertFalse(next.locked)
        next.didEnterBackground(now: Date(timeIntervalSince1970: 0))
        next.willEnterForeground(now: Date(timeIntervalSince1970: 10_000))
        XCTAssertFalse(next.locked, "setting off: never locks")
    }

    func testBypassIsThisRunOnly() {
        let d = defaults()
        let bypassed = AppLock(defaults: d, bypass: true) { _ in .success(nil) }
        XCTAssertFalse(bypassed.required)
        XCTAssertFalse(bypassed.locked)
        XCTAssertNil(d.object(forKey: AppLock.settingKey), "bypass stores nothing")
        XCTAssertTrue(AppLock(defaults: d) { _ in .success(nil) }.locked, "next normal launch is locked")
        #if !targetEnvironment(simulator)
        XCTAssertFalse(SimulatorSwitches.noAppLock, "no bypass outside the Simulator")
        #endif
    }

    func testTurningOnAsksFirstThenLocksAtLaunchAndAfterFiveMinutes() async {
        let d = defaults()
        d.set(false, forKey: AppLock.settingKey)
        var asked = 0
        var answer: Result<LAContext?, Error> = .failure(LAErrorStub.cancel)
        let lock = AppLock(defaults: d) { _ in asked += 1; return answer }
        XCTAssertFalse(lock.locked)
        await lock.setRequired(true)
        XCTAssertFalse(lock.required, "a failed Touch ID leaves the lock off")
        answer = .success(nil)
        await lock.setRequired(true)
        XCTAssertTrue(lock.required)
        XCTAssertEqual(asked, 2)
        XCTAssertTrue(AppLock(defaults: d) { _ in .success(nil) }.locked, "next launch starts locked")

        let t0 = Date(timeIntervalSince1970: 0)
        lock.didEnterBackground(now: t0)
        lock.willEnterForeground(now: t0.addingTimeInterval(60))
        XCTAssertFalse(lock.locked, "back within 5 minutes: still unlocked")
        lock.didEnterBackground(now: t0)
        lock.willEnterForeground(now: t0.addingTimeInterval(301))
        XCTAssertTrue(lock.locked)
        answer = .failure(LAErrorStub.cancel)
        await lock.unlock()
        XCTAssertTrue(lock.locked)
        answer = .success(nil)
        await lock.unlock()
        XCTAssertFalse(lock.locked)
    }
}

private enum LAErrorStub: Error { case cancel }

final class AboutTests: XCTestCase {
    /// The built app (this test's host) carries every notice About lists, with the expected texts.
    func testEveryNoticeIsInTheBuiltApp() {
        let notices = AboutView.loadNotices(bundle: .main)
        var expected = 4
        #if DUO_TERMINAL
        expected += 1
        XCTAssertTrue(notices.contains { $0.id == "TerminalNotice" && $0.text.contains("Miguel de Icaza") }, "SwiftTerm")
        #endif
        #if DUO_JETKVM
        expected += 1
        XCTAssertTrue(notices.contains { $0.id == "JetKVMNotice" && $0.text.contains("The WebRTC project authors") },
                      "WebRTC licence")
        #endif
        #if DUO_RDP
        expected += 1
        XCTAssertTrue(notices.contains { $0.id == "RemoteDesktopNotice" && $0.text.contains("== OpenSSL 3.6.5 ==") },
                      "FreeRDP and OpenSSL licences")
        #else
        XCTAssertFalse(notices.contains { $0.text.contains("FreeRDP") }, "no FreeRDP notice without DUO_RDP")
        #endif
        XCTAssertEqual(notices.count, expected)
        // The plain version names neither (the owner 2026-11-21: two versions from one repository).
        #if !DUO_TERMINAL
        XCTAssertFalse(notices.contains { $0.text.contains("SwiftTerm") }, "no SwiftTerm notice in the plain build")
        #endif
        for n in notices { XCTAssertFalse(n.text.hasPrefix("Missing"), n.id) }
        let all = notices.map(\.text).joined(separator: "\n")
        for needle in ["# Glass Act", "Brian Lopez", "# libwebp", "Additional IP Rights Grant (Patents)", "# libaom",
                       "Alliance for Open Media Patent License 1.0", "# av1gpu", "MIT License",
                       "# Third-party notices", "Apps/iPad/SessionModel.swift"] {
            XCTAssertTrue(all.contains(needle), needle)
        }
        XCTAssertEqual(AboutView.glassActCommit.count, 40)
    }
}

// MARK: - Horizontal layout: touch on the whole picture is the mouse

@MainActor
final class HorizontalTouchTests: XCTestCase {
    /// The open Duo held horizontally, in points (simulator).
    let open = CGSize(width: 951, height: 669)

    func testLayoutFollowsTheSceneShape() {
        XCTAssertTrue(SessionLayout.isHorizontal(open))
        XCTAssertFalse(SessionLayout.isHorizontal(CGSize(width: 669, height: 951)))
    }

    /// 1920 x 1080 is wider than the screen: full width, black bands above and below (letterboxed).
    func testLetterboxedPictureMapping() {
        let f = PictureFit.frame(canvasWidth: 1920, canvasHeight: 1080, in: open, screenScale: 3)
        XCTAssertEqual(f.width, 951, accuracy: 0.001)
        XCTAssertEqual(f.height, 951 * 1080 / 1920, accuracy: 0.001)
        XCTAssertGreaterThan(f.minY, 60)
        func map(_ x: CGFloat, _ y: CGFloat) -> [Int]? {
            DirectTouchEngine.canvasPoint(CGPoint(x: x, y: y), picture: f, canvasWidth: 1920, canvasHeight: 1080)
                .map { [$0.0, $0.1] }
        }
        XCTAssertEqual(map(f.minX, f.minY), [0, 0])
        XCTAssertEqual(map(f.midX, f.midY), [960, 540])
        XCTAssertEqual(map(f.maxX - 0.01, f.maxY - 0.01), [1919, 1079])
        XCTAssertNil(map(475, f.minY - 10), "a touch in the band above is not on the Mac")
        XCTAssertNil(map(475, f.maxY + 10), "nor the band below")
        let clamped = DirectTouchEngine.canvasPoint(CGPoint(x: f.midX, y: f.maxY + 10), picture: f,
                                                    canvasWidth: 1920, canvasHeight: 1080, clamp: true)
        XCTAssertEqual(clamped.map { [$0.0, $0.1] }, [960, 1079], "a drag that leaves the picture is pinned to its edge")
    }

    /// A 4:3 canvas (1440 x 1080) is narrower than the screen: full height, bands left and right (pillarboxed).
    func testPillarboxedPictureMapping() {
        let f = PictureFit.frame(canvasWidth: 1440, canvasHeight: 1080, in: open, screenScale: 3)
        XCTAssertEqual(f.height, 669, accuracy: 0.001)
        XCTAssertEqual(f.minY, 0)
        XCTAssertGreaterThan(f.minX, 25)
        func map(_ x: CGFloat, _ y: CGFloat) -> [Int]? {
            DirectTouchEngine.canvasPoint(CGPoint(x: x, y: y), picture: f, canvasWidth: 1440, canvasHeight: 1080)
                .map { [$0.0, $0.1] }
        }
        XCTAssertEqual(map(f.minX, 0), [0, 0])
        XCTAssertEqual(map(f.midX, f.midY), [720, 540])
        XCTAssertEqual(map(f.maxX - 0.01, 668.99), [1439, 1079])
        XCTAssertNil(map(f.minX - 5, 300), "left band")
        XCTAssertNil(map(f.maxX + 5, 300), "right band")
    }

    /// The engine follows the negotiated canvas: after 1920 → 1600 x 1000, the same screen point lands on the
    /// new canvas's pixels.
    func testEngineUsesTheNegotiatedCanvas() {
        let e = DirectTouchEngine(sink: Recorder())
        e.setCanvas(width: 1600, height: 1000)
        let f = PictureFit.frame(canvasWidth: 1600, canvasHeight: 1000, in: open, screenScale: 3)
        let p = e.point(CGPoint(x: f.maxX - 0.01, y: f.maxY - 0.01), picture: f)
        XCTAssertEqual(p.map { [$0.0, $0.1] }, [1599, 999])
    }

    /// Pinch zoom: the zoomed picture can't be pushed off the screen; the mapping follows the zoomed picture.
    func testZoomedMappingAndPanLimit() {
        let z = PictureFit.zoomed(canvasWidth: 1920, canvasHeight: 1080, in: open, screenScale: 3, zoom: 2,
                                  pan: CGPoint(x: 10_000, y: 0))
        XCTAssertEqual(z.pan.x, 951 / 2, accuracy: 0.001, "pan limited to half the overflow")
        XCTAssertEqual(z.frame.minX, 0, accuracy: 0.34, "left edge of the picture at the screen's left edge")
        let p = DirectTouchEngine.canvasPoint(CGPoint(x: 1, y: z.frame.midY), picture: z.frame,
                                              canvasWidth: 1920, canvasHeight: 1080)
        XCTAssertEqual(p?.0, 1, "one point in at 2x zoom is about one canvas pixel (fit is ~0.5)")
        XCTAssertEqual(PictureFit.zoomed(canvasWidth: 1920, canvasHeight: 1080, in: open, screenScale: 3, zoom: 1,
                                         pan: CGPoint(x: 50, y: 50)).pan, .zero)
    }

    /// Tap = move there, press, release; a second tap close by is a double click; two-finger tap = right click.
    func testTapsClickWhereTouched() {
        let r = Recorder()
        let e = DirectTouchEngine(sink: r)
        e.click(at: (100, 200), button: 0, time: 1)
        e.click(at: (110, 205), button: 0, time: 1.2)
        e.click(at: (500, 500), button: 1, time: 5)
        XCTAssertEqual(r.events, [
            InputEvent(kind: 1, x: 100, y: 200, a: 0, b: 0),
            InputEvent(kind: 2, x: 100, y: 200, a: 1, b: 0),
            InputEvent(kind: 3, x: 100, y: 200, a: 1, b: 0),
            InputEvent(kind: 1, x: 110, y: 205, a: 0, b: 0),
            InputEvent(kind: 2, x: 110, y: 205, a: 2, b: 0),
            InputEvent(kind: 3, x: 110, y: 205, a: 2, b: 0),
            InputEvent(kind: 1, x: 500, y: 500, a: 0, b: 0),
            InputEvent(kind: 2, x: 500, y: 500, a: 1, b: 1),
            InputEvent(kind: 3, x: 500, y: 500, a: 1, b: 1),
        ])
    }

    /// Drag presses where the finger first touched, follows it, and lets go where it lifts; a scroll puts the
    /// pointer where it started, then scrolls there.
    func testDragAndScroll() {
        let r = Recorder()
        let e = DirectTouchEngine(sink: r)
        e.beginDrag(at: (10, 10), now: (20, 15))
        e.dragMoved(to: (40, 30))
        e.endDrag(at: (50, 35))
        e.beginScroll(at: (300, 300))
        r.events.removeLast()
        e.scroll(dx: 0.6, dy: -12.4)
        e.scroll(dx: 0.6, dy: 0)
        XCTAssertEqual(r.events, [
            InputEvent(kind: 1, x: 10, y: 10, a: 0, b: 0),
            InputEvent(kind: 2, x: 10, y: 10, a: 1, b: 0),
            InputEvent(kind: 1, x: 20, y: 15, a: 0, b: 0),
            InputEvent(kind: 1, x: 40, y: 30, a: 0, b: 0),
            InputEvent(kind: 3, x: 50, y: 35, a: 1, b: 0),
            InputEvent(kind: 7, x: 300, y: 300, a: 0, b: -12),
            InputEvent(kind: 7, x: 300, y: 300, a: 1, b: 0),
        ])
        XCTAssertFalse(e.dragging)
    }

    /// Turning the phone mid-session lets go of a touch drag, a held key, a held modifier and a trackpad drag,
    /// once; a second switch sends nothing.
    func testTurningThePhoneReleasesEverythingOnce() {
        let r = Recorder()
        let parts = SessionParts(sink: r)
        let k = parts.keyboard.engine
        k.tapModifier(.command)
        k.keyDown(key("a"))
        parts.trackpad.beginDrag()
        parts.touch.beginDrag(at: (5, 5), now: (300, 400))
        r.events.removeAll()
        parts.layoutChanged()
        XCTAssertEqual(r.events.filter { $0.kind == InputKind.keyUp }.map(\.x).sorted(), [0, 55],
                       "A and Command lifted")
        let ups = r.events.filter { $0.kind == InputKind.buttonUp }
        XCTAssertEqual(ups.count, 2, "both held buttons lifted")
        XCTAssertTrue(ups.contains(InputEvent(kind: 3, x: 300, y: 400, a: 1, b: 0)), "touch drag lifted where it was")
        XCTAssertFalse(parts.touch.dragging)
        XCTAssertFalse(parts.trackpad.dragging)
        r.events.removeAll()
        parts.layoutChanged()
        XCTAssertTrue(r.events.isEmpty)
    }

    /// Where touch leaves the pointer is where the trackpad carries on after turning upright.
    func testTrackpadCarriesOnFromTheTouchPointer() {
        let parts = SessionParts(sink: Recorder())
        parts.setCanvas(width: 1920, height: 1080)
        parts.touch.click(at: (1234, 567), button: 0, time: 0)
        XCTAssertEqual(parts.trackpad.pixel.0, 1234)
        XCTAssertEqual(parts.trackpad.pixel.1, 567)
    }
}

// MARK: - Touch like Apple's touch-display MacBook (the owner 2026-11-20; table in project notes)

@MainActor final class TouchLikeMacBookProTests: XCTestCase {
    private let ctl = Int(KeyMap.Modifier.control.eventFlags)
    private let arrow = Int(MacKeyFlags.arrow)

    private func move(_ x: Int, _ y: Int) -> InputEvent { InputEvent(kind: 1, x: x, y: y, a: 0, b: 0) }
    private func down(_ x: Int, _ y: Int, count: Int = 1, button: Int = 0) -> InputEvent {
        InputEvent(kind: 2, x: x, y: y, a: count, b: button)
    }
    private func up(_ x: Int, _ y: Int, count: Int = 1, button: Int = 0) -> InputEvent {
        InputEvent(kind: 3, x: x, y: y, a: count, b: button)
    }

    /// Row "Tap": the pointer moves to the finger, then a left click there.
    func testTapIsAClickWhereTouched() {
        let r = Recorder()
        DirectTouchEngine(sink: r).click(at: (640, 360), button: 0, time: 10)
        XCTAssertEqual(r.events, [move(640, 360), down(640, 360), up(640, 360)])
    }

    /// Row "Double-tap": the second quick tap close by is a double click (click count 2).
    func testDoubleTapIsADoubleClick() {
        let r = Recorder()
        let e = DirectTouchEngine(sink: r)
        e.click(at: (640, 360), button: 0, time: 10)
        e.click(at: (645, 362), button: 0, time: 10.25)
        XCTAssertEqual(Array(r.events.suffix(3)), [move(645, 362), down(645, 362, count: 2), up(645, 362, count: 2)])
        r.events.removeAll()
        e.click(at: (645, 362), button: 0, time: 12)
        XCTAssertEqual(r.events[1], down(645, 362), "a slow second tap is a new single click")
    }

    /// Row "Touch and hold" (still, then lift): a right click where the finger was held; nothing until the lift.
    func testStillHoldIsARightClick() {
        let r = Recorder()
        let e = DirectTouchEngine(sink: r)
        e.holdBegan(at: (100, 200))
        XCTAssertTrue(r.events.isEmpty, "holding alone sends nothing yet")
        e.holdEnded(at: (101, 201), time: 3)
        XCTAssertEqual(r.events, [move(100, 200), down(100, 200, button: 1), up(100, 200, button: 1)])
        XCTAssertNil(e.holdAt)
    }

    /// Row "Touch and hold, then drag": left button down where it was held, follows the finger, up at the lift;
    /// no right click.
    func testHoldThenMoveIsADrag() {
        let r = Recorder()
        let e = DirectTouchEngine(sink: r)
        e.holdBegan(at: (100, 200))
        e.holdMoved(to: (130, 210))
        e.holdMoved(to: (400, 300))
        e.holdEnded(at: (410, 305), time: 4)
        XCTAssertEqual(r.events, [move(100, 200), down(100, 200), move(130, 210), move(400, 300), up(410, 305)])
        XCTAssertFalse(e.dragging)
    }

    /// A held touch the system takes away (or the phone turning) lets go, and is not a right click.
    func testCancelledHoldLetsGoWithoutARightClick() {
        let r = Recorder()
        let e = DirectTouchEngine(sink: r)
        e.holdBegan(at: (1, 1))
        e.holdCancelled()
        XCTAssertTrue(r.events.isEmpty)
        e.holdBegan(at: (1, 1))
        e.holdMoved(to: (50, 50))
        e.holdCancelled()
        XCTAssertEqual(r.events.last, up(50, 50))
        e.holdEnded(at: nil, time: 9)
        XCTAssertEqual(r.events.count, 4, "nothing after the cancel")
    }

    /// Row "Scroll or pan, one finger": the pointer goes where the finger started, then the content follows the
    /// finger (finger up = negative dy, as the trackpad's natural scroll), in canvas pixels, at that point.
    func testOneFingerMovingScrolls() {
        let r = Recorder()
        let e = DirectTouchEngine(sink: r)
        e.beginScroll(at: (960, 540))
        e.scroll(dx: 0, dy: -30.6)
        e.scroll(dx: 2.2, dy: -0.6)
        XCTAssertEqual(r.events, [
            move(960, 540),
            InputEvent(kind: 7, x: 960, y: 540, a: 0, b: -30),
            InputEvent(kind: 7, x: 960, y: 540, a: 2, b: -1),
        ])
        XCTAssertFalse(r.events.contains { $0.kind == InputKind.buttonDown }, "a scroll never presses")
    }

    /// Row "Scroll quickly": a quick swipe glides on after the lift, slowing each frame, then stops.
    func testQuickSwipeGlidesThenStops() {
        var v = CGPoint(x: 0, y: -1500)
        var moves: [CGFloat] = []
        while let step = CanvasView.glideStep(v, dt: 1.0 / 60) {
            v = step.velocity
            moves.append(step.move.y)
        }
        XCTAssertGreaterThan(moves.count, 30)
        XCTAssertTrue(moves.allSatisfy { $0 < 0 }, "glides on in the swipe's direction")
        XCTAssertTrue(zip(moves, moves.dropFirst()).allSatisfy { abs($1) < abs($0) }, "slows every frame")
        XCTAssertNil(CanvasView.glideStep(CGPoint(x: 10, y: 10), dt: 1.0 / 60), "a slow lift doesn't glide")
    }

    /// Rows "Show the Dock / menu bar (when hidden)": a swipe in from the bottom or top edge moves the pointer to
    /// that edge; a swipe along the edge, or out of it, is a scroll.
    func testEdgeSwipesPutThePointerOnTheEdge() {
        let f = CGRect(x: 0, y: 100, width: 669, height: 376)
        XCTAssertEqual(CanvasView.edgeSwipe(start: CGPoint(x: 300, y: 104), translation: CGPoint(x: 2, y: 30),
                                            picture: f), true)
        XCTAssertEqual(CanvasView.edgeSwipe(start: CGPoint(x: 300, y: 92), translation: CGPoint(x: 0, y: 30),
                                            picture: f), true, "from the black just above the picture too")
        XCTAssertEqual(CanvasView.edgeSwipe(start: CGPoint(x: 300, y: 470), translation: CGPoint(x: 0, y: -30),
                                            picture: f), false)
        XCTAssertNil(CanvasView.edgeSwipe(start: CGPoint(x: 300, y: 104), translation: CGPoint(x: 0, y: -30),
                                          picture: f))
        XCTAssertNil(CanvasView.edgeSwipe(start: CGPoint(x: 300, y: 104), translation: CGPoint(x: 40, y: 10),
                                          picture: f))
        XCTAssertNil(CanvasView.edgeSwipe(start: CGPoint(x: 300, y: 250), translation: CGPoint(x: 0, y: 30),
                                          picture: f))
        let r = Recorder()
        let e = DirectTouchEngine(sink: r)
        e.setCanvas(width: 1920, height: 1080)
        e.pointerToEdge(x: 700, top: false)
        e.pointerToEdge(x: 2500, top: true)
        XCTAssertEqual(r.events, [move(700, 1079), move(1919, 0)])
    }

    /// Rows "Mission Control", "App Exposé", "Switch between spaces": three fingers send the Mac's default
    /// shortcuts (⌃↑, ⌃↓, ⌃→ for a swipe left, ⌃← for a swipe right), arrows with their own fn/keypad flags.
    func testThreeFingerSwipesSendTheMissionControlShortcuts() {
        XCTAssertEqual(CanvasView.threeFingerSwipe(CGPoint(x: 5, y: -80)), .up)
        XCTAssertEqual(CanvasView.threeFingerSwipe(CGPoint(x: 5, y: 80)), .down)
        XCTAssertEqual(CanvasView.threeFingerSwipe(CGPoint(x: -90, y: 10)), .left)
        XCTAssertEqual(CanvasView.threeFingerSwipe(CGPoint(x: 90, y: 10)), .right)
        XCTAssertNil(CanvasView.threeFingerSwipe(CGPoint(x: 10, y: 20)), "too short")
        let r = Recorder()
        let parts = SessionParts(sink: r)
        for (swipe, code) in [(DirectTouchEngine.Swipe.up, 126), (.down, 125), (.left, 124), (.right, 123)] {
            r.events.removeAll()
            parts.touch.threeFingerSwipe(swipe)
            XCTAssertEqual(r.events, [
                InputEvent(kind: 5, x: 59, y: 0, a: ctl, b: 0),
                InputEvent(kind: 5, x: code, y: 0, a: ctl | arrow, b: 0),
                InputEvent(kind: 6, x: code, y: 0, a: ctl | arrow, b: 0),
                InputEvent(kind: 6, x: 59, y: 0, a: 0, b: 0),
            ], "\(swipe)")
        }
    }

    /// Row "Zoom in and out" (pinch): the picture zooms on the phone; the Mac is sent nothing. Upright too: the
    /// pinch zooms the 16:9 picture above the keys, and taps land on the zoomed picture's pixels.
    func testPinchZoomsThePictureUpright() {
        let upright = SessionLayout.Upright(size: CGSize(width: 669, height: 951), keyboardInset: 300).picture.size
        let z = PictureFit.zoomed(canvasWidth: 1920, canvasHeight: 1080, in: upright, screenScale: 3, zoom: 3,
                                  pan: .zero)
        let centre = DirectTouchEngine.canvasPoint(CGPoint(x: upright.width / 2, y: upright.height / 2),
                                                   picture: z.frame, canvasWidth: 1920, canvasHeight: 1080)
        XCTAssertEqual(centre?.0 ?? 0, 960, accuracy: 2)
        XCTAssertEqual(centre?.1 ?? 0, 540, accuracy: 2)
        let corner = DirectTouchEngine.canvasPoint(.zero, picture: z.frame, canvasWidth: 1920, canvasHeight: 1080)
        XCTAssertEqual(corner?.0 ?? 0, 640, accuracy: 2, "at 3x the left edge shows a third of the way in")
    }

    /// Mapping, upright: the 16:9 picture above the keys; a 16:9 canvas fills it, a 4:3 one is pillarboxed and its
    /// bands are not the Mac.
    func testUprightMapping() {
        let box = SessionLayout.Upright(size: CGSize(width: 669, height: 951), keyboardInset: 300).picture.size
        let f = PictureFit.frame(canvasWidth: 1920, canvasHeight: 1080, in: box, screenScale: 3)
        func map(_ p: CGPoint, _ f: CGRect, _ w: Int, _ h: Int) -> [Int]? {
            DirectTouchEngine.canvasPoint(p, picture: f, canvasWidth: w, canvasHeight: h).map { [$0.0, $0.1] }
        }
        XCTAssertEqual(map(CGPoint(x: f.minX, y: f.minY), f, 1920, 1080), [0, 0])
        XCTAssertEqual(map(CGPoint(x: f.midX, y: f.midY), f, 1920, 1080), [960, 540])
        XCTAssertEqual(map(CGPoint(x: f.maxX - 0.01, y: f.maxY - 0.01), f, 1920, 1080), [1919, 1079])
        let p = PictureFit.frame(canvasWidth: 1440, canvasHeight: 1080, in: box, screenScale: 3)
        XCTAssertEqual(p.height, box.height, accuracy: 0.001)
        let mid = map(CGPoint(x: p.midX, y: p.midY), p, 1440, 1080) ?? []
        XCTAssertEqual(Double(mid.first ?? 0), 720, accuracy: 1, "within a pixel: the frame sits on whole device pixels")
        XCTAssertEqual(mid.last, 540)
        XCTAssertNil(map(CGPoint(x: p.minX - 4, y: p.midY), p, 1440, 1080), "left band")
        XCTAssertNil(map(CGPoint(x: p.maxX + 4, y: p.midY), p, 1440, 1080), "right band")
    }

    /// Mapping, horizontal: the same screen point maps to the same pixel whichever layout the engine was used in;
    /// the engine itself has no layout.
    func testHorizontalMappingUnchanged() {
        let f = PictureFit.frame(canvasWidth: 1920, canvasHeight: 1080, in: CGSize(width: 951, height: 669),
                                 screenScale: 3)
        let e = DirectTouchEngine(sink: Recorder())
        XCTAssertEqual(e.point(CGPoint(x: f.midX, y: f.midY), picture: f).map { [$0.0, $0.1] }, [960, 540])
        XCTAssertNil(e.point(CGPoint(x: 400, y: f.minY - 5), picture: f))
    }

    /// Held modifier keys apply to a touch as to a trackpad click: ⌘ held + tap is a Command-click; ⌃ held + a
    /// still hold is a Control-right-click. A one-shot ⌘ is used up by the tap.
    func testHeldModifiersApplyToTouchClicks() {
        let r = Recorder()
        let parts = SessionParts(sink: r)
        let k = parts.keyboard.engine
        k.tapModifier(.command)
        r.events.removeAll()
        parts.touch.click(at: (10, 20), button: 0, time: 1)
        let cmdFlags = Int(KeyMap.Modifier.command.eventFlags)
        XCTAssertEqual(r.events, [
            move(10, 20),
            InputEvent(kind: 5, x: 55, y: 0, a: cmdFlags, b: 0),
            down(10, 20), up(10, 20),
            InputEvent(kind: 6, x: 55, y: 0, a: 0, b: 0),
        ])
        k.tapModifier(.control)
        r.events.removeAll()
        parts.touch.holdBegan(at: (30, 40))
        parts.touch.holdEnded(at: (30, 40), time: 5)
        XCTAssertEqual(r.events, [
            move(30, 40),
            InputEvent(kind: 5, x: 59, y: 0, a: ctl, b: 0),
            down(30, 40, button: 1), up(30, 40, button: 1),
            InputEvent(kind: 6, x: 59, y: 0, a: 0, b: 0),
        ])
    }

    /// Turning the phone mid-hold lets go of the touch drag and drops the hold (no right click afterwards).
    func testTurningThePhoneDropsAHold() {
        let r = Recorder()
        let parts = SessionParts(sink: r)
        parts.touch.holdBegan(at: (5, 5))
        parts.touch.holdMoved(to: (9, 9))
        parts.layoutChanged()
        XCTAssertEqual(r.events.last, up(9, 9))
        XCTAssertNil(parts.touch.holdAt)
    }
}

// MARK: - Keyboard at standard key sizes (the owner 2026-11-20: "The keyboard shouldn't be weirdly stretched.")

final class KeySizeTests: XCTestCase {
    /// The Duo open, upright: 669 x 951 pt less the top row (the navigation bar in the clock's row ends at 82 pt,
    /// measured by `testPictureStartsAtTheBottomOfTheTopRowAndTheRowIsTheClocksRow`) and the bottom safe area (34).
    let safeUpright = CGSize(width: 669, height: 951 - 82 - 34)
    /// Keyboard heights above the bottom safe area: none, this simulator's keyboard (277, seen live), a portrait
    /// iPhone keyboard (291), with a suggestion bar (about 321), and taller ones, to make sure the layout gives way.
    let keyboardInsets: [CGFloat] = [0, 216, 273, 277, 285, 291, 292, 317, 321, 333, 336, 380, 450]

    /// The owner 2026-11-20: "we should have a system standard keyboard on the bottom, and the middle part should be a
    /// trackpad." The picture, the band, the special keys and the trackpad never reach into the keyboard's frame.
    func testPictureAndMiddleBandNeverOverlapTheKeyboard() {
        for inset in keyboardInsets {
            let u = SessionLayout.Upright(size: safeUpright, keyboardInset: inset)
            let keyboard = CGRect(x: 0, y: u.keyboardTop, width: safeUpright.width, height: inset)
            for (name, r) in [("picture", u.picture), ("band", u.band), ("keys", u.keys), ("trackpad", u.trackpad)] {
                XCTAssertFalse(r.intersects(keyboard), "\(name) \(r) under the keyboard \(keyboard)")
                XCTAssertLessThanOrEqual(r.maxY, u.keyboardTop, "\(name) at inset \(inset)")
            }
            // The band sits below the picture whenever the keys' floor at minimum spacing fits (here up to 323).
            if inset <= 323 {
                XCTAssertFalse(u.overlapsPicture, "inset \(inset)")
                XCTAssertLessThanOrEqual(u.picture.maxY, u.band.minY, "inset \(inset)")
            }
            XCTAssertEqual(u.keys.width, u.trackpad.width, accuracy: 1)
            XCTAssertEqual(u.trackpad.height, u.band.height)
            // The 8 x 4 grid fits its half, both ways.
            let m = u.keyMetrics
            XCTAssertLessThanOrEqual(m.width(units: SpecialKeysLayout.units), u.keys.width, "inset \(inset)")
            XCTAssertLessThanOrEqual(m.height(rows: 4), u.keys.height + 0.5, "inset \(inset)")
            XCTAssertGreaterThanOrEqual(u.spacing.pad, SessionLayout.Upright.minBandPad)
            XCTAssertGreaterThanOrEqual(u.spacing.rowGap, SessionLayout.Upright.minRowGap)
        }
        // Standard spacing while the keys are above their floor (room >= 154 pt: a keyboard up to 305 pt).
        for inset: CGFloat in [0, 216, 273, 277, 293, 305] {
            let u = SessionLayout.Upright(size: safeUpright, keyboardInset: inset)
            XCTAssertEqual(u.spacing.pad, SessionLayout.Upright.bandPad, "inset \(inset)")
            XCTAssertEqual(u.spacing.rowGap, KeyMetrics.gap, "inset \(inset)")
        }
        // The suggestion bar's keyboard (321): keys at the floor, the padding and then the row gap give way.
        let bar = SessionLayout.Upright(size: safeUpright, keyboardInset: 321)
        XCTAssertEqual(bar.keyMetrics.keyHeight, SessionLayout.Upright.minKeyHeight)
        XCTAssertEqual(bar.spacing.pad, SessionLayout.Upright.minBandPad)
        XCTAssertFalse(bar.overlapsPicture)
        // Too tall even for the floor at minimum spacing: the band covers the picture's bottom edge. (Its top
        // padding is used up first, so it first touches the picture at 326.)
        XCTAssertFalse(SessionLayout.Upright(size: safeUpright, keyboardInset: 325).overlapsPicture)
        XCTAssertTrue(SessionLayout.Upright(size: safeUpright, keyboardInset: 326).overlapsPicture)
    }

    /// The owner 2026-11-20: "We can make our keys smaller to get 4 rows?" / "Yes". On his phone (keyboard 293 pt, so
    /// 166 pt of room and a 150 pt band): 4 rows of 33 pt keys with 6 pt gaps (132 + 18 = 150), 35 pt wide.
    func testBensPhoneGetsFourRowsOf33ptKeys() {
        let u = SessionLayout.Upright(size: safeUpright, keyboardInset: 293)
        XCTAssertEqual(u.keyboardTop - u.picture.maxY, 166)
        XCTAssertEqual(u.band.height, 150)
        XCTAssertEqual(u.keyMetrics.keyHeight, 33)
        XCTAssertEqual(u.keyMetrics.rowGap, 6)
        XCTAssertEqual(u.keyMetrics.keyWidth, 35)
        XCTAssertEqual(u.keyMetrics.height(rows: 4), 150)
        XCTAssertFalse(u.overlapsPicture)
        // This simulator's keyboard (277): the same grid, rows grown to fill a 166 pt band.
        let sim = SessionLayout.Upright(size: safeUpright, keyboardInset: 277)
        XCTAssertEqual(sim.band.height, 166)
        XCTAssertEqual(sim.keyMetrics.keyHeight, 37)
        XCTAssertEqual(sim.keyMetrics.height(rows: 4), 166, accuracy: 0.01)
    }

    /// The floor, at stated heights: the keys never go under 30 pt; at the floor the padding gives way, then the
    /// row gap; the band needs at least 136 pt (4 x 30 + 3 x 4 + 2 x 2), a keyboard up to 323 pt here.
    func testKeysStopAtTheFloorThenSpacingGivesWay() {
        XCTAssertEqual(SessionLayout.Upright.minKeyHeight, 30)
        XCTAssertEqual(SessionLayout.Upright.minimumRoom, 136)
        for inset in stride(from: CGFloat(0), through: 500, by: 1) {
            let u = SessionLayout.Upright(size: safeUpright, keyboardInset: inset)
            XCTAssertGreaterThanOrEqual(u.keyMetrics.keyHeight, SessionLayout.Upright.minKeyHeight, "inset \(inset)")
            XCTAssertEqual(u.picture.width, safeUpright.width)
        }
        // Above the floor (keyboard up to 305): standard spacing; 306-323: at the floor, spacing gives way.
        let tight = SessionLayout.Upright(size: safeUpright, keyboardInset: 323)
        XCTAssertEqual(tight.spacing.pad, SessionLayout.Upright.minBandPad)
        XCTAssertEqual(tight.spacing.rowGap, SessionLayout.Upright.minRowGap)
        XCTAssertEqual(tight.keyMetrics.keyHeight, 30)
        XCTAssertFalse(tight.overlapsPicture)
        let over = SessionLayout.Upright(size: safeUpright, keyboardInset: 400)
        XCTAssertTrue(over.overlapsPicture)
        XCTAssertEqual(over.keyMetrics.keyHeight, 30)
        XCTAssertLessThanOrEqual(over.band.maxY, over.keyboardTop)
    }

    /// From the owner's 150 pt band upward (and at every keyboard height), the 4 rows fill the band: top and bottom
    /// level with the trackpad's, whole-point keys, spare points in the gaps, the same key width throughout.
    func testFourRowsFillTheBandsHeight() {
        let width = SessionLayout.Upright(size: safeUpright, keyboardInset: 293).keyMetrics.keyWidth
        for inset in stride(from: CGFloat(0), through: 500, by: 1) {
            let u = SessionLayout.Upright(size: safeUpright, keyboardInset: inset)
            let m = u.keyMetrics
            XCTAssertEqual(m.keyWidth, width, "inset \(inset)")
            XCTAssertEqual(m.keyHeight, m.keyHeight.rounded(), "whole points, inset \(inset)")
            XCTAssertGreaterThanOrEqual(m.rowGap, u.spacing.rowGap, "inset \(inset)")
            XCTAssertLessThan(m.rowGap, u.spacing.rowGap + 1.34, "spare points go to the gaps, inset \(inset)")
            XCTAssertEqual(m.height(rows: 4), u.band.height, accuracy: 0.01, "inset \(inset)")
        }
        // Band heights from the owner's 150 pt upward: key = whole points of (band - 18) / 4.
        for band in stride(from: CGFloat(150), through: 300, by: 1) {
            let r = SessionLayout.Upright.rowMetrics(bandHeight: band, rowGap: KeyMetrics.gap)
            XCTAssertEqual(r.keyHeight, ((band - 18) / 4).rounded(.down), "band \(band)")
            XCTAssertEqual(4 * r.keyHeight + 3 * r.rowGap, band, accuracy: 0.01, "band \(band)")
            XCTAssertGreaterThanOrEqual(r.keyHeight, 33)
        }
    }

    /// The owner 2026-11-20: "The Mac screen needs to be max width." At every keyboard height, every step from none to
    /// taller than any real keyboard, the picture is the screen's full width, 16:9, from the top row's bottom.
    func testPictureIsAlwaysTheFullWidthAndStartsAtTheTopRowsBottom() {
        for inset in stride(from: CGFloat(0), through: 500, by: 1) {
            let u = SessionLayout.Upright(size: safeUpright, keyboardInset: inset)
            XCTAssertEqual(u.picture.minX, 0, "inset \(inset)")
            XCTAssertEqual(u.picture.minY, 0, "inset \(inset)")
            XCTAssertEqual(u.picture.width, safeUpright.width, "inset \(inset)")
            XCTAssertEqual(u.picture.height, (safeUpright.width * 9 / 16).rounded(.down), "inset \(inset)")
        }
    }

    /// One grid: 8 equal columns across the keys' half (2 for the click buttons, 6 for the keys), 6 pt apart.
    func testSpecialKeysAreOneUniformGrid() {
        XCTAssertEqual(SpecialKeysLayout.gridColumns, 8)
        XCTAssertEqual(SpecialKeysLayout.columns, 6)
        XCTAssertEqual(ClickButtonsLayout.columns, 2)
        for inset in stride(from: CGFloat(0), through: 500, by: 1) {
            let u = SessionLayout.Upright(size: safeUpright, keyboardInset: inset)
            let m = u.keyMetrics
            XCTAssertGreaterThanOrEqual(m.keyWidth, 34, "inset \(inset)")
            XCTAssertEqual(m.width(units: SpecialKeysLayout.units), u.keys.width, accuracy: 8, "inset \(inset)")
        }
        XCTAssertEqual(KeyMetrics.gap, 6)
    }

    /// The 24 keys, and never fn (the owner 2026-11-20: "I think fn is the one to go?").
    private let allIDs = Set(MacShortcut.all.map { "s-" + $0.id } + [
        "k-control", "k-option", "k-command", "k-shift", "k-left", "k-up", "k-down", "k-right",
        "k-escape", "k-tab", "k-forwarddelete", "k-fblock"])

    private func keyIDs(_ row: [MacKeyboardLayout.Cell]) -> [String?] {
        row.map { if case .gap = $0 { nil } else { $0.id } }
    }

    /// The owner's table (mock-up, 2026-11-20: "Looks good. Build it"): 4 rows of 6 one-wide keys, no empty cell, no fn,
    /// every one of the 24 keys once, the arrows together, ⌃ ⌥ ⌘ ⇧ together in the bottom row.
    func testKeysAreFourRowsOfSixInBensOrder() {
        let rows = SpecialKeysLayout.rows(functionKeys: false)
        XCTAssertEqual(rows.map { $0.map(\.id) }, [
            ["s-copy", "s-paste", "s-cut", "s-undo", "s-redo", "s-selectall"],
            ["s-save", "s-find", "s-switchapp", "s-spotlight", "s-close", "s-quit"],
            ["k-escape", "k-tab", "k-left", "k-up", "k-down", "k-right"],
            ["k-control", "k-option", "k-command", "k-shift", "k-forwarddelete", "k-fblock"],
        ])
        for functionKeys in [false, true] {
            let rows = SpecialKeysLayout.rows(functionKeys: functionKeys)
            XCTAssertEqual(rows.count, 4)
            for row in rows {
                XCTAssertEqual(row.count, 6)
                XCTAssertTrue(row.allSatisfy { $0.width == 1 })
                for cell in row { if case .gap = cell { XCTFail("empty cell \(cell.id)") } }
            }
            let ids = rows.joined().map(\.id)
            XCTAssertEqual(Set(ids).count, 24)
            XCTAssertFalse(ids.contains("k-fn"))
        }
        XCTAssertEqual(Set(rows.joined().map(\.id)), allIDs)
        XCTAssertNil(MacKeysBar.keys.first { $0.id == "fn" })
        // The buttons (the owner 2026-11-20: "a 2x2 button that is the left click, a 1x2 button that is right click, and
        // a 1x2 button that is scroll"): top to bottom Left 2 rows, Right 1, Scroll 1, all 2 wide; the grid's 4 rows.
        XCTAssertEqual(ClickButtonsLayout.stack.map(\.button), [.right, .scroll, .left])
        XCTAssertEqual(ClickButtonsLayout.stack.map(\.rows), [1, 1, 2])
        XCTAssertEqual(ClickButtonsLayout.stack.map(\.rows).reduce(0, +), SpecialKeysLayout.rowCount)
        for side in TrackpadSide.allCases {
            let m = SessionLayout.Upright(size: safeUpright, keyboardInset: 293, side: side).keyMetrics
            XCTAssertEqual(m.height(rows: ClickButtonsLayout.leftRows), 2 * 33 + 6)
            XCTAssertEqual(m.height(rows: ClickButtonsLayout.scrollRows), 33)
            XCTAssertEqual(m.width(units: 2), 2 * 35 + 6)
            // Left 2 rows + Right + Scroll with their gaps = the 4 key rows exactly.
            let stacked = ClickButtonsLayout.stack.map { m.height(rows: $0.rows) }.reduce(0, +) + 2 * m.rowGap
            XCTAssertEqual(stacked, m.height(rows: 4), accuracy: 0.001)
        }
    }

    // MARK: Trackpad on the left (the owner 2026-11-20: "It should be an option to flip the buttons and the trackpad")

    /// The keys do not flip (the owner 2026-11-20: "All of our extra modifier keys should stay the same. They should not
    /// flip."): one order, the table's, with and without "more", whichever side the trackpad is on.
    func testKeysKeepTheirOrderWithTheTrackpadOnTheLeft() {
        for more in [false, true] {
            let rows = SpecialKeysLayout.rows(functionKeys: more)
            XCTAssertEqual(rows.count, SpecialKeysLayout.table.count)
            for (row, ids) in zip(rows, SpecialKeysLayout.table) { XCTAssertEqual(row.count, ids.count) }
        }
        let rows = SpecialKeysLayout.rows(functionKeys: false)
        XCTAssertEqual(rows[2].map(\.id), ["k-escape", "k-tab", "k-left", "k-up", "k-down", "k-right"])
        XCTAssertEqual(rows[0].first?.id, "s-copy")
        XCTAssertEqual(rows[3].first?.id, "k-control")
    }

    /// All three show their symbols (Left click `cursorarrow.click` since build 33).
    func testBandButtonFaces() {
        let pad = TrackpadEngine(sink: Recorder())
        XCTAssertEqual(ClickButton(pad: pad, button: .left).face, .symbol("cursorarrow.click"))
        XCTAssertEqual(ClickButton(pad: pad, button: .right).face, .symbol("contextualmenu.and.cursorarrow"))
        XCTAssertEqual(ClickButton(pad: pad, button: .scroll).face, .symbol("arrow.up.and.down"))
    }

    /// The band's halves swap places, same sizes: trackpad at the band's left edge, keys (and buttons) at its right.
    func testTrackpadOnTheLeftSwapsTheHalves() {
        for inset: CGFloat in [0, 277, 293, 330] {
            let r = SessionLayout.Upright(size: safeUpright, keyboardInset: inset)
            let l = SessionLayout.Upright(size: safeUpright, keyboardInset: inset, side: .left)
            XCTAssertEqual(r.keys.size, l.keys.size)
            XCTAssertEqual(r.trackpad.size, l.trackpad.size)
            XCTAssertEqual(r.keyMetrics, l.keyMetrics)
            XCTAssertEqual(l.trackpad.minX, l.band.minX)
            XCTAssertEqual(l.keys.maxX, l.band.maxX)
            XCTAssertEqual(l.keys.minX - l.trackpad.maxX, SessionLayout.Upright.split)
            XCTAssertEqual(r.keys.minX, r.band.minX)
            XCTAssertEqual(r.trackpad.maxX, r.band.maxX)
        }
    }

    /// The setting: Right unless Left was stored; remembered in the defaults; an unknown value reads as Right.
    func testTrackpadSideIsStoredAndDefaultsToRight() throws {
        let suite = "duo-trackpad-side-test"
        let d = try XCTUnwrap(UserDefaults(suiteName: suite))
        d.removePersistentDomain(forName: suite)
        defer { d.removePersistentDomain(forName: suite) }
        XCTAssertEqual(TrackpadSide.stored(in: d), .right)
        TrackpadSide.left.store(in: d)
        XCTAssertEqual(d.string(forKey: "trackpadSide"), "left")
        XCTAssertEqual(TrackpadSide.stored(in: d), .left)
        TrackpadSide.right.store(in: d)
        XCTAssertEqual(TrackpadSide.stored(in: d), .right)
        d.set("middle", forKey: TrackpadSide.storageKey)
        XCTAssertEqual(TrackpadSide.stored(in: d), .right)
        XCTAssertEqual(TrackpadSide.allCases.map(\.title), ["Left", "Right"])
    }


    /// One thing on each key: the Mac's glyph where one exists, a short word only where none does.
    func testKeysShowOneGlyphOrOneShortWord() {
        let labels = Dictionary(uniqueKeysWithValues: SpecialKeysLayout.rows(functionKeys: false).joined()
            .compactMap { if case let .key(k) = $0 { (k.id, k.label) } else { nil } })
        // esc is the word, as on the horizontal row (the owner 2026-11-20), not the circular-arrow symbol.
        XCTAssertEqual(labels["escape"], "esc")
        XCTAssertEqual(KeyCap.face(MacKeyboardLayout.escape), .text("esc"))
        XCTAssertEqual(labels["tab"], "⇥")
        XCTAssertEqual(labels["forwarddelete"], "⌦")
        XCTAssertEqual(labels["command"], "⌘")
        let more = Dictionary(uniqueKeysWithValues: SpecialKeysLayout.rows(functionKeys: true).joined()
            .compactMap { if case let .key(k) = $0 { (k.id, k.label) } else { nil } })
        XCTAssertEqual([more["home"], more["end"], more["pageup"], more["pagedown"]], ["↖", "↘", "pg↑", "pg↓"])
        // Shortcuts: a symbol or a word, never both; the name is still there for VoiceOver.
        for sc in MacShortcut.all {
            switch ShortcutKey.face(sc) {
            case let .symbol(name): XCTAssertNotNil(UIImage(systemName: name), "\(sc.id): \(name)")
            case let .text(t): XCTAssertLessThanOrEqual(t.count, 4, sc.id)
            }
            XCTAssertFalse(sc.title.isEmpty)
        }
        XCTAssertEqual(ShortcutKey.face(.find), .text("Find"))
        XCTAssertEqual(ShortcutKey.face(.selectAll), .text("All"))
        XCTAssertEqual(ShortcutKey.face(.copy), .symbol("doc.on.doc"))
        XCTAssertEqual(KeyCap.accessibilityName(SpecialKeysLayout.home, more: true), "Home")
        for k in [MacKeyboardLayout.tab.relabeled("⇥"), SpecialKeysLayout.moreKey] {
            guard case let .symbol(name) = KeyCap.face(k) else { return XCTFail(k.id) }
            XCTAssertNotNil(UIImage(systemName: name), name)
        }
        // The "more" key's spoken hint (the info bubble's line) says what it swaps.
        let off = KeyInfo.description(.key(SpecialKeysLayout.moreKey), more: false)
        for word in ["F1", "F12", "home", "end", "page up", "page down"] { XCTAssertTrue(off.contains(word), off) }
        XCTAssertTrue(KeyInfo.description(.key(SpecialKeysLayout.moreKey), more: true).contains("shortcuts"))
    }

    /// The "more" key swaps the 12 shortcut cells for F1-F12 in the same places, and the four arrows for the
    /// Mac's fn+arrow keys (← home, ↑ page up, ↓ page down, → end); everything else stays.
    @MainActor
    func testFunctionBlockKeySwapsShortcutsForFKeys() {
        let state = KeyboardState(engine: MacKeyboardEngine(sink: Recorder()))
        XCTAssertFalse(state.functionKeys)
        let off = SpecialKeysLayout.rows(functionKeys: false).joined().map(\.id)
        let on = SpecialKeysLayout.rows(functionKeys: true).joined().map(\.id)
        XCTAssertEqual(off.count, on.count)
        let swaps = Dictionary(uniqueKeysWithValues: zip(off, on).filter { $0 != $1 })
        var wanted: [String: String] = [:]
        for (i, sc) in MacShortcut.all.enumerated() { wanted["s-" + sc.id] = "k-F\(i + 1)" }
        wanted["k-left"] = "k-home"
        wanted["k-up"] = "k-pageup"
        wanted["k-down"] = "k-pagedown"
        wanted["k-right"] = "k-end"
        XCTAssertEqual(swaps, wanted)
        XCTAssertEqual(SpecialKeysLayout.rows(functionKeys: true)[0].map(\.id), (1...6).map { "k-F\($0)" })
        XCTAssertEqual([SpecialKeysLayout.home.code, SpecialKeysLayout.end.code, SpecialKeysLayout.pageUp.code,
                        SpecialKeysLayout.pageDown.code], [115, 119, 116, 121])
    }

    func testKeyboardGuideInset() {
        let screen = CGRect(x: 0, y: 0, width: 669, height: 951)
        // Keyboard down: the guide's top is the bottom safe area.
        XCTAssertEqual(KeyboardGuideReader.inset(keyboardTop: 951 - 34, bounds: screen, bottomSafeArea: 34), 0)
        // A 325 pt keyboard (home area included) covers 291 pt above the safe area.
        XCTAssertEqual(KeyboardGuideReader.inset(keyboardTop: 951 - 325, bounds: screen, bottomSafeArea: 34), 291)
    }

    func testMainRowsAreAllOneWidthAndModifiersKeepANSIProportions() {
        for layer in [MacKeyboardLayout.letters, MacKeyboardLayout.symbols] {
            for row in layer {
                let units = row.filter { $0.id != "down" }.reduce(0) { $0 + $1.width }
                XCTAssertEqual(units, MacKeyboardLayout.mainUnits, accuracy: 0.001, row.map(\.label).joined())
            }
        }
        XCTAssertEqual(key("tab").width, 1.5)
        XCTAssertEqual(key("delete").width, 2)
        XCTAssertEqual(key("return").width, 2)
        XCTAssertEqual(key("shift").width, 1.5)
        XCTAssertEqual(key("command").width, 1.5)
        XCTAssertGreaterThan(key("space").width, 4)
    }

    func testEveryKeyThatWasThereIsStillThere() {
        let before = ["escape", "1", "0", "delete", "tab", "q", "p", "a", "'", "return", "shift", "z", "/",
                      "shift-right", "layer", "control", "option", "command", "space", "left", "up", "down",
                      "right"]
        for id in before { XCTAssertNotNil(MacKeyboardLayout.letters.joined().first { $0.id == id }, id) }
        let symbolsBefore = ["!", ")", "-", "=", "[", "]", "\\", "`", "_", "+", "{", "}", "|", "~", ":", "\"",
                             "<", ">", "?", "home", "end", "pageup", "pagedown", "F1", "F12", "forwarddelete"]
        for id in symbolsBefore { XCTAssertNotNil(MacKeyboardLayout.symbols.joined().first { $0.id == id }, id) }
    }
}

// MARK: - Shortcut keys

final class ShortcutTests: XCTestCase {
    func testCopySendsCommandC() {
        let r = Recorder()
        MacKeyboardEngine(sink: r).sendShortcut(.copy)
        XCTAssertEqual(r.events, [
            InputEvent(kind: InputKind.keyDown, x: 55, y: 0, a: cmd, b: 0),
            InputEvent(kind: InputKind.keyDown, x: 8, y: 0, a: cmd, b: 0),
            InputEvent(kind: InputKind.keyUp, x: 8, y: 0, a: cmd, b: 0),
            InputEvent(kind: InputKind.keyUp, x: 55, y: 0, a: 0, b: 0),
        ])
    }

    func testRedoIsShiftCommandZInKeyboardOrder() {
        let r = Recorder()
        MacKeyboardEngine(sink: r).sendShortcut(.redo)
        XCTAssertEqual(r.events.map(\.x), [56, 55, 6, 6, 55, 56])
        XCTAssertEqual(r.events[2].a, cmd | shift)
    }

    func testLatchedOptionJoinsAndIsUsedUp() {
        let r = Recorder()
        let k = MacKeyboardEngine(sink: r)
        k.tapModifier(.option)
        k.sendShortcut(.copy)
        XCTAssertEqual(r.events.map(\.x), [58, 55, 8, 8, 55, 58])
        XCTAssertEqual(k.latch(of: .option), .off)
    }

    @MainActor
    func testPasteSendsTheTextThenCommandV() {
        let r = Recorder()
        let state = KeyboardState(engine: MacKeyboardEngine(sink: r))
        var sent: [String] = []
        state.sendClipboard = { text in
            sent.append(text)
            XCTAssertTrue(r.events.isEmpty, "the clipboard goes before ⌘V")
        }
        state.pasteToMac("hello")
        XCTAssertEqual(sent, ["hello"])
        XCTAssertEqual(r.events.map(\.x), [55, 9, 9, 55])
    }

    func testShortcutSetAndOrder() {
        XCTAssertEqual(MacShortcut.all.map(\.id), ["copy", "paste", "cut", "undo", "redo", "selectall", "save",
                                                   "find", "switchapp", "spotlight", "close", "quit"])
        // Every shortcut is in the band once: six in row 1, six in row 2.
        let rows = Array(SpecialKeysLayout.rows(functionKeys: false).prefix(2))
        XCTAssertEqual(rows.joined().compactMap { if case let .shortcut(s) = $0 { s.id } else { nil } },
                       MacShortcut.all.map(\.id))
    }
}

// MARK: - Horizontal typing (system keyboard over the picture)

final class HorizontalTypingTests: XCTestCase {
    func testTypedCharactersAreTheUprightKeyboardsKeys() {
        let r = Recorder()
        let k = MacKeyboardEngine(sink: r)
        for c in "Hi!" { XCTAssertTrue(MacTyping.type(c, into: k)) }
        XCTAssertEqual(r.events, [
            InputEvent(kind: InputKind.keyDown, x: 4, y: 0, a: shift, b: 0),
            InputEvent(kind: InputKind.keyUp, x: 4, y: 0, a: shift, b: 0),
            InputEvent(kind: InputKind.keyDown, x: 34, y: 0, a: 0, b: 0),
            InputEvent(kind: InputKind.keyUp, x: 34, y: 0, a: 0, b: 0),
            InputEvent(kind: InputKind.keyDown, x: 18, y: 0, a: shift, b: 0),
            InputEvent(kind: InputKind.keyUp, x: 18, y: 0, a: shift, b: 0),
        ])
        XCTAssertFalse(MacTyping.type("é", into: k))
    }

    func testLatchedCommandPlusTypedCIsCommandC() {
        let r = Recorder()
        let k = MacKeyboardEngine(sink: r)
        k.tapModifier(.command)
        MacTyping.type("c", into: k)
        XCTAssertEqual(r.events.map(\.x), [55, 8, 8, 55])
    }

    /// The upright system keyboard: a typed "c" with command held from the special keys is ⌘C, through the hidden
    /// input the session uses; the next key is plain again (the modifier is let go after one key).
    @MainActor
    func testSystemKeyboardTypingWithHeldCommandThenReleases() {
        let r = Recorder()
        let k = MacKeyboardEngine(sink: r)
        let input = MacTypingView(frame: .zero)
        input.engine = k
        input.showsMacKeysBar = false
        input.state = KeyboardState(engine: k)
        // No Mac keys row upright: the accessory is only the empty click view (build 36, `KeyFeedback`).
        XCTAssertEqual(input.inputAccessoryView?.bounds.height, 0)
        k.tapModifier(.command)
        input.insertText("c")
        XCTAssertEqual(r.events, [
            InputEvent(kind: InputKind.keyDown, x: 55, y: 0, a: cmd, b: 0),
            InputEvent(kind: InputKind.keyDown, x: 8, y: 0, a: cmd, b: 0),
            InputEvent(kind: InputKind.keyUp, x: 8, y: 0, a: cmd, b: 0),
            InputEvent(kind: InputKind.keyUp, x: 55, y: 0, a: 0, b: 0),
        ])
        XCTAssertEqual(k.latch(of: .command), .off)
        r.events.removeAll()
        input.insertText("v")
        input.deleteBackward()
        input.insertText("\n")
        XCTAssertEqual(r.events, [
            InputEvent(kind: InputKind.keyDown, x: 9, y: 0, a: 0, b: 0),
            InputEvent(kind: InputKind.keyUp, x: 9, y: 0, a: 0, b: 0),
            InputEvent(kind: InputKind.keyDown, x: 51, y: 0, a: 0, b: 0),
            InputEvent(kind: InputKind.keyUp, x: 51, y: 0, a: 0, b: 0),
            InputEvent(kind: InputKind.keyDown, x: 36, y: 0, a: 0, b: 0),
            InputEvent(kind: InputKind.keyUp, x: 36, y: 0, a: 0, b: 0),
        ])
        // What is typed is what is sent: no autocorrect, capitals, prediction or smart punctuation.
        XCTAssertEqual(input.autocorrectionType, .no)
        XCTAssertEqual(input.autocapitalizationType, .none)
        XCTAssertEqual(input.inlinePredictionType, .no)
        XCTAssertEqual(input.smartQuotesType, .no)
        XCTAssertEqual(input.smartDashesType, .no)
        // Horizontal keeps its Mac keys row.
        input.showsMacKeysBar = true
        XCTAssertNotNil(input.inputAccessoryView)
    }

    /// Keyboard up and down: the picture's frame does not change, so the touch mapping does not either. The
    /// probe uses the session screen's own arrangement (a GeometryReader that ignores the keyboard's safe area,
    /// the picture filling it) and raises the real system keyboard through `MacTypingField`.
    @MainActor
    func testKeyboardUpAndDownLeavesThePictureAndMappingAlone() async throws {
        let up = BindingBox()
        let frames = FrameLog()
        let state = KeyboardState(engine: MacKeyboardEngine(sink: Recorder()))
        let probe = KeyboardProbe(box: up, frames: frames, state: state)
        let host = UIHostingController(rootView: probe)
        // A window on the app's own scene: a window without a scene never gets a software keyboard.
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 951, height: 669)
        window.rootViewController = host
        window.makeKeyAndVisible()
        var keyboardShown = false
        let token = NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidShowNotification,
                                                           object: nil, queue: .main) { _ in keyboardShown = true }
        defer { NotificationCenter.default.removeObserver(token) }
        try await Task.sleep(for: .milliseconds(500))
        let before = try XCTUnwrap(frames.last)
        up.up = true
        try await Task.sleep(for: .seconds(1.5))
        let during = try XCTUnwrap(frames.last)
        up.up = false
        try await Task.sleep(for: .seconds(1))
        let after = try XCTUnwrap(frames.last)
        XCTAssertEqual(before, during)
        XCTAssertEqual(before, after)
        let fit = PictureFit.frame(canvasWidth: 1920, canvasHeight: 1080, in: before.size, screenScale: 3)
        let fitDuring = PictureFit.frame(canvasWidth: 1920, canvasHeight: 1080, in: during.size, screenScale: 3)
        for p in [CGPoint(x: 10, y: 100), CGPoint(x: 475, y: 334), CGPoint(x: 900, y: 600)] {
            let a = DirectTouchEngine.canvasPoint(p, picture: fit, canvasWidth: 1920, canvasHeight: 1080)
            let b = DirectTouchEngine.canvasPoint(p, picture: fitDuring, canvasWidth: 1920, canvasHeight: 1080)
            XCTAssertEqual(a.map { [$0.0, $0.1] }, b.map { [$0.0, $0.1] })
        }
        // Says whether a software keyboard really appeared (a simulator with a hardware keyboard shows none).
        print("DUO-TEST keyboard shown during probe: \(keyboardShown)")
        window.isHidden = true
    }
}

// MARK: - The top row (the owner 2026-11-20: "Should mimic Claud app. Mac below")

final class TopRowTests: XCTestCase {
    /// On the app's own scene, upright, the session's real top row (`SessionTopRow` in a NavigationStack) over a
    /// stand-in picture laid out by `SessionLayout.Upright`: the picture's top edge is the top row's bottom, and the
    /// top row is no taller than the status cluster's own row plus standard padding (16 pt).
    @MainActor
    func testPictureStartsAtTheBottomOfTheTopRowAndTheRowIsTheClocksRow() async throws {
        let frames = FrameLog()
        let host = UIHostingController(rootView: TopRowProbe(frames: frames))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        // The clock's row exists only with the scene upright: the system draws it, so no window size can stand in
        // for it, and the scene cannot be turned from code on the Duo (UISceneErrorDomain 101).
        if scene.effectiveGeometry.interfaceOrientation.isLandscape {
            throw XCTSkip("needs the simulator upright: the clock's row exists only upright, and the scene cannot "
                          + "be turned from code. Turn the simulator upright to run it.")
        }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 669, height: 951)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .seconds(1))
        let picture = try XCTUnwrap(frames.last)
        let nav = try XCTUnwrap(Self.find(UINavigationBar.self, in: host.view))
        let bar = nav.convert(nav.bounds, to: nil)
        // On the open Duo the status bar frame is not the clock's row (it reads 2 pt tall); the window's top safe
        // inset is where the system lets the app's top row begin.
        let top = window.safeAreaInsets.top
        let status = scene.statusBarManager?.statusBarFrame ?? .zero
        let buttons = Self.all(UIControl.self, in: nav).map { $0.convert($0.bounds, to: nil) }
        print("DUO-TEST top row: bar \(bar), window top inset \(top), status \(status), picture \(picture), "
              + "controls \(buttons)")
        XCTAssertGreaterThan(bar.height, 0)
        XCTAssertEqual(picture.minY, bar.maxY, accuracy: 0.5, "picture top \(picture.minY), top row bottom \(bar.maxY)")
        XCTAssertEqual(picture.minX, 0)
        XCTAssertEqual(picture.width, 669)
        // The status area alone: a plain view, no bar, in the same window size. Its top safe inset is the strip
        // the clock and status icons need (the old layout put its bar below this strip).
        let plain = UIHostingController(rootView: Color.clear)
        let plainWindow = UIWindow(windowScene: scene)
        plainWindow.frame = window.frame
        plainWindow.rootViewController = plain
        plainWindow.isHidden = false
        defer { plainWindow.isHidden = true }
        try await Task.sleep(for: .milliseconds(300))
        let statusArea = plain.view.safeAreaInsets.top
        print("DUO-TEST status area alone: \(statusArea)")
        XCTAssertGreaterThan(statusArea, 0)
        // One row: the bar starts inside the status area (beside the clock, not under it) and ends with it, so
        // the top row is no taller than the status area itself (seen: both 82 pt; the bar runs 24-82).
        XCTAssertLessThan(bar.minY, statusArea, "top row \(bar) starts below the status area \(statusArea)")
        XCTAssertLessThanOrEqual(bar.maxY, statusArea + 0.5, "top row \(bar), status area \(statusArea)")
    }

    /// Horizontal, 951 x 669 on the app's own scene: the 16:9 picture is fitted to the FULL screen, safe areas
    /// ignored: 951 wide from x 0, centred vertically (black bars only above and below). Before the fix it stopped
    /// about 85 pt short of the right edge and sat about 74 pt low.
    @MainActor
    func testHorizontalPictureFillsTheWholeScreenWidthCentred() async throws {
        let frames = FrameLog()
        let host = UIHostingController(rootView: HorizontalProbe(frames: frames))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 951, height: 669)
        let upright = !scene.effectiveGeometry.interfaceOrientation.isLandscape
        if upright {
            // The scene is upright and cannot be turned from code on the Duo (UISceneErrorDomain 101), so the window
            // stays 669 x 951 whatever frame it is given. Lay the session out in explicit 951 x 669 bounds at the
            // window's origin instead; the picture ignores safe areas, so the upright insets do not move it.
            let root = UIViewController()
            window.rootViewController = root
            root.addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = true
            host.view.autoresizingMask = []
            host.view.frame = CGRect(x: 0, y: 0, width: 951, height: 669)
            root.view.addSubview(host.view)
            host.didMove(toParent: root)
        } else {
            window.rootViewController = host
        }
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        try await Task.sleep(for: .seconds(1))
        let picture = try XCTUnwrap(frames.last)
        print("DUO-TEST horizontal picture \(picture), scene \(upright ? "upright, explicit bounds" : "horizontal"), "
              + "host view \(host.view.frame), window safe area \(window.safeAreaInsets)")
        XCTAssertEqual(picture.minX, 0, accuracy: 0.01)
        XCTAssertEqual(picture.width, 951, accuracy: 0.01)
        let h = 951.0 * 1080 / 1920
        XCTAssertEqual(picture.height, h, accuracy: 0.01)
        XCTAssertEqual(picture.minY, (669 - h) / 2, accuracy: 0.5, "centred vertically")
        XCTAssertEqual(669 - picture.maxY, picture.minY, accuracy: 0.7, "equal bars above and below")
    }

    /// The owner 2026-11-21: "We should flip the order of the computer name and its screens and the four views" and the
    /// info button "doesn't need to be on every screen"; after build 46 brought it back and a long name truncated:
    /// "No, no truncation. Cut it again". Upright, 669 wide, on the app's scene, with long names, two and four views:
    /// the order is back, the name bubble, the view switch; no control right of the switch (no info, no More); all
    /// 48 pt tall on one line; nothing overlaps; the switch ends left of the clock's area.
    /// RULE: with "My Mac mini" / "Studio Display (2)" and four views, neither line of the bubble truncates
    /// (the bubble in the row is at least as wide as the same bubble with no cap at all).
    @MainActor
    func testRowOrderBackNameSwitchNoInfoAndNothingOverlaps() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        if scene.effectiveGeometry.interfaceOrientation.isLandscape {
            throw XCTSkip("needs the simulator upright (the scene cannot be turned from code)")
        }
        let cases: [(String, String?)] = [("Test host", nil), ("My Mac mini", "Studio Display (2)"),
                                           ("My Mac mini", "All Screens"),
                                           ("a-very-long-mac-name-that-cannot-fit", "Another Very Long Screen Name")]
        let switches: [[SessionView]] = [SessionView.choices(terminal: false),
                                         SessionView.choices(terminal: true, jetkvm: true)]
        for choices in switches {
            for (mac, screen) in cases {
                let parts = TopRowParts()
                let host = UIHostingController(rootView: TopRowProbe(frames: FrameLog(), preview: (mac, screen),
                                                                     parts: parts, choices: choices))
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: 669, height: 951)
                window.rootViewController = host
                window.makeKeyAndVisible()
                try await Task.sleep(for: .seconds(1))
                let name = try XCTUnwrap(parts.frames["name"]), sel = try XCTUnwrap(parts.frames["selector"])
                let nav = try XCTUnwrap(Self.find(UINavigationBar.self, in: host.view))
                let controls = Self.all(UIControl.self, in: nav).map { $0.convert($0.bounds, to: nil) }
                    .filter { $0.width >= 40 }
                let back = try XCTUnwrap(controls.min { $0.minX < $1.minX })
                let labels = Self.all(UIView.self, in: nav).compactMap(\.accessibilityLabel)
                let selW = ViewSelector.target * CGFloat(choices.count)
                print("DUO-TEST top row \(choices.count) views '\(mac)' / '\(screen ?? "-")': back \(back), "
                      + "name \(name), selector \(sel), controls \(controls), labels \(labels)")
                XCTAssertEqual(sel.width, selW, accuracy: 0.5, "selector width")
                XCTAssertEqual(sel.height, TopRow.height, accuracy: 0.5, "selector height")
                XCTAssertEqual(name.height, TopRow.height, accuracy: 0.5, "name height")
                XCTAssertEqual(name.midY, sel.midY, accuracy: 0.5, "name and selector on one line")
                XCTAssertFalse(labels.contains("More"), "the More menu is gone")
                XCTAssertFalse(labels.contains("Key Info"), "the info button is gone")
                XCTAssertGreaterThanOrEqual(name.minX, back.maxX + 4, "name right of back")
                XCTAssertLessThanOrEqual(name.maxX + 4, sel.minX, "switch right of the name")
                XCTAssertLessThanOrEqual(name.width, SessionTopRow.nameMaxWidth(rowWidth: 669, selectorWidth: selW) + 4)
                XCTAssertLessThanOrEqual(sel.maxX, 669 - SessionTopRow.leadingEndFromRight + 0.5, "inside the kept area")
                XCTAssertTrue(controls.filter { $0.minX > sel.maxX }.isEmpty, "nothing right of the switch")
                if mac == "My Mac mini", screen == "Studio Display (2)" {
                    let free = UIHostingController(rootView: TopRowName(mac: mac, screen: screen, notice: nil,
                                                                       interactive: true))
                    let natural = free.sizeThatFits(in: CGSize(width: 2000, height: 200))
                    print("DUO-TEST no truncation \(choices.count) views: bubble \(name.width), uncapped \(natural.width)")
                    XCTAssertGreaterThanOrEqual(name.width, natural.width - 0.5,
                                                "\(choices.count) views: neither line of the bubble truncates")
                }
                window.isHidden = true
            }
        }
    }

    /// No bubble in a bubble (the owner 2026-11-21 and 2026-11-22, twice: "The double bubble is back."): the session's
    /// real top bar, both layouts (the Duo's switch, the normal iPhone's view button with one view and with several),
    /// one-line and two-line names, short and long. The bar draws one glass platter per part (`barGlass`); a part
    /// that draws its own `glassEffect` adds a second glass layer inside it (`ownGlass`). Build 55 had exactly that at
    /// the one-line name pill and the view switch, so this test fails on build 55 and passes on 56. It also checks
    /// that back, the name and the views stay on the row (not folded into the bar's "•••").
    @MainActor
    func testTopBarHasNoGlassInsideGlass() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        if scene.effectiveGeometry.interfaceOrientation.isLandscape {
            throw XCTSkip("needs the simulator upright (the scene cannot be turned from code)")
        }
        let names: [(String, String?)] = [("Test host", nil), ("Studio Mac mini", nil),
                                           ("a-very-long-mac-name-that-cannot-fit", nil),
                                           ("My Mac mini", "Studio Display (2)"),
                                           ("a-very-long-mac-name-that-cannot-fit", "Another Very Long Screen Name")]
        let rows: [(String, [SessionView], Bool, CGFloat)] = [
            ("duo 2", SessionView.choices(terminal: false), false, 669),
            ("duo 4", SessionView.choices(terminal: true, jetkvm: true), false, 669),
            ("phone 1", [.centred], true, 402),
            // The menu with several choices, in every build (the plain build offers the phone only Follow Pointer).
            ("phone menu", [.regular, .centred], true, 402),
            ("phone all", SessionView.normalPhoneChoices(terminal: true, jetkvm: true), true, 402),
        ]
        for (label, choices, menu, width) in rows {
            for (mac, screen) in names {
                let host = UIHostingController(rootView: TopRowProbe(frames: FrameLog(), preview: (mac, screen),
                                                                     choices: choices, viewMenu: menu,
                                                                     rowWidth: width))
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(x: 0, y: 0, width: width, height: 900)
                window.rootViewController = host
                window.makeKeyAndVisible()
                try await Task.sleep(for: .seconds(1))
                let nav = try XCTUnwrap(Self.find(UINavigationBar.self, in: host.view))
                let own = Self.ownGlass(in: nav), bar = Self.barGlass(in: nav)
                print("DUO-TEST glass \(label) '\(mac)' / '\(screen ?? "-")': bar \(bar), own \(own)")
                XCTAssertGreaterThanOrEqual(bar.count, 3, "\(label): back, name and views each on the bar's glass")
                XCTAssertEqual(own, [], "\(label) '\(mac)' / '\(screen ?? "-")': a top-bar part draws its own glass "
                               + "on the bar's (a bubble in a bubble)")
                window.isHidden = true
            }
        }
    }

    /// Project notes 7 (the owner: "I added a key. The next time I launched Robin, the top menu bar was gone": a
    /// computer that started JetKVM-only, then got Screen Sharing and Terminal, showed only "•••"). For every mix of
    /// ways in, on the Duo folded (the session layout on the outer screen, 466 pt), the Duo open (669 pt), a regular
    /// iPhone (402 pt) and the widths of those held sideways (when the bar shows): back and the name are always on
    /// the row, each on the bar's glass and inside the window, and the views are there too, as the switch when it
    /// fits and otherwise as one view button. Before the fix, four views at 466 pt dropped back off the row.
    @MainActor
    func testTopBarKeepsBackAndNameForEveryMixOfWaysIn() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        if scene.effectiveGeometry.interfaceOrientation.isLandscape {
            throw XCTSkip("needs the simulator upright (the scene cannot be turned from code)")
        }
        // Screen Sharing alone; with Terminal; with JetKVM; with both (Robin's Mac).
        let mixes: [(String, Bool, Bool)] = [("SS", false, false), ("SS+T", true, false), ("SS+J", false, true),
                                             ("SS+T+J", true, true)]
        // (label, width, normal iPhone): upright, then held sideways.
        // "duo layout narrow": the Duo's session bar (the switch, not the phone's menu) at a regular iPhone's width,
        // so the switch-or-menu rule is exercised on the simulator that can lay it out.
        let screens: [(String, CGFloat, Bool)] = [("duo layout narrow", 402, false), ("duo folded", 466, false), ("duo open", 669, false),
                                                  ("iphone", 402, true), ("duo folded sideways", 900, false),
                                                  ("duo open sideways", 960, false), ("iphone sideways", 874, true)]
        let names: [(String, String?)] = [("Robin’s Mac", nil), ("a-very-long-mac-name-that-cannot-fit", "Studio Display (2)")]
        // The bar lays out at the simulator screen's width, whatever the test window's (why the older top-row tests
        // fail on the folded Duo): each width runs where the screen is at least that wide, and says when it is skipped.
        let screenWidth = scene.screen.bounds.width
        // The folded Duo's outer screen keeps the clock in a column on the right and lays a bar out in its own way; a
        // session there uses the outer-screen layout, with no top bar, so nothing real is measured on it.
        if !PhoneKind.current, screenWidth < 600 {
            throw XCTSkip("the folded Duo's outer screen shows no session top bar; run on a regular iPhone or the open Duo")
        }
        var ran = 0
        for (mix, terminal, jetkvm) in mixes {
            for (label, width, phone) in screens {
                guard width <= screenWidth + 1, width >= screenWidth - 70 else {
                    print("DUO-TEST mix \(mix) \(label): skipped here (screen \(screenWidth) pt)")
                    continue
                }
                ran += 1
                let choices = phone ? SessionView.normalPhoneChoices(terminal: terminal, jetkvm: jetkvm)
                                    : SessionView.choices(terminal: terminal, jetkvm: jetkvm)
                for (mac, screen) in names {
                    let parts = TopRowParts()
                    let host = UIHostingController(rootView: TopRowProbe(frames: FrameLog(), preview: (mac, screen),
                                                                         parts: parts, choices: choices,
                                                                         viewMenu: phone, rowWidth: width))
                    let window = UIWindow(windowScene: scene)
                    window.frame = CGRect(x: 0, y: 0, width: width, height: 900)
                    window.rootViewController = host
                    window.makeKeyAndVisible()
                    try await Task.sleep(for: .seconds(1))
                    let what = "\(mix) \(label) '\(mac)'"
                    let nav = try XCTUnwrap(Self.find(UINavigationBar.self, in: host.view))
                    let bar = Self.barGlass(in: nav).filter { $0.minY < 140 }
                    print("DUO-TEST mix \(what): bar \(bar) parts \(parts.frames)")
                    // Folded into "•••", the bar shows ONE platter; back, the name and the views are three.
                    XCTAssertGreaterThanOrEqual(bar.count, 3, "\(what): back, name and views each on the bar's glass (not folded into •••)")
                    for f in bar { XCTAssertTrue(f.minX >= 0 && f.maxX <= width + 0.5, "\(what): a part is off the row: \(f)") }
                    let sorted = bar.sorted { $0.minX < $1.minX }
                    if sorted.count >= 3 {
                        // Back is the first, round part; the name the second, and wide enough to read.
                        XCTAssertLessThan(sorted[0].width, 60, "\(what): back is first")
                        XCTAssertGreaterThanOrEqual(sorted[1].width, 70, "\(what): the name is readable")
                    }
                    window.isHidden = true
                }
            }
        }
        XCTAssertGreaterThan(ran, 0, "no width matched this simulator")
        XCTAssertFalse(SessionTopRow.switchFits(rowWidth: 466, count: 4), "four views do not fit folded")
        XCTAssertTrue(SessionTopRow.switchFits(rowWidth: 669, count: 4), "four views fit open")
    }

    /// Glass a bar item draws itself, in window points: SwiftUI's `glassEffect` renders through a view whose
    /// layer is an `SDFLayer` (seen in build 55 exactly at the name pill and the view switch; the bar's own items have
    /// none). The bar's own item glass is a platter view (`barGlass`), not this.
    /// The bar's own full-width background uses the same kind of layer and is left out.
    @MainActor static func ownGlass(in view: UIView) -> [CGRect] {
        all(UIView.self, in: view)
            .filter { !$0.isHidden && $0.alpha > 0.01 && String(describing: type(of: $0.layer)).contains("SDFLayer") }
            .map { $0.convert($0.bounds, to: nil).integral }
            .filter { $0.width < view.bounds.width - 1 }
    }

    /// The bar's own glass shapes behind its items (its "platter" views), in window points.
    @MainActor static func barGlass(in view: UIView) -> [CGRect] {
        all(UIView.self, in: view)
            .filter { !$0.isHidden && $0.bounds.width > 4 && String(describing: type(of: $0)).contains("NavigationBarPlatter") }
            .map { $0.convert($0.bounds, to: nil).integral }
            .filter { $0.width < view.bounds.width - 1 }   // the bar's own full-width background
    }

    /// The full build's four-choice switch: the bubble's widest size still ends the switch where the bar
    /// keeps the leading parts (measured; build 56: about x 500), and the test names fit under it.
    func testFourChoiceRowFitsBesideTheClock() {
        let w = SessionTopRow.nameMaxWidth(rowWidth: 669, selectorWidth: 4 * ViewSelector.target)
        XCTAssertEqual(w, 192)
        XCTAssertLessThanOrEqual(SessionTopRow.beforeSwitch + w + 4 * ViewSelector.target,
                                 669 - SessionTopRow.leadingEndFromRight)
        XCTAssertEqual(SessionTopRow.nameMaxWidth(rowWidth: 669, selectorWidth: 2 * ViewSelector.target), 288)
    }

    /// The bubble's two lines (the owner 2026-11-21, the Claude app's two-line title): one screen, the Mac's name alone
    /// (no empty second line); several screens, the screen under it; All Screens says so; a problem on the Mac
    /// takes line 2.
    func testNameBubbleLines() {
        XCTAssertNil(TopRowName(mac: "My Mac mini", screen: nil, notice: nil).secondLine)
        XCTAssertEqual(TopRowName(mac: "My Mac mini", screen: "Studio Display (2)", notice: nil).secondLine,
                       "Studio Display (2)")
        XCTAssertEqual(TopRowName(mac: "M", screen: "All Screens", notice: nil).secondLine, "All Screens")
        XCTAssertEqual(TopRowName(mac: "M", screen: "S", notice: "This Mac switched to another user.").secondLine,
                       "This Mac switched to another user.")
    }

    @MainActor static func all<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }

    @MainActor static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let v = view as? T, !v.isHidden { return v }
        for sub in view.subviews { if let v = find(type, in: sub) { return v } }
        return nil
    }
}

/// The horizontal session's picture, through the session's own geometry (`SessionGeometry`) with the bar hidden
/// as the session hides it: a 16:9 picture fitted by `PictureFit` in the canvas's bounds.
private struct HorizontalProbe: View {
    let frames: FrameLog

    var body: some View {
        NavigationStack {
            SessionGeometry { proxy, wide in
                let f = PictureFit.frame(canvasWidth: 1920, canvasHeight: 1080, in: proxy.size, screenScale: 3)
                ZStack(alignment: .topLeading) {
                    Color.black
                    Color.gray.frame(width: f.width, height: f.height)
                        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frames.frames.append($0) }
                        .padding(.leading, f.minX)
                        .padding(.top, f.minY)
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .ignoresSafeArea(edges: wide ? .all : [])
                .statusBarHidden(wide)
                .persistentSystemOverlays(wide ? .hidden : .automatic)
                .modifier(SessionTopRow(model: SessionModel(), title: "Test host", notice: nil, hidden: wide,
                                        view: .constant(.regular), leave: {}))
            }
        }
    }
}

private struct TopRowProbe: View {
    let frames: FrameLog
    var preview: (mac: String, screen: String?)? = nil
    var parts: TopRowParts? = nil
    var choices: [SessionView]? = nil
    /// The normal iPhone's top row (`ViewMenuButton`, its own name cap) instead of the Duo's.
    var viewMenu = false
    var rowWidth: CGFloat = 669

    var body: some View {
        NavigationStack {
            SessionGeometry { proxy, _ in
                let u = SessionLayout.Upright(size: proxy.size, keyboardInset: 0)
                Color.black
                    .frame(width: u.picture.width, height: u.picture.height)
                    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frames.frames.append($0) }
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                    .modifier(SessionTopRow(model: SessionModel(), title: "Test host", notice: nil, hidden: false,
                                            view: .constant(.regular), leave: {}, preview: preview,
                                            report: { name, f in parts?.frames[name] = f },
                                            rowWidth: rowWidth, choicesForTest: choices,
                                            nameMaxOverride: viewMenu ? NormalPhoneTopRow.nameMax(rowWidth: rowWidth) : nil,
                                            viewMenu: viewMenu))
            }
        }
    }
}

@MainActor private final class TopRowParts { var frames: [String: CGRect] = [:] }

@MainActor @Observable private final class BindingBox { var up = false }
@MainActor private final class FrameLog { var frames: [CGRect] = []; var last: CGRect? { frames.last } }

private struct KeyboardProbe: View {
    @Bindable var box: BindingBox
    let frames: FrameLog
    let state: KeyboardState

    var body: some View {
        GeometryReader { proxy in
            Color.black
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { frames.frames.append($0) }
                .background { MacTypingField(up: $box.up, state: state).frame(width: 1, height: 1) }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .ignoresSafeArea(edges: .all)
        }
        .ignoresSafeArea(.keyboard)
    }
}

// MARK: - Shared clipboard (Glass Act's sync through DuoPasteboard)

final class ClipboardTests: XCTestCase {
    @MainActor
    func testMacToPhoneWritesAndPhoneToMacOnlyWhenAllowed() {
        let pb = UIPasteboard.withUniqueName()
        defer { UIPasteboard.remove(withName: pb.name) }
        var allowed = false
        let duo = DuoPasteboard(pasteboard: pb, autoSendAllowed: { allowed })
        // Mac → phone.
        let count = duo.changeCount
        duo.setText("from the Mac")
        XCTAssertEqual(pb.string, "from the Mac")
        XCTAssertNotEqual(duo.changeCount, count)
        // Phone → Mac: nothing read while the switch is off.
        pb.string = "from the phone"
        XCTAssertNil(duo.shareableText())
        allowed = true
        XCTAssertEqual(duo.shareableText(), "from the phone")
        // A password manager's concealed item stays on the phone.
        pb.setItems([["public.utf8-plain-text": "secret", "org.nspasteboard.ConcealedType": ""]])
        XCTAssertNil(duo.shareableText())
    }
}

// MARK: - Key info bubble

/// The owner 2026-11-20: "For the duo extra keys, add an info bubble control explaining what each key does".
final class KeyInfoTests: XCTestCase {
    private func nonGap(_ rows: [[MacKeyboardLayout.Cell]]) -> [MacKeyboardLayout.Cell] {
        rows.joined().filter { if case .gap = $0 { false } else { true } }
    }

    /// Every key, in both states, and the horizontal row, has a name and one plain line.
    func testEveryKeyInEveryStateHasANameAndADescription() {
        for more in [false, true] {
            for cell in nonGap(SpecialKeysLayout.rows(functionKeys: more)) {
                XCTAssertFalse(KeyInfo.name(cell).isEmpty, cell.id)
                let d = KeyInfo.description(cell, more: more)
                XCTAssertFalse(d.isEmpty, cell.id)
                XCTAssertFalse(d.contains("\n"), cell.id)
                XCTAssertFalse(d.contains("?"), "\(cell.id): \(d)")
            }
        }
        for key in MacKeysBar.keys {
            XCTAssertFalse(KeyInfo.name(.key(key)).isEmpty, key.id)
            XCTAssertFalse(KeyInfo.description(.key(key)).isEmpty, key.id)
        }
        XCTAssertEqual(KeyInfo.description(.shortcut(.copy)), "copies the selection (Command-C)")
        XCTAssertEqual(KeyInfo.description(.shortcut(.redo)), "redoes what you undid (Shift-Command-Z)")
        XCTAssertEqual(KeyInfo.description(.shortcut(.spotlight)), "opens Spotlight search (Command-Space)")
        XCTAssertEqual(KeyInfo.description(.shortcut(.switchApp)), "keeps the app switcher open: pick with the arrows or a tap, then Apps or Return; esc cancels (Command-Tab)")
        XCTAssertEqual(KeyInfo.description(.key(SpecialKeysLayout.forwardDelete)),
                       "deletes the character to the right")
        XCTAssertEqual(KeyInfo.name(.key(MacKeyboardLayout.optionKey)), "Option")
        XCTAssertEqual(KeyInfo.name(.key(SpecialKeysLayout.moreKey)), "More")
    }

    /// The reference lists the keys in the order they are on screen, from the same rows that draw them; the "more"
    /// keys under their own heading.
    func testListOrderIsTheOnScreenOrder() {
        let sections = KeyInfo.uprightSections()
        XCTAssertEqual(sections.map(\.title), ["Keys", "After More"])
        let shown = nonGap(SpecialKeysLayout.rows(functionKeys: false)).map(\.id)
        XCTAssertEqual(sections[0].entries.map(\.id), shown)
        XCTAssertEqual(shown.count, 24)
        let more = nonGap(SpecialKeysLayout.rows(functionKeys: true)).map(\.id)
        XCTAssertEqual(sections[1].entries.map(\.id), more.filter { !shown.contains($0) })
        XCTAssertEqual(sections[1].entries.count, 16)
        XCTAssertEqual(sections[0].entries.prefix(3).map(\.id), ["s-copy", "s-paste", "s-cut"])
        XCTAssertEqual(KeyInfo.horizontalSections[0].entries.map(\.id), MacKeysBar.keys.map { "k-" + $0.id })
    }


    /// The owner 2026-11-20: "Dump the info button. We can put it in the Mac selection screen." The session screen has
    /// no info control in either layout: the horizontal row is its 9 keys alone.
    func testNoInfoControlInTheSession() {
        XCTAssertEqual(MacKeysBar.keys.count, 9)
        XCTAssertEqual(Set(SpecialKeysLayout.rows(functionKeys: false).joined().map(\.id)).count, 24)
    }

    // The owner 2026-11-20: "'i' with a circle" / "dramatically more condensed".

    /// Every key, including those behind "more", and the two click buttons are on a line of the reference.
    func testPopUpLinesCoverEveryKeyAndBothClicks() {
        let sections = KeyInfo.uprightSections()
        let lines = KeyInfo.lines(sections, clicks: true)
        XCTAssertEqual(Set(lines.flatMap(\.ids)),
                       Set(sections.flatMap(\.entries).map(\.id) + ["click-left", "click-right", "click-scroll"]))
        XCTAssertEqual(lines.prefix(3).map(\.id), ["click-left", "click-right", "click-scroll"])
        XCTAssertEqual(lines.count, 29, "3 buttons, 20 keys, the 4 arrows on one line, 4 navigation keys, F1-F12")
        XCTAssertEqual(KeyInfo.moreStart(sections, clicks: true), 24)
        for line in lines { XCTAssertFalse(line.text.isEmpty, line.id) }
        for line in KeyInfo.clickLines {
            guard case let .symbol(name) = line.face else { return XCTFail(line.id) }
            XCTAssertNotNil(UIImage(systemName: name), name)
        }
        XCTAssertEqual(KeyInfo.short(.shortcut(.copy)), "Copy (⌘C)")
        XCTAssertEqual(KeyInfo.short(.shortcut(.redo)), "Redo (⇧⌘Z)")
        XCTAssertEqual(KeyInfo.short(.shortcut(.switchApp)), "app switcher: stays open (⌘Tab)")
        XCTAssertEqual(KeyInfo.short(.key(MacKeyboardLayout.commandKey)), "Command")
        XCTAssertEqual(KeyInfo.description(.shortcut(.copy)), "copies the selection (Command-C)")
    }

    /// The reference is a sheet (HIG Sheets) in three sections: the two click buttons, the keys, the keys behind
    /// "more". Together they cover every line, in order (the clipped popover, 2026-11-20).
    func testKeySheetSectionsCoverEveryLine() {
        let groups = KeyInfoSheet.groups()
        // project notes: one plain line about Unlock Automatically, last.
        XCTAssertEqual(groups.map(\.title), ["Buttons", "Keys", "After More (⋯)", "Locked Mac"])
        let sections = KeyInfo.uprightSections()
        XCTAssertEqual(groups.dropLast().flatMap(\.lines).map(\.id), KeyInfo.lines(sections, clicks: true).map(\.id))
        XCTAssertEqual(groups[3].lines.map(\.id), ["auto-unlock"])
        XCTAssertEqual(groups[2].lines.last?.id, "k-end")
    }

    /// Two columns (the owner 2026-11-21): every item in order, left column then right, about even, never a title at the
    /// bottom of the left column; one column keeps them all.
    func testKeySheetTwoColumnsKeepEveryItemInOrder() {
        let one = KeyInfoSheet.columns(1), two = KeyInfoSheet.columns(2)
        XCTAssertEqual(one.count, 1)
        XCTAssertEqual(two.count, 2)
        XCTAssertEqual(two.flatMap { $0 }.map(\.id), one[0].map(\.id))
        XCTAssertLessThanOrEqual(abs(two[0].count - two[1].count), 2)
        if case .title = two[0].last! { XCTFail("a title ends the left column") }
    }

}

// MARK: - Modifiers: one rule, combos, the held look (the owner 2026-11-20)

final class ModifierRuleTests: XCTestCase {
    private let all: [KeyMap.Modifier] = [.control, .option, .command, .shift]

    private func flags(_ m: KeyMap.Modifier) -> Int {
        var f: UInt32 = 0
        for one in KeyMap.Modifier.order where m.contains(one) { f |= one.eventFlags }
        return Int(Int32(bitPattern: f))
    }

    private func combos() -> [[KeyMap.Modifier]] {
        var out: [[KeyMap.Modifier]] = []
        for i in 0..<all.count { for j in (i + 1)..<all.count { out.append([all[i], all[j]]) } }
        out.append(all)
        return out
    }

    /// Each pair of modifiers, and all four, held by taps in any order, then a key: the modifier keys go down in
    /// keyboard order, the key carries every flag, then everything lets go and nothing stays held.
    func testEveryPairAndAllFourPlusAKeySendTheFlagsThenRelease() {
        for combo in combos() {
            for tapOrder in [combo, combo.reversed()] {
                let r = Recorder()
                let k = MacKeyboardEngine(sink: r)
                for m in tapOrder { k.tapModifier(m) }
                var want: KeyMap.Modifier = []
                for m in combo { want.insert(m) }
                XCTAssertEqual(k.activeModifiers, want)
                let z = key("z")
                k.keyDown(z); k.keyUp(z)
                let downs = KeyMap.Modifier.order.filter { want.contains($0) }.compactMap(\.keyCode).map(Int.init)
                XCTAssertEqual(r.events.map(\.x), downs + [6, 6] + downs.reversed(), "\(combo)")
                let zDown = r.events[downs.count]
                XCTAssertEqual(zDown.kind, InputKind.keyDown)
                XCTAssertEqual(zDown.a, flags(want), "\(combo)")
                XCTAssertEqual(r.events.last?.a, 0, "every flag lifted at the end")
                for m in all { XCTAssertEqual(k.latch(of: m), .off, "\(m) let go") }
                // The next key goes alone.
                r.events.removeAll()
                k.keyDown(z); k.keyUp(z)
                XCTAssertEqual(r.events.map(\.a), [0, 0])
            }
        }
    }

    /// The same rule for each of the four: a tap holds it, a second tap lets it go however quickly (no lock).
    func testTheRuleIsTheSameForAllFour() {
        for m in all {
            let k = MacKeyboardEngine(sink: Recorder())
            k.tapModifier(m)
            XCTAssertEqual(k.latch(of: m), .once)
            k.tapModifier(m)
            XCTAssertEqual(k.latch(of: m), .off)
            k.tapModifier(m); k.tapModifier(m)
            XCTAssertEqual(k.latch(of: m), .off)
        }
    }

    /// Each modifier, and Command+Shift, around a trackpad click (upright) and a touch click (horizontal); after
    /// the click they let go.
    func testModifiersPlusAClickThenRelease() {
        for combo in all.map({ [$0] }) + [[.command, .shift]] {
            var want: KeyMap.Modifier = []
            for m in combo { want.insert(m) }
            let codes = KeyMap.Modifier.order.filter { want.contains($0) }.compactMap(\.keyCode).map(Int.init)
            // Upright trackpad.
            do {
                let r = Recorder()
                let k = MacKeyboardEngine(sink: r)
                let t = TrackpadEngine(sink: r)
                t.modifierWrap = { k.withModifiers($0) }
                for m in combo { k.tapModifier(m) }
                t.tap(button: 0, at: .zero, time: 1)
                let kinds = r.events.map(\.kind)
                XCTAssertEqual(kinds, Array(repeating: InputKind.keyDown, count: codes.count)
                               + [InputKind.move, InputKind.buttonDown, InputKind.buttonUp]
                               + Array(repeating: InputKind.keyUp, count: codes.count), "\(combo)")
                XCTAssertEqual(r.events.prefix(codes.count).map(\.x), codes)
                XCTAssertEqual(r.events.last?.a, 0)
                for m in all { XCTAssertEqual(k.latch(of: m), .off) }
            }
            // Horizontal: a tap on the picture, through the session's wiring.
            do {
                let r = Recorder()
                let parts = MainActor.assumeIsolated { SessionParts(sink: r) }
                let k = MainActor.assumeIsolated { parts.keyboard.engine }
                for m in combo { k.tapModifier(m) }
                MainActor.assumeIsolated { parts.touch.click(at: (100, 100), button: 0, time: 1) }
                let buttonDown = r.events.firstIndex { $0.kind == InputKind.buttonDown }!
                XCTAssertEqual(r.events.filter { $0.kind == InputKind.keyDown }.map(\.x), codes, "\(combo)")
                XCTAssertTrue(r.events[..<buttonDown].contains { $0.kind == InputKind.keyDown })
                XCTAssertEqual(r.events.last?.kind, InputKind.keyUp)
                XCTAssertEqual(r.events.last?.a, 0)
                for m in all { XCTAssertEqual(k.latch(of: m), .off) }
            }
        }
    }

    /// The key shows held from its tap until it lets go: after a key, after a second tap, and with others held.
    @MainActor
    func testHeldStateShowsOnTheKey() {
        let keys = [MacKeyboardLayout.controlKey, MacKeyboardLayout.optionKey, MacKeyboardLayout.commandKey,
                    MacKeyboardLayout.shiftKey]
        let state = KeyboardState(engine: MacKeyboardEngine(sink: Recorder()))
        for key in keys { XCTAssertFalse(KeyCap.isLit(key, state: state)) }
        state.engine.tapModifier(.command)
        state.engine.tapModifier(.shift)
        XCTAssertEqual(keys.map { KeyCap.isLit($0, state: state) }, [false, false, true, true])
        state.engine.tapModifier(.shift)   // a second tap lets Shift go
        XCTAssertEqual(keys.map { KeyCap.isLit($0, state: state) }, [false, false, true, false])
        let a = MacTyping.keys["a"]!
        state.engine.keyDown(a); state.engine.keyUp(a)
        for key in keys { XCTAssertFalse(KeyCap.isLit(key, state: state), key.id) }
        // The horizontal row uses the same keys.
        XCTAssertTrue(MacKeysBar.keys.contains(MacKeyboardLayout.commandKey))
    }

    /// The keys take the iOS 27 system keyboard's flat look (the owner 2026-11-20): at rest the system key colour
    /// (#FFFFFF light, #444444 dark), pressed a different grey, held the accent fill. One proof per state, both
    /// appearances.
    @MainActor
    func testKeyFillsMatchTheSystemKeyboard() throws {
        func pixel(lit: Bool, pressed: Bool = false, scheme: ColorScheme) throws -> (r: Int, g: Int, b: Int, a: Int) {
            let r = ImageRenderer(content: KeyFace(content: .text("⌘"), lit: lit, pressed: pressed)
                .frame(width: 52, height: 38).environment(\.colorScheme, scheme))
            r.scale = 1
            let cg = try XCTUnwrap(r.cgImage)
            let ctx = try XCTUnwrap(CGContext(data: nil, width: cg.width, height: cg.height, bitsPerComponent: 8,
                                              bytesPerRow: cg.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
            let px = try XCTUnwrap(ctx.data).assumingMemoryBound(to: UInt8.self)
            let i = (19 * cg.width + 8) * 4   // inside the key, left of the glyph
            return (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]), Int(px[i + 3]))
        }
        for (scheme, rest) in [(ColorScheme.light, 255), (.dark, 0x44)] {
            let off = try pixel(lit: false, scheme: scheme)
            XCTAssertEqual(off.a, 255, "\(scheme): opaque, no glass: \(off)")
            for c in [off.r, off.g, off.b] { XCTAssertLessThanOrEqual(abs(c - rest), 2, "\(scheme) rest: \(off)") }
            let down = try pixel(lit: false, pressed: true, scheme: scheme)
            XCTAssertGreaterThan(abs(down.r - off.r), 20, "\(scheme) pressed shows: \(down)")
            let on = try pixel(lit: true, scheme: scheme)
            XCTAssertGreaterThan(on.a, 200, "\(scheme): \(on)")
            XCTAssertGreaterThan(on.b - on.r, 100, "held is the accent blue, \(scheme): \(on)")
        }
    }

    /// The pop-up only names what a key is or does (the owner 2026-11-20: "You don't need to say they are combinable");
    /// nothing about combining or holding. The four modifiers' VoiceOver hints use the same words.
    func testPopUpNamesSymbolsOnly() {
        for sections in [KeyInfo.uprightSections(), KeyInfo.horizontalSections] {
            let lines = KeyInfo.lines(sections)
            for line in lines {
                XCTAssertFalse(line.text.lowercased().contains("combine"), line.text)
                XCTAssertFalse(line.text.lowercased().contains("hold"), line.text)
            }
            for (id, name) in [("k-control", "Control"), ("k-option", "Option"), ("k-command", "Command"),
                               ("k-shift", "Shift")] {
                if let line = lines.first(where: { $0.ids == [id] }) { XCTAssertEqual(line.text, name) }
            }
            // Every key, word keys included, has a line.
            XCTAssertEqual(Set(lines.flatMap(\.ids)), Set(sections.flatMap(\.entries).map(\.id)))
        }
        let up = KeyInfo.lines(KeyInfo.uprightSections())
        XCTAssertEqual(up.filter { $0.ids.contains("k-left") }.first?.ids.count, 4, "the arrows share one line")
        for key in [MacKeyboardLayout.controlKey, MacKeyboardLayout.optionKey, MacKeyboardLayout.commandKey,
                    MacKeyboardLayout.shiftKey] {
            let name = KeyCap.accessibilityName(key, more: false)
            XCTAssertEqual(KeyInfo.description(.key(key)), name, "the hint matches the pop-up's wording")
        }
    }

    /// Page up and page down are short words that read at key size, on the key and in the pop-up.
    func testPageKeysAreWords() {
        XCTAssertEqual(KeyCap.face(SpecialKeysLayout.pageUp), .text("pg↑"))
        XCTAssertEqual(KeyCap.face(SpecialKeysLayout.pageDown), .text("pg↓"))
        XCTAssertTrue(KeyCap.face(SpecialKeysLayout.pageUp).isWord)
    }
}

// MARK: - Apps key: the Mac's app switcher stays open (the owner 2026-11-20)

final class AppSwitcherTests: XCTestCase {
    private func e(_ kind: UInt8, _ code: Int, _ flags: Int) -> InputEvent {
        InputEvent(kind: kind, x: code, y: 0, a: flags, b: 0)
    }
    private let down = InputKind.keyDown, up = InputKind.keyUp
    private let cmdCode = 55, tabCode = 48
    private var arrow: Int { Int(MacKeyboardLayout.right.ownFlags) }
    private var opening: [InputEvent] { [e(down, cmdCode, cmd), e(down, tabCode, cmd), e(up, tabCode, cmd)] }
    private var commandUp: InputEvent { e(up, cmdCode, 0) }

    private func tap(_ k: MacKeyboardEngine, _ key: MacKey) { k.keyDown(key); k.keyUp(key) }

    func testAppsOpensWithCommandHeldAndAppsAgainPicks() {
        let r = Recorder()
        let k = MacKeyboardEngine(sink: r)
        k.sendShortcut(.switchApp)
        XCTAssertTrue(k.switcherOpen)
        XCTAssertEqual(r.events, opening, "Command stays down")
        k.sendShortcut(.switchApp)
        XCTAssertFalse(k.switcherOpen)
        XCTAssertEqual(r.events, opening + [commandUp])
    }

    /// Arrows, Tab and Shift-Tab move with Command still down; Return picks (Command up, no Return sent).
    func testArrowsAndTabMoveThenReturnPicks() {
        let r = Recorder()
        let k = MacKeyboardEngine(sink: r)
        k.sendShortcut(.switchApp)
        r.events.removeAll()
        tap(k, MacKeyboardLayout.right)
        tap(k, MacKeyboardLayout.left)
        tap(k, SpecialKeysLayout.rows(functionKeys: false).joined()
                .compactMap { if case let .key(x) = $0, x.id == "tab" { x } else { nil } }[0])
        k.tapModifier(.shift)
        tap(k, MacKeyboardLayout.tab)
        XCTAssertTrue(k.switcherOpen)
        XCTAssertEqual(r.events, [
            e(down, 124, cmd | arrow), e(up, 124, cmd | arrow),
            e(down, 123, cmd | arrow), e(up, 123, cmd | arrow),
            e(down, tabCode, cmd), e(up, tabCode, cmd),
            e(down, 56, cmd | shift), e(down, tabCode, cmd | shift), e(up, tabCode, cmd | shift), e(up, 56, cmd),
        ])
        XCTAssertEqual(k.latch(of: .shift), .off, "Shift used up by one Tab")
        r.events.removeAll()
        MacTyping.type("\n", into: k)
        XCTAssertEqual(r.events, [commandUp])
        XCTAssertFalse(k.switcherOpen)
    }

    /// A trackpad click on an app's icon picks it: the click, then Command up.
    @MainActor
    func testClickPicksThenCommandGoesUp() {
        let r = Recorder()
        let parts = SessionParts(sink: r)
        parts.setCanvas(width: 1920, height: 1080)
        parts.keyboard.engine.sendShortcut(.switchApp)
        r.events.removeAll()
        parts.trackpad.tap(button: 0, at: .zero, time: 0)
        XCTAssertEqual(r.events.map(\.kind), [InputKind.move, InputKind.buttonDown, InputKind.buttonUp, up])
        XCTAssertEqual(r.events.last, commandUp)
        XCTAssertFalse(parts.keyboard.engine.switcherOpen)
        // A touch click on the picture picks the same way.
        parts.keyboard.engine.sendShortcut(.switchApp)
        r.events.removeAll()
        parts.touch.click(at: (100, 100), button: 0, time: 5)
        XCTAssertEqual(r.events.last, commandUp)
        XCTAssertEqual(r.events.filter { $0.kind == InputKind.buttonUp }.count, 1)
    }

    /// esc: Escape (with Command, as the Mac's switcher expects), then Command up.
    func testEscapeCancels() {
        let r = Recorder()
        let k = MacKeyboardEngine(sink: r)
        k.sendShortcut(.switchApp)
        r.events.removeAll()
        tap(k, MacKeyboardLayout.escape)
        XCTAssertEqual(r.events, [e(down, 53, cmd), e(up, 53, cmd), commandUp])
        XCTAssertFalse(k.switcherOpen)
    }

    /// Tapping the held-looking Command key lets Command go too.
    func testTappingCommandPicks() {
        let r = Recorder()
        let k = MacKeyboardEngine(sink: r)
        k.sendShortcut(.switchApp)
        k.tapModifier(.command)
        XCTAssertEqual(r.events, opening + [commandUp])
        XCTAssertEqual(k.latch(of: .command), .off)
    }

    /// The other shortcut keys send nothing while it is open (the Quit key would quit the highlighted app); a
    /// typed q still goes as ⌘Q, which is the Mac's own behaviour.
    func testOtherShortcutsDoNothingWhileOpenTypedQGoes() {
        let r = Recorder()
        let k = MacKeyboardEngine(sink: r)
        k.sendShortcut(.switchApp)
        r.events.removeAll()
        k.sendShortcut(.quit)
        k.sendShortcut(.copy)
        XCTAssertTrue(r.events.isEmpty)
        MacTyping.type("q", into: k)
        XCTAssertEqual(r.events, [e(down, 12, cmd), e(up, 12, cmd)])
        XCTAssertTrue(k.switcherOpen)
        k.releaseAll()
    }

    /// Leaving, turning the phone and the app going to the background all let Command go at once,
    /// and only once. Command is never left down.
    @MainActor
    func testEveryReleasePathLetsCommandGo() {
        let paths: [(String, (SessionParts) -> Void)] = [
            ("release (leave, fold, background)", { $0.releaseAll() }),
            ("turn the phone", { $0.layoutChanged() }),
        ]
        for (name, release) in paths {
            let r = Recorder()
            let parts = SessionParts(sink: r)
            parts.keyboard.engine.sendShortcut(.switchApp)
            XCTAssertTrue(parts.keyboard.switcherOpen, name)
            r.events.removeAll()
            release(parts)
            XCTAssertEqual(r.events, [commandUp], name)
            XCTAssertFalse(parts.keyboard.switcherOpen, name)
            release(parts)
            XCTAssertEqual(r.events, [commandUp], "\(name): nothing more")
        }
    }

    /// Apps and Command show held while it is open; nothing else does.
    @MainActor
    func testHeldLook() {
        let state = KeyboardState(engine: MacKeyboardEngine(sink: Recorder()))
        state.engine.sendShortcut(.switchApp)
        XCTAssertTrue(state.switcherOpen)
        XCTAssertTrue(KeyCap.isLit(MacKeyboardLayout.commandKey, state: state))
        XCTAssertFalse(KeyCap.isLit(MacKeyboardLayout.shiftKey, state: state))
        state.engine.sendShortcut(.switchApp)
        XCTAssertFalse(KeyCap.isLit(MacKeyboardLayout.commandKey, state: state))
    }

    /// The owner 2026-11-20: the system keyboard's own caps lock is untouched; its capitals reach the Mac as capitals.
    @MainActor
    func testSystemKeyboardCapsLockCapitalsReachTheMac() {
        let r = Recorder()
        let k = MacKeyboardEngine(sink: r)
        let input = MacTypingView(frame: .zero)
        input.engine = k
        input.showsMacKeysBar = false
        input.insertText("HI")   // what the system keyboard sends with caps lock on
        XCTAssertEqual(r.events, [e(down, 4, shift), e(up, 4, shift), e(down, 34, shift), e(up, 34, shift)])
    }

    /// No pop-up line or VoiceOver hint mentions a lock.
    func testNothingMentionsALock() {
        for line in KeyInfo.lines(KeyInfo.uprightSections(), clicks: true) {
            XCTAssertFalse(line.text.lowercased().contains("lock"), line.text)
        }
        let cells: [MacKeyboardLayout.Cell] = Array(SpecialKeysLayout.rows(functionKeys: false).joined())
            + Array(SpecialKeysLayout.rows(functionKeys: true).joined())
        for cell in cells {
            XCTAssertFalse(KeyInfo.description(cell).lowercased().contains("lock"), KeyInfo.description(cell))
        }
    }
}

// MARK: - Release on connect (host key release order, 2026-11-20)

final class ConnectReleaseTests: XCTestCase {
    /// Every modifier's key goes up once, flags 0, and nothing goes down.
    func testConnectSendsAKeyUpForEveryModifierAndNothingElse() {
        let r = Recorder()
        ConnectRelease.send(to: r)
        XCTAssertEqual(r.events, [59, 58, 56, 55, 63].map { InputEvent(kind: InputKind.keyUp, x: $0, y: 0, a: 0, b: 0) })
    }

    /// The existing release paths are unchanged: a held Command (Apps switcher) still goes up on releaseAll.
    func testExistingReleasePathStillLiftsHeldCommand() {
        let r = Recorder()
        let keys = MacKeyboardEngine(sink: r)
        keys.tapAppSwitcher()
        r.events.removeAll()
        keys.releaseAll()
        XCTAssertEqual(r.events.filter { $0.kind == InputKind.keyUp }.map(\.x), [55])
    }
}

// MARK: - Coming back from another app (ReturnFlow, order 2026-11-20 "return without reconnect")

final class ReturnFlowTests: XCTestCase {
    private func live() -> ReturnFlow {
        var f = ReturnFlow()
        XCTAssertEqual(f.wentLive(), .nothing)
        return f
    }

    func testLeaveExpireReturnLive() {
        var f = live()
        XCTAssertTrue(f.acceptsInput)
        XCTAssertEqual(f.left(), .pause)
        XCTAssertEqual(f.stage, .awayKept)
        XCTAssertFalse(f.acceptsInput)
        XCTAssertFalse(f.showsHeldPicture, "still the session's own (paused) picture")
        XCTAssertEqual(f.backgroundTimeUp(), .endKeepingPicture)
        XCTAssertEqual(f.stage, .awayEnded)
        XCTAssertTrue(f.showsSession, "the session screen stays: no list of Macs on return")
        XCTAssertTrue(f.showsHeldPicture)
        XCTAssertEqual(f.returned(locked: false), .dial, "rejoin at once on return")
        XCTAssertEqual(f.stage, .rejoining)
        XCTAssertTrue(f.showsHeldPicture)
        XCTAssertFalse(f.acceptsInput, "nothing reaches the Mac until live")
        XCTAssertEqual(f.wentLive(), .nothing)
        XCTAssertEqual(f.stage, .live)
        XCTAssertTrue(f.acceptsInput)
        XCTAssertFalse(f.showsHeldPicture)
    }

    func testReturnBeforeExpiryResumesTheSameSession() {
        var f = live()
        XCTAssertEqual(f.left(), .pause)
        XCTAssertEqual(f.returned(locked: false), .check, "a kept session is checked first")
        XCTAssertEqual(f.stage, .checking)
        XCTAssertEqual(f.backgroundTimeUp(), .nothing, "a late expiry during the check changes nothing")
        XCTAssertEqual(f.checkPassed(), .resume)
        XCTAssertEqual(f.stage, .live)
        XCTAssertEqual(f.backgroundTimeUp(), .nothing, "a late expiry after the return changes nothing")
        XCTAssertEqual(f.stage, .live)
    }

    func testSessionDiedWhileSuspendedRejoinsBehindThePicture() {
        // Back before the background task expired, but the Host had already dropped us: the drop arrives in the
        // foreground and the rejoin runs behind the last picture.
        var f = live()
        _ = f.left()
        XCTAssertEqual(f.returned(locked: false), .check)
        XCTAssertEqual(f.connectionDropped(inForeground: true), .dial)
        XCTAssertEqual(f.stage, .rejoining)
        XCTAssertTrue(f.showsHeldPicture)
    }

    func testDropWhileAwayWaitsForTheReturn() {
        var f = live()
        _ = f.left()
        XCTAssertEqual(f.connectionDropped(inForeground: false), .endKeepingPicture)
        XCTAssertEqual(f.stage, .awayEnded)
        XCTAssertEqual(f.backgroundTimeUp(), .nothing)
        XCTAssertEqual(f.returned(locked: false), .dial)
    }

    func testFailedRejoinShowsFailureThenRetry() {
        var f = live()
        _ = f.left(); _ = f.backgroundTimeUp(); _ = f.returned(locked: false)
        XCTAssertEqual(f.rejoinFailed(), .showFailure)
        XCTAssertEqual(f.stage, .failed)
        XCTAssertTrue(f.showsHeldPicture, "the picture stays behind the message")
        XCTAssertFalse(f.acceptsInput)
        XCTAssertEqual(f.retry(), .dial)
        XCTAssertEqual(f.stage, .rejoining)
        XCTAssertEqual(f.wentLive(), .nothing)
        XCTAssertEqual(f.retry(), .nothing, "Try Again does nothing once live")
    }

    func testLockPathWaitsForTouchIDBeforeRejoining() {
        var f = live()
        _ = f.left(); _ = f.backgroundTimeUp()
        XCTAssertEqual(f.returned(locked: true), .nothing, "no dial behind the lock")
        XCTAssertEqual(f.stage, .waitingForUnlock)
        XCTAssertFalse(f.acceptsInput)
        XCTAssertEqual(f.unlocked(), .dial)
        XCTAssertEqual(f.stage, .rejoining)
        XCTAssertEqual(f.unlocked(), .nothing)
    }

    func testLockRuleDecidesTheReturnAtFiveMinutes() {
        // The lock's own rule (AppLock.shouldLock) feeds `returned(locked:)`: 4:59 away rejoins at once, 5:00 waits.
        let left = Date(timeIntervalSinceReferenceDate: 0)
        for (away, expected) in [(299.0, ReturnFlow.Stage.rejoining), (300.0, .waitingForUnlock)] {
            var f = live()
            _ = f.left(); _ = f.backgroundTimeUp()
            let locked = AppLock.shouldLock(required: true, backgroundedAt: left, now: left.addingTimeInterval(away))
            _ = f.returned(locked: locked)
            XCTAssertEqual(f.stage, expected, "\(away) s away")
        }
    }

    func testLeavingMidRejoinStopsAndRejoinsOnReturn() {
        var f = live()
        _ = f.connectionDropped(inForeground: true)
        XCTAssertEqual(f.left(), .endKeepingPicture)
        XCTAssertEqual(f.stage, .awayEnded)
        XCTAssertEqual(f.returned(locked: false), .dial)
    }

    func testEndedGoesBackToTheList() {
        var f = live()
        _ = f.left(); _ = f.backgroundTimeUp()
        f.ended()
        XCTAssertEqual(f.stage, .none)
        XCTAssertFalse(f.showsSession)
        XCTAssertEqual(f.returned(locked: false), .nothing)
    }

    func testNothingHappensWithoutASession() {
        var f = ReturnFlow()
        XCTAssertEqual(f.left(), .nothing)
        XCTAssertEqual(f.backgroundTimeUp(), .nothing)
        XCTAssertEqual(f.connectionDropped(inForeground: true), .nothing)
        XCTAssertEqual(f.returned(locked: false), .nothing)
        XCTAssertFalse(f.showsSession)
    }
}

// MARK: - Checking the session is alive on return (order 2026-11-20 "check live on return", the owner: "Go ahead")

final class ReturnCheckTests: XCTestCase {
    private let back: UInt64 = 50_000_000 // the return, in the engine's microseconds

    /// Live, left, back within the background time: checking.
    private func checking() -> ReturnFlow {
        var f = ReturnFlow()
        _ = f.wentLive(); _ = f.left()
        XCTAssertEqual(f.returned(locked: false), .check)
        return f
    }

    /// Drives the check at 50 ms ticks, as `SessionModel` does; `pingAt` is when control bytes arrive (offset
    /// from the return), nil for a dead session. Returns the verdict and when it came.
    private func run(pingAt: UInt64?, lastBefore: UInt64 = 0) -> (ReturnCheck.Verdict, UInt64) {
        let check = ReturnCheck(returnedUS: back)
        var t: UInt64 = 0
        while t <= 5_000_000 {
            var rx = lastBefore
            if let p = pingAt, t >= p { rx = back + p }
            let v = check.verdict(lastControlRxUS: rx, nowUS: back + t)
            if v != .waiting { return (v, t) }
            t += 50_000
        }
        return (.waiting, t)
    }

    func testAliveOnReturnGoesLiveAtTheFirstPing() {
        // The Host pings once a second; one lands 0.4 s after the return.
        var f = checking()
        XCTAssertFalse(f.showsHeldPicture, "the picture is not marked not-live while checking: no flicker")
        XCTAssertTrue(f.drawsFromSession, "the session's own picture keeps drawing")
        let (v, at) = run(pingAt: 400_000)
        XCTAssertEqual(v, .alive)
        XCTAssertEqual(at, 400_000, "live at the poll after the ping, not later")
        XCTAssertEqual(f.checkPassed(), .resume)
        XCTAssertEqual(f.stage, .live)
        XCTAssertTrue(f.acceptsInput)
        XCTAssertEqual(f.checkTimedOut(), .nothing, "a stale timeout after the pass changes nothing")
    }

    func testEveryPingPhaseIsAliveWithinTheBound() {
        // Wherever the 1 Hz ping falls, a healthy session passes before the bound, even when the first ping
        // lands in the grace moment and only the next one counts.
        for phase in stride(from: UInt64(0), to: 1_000_000, by: 50_000) {
            let check = ReturnCheck(returnedUS: back)
            var verdict = ReturnCheck.Verdict.waiting
            var t: UInt64 = 0
            while verdict == .waiting && t <= 2_000_000 {
                // Pings at phase, phase + 1 s, … plus 100 ms of network.
                let delivered = [phase, phase + 1_000_000].map { $0 + 100_000 }.filter { $0 <= t }.last
                verdict = check.verdict(lastControlRxUS: delivered.map { back + $0 } ?? 0, nowUS: back + t)
                t += 50_000
            }
            XCTAssertEqual(verdict, .alive, "ping phase \(phase) µs")
        }
    }

    func testOldBytesReadAtTheReturnDoNotCount() {
        // Bytes iOS buffered while the app was suspended are read the moment it resumes; they prove nothing.
        let (v, _) = run(pingAt: 20_000)
        XCTAssertEqual(v, .dead)
        let check = ReturnCheck(returnedUS: back)
        XCTAssertEqual(check.verdict(lastControlRxUS: back - 9_000_000, nowUS: back + 1_000_000), .waiting,
                       "the last ping before leaving is not proof")
    }

    func testDeadOnReturnRejoinsWithinTheBound() {
        // The Host dropped the session while the app was suspended: nothing arrives after the return.
        var f = checking()
        let (v, at) = run(pingAt: nil, lastBefore: back - 25_000_000)
        XCTAssertEqual(v, .dead)
        XCTAssertEqual(at, ReturnCheck.floorUS, "the rejoin starts at the bound, not at 10 s or 30 s")
        XCTAssertEqual(ReturnCheck(returnedUS: back).boundSeconds, 1.5)
        XCTAssertEqual(f.checkTimedOut(), .dial)
        XCTAssertEqual(f.stage, .rejoining)
        XCTAssertTrue(f.showsHeldPicture, "now dimmed with Reconnecting…")
        XCTAssertFalse(f.acceptsInput)
        XCTAssertEqual(f.checkPassed(), .nothing, "a late ping after the timeout changes nothing")
    }

    func testADropDuringTheCheckRejoinsAtOnce() {
        var f = checking()
        XCTAssertEqual(f.connectionDropped(inForeground: true), .dial, "no need to wait for the bound")
        XCTAssertEqual(f.stage, .rejoining)
    }

    func testLeavingDuringTheCheckKeepsTheSession() {
        var f = checking()
        XCTAssertEqual(f.left(), .pause)
        XCTAssertEqual(f.stage, .awayKept)
        XCTAssertEqual(f.returned(locked: false), .check, "checked again on the next return")
    }

    func testNoInputReachesTheMacBeforeProof() {
        // SessionModel's order: on return the gate stays closed; on `.resume` the engines are cleared with the
        // gate still closed, then it opens. Anything typed or clicked during the check goes nowhere.
        var f = checking()
        let gate = InputGate(), mac = Recorder()
        let keys = MacKeyboardEngine(sink: gate)
        let pad = TrackpadEngine(sink: gate)
        XCTAssertFalse(f.acceptsInput)
        keys.keyDown(key("a")); keys.keyUp(key("a"))
        pad.tap(button: 0, at: CGPoint(x: 10, y: 10), time: 0)
        XCTAssertTrue(mac.events.isEmpty)
        XCTAssertEqual(f.checkPassed(), .resume)
        keys.releaseAll(); pad.releaseAll()
        gate.open(to: mac)
        XCTAssertTrue(mac.events.isEmpty, "nothing held back arrives when the gate opens")
        keys.keyDown(key("b")); keys.keyUp(key("b"))
        XCTAssertEqual(mac.events.count, 2, "input flows once proven")
    }
}

final class InputGateTests: XCTestCase {
    func testClosedGateSendsAndQueuesNothing() {
        let gate = InputGate(), mac = Recorder()
        let keys = MacKeyboardEngine(sink: gate)
        keys.keyDown(key("a")); keys.keyUp(key("a"))
        XCTAssertTrue(mac.events.isEmpty)
        gate.open(to: mac)
        XCTAssertTrue(mac.events.isEmpty, "nothing typed while closed arrives when it opens")
        keys.keyDown(key("b")); keys.keyUp(key("b"))
        XCTAssertEqual(mac.events.count, 2)
        gate.close()
        keys.keyDown(key("c")); keys.keyUp(key("c"))
        XCTAssertEqual(mac.events.count, 2)
    }
}

// MARK: - Every picture size the Host can send (project notes)

/// The Host's input mapping (`HostController.injectInput` / `mappingScale` at the pinned commit): a picture pixel
/// is a Mac point at `pixel / (pictureWidth / screenWidth)`. The Mac screen here is 1920 x 1080 points.
fileprivate struct MacScreen {
    var width = 1920.0, height = 1080.0
    func point(_ e: InputEvent, picture: (w: Int, h: Int)) -> (x: Double, y: Double) {
        (Double(e.x) / (Double(picture.w) / width), Double(e.y) / (Double(picture.h) / height))
    }
}

final class PictureSizeTests: XCTestCase {
    /// What Scale mode and the Host's auto-scale can pick for a 1920 x 1080 Mac (full, and the one halved rung),
    /// what the 1920 x 1080 request gives other Macs' displays and their halved rung, and an odd size.
    static let sizes: [(Int, Int)] = [(1920, 1080), (960, 540), (1728, 1080), (1600, 1000), (800, 500),
                                      (1366, 767)]
    fileprivate let screen = MacScreen()

    /// The trackpad pointer reaches every edge of the Mac's screen at every size: within one picture pixel's worth
    /// of Mac points of the far edges.
    func testTrackpadPointerReachesEveryEdgeAtEverySize() {
        for (w, h) in Self.sizes {
            let r = Recorder()
            let t = TrackpadEngine(sink: r)
            t.setCanvas(width: w, height: h)
            let step = 1920.0 / Double(w)
            t.move(dx: 100_000, dy: 100_000, dt: 1)
            var p = screen.point(r.events.last!, picture: (w, h))
            XCTAssertGreaterThanOrEqual(p.x, 1920 - step - 1e-9, "\(w)x\(h) right")
            XCTAssertGreaterThanOrEqual(p.y, 1080 - 1080.0 / Double(h) - 1e-9, "\(w)x\(h) bottom")
            XCTAssertLessThan(p.x, 1920); XCTAssertLessThan(p.y, 1080)
            t.move(dx: -100_000, dy: -100_000, dt: 1)
            p = screen.point(r.events.last!, picture: (w, h))
            XCTAssertEqual(p.x, 0); XCTAssertEqual(p.y, 0)
        }
    }

    /// 960 x 540 against a 1920 x 1080 screen (the owner's slow link): the pad's far right is the Mac's far right, and a
    /// tap clicks there.
    func testHalfSizePictureReachesTheRightEdgeAndClicksThere() {
        let r = Recorder()
        let t = TrackpadEngine(sink: r)
        t.setCanvas(width: 960, height: 540)
        t.hostPointer(x: 480, y: 270)
        t.move(dx: 10_000, dy: 0, dt: 1)
        XCTAssertEqual(r.events.last, InputEvent(kind: 1, x: 959, y: 270, a: 0, b: 0))
        XCTAssertEqual(screen.point(r.events.last!, picture: (960, 540)).x, 1918)
        r.events.removeAll()
        t.tap(button: 0, at: .zero, time: 1)
        XCTAssertEqual(r.events.map(\.x), [959, 959, 959])
        r.events.removeAll()
        t.pressButton(1, time: 5)
        t.releaseButton(1)
        XCTAssertEqual(r.events, [InputEvent(kind: 1, x: 959, y: 270, a: 0, b: 0),
                                  InputEvent(kind: 2, x: 959, y: 270, a: 1, b: 1),
                                  InputEvent(kind: 3, x: 959, y: 270, a: 1, b: 1)])
    }

    /// The picture shrinks and grows back in the middle of a Left-click-button drag: the Mac's pointer stays where
    /// it was (in Mac points), the button stays down, and the drag carries on to the far edge in the new size.
    func testSizeChangesMidDragKeepThePointerAndTheButton() {
        let r = Recorder()
        let t = TrackpadEngine(sink: r)
        t.setCanvas(width: 1920, height: 1080)
        t.hostPointer(x: 1500, y: 800)
        t.pressButton(0, time: 1)
        let before = screen.point(r.events.last!, picture: (1920, 1080))
        t.setCanvas(width: 960, height: 540)
        t.move(dx: 0, dy: 0, dt: 1)
        XCTAssertEqual(r.events.last, InputEvent(kind: 1, x: 750, y: 400, a: 0, b: 0))
        let after = screen.point(r.events.last!, picture: (960, 540))
        XCTAssertEqual(after.x, before.x); XCTAssertEqual(after.y, before.y)
        t.move(dx: 10_000, dy: 0, dt: 1)
        XCTAssertEqual(r.events.last?.x, 959)
        t.setCanvas(width: 1920, height: 1080)
        t.move(dx: 0, dy: 0, dt: 1)
        XCTAssertEqual(screen.point(r.events.last!, picture: (1920, 1080)).x, 1918) // 959 → 1918.5, down
        t.move(dx: 10_000, dy: 0, dt: 1)
        XCTAssertEqual(r.events.last?.x, 1919)
        t.releaseButton(0)
        XCTAssertEqual(r.events.filter { $0.kind == 2 }.count, 1)
        XCTAssertEqual(r.events.last, InputEvent(kind: 3, x: 1919, y: 800, a: 1, b: 0))
    }

    /// A direct tap maps through the picture's rectangle at the SAME size the pointer engines use: the tap lands
    /// under the finger on the Mac at every size. With the old size kept by the picture (the bug), a tap on the
    /// picture's right half would land past the Mac's right edge.
    func testDirectTapLandsUnderTheFingerAtEverySize() {
        let bounds = CGSize(width: 800, height: 450)
        for (w, h) in Self.sizes {
            let f = PictureFit.frame(canvasWidth: w, canvasHeight: h, in: bounds, screenScale: 3)
            for fx in [0.0, 0.25, 0.5, 0.75, 0.999] {
                let finger = CGPoint(x: f.minX + f.width * fx, y: f.minY + f.height * 0.9)
                let p = DirectTouchEngine.canvasPoint(finger, picture: f, canvasWidth: w, canvasHeight: h)!
                let r = Recorder()
                let e = DirectTouchEngine(sink: r)
                e.setCanvas(width: w, height: h)
                e.click(at: p, button: 0, time: 1)
                let mac = screen.point(r.events[1], picture: (w, h))
                XCTAssertEqual(mac.x, 1920 * fx, accuracy: 1920.0 / Double(w) + 0.01, "\(w)x\(h) at \(fx)")
                XCTAssertEqual(mac.y, 1080 * 0.9, accuracy: 1080.0 / Double(h) + 0.01, "\(w)x\(h)")
            }
        }
        // The fault itself: the picture still at 1920 x 1080 while the Host sends 960 x 540.
        let f = PictureFit.frame(canvasWidth: 1920, canvasHeight: 1080, in: bounds, screenScale: 3)
        let stale = DirectTouchEngine.canvasPoint(CGPoint(x: f.minX + f.width * 0.75, y: f.midY), picture: f,
                                                  canvasWidth: 1920, canvasHeight: 1080)!
        XCTAssertGreaterThan(Double(stale.0) / 0.5, 1920) // off the Mac's screen
    }

    /// Edge swipes go to the top or bottom row of the picture at every size, at the finger's place across.
    func testEdgeSwipesAtEverySize() {
        for (w, h) in Self.sizes {
            let r = Recorder()
            let e = DirectTouchEngine(sink: r)
            e.setCanvas(width: w, height: h)
            e.pointerToEdge(x: w * 2, top: false)
            XCTAssertEqual(r.events.last, InputEvent(kind: 1, x: w - 1, y: h - 1, a: 0, b: 0))
            e.pointerToEdge(x: w / 2, top: true)
            XCTAssertEqual(r.events.last, InputEvent(kind: 1, x: w / 2, y: 0, a: 0, b: 0))
        }
    }

    /// A touch drag in progress when the size changes ends at the same Mac place, in the new size.
    func testTouchDragAcrossASizeChange() {
        let r = Recorder()
        let e = DirectTouchEngine(sink: r)
        e.setCanvas(width: 1920, height: 1080)
        e.beginDrag(at: (100, 100), now: (1800, 1000))
        e.setCanvas(width: 960, height: 540)
        e.endDrag(at: nil)
        XCTAssertEqual(r.events.last, InputEvent(kind: 3, x: 900, y: 500, a: 1, b: 0))
        XCTAssertEqual(r.events.filter { $0.kind == 2 }.count, 1)
    }
}

/// The slow-link leftovers (project notes; the owner 2026-11-20: "This needs to work on all
/// connections"). Full picture sizes paired with the Host's halved rung, and one in-between size.
final class SlowLinkTests: XCTestCase {
    static let pairs: [(full: (Int, Int), shrunk: (Int, Int))] = [
        ((1920, 1080), (960, 540)), ((1728, 1080), (864, 540)), ((1600, 1000), (800, 500)), ((1920, 1080), (1366, 767)),
    ]

    /// Mac distance (in full-picture pixels, which is Mac points times one fixed factor) a pad stroke moves.
    private func padTravel(width w: Int, height h: Int, full: Int, dx: Double, speed: Double) -> Double {
        let r = Recorder()
        let t = TrackpadEngine(sink: r)
        t.setCanvas(width: w, height: h, fullWidth: full)
        t.hostPointer(x: w / 4, y: h / 2)
        t.move(dx: dx, dy: 0, dt: dx / speed)
        return Double(r.events.last!.x - w / 4) * Double(full) / Double(w)
    }

    /// Item 1: the pointer crosses the Mac at the same speed whatever size is sent, slow and fast strokes.
    func testTrackpadSpeedIsTheSameOnTheMacAtEverySize() {
        for (full, shrunk) in Self.pairs {
            for speed in [100.0, 500.0, 2000.0] {
                let a = padTravel(width: full.0, height: full.1, full: full.0, dx: 40, speed: speed)
                let b = padTravel(width: shrunk.0, height: shrunk.1, full: full.0, dx: 40, speed: speed)
                // Within one shrunk pixel (the pointer is in whole pixels).
                XCTAssertEqual(b, a, accuracy: Double(full.0) / Double(shrunk.0) + 1e-9,
                               "\(shrunk.0)x\(shrunk.1) of \(full.0) at \(speed) pt/s")
            }
        }
    }

    /// Item 1: two-finger scroll and the Scroll button send the same Mac points at every size.
    func testTrackpadScrollAndScrollButtonAreTheSameAtEverySize() {
        for (full, shrunk) in Self.pairs {
            var sent: [[InputEvent]] = []
            for (w, h) in [full, shrunk] {
                let r = Recorder()
                let t = TrackpadEngine(sink: r)
                t.setCanvas(width: w, height: h, fullWidth: full.0)
                t.scroll(dx: 0, dy: 37)
                t.pressScroll()
                t.move(dx: 12, dy: -25, dt: 0.1)
                t.releaseScroll()
                sent.append(r.events.filter { $0.kind == InputKind.scrollPoints })
            }
            XCTAssertEqual(sent[0].map { [$0.a, $0.b] }, [[0, 37], [12, -25]])
            XCTAssertEqual(sent[1].map { [$0.a, $0.b] }, sent[0].map { [$0.a, $0.b] }, "\(shrunk.0)x\(shrunk.1)")
        }
    }

    /// Item 2: one finger moving 100 points on a 400-point-wide picture scrolls the Mac the same at every size.
    /// The picture view hands the engine picture pixels (finger points × width ÷ picture frame width).
    func testOneFingerScrollOnThePictureIsTheSameAtEverySize() {
        for (full, shrunk) in Self.pairs {
            var b: [Int] = []
            for (w, h) in [full, shrunk] {
                let r = Recorder()
                let e = DirectTouchEngine(sink: r)
                e.setCanvas(width: w, height: h, fullWidth: full.0)
                e.beginScroll(at: (w / 2, h / 2))
                let perPoint = CGFloat(w) / 400
                for _ in 0..<10 { e.scroll(dx: 0, dy: 10 * perPoint) }
                b.append(r.events.filter { $0.kind == InputKind.scrollPoints }.map(\.b).reduce(0, +))
            }
            XCTAssertEqual(b[0], full.0 / 4, "full size: 100 of 400 points is a quarter of the picture")
            XCTAssertEqual(b[1], b[0], "\(shrunk.0)x\(shrunk.1)")
        }
    }

    /// Item 3: at every size the pad's bottom edge lands in the Mac's last two rows and the top edge at row 0, and
    /// never past the picture (one past landed off screen on my-mac; a hidden Dock showed at Mac rows 1078
    /// and 1079, not at 1080; measured 2026-11-20, project notes).
    func testEdgesReachTheMacsLastTwoRowsAndNeverPast() {
        let screen = (w: 1920.0, h: 1080.0)
        for (w, h) in [(1920, 1080), (960, 540), (1366, 767)] {
            let r = Recorder()
            let t = TrackpadEngine(sink: r)
            t.setCanvas(width: w, height: h, fullWidth: 1920)
            t.move(dx: 0, dy: 1_000_000, dt: 1)
            let bottom = Double(r.events.last!.y) / (Double(h) / screen.h)
            XCTAssertEqual(r.events.last!.y, h - 1, "never one past the picture")
            XCTAssertGreaterThanOrEqual(bottom, screen.h - 2, "\(w)x\(h): Mac row \(bottom)")
            t.move(dx: 0, dy: -1_000_000, dt: 1)
            XCTAssertEqual(r.events.last!.y, 0)
        }
    }

    /// Item 5: a healthy slow link whose control bytes come 1.8 s apart is not called dead when its next ping
    /// arrives 2.0 s after the return (the fixed 1.5 s bound rejoined it).
    func testSlowHealthyLinkIsNotCalledDead() {
        var pace = LinkPace()
        for i in 0..<40 { pace.record(stalenessUS: UInt64(i % 8) * 225_000) } // 0 … 1.575 s, then …
        pace.record(stalenessUS: 1_800_000)
        XCTAssertEqual(pace.returnBoundUS, 2_300_000)
        let back: UInt64 = 100_000_000
        let check = ReturnCheck(returnedUS: back, boundUS: pace.returnBoundUS)
        XCTAssertEqual(check.verdict(lastControlRxUS: back - 1_000_000, nowUS: back + 1_900_000), .waiting)
        XCTAssertEqual(check.verdict(lastControlRxUS: back + 2_000_000, nowUS: back + 2_050_000), .alive)
    }

    /// Item 5: a fast link keeps the 1.5 s bound; a dead session is caught by 4 s at the very worst.
    func testBoundFloorAndCeiling() {
        var fast = LinkPace()
        for i in 0..<120 { fast.record(stalenessUS: UInt64(i % 10) * 100_000) } // pings 1 s apart, 0 … 0.9 s
        XCTAssertEqual(fast.returnBoundUS, ReturnCheck.floorUS)
        XCTAssertEqual(LinkPace().returnBoundUS, 1_500_000, "nothing measured yet: the floor")
        var stalled = LinkPace()
        stalled.record(stalenessUS: 30_000_000)
        XCTAssertEqual(stalled.returnBoundUS, 4_000_000)
        let back: UInt64 = 100_000_000
        let check = ReturnCheck(returnedUS: back, boundUS: stalled.returnBoundUS)
        XCTAssertEqual(check.verdict(lastControlRxUS: back - 5_000_000, nowUS: back + 3_950_000), .waiting)
        XCTAssertEqual(check.verdict(lastControlRxUS: back - 5_000_000, nowUS: back + 4_000_000), .dead)
        // Only the last 30 s count: an old stall stops widening the bound.
        for _ in 0..<LinkPace.keep { stalled.record(stalenessUS: 500_000) }
        XCTAssertEqual(stalled.returnBoundUS, ReturnCheck.floorUS)
    }
}
