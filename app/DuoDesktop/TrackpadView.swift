import SwiftUI
import UIKit

/// The trackpad panel: raw touches turned into `TrackpadEngine` calls. One finger moves; a tap clicks; two
/// fingers tapping right-click; two fingers moving scroll (with a short glide after lift); a tap then touch and
/// hold, then move, drags. No drawn buttons: the whole pad clicks.
final class TrackpadUIView: UIView {
    var engine: TrackpadEngine?
    private static let tapMaxDuration: TimeInterval = 0.3
    private static let tapMaxTravel: CGFloat = 8

    private var touches: Set<UITouch> = []
    private var startTime: TimeInterval = 0
    private var startPoint = CGPoint.zero
    private var travel: CGFloat = 0
    private var maxTouches = 0
    private var pendingDrag = false
    private var lastCentroid = CGPoint.zero
    private var lastTime: TimeInterval = 0
    private var scrollVelocity = CGPoint.zero // pt per second
    private var glide: CADisplayLink?
    /// This touch scrolled with one finger while the Scroll button was held (it glides on a quick lift, as two do).
    private var buttonScrolled = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        // The surface is drawn by SwiftUI as Liquid Glass (`TrackpadView.surface`); this view only takes touches.
        backgroundColor = .clear
        isAccessibilityElement = true
        accessibilityLabel = "Trackpad"
        accessibilityHint = "Move one finger to move the pointer. Tap to click."
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    private func centroid(_ set: Set<UITouch>) -> CGPoint {
        guard !set.isEmpty else { return .zero }
        var sx: CGFloat = 0, sy: CGFloat = 0
        for t in set {
            let p = t.location(in: self)
            sx += p.x
            sy += p.y
        }
        return CGPoint(x: sx / CGFloat(set.count), y: sy / CGFloat(set.count))
    }

    override func touchesBegan(_ new: Set<UITouch>, with event: UIEvent?) {
        stopGlide()
        let now = event?.timestamp ?? CACurrentMediaTime()
        if touches.isEmpty {
            engine?.onFingerDown?(true)
            startTime = now
            startPoint = centroid(new)
            travel = 0
            maxTouches = 0
            pendingDrag = engine?.touchStartsDrag(at: now) ?? false
            engine?.resetScroll()
            scrollVelocity = .zero
            buttonScrolled = false
        }
        touches.formUnion(new)
        maxTouches = max(maxTouches, touches.count)
        if touches.count > 1 { pendingDrag = false }
        lastCentroid = centroid(touches)
        lastTime = now
    }

    override func touchesMoved(_ moved: Set<UITouch>, with event: UIEvent?) {
        guard let engine else { return }
        let now = event?.timestamp ?? CACurrentMediaTime()
        let c = centroid(touches)
        let dx = c.x - lastCentroid.x, dy = c.y - lastCentroid.y
        let dt = max(0.001, now - lastTime)
        lastCentroid = c
        lastTime = now
        travel += hypot(dx, dy)
        if maxTouches >= 2 {
            guard touches.count >= 2 else { return }
            engine.scroll(dx: dx, dy: dy)
            scrollVelocity = CGPoint(x: dx / dt, y: dy / dt)
        } else if engine.scrollHeld {
            // The Scroll button is held: the one finger scrolls, through the same path as two fingers.
            pendingDrag = false
            buttonScrolled = true
            engine.move(dx: dx, dy: dy, dt: dt)
            scrollVelocity = CGPoint(x: dx / dt, y: dy / dt)
        } else {
            if pendingDrag, !engine.dragging, travel > 2 {
                pendingDrag = false
                engine.beginDrag()
            }
            engine.move(dx: dx, dy: dy, dt: dt)
        }
    }

    override func touchesEnded(_ ended: Set<UITouch>, with event: UIEvent?) {
        finish(ended, event: event, cancelled: false)
    }

    override func touchesCancelled(_ ended: Set<UITouch>, with event: UIEvent?) {
        finish(ended, event: event, cancelled: true)
    }

    private func finish(_ ended: Set<UITouch>, event: UIEvent?, cancelled: Bool) {
        touches.subtract(ended)
        lastCentroid = centroid(touches)
        guard touches.isEmpty, let engine else { return }
        engine.onFingerDown?(false)
        let now = event?.timestamp ?? CACurrentMediaTime()
        let isTap = !cancelled && now - startTime <= Self.tapMaxDuration && travel <= Self.tapMaxTravel
        if engine.dragging {
            engine.endDrag()
        } else if isTap {
            KeyFeedback.tap()
            engine.tap(button: maxTouches >= 2 ? 1 : 0, at: startPoint, time: now)
        } else if maxTouches >= 2 || (buttonScrolled && engine.scrollHeld), !cancelled, hypot(scrollVelocity.x, scrollVelocity.y) > 60,
                  now - lastTime < 0.08 {
            startGlide()
        }
        pendingDrag = false
    }

    // MARK: Glide after a two-finger scroll

    private func startGlide() {
        let link = CADisplayLink(target: self, selector: #selector(glideTick(_:)))
        link.add(to: .main, forMode: .common)
        glide = link
    }

    @objc private func glideTick(_ link: CADisplayLink) {
        let dt = max(0.001, link.targetTimestamp - link.timestamp)
        scrollVelocity.x *= 0.93
        scrollVelocity.y *= 0.93
        guard hypot(scrollVelocity.x, scrollVelocity.y) > 20 else { return stopGlide() }
        engine?.scroll(dx: scrollVelocity.x * dt, dy: scrollVelocity.y * dt)
    }

    fileprivate func stopGlide() {
        glide?.invalidate()
        glide = nil
    }

    /// Stops the glide, and makes a finger still down count as neither a tap nor a drag when it lifts.
    func cancelGlideAndTouches() {
        stopGlide()
        pendingDrag = false
        scrollVelocity = .zero
        travel = .infinity // a finger still down then lifting is not a tap
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil { engine?.releaseAll() }
        super.willMove(toWindow: newWindow)
    }
}

struct TrackpadView: UIViewRepresentable {
    let engine: TrackpadEngine

    /// The trackpad's surface: one large flat key, the keys' fill and corner (KeyLook; the owner 2026-11-20: the system
    /// keyboard's flat grey look), like the system keyboard's space bar.
    static let cornerRadius: CGFloat = KeyLook.cornerRadius

    func makeUIView(context: Context) -> TrackpadUIView {
        let v = TrackpadUIView()
        v.attach(engine)
        return v
    }

    func updateUIView(_ v: TrackpadUIView, context: Context) { v.engine = engine }
}

extension TrackpadUIView {
    /// Connects the engine's release to this view's glide.
    func attach(_ engine: TrackpadEngine) {
        self.engine = engine
        engine.onReleaseAll = { [weak self] in self?.cancelGlideAndTouches() }
        engine.onScrollReleased = { [weak self] in self?.stopGlide() }
    }
}
