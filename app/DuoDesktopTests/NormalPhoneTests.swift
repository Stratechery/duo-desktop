import CoreGraphics
import UIKit
import XCTest
@testable import DuoDesktop

/// Duo Desktop on a normal iPhone (normal iPhone layout build (change)): the layout arithmetic at three phone
/// widths and the normal-iPhone-vs-Duo decision.
@MainActor
final class NormalPhoneTests: XCTestCase {
    /// The safe area below the top row and the system keyboard's inset, roughly as the simulators report them:
    /// a small phone (375), the drawing's 402 (iPhone 17 Pro), a Max (440).
    let phones: [(name: String, size: CGSize, keyboard: CGFloat)] = [
        ("small 375", CGSize(width: 375, height: 640), 250),
        ("402", CGSize(width: 402, height: 740), 260),
        ("Max 440", CGSize(width: 440, height: 818), 270),
    ]

    func testEveryTouchAreaIs44OrMoreAtThreeWidths() {
        for p in phones {
            let l = NormalPhoneLayout(size: p.size, keyboardInset: p.keyboard)
            XCTAssertGreaterThanOrEqual(l.click.width, 44, p.name)
            XCTAssertGreaterThanOrEqual(l.click.height, 44, p.name)
            XCTAssertGreaterThanOrEqual(l.column.width, 44, p.name)
            XCTAssertGreaterThanOrEqual(l.cellTouchHeight, 44, p.name)
            XCTAssertGreaterThanOrEqual(l.moreKeyTouch.width, 44, p.name)
            XCTAssertGreaterThanOrEqual(l.moreKeyTouch.height, 44, p.name)
            XCTAssertGreaterThan(l.trackpad.width, 150, p.name)
        }
    }

    func testPartsFitTheWidthInTheDrawingsOrder() {
        for p in phones {
            let l = NormalPhoneLayout(size: p.size, keyboardInset: p.keyboard)
            XCTAssertEqual(l.click.minX, NormalPhoneLayout.margin, p.name)          // Click on the outer left edge
            XCTAssertEqual(l.click.height, l.band.height, p.name)                    // full band height
            XCTAssertLessThan(l.click.maxX, l.column.minX, p.name)
            XCTAssertLessThan(l.column.maxX, l.trackpad.minX, p.name)
            XCTAssertEqual(l.trackpad.maxX, p.size.width - NormalPhoneLayout.margin, accuracy: 0.01, p.name)
            XCTAssertEqual(l.cell(2).maxY, l.band.maxY, accuracy: 0.01, p.name)       // Scroll at the bottom
            XCTAssertLessThanOrEqual(l.band.maxY + NormalPhoneLayout.pad, l.keyboardTop + 0.01, p.name)
            XCTAssertEqual(l.picture.width, p.size.width, p.name)
        }
    }

    /// At 402 the drawing's sizes: Click 80, column 50.
    func testDrawingSizesAt402() {
        let l = NormalPhoneLayout(size: CGSize(width: 402, height: 740), keyboardInset: 260)
        XCTAssertEqual(l.clickWidth, 80)
        XCTAssertEqual(l.columnWidth, 50)
        XCTAssertEqual(l.trackpad.width, 402 - 16 - 80 - 6 - 50 - 8)
    }

    /// Square when there is room; otherwise the picture gives way and the band keeps its least height.
    func testPictureGivesWayFirst() {
        let roomy = NormalPhoneLayout(size: CGSize(width: 402, height: 900), keyboardInset: 260)
        XCTAssertTrue(roomy.pictureIsSquare)
        XCTAssertEqual(roomy.picture.height, 402)
        let short = NormalPhoneLayout(size: CGSize(width: 402, height: 600), keyboardInset: 260)
        XCTAssertFalse(short.pictureIsSquare)
        XCTAssertEqual(short.band.height, NormalPhoneLayout.minBand, accuracy: 0.5)
    }

    func testMorePageHasTheModifiersAndAWayBack() {
        let ids = NormalPhoneLayout.moreTable.joined()
        for id in ["control", "option", "command", "shift", "back"] { XCTAssertTrue(ids.contains(id), id) }
        XCTAssertEqual(NormalPhoneLayout.moreTable[1][2], "back")   // the "…" button's spot (row 2, third)
        for id in ids where id != "back" { _ = SpecialKeysLayout.cell(id, functionKeys: false) }
    }

    // MARK: normal iPhone or Duo

    func testDuoIsNeverANormalPhone() {
        XCTAssertFalse(PhoneKind.isNormalPhone(model: "iPhone19,4", idiom: .phone))
    }

    func testOtherIPhonesAreNormal() {
        for m in ["iPhone18,1", "iPhone18,2", "iPhone18,3", "iPhone18,4", "iPhone19,1"] {
            XCTAssertTrue(PhoneKind.isNormalPhone(model: m, idiom: .phone), m)
        }
        XCTAssertFalse(PhoneKind.isNormalPhone(model: "iPad16,1", idiom: .pad))
    }

    /// The tests run on the iPhone Duo simulator: there the app must take the Duo's path.
    func testThisDeviceDecision() {
        let model = PhoneKind.modelIdentifier
        XCTAssertFalse(model.isEmpty)
        XCTAssertEqual(PhoneKind.current, !PhoneKind.duoModels.contains(model))
    }

    /// The Duo's horizontal layout is unchanged when no insets are given.
    func testHorizontalLayoutUnchangedWithoutInsets() {
        let size = CGSize(width: 951, height: 669)
        let a = HorizontalLayout(size: size)
        XCTAssertEqual(a.column.minX, HorizontalLayout.edge)
        XCTAssertEqual(a.trackpad.maxX, size.width - HorizontalLayout.edge)
        let b = HorizontalLayout(size: CGSize(width: 874, height: 402), leadingInset: 62)
        XCTAssertEqual(b.column.minX, HorizontalLayout.edge + 62)
        XCTAssertGreaterThanOrEqual(b.trackpad.width, 44)
        XCTAssertGreaterThanOrEqual(b.frame(.click).height, 44)
    }
}

/// Terminal and JetKVM on a normal iPhone (normal iPhone terminal jetkvm (change)).
@MainActor
final class NormalPhoneViewsTests: XCTestCase {
    func testViewButtonOffersFollowPointerThenTheMacsViews() {
        XCTAssertEqual(SessionView.normalPhoneChoices(terminal: false, jetkvm: false), [.centred])
        var both: [SessionView] = [.centred]
        #if DUO_TERMINAL
        both.append(.terminal)
        XCTAssertEqual(SessionView.normalPhoneChoices(terminal: true, jetkvm: false), [.centred, .terminal])
        #endif
        #if DUO_JETKVM
        both.append(.jetkvm)
        XCTAssertEqual(SessionView.normalPhoneChoices(terminal: false, jetkvm: true), [.centred, .jetkvm])
        #endif
        XCTAssertEqual(SessionView.normalPhoneChoices(terminal: true, jetkvm: true), both)
        // Never Whole Screen; the Duo's own choices unchanged.
        XCTAssertFalse(SessionView.normalPhoneChoices(terminal: true, jetkvm: true).contains(.regular))
        XCTAssertEqual(Array(SessionView.choices(terminal: true, jetkvm: true).prefix(2)), [.regular, .centred])
    }

    func testNameBubbleHasTheRoomTheThreeButtonsTook() {
        // 402 wide: margins 2x16, back 48, ONE view button 48, two spacers 2x12, 8 slack -> 242 (was 146 with three
        // 48 pt view buttons), whatever the Mac offers.
        XCTAssertEqual(NormalPhoneTopRow.nameMax(rowWidth: 402), 242)
        XCTAssertEqual(NormalPhoneTopRow.nameMax(rowWidth: 375), 215)
        XCTAssertEqual(NormalPhoneTopRow.nameMax(rowWidth: 440), 280)
        XCTAssertEqual(NormalPhoneTopRow.nameMax(rowWidth: 200), 80)
    }

    func testTerminalTakesPictureAndBandLessOneRow() {
        for (w, h, kb) in [(375.0, 640.0, 250.0), (402, 740, 260), (440, 818, 270), (402, 600, 300)] {
            let l = NormalPhoneLayout(size: CGSize(width: w, height: h), keyboardInset: kb)
            let t = l.terminalHeight(keysRow: 44)
            // The row of keys ends where the band ends (on the keyboard, one pad above it).
            let rowTop = l.band.minY + l.terminalKeysTop(keysRow: 44)
            XCTAssertEqual(rowTop + 44, l.band.maxY, accuracy: 0.01)
            XCTAssertEqual(t, l.picture.height + l.band.height - 44, accuracy: 0.01)
            // One pad between the terminal and the row; nothing overlaps.
            XCTAssertEqual(rowTop - t, NormalPhoneLayout.pad, accuracy: 0.01)
            XCTAssertGreaterThan(t, l.picture.height)
            // The band's panel starts where the terminal ends, never over it (build 51 started it at the picture's
            // bottom edge and hid the terminal's last rows).
            XCTAssertEqual(l.terminalPanelTop(keysRow: 44), t, accuracy: 0.01)
            XCTAssertEqual(l.terminalPanelTop(keysRow: 44) + NormalPhoneLayout.pad, rowTop, accuracy: 0.01)
        }
    }
}

/// normal iPhone view menu (change): on a normal iPhone the view switch is one button that opens a menu.
@MainActor
final class NormalPhoneViewMenuTests: XCTestCase {
    func titles(_ items: [ViewMenuButton.Item]) -> [String] { items.map(\.title) }

    func testMenuContentsPerSwitchCombination() {
        // Neither switch: one view, so the button is plain and opens nothing.
        let none = SessionView.normalPhoneChoices(terminal: false, jetkvm: false)
        XCTAssertFalse(ViewMenuButton.opensMenu(none))
        XCTAssertEqual(ViewMenuButton.items(choices: none, current: .centred), [])
        XCTAssertEqual(ViewMenuButton.shown(choices: none, current: .centred), .centred)
        #if DUO_TERMINAL
        let t = SessionView.normalPhoneChoices(terminal: true, jetkvm: false)
        XCTAssertEqual(ViewMenuButton.items(choices: t, current: .terminal), [
            .init(view: .centred, title: "Follow Pointer", symbol: "scope", checked: false),
            .init(view: .terminal, title: "Terminal", symbol: "apple.terminal", checked: true),
        ])
        #endif
        #if DUO_JETKVM
        let j = SessionView.normalPhoneChoices(terminal: false, jetkvm: true)
        XCTAssertEqual(ViewMenuButton.items(choices: j, current: .centred), [
            .init(view: .centred, title: "Follow Pointer", symbol: "scope", checked: true),
            .init(view: .jetkvm, title: "JetKVM", symbol: "cable.connector", checked: false),
        ])
        #endif
        #if DUO_TERMINAL && DUO_JETKVM
        let both = SessionView.normalPhoneChoices(terminal: true, jetkvm: true)
        let items = ViewMenuButton.items(choices: both, current: .jetkvm)
        XCTAssertEqual(titles(items), ["Follow Pointer", "Terminal", "JetKVM"])
        XCTAssertEqual(items.filter(\.checked).map(\.view), [.jetkvm])
        #endif
        // Never Whole Screen in the menu; exactly one row checked whenever there is a menu.
        for tOn in [false, true] { for jOn in [false, true] {
            let c = SessionView.normalPhoneChoices(terminal: tOn, jetkvm: jOn)
            for cur in c {
                let items = ViewMenuButton.items(choices: c, current: cur)
                XCTAssertFalse(items.contains { $0.view == .regular })
                if ViewMenuButton.opensMenu(c) { XCTAssertEqual(items.filter(\.checked).count, 1) }
            }
        } }
    }

    func testButtonShowsFirstChoiceWhenCurrentIsNotOffered() {
        XCTAssertEqual(ViewMenuButton.shown(choices: [.centred], current: .regular), .centred)
    }
}

/// normal iPhone own keyboard (change): upright on a normal iPhone, our own keyboard (the sideways view's
/// `TouchKeyboardView`, portrait sizes) replaces the system keyboard in the Mac and JetKVM views, so the picture is
/// square. Heights are the space between the system top row and the home indicator: measured on the iPhone 18 Pro
/// simulator (874 tall, top row ends at 116, home indicator 34: 724); the 375 (812-tall mini) and 440 (956-tall
/// Max) ones use the same bars.
@MainActor
final class NormalPhoneOwnKeyboardTests: XCTestCase {
    func layout(_ w: CGFloat, _ h: CGFloat) -> NormalPhoneLayout {
        NormalPhoneLayout(size: CGSize(width: w, height: h),
                          keyboardInset: NormalPhoneLayout.ownKeyboardHeight(width: w), keyboardGap: 0)
    }

    func testPictureIsSquareAt402() {
        let l = layout(402, 874 - 116 - 34)
        XCTAssertEqual(l.picture.size, CGSize(width: 402, height: 402))
        XCTAssertTrue(l.pictureIsSquare)
        XCTAssertEqual(l.band.height, NormalPhoneLayout.minBand, accuracy: 0.5)       // 126, as drawn
        XCTAssertEqual(l.band.maxY, l.keyboardTop, accuracy: 0.5)
    }

    func testSizesAt375And440() {
        let small = layout(375, 812 - 104 - 34)                // picture gives way first
        XCTAssertEqual(small.picture.width, 375)
        XCTAssertEqual(small.picture.height, 352)
        XCTAssertEqual(small.band.height, NormalPhoneLayout.minBand, accuracy: 0.5)
        let max = layout(440, 956 - 116 - 34)
        XCTAssertEqual(max.picture.size, CGSize(width: 440, height: 440))
    }

    func testKeyboardIs190TallAtEveryWidth() {
        for w: CGFloat in [375, 402, 440] { XCTAssertEqual(NormalPhoneLayout.ownKeyboardHeight(width: w), 190) }
    }

    /// The drawing's keys at 402: 34.2 x 40; every key's touch area (the key and half of each gap) 48 tall; the
    /// wide keys 44 wide or more; the ten-across letter row 40.2 wide (as Apple's own keyboard: ten 44 pt keys need
    /// 440 pt). The band's touch areas are covered by `NormalPhoneTests` (44 or more).
    func testKeySizesAndTouchAreas() {
        let s = TouchKeyboardLayout.Sizes.portrait
        for w: CGFloat in [375, 402, 440] {
            for page in [TouchKeyboardLayout.Page.letters, .numbers, .symbols] {
                let frames = TouchKeyboardLayout.frames(page, width: w, sizes: s)
                for f in frames {
                    let t = TouchKeyboardLayout.touchArea(f.frame, width: w, sizes: s)
                    XCTAssertGreaterThanOrEqual(t.height, 48 - 0.01, "\(f.key.id) \(w)")
                    XCTAssertGreaterThanOrEqual(t.width, 40.2 * w / 402 - 0.01, "\(f.key.id) \(w)")
                    if case .char = f.key {} else { XCTAssertGreaterThanOrEqual(t.width, 44, "\(f.key.id) \(w)") }
                    XCTAssertGreaterThanOrEqual(f.frame.minX, 0)
                    XCTAssertLessThanOrEqual(f.frame.maxX, w + 0.01)
                    XCTAssertLessThanOrEqual(f.frame.maxY, NormalPhoneLayout.ownKeyboardHeight(width: w) + 0.01)
                }
            }
        }
        let q = TouchKeyboardLayout.frames(.letters, width: 402, sizes: s).first { $0.key == .char("q") }!.frame
        XCTAssertEqual(q.width, 34.2, accuracy: 0.01)
        XCTAssertEqual(q.height, 40)
        XCTAssertEqual(q.minY, 6)
    }

    /// Sideways is unchanged: the default sizes give the same frames and height as before.
    func testSidewaysKeyboardUnchanged() {
        XCTAssertEqual(TouchKeyboardLayout.Sizes.sideways.drawnWidth, HorizontalLayout.uprightWidth)
        let w: CGFloat = 589
        XCTAssertEqual(TouchKeyboardLayout.height(width: w),
                       (8 + 4 * 49 + 3 * (63.8 - 49) + 12) * w / HorizontalLayout.uprightWidth, accuracy: 0.001)
        let q = TouchKeyboardLayout.frames(.letters, width: w).first { $0.key == .char("q") }!.frame
        XCTAssertEqual(q.height, 49 * w / HorizontalLayout.uprightWidth, accuracy: 0.001)
    }
}
