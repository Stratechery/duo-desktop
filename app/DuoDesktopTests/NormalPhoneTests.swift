import CoreGraphics
import SwiftUI
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
            .init(view: .jetkvm, title: "JetKVM", symbol: "mediastick", checked: false),
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

/// The wide sideways trackpad on a normal iPhone.
final class SidewaysWidePadTests: XCTestCase {
    /// Each class of supported iPhone held sideways: screen in points, the Dynamic Island's (or notch's) inset on
    /// one side, and points per millimetre (dpi / scale / 25.4).
    static let phones: [(name: String, size: CGSize, inset: CGFloat, ptPerMM: CGFloat)] = [
        ("iPhone SE (narrowest)", CGSize(width: 667, height: 375), 0, 326 / 2 / 25.4),
        ("iPhone 16e", CGSize(width: 844, height: 390), 47, 460 / 3 / 25.4),
        ("iPhone 18 Pro", CGSize(width: 874, height: 402), 62, 460 / 3 / 25.4),
        ("iPhone 18 Pro Max", CGSize(width: 956, height: 440), 62, 460 / 3 / 25.4),
    ]
    static let duo = CGSize(width: 951, height: 669)
    static let duoPtPerMM: CGFloat = 460 / 3 / 25.4

    func testWidePadOnEveryNormalIPhone() {
        let duoPad = HorizontalLayout(size: Self.duo).trackpad
        for p in Self.phones {
            for side in [TrackpadSide.right, .left] {
                for (lead, trail) in [(p.inset, CGFloat(0)), (0, p.inset)] {
                    let l = HorizontalLayout(size: p.size, side: side, leadingInset: lead, trailingInset: trail,
                                             normalPhone: true)
                    let pad = l.trackpad, column = l.column
                    // The upright pad the owner accepted on the same phone (upper bound: the whole long side as height).
                    let upright = NormalPhoneLayout(size: CGSize(width: p.size.height, height: p.size.width),
                                                    keyboardInset: NormalPhoneLayout.ownKeyboardHeight(width: p.size.height),
                                                    keyboardGap: 0).trackpad
                    XCTAssertGreaterThanOrEqual(pad.width, upright.width, p.name)
                    // (No height bound against the upright pad any more: build 58 makes the height the column's.)
                    XCTAssertGreaterThanOrEqual(pad.width / p.ptPerMM, duoPad.width / Self.duoPtPerMM, p.name)
                    // Build 58: top level with the top of Keyboard, bottom level with the bottom of Click, exactly the
                    // column's height; 3:2.
                    XCTAssertEqual(pad.minY, column.minY, p.name)
                    XCTAssertEqual(pad.maxY, column.maxY, p.name)
                    XCTAssertEqual(pad.minY, l.frame(.keyboard).minY, p.name)
                    XCTAssertEqual(pad.maxY, l.frame(.click).maxY, p.name)
                    XCTAssertEqual(pad.width, (pad.height * HorizontalLayout.wideAspect).rounded(.down), p.name)
                    // On its side at the screen's edge (clear of the island), never over the column.
                    if side == .right {
                        XCTAssertEqual(pad.maxX, p.size.width - HorizontalLayout.edge - trail, p.name)
                        XCTAssertGreaterThanOrEqual(pad.minX, column.maxX + HorizontalLayout.gap, p.name)
                    } else {
                        XCTAssertEqual(pad.minX, HorizontalLayout.edge + lead, p.name)
                        XCTAssertLessThanOrEqual(pad.maxX, column.minX - HorizontalLayout.gap, p.name)
                    }
                    // The column (and so Click on the outside) is where it was.
                    XCTAssertEqual(column, HorizontalLayout(size: p.size, side: side, leadingInset: lead,
                                                            trailingInset: trail).column, p.name)
                    print(String(format: "wide pad %@ %@: %.0f x %.0f pt = %.1f x %.1f mm", p.name,
                                 side == .right ? "right" : "left", pad.width, pad.height,
                                 pad.width / p.ptPerMM, pad.height / p.ptPerMM))
                }
            }
        }
    }

    /// The Duo's sideways layout does not change (its pad, column and keyboard), whatever the keyboard does.
    func testDuoUnchanged() {
        for typing in [false, true] {
            let l = HorizontalLayout(size: Self.duo, side: .right, typing: typing)
            XCTAssertEqual(l.trackpad.width, 250, accuracy: 0.01)
            XCTAssertEqual(l.trackpad.maxX, Self.duo.width - HorizontalLayout.edge)
            XCTAssertEqual(l.trackpad.minY, l.column.minY)
        }
    }

    /// Keyboard up on a normal iPhone: the pad goes back to the room beside our keyboard, as before.
    func testKeyboardUpKeepsTheOldRule() {
        let size = CGSize(width: 874, height: 402)
        let up = HorizontalLayout(size: size, leadingInset: 62, normalPhone: true, typing: true)
        let before = HorizontalLayout(size: size, leadingInset: 62)
        XCTAssertEqual(up.trackpad, before.trackpad)
        XCTAssertEqual(up.keyboard, before.keyboard)
    }
}

/// Before/after pictures of the sideways controls on a normal iPhone (rendered, not the app on a phone): the phone's
/// outline and Dynamic Island are drawn as guides. Run with TEST_RUNNER_DUO_SNAPSHOT_DIR set.
@MainActor
final class SidewaysWidePadSnapshotTests: XCTestCase {
    func testRenderBeforeAndAfter() throws {
        guard let dir = ProcessInfo.processInfo.environment["DUO_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_DUO_SNAPSHOT_DIR to render")
        }
        let mac = try XCTUnwrap(UIImage(contentsOfFile: dir + "/" + (ProcessInfo.processInfo.environment["DUO_SNAPSHOT_MAC"] ?? "mac-1920x1200.png")))
        let out = dir + "/normal-phone/sideways-pad-58/"
        try FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let phones: [(String, CGSize, CGFloat, CGFloat, Bool)] = [   // name, size, island inset, corner radius, island
            ("18pro", CGSize(width: 874, height: 402), 62, 55, true),
            ("se", CGSize(width: 667, height: 375), 0, 0, false),
            ("duo", CGSize(width: 951, height: 669), 0, 59, false),
        ]
        for (phone, size, inset, radius, island) in phones {
            for canvasH in [1200, 1080] {
                for (state, wide, typing) in [("before", false, false), ("after", true, false), ("after-keyboard", true, true)] {
                    if phone == "duo" && state != "after" { continue }
                    if typing && canvasH == 1080 { continue }
                    let layout = HorizontalLayout(size: size, side: .right, leadingInset: inset,
                                                  normalPhone: wide && phone != "duo", typing: typing)
                    let parts = SessionParts(sink: Recorder())
                    let kb = TouchKeyboardModel(engine: parts.keyboard.engine)
                    let fit = PictureFit.frame(canvasWidth: 1920, canvasHeight: canvasH, in: size, screenScale: 3)
                    let picture = canvasH == 1080
                        ? UIImage(cgImage: try XCTUnwrap(mac.cgImage?.cropping(to: CGRect(x: 0, y: 0, width: 1920, height: 1080))))
                        : mac
                    let view = ZStack(alignment: .topLeading) {
                        Color.black
                        Image(uiImage: picture).resizable()
                            .frame(width: fit.width, height: fit.height).offset(x: fit.minX, y: fit.minY)
                        HorizontalControls(model: SessionModel.app, parts: parts, keyboard: kb, layout: layout,
                                           typing: .constant(typing))
                        if island {
                            Capsule().fill(Color.black).frame(width: 37, height: 126)
                                .offset(x: 11, y: (size.height - 126) / 2)
                        }
                    }
                    .frame(width: size.width, height: size.height, alignment: .topLeading)
                    .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .containerShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                    .padding(12).background(Color(white: 0.75))
                    let full = CGSize(width: size.width + 24, height: size.height + 24)
                    let host = UIHostingController(rootView: view.ignoresSafeArea())
                    host.safeAreaRegions = []
                    let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
                    let window = UIWindow(windowScene: scene)
                    window.frame = CGRect(origin: .zero, size: full)
                    window.windowLevel = .alert + 1
                    window.rootViewController = host
                    window.makeKeyAndVisible()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.8))
                    host.view.layoutIfNeeded()
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 2
                    let image = UIGraphicsImageRenderer(size: full, format: format).image { _ in
                        host.view.drawHierarchy(in: CGRect(origin: .zero, size: full), afterScreenUpdates: true)
                    }
                    let aspect = canvasH == 1200 ? "16x10" : "16x9"
                    try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: out + "\(phone)-\(aspect)-\(state).png"))
                    window.isHidden = true
                }
            }
        }
    }
}
