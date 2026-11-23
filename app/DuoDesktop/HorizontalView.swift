import SwiftUI
import UIKit
import os

// The horizontal view on the open Duo (project notes, round 4, 589 pt keyboard). The owner
// 2026-11-21: "The horizontal view on the Duo, when it's open, is where we're really going for the full Mac screen.
// The Mac screen should fill the entire Duo without stretching. ... a trackpad under your right thumb in the corner.
// ... Then on the left, there are three buttons" / "the scroll should be the bottom button, the right click the
// middle button, and the keyboard the top button." / "Yes, we should do our own keyboard. That keyboard should also
// be moved to the left so it's off center" / "The four buttons can then be collapsed to being a single column with
// the click on the bottom." / "We can make a smaller keyboard that is the same as the vertical view." / "589".
// Settled answers: the same column and the same 250 x 251 trackpad in the same places in both states;
// keyboard up keeps the full-screen scale and moves the view up and down to follow the pointer; regular glass; the
// column keeps its order when the sides swap; the keyboard comes up only from the Keyboard button.

/// Where everything sits on the open Duo held sideways, in points. Pure geometry, the same in both states: the
/// keyboard state only adds the key row and the keyboard between the column and the trackpad.
struct HorizontalLayout: Equatable {
    /// Our keyboard is the upright iPhone keyboard (669 pt wide on the Duo) scaled as one piece to 589 pt.
    static let keyboardWidth: CGFloat = 589
    static let uprightWidth: CGFloat = 669
    static var scale: CGFloat { keyboardWidth / uprightWidth }
    static let edge: CGFloat = 10
    static let bottom: CGFloat = 12
    static let gap: CGFloat = 8
    static let columnWidth: CGFloat = 76
    /// Keyboard, Right click and Scroll: Apple's smallest touch target tall.
    static let smallButton: CGFloat = 44
    static let buttonGap: CGFloat = 6
    /// The key row's height at the upright size (`MacKeysBar.height`), scaled.
    static var keyRowHeight: CGFloat { MacKeysBar.height * scale }

    let size: CGSize
    var side: TrackpadSide = .standard
    /// A normal iPhone held sideways only: extra room kept clear at each side (the Dynamic Island's side,
    /// `PhoneKind.sidewaysInsets`). Zero on the Duo, so its layout is unchanged.
    var leadingInset: CGFloat = 0
    var trailingInset: CGFloat = 0
    /// A normal iPhone held sideways (never the Duo): with the keyboard down the trackpad is the wide overlay
    /// (`widePad`). With the keyboard up it keeps the Duo's rule (the room beside our 589 pt keyboard).
    var normalPhone = false
    /// Our keyboard is up (only changes anything on a normal iPhone).
    var typing = false

    /// The wide overlay on a normal iPhone, keyboard down (project notes; the owner: "The
    /// trackpad overlays the picture. This is the horizontal view. It doesn't matter how wide it is."). Build 58
    /// (the owner: "It should be the same vertically as the buttons."): exactly the column's height, read from the
    /// column's own frame (top of Keyboard to bottom of Click), and `wideAspect` times as wide as it is tall, never
    /// past the room beside the column.
    /// 3:2: wide like a Mac trackpad (a Magic Trackpad is 160 x 115 mm, about 1.4:1).
    static let wideAspect: CGFloat = 1.5
    var widePad: Bool { normalPhone && !typing }

    /// Our keyboard's height (four rows with the upright gaps, 8 above and 12 below, scaled).
    var keyboardHeight: CGFloat { TouchKeyboardLayout.height(width: Self.keyboardWidth) }
    /// The top of the key row: the Mac picture shows above it while the keyboard is up.
    var panelTop: CGFloat { size.height - keyboardHeight - Self.keyRowHeight }
    /// The column and the trackpad: from just under the panel's top to 12 pt above the bottom, in both states.
    private var controlsTop: CGFloat { panelTop + Self.edge }
    private var controlsHeight: CGFloat { size.height - Self.bottom - controlsTop }

    var column: CGRect {
        let x = side == .right ? Self.edge + leadingInset : size.width - Self.edge - trailingInset - Self.columnWidth
        return CGRect(x: x, y: controlsTop, width: Self.columnWidth, height: controlsHeight)
    }
    var trackpad: CGRect {
        if widePad {
            let c = column, h = c.height
            let room = size.width - 2 * Self.edge - leadingInset - trailingInset - Self.columnWidth - Self.gap
            let w = min(room, (h * Self.wideAspect).rounded(.down))
            let x = side == .right ? size.width - Self.edge - trailingInset - w : Self.edge + leadingInset
            return CGRect(x: x, y: c.minY, width: w, height: h)
        }
        let w = size.width - 2 * Self.edge - leadingInset - trailingInset - Self.columnWidth - 2 * Self.gap
            - Self.keyboardWidth
        let x = side == .right ? size.width - Self.edge - trailingInset - w : Self.edge + leadingInset
        return CGRect(x: x, y: controlsTop, width: w, height: controlsHeight)
    }
    private var keyboardX: CGFloat {
        side == .right ? column.maxX + Self.gap : trackpad.maxX + Self.gap
    }
    var keyRow: CGRect { CGRect(x: keyboardX, y: panelTop, width: Self.keyboardWidth, height: Self.keyRowHeight) }
    var keyboard: CGRect {
        CGRect(x: keyboardX, y: panelTop + Self.keyRowHeight, width: Self.keyboardWidth, height: keyboardHeight)
    }

    /// The column's four buttons, top to bottom: Keyboard, Right click, Scroll, then Click taking the rest. The order
    /// never changes with the side.
    enum Button: CaseIterable { case keyboard, right, scroll, click }
    func frame(_ b: Button) -> CGRect {
        let c = column, step = Self.smallButton + Self.buttonGap
        switch b {
        case .keyboard: return CGRect(x: c.minX, y: c.minY, width: c.width, height: Self.smallButton)
        case .right: return CGRect(x: c.minX, y: c.minY + step, width: c.width, height: Self.smallButton)
        case .scroll: return CGRect(x: c.minX, y: c.minY + 2 * step, width: c.width, height: Self.smallButton)
        case .click:
            let y = c.minY + 3 * step
            return CGRect(x: c.minX, y: y, width: c.width, height: c.maxY - y)
        }
    }

    /// Which of the screen's bottom corners a control sits in: the Click button and the trackpad, by side.
    enum ScreenCorner { case bottomLeading, bottomTrailing }
    var clickCorner: ScreenCorner { side == .right ? .bottomLeading : .bottomTrailing }
    var trackpadCorner: ScreenCorner { side == .right ? .bottomTrailing : .bottomLeading }

    /// The one key row over our keyboard (the plan's 11 keys). The order never flips.
    static let rowKeys: [MacKey] = [
        MacKeyboardLayout.escape, MacKeyboardLayout.tab, MacKeyboardLayout.controlKey, MacKeyboardLayout.optionKey,
        MacKeyboardLayout.commandKey, MacKeyboardLayout.shiftKey, MacKeyboardLayout.left, MacKeyboardLayout.up,
        MacKeyboardLayout.down, MacKeyboardLayout.right, SpecialKeysLayout.forwardDelete,
    ]
    /// The row's keys: the upright row key (52 x 38) scaled, spread over the keyboard's letter width.
    static var rowKeySize: CGSize { CGSize(width: 52 * scale, height: KeyMetrics.height * scale) }
}

/// With the keyboard up the view keeps the full-screen scale and moves only up and down so the pointer sits in the
/// middle of the space above the key row; it stops at the Mac screen's top (no move) and bottom (the picture's
/// bottom edge at the key row). Returns how far to move the fitted picture down (negative = up).
enum TypingFollow {
    static func offset(pointerY: CGFloat, canvasHeight: Int, fit: CGRect, visibleHeight: CGFloat) -> CGFloat {
        guard canvasHeight > 0, fit.height > 0, visibleHeight > 0 else { return 0 }
        let y = fit.minY + pointerY / CGFloat(canvasHeight) * fit.height
        let wanted = visibleHeight / 2 - y
        let lowest = min(0, visibleHeight - fit.maxY)
        return min(0, max(lowest, wanted))
    }
}

// MARK: - Our keyboard

/// One key of our keyboard: what it does, not where it sits.
enum TouchKey: Equatable {
    case char(Character)
    case shift
    case delete
    case page(TouchKeyboardLayout.Page)
    case space
    case ret

    /// 123, ABC, #+= and space: words, set smaller than letters.
    var isWordKey: Bool {
        switch self {
        case .page, .space: true
        default: false
        }
    }

    var id: String {
        switch self {
        case let .char(c): "c-\(c)"
        case .shift: "shift"
        case .delete: "delete"
        case let .page(p): "page-\(p)"
        case .space: "space"
        case .ret: "return"
        }
    }
}

/// The upright iPhone keyboard's layout and proportions (measured from the owner's real screenshots: letter key
/// 53.5 x 49 at 669 wide, 64.2 across and 63.8 down, 18.8 at the sides; ⇧ and ⌫ 72.7; 123 49.5; return 79.4),
/// scaled as one piece. Globe, emoji and mic are not ours to offer, so their slots join the space bar.
enum TouchKeyboardLayout {
    enum Page: String { case letters, numbers, symbols }

    // Upright sizes at 669 pt.
    static let keyW: CGFloat = 53.5, keyH: CGFloat = 49, pitchX: CGFloat = 64.2, pitchY: CGFloat = 63.8
    static let side: CGFloat = 18.8, top: CGFloat = 8, bottom: CGFloat = 12
    static let wideKey: CGFloat = 72.7, pageKey: CGFloat = 49.5, returnKey: CGFloat = 79.4
    static var gapX: CGFloat { pitchX - keyW }

    /// One set of the keyboard's proportions. Widths are in units of `drawnWidth` and scale with the keyboard's
    /// width; heights scale too unless `fixedHeights` (then they are points at every width).
    struct Sizes: Equatable {
        var drawnWidth: CGFloat
        var keyW: CGFloat, keyH: CGFloat, pitchX: CGFloat, pitchY: CGFloat
        var side: CGFloat, top: CGFloat, bottom: CGFloat
        var wideKey: CGFloat, pageKey: CGFloat, returnKey: CGFloat
        var fixedHeights = false
        var gapX: CGFloat { pitchX - keyW }
        var rowGap: CGFloat { pitchY - keyH }

        /// The sideways keyboard (the open Duo's upright proportions, scaled as one piece).
        static let sideways = Sizes(drawnWidth: HorizontalLayout.uprightWidth,
                                    keyW: TouchKeyboardLayout.keyW, keyH: TouchKeyboardLayout.keyH,
                                    pitchX: TouchKeyboardLayout.pitchX, pitchY: TouchKeyboardLayout.pitchY,
                                    side: TouchKeyboardLayout.side, top: TouchKeyboardLayout.top,
                                    bottom: TouchKeyboardLayout.bottom, wideKey: TouchKeyboardLayout.wideKey,
                                    pageKey: TouchKeyboardLayout.pageKey, returnKey: TouchKeyboardLayout.returnKey)
        /// A normal iPhone upright (the agreed drawing, screenshots/normal-phone/R8-V1-light.png, draw2.py at 402
        /// wide): letter keys 34.2 x 40, 6 apart, 3 in from the sides; ⇧ and ⌫ 1.3 keys, 123 1.3 keys + 4, return
        /// 2.2 keys; 6 above the first row (the gap under the band). Rows 48 apart, not the drawing's 50, and
        /// nothing below the last row (it sits on the home indicator's area, not in it): the app's top row is the
        /// system bar, 16 pt taller than the drawing's, and these 6 + 4 pt (with the band's lower gap, now the
        /// keyboard's own top inset) give the picture its 402 x 402. Each key's touch area stays 48 tall.
        /// 190 pt tall at every width.
        static let portrait = Sizes(drawnWidth: 402, keyW: 34.2, keyH: 40, pitchX: 40.2, pitchY: 48,
                                    side: 3, top: 6, bottom: 0, wideKey: 34.2 * 1.3, pageKey: 34.2 * 1.3 + 4,
                                    returnKey: 34.2 * 2.2, fixedHeights: true)
    }

    static func height(width: CGFloat, sizes: Sizes = .sideways) -> CGFloat {
        let s = sizes
        return (s.top + 4 * s.keyH + 3 * s.rowGap + s.bottom) * (s.fixedHeights ? 1 : width / s.drawnWidth)
    }

    private static func chars(_ s: String) -> [TouchKey] { s.map { .char($0) } }

    /// The three middle-row sets and the first two rows of each page (iPhone US). The symbols page's € £ ¥ • have
    /// no US Mac key, so that row carries the US keys the other pages lack.
    static func rows(_ page: Page) -> [[TouchKey]] {
        switch page {
        case .letters:
            return [chars("qwertyuiop"), chars("asdfghjkl"), [.shift] + chars("zxcvbnm") + [.delete],
                    [.page(.numbers), .space, .ret]]
        case .numbers:
            return [chars("1234567890"), chars("-/:;()$&@\""), [.page(.symbols)] + chars(".,?!'") + [.delete],
                    [.page(.letters), .space, .ret]]
        case .symbols:
            return [chars("[]{}#%^*+="), chars("_\\|~<>`"), [.page(.numbers)] + chars(".,?!'") + [.delete],
                    [.page(.letters), .space, .ret]]
        }
    }

    /// Every key's frame in a keyboard `width` points wide (origin at the keyboard's top-left).
    static func frames(_ page: Page, width: CGFloat, sizes s: Sizes = .sideways) -> [(key: TouchKey, frame: CGRect)] {
        let k = width / s.drawnWidth
        let kv = s.fixedHeights ? 1 : k
        var out: [(TouchKey, CGRect)] = []
        let inner = s.drawnWidth - 2 * s.side
        let keyW = s.keyW, gapX = s.gapX, side = s.side, wideKey = s.wideKey
        for (r, row) in rows(page).enumerated() {
            let y = s.top + CGFloat(r) * s.pitchY
            var cells: [(TouchKey, CGFloat, CGFloat)] = [] // key, x, width (drawn units)
            switch r {
            case 0, 1:
                // Letter-width keys at the letter pitch, the row centred (A-L sits in by half a key).
                let n = CGFloat(row.count)
                let x0 = side + (inner - (n * keyW + (n - 1) * gapX)) / 2
                for (i, key) in row.enumerated() { cells.append((key, x0 + CGFloat(i) * s.pitchX, keyW)) }
            case 2:
                // ⇧ (or the page key) at the left, ⌫ at the right, the rest between: letters at the letter pitch,
                // centred; the five punctuation keys share the space evenly (as the iPhone's 123 page).
                cells.append((row[0], side, wideKey))
                cells.append((row[row.count - 1], side + inner - wideKey, wideKey))
                let mid = Array(row.dropFirst().dropLast())
                let n = CGFloat(mid.count)
                if page == .letters {
                    let x0 = side + (inner - (n * keyW + (n - 1) * gapX)) / 2
                    for (i, key) in mid.enumerated() { cells.append((key, x0 + CGFloat(i) * s.pitchX, keyW)) }
                } else {
                    let room = inner - 2 * wideKey - 2 * gapX
                    let w = (room - (n - 1) * gapX) / n
                    for (i, key) in mid.enumerated() {
                        cells.append((key, side + wideKey + gapX + CGFloat(i) * (w + gapX), w))
                    }
                }
            default:
                cells.append((row[0], side, s.pageKey))
                cells.append((row[2], side + inner - s.returnKey, s.returnKey))
                cells.append((row[1], side + s.pageKey + gapX, inner - s.pageKey - s.returnKey - 2 * gapX))
            }
            for (key, x, w) in cells { out.append((key, CGRect(x: x * k, y: y * kv, width: w * k, height: s.keyH * kv))) }
        }
        return out
    }

    /// A key's touch area: its frame grown by half the gap to each neighbour (so the keys' areas meet with no dead
    /// strip between them, as the system keyboard's).
    static func touchArea(_ frame: CGRect, width: CGFloat, sizes s: Sizes) -> CGRect {
        let k = width / s.drawnWidth, kv = s.fixedHeights ? 1 : k
        return frame.insetBy(dx: -s.gapX * k / 2, dy: -s.rowGap * kv / 2)
    }
}

/// Our keyboard's behaviour apart from the view: the page, shift (tap = next letter capital, double tap = caps
/// lock, as the iPhone's), and what each key sends through the same engine as the upright view's keys (so a
/// modifier held from the row applies to the next key).
@MainActor @Observable
final class TouchKeyboardModel {
    enum Shift: Equatable { case off, once, locked }
    var page: TouchKeyboardLayout.Page = .letters
    var shift: Shift = .off
    @ObservationIgnored private var lastShiftTap: TimeInterval = -10
    @ObservationIgnored let engine: MacKeyboardEngine
    static let doubleTap: TimeInterval = 0.35

    init(engine: MacKeyboardEngine) {
        self.engine = engine
        // `--hold-key-look ID` (simulator only, README pictures): that key is drawn pressed and stays so. Look only:
        // nothing is typed.
        if let id = SimulatorSwitches.holdKeyLook {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.shownKeys.insert(id) }
        }
        if let p = SimulatorSwitches.keyboardPage { page = p }
        if SimulatorSwitches.keyboardShift { shift = .once }
    }

    /// The Mac key a character key sends now (capital with shift on the letters page).
    func macKey(for c: Character) -> MacKey? {
        let ch = (page == .letters && shift != .off) ? Character(c.uppercased()) : c
        return MacTyping.keys[ch]
    }

    func label(_ key: TouchKey) -> String {
        switch key {
        case let .char(c): page == .letters ? c.uppercased() : String(c)
        case .shift, .delete, .ret: ""
        case let .page(p): p == .letters ? "ABC" : p == .numbers ? "123" : "#+="
        case .space: "space"
        }
    }

    func tapShift(at time: TimeInterval) {
        switch shift {
        case .off: shift = .once
        case .once: shift = time - lastShiftTap < Self.doubleTap ? .locked : .off
        case .locked: shift = .off
        }
        lastShiftTap = time
    }

    /// The keys drawn as pressed now (pop-up for a letter, the darker shade for the others), by key id. Kept apart
    /// from the click and the haptic (the owner 2026-11-21: with mute on, "no sound and no haptics, but I still want the
    /// pop-ups"): set first, on touch down, before any feedback is asked for, and nothing in `KeyFeedback` can
    /// clear or skip it. Held at least `minimumShown` after the press, so an 80 ms tap still shows it.
    private(set) var shownKeys: Set<String> = []
    @ObservationIgnored private var shownSince: [String: TimeInterval] = [:]
    @ObservationIgnored private var shownToken: [String: Int] = [:]
    @ObservationIgnored private var nextToken = 0
    /// About the system keyboard's pop-up on a quick tap: long enough to see, short enough for fast typing.
    static let minimumShown: TimeInterval = 0.12

    /// The key under a finger: drawn pressed now. The click and haptic come after, on the next turn of the run loop
    /// (`KeyFeedback.keyDown` through `feedbackAfterDrawing`), so neither can delay or stop the drawing.
    func showPressed(_ id: String, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        nextToken += 1
        shownToken[id] = nextToken
        shownSince[id] = time
        shownKeys.insert(id)
    }

    /// The finger lifted (or slid off): the pressed look goes now if it has been shown `minimumShown`, else when
    /// that has passed. A new press of the same key in between keeps it.
    func hidePressed(_ id: String, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard let since = shownSince[id], let token = shownToken[id] else { return }
        let left = Self.minimumShown - (time - since)
        if left <= 0 { clear(id, token: token); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + left) { [weak self] in
            MainActor.assumeIsolated { self?.clear(id, token: token) }
        }
    }

    private func clear(_ id: String, token: Int) {
        guard shownToken[id] == token else { return }
        shownKeys.remove(id)
        shownSince[id] = nil
        shownToken[id] = nil
    }

    /// The click and haptic, after the pressed look has been set and drawn; replaced in tests.
    @ObservationIgnored var feedbackAfterDrawing: (@escaping @MainActor () -> Void) -> Void = { work in
        DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
    }

    /// A key went down. Delete, shift and the page keys act now, as the system keyboard's (delete's Mac key goes
    /// down and repeats while held; the caller times the repeats). Characters wait for the lift.
    func touchDown(_ key: TouchKey, at time: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        switch key {
        case .shift: tapShift(at: time)
        case let .page(p): page = p
        case .delete: engine.keyDown(MacKeyboardLayout.delete)
        case .char, .space, .ret: break
        }
    }

    /// A key lifted. Characters, space and return type now, only when the finger lifted on the key (`onKey`);
    /// a finger that slid off takes it back. Delete's Mac key comes up.
    func lifted(_ key: TouchKey, onKey: Bool = true) {
        switch key {
        case let .char(c):
            guard onKey, let k = macKey(for: c) else { return }
            engine.keyDown(k)
            engine.keyUp(k)
            if shift == .once { shift = .off }
            // The iPhone goes back to letters after a quote or apostrophe on the 123 page; ours stays (Mac typing).
        case .space:
            guard onKey else { return }
            engine.keyDown(MacKeyboardLayout.space)
            engine.keyUp(MacKeyboardLayout.space)
        case .ret:
            guard onKey else { return }
            engine.keyDown(MacKeyboardLayout.returnKey)
            engine.keyUp(MacKeyboardLayout.returnKey)
        case .delete: engine.keyUp(MacKeyboardLayout.delete)
        case .shift, .page: break
        }
    }
}

/// Our keyboard on its panel: the four rows drawn with the keys' own look (`KeyLook`), at `width` points.
struct TouchKeyboardView: View {
    let model: TouchKeyboardModel
    let width: CGFloat
    /// The proportions: sideways (the Duo's horizontal view, as always) or a normal iPhone upright.
    var sizes: TouchKeyboardLayout.Sizes = .sideways
    /// Proof renders only: draw these keys as held down.
    var shownPressed: Set<String> = []

    var body: some View {
        let frames = TouchKeyboardLayout.frames(model.page, width: width, sizes: sizes)
        // Upright on a normal iPhone each key also takes the half gaps around it (`touchArea`); sideways, as before,
        // only the key itself.
        let grows = sizes.fixedHeights
        ZStack(alignment: .topLeading) {
            ForEach(frames, id: \.key.id) { item in
                let area = grows ? TouchKeyboardLayout.touchArea(item.frame, width: width, sizes: sizes) : item.frame
                TouchKeyCap(model: model, key: item.key, size: item.frame.size,
                            shownPressed: shownPressed.contains(item.key.id),
                            popupShift: KeyPopup.shift(keyMinX: item.frame.minX, keyWidth: item.frame.width,
                                                       containerWidth: width),
                            touchPad: CGSize(width: item.frame.minX - area.minX, height: item.frame.minY - area.minY))
                    .frame(width: area.width, height: area.height)
                    .offset(x: area.minX, y: area.minY)
                    .zIndex(model.shownKeys.contains(item.key.id) || shownPressed.contains(item.key.id) ? 1 : 0)
            }
        }
        .frame(width: width, height: TouchKeyboardLayout.height(width: width, sizes: sizes), alignment: .topLeading)
        .onAppear { KeyFeedback.prepare() }
    }
}

private struct TouchKeyCap: View {
    let model: TouchKeyboardModel
    let key: TouchKey
    var size: CGSize = .zero
    var shownPressed = false
    var popupShift: CGFloat = 0
    /// How far the touch area reaches past the key on each side (0 sideways).
    var touchPad: CGSize = .zero
    @State private var touched = false
    /// Drawn pressed: the model's shown keys (held at least `minimumShown`), or a proof render's.
    private var pressed: Bool { model.shownKeys.contains(key.id) || shownPressed }
    /// The finger is still on the key (within `KeyPressRules.slop`).
    @State private var onKey = true
    @State private var repeatTimer: Timer?

    private var face: KeyFaceContent {
        switch key {
        case .shift: .symbol(model.shift == .locked ? "capslock.fill" : model.shift == .once ? "shift.fill" : "shift")
        case .delete: .symbol("delete.left")
        case .ret: .symbol("return")
        default: .text(model.label(key))
        }
    }

    private var name: String {
        switch key {
        case .shift: model.shift == .locked ? "Caps Lock, on" : model.shift == .once ? "Shift, on" : "Shift"
        case .delete: "Delete"
        case .ret: "Return"
        case .space: "Space"
        default: model.label(key)
        }
    }

    /// Letter and character keys show the pop-up instead of darkening, as the system's; the others darken.
    private var isCharacter: Bool { if case .char = key { true } else { false } }
    private var showsPopup: Bool { pressed && isCharacter }

    var body: some View {
        // Letters in the system's letter size; the scaled keyboard keeps the glyph at the keys' own size.
        KeyFace(content: face, pressed: pressed && !isCharacter, textSize: key.isWordKey ? 16 : 22)
            .overlay(alignment: .topLeading) {
                if showsPopup {
                    KeyPopupView(letter: model.label(key), keySize: size, shift: popupShift)
                }
            }
            // Only upright on a normal iPhone: sideways nothing here changes (touchPad is zero).
            .modifier(TouchPadArea(pad: touchPad))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !touched { down() }
                    let now = KeyPressRules.inside(CGPoint(x: v.location.x - touchPad.width,
                                                           y: v.location.y - touchPad.height), size: size)
                    if now != onKey {
                        onKey = now
                        // Slid off: the look goes (as the system's); back on: it returns.
                        if now { model.showPressed(key.id) } else { model.hidePressed(key.id) }
                    }
                }
                .onEnded { _ in up() })
            .accessibilityElement()
            .accessibilityLabel(name)
            .accessibilityAddTraits(.isKeyboardKey)
            .accessibilityIdentifier("touchKey-\(key.id)")
            .accessibilityAction { down(); up() }
            .onDisappear { if touched { up() } }
    }

    private func down() {
        touched = true
        onKey = true
        // Drawing first: the pop-up (or the shade) is set before anything else, and does not depend on the click,
        // the haptic, mute or any setting.
        model.showPressed(key.id)
        model.touchDown(key)
        model.feedbackAfterDrawing { KeyFeedback.keyDown() }
        guard key == .delete else { return }
        let engine = model.engine, del = MacKeyboardLayout.delete
        repeatTimer = Timer.scheduledTimer(withTimeInterval: MacKeyboardEngine.repeatDelay, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard touched else { return }
                engine.keyRepeat(del)
                repeatTimer = Timer.scheduledTimer(withTimeInterval: MacKeyboardEngine.repeatInterval,
                                                   repeats: true) { _ in
                    MainActor.assumeIsolated { engine.keyRepeat(del) }
                }
            }
        }
    }

    private func up() {
        let lifted = onKey
        touched = false
        onKey = true
        model.hidePressed(key.id)
        repeatTimer?.invalidate()
        repeatTimer = nil
        model.lifted(key, onKey: lifted)
    }
}

/// A key's touch area grown by `pad` on each side; nothing at all when `pad` is zero.
private struct TouchPadArea: ViewModifier {
    let pad: CGSize
    func body(content: Content) -> some View {
        if pad == .zero {
            content
        } else {
            content.padding(.horizontal, pad.width).padding(.vertical, pad.height).contentShape(Rectangle())
        }
    }
}

// MARK: - The controls over the picture

/// The column, trackpad, key row and our keyboard, laid over the whole-screen picture. Only the controls take
/// touches; everywhere else touches reach the picture (tap = click, as today).
struct HorizontalControls: View {
    /// The Glass Act session, or nil for a JetKVM-only computer's screen (project notes, 2026-11-22: the same
    /// sideways trackpad and button column as a Mac's session), which passes its own `back`.
    let model: SessionModel?
    let parts: SessionParts
    let keyboard: TouchKeyboardModel
    let layout: HorizontalLayout
    @Binding var typing: Bool
    var back: (() -> Void)? = nil

    private var acceptsInput: Bool { model?.flow.acceptsInput ?? true }
    private var held: Bool { model?.flow.showsHeldPicture ?? false }
    private var overview: Bool { model?.showsOverview ?? false }

    var body: some View {
        ZStack(alignment: .topLeading) {
            if typing {
                // The panel the colour of the keyboard's, the whole width under the row, as the upright keyboard's.
                KeyLook.panelShape.fill(KeyLook.panel)
                    .frame(width: layout.size.width, height: layout.size.height - layout.panelTop)
                    .offset(y: layout.panelTop)
                keyRow
                    .frame(width: layout.keyRow.width, height: layout.keyRow.height)
                    .offset(x: layout.keyRow.minX, y: layout.keyRow.minY)
                TouchKeyboardView(model: keyboard, width: layout.keyboard.width)
                    .offset(x: layout.keyboard.minX, y: layout.keyboard.minY)
            }
            Group {
                if typing {
                    // Keyboard up: the controls sit over the keyboard's panel, not the picture; regular glass as before.
                    GlassEffectContainer { controls }
                } else {
                    controls
                }
            }
            .allowsHitTesting(acceptsInput)
            .opacity(held ? 0.5 : 1)
            .background(ColumnLookWatch(typing: typing, held: held,
                                        acceptsInput: acceptsInput).frame(width: 1, height: 1))
            TopCornerButtons(model: model, back: back)
                .frame(width: layout.size.width, alignment: .top)
        }
        .frame(width: layout.size.width, height: layout.size.height, alignment: .topLeading)
    }

    private var clickShape: AnyShape { CornerShapes.shape(fixed: KeyLook.cornerRadius, concentric: layout.clickCorner) }
    private var trackpadShape: AnyShape { CornerShapes.shape(fixed: 22, concentric: layout.trackpadCorner) }

    /// Full screen: almost clear, drawn by us (`ClearLook`). Keyboard up: regular glass (over the panel).
    private var controls: some View {
        ZStack(alignment: .topLeading) {
            keyboardButton.place(layout.frame(.keyboard))
            ClickButton(pad: parts.trackpad, button: .right, glass: typing, clear: !typing)
                .place(layout.frame(.right))
            ClickButton(pad: parts.trackpad, button: .scroll, glass: typing, clear: !typing)
                .place(layout.frame(.scroll))
            ClickButton(pad: parts.trackpad, button: .left, glass: typing, clear: !typing, shape: clickShape)
                .place(layout.frame(.click))
            trackpad
                .opacity(overview ? 0.4 : 1)
                .allowsHitTesting(!overview)
                .place(layout.trackpad)
        }
    }

    @ViewBuilder private var trackpad: some View {
        if typing {
            TrackpadView(engine: parts.trackpad)
                .contentShape(trackpadShape)
                .glassEffect(.regular, in: trackpadShape)
        } else {
            TrackpadView(engine: parts.trackpad).clearSurface(trackpadShape)
        }
    }

    private var keyRow: some View {
        HStack(spacing: 0) {
            ForEach(HorizontalLayout.rowKeys) { key in
                KeyCap(state: parts.keyboard, key: key)
                    .frame(width: HorizontalLayout.rowKeySize.width, height: HorizontalLayout.rowKeySize.height)
                if key != HorizontalLayout.rowKeys.last { Spacer(minLength: 0) }
            }
        }
        .padding(.horizontal, TouchKeyboardLayout.side * HorizontalLayout.scale)
    }

    /// The Keyboard button: on, it is the accent with a white symbol (HIG: a toggle that is on), and hides it.
    private var keyboardButton: some View {
        Button { typing.toggle() } label: {
            Image(systemName: typing ? "keyboard.chevron.compact.down" : "keyboard")
                .font(.system(size: KeyLook.glyphSize))
                .foregroundStyle(typing ? Color.white : Color.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(KeyLook.shape)
        }
        .buttonStyle(.plain)
        .modifier(KeyboardButtonSurface(on: typing))
        .accessibilityLabel("Keyboard")
        .accessibilityValue(typing ? "on" : "off")
        .accessibilityHint(typing ? "Hides the keyboard" : "Shows the keyboard")
        .accessibilityIdentifier("keyboardButton")
    }
}

private extension View {
    func place(_ r: CGRect) -> some View { frame(width: r.width, height: r.height).offset(x: r.minX, y: r.minY) }
}

/// The Keyboard button's surface: off (full screen) almost clear with the halo'd symbol; on (keyboard up) the solid
/// accent in glass, as before.
private struct KeyboardButtonSurface: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on {
            // Solid accent drawn by us from the asset (not the system glass, not the inherited tint, which the
            // system can dim), so it stays orange the whole time the keyboard is up.
            content.background(KeyLook.shape.fill(ClearLook.accent)).contentShape(KeyLook.shape)
        } else {
            content.modifier(ClearLook.Halo()).clearSurface(AnyShape(KeyLook.shape))
        }
    }
}

/// Back to Macs (top-left, the shared `BackToMacsButton`); Screens (several screens only, top-right): small round
/// glass buttons. No info control (the owner
/// 2026-11-21: the shortcuts "don't need to be on every screen"; Keyboard Shortcuts is a row on the Mac list; after
/// build 46 brought it back: "No, no truncation. Cut it again").
private struct TopCornerButtons: View {
    let model: SessionModel?
    var back: (() -> Void)? = nil

    var body: some View {
        GlassEffectContainer {
            HStack {
                // The same back button as upright (not an X: X closes a modal; this goes back to the Mac list).
                BackToMacsButton { if let back { back() } else { model?.disconnect() } }
                Spacer()
                if let model, model.multiScreen {
                    Menu {
                        ScreenMenuItems(model: model)
                    } label: {
                        Image(systemName: "display.2").frame(width: 20, height: 20)
                    }
                    .accessibilityLabel("Screens")
                    .accessibilityIdentifier("screenMenuButton")
                }
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .controlSize(.large)
            // Clear of the display's rounded top corners: a 48 pt circle 14 pt in sits inside a 59 pt corner (the
            // iPhone Duo simulator's display radius) with about 3 pt to spare; at 8 pt in it crossed the curve.
            .padding(14)
        }
    }
}

/// The horizontal view's controls over the Mac picture (full-screen state). The owner 2026-11-21: "In the horizontal view,
/// we need almost total transparency for the trackpad and the buttons so we can see the pointer behind it." / "We
/// can't depend on system settings for transparency. We need to enforce super transparent." So no system material
/// (Liquid Glass follows Clear/Tinted, Reduce Transparency and Increase Contrast): a fixed near-zero fill with no
/// blur, a thin two-tone rim (light line on a dark line, so it shows over a white window and a dark one), and the
/// symbol with a halo of the opposite colour.
enum ClearLook {
    /// 6% of black in light mode, 6% of white in dark mode.
    static let fill = Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.06) : UIColor(white: 0, alpha: 0.06) })
    static let pressedFill = Color(UIColor { $0.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.22) : UIColor(white: 0, alpha: 0.18) })
    /// The accent (#FAA634) read straight from the asset: a fixed colour, never the inherited tint.
    static let accent = Color(UIColor(named: "AccentColor") ?? .systemOrange)
    /// The rim: a 2.5 pt dark line under a 1 pt light line, both at the shape's edge.
    static let rimDark = Color.black.opacity(0.4)
    static let rimLight = Color.white.opacity(0.8)
    static let halo = Color(UIColor { $0.userInterfaceStyle == .dark ? .black : .white })

    struct Halo: ViewModifier {
        func body(content: Content) -> some View {
            content.shadow(color: ClearLook.halo, radius: 1).shadow(color: ClearLook.halo.opacity(0.8), radius: 2.5)
        }
    }
}

extension View {
    /// The clear control surface in `shape`: fill, rim, and the hit area the same shape.
    func clearSurface(_ shape: AnyShape, pressed: Bool = false) -> some View {
        background(shape.fill(pressed ? ClearLook.pressedFill : ClearLook.fill))
            .overlay(shape.stroke(ClearLook.rimDark, lineWidth: 2.5).allowsHitTesting(false))
            .overlay(shape.stroke(ClearLook.rimLight, lineWidth: 1).allowsHitTesting(false))
            .clipShape(shape)
            .contentShape(shape)
    }
}

/// The two controls in the screen's bottom corners (the Click button and the trackpad) follow the open Duo's own
/// rounded display corner (the owner 2026-11-21: "the bottom left edge of the left click button and the bottom right edge
/// of the touchpad are covered by the actual physical curve of the Duo. Ideally, we have a rounded edge on both of
/// those corners to fit the screen."). The corner in the screen's corner is `.concentric`: SwiftUI's
/// `ConcentricRectangle` (iOS 26) gives it the container shape's radius minus the distance from it; with no closer
/// container shape that is the window, whose shape is the display's corner. The other three keep `fixed`.
enum CornerShapes {
    static func shape(fixed: CGFloat, concentric corner: HorizontalLayout.ScreenCorner?) -> AnyShape {
        let f = Edge.Corner.Style.fixed(fixed)
        let c = Edge.Corner.Style.concentric(minimum: f)
        return AnyShape(ConcentricRectangle(topLeadingCorner: f, topTrailingCorner: f,
                                            bottomLeadingCorner: corner == .bottomLeading ? c : f,
                                            bottomTrailingCorner: corner == .bottomTrailing ? c : f))
    }
}

/// A log line each time something that can change the column's look changes, with the reason (the owner's fading buttons,
/// 2026-11-21, not reproduced in the simulator): the keyboard up or down, the held-picture fade (half opacity), input
/// on or off, the system's dimmed tint (`tintAdjustmentMode`, set while the system shows something over the app),
/// and the window gaining or losing key status. Read with Console, subsystem com.example.duodesktop, category
/// "column".
struct ColumnLookWatch: UIViewRepresentable {
    let typing: Bool
    let held: Bool
    let acceptsInput: Bool
    static let log = Logger(subsystem: "com.example.duodesktop", category: "column")

    final class Probe: UIView {
        var last = ""
        private var tokens: [NSObjectProtocol] = []
        override func tintColorDidChange() {
            super.tintColorDidChange()
            ColumnLookWatch.log.notice("column tint mode \(self.tintAdjustmentMode == .dimmed ? "DIMMED" : "normal", privacy: .public)")
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else { return }
            for (name, what) in [(UIWindow.didBecomeKeyNotification, "window became key"),
                                 (UIWindow.didResignKeyNotification, "window lost key")] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { _ in
                    ColumnLookWatch.log.notice("column: \(what, privacy: .public)")
                })
            }
        }
    }

    func makeUIView(context: Context) -> Probe {
        let v = Probe()
        v.isUserInteractionEnabled = false
        return v
    }

    func updateUIView(_ v: Probe, context: Context) {
        let now = "keyboard \(typing ? "up" : "down"), held fade \(held ? "on" : "off"), input \(acceptsInput ? "on" : "off")"
        guard now != v.last else { return }
        v.last = now
        Self.log.notice("column look: \(now, privacy: .public)")
    }
}
