import CoreGraphics

/// The pinch steps between the views:
///
///     Follow Pointer --pinch in--> Whole Screen --pinch in--> All Screens (more than one screen only)
///     Whole Screen --pinch out--> Follow Pointer
///
/// No pinch in All Screens. One step per pinch. This replaces the regular view's free pinch-to-zoom: Follow Pointer is
/// the zoomed view.
enum PinchStep: Equatable { case pinchIn, pinchOut }

enum PinchLadder {
    enum Outcome: Equatable {
        case view(SessionView)
        case allScreens
        case nothing
    }

    /// `view` is the view on screen. `followPointerOffered`: false in the horizontal view, which has only the whole
    /// screen (Follow Pointer is upright only), so there a pinch out does nothing.
    static func next(from view: SessionView, step: PinchStep, multiScreen: Bool, overview: Bool,
                     followPointerOffered: Bool = true) -> Outcome {
        guard !overview else { return .nothing }
        switch (view, step) {
        case (.centred, .pinchIn): return .view(.regular)
        case (.centred, .pinchOut): return .nothing
        case (.regular, .pinchIn): return multiScreen ? .allScreens : .nothing
        case (.regular, .pinchOut): return followPointerOffered ? .view(.centred) : .nothing
        #if DUO_TERMINAL
        case (.terminal, _): return .nothing
        #endif
        #if DUO_JETKVM
        case (.jetkvm, _): return .nothing
        #endif
        }
    }
}

/// One two-finger gesture on the picture: decided once, as a scroll or a pinch, by whichever shows first. A scroll
/// is both fingers travelling together (`scrollTravel` points); a pinch is the gap between them changing
/// (`decideScale`). Once it is a scroll it never steps; once it is a pinch it steps once, when the gap has shrunk to
/// `inScale` or grown to `outScale` of where it started, however far the fingers then go.
struct PinchTracker {
    enum Mode: Equatable { case undecided, scroll, pinch }

    /// Travel (points) that makes two fingers a scroll (unchanged from before the ladder).
    static let scrollTravel: CGFloat = 12
    /// A change in the gap of 8% makes it a pinch (unchanged from before the ladder).
    static let decideScale: CGFloat = 0.08
    /// The step: the gap down to 75% (pinch in) or up to 133% (pinch out). On fingers 60 pt apart that is a 15–20 pt
    /// change, well past the 8% that decides a pinch, so a scroll that drifts apart a little never gets there.
    static let inScale: CGFloat = 0.75
    static let outScale: CGFloat = 1 / 0.75

    private(set) var mode = Mode.undecided
    private(set) var stepped = false

    /// Both fingers lifted: the next two-finger touch is a new gesture.
    mutating func reset() {
        mode = .undecided
        stepped = false
    }

    /// The fingers' shared travel. True when this makes the gesture a scroll (start scrolling now).
    mutating func moved(_ t: CGPoint) -> Bool {
        guard mode == .undecided, hypot(t.x, t.y) > Self.scrollTravel else { return false }
        mode = .scroll
        return true
    }

    /// The gap's scale since the gesture began. Returns the step to take, at most once per gesture.
    mutating func scaled(_ scale: CGFloat) -> PinchStep? {
        if mode == .undecided, abs(scale - 1) > Self.decideScale { mode = .pinch }
        guard mode == .pinch, !stepped else { return nil }
        if scale <= Self.inScale { stepped = true; return .pinchIn }
        if scale >= Self.outScale { stepped = true; return .pinchOut }
        return nil
    }
}
