import SwiftUI
import UIKit
import GlassActSession
import XCTest
@testable import DuoDesktop

/// Our keys give the system keyboard's feedback (project notes): one test per rule.
@MainActor
final class KeyFeedbackTests: XCTestCase {
    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: KeyFeedback.hapticsKey)
        KeyFeedback.playClick = { UIDevice.current.playInputClick() }
    }

    /// Characters, space and return act on the lift; delete, shift and the page keys on touch down.
    func testEdges() {
        XCTAssertEqual(KeyPressRules.edge(.char("a")), .up)
        XCTAssertEqual(KeyPressRules.edge(.space), .up)
        XCTAssertEqual(KeyPressRules.edge(.ret), .up)
        XCTAssertEqual(KeyPressRules.edge(.delete), .down)
        XCTAssertEqual(KeyPressRules.edge(.shift), .down)
        XCTAssertEqual(KeyPressRules.edge(.page(.numbers)), .down)

        let r = Recorder()
        let m = TouchKeyboardModel(engine: MacKeyboardEngine(sink: r))
        m.touchDown(.char("a"))
        XCTAssertTrue(r.events.isEmpty, "a letter sends nothing on touch down")
        m.lifted(.char("a"))
        XCTAssertEqual(r.events.count, 2, "the letter types on the lift")

        m.touchDown(.shift)
        XCTAssertEqual(m.shift, .once, "shift acts on touch down")
        m.lifted(.shift)
        XCTAssertEqual(m.shift, .once, "and nothing more on the lift")

        m.touchDown(.page(.numbers))
        XCTAssertEqual(m.page, .numbers, "123 switches on touch down")

        r.events.removeAll()
        m.touchDown(.delete)
        XCTAssertEqual(r.events.map(\.kind), [InputKind.keyDown], "delete goes down on touch down")
        m.lifted(.delete)
        XCTAssertEqual(r.events.map(\.kind), [InputKind.keyDown, InputKind.keyUp])
        // The upright and row Mac keys: a modifier latches on down, "more" waits for the lift.
        XCTAssertEqual(KeyCap.edge(MacKeyboardLayout.commandKey), .down)
        XCTAssertEqual(KeyCap.edge(MacKeyboardLayout.escape), .down)
    }

    /// A finger that slides off a character key takes it back: nothing is typed.
    func testSlideOffCancels() {
        let size = CGSize(width: 47, height: 43)
        XCTAssertTrue(KeyPressRules.inside(CGPoint(x: 20, y: 20), size: size))
        XCTAssertTrue(KeyPressRules.inside(CGPoint(x: -7, y: 50), size: size), "within the slop")
        XCTAssertFalse(KeyPressRules.inside(CGPoint(x: 20, y: -30), size: size))
        XCTAssertFalse(KeyPressRules.inside(CGPoint(x: 60, y: 20), size: size))

        let r = Recorder()
        let m = TouchKeyboardModel(engine: MacKeyboardEngine(sink: r))
        for key in [TouchKey.char("q"), .space, .ret] {
            m.touchDown(key)
            m.lifted(key, onKey: false)
        }
        XCTAssertTrue(r.events.isEmpty)
    }

    /// Delete repeats as before: first repeat 0.5 s after the press, then every 0.05 s.
    func testRepeatTiming() {
        XCTAssertEqual(MacKeyboardEngine.repeatDelay, 0.5)
        XCTAssertEqual(MacKeyboardEngine.repeatInterval, 0.05)
        XCTAssertEqual(MacKeyboardEngine.repeatCount(heldFor: 0.49), 0)
        XCTAssertEqual(MacKeyboardEngine.repeatCount(heldFor: 1.0), 11)
    }

    /// Every key press asks for the system click; the haptic only with the app's switch on (off by default).
    func testClickRequestedAndHapticBehindSwitch() {
        var clicks = 0, taps = 0
        KeyFeedback.playClick = { clicks += 1 }
        let oldHaptic = KeyFeedback.playHaptic
        KeyFeedback.playHaptic = { _ in taps += 1 }
        defer { KeyFeedback.playHaptic = oldHaptic }

        UserDefaults.standard.removeObject(forKey: KeyFeedback.hapticsKey)
        XCTAssertFalse(KeyFeedback.hapticsOn, "off by default")
        KeyFeedback.keyDown()
        KeyFeedback.tap()
        XCTAssertEqual(clicks, 1)
        XCTAssertEqual(taps, 0, "switch off: nothing taps")

        UserDefaults.standard.set(true, forKey: KeyFeedback.hapticsKey)
        KeyFeedback.keyDown()
        KeyFeedback.tap(.medium)
        XCTAssertEqual(clicks, 2)
        XCTAssertEqual(taps, 2)
    }

    /// The click can play: the typing responder carries a view that adopts UIInputViewAudioFeedback, as its
    /// accessory over the system keyboard and as its input view sideways.
    func testClickViewInPlace() {
        let v = MacTypingView(frame: .zero)
        v.state = KeyboardState(engine: MacKeyboardEngine(sink: Recorder()))
        v.showsMacKeysBar = false
        let acc = v.inputAccessoryView as? ClickInputView
        XCTAssertNotNil(acc)
        XCTAssertEqual(acc?.enableInputClicksWhenVisible, true)
        XCTAssertNil(v.inputView)
        v.clickOnly = true
        XCTAssertTrue(v.inputView is ClickInputView)
        XCTAssertNil(v.inputAccessoryView)
        v.clickOnly = false
        v.showsMacKeysBar = true
        XCTAssertTrue(v.inputAccessoryView is ClickInputView, "the Mac keys row sits in one too")
    }

    /// Sideways the clear click view is all the system shows: its keyboard frame is the one point (plus at most the
    /// home indicator's strip), so nothing covers our keyboard or the controls.
    func testClickOnlyInputIsTiny() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        let v = MacTypingView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        v.clickOnly = true
        window.rootViewController?.view.addSubview(v)
        var frame: CGRect?
        let obs = NotificationCenter.default.addObserver(forName: UIResponder.keyboardDidShowNotification, object: nil,
                                                         queue: .main) { n in
            frame = n.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
        }
        defer { NotificationCenter.default.removeObserver(obs) }
        XCTAssertTrue(v.becomeFirstResponder())
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))
        print("DUO click-only keyboard frame:", frame as Any, "window", window.bounds,
              "bottom inset", window.safeAreaInsets.bottom)
        // A notice for a keyboard entirely below the window (an earlier test's going away) covers nothing.
        if let frame, frame.minY < window.bounds.maxY {
            XCTAssertLessThanOrEqual(frame.height, 1 + window.safeAreaInsets.bottom + 0.5)
        }
        v.resignFirstResponder()
        window.isHidden = true
    }

    /// The pop-up stays on the keyboard at both ends of the top row.
    func testPopupStaysOnKeyboard() {
        let width = HorizontalLayout.keyboardWidth
        let top = TouchKeyboardLayout.frames(.letters, width: width).filter { $0.frame.minY < 20 }.map(\.frame)
        XCTAssertEqual(top.count, 10)
        for f in top {
            let shift = KeyPopup.shift(keyMinX: f.minX, keyWidth: f.width, containerWidth: width)
            let b = KeyPopup.bubble(keySize: f.size, shift: shift).offsetBy(dx: f.minX, dy: 0)
            XCTAssertGreaterThanOrEqual(b.minX, -0.01)
            XCTAssertLessThanOrEqual(b.maxX, width + 0.01)
        }
        // Middle keys are centred.
        let mid = top[4]
        XCTAssertEqual(KeyPopup.shift(keyMinX: mid.minX, keyWidth: mid.width, containerWidth: width), 0)
    }

    /// The owner 2026-11-21, mute on: "no sound and no haptics, but I still want the pop-ups". With every feedback path
    /// off (no click, haptic switch off, and the after-drawing feedback never run) the letter is drawn pressed:
    /// the pop-up is in the picture of the keyboard.
    func testPopupShowsWithEveryFeedbackPathOff() throws {
        var clicks = 0, taps = 0
        KeyFeedback.playClick = { clicks += 1 }
        let oldHaptic = KeyFeedback.playHaptic
        KeyFeedback.playHaptic = { _ in taps += 1 }
        defer { KeyFeedback.playHaptic = oldHaptic }
        UserDefaults.standard.set(false, forKey: KeyFeedback.hapticsKey)

        let m = TouchKeyboardModel(engine: MacKeyboardEngine(sink: Recorder()))
        m.feedbackAfterDrawing = { _ in }  // the feedback never comes
        let before = try render(m)
        m.showPressed("c-t")
        XCTAssertTrue(m.shownKeys.contains("c-t"))
        let after = try render(m)
        XCTAssertEqual(clicks, 0)
        XCTAssertEqual(taps, 0)
        // Above T (the middle of the top row): the pop-up's bubble is drawn there only when pressed.
        let width = HorizontalLayout.keyboardWidth
        let t = try XCTUnwrap(TouchKeyboardLayout.frames(.letters, width: width).first { $0.key.id == "c-t" })
        let probe = CGPoint(x: 20 + t.frame.midX, y: 70 + t.frame.minY - t.frame.height * 0.5)
        XCTAssertNotEqual(pixel(before, probe), pixel(after, probe), "the pop-up is drawn above T")
    }

    /// A quick tap (lifted after 30 ms) still shows the look for `minimumShown`, then it goes; a new press of the
    /// same key in between keeps it.
    func testPressedLookHeldOnQuickTap() {
        let m = TouchKeyboardModel(engine: MacKeyboardEngine(sink: Recorder()))
        let t0 = ProcessInfo.processInfo.systemUptime
        m.showPressed("c-a", at: t0)
        m.hidePressed("c-a", at: t0 + 0.03)
        XCTAssertTrue(m.shownKeys.contains("c-a"), "still shown right after a quick lift")
        RunLoop.main.run(until: Date().addingTimeInterval(TouchKeyboardModel.minimumShown + 0.1))
        XCTAssertFalse(m.shownKeys.contains("c-a"), "gone after the minimum")

        m.showPressed("c-b")
        m.hidePressed("c-b")
        m.showPressed("c-b")  // pressed again before the old lift's timer
        RunLoop.main.run(until: Date().addingTimeInterval(TouchKeyboardModel.minimumShown + 0.1))
        XCTAssertTrue(m.shownKeys.contains("c-b"), "the second press is not cleared by the first lift")

        m.showPressed("c-c", at: t0)
        m.hidePressed("c-c", at: t0 + 1)
        XCTAssertFalse(m.shownKeys.contains("c-c"), "a long press goes at once on the lift")
    }

    private func render(_ m: TouchKeyboardModel) throws -> UIImage {
        let width = HorizontalLayout.keyboardWidth
        let size = CGSize(width: width + 40, height: TouchKeyboardLayout.height(width: width) + 70)
        let host = UIHostingController(rootView: ZStack(alignment: .topLeading) {
            KeyLook.panel
            TouchKeyboardView(model: m, width: width).offset(x: 20, y: 70)
        }.frame(width: size.width, height: size.height))
        host.safeAreaRegions = []
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.overrideUserInterfaceStyle = .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        window.isHidden = true
        return image
    }

    private func pixel(_ image: UIImage, _ p: CGPoint) -> [UInt8] {
        guard let cg = image.cgImage, let data = cg.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return [] }
        let o = Int(p.y) * cg.bytesPerRow + Int(p.x) * cg.bitsPerPixel / 8
        return (0..<4).map { bytes[o + $0] }
    }
}

/// Build 39 proof renders: the keys pressed through the same call a touch makes (`showPressed`), with every
/// feedback path off, over the panel with the horizontal key row's space above, light and dark.
@MainActor
final class KeyPopupProofRenders: XCTestCase {
    func testRenderTouchPressed() throws {
        guard let dir = ProcessInfo.processInfo.environment["DUO_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_DUO_SNAPSHOT_DIR to render")
        }
        KeyFeedback.playClick = {}
        defer { KeyFeedback.playClick = { UIDevice.current.playInputClick() } }
        UserDefaults.standard.set(false, forKey: KeyFeedback.hapticsKey)
        let width = HorizontalLayout.keyboardWidth
        let size = CGSize(width: width + 40, height: TouchKeyboardLayout.height(width: width) + 70)
        for scheme in [UIUserInterfaceStyle.light, .dark] {
            for id in ["c-t", "c-q", "c-p", "c-a", "c-l", "shift", "delete"] {
                let kb = TouchKeyboardModel(engine: MacKeyboardEngine(sink: Recorder()))
                kb.feedbackAfterDrawing = { _ in }
                kb.showPressed(id)
                let host = UIHostingController(rootView: ZStack(alignment: .topLeading) {
                    KeyLook.panel
                    TouchKeyboardView(model: kb, width: width).offset(x: 20, y: 70)
                }.frame(width: size.width, height: size.height))
                host.safeAreaRegions = []
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(origin: .zero, size: size)
                window.overrideUserInterfaceStyle = scheme
                window.rootViewController = host
                window.makeKeyAndVisible()
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                let format = UIGraphicsImageRendererFormat()
                format.scale = 3
                let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
                }
                let name = "build39-\(id)-\(scheme == .dark ? "dark" : "light").png"
                try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: dir + "/" + name))
                window.isHidden = true
            }
        }
    }
}

/// Pressed state and pop-up renders: Q, T and P (the ends and the middle of the top row), plus delete and shift
/// held, light and dark.
@MainActor
final class KeyFeedbackSnapshotTests: XCTestCase {
    func testRenderPressed() throws {
        guard let dir = ProcessInfo.processInfo.environment["DUO_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_DUO_SNAPSHOT_DIR to render")
        }
        let width = HorizontalLayout.keyboardWidth
        let height = TouchKeyboardLayout.height(width: width) + 70
        let size = CGSize(width: width + 40, height: height)
        for (name, scheme, keys) in [
            ("q-light", UIUserInterfaceStyle.light, ["c-q"]), ("q-dark", .dark, ["c-q"]),
            ("t-light", .light, ["c-t"]), ("t-dark", .dark, ["c-t"]),
            ("p-light", .light, ["c-p"]), ("p-dark", .dark, ["c-p"]),
            ("shift-delete-light", .light, ["shift", "delete"]), ("shift-delete-dark", .dark, ["shift", "delete"]),
        ] as [(String, UIUserInterfaceStyle, Set<String>)] {
            let kb = TouchKeyboardModel(engine: MacKeyboardEngine(sink: Recorder()))
            let view = ZStack(alignment: .topLeading) {
                KeyLook.panel
                TouchKeyboardView(model: kb, width: width, shownPressed: keys)
                    .offset(x: 20, y: 70)
            }
            .frame(width: size.width, height: size.height)
            let host = UIHostingController(rootView: view)
            host.safeAreaRegions = []
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(origin: .zero, size: size)
            window.overrideUserInterfaceStyle = scheme
            window.rootViewController = host
            window.makeKeyAndVisible()
            RunLoop.main.run(until: Date().addingTimeInterval(0.5))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
            }
            try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: dir + "/key-press-\(name)-2026-11-21.png"))
            window.isHidden = true
        }
    }
}
