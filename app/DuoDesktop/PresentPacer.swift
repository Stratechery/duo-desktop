import Foundation

/// Heat, with no loss of smoothness: the picture's display timer runs at full rate (120 Hz where the phone allows)
/// while anything is happening, and rests only after a second with nothing new and no finger on the picture. Any new
/// picture data, touch, input sent to the Mac, size change or slide wakes it at once.
///
/// The library has no "new picture data" call, so while resting a cheap watch on the library's own queue reads
/// `ViewerEngine.contentVersion` (one integer, no copy, no main-thread hop) and wakes the timer the moment it moves.
struct PresentPacer {
    /// How long nothing new may happen before the timer rests.
    static let restAfterUS: UInt64 = 1_000_000
    /// The resting watch's interval: at most one 60 Hz frame (the Mac's capture rate) before a change shows.
    static let watchIntervalNS: UInt64 = 16_666_667

    private(set) var lastActivityUS: UInt64

    init(nowUS: UInt64) { lastActivityUS = nowUS }

    /// A new frame landed, a finger touched, input went to the Mac, the size changed: stay at full rate.
    mutating func activity(atUS now: UInt64) {
        if now > lastActivityUS { lastActivityUS = now }
    }

    /// Whether the timer may rest now: a full second with nothing new, no finger down, nothing animating.
    func shouldRest(nowUS now: UInt64, fingersDown: Bool, animating: Bool) -> Bool {
        guard !fingersDown, !animating, now > lastActivityUS else { return false }
        return now - lastActivityUS >= Self.restAfterUS
    }
}

/// Heat: whether the Terminal or JetKVM view fully covers the Mac picture (open screen, upright only), and so
/// whether the Mac should keep sending it.
enum PictureCover {
    static func covers(_ view: SessionView, wide: Bool) -> Bool {
        guard !wide else { return false }
        return view.isTerminal || view.isJetKVM
    }

    /// What the library is told: visible only when the app is on screen AND the picture is not covered.
    static func hostVisible(appVisible: Bool, covered: Bool) -> Bool { appVisible && !covered }
}
