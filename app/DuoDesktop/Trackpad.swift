import CoreGraphics
import Foundation

/// The trackpad's behaviour, apart from any view (plan §5). It keeps its own pointer in canvas pixels and sends
/// absolute INPUT moves to it. Main thread.
final class TrackpadEngine {
    /// Gain (Mac pixels per pad point) from 2 at slow speed to 6 at `fastSpeed` and above, smoothly.
    static let slowGain = 2.0
    static let fastGain = 6.0
    static let fastSpeed = 1000.0 // pt/s
    /// Taps this close in time and distance (pad points) are one double or triple click.
    static let multiClickInterval: TimeInterval = 0.35
    static let multiClickSlop = 10.0

    let sink: any InputSink
    /// Wraps clicks so latched keyboard modifiers apply (Command-click).
    var modifierWrap: (() -> Void) -> Void = { $0() }
    /// The pointer moved here (canvas px): the view draws it at once, ahead of the Host's report.
    var onPointer: ((Int, Int) -> Void)?

    private(set) var canvasWidth = 1920
    private(set) var canvasHeight = 1080
    /// The session's full picture width (the size before any shrink on a slow link). The gain is tuned for the full
    /// picture: on a shrunk one it is scaled by width ÷ full width, so the pointer crosses the Mac at the same
    /// speed whatever size is sent (the owner 2026-11-20: "This needs to work on all connections").
    private(set) var fullWidth = 1920
    private(set) var x = 960.0
    private(set) var y = 540.0
    private(set) var dragging = false
    private var lastTap: (point: CGPoint, time: TimeInterval, count: Int, button: Int)?
    /// The click buttons held down (0 left, 1 right), and the last press, for counting double clicks.
    private(set) var heldButtons: Set<Int> = []
    private var lastPress: (time: TimeInterval, count: Int, button: Int, x: Int, y: Int)?
    private var scrollRemainder = CGPoint.zero
    private var touchedYet = false

    init(sink: any InputSink) { self.sink = sink }

    var pixel: (Int, Int) { (Int(x.rounded(.down)), Int(y.rounded(.down))) }

    func setCanvas(width: Int, height: Int, fullWidth full: Int? = nil) {
        guard width > 0, height > 0 else { return }
        fullWidth = max(width, full ?? width)
        if canvasWidth > 0, width != canvasWidth || height != canvasHeight {
            x = x / Double(canvasWidth) * Double(width)
            y = y / Double(canvasHeight) * Double(height)
        }
        canvasWidth = width
        canvasHeight = height
        clamp()
    }

    /// The Host's pointer (CURSOR_POS): adopted until the pad is first used, so the pad starts where the Mac's
    /// pointer is.
    func hostPointer(x hx: Int, y hy: Int) {
        guard !touchedYet else { return }
        x = Double(hx)
        y = Double(hy)
        clamp()
    }

    // MARK: Crossing an edge (plan item 13, M5)

    /// The pointer was pushed to canvas (x, y), outside the picture: true when the session starts a switch to the
    /// screen there (false: a wall, the pointer stops at the edge as before).
    var onPushPastEdge: ((Double, Double, Int, Int) -> Bool)?
    /// A finger went down on the pad (true) or the last one lifted (false): a neighbour of another shape keeps
    /// the old layout until the finger lifts (plan item 13).
    var onFingerDown: ((Bool) -> Void)?
    /// A switch from an edge crossing is under way: moves are held back.
    private(set) var switching = false
    /// Button ups that came during the switch (review finding 2): sent once, at the pointer the Host confirmed.
    private(set) var pendingUps: [(button: Int, count: Int)] = []

    /// The switch is over. `at`: the pointer the Host placed, in the new picture (`width` x `height` pixels); nil
    /// when it failed or got no answer (the pointer stays where it was). Held-back button ups go now, once.
    func switchEnded(at point: (x: Int, y: Int, width: Int, height: Int)?) {
        guard switching else { return }
        switching = false
        if let point, point.width > 0, point.height > 0 {
            canvasWidth = point.width
            canvasHeight = point.height
            x = Double(point.x)
            y = Double(point.y)
            clamp()
            onPointer?(pixel.0, pixel.1)
        }
        let ups = pendingUps
        pendingUps = []
        let p = pixel
        for up in ups { sink.sendInput(kind: InputKind.buttonUp, x: p.0, y: p.1, a: up.count, b: up.button) }
    }

    /// The pointer was put here another way (touch on the picture in the horizontal layout): the pad carries on
    /// from it when the phone is turned upright.
    func adopt(x px: Int, y py: Int) {
        x = Double(px)
        y = Double(py)
        clamp()
    }

    static func gain(speed: Double) -> Double {
        let t = min(1, max(0, speed / fastSpeed))
        let s = t * t * (3 - 2 * t) // smoothstep
        return slowGain + (fastGain - slowGain) * s
    }

    /// One finger moved by (dx, dy) pad points over `dt` seconds: the pointer moves, or, while the Scroll button
    /// is held, the Mac scrolls at the pointer exactly as a two-finger scroll does.
    func move(dx: Double, dy: Double, dt: Double) {
        touchedYet = true
        if scrollHeld { return scroll(dx: dx, dy: dy) }
        // Moves pause while the Mac switches screens after an edge crossing (plan item 13).
        if switching { return }
        let speed = dt > 0 ? hypot(dx, dy) / dt : 0
        let g = Self.gain(speed: speed) * Double(canvasWidth) / Double(max(1, fullWidth))
        x += dx * g
        y += dy * g
        // Pushed past an edge: if the Mac has a screen there, the session starts the switch and the Host puts the
        // pointer on it (a drag if a button is held); nothing more is sent until `switchEnded`.
        if x < 0 || y < 0 || x > Double(canvasWidth - 1) || y > Double(canvasHeight - 1),
           onPushPastEdge?(x, y, canvasWidth, canvasHeight) == true {
            switching = true
            clamp()
            onPointer?(pixel.0, pixel.1)
            return
        }
        clamp()
        let p = pixel
        onPointer?(p.0, p.1)
        sink.sendInput(kind: InputKind.move, x: p.0, y: p.1, a: 0, b: 0)
    }

    /// A tap: button 0 (one finger) or 1 (two fingers), at `padPoint` for click counting.
    func tap(button: Int, at padPoint: CGPoint, time: TimeInterval) {
        touchedYet = true
        var count = 1
        if let last = lastTap, last.button == button, time - last.time <= Self.multiClickInterval,
           hypot(padPoint.x - last.point.x, padPoint.y - last.point.y) <= Self.multiClickSlop {
            count = last.count % 3 + 1
        }
        lastTap = (padPoint, time, count, button)
        let p = pixel
        modifierWrap {
            sink.sendInput(kind: InputKind.move, x: p.0, y: p.1, a: 0, b: 0)
            sink.sendInput(kind: InputKind.buttonDown, x: p.0, y: p.1, a: count, b: button)
            sink.sendInput(kind: InputKind.buttonUp, x: p.0, y: p.1, a: count, b: button)
        }
    }

    /// Whether a touch landing at `time` follows a tap closely enough to start a drag (tap, then touch and hold).
    func touchStartsDrag(at time: TimeInterval) -> Bool {
        guard let last = lastTap, last.button == 0 else { return false }
        return time - last.time <= Self.multiClickInterval
    }

    func beginDrag() {
        guard !dragging else { return }
        touchedYet = true
        dragging = true
        lastTap = nil
        // The Left click button already holds the Mac's button down: nothing more to press.
        guard !heldButtons.contains(0) else { return }
        let p = pixel
        sink.sendInput(kind: InputKind.buttonDown, x: p.0, y: p.1, a: 1, b: 0)
    }

    func endDrag() {
        guard dragging else { return }
        dragging = false
        guard !heldButtons.contains(0) else { return }
        if switching { return pendingUps.append((0, 1)) }
        let p = pixel
        sink.sendInput(kind: InputKind.buttonUp, x: p.0, y: p.1, a: 1, b: 0)
    }

    // MARK: Click buttons (the owner 2026-11-20: "There should be a button under the left thumb for click.")

    /// Presses closer together than this, with the pointer still, count as a double (or triple) click. The Host
    /// posts the count the phone sends (`HostController`, kind 2: "The viewer's click count"), so the phone does
    /// the counting; 0.5 s is the Mac's default double-click speed.
    static let buttonMultiClickInterval: TimeInterval = 0.5
    /// How far (Mac pixels) the pointer may move between presses of one double click.
    static let buttonMultiClickSlop = 4

    /// A click button went down: the Mac's button goes down at the pointer, and stays down until
    /// `releaseButton`, so moving on the trackpad meanwhile drags. Held keyboard modifiers apply as to a
    /// trackpad click (they are pressed around the button's down).
    func pressButton(_ button: Int, time: TimeInterval) {
        guard !heldButtons.contains(button) else { return }
        touchedYet = true
        heldButtons.insert(button)
        let p = pixel
        var count = 1
        if let last = lastPress, last.button == button, time - last.time <= Self.buttonMultiClickInterval,
           abs(p.0 - last.x) <= Self.buttonMultiClickSlop, abs(p.1 - last.y) <= Self.buttonMultiClickSlop {
            count = last.count % 3 + 1
        }
        lastPress = (time, count, button, p.0, p.1)
        // A trackpad drag already holds the left button down.
        if button == 0 && dragging { return }
        modifierWrap {
            sink.sendInput(kind: InputKind.move, x: p.0, y: p.1, a: 0, b: 0)
            sink.sendInput(kind: InputKind.buttonDown, x: p.0, y: p.1, a: count, b: button)
        }
    }

    /// The click button came up: the Mac's button goes up where the pointer is now.
    func releaseButton(_ button: Int) {
        guard heldButtons.remove(button) != nil else { return }
        if button == 0 && dragging { return }
        if switching { return pendingUps.append((button, lastPress?.count ?? 1)) }
        let p = pixel
        sink.sendInput(kind: InputKind.buttonUp, x: p.0, y: p.1, a: lastPress?.count ?? 1, b: button)
    }

    // MARK: Scroll button (the owner 2026-11-20: "If you press that button and scroll on the trackpad, then it scrolls.")

    /// The Scroll button is down: one finger on the trackpad scrolls instead of moving the pointer.
    private(set) var scrollHeld = false
    /// The Scroll button came up: the view stops a glide at once (set by `TrackpadUIView`).
    var onScrollReleased: (() -> Void)?

    /// The Scroll button went down. Nothing is sent: a press alone does nothing on the Mac.
    func pressScroll() {
        touchedYet = true
        scrollHeld = true
    }

    /// The Scroll button came up: one finger moves the pointer again from the next movement on.
    func releaseScroll() {
        guard scrollHeld else { return }
        scrollHeld = false
        resetScroll()
        onScrollReleased?()
    }

    /// Two fingers moved by (dx, dy) pad points: scroll in points, the content following the fingers (a Mac
    /// trackpad's natural direction). Points are the Mac's own (the Host posts them unscaled, kind 7), so the
    /// distance is the same whatever picture size is being sent.
    func scroll(dx: Double, dy: Double) {
        scrollRemainder.x += dx
        scrollRemainder.y += dy
        let sx = scrollRemainder.x.rounded(.towardZero), sy = scrollRemainder.y.rounded(.towardZero)
        scrollRemainder.x -= sx
        scrollRemainder.y -= sy
        guard sx != 0 || sy != 0 else { return }
        let p = pixel
        sink.sendInput(kind: InputKind.scrollPoints, x: p.0, y: p.1, a: Int(sx), b: Int(sy))
    }

    func resetScroll() { scrollRemainder = .zero }

    /// The view's scroll glide stops here (set by `TrackpadUIView`).
    var onReleaseAll: (() -> Void)?

    /// Lifts a held button and stops any glide (the view is hiding, the app is leaving the foreground, or the
    /// session is ending).
    func releaseAll() {
        onReleaseAll?()
        for b in heldButtons.sorted() { releaseButton(b) }
        releaseScroll()
        endDrag()
        resetScroll()
        // A disconnect or a failed switch: nothing waits for the Host's answer; held ups go where the pointer is.
        switchEnded(at: nil)
    }

    private func clamp() {
        x = min(Double(canvasWidth - 1), max(0, x))
        y = min(Double(canvasHeight - 1), max(0, y))
    }
}
