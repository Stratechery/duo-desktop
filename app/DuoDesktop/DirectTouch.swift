// The touch mapping is adapted from Glass Act Apps/iPad/CanvasView.swift at 486f11518da42d3ff7fac840a7bb9881d1425ca9
// (the GlassActViewer library itself has no touch mode; the iPad app does). Glass Act is MIT licensed, Copyright (c)
// Brian Lopez; see Acknowledgements.
import CoreGraphics
import Foundation

/// Touch on the Mac's picture, in both layouts, the way Apple maps touch on a touch-display MacBook. The table and its
/// sources are in project notes (Touch on the Mac picture). In short: tap = click where you touch (quick taps are a
/// double or triple click); one finger moving at once = scroll, content following the finger, with a glide after a
/// quick swipe; touch and hold, then move = drag with the button held; touch and hold, then lift without moving = right
/// click; pinch = step between the phone's views (`PinchLadder`; the Mac can't be sent a magnify); three-finger swipes
/// = the Mac's default Mission Control / App Exposé / Spaces shortcuts; a swipe in from the picture's top or bottom
/// edge = the pointer to that edge (shows a hidden menu bar or Dock). Positions are canvas pixels, from the negotiated
/// canvas (`setCanvas`). Main thread.
final class DirectTouchEngine {
    let sink: any InputSink
    /// The pointer moved here (canvas px): drawn at once, ahead of the Host's report.
    var onPointer: ((Int, Int) -> Void)?
    /// Held modifiers around a click (Command-click), as the upright trackpad's click; set by the session.
    var modifierWrap: (() -> Void) -> Void = { $0() }
    /// Sends the three-finger swipes' keyboard shortcuts; set by the session.
    weak var keys: MacKeyboardEngine?

    private(set) var canvasWidth = 1920
    private(set) var canvasHeight = 1080
    private(set) var dragging = false
    private var last: (Int, Int)?
    private var clicks = ClickCounter()
    private var scrollRemainder = CGPoint.zero
    /// Where the current scroll started (the pointer is put there, so the Mac scrolls what is under the finger).
    private var scrollAt: (Int, Int)?
    /// A touch held still long enough: where it touched. Moving then drags; lifting then is a right click.
    private(set) var holdAt: (Int, Int)?

    init(sink: any InputSink) { self.sink = sink }

    /// The session's full picture width (before any shrink on a slow link): scrolls are sent in full-size pixels,
    /// so a finger moves the Mac's content the same distance whatever size is being sent.
    private(set) var fullWidth = 1920

    func setCanvas(width: Int, height: Int, fullWidth full: Int? = nil) {
        guard width > 0, height > 0 else { return }
        fullWidth = max(width, full ?? width)
        if width != canvasWidth || height != canvasHeight {
            // A touch in progress carries on at the same place on the Mac in the new picture's pixels.
            let fx = Double(width) / Double(canvasWidth), fy = Double(height) / Double(canvasHeight)
            func rescale(_ p: (Int, Int)?) -> (Int, Int)? {
                p.map { (min(width - 1, Int(Double($0.0) * fx)), min(height - 1, Int(Double($0.1) * fy))) }
            }
            last = rescale(last)
            scrollAt = rescale(scrollAt)
            holdAt = rescale(holdAt)
        }
        canvasWidth = width
        canvasHeight = height
    }

    /// A view point to a canvas pixel, through the picture's rectangle on screen. Nil off the picture (in the
    /// black bands); `clamp` pins it to the edge instead, for drags and scrolls that leave it.
    static func canvasPoint(_ p: CGPoint, picture: CGRect, canvasWidth: Int, canvasHeight: Int,
                            clamp: Bool = false) -> (Int, Int)? {
        guard picture.width > 0, picture.height > 0, canvasWidth > 0, canvasHeight > 0 else { return nil }
        var cx = Int(((p.x - picture.minX) / picture.width * CGFloat(canvasWidth)).rounded(.down))
        var cy = Int(((p.y - picture.minY) / picture.height * CGFloat(canvasHeight)).rounded(.down))
        if clamp {
            cx = min(canvasWidth - 1, max(0, cx))
            cy = min(canvasHeight - 1, max(0, cy))
        }
        guard cx >= 0, cy >= 0, cx < canvasWidth, cy < canvasHeight else { return nil }
        return (cx, cy)
    }

    func point(_ p: CGPoint, picture: CGRect, clamp: Bool = false) -> (Int, Int)? {
        Self.canvasPoint(p, picture: picture, canvasWidth: canvasWidth, canvasHeight: canvasHeight, clamp: clamp)
    }

    private func send(_ kind: UInt8, _ p: (Int, Int), a: Int = 0, b: Int = 0) {
        if kind <= InputKind.buttonUp {
            last = p
            onPointer?(p.0, p.1)
        }
        sink.sendInput(kind: kind, x: p.0, y: p.1, a: a, b: b)
    }

    /// A whole click at `p` (button 0 left, 1 right): the pointer moves there first, so the Mac's hover state sees
    /// it arrive. `slop`: how far apart (canvas px) taps can be and still count as one double click.
    func click(at p: (Int, Int), button: Int, time: CFTimeInterval, slop: CGFloat = 40) {
        let count = clicks.press(at: CGPoint(x: p.0, y: p.1), button: button, time: time, slop: slop)
        send(InputKind.move, p)
        modifierWrap {
            send(InputKind.buttonDown, p, a: count, b: button)
            send(InputKind.buttonUp, p, a: count, b: button)
        }
    }

    /// One finger started dragging: press where it first touched, then follow it.
    func beginDrag(at start: (Int, Int), now: (Int, Int)) {
        guard !dragging else { return }
        dragging = true
        send(InputKind.move, start)
        send(InputKind.buttonDown, start, a: 1, b: 0)
        send(InputKind.move, now)
    }

    func dragMoved(to p: (Int, Int)) {
        guard dragging else { return }
        send(InputKind.move, p)
    }

    func endDrag(at p: (Int, Int)?) {
        guard dragging else { return }
        dragging = false
        send(InputKind.buttonUp, p ?? last ?? (0, 0), a: 1, b: 0)
    }

    // MARK: Touch and hold (Apple: "Touching, briefly holding, and then moving emulates mouseDown(with:), followed
    // by mouseDragged(with:) as it moves, and mouseUp(with:) on lift." / "Touching and holding without movement
    // emulates rightMouseDown(with:), and rightMouseUp(with:) on lift.")

    /// A finger has been held still at `p` long enough. Nothing is sent yet: what it does depends on what follows.
    func holdBegan(at p: (Int, Int)) { holdAt = p }

    /// The held finger moved (past the slop): press where it was held, then follow it.
    func holdMoved(to p: (Int, Int)) {
        guard let start = holdAt else { return }
        if dragging { dragMoved(to: p) } else { beginDrag(at: start, now: p) }
    }

    /// The held finger lifted: the end of a drag, or, if it never moved, a right click where it was held.
    func holdEnded(at p: (Int, Int)?, time: CFTimeInterval, slop: CGFloat = 40) {
        defer { holdAt = nil }
        if dragging {
            endDrag(at: p)
        } else if let start = holdAt {
            click(at: start, button: 1, time: time, slop: slop)
        }
    }

    /// The system took the touch (or the layout changed): let go, and no right click.
    func holdCancelled() {
        holdAt = nil
        endDrag(at: nil)
    }

    // MARK: Scrolling (Apple: "Touching and then immediately panning emulates a trackpad scroll."; "Scroll or
    // pan: Drag with one finger in any direction"; "Scroll quickly: Quickly swipe your finger up or down")

    /// A scroll starts at `p`: the pointer goes there first, because a Mac scrolls whatever is under its pointer.
    func beginScroll(at p: (Int, Int)) {
        scrollRemainder = .zero
        scrollAt = p
        send(InputKind.move, p)
    }

    /// The content moves by (dx, dy) canvas pixels, following the finger (a Mac trackpad's natural direction).
    /// Used for one finger, its glide, and two fingers.
    /// (dx, dy) in picture pixels. The Host posts scroll amounts as Mac points, unscaled (kind 7), so they are
    /// first put in full-size pixels: at half size each pixel the finger crosses is two.
    func scroll(dx: CGFloat, dy: CGFloat) {
        let k = CGFloat(fullWidth) / CGFloat(max(1, canvasWidth))
        scrollRemainder.x += dx * k
        scrollRemainder.y += dy * k
        let sx = scrollRemainder.x.rounded(.towardZero), sy = scrollRemainder.y.rounded(.towardZero)
        scrollRemainder.x -= sx
        scrollRemainder.y -= sy
        guard sx != 0 || sy != 0 else { return }
        let p = scrollAt ?? last ?? (0, 0)
        sink.sendInput(kind: InputKind.scrollPoints, x: p.0, y: p.1, a: Int(sx), b: Int(sy))
    }

    func resetScroll() { scrollRemainder = .zero }

    // MARK: Edge swipes (Apple: "Show the Dock (when hidden): Swipe with one finger from the bottom of the screen";
    // "Show the menu bar (when hidden): Swipe with one finger from the top edge of the screen")

    /// A swipe in from the picture's top or bottom edge: the pointer goes to that edge at the finger's x, which is
    /// what shows a hidden menu bar or Dock on a Mac without touch. No button, no scroll.
    func pointerToEdge(x: Int, top: Bool) {
        send(InputKind.move, (min(canvasWidth - 1, max(0, x)), top ? 0 : canvasHeight - 1))
    }

    // MARK: Three-finger swipes (Apple: "Open Mission Control: Swipe up on the screen with three fingers"; App
    // Exposé: "Swipe down on the screen with three fingers"; "Switch between spaces: Swipe with three fingers left
    // or right")

    enum Swipe { case up, down, left, right }

    /// The Mac's default keyboard shortcut for each: Mission Control ⌃↑, App Exposé ⌃↓, a space to the right ⌃→
    /// (fingers moving left, the space follows them in from the right), a space to the left ⌃←.
    static func shortcut(for swipe: Swipe) -> MacShortcut {
        switch swipe {
        case .up: MacShortcut.missionControl
        case .down: MacShortcut.appExpose
        case .left: MacShortcut.spaceRight
        case .right: MacShortcut.spaceLeft
        }
    }

    func threeFingerSwipe(_ swipe: Swipe) { keys?.sendShortcut(Self.shortcut(for: swipe)) }

    /// Lets go of a held button (the phone turned, the app is leaving, or the session is ending).
    func releaseAll() {
        holdAt = nil
        endDrag(at: nil)
        resetScroll()
    }
}

/// Click counting for taps: a tap soon after the last one, near it, with the same button, is the next click of a
/// double or triple click. From Glass Act's iPad `ClickCounter`.
struct ClickCounter {
    static let interval: CFTimeInterval = 0.4
    private var last: (point: CGPoint, button: Int, time: CFTimeInterval, count: Int)?

    mutating func press(at point: CGPoint, button: Int, time: CFTimeInterval, slop: CGFloat) -> Int {
        var count = 1
        if let last, last.button == button, time - last.time < Self.interval,
           hypot(point.x - last.point.x, point.y - last.point.y) <= slop {
            count = last.count % 3 + 1
        }
        last = (point, button, time, count)
        return count
    }
}
