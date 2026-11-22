import XCTest
@testable import DuoDesktop

/// The 16:10 view (project notes; mock-ups `screenshots/view-16x10-v2-*-2026-11-21.png`).
@MainActor
final class SixteenTenViewTests: XCTestCase {
    /// The owner's upright safe area below the top row (as `DuoDesktopTests.safeUpright`) and his keyboard (293 pt).
    let safeUpright = CGSize(width: 669, height: 951 - 82 - 34)
    let bensKeyboard: CGFloat = 293

    /// Layout chosen by the larger fitted picture (the owner 2026-11-21: "change the rule to show the largest possible
    /// picture"); a tie goes to 16:9. The order's examples, then more.
    func testShapeShowsTheLargestPicture() {
        for (w, h) in [(3456, 2234), (2560, 2880), (1920, 1200), (1728, 1080), (1440, 900), (1024, 768), (1080, 1920)] {
            XCTAssertEqual(PictureShape.of(width: w, height: h), .sixteenTen, "\(w)x\(h)")
        }
        for (w, h) in [(1920, 1080), (3440, 1440), (0, 0), (960, 540), (3840, 2160), (5120, 1440)] {
            XCTAssertEqual(PictureShape.of(width: w, height: h), .sixteenNine, "\(w)x\(h)")
        }
        // The fitted areas behind one case: 3456 x 2234 is height-bound in both boxes; 16:10's is larger.
        let ten = PictureShape.fittedArea(width: 3456, height: 2234, box: 10 / 16)
        let nine = PictureShape.fittedArea(width: 3456, height: 2234, box: 9 / 16)
        XCTAssertGreaterThan(ten, nine)
    }

    /// 16:9 is unchanged: the same numbers as before this build (project notes table, "Today").
    func testSixteenNineUnchanged() {
        let u = SessionLayout.Upright(size: safeUpright, keyboardInset: bensKeyboard)
        XCTAssertEqual(u.shape, .sixteenNine)
        XCTAssertEqual(u.picture.size, CGSize(width: 669, height: 376))
        XCTAssertEqual(u.rows, 4)
        XCTAssertEqual(u.band.height, 150)
        XCTAssertEqual(u.keyMetrics.keyWidth, 35)
        XCTAssertEqual(u.keyMetrics.keyHeight, 33)
        XCTAssertEqual(u.trackpad.size, CGSize(width: 323, height: 150))
        XCTAssertEqual(SessionLayout.Upright.minimumRoom, 136)
        XCTAssertEqual(SpecialKeysLayout.rows(functionKeys: false).count, 4)
    }

    /// The sizes in the mock-up's table: picture 669 x 418, band 108, keys 35 x 32, Left click 76 x 70, Right click
    /// and Scroll one key, trackpad 323 x 108, "more" keys 28.6 x 32.
    func testSixteenTenSizes() {
        let u = SessionLayout.Upright(size: safeUpright, keyboardInset: bensKeyboard, shape: .sixteenTen)
        XCTAssertEqual(u.picture.size, CGSize(width: 669, height: 418))
        XCTAssertEqual(u.rows, 3)
        XCTAssertEqual(u.band.height, 108)
        let m = u.keyMetrics
        XCTAssertEqual(m.keyWidth, 35)
        XCTAssertEqual(m.keyHeight, 32)
        XCTAssertEqual(m.rowGap, 6)
        XCTAssertEqual(m.width(units: 2), 76)
        XCTAssertEqual(m.height(rows: 2), 70)
        XCTAssertEqual(u.trackpad.size, CGSize(width: 323, height: 108))
        XCTAssertEqual(u.keys.width, 322)
        XCTAssertEqual(SixteenTenKeysLayout.moreKeyWidth(in: m.width(units: SpecialKeysLayout.units)), 28.6)
        // The rows fill the band exactly, and the band never reaches the keyboard.
        XCTAssertEqual(m.height(rows: 3), u.band.height)
        XCTAssertLessThanOrEqual(u.band.maxY, u.keyboardTop)
        XCTAssertGreaterThanOrEqual(u.band.minY, u.picture.maxY)
        // Sides: the trackpad keeps its width either side.
        let left = SessionLayout.Upright(size: safeUpright, keyboardInset: bensKeyboard, side: .left, shape: .sixteenTen)
        XCTAssertEqual(left.trackpad.minX, left.band.minX)
        XCTAssertEqual(left.trackpad.size, u.trackpad.size)
        XCTAssertEqual(left.keys.maxX, left.band.maxX)
    }

    private func ids(_ rows: [[MacKeyboardLayout.Cell]]) -> [[String]] {
        rows.map { $0.map { String($0.id.dropFirst(2)) } }
    }

    /// Normal: the three kept rows; "more": 3 rows of 10, as drawn.
    func testTheKeysAsDrawn() {
        XCTAssertEqual(ids(SixteenTenKeysLayout.rows(functionKeys: false)), [
            ["copy", "paste", "cut", "undo", "redo", "selectall"],
            ["escape", "tab", "left", "up", "down", "right"],
            ["control", "option", "command", "shift", "forwarddelete", "fblock"],
        ])
        let more = ids(SixteenTenKeysLayout.rows(functionKeys: true))
        XCTAssertEqual(more.map(\.count), [10, 10, 10])
        XCTAssertEqual(Set(more.joined()).count, 30)
        XCTAssertEqual(more, [
            ["F1", "F2", "F3", "F4", "F5", "F6", "save", "find", "switchapp", "spotlight"],
            ["F7", "F8", "F9", "F10", "F11", "F12", "close", "quit", "escape", "tab"],
            ["control", "option", "command", "shift", "home", "pageup", "pagedown", "end", "forwarddelete", "fblock"],
        ])
    }

    /// What one press of a cell sends (keys down and up; a shortcut's one press; a modifier's tap and a key after).
    private func sent(_ cell: MacKeyboardLayout.Cell) -> [InputEvent] {
        let r = Recorder()
        let e = MacKeyboardEngine(sink: r)
        switch cell {
        case let .key(k):
            switch k.role {
            case .key: e.keyDown(k); e.keyUp(k)
            case let .modifier(m): e.tapModifier(m); e.keyDown(MacKeyboardLayout.escape); e.keyUp(MacKeyboardLayout.escape)
            default: break
            }
        case let .shortcut(s): e.sendShortcut(s); if s == .switchApp { e.closeAppSwitcher() }
        case .gap: break
        }
        return r.events
    }

    /// Each of the 30 "more" keys and the 18 normal keys sends exactly what its 16:9 counterpart sends.
    func testEachKeySendsWhatItsSixteenNineCounterpartSends() {
        let nine = Array((SpecialKeysLayout.rows(functionKeys: false) + SpecialKeysLayout.rows(functionKeys: true))
            .joined())
        for cell in (SixteenTenKeysLayout.rows(functionKeys: false) + SixteenTenKeysLayout.rows(functionKeys: true))
            .joined() {
            guard let twin = nine.first(where: { $0.id == cell.id }) else { return XCTFail("no 16:9 \(cell.id)") }
            XCTAssertEqual(sent(cell), sent(twin), cell.id)
        }
        // Spot checks: F5 is code 96 with fn; Save is ⌘S.
        let f5 = sent(SpecialKeysLayout.anyCell("F5"))
        XCTAssertEqual(f5.first?.x, 96)
        XCTAssertEqual(f5.first.map { UInt32(bitPattern: Int32($0.a)) & MacKeyFlags.function }, MacKeyFlags.function)
        XCTAssertTrue(sent(SpecialKeysLayout.anyCell("save")).contains { $0.x == 1 })
    }

    /// "…" stays on after other keys are pressed and closes only on a second tap; held modifiers are untouched by
    /// opening or closing.
    func testMoreStaysOnAndLeavesModifiersAlone() {
        let state = KeyboardState(engine: MacKeyboardEngine(sink: Recorder()))
        state.engine.tapModifier(.command)
        state.functionKeys.toggle()                          // … on (KeyCap's tap on "fblock")
        XCTAssertEqual(state.latch(.command), .once, "opening leaves ⌘ held")
        XCTAssertTrue(KeyCap.isLit(SpecialKeysLayout.moreKey, state: state))
        state.engine.tapModifier(.shift)
        state.functionKeys.toggle()                          // … off
        XCTAssertEqual(state.latch(.command), .once, "closing leaves ⌘ held")
        XCTAssertEqual(state.latch(.shift), .once)
        state.functionKeys.toggle()
        guard case let .key(f1) = SpecialKeysLayout.anyCell("F1") else { return XCTFail() }
        state.engine.keyDown(f1); state.engine.keyUp(f1)
        XCTAssertTrue(state.functionKeys, "an F key does not close …")
        XCTAssertEqual(state.latch(.command), .off, "the key used the held modifier, as always")
    }

    /// Third row of the 16:10 click column: Scroll at the screen's outer edge, Right click inside it, on both sides
    /// (the owner 2026-11-21: "The scroll button is more important and should be on the outside.").
    func testScrollIsOnTheOutsideOnBothSides() {
        // Trackpad Right: the column is at the far left, so Scroll is leftmost.
        XCTAssertEqual(ClickButtonsLayout.sixteenTenThirdRow(side: .right), [.scroll, .right])
        // Trackpad Left: the column is at the far right, so Scroll is rightmost.
        XCTAssertEqual(ClickButtonsLayout.sixteenTenThirdRow(side: .left), [.right, .scroll])
        // 16:9 is untouched: Right click above Scroll.
        XCTAssertEqual(ClickButtonsLayout.stack.map(\.button), [.right, .scroll, .left])
    }
}

/// The shape is decided once per shown screen and then held (project notes; the owner: "the size
/// test to see if it should be 1610 or 16:9 needs to run once, not multiple times").
final class LayoutShapeDecisionTests: XCTestCase {
    /// Decided once at the first picture; a later picture size (slow-link halving, a re-fit) does not change it.
    func testDecidedOnceAtFirstPicture() {
        var d = LayoutShapeDecision()
        XCTAssertNotNil(d.firstPicture(width: 1920, height: 1080))
        XCTAssertEqual(d.shape, .sixteenNine)
        XCTAssertNil(d.firstPicture(width: 1680, height: 1050), "a new picture size must not decide again")
        XCTAssertNil(d.firstPicture(width: 958, height: 540))
        XCTAssertEqual(d.shape, .sixteenNine)
        XCTAssertEqual(d.decisions, 1)
    }

    /// The list names the screen; the same screen shown again (a list refresh, the overview) keeps the decision.
    func testSameScreenKeepsIt() {
        var d = LayoutShapeDecision()
        _ = d.firstPicture(width: 1920, height: 1080)
        d.listed(shownID: 1)
        XCTAssertNil(d.shown(id: 1, screenSize: CGSize(width: 1680, height: 1050), pictureWidth: 1680,
                             pictureHeight: 1050, reason: .chosen))
        XCTAssertEqual(d.shape, .sixteenNine)
        XCTAssertEqual(d.decisions, 1)
    }

    /// A screen change decides again, from the Mac screen's own size; back to the first screen decides again.
    func testScreenChangeDecidesAgain() {
        var d = LayoutShapeDecision()
        _ = d.firstPicture(width: 1920, height: 1080)
        d.listed(shownID: 1)
        let line = d.shown(id: 2, screenSize: CGSize(width: 1680, height: 1050), pictureWidth: 1728,
                           pictureHeight: 1080, reason: .crossing)
        XCTAssertEqual(line, "layout shape decided: 16:10 (edge crossing) for screen 2 from screen 1680x1050, picture 1728x1080")
        XCTAssertEqual(d.shape, .sixteenTen)
        XCTAssertNotNil(d.shown(id: 1, screenSize: CGSize(width: 1920, height: 1080), pictureWidth: 1920,
                                pictureHeight: 1080, reason: .chosen))
        XCTAssertEqual(d.shape, .sixteenNine)
        XCTAssertEqual(d.decisions, 3)
        // No list size (an older Host's answer): the picture's.
        _ = d.shown(id: 5, screenSize: nil, pictureWidth: 1728, pictureHeight: 1080, reason: .chosen)
        XCTAssertEqual(d.shape, .sixteenTen)
    }

    /// A rejoin to the same screen keeps it: the new connection's first picture, its list (the Host back on main)
    /// and the switch back to the remembered screen decide nothing.
    func testRejoinToSameScreenKeepsIt() {
        var d = LayoutShapeDecision()
        _ = d.firstPicture(width: 1920, height: 1080)
        d.listed(shownID: 1)
        _ = d.shown(id: 2, screenSize: CGSize(width: 1680, height: 1050), pictureWidth: 1728, pictureHeight: 1080,
                    reason: .chosen)
        // Rejoin: the Host opens on main first.
        XCTAssertNil(d.firstPicture(width: 1920, height: 1080))
        d.listed(shownID: 1)
        XCTAssertNil(d.shown(id: 2, screenSize: CGSize(width: 1680, height: 1050), pictureWidth: 1728,
                             pictureHeight: 1080, reason: .remembered))
        XCTAssertEqual(d.shape, .sixteenTen)
        XCTAssertEqual(d.screenID, 2)
        XCTAssertEqual(d.decisions, 2)
    }
}
