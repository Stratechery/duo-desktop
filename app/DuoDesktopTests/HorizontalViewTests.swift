import CoreGraphics
import SwiftUI
import UIKit
import GlassActSession
import XCTest
@testable import DuoDesktop

/// The horizontal view (project notes, round 4, 589 pt): one test per claim.
@MainActor
final class HorizontalViewTests: XCTestCase {
    let open = CGSize(width: 951, height: 669)

    /// The Mac picture fills the whole screen, never stretched: 1920x1080 → 951 x 535 with 67 pt bars;
    /// 1920x1200 → 951 x 594 with 37 pt bars.
    func testFitAt1080And1200() {
        let a = PictureFit.frame(canvasWidth: 1920, canvasHeight: 1080, in: open, screenScale: 3)
        XCTAssertEqual(a.width, 951, accuracy: 0.01)
        XCTAssertEqual(a.height, 951 * 1080 / 1920, accuracy: 0.01)
        XCTAssertEqual(a.minY, 67, accuracy: 0.5)
        let b = PictureFit.frame(canvasWidth: 1920, canvasHeight: 1200, in: open, screenScale: 3)
        XCTAssertEqual(b.width, 951, accuracy: 0.01)
        XCTAssertEqual(b.height, 951 * 1200 / 1920, accuracy: 0.01)
        XCTAssertEqual(b.minY, 37, accuracy: 0.5)
        XCTAssertEqual(a.width / a.height, 1920.0 / 1080.0, accuracy: 0.001, "not stretched")
        XCTAssertEqual(b.width / b.height, 1920.0 / 1200.0, accuracy: 0.001, "not stretched")
    }

    /// The column and the trackpad: the mockup's sizes and places, the same in both states (the layout has no
    /// keyboard input: only the key row and keyboard appear between them). Keyboard 589 wide between them.
    func testColumnAndPadFrames() {
        let l = HorizontalLayout(size: open, side: .right)
        XCTAssertEqual(l.column.minX, 10)
        XCTAssertEqual(l.column.width, 76)
        XCTAssertEqual(l.trackpad.width, 250, accuracy: 0.01)
        XCTAssertEqual(l.trackpad.height, 251, accuracy: 1.5)
        XCTAssertEqual(l.trackpad.maxX, 941, accuracy: 0.01)
        XCTAssertEqual(l.column.minY, l.trackpad.minY)
        XCTAssertEqual(l.column.maxY, 657, accuracy: 0.01)
        XCTAssertEqual(l.panelTop, 396, accuracy: 1.5)
        XCTAssertEqual(l.frame(.keyboard).height, 44)
        XCTAssertEqual(l.frame(.right).minY - l.frame(.keyboard).maxY, 6)
        XCTAssertEqual(l.frame(.click).height, 101, accuracy: 1.5)
        XCTAssertEqual(l.frame(.click).maxY, l.column.maxY)
        XCTAssertEqual(l.keyboard.minX, 94)
        XCTAssertEqual(l.keyboard.width, 589)
        XCTAssertEqual(l.keyboard.maxY, 669, accuracy: 0.01)
        XCTAssertEqual(l.trackpad.minX - l.keyboard.maxX, 8, accuracy: 0.01)
        XCTAssertLessThanOrEqual(l.keyRow.maxY, l.keyboard.minY + 0.01)
    }

    /// Trackpad Left swaps column and pad; the keyboard sits off centre the other way; the row keeps its order and
    /// the column its top-to-bottom order.
    func testSidesSwap() {
        let r = HorizontalLayout(size: open, side: .right), l = HorizontalLayout(size: open, side: .left)
        XCTAssertEqual(l.trackpad.minX, 10)
        XCTAssertEqual(l.column.maxX, 941)
        XCTAssertEqual(l.keyboard.minX, 268, accuracy: 0.01)
        XCTAssertLessThan(r.keyboard.midX, open.width / 2)
        XCTAssertGreaterThan(l.keyboard.midX, open.width / 2)
        XCTAssertEqual(r.trackpad.size, l.trackpad.size)
        for side in [r, l] {
            let ys = HorizontalLayout.Button.allCases.map { side.frame($0).minY }
            XCTAssertEqual(ys, ys.sorted(), "Keyboard, Right click, Scroll, Click top to bottom")
        }
        XCTAssertEqual(HorizontalLayout.rowKeys.map(\.id),
                       ["escape", "tab", "control", "option", "command", "shift", "left", "up", "down", "right",
                        "forwarddelete"])
    }

    /// Our keyboard: the upright proportions scaled to 589 (letter key 47.1 x 43.1), every key inside the keyboard,
    /// no two overlapping, on every page.
    func testKeyboardGeometry() {
        let w: CGFloat = 589, h = TouchKeyboardLayout.height(width: w)
        XCTAssertEqual(h, 260.4 * w / 669, accuracy: 0.1)
        for page in [TouchKeyboardLayout.Page.letters, .numbers, .symbols] {
            let f = TouchKeyboardLayout.frames(page, width: w)
            for a in f {
                XCTAssertTrue(CGRect(x: 0, y: 0, width: w, height: h).insetBy(dx: -0.01, dy: -0.01).contains(a.frame),
                              "\(page) \(a.key.id)")
                for b in f where b.key.id != a.key.id {
                    XCTAssertFalse(a.frame.insetBy(dx: 0.5, dy: 0.5).intersects(b.frame), "\(a.key.id) vs \(b.key.id)")
                }
            }
        }
        let q = TouchKeyboardLayout.frames(.letters, width: w).first { $0.key == .char("q") }!.frame
        XCTAssertEqual(q.width, 47.1, accuracy: 0.05)
        XCTAssertEqual(q.height, 43.1, accuracy: 0.05)
    }

    /// Every key of our keyboard sends the US key code the upright view sends for that character: every letter
    /// (plain and with shift), every 123 and #+= key, space, return and delete.
    func testEveryKeySendsTheRightCode() {
        let r = Recorder()
        let m = TouchKeyboardModel(engine: MacKeyboardEngine(sink: r))
        func sent(_ key: TouchKey) -> [InputEvent] {
            r.events.removeAll()
            m.lifted(key)
            return r.events
        }
        for page in [TouchKeyboardLayout.Page.letters, .numbers, .symbols] {
            m.page = page
            for row in TouchKeyboardLayout.rows(page) {
                for case let .char(c) in row {
                    let want = MacTyping.keys[c]!
                    let e = sent(.char(c))
                    XCTAssertEqual(e.map(\.x), [Int(want.code), Int(want.code)], "\(c)")
                    XCTAssertEqual(UInt32(truncatingIfNeeded: e[0].a), want.ownFlags, "\(c) flags")
                }
            }
        }
        // Shift: the next letter is capital (shift flag), then shift lets go.
        m.page = .letters
        m.tapShift(at: 100)
        var e = sent(.char("a"))
        XCTAssertEqual(e[0].x, 0)
        XCTAssertEqual(UInt32(truncatingIfNeeded: e[0].a) & MacKeyFlags.shift, MacKeyFlags.shift)
        XCTAssertEqual(m.shift, .off)
        e = sent(.char("a"))
        XCTAssertEqual(UInt32(truncatingIfNeeded: e[0].a) & MacKeyFlags.shift, 0)
        // Double tap = caps lock: stays on.
        m.tapShift(at: 200); m.tapShift(at: 200.2)
        XCTAssertEqual(m.shift, .locked)
        _ = sent(.char("b"))
        XCTAssertEqual(m.shift, .locked)
        // Space, return; the page keys send nothing and change the page.
        XCTAssertEqual(sent(.space).map(\.x), [49, 49])
        XCTAssertEqual(sent(.ret).map(\.x), [36, 36])
        // (Since build 36 the page keys act on touch down, as the system's.)
        r.events.removeAll()
        m.touchDown(.page(.numbers))
        XCTAssertEqual(r.events.count, 0)
        XCTAssertEqual(m.page, .numbers)
        XCTAssertNil(MacTyping.keys["€"], "why #+= carries US keys instead")
    }

    /// A modifier held from the row applies to the next key of our keyboard (⌘ + a = ⌘A), then lets go.
    func testRowModifierAppliesToOurKeys() {
        let r = Recorder()
        let engine = MacKeyboardEngine(sink: r)
        let m = TouchKeyboardModel(engine: engine)
        engine.tapModifier(.command)
        m.lifted(.char("a"))
        let aDown = r.events.first { $0.kind == InputKind.keyDown && $0.x == 0 }!
        XCTAssertEqual(UInt32(truncatingIfNeeded: aDown.a) & KeyMap.Modifier.command.eventFlags,
                       KeyMap.Modifier.command.eventFlags)
        XCTAssertEqual(engine.latch(of: .command), .off)
    }

    /// Keyboard up: the view keeps the scale and moves so the pointer sits mid-way above the key row; it stops at
    /// the Mac screen's top (no move) and bottom (the picture's bottom at the row).
    func testFollowRule() {
        let fit = PictureFit.frame(canvasWidth: 1920, canvasHeight: 1080, in: open, screenScale: 3)
        let visible: CGFloat = 396
        // Middle of the Mac screen: lands at visible/2.
        let mid = TypingFollow.offset(pointerY: 540, canvasHeight: 1080, fit: fit, visibleHeight: visible)
        XCTAssertEqual(fit.minY + 540 * fit.height / 1080 + mid, visible / 2, accuracy: 0.01)
        // Top: no move.
        XCTAssertEqual(TypingFollow.offset(pointerY: 0, canvasHeight: 1080, fit: fit, visibleHeight: visible), 0)
        // Bottom: the picture's bottom edge sits at the row's top, no further.
        let low = TypingFollow.offset(pointerY: 1079, canvasHeight: 1080, fit: fit, visibleHeight: visible)
        XCTAssertEqual(fit.maxY + low, visible, accuracy: 0.01)
    }
}

/// Rendered pictures of the horizontal view at the open Duo's sideways size (951 x 669), light and dark, both states
/// and both sides, over a real Mac screenshot (the simulator cannot be turned sideways from code: scene error 101).
/// Only when `TEST_RUNNER_DUO_SNAPSHOT_DIR` is set.
@MainActor
final class HorizontalSnapshotTests: XCTestCase {
    func testRenderStates() throws {
        guard let dir = ProcessInfo.processInfo.environment["DUO_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_DUO_SNAPSHOT_DIR to render")
        }
        let mac = try XCTUnwrap(UIImage(contentsOfFile: dir + "/" + (ProcessInfo.processInfo.environment["DUO_SNAPSHOT_MAC"] ?? "mac-1920x1200.png")))
        let size = CGSize(width: 951, height: 669)
        for (name, scheme, typing, side, canvasH) in [
            ("full-light", UIUserInterfaceStyle.light, false, TrackpadSide.right, 1080),
            ("full-dark", .dark, false, .right, 1080),
            ("keyboard-light", .light, true, .right, 1080),
            ("keyboard-dark", .dark, true, .right, 1080),
            ("keyboard-trackpad-left-light", .light, true, .left, 1080),
            ("full-trackpad-left-light", .light, false, .left, 1080),
            ("full-16x10-light", .light, false, .right, 1200),
        ] as [(String, UIUserInterfaceStyle, Bool, TrackpadSide, Int)] {
            let layout = HorizontalLayout(size: size, side: side)
            let parts = SessionParts(sink: Recorder())
            let kb = TouchKeyboardModel(engine: parts.keyboard.engine)
            let fit = PictureFit.frame(canvasWidth: 1920, canvasHeight: canvasH, in: size, screenScale: 3)
            // Keyboard up: the pointer in the Mac screen's lower part (y 900) so the follow rule shows its move.
            let dy = typing ? TypingFollow.offset(pointerY: CGFloat(canvasH) * 0.83, canvasHeight: canvasH, fit: fit,
                                                  visibleHeight: layout.panelTop) : 0
            let picture = canvasH == 1080 ? mac.cropped(height: 1080) : mac
            let view = ZStack(alignment: .topLeading) {
                Color.black
                Image(uiImage: picture).resizable()
                    .frame(width: fit.width, height: fit.height)
                    .offset(x: fit.minX, y: fit.minY + dy)
                HorizontalControls(model: SessionModel.app, parts: parts, keyboard: kb, layout: layout,
                                   typing: .constant(typing))
            }
            .frame(width: size.width, height: size.height)
            .ignoresSafeArea()
            let host = UIHostingController(rootView: view)
            host.safeAreaRegions = []
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.windowLevel = .alert + 1
            window.overrideUserInterfaceStyle = scheme
            let root = UIViewController()
            window.rootViewController = root
            window.makeKeyAndVisible()
            root.addChild(host)
            root.view.addSubview(host.view)
            host.view.translatesAutoresizingMaskIntoConstraints = true
            host.view.autoresizingMask = []
            host.view.frame = CGRect(origin: .zero, size: size)
            host.didMove(toParent: root)
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            host.view.layoutIfNeeded()
            print("snapshot window", window.bounds, "host", host.view.frame)
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: dir + "/horizontal-build-\(name)-2026-11-21.png"))
            window.isHidden = true
        }
    }
}

private extension UIImage {
    func cropped(height: Int) -> UIImage {
        guard let cg = cgImage?.cropping(to: CGRect(x: 0, y: 0, width: cg_w, height: height)) else { return self }
        return UIImage(cgImage: cg)
    }
    var cg_w: Int { cgImage?.width ?? 0 }
}

/// Proof renders for the clear controls and the screen-corner shapes (2026-11-21 leftovers order). The simulator
/// cannot show the Duo's physical corner, so its curve is drawn as a red guide line here only, at the display's own
/// corner radius (read from the simulator's screen for the proof; the app itself uses `ConcentricRectangle`).
@MainActor
final class HorizontalClearSnapshotTests: XCTestCase {
    func testRenderClearControls() throws {
        guard let dir = ProcessInfo.processInfo.environment["DUO_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_DUO_SNAPSHOT_DIR to render")
        }
        let size = CGSize(width: 951, height: 669)
        let radius = (UIScreen.main.value(forKey: "_displayCornerRadius") as? CGFloat) ?? 0
        print("display corner radius", radius)
        try "\(radius)\n".write(toFile: dir + "/display-corner-radius.txt", atomically: true, encoding: .utf8)
        for (name, scheme, white, side, typing) in [
            ("white-light", UIUserInterfaceStyle.light, true, TrackpadSide.right, false),
            ("white-dark", .dark, true, .right, false),
            ("dark-light", .light, false, .right, false),
            ("dark-dark", .dark, false, .right, false),
            ("white-light-trackpad-left", .light, true, .left, false),
            ("keyboard-light", .light, true, .right, true),
            ("keyboard-dark", .dark, false, .right, true),
        ] as [(String, UIUserInterfaceStyle, Bool, TrackpadSide, Bool)] {
            let layout = HorizontalLayout(size: size, side: side)
            let parts = SessionParts(sink: Recorder())
            let kb = TouchKeyboardModel(engine: parts.keyboard.engine)
            let pad = layout.trackpad, scroll = layout.frame(.scroll)
            let view = ZStack(alignment: .topLeading) {
                (white ? Color.white : Color(white: 0.1))
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(0..<40) { i in
                        Text("Mac window text line \(i) — the pointer and this text must stay sharp under the controls")
                            .font(.system(size: 13)).foregroundStyle(white ? Color.black : Color.white)
                    }
                }.padding(8)
                pointer.offset(x: pad.midX, y: pad.midY)
                pointer.offset(x: scroll.midX - 4, y: scroll.minY + 8)
                HorizontalControls(model: SessionModel.app, parts: parts, keyboard: kb, layout: layout,
                                   typing: .constant(typing))
                RoundedRectangle(cornerRadius: radius, style: .continuous).stroke(Color.red, lineWidth: 1)
                    .frame(width: size.width, height: size.height).allowsHitTesting(false)
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipped()
            .containerShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            let image = try render(view, size: size, scheme: scheme)
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: dir + "/clear-\(name).png"))
            // Close-ups of the two bottom corners (130 x 130 pt, at 3x).
            for (corner, x) in [("bottom-left", 0.0), ("bottom-right", size.width - 130)] {
                let crop = CGRect(x: x * 3, y: (size.height - 130) * 3, width: 390, height: 390)
                let cg = try XCTUnwrap(image.cgImage?.cropping(to: crop))
                try XCTUnwrap(UIImage(cgImage: cg).pngData())
                    .write(to: URL(fileURLWithPath: dir + "/clear-\(name)-\(corner).png"))
            }
        }
    }

    /// A Mac pointer: black arrow with a white edge, as macOS draws it.
    private var pointer: some View {
        ZStack {
            Image(systemName: "cursorarrow").font(.system(size: 30, weight: .black)).foregroundStyle(.white)
            Image(systemName: "cursorarrow").font(.system(size: 24, weight: .regular)).foregroundStyle(.black)
        }
    }

    private func render(_ view: some View, size: CGSize, scheme: UIUserInterfaceStyle) throws -> UIImage {
        let host = UIHostingController(rootView: view.ignoresSafeArea())
        host.safeAreaRegions = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = scheme
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        root.addChild(host)
        root.view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = true
        host.view.autoresizingMask = []
        host.view.frame = CGRect(origin: .zero, size: size)
        host.didMove(toParent: root)
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        window.isHidden = true
        return image
    }
}
