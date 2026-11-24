// Adapted from Glass Act Apps/iPad/CanvasView.swift at 486f11518da42d3ff7fac840a7bb9881d1425ca9. Glass Act is MIT
// licensed, Copyright (c) Brian Lopez; see Acknowledgements. Trimmed to presentation and the pointer, plus touch on the
// picture in both layouts (`directTouch`), mapped the way Apple maps touch on a MacBook Pro's touch display.
import GlassActCore
import GlassActSession
import GlassActTransport
import UIKit

/// §5 present path: each display-link tick starts at most one blit on the engine's queue (`SurfacePresenter`),
/// and the main thread only flips the content layer when it lands. The picture is aspect-fitted in the 16:9
/// frame from the negotiated canvas, which need not be 16:9 or 1920 wide (`PictureFit`).
final class CanvasView: UIView, UIGestureRecognizerDelegate {
    /// The old picture while a crossing slide runs (`crossingSlide`).
    private weak var slideSnapshot: UIView?
    /// How long the crossing slide takes.
    static let crossingSlideDuration: TimeInterval = 0.25

    /// An edge crossing's new screen is shown: the old picture slides out and the new one slides in, in the direction
    /// of the crossing (push right, dx 1 → content moves left). Reduce Motion: a cross-fade instead. Visual only: the
    /// layers move, touches and the trackpad carry on at once, a held drag is not touched. The old picture is a
    /// snapshot held at -W; the layer's sublayer transform runs +W → 0, so the snapshot ends at -W and the live
    /// picture at 0, both from one animation.
    func crossingSlide(dx: CGFloat, dy: CGFloat, reduceMotion: Bool = UIAccessibility.isReduceMotionEnabled) {
        guard bounds.width > 0, bounds.height > 0, dx != 0 || dy != 0,
              let snap = snapshotView(afterScreenUpdates: false) else { return }
        slideSnapshot?.removeFromSuperview()
        layer.removeAnimation(forKey: "crossingSlide")
        snap.frame = bounds
        snap.isUserInteractionEnabled = false
        addSubview(snap)
        slideSnapshot = snap
        if reduceMotion {
            UIView.animate(withDuration: Self.crossingSlideDuration, delay: 0,
                           options: [.curveEaseInOut, .allowUserInteraction, .beginFromCurrentState],
                           animations: { snap.alpha = 0 },
                           completion: { _ in snap.removeFromSuperview() })
            return
        }
        let w = bounds.width * dx, h = bounds.height * dy
        snap.layer.transform = CATransform3DMakeTranslation(-w, -h, 0)
        let anim = CABasicAnimation(keyPath: "sublayerTransform")
        anim.fromValue = CATransform3DMakeTranslation(w, h, 0)
        anim.toValue = CATransform3DIdentity
        anim.duration = Self.crossingSlideDuration * SimulatorSwitches.slideSlowdown
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak snap] in snap?.removeFromSuperview() }
        layer.add(anim, forKey: "crossingSlide")
        CATransaction.commit()
    }

    /// The live session's controller; nil while the session is being rejoined, when the last picture stays as it
    /// was (`attach`).
    private var controller: ViewerController?
    private var grid: TileGrid
    private var presenter: SurfacePresenter
    private var presenterGeneration = 0
    private var blitInFlight = false
    private var link: CADisplayLink?

    private let contentLayer = CALayer()
    private let cursorLayer = CALayer()

    /// The pointer as this phone last put it (canvas px): drawn at once, ahead of the Host's report a round
    /// trip later.
    private var localCursor: (x: Int, y: Int)?
    private var localCursorAt: CFTimeInterval = 0
    private static let localCursorHold: CFTimeInterval = 1.0
    /// The Host's pointer moved (canvas px).
    var onHostCursor: ((Int, Int) -> Void)?

    /// Touch on the picture is the Mac's pointer (`DirectTouchEngine`), in both layouts.
    var touchEngine: DirectTouchEngine?
    var directTouch = false {
        didSet {
            guard directTouch != oldValue else { return }
            isUserInteractionEnabled = directTouch
            if !directTouch { touchEngine?.releaseAll() }
            stopGlide()
            resetZoom()
        }
    }
    /// The phone turned: the picture's zoom starts again at fit, and any glide stops. (Held buttons are let go by
    /// `SessionParts.layoutChanged`.)
    func layoutChanged() {
        stopGlide()
        resetZoom()
    }
    /// The centred view: the picture shows a quarter of the Mac screen and follows the pointer so it stays in the
    /// centre; at the screen's edges the view stops and the pointer leaves the centre. The view moves here on the phone
    /// as the pointer is put, never waiting for the stream. A pinch steps views.
    var followPointer = false {
        didSet {
            guard followPointer != oldValue else { return }
            resetZoom()
        }
    }
    /// The horizontal view with our keyboard up: the height of the picture's space above the key row. The picture keeps
    /// the full-screen scale and moves only up and down so the pointer stays in the middle of that space
    /// (`TypingFollow`); nil = the whole screen.
    var typingVisibleHeight: CGFloat? {
        didSet {
            guard typingVisibleHeight != oldValue else { return }
            typingOffset = 0
            resetZoom()
            updateCursorLayer()
        }
    }
    /// With the keyboard up: the picture height (pixels) where typing goes on the Mac, kept in the middle of the
    /// space above the key row instead of the pointer (`AutoKeyboard`); nil = follow the pointer.
    var typingAimY: CGFloat? {
        didSet {
            guard typingAimY != oldValue else { return }
            updateCursorLayer()
        }
    }
    private var typingOffset: CGFloat = 0
    private var baseZoom: CGFloat {
        followPointer ? PictureFit.centredZoom : 1
    }

    // MARK: The outer screen (OuterScreen.swift)

    /// false: the open phone's views. true: the outer screen (`outerMode` picks vertical or free): one Mac pixel per
    /// point over the whole display, the display's top-left at Mac pixel `outerOrigin`; a tap clicks under the finger.
    /// No hold, two-finger tap, pinch or three-finger gestures.
    var outer = false {
        didSet {
            guard outer != oldValue else { return }
            for g in [hold, twoFingerTap, pinch, threeFinger] as [UIGestureRecognizer] { g.isEnabled = !outer }
            outerOrigin = nil
            resetZoom()
        }
    }
    /// The session's full picture width (before any slow-link shrink), so a half-size stream is drawn 2x.
    var fullWidth = 0 {
        didSet { if fullWidth != oldValue { layoutContent() } }
    }
    /// The outer screen's safe area in this view's points (sets the dialog spot's height); the view itself fills
    /// the whole display. nil = the whole view.
    var outerTouchable: CGRect? {
        didSet {
            guard outerTouchable != oldValue else { return }
            layoutContent()
            updateCursorLayer()
        }
    }
    private var touchable: CGRect { outerTouchable ?? CGRect(origin: .zero, size: bounds.size) }
    /// Vertical: one finger scrolls the picture up and down (sending nothing), no sideways movement, two fingers do
    /// nothing. Free: one finger drags on the Mac, two fingers move the picture in any direction.
    var outerMode = OuterMode.vertical {
        didSet {
            guard outerMode != oldValue else { return }
            layoutContent()
            updateCursorLayer()
        }
    }
    /// The Mac pixel at the display's top-left; nil = the opening place (vertical: the password spot; free: the
    /// dialog spot).
    private(set) var outerOrigin: CGPoint?
    /// The system keyboard's top in this view's points while it is up on the outer screen; nil while it is down.
    /// When it comes up, the place last tapped is kept visible above it (`OuterWindow.keepVisible`).
    var outerKeyboardTop: CGFloat? {
        didSet {
            guard outerKeyboardTop != oldValue else { return }
            if let top = outerKeyboardTop, let tapY = lastOuterTapY, let o = outerOrigin {
                outerOrigin = OuterWindow.keepVisible(o, tapY: tapY, keyboardTop: top)
            }
            layoutContent()
            updateCursorLayer()
        }
    }
    /// The Mac y of the last tap on the outer view (Mac pixels), or nil.
    private(set) var lastOuterTapY: CGFloat?
    private var macSize: CGSize {
        OuterWindow.macSize(gridWidth: grid.width, gridHeight: grid.height, fullWidth: fullWidth)
    }
    /// Vertical opens on the lock screen's password field (Mac locked, or a Host that does not say); else at the
    /// dialog spot.
    var outerOpensOnPassword = true
    private func outerHome(_ mode: OuterMode) -> CGPoint {
        mode == .vertical && outerOpensOnPassword
            ? OuterWindow.passwordSpot(mac: macSize, display: bounds.size, touchable: touchable,
                                       keyboardTop: outerKeyboardTop)
            : OuterWindow.dialogSpot(mac: macSize, display: bounds.size, touchable: touchable)
    }
    private func outerClamp(_ o: CGPoint, _ mode: OuterMode) -> CGPoint {
        if mode == .vertical {
            return OuterWindow.verticalClamp(o, mac: macSize, display: bounds.size, touchable: touchable,
                                             keyboardTop: outerKeyboardTop)
        }
        let h = OuterWindow.bottom(touchable: CGRect(origin: .zero, size: bounds.size), keyboardTop: outerKeyboardTop)
        return OuterWindow.clamp(o, mac: macSize, display: CGSize(width: bounds.width, height: h))
    }
    private var outerOriginNow: CGPoint { outerClamp(outerOrigin ?? outerHome(outerMode), outerMode) }

    /// The person chose another view: it starts where the picture is now (each view has its own opening place).
    func switchOuterMode(to mode: OuterMode) {
        guard mode != outerMode else { return }
        if outer, bounds.width > 0 { outerOrigin = outerOriginNow }
        outerMode = mode
    }

    /// Back to the opening place (each time the outer view appears, and choosing vertical): vertical's is the
    /// password spot, one scroll below the dialog spot. Only the picture moves.
    func returnToDialogSpot() {
        outerOrigin = nil
        lastOuterTapY = nil
        layoutContent()
        updateCursorLayer()
    }

    /// Two fingers moved by `d` points: the picture moves with them (fingers right = the picture moves right, so
    /// the display shows more of the Mac's left), stopped at the Mac screen's edges. Nothing is sent to the Mac.
    func moveOuterPicture(by d: CGPoint) {
        let o = outerOriginNow
        outerOrigin = outerClamp(CGPoint(x: o.x - d.x, y: o.y - d.y), outerMode)
        layoutContent()
        updateCursorLayer()
    }

    /// One finger dragging on the outer view: press where it first touched, follow it, let go where it lifts
    /// (the inner view's direct-touch drag, without the hold first).
    func outerDragBegan(at start: CGPoint, now: CGPoint) {
        guard let a = canvasPoint(start, clamp: true), let b = canvasPoint(now, clamp: true) else { return }
        touchEngine?.beginDrag(at: a, now: b)
    }
    func outerDragMoved(to p: CGPoint) {
        guard let q = canvasPoint(p, clamp: true) else { return }
        touchEngine?.dragMoved(to: q)
    }
    func outerDragEnded(at p: CGPoint?) {
        touchEngine?.endDrag(at: p.flatMap { canvasPoint($0, clamp: true) })
    }

    /// The outer view's tap: a click where the finger touched.
    func outerTap(at p: CGPoint, time: CFTimeInterval) {
        guard let q = canvasPoint(p) else { return }
        // From the first tap the picture stays where it is (it no longer follows the opening place), so a
        // keyboard coming up after it only shifts as far as keeping this place visible.
        outerOrigin = outerOriginNow
        lastOuterTapY = p.y + outerOriginNow.y
        touchEngine?.click(at: q, button: 0, time: time, slop: clickSlop)
    }
    /// Fingers on the picture: the view holds still under them (else a drag would chase itself), and catches up
    /// with the pointer when they lift.
    private var fingersDown = Set<ObjectIdentifier>()
    /// Local zoom (1 = fit) and the zoomed picture's offset from centred, in view points.
    private var zoom: CGFloat = 1
    private var pan = CGPoint.zero

    init(controller: ViewerController?, grid: TileGrid) {
        self.grid = grid
        presenter = SurfacePresenter(grid: grid)
        super.init(frame: .zero)
        backgroundColor = .black
        clipsToBounds = true
        isUserInteractionEnabled = false
        contentLayer.magnificationFilter = .linear
        contentLayer.minificationFilter = .trilinear
        contentLayer.contentsGravity = .resize
        contentLayer.actions = ["contents": NSNull(), "frame": NSNull(), "position": NSNull(),
                                "bounds": NSNull(), "transform": NSNull()]
        layer.addSublayer(contentLayer)
        cursorLayer.isHidden = true
        cursorLayer.magnificationFilter = .nearest
        cursorLayer.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull(), "contents": NSNull()]
        contentLayer.addSublayer(cursorLayer)
        isAccessibilityElement = true
        accessibilityLabel = "Mac screen"
        isMultipleTouchEnabled = true
        installGestures()
        attach(controller)
    }

    /// Changes the session behind the picture. nil (the session ended, a rejoin is on the way): the last picture and
    /// pointer stay exactly as they were, and nothing is drawn or read until a live session is attached. A new
    /// session starts a fresh presenter; the old picture stays until the new one's first frame lands.
    func attach(_ new: ViewerController?) {
        guard new !== controller else { return }
        controller?.onCursorUpdate = nil
        controller = new
        guard let new else { return }
        presenter = SurfacePresenter(grid: grid)
        presenterGeneration += 1
        new.onCursorUpdate = { [weak self, weak new] in
            guard let self, let new, self.controller === new else { return }
            self.updateCursorLayer()
            self.onHostCursor?(new.cursorX, new.cursorY)
        }
        reportPresentedScale()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    /// The size the picture view draws at now.
    var drawnGrid: TileGrid { grid }

    /// Brings the view to the session's size. The hosts (`CanvasHost`, `OuterCanvasHost`) call this on every update:
    /// it reconfigures when the size differs from the one drawn OR the model's size counter moved. Keyed on the
    /// counter alone, a switch to a screen of another size froze the picture (multi-screen build 4): SwiftUI first
    /// updated the host with the new counter and the old size, then skipped the update with the new size because the
    /// counter already matched, so the view kept a presenter of the old size and the library's frames of the new
    /// size never matched it (`SurfacePresenter.blit` returns nil on a size mismatch).
    func follow(grid wanted: TileGrid, generation: Int, lastGeneration: inout Int) {
        guard wanted != grid || generation != lastGeneration else { return }
        lastGeneration = generation
        reconfigure(grid: wanted)
    }

    func reconfigure(grid newGrid: TileGrid) {
        // The picture's size changed in session (1920 <-> 960 on a slow link): the phone's own pointer moves to the
        // same place in the new size, so the centred view stays on it.
        if let c = localCursor, grid.width > 0, grid.height > 0, newGrid.width != grid.width {
            localCursor = (c.x * newGrid.width / grid.width, c.y * newGrid.height / grid.height)
        }
        grid = newGrid
        presenter = SurfacePresenter(grid: newGrid)
        presenterGeneration += 1
        layoutContent()
        updateCursorLayer()
    }

    func startPresenting() {
        guard link == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(present))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stopPresenting() {
        link?.invalidate()
        link = nil
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startPresenting() } else { stopPresenting() }
    }

    @objc private func present() {
        guard !blitInFlight, let controller else { return }
        blitInFlight = true
        let presenter = self.presenter
        let generation = presenterGeneration
        let engine = controller.engine
        controller.queue.async { [weak self] in
            let frame = presenter.blit(from: engine)
            let first = frame == nil ? nil : controller.takeFirstPicture()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.blitLanded(frame, generation: generation)
                    if let first { controller.logFirstPicture(first, presentedUS: MonotonicClock.nowUS) }
                }
            }
        }
    }

    private func blitLanded(_ frame: SurfacePresenter.Frame?, generation: Int) {
        blitInFlight = false
        guard generation == presenterGeneration, let frame else { return }
        contentLayer.contents = frame.surface
        let flippedUS = SurfacePresenter.uptimeUS()
        controller?.recordPresent(blitUS: frame.blitUS,
                                 flipDelayUS: flippedUS > frame.completedUptimeUS ? flippedUS - frame.completedUptimeUS : 0)
    }

    private var screenScale: CGFloat { window?.screen.scale ?? traitCollection.displayScale }

    /// The picture's frame in view points: fit and centred, on whole device pixels.
    var pictureFrame: CGRect {
        if outer {
            return OuterWindow.pictureFrame(mac: macSize, origin: outerOriginNow, screenScale: screenScale)
        }
        if typingVisibleHeight != nil {
            let fit = PictureFit.frame(canvasWidth: grid.width, canvasHeight: grid.height, in: bounds.size,
                                       screenScale: screenScale)
            let s = max(1, screenScale)
            return fit.offsetBy(dx: 0, dy: (typingOffset * s).rounded() / s)
        }
        return PictureFit.zoomed(canvasWidth: grid.width, canvasHeight: grid.height, in: bounds.size,
                          screenScale: screenScale, zoom: zoom, pan: pan).frame
    }

    private func layoutContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        pan = PictureFit.zoomed(canvasWidth: grid.width, canvasHeight: grid.height, in: bounds.size,
                                screenScale: screenScale, zoom: zoom, pan: pan).pan
        contentLayer.frame = pictureFrame
        if outer, let image = SimulatorSwitches.outerPicture {
            if stillLayer.superlayer == nil { stillLayer.contents = image.cgImage; layer.insertSublayer(stillLayer, above: contentLayer) }
            stillLayer.frame = pictureFrame
        }
    }
    /// Simulator screenshots only (`--outer-picture`).
    private let stillLayer = CALayer()

    override func layoutSubviews() {
        super.layoutSubviews()
        layoutContent()
        updateCursorLayer()
        reportPresentedScale()
    }

    private func reportPresentedScale() {
        guard let controller, grid.width > 0, bounds.width > 0 else { return }
        let pct = min(100, Int(pictureFrame.width * screenScale / CGFloat(grid.width) * 100))
        controller.updatePresentedScale(max(1, pct))
    }

    // MARK: Pointer (cursor metadata, §5)

    private var localCursorActive: Bool {
        localCursor != nil && CACurrentMediaTime() - localCursorAt < Self.localCursorHold
    }

    func noteLocalCursor(_ x: Int, _ y: Int) {
        localCursor = (x, y)
        let at = CACurrentMediaTime()
        localCursorAt = at
        updateCursorLayer()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.localCursorHold) { [weak self] in
            guard let self, self.localCursorAt == at else { return }
            self.updateCursorLayer()
        }
    }

    private func updateCursorLayer() {
        // No session (being rejoined): the pointer stays where the last picture left it.
        guard let controller else { return }
        let local = localCursorActive ? localCursor : nil
        if followPointer, fingersDown.isEmpty {
            follow(x: CGFloat(local?.x ?? controller.cursorX), y: CGFloat(local?.y ?? controller.cursorY))
        } else if let visible = typingVisibleHeight, fingersDown.isEmpty {
            let fit = PictureFit.frame(canvasWidth: grid.width, canvasHeight: grid.height, in: bounds.size,
                                       screenScale: screenScale)
            let wanted = TypingFollow.offset(pointerY: typingAimY ?? CGFloat(local?.y ?? controller.cursorY),
                                             canvasHeight: grid.height, fit: fit, visibleHeight: visible)
            if wanted != typingOffset {
                typingOffset = wanted
                layoutContent()
            }
        }
        guard controller.cursorVisible || local != nil, let image = controller.cursorImage,
              grid.width > 0, contentLayer.bounds.width > 0 else {
            cursorLayer.isHidden = true
            return
        }
        let k = contentLayer.bounds.width / CGFloat(grid.width)
        let x = CGFloat(local?.x ?? controller.cursorX), y = CGFloat(local?.y ?? controller.cursorY)
        cursorLayer.contents = image
        cursorLayer.frame = CGRect(x: (x - controller.cursorHotspot.x) * k, y: (y - controller.cursorHotspot.y) * k,
                                   width: CGFloat(image.width) * k, height: CGFloat(image.height) * k)
        cursorLayer.isHidden = false
        #if targetEnvironment(simulator)
        // UI tests only (compiled out of device builds): the picture's size and where the pointer is drawn, as a
        // fraction of the picture.
        let tip = CGPoint(x: x * k, y: y * k)
        accessibilityValue = String(format: "picture %dx%d; pointer %.3f,%.3f", grid.width, grid.height,
                                    tip.x / contentLayer.bounds.width, tip.y / contentLayer.bounds.height)
        #endif
    }

    /// The centred view: moves the zoomed picture so (x, y) is in the middle, stopped at the screen's edges.
    private func follow(x: CGFloat, y: CGFloat) {
        guard grid.width > 0, grid.height > 0 else { return }
        zoom = baseZoom
        pan = PictureFit.pan(centring: x, y, canvasWidth: grid.width, canvasHeight: grid.height, in: bounds.size,
                             screenScale: screenScale, zoom: zoom)
        layoutContent()
    }

    func resetZoom() {
        zoom = baseZoom
        pan = .zero
        layoutContent()
        updateCursorLayer()
        reportPresentedScale()
    }

    // MARK: Touch on the picture, both layouts (Apple's touch-display MacBook mapping)

    private let pinch = UIPinchGestureRecognizer()
    private let twoFingerTap = UITapGestureRecognizer()
    private let threeFinger = UIPanGestureRecognizer()
    private let twoFingerPan = UIPanGestureRecognizer()
    private let hold = UILongPressGestureRecognizer()
    /// Two fingers: a scroll or a pinch, decided once per gesture; a pinch takes one step (`PinchLadder`).
    private var twoFinger = PinchTracker()
    private var lastScrollTranslation = CGPoint.zero
    /// A pinch on the picture: one step between the views (the session screen picks which, `PinchLadder`).
    var onPinchStep: ((PinchStep) -> Void)?
    /// The held finger's first point (view), to tell a still hold (right click) from a hold then move (drag).
    private var holdStartPoint = CGPoint.zero
    /// One-finger pan: scroll, or a swipe in from an edge (pointer to the edge, nothing else).
    private var oneFingerIsEdgeSwipe = false
    private var glide: CADisplayLink?
    private var glideVelocity = CGPoint.zero

    /// Apple: "Touching, briefly holding, and then moving" drags. No duration is published; 0.5 s is UIKit's
    /// standard touch and hold.
    static let holdDuration: TimeInterval = 0.5
    /// A held finger moving this far (points) is a drag, not a still hold.
    static let holdSlop: CGFloat = 10
    /// A one-finger swipe starting this close (points) to the picture's top or bottom edge, moving inward, is an
    /// edge swipe.
    static let edgeBand: CGFloat = 16
    /// A three-finger swipe needs this much travel (points) along its main direction.
    static let threeFingerTravel: CGFloat = 40

    private func canvasPoint(_ p: CGPoint, clamp: Bool = false) -> (Int, Int)? {
        DirectTouchEngine.canvasPoint(p, picture: pictureFrame, canvasWidth: grid.width, canvasHeight: grid.height,
                                      clamp: clamp)
    }

    /// Canvas pixels per view point: a scroll moves the Mac's content as far as the finger moved on the picture.
    private var canvasPerPoint: CGFloat { CGFloat(grid.width) / max(1, pictureFrame.width) }

    /// Taps this far apart on screen (24 pt) still count as one double click, in canvas pixels.
    private var clickSlop: CGFloat { 24 * canvasPerPoint }

    private func installGestures() {
        hold.addTarget(self, action: #selector(held(_:)))
        hold.minimumPressDuration = Self.holdDuration
        hold.allowableMovement = Self.holdSlop
        addGestureRecognizer(hold)

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.require(toFail: hold)
        addGestureRecognizer(tap)

        twoFingerTap.addTarget(self, action: #selector(twoFingerTapped(_:)))
        twoFingerTap.numberOfTouchesRequired = 2
        addGestureRecognizer(twoFingerTap)

        let oneFinger = UIPanGestureRecognizer(target: self, action: #selector(oneFingerPanned(_:)))
        oneFinger.maximumNumberOfTouches = 1
        addGestureRecognizer(oneFinger)

        twoFingerPan.addTarget(self, action: #selector(twoFingerPanned(_:)))
        twoFingerPan.minimumNumberOfTouches = 2
        twoFingerPan.maximumNumberOfTouches = 2
        twoFingerPan.delegate = self
        addGestureRecognizer(twoFingerPan)

        pinch.addTarget(self, action: #selector(pinched(_:)))
        pinch.delegate = self
        addGestureRecognizer(pinch)

        threeFinger.addTarget(self, action: #selector(threeFingerPanned(_:)))
        threeFinger.minimumNumberOfTouches = 3
        threeFinger.maximumNumberOfTouches = 3
        addGestureRecognizer(threeFinger)
    }

    func gestureRecognizer(_ g: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (g === pinch && other === twoFingerPan) || (g === twoFingerPan && other === pinch)
    }

    /// A new finger on the picture stops a glide, as on a Mac.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        stopGlide()
        for t in touches { fingersDown.insert(ObjectIdentifier(t)) }
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        fingersLifted(touches)
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        fingersLifted(touches)
        super.touchesCancelled(touches, with: event)
    }

    private func fingersLifted(_ touches: Set<UITouch>) {
        for t in touches { fingersDown.remove(ObjectIdentifier(t)) }
        // Gesture handlers run before this on the same touch; catch up with where they put the pointer.
        if fingersDown.isEmpty, followPointer { DispatchQueue.main.async { [weak self] in self?.updateCursorLayer() } }
    }

    @objc private func tapped(_ g: UITapGestureRecognizer) {
        guard directTouch, g.state == .ended else { return }
        if outer { return outerTap(at: g.location(in: self), time: CACurrentMediaTime()) }
        guard let p = canvasPoint(g.location(in: self)) else { return }
        touchEngine?.click(at: p, button: 0, time: CACurrentMediaTime(), slop: clickSlop)
    }

    /// Touch and hold: still, then lift = right click; then move = drag with the button held. The recogniser
    /// keeps tracking the finger after it begins, so a hold that moves is still this gesture.
    @objc private func held(_ g: UILongPressGestureRecognizer) {
        guard directTouch, let engine = touchEngine else { return }
        let here = g.location(in: self)
        switch g.state {
        case .began:
            guard let p = canvasPoint(here) else { return }
            holdStartPoint = here
            KeyFeedback.tap(.medium)
            engine.holdBegan(at: p)
        case .changed:
            guard engine.holdAt != nil else { return }
            if engine.dragging || hypot(here.x - holdStartPoint.x, here.y - holdStartPoint.y) > Self.holdSlop,
               let p = canvasPoint(here, clamp: true) {
                engine.holdMoved(to: p)
            }
        case .ended:
            guard engine.holdAt != nil else { return }
            engine.holdEnded(at: canvasPoint(here, clamp: true), time: CACurrentMediaTime(), slop: clickSlop)
        case .cancelled, .failed:
            engine.holdCancelled()
        default:
            break
        }
    }

    @objc private func twoFingerTapped(_ g: UITapGestureRecognizer) {
        guard directTouch, g.state == .ended, let p = canvasPoint(g.location(in: self)) else { return }
        touchEngine?.click(at: p, button: 1, time: CACurrentMediaTime(), slop: clickSlop)
    }

    /// Whether a one-finger swipe from `start` moving by `t` is a swipe in from the picture's top (true) or bottom
    /// (false) edge; nil if it isn't an edge swipe.
    static func edgeSwipe(start: CGPoint, translation t: CGPoint, picture: CGRect) -> Bool? {
        guard abs(t.y) > abs(t.x) else { return nil }
        if abs(start.y - picture.minY) <= edgeBand, t.y > 0 { return true }
        if abs(start.y - picture.maxY) <= edgeBand, t.y < 0 { return false }
        return nil
    }

    /// One finger moving at once scrolls (the content follows it); a quick swipe glides on after the lift. A swipe
    /// in from the top or bottom edge puts the pointer on that edge instead.
    @objc private func oneFingerPanned(_ g: UIPanGestureRecognizer) {
        guard directTouch, let engine = touchEngine else { return }
        let here = g.location(in: self)
        let t = g.translation(in: self)
        if outer, outerMode == .vertical {
            // Vertical: the drag scrolls the picture up and down (only the up-and-down part counts); nothing is sent.
            if g.state == .began || g.state == .changed {
                moveOuterPicture(by: CGPoint(x: 0, y: t.y))
                g.setTranslation(.zero, in: self)
            }
            return
        }
        if outer {
            // Free: a drag on the Mac under the finger.
            switch g.state {
            case .began: outerDragBegan(at: CGPoint(x: here.x - t.x, y: here.y - t.y), now: here)
            case .changed: outerDragMoved(to: here)
            case .ended: outerDragEnded(at: here)
            case .cancelled, .failed: outerDragEnded(at: nil)
            default: break
            }
            return
        }
        switch g.state {
        case .began:
            let start = CGPoint(x: here.x - t.x, y: here.y - t.y)
            if let top = Self.edgeSwipe(start: start, translation: t, picture: pictureFrame),
               let p = canvasPoint(start, clamp: true) {
                oneFingerIsEdgeSwipe = true
                engine.pointerToEdge(x: p.0, top: top)
                return
            }
            oneFingerIsEdgeSwipe = false
            guard let p = canvasPoint(start, clamp: true) else { return }
            engine.beginScroll(at: p)
            lastScrollTranslation = .zero
            fallthrough
        case .changed:
            guard !oneFingerIsEdgeSwipe else { return }
            let k = canvasPerPoint
            engine.scroll(dx: (t.x - lastScrollTranslation.x) * k, dy: (t.y - lastScrollTranslation.y) * k)
            lastScrollTranslation = t
        case .ended:
            guard !oneFingerIsEdgeSwipe else { return }
            let v = g.velocity(in: self)
            if hypot(v.x, v.y) > 300 { startGlide(velocity: v) }
        default:
            break
        }
    }

    // MARK: Glide after a quick one-finger swipe (Apple: "Scroll quickly: Quickly swipe your finger up or down")

    private func startGlide(velocity: CGPoint) {
        stopGlide()
        glideVelocity = velocity
        let link = CADisplayLink(target: self, selector: #selector(glideTick(_:)))
        link.add(to: .main, forMode: .common)
        glide = link
    }

    @objc private func glideTick(_ link: CADisplayLink) {
        let dt = max(0.001, link.targetTimestamp - link.timestamp)
        guard directTouch, let step = Self.glideStep(glideVelocity, dt: dt) else { return stopGlide() }
        glideVelocity = step.velocity
        let k = canvasPerPoint
        touchEngine?.scroll(dx: step.move.x * k, dy: step.move.y * k)
    }

    /// One display frame of a glide: the velocity (points/s) slows by 5%, and the content moves that far; nil once
    /// it is slower than 20 points/s.
    static func glideStep(_ v: CGPoint, dt: CGFloat) -> (velocity: CGPoint, move: CGPoint)? {
        let slowed = CGPoint(x: v.x * 0.95, y: v.y * 0.95)
        guard hypot(slowed.x, slowed.y) > 20 else { return nil }
        return (slowed, CGPoint(x: slowed.x * dt, y: slowed.y * dt))
    }

    func stopGlide() {
        glide?.invalidate()
        glide = nil
    }

    /// Three fingers: Mission Control (up), App Exposé (down), the next space (left or right), sent once at lift
    /// as the Mac's default shortcuts.
    @objc private func threeFingerPanned(_ g: UIPanGestureRecognizer) {
        guard directTouch, g.state == .ended, let swipe = Self.threeFingerSwipe(g.translation(in: self)) else { return }
        touchEngine?.threeFingerSwipe(swipe)
    }

    static func threeFingerSwipe(_ t: CGPoint) -> DirectTouchEngine.Swipe? {
        if abs(t.y) >= abs(t.x) {
            guard abs(t.y) >= threeFingerTravel else { return nil }
            return t.y < 0 ? .up : .down
        }
        guard abs(t.x) >= threeFingerTravel else { return nil }
        return t.x < 0 ? .left : .right
    }

    /// Two fingers: two fingers moving together scroll the Mac as a trackpad does; a pinch steps between the views
    /// instead of zooming freely. Decided once per gesture (`PinchTracker`).
    @objc private func twoFingerPanned(_ g: UIPanGestureRecognizer) {
        guard directTouch else { return }
        let t = g.translation(in: self)
        if outer {
            // Free: two fingers move the picture, and nothing is sent. Vertical: two fingers do nothing.
            if outerMode == .free, g.state == .began || g.state == .changed {
                moveOuterPicture(by: t)
                g.setTranslation(.zero, in: self)
            }
            return
        }
        switch g.state {
        case .began:
            lastScrollTranslation = t
        case .changed:
            if twoFinger.moved(t) {
                let start = g.location(in: self)
                if let p = canvasPoint(CGPoint(x: start.x - t.x, y: start.y - t.y), clamp: true) {
                    touchEngine?.beginScroll(at: p)
                }
            }
            switch twoFinger.mode {
            case .scroll:
                let k = canvasPerPoint
                touchEngine?.scroll(dx: (t.x - lastScrollTranslation.x) * k, dy: (t.y - lastScrollTranslation.y) * k)
            case .pinch:
                break // a pinch moves nothing
            case .undecided:
                return // don't use up the movement until decided
            }
            lastScrollTranslation = t
        default:
            if pinch.state != .changed && pinch.state != .began { twoFinger.reset() }
        }
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        guard directTouch, !outer else { return }
        switch g.state {
        case .began, .changed:
            if let step = twoFinger.scaled(g.scale) { onPinchStep?(step) }
        default:
            if twoFingerPan.state != .changed && twoFingerPan.state != .began { twoFinger.reset() }
        }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
        if newWindow == nil {
            stopGlide()
            touchEngine?.releaseAll()
        }
        super.willMove(toWindow: newWindow)
    }
}
