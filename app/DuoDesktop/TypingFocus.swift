import CoreGraphics
import Foundation
import GlassActWire

/// Where the horizontal view keeps its eye while our keyboard is up: on the pointer, or on the place typing goes.
enum TypingAim: Equatable {
    case pointer
    /// A height on the Mac picture, in picture pixels.
    case field(y: CGFloat)
}

/// The horizontal view's keyboard rules. The Mac's Host says where typing goes (TEXT_FOCUS) and whether it is locked
/// (SCREEN_LOCK).
///
/// - A text place reported within `clickWindow` of the user's click raises the keyboard and aims at it.
/// - Focus leaving text puts the keyboard down, unless it was raised by hand (or the Mac is locked).
/// - The Keyboard button always wins: raised by hand stays up; lowered by hand stays down until the next click
///   into a text place.
/// - Locked: the password field is where typing goes (the measured spot); the keyboard comes up unless lowered
///   by hand.
/// - With the keyboard up the view aims at the field; a pointer move aims at the pointer; typing aims back at the field.
struct AutoKeyboard: Equatable {
    static let clickWindow: TimeInterval = 2.0

    private(set) var up = false
    private(set) var raisedByHand = false
    private(set) var loweredByHand = false
    private(set) var aim: TypingAim = .pointer
    private(set) var locked = false
    /// The last place typing goes (picture pixels), nil = not a text place.
    private(set) var fieldY: CGFloat?
    private var lastClickAt: TimeInterval = -.infinity

    mutating func userClicked(at t: TimeInterval) { lastClickAt = t }

    /// A TEXT_FOCUS: `y` = where typing goes on the picture, nil = not a text place.
    mutating func focus(y: CGFloat?, at t: TimeInterval) {
        guard !locked else { return } // the lock screen is where typing goes; reports from behind it are stale
        fieldY = y
        let afterClick = t - lastClickAt <= Self.clickWindow
        if let y {
            if afterClick {
                if !up { up = true; raisedByHand = false }
                loweredByHand = false
                aim = .field(y: y)
            } else if up, case .field = aim {
                aim = .field(y: y) // the field moved or grew; keep it in view
            }
        } else if up, !raisedByHand {
            up = false
            aim = .pointer
        }
    }

    /// The Keyboard button.
    mutating func button() {
        if up {
            up = false
            loweredByHand = true
            raisedByHand = false
        } else {
            up = true
            raisedByHand = true
            loweredByHand = false
            aim = fieldY.map { .field(y: $0) } ?? .pointer
        }
    }

    /// SCREEN_LOCK. `passwordY`: the measured password field on the lock screen, picture pixels.
    mutating func lock(_ isLocked: Bool, passwordY: CGFloat) {
        guard isLocked != locked else { return }
        locked = isLocked
        if isLocked {
            fieldY = passwordY
            if !loweredByHand {
                up = true
                aim = .field(y: passwordY)
            }
        } else {
            fieldY = nil
            if up, !raisedByHand { up = false; aim = .pointer }
        }
    }

    mutating func pointerMoved() { if up { aim = .pointer } }
    mutating func typed() { if up, let fieldY { aim = .field(y: fieldY) } }

    /// The phone turned: the keyboard goes away; nothing raised or lowered by hand carries over.
    mutating func reset() {
        let wasLocked = locked, y = fieldY
        self = AutoKeyboard()
        locked = wasLocked
        fieldY = y
    }
}

enum TypingFocusMap {
    /// Lock screen password field, as a fraction of the Mac screen.
    static var passwordField: CGPoint { OuterWindow.passwordField }

    /// The picture height (pixels) where typing goes for a TEXT_FOCUS, or nil when it is not a text place or lies
    /// outside the shown screen. `screen`: the shown screen in global points.
    static func pictureY(_ f: WireTextFocus, screen: CGRect, pictureHeight: Int) -> CGFloat? {
        guard f.hasText, screen.height > 0, pictureHeight > 0 else { return nil }
        let globalY: CGFloat
        if f.caretH > 0 {
            globalY = CGFloat(f.caretY) + CGFloat(f.caretH) / 2
        } else if f.fieldH > 0 {
            // A tall text area with no caret: aim near its BOTTOM line. A Host with the end-of-text fallback sends
            // Terminal's prompt as the caret instead, so this is only the last resort.
            globalY = f.fieldH <= 120 ? CGFloat(f.fieldY) + CGFloat(f.fieldH) / 2
                : CGFloat(f.fieldY) + CGFloat(f.fieldH) - 30
        } else {
            return nil
        }
        let local = globalY - screen.minY
        guard local >= 0, local <= screen.height else { return nil }
        return local / screen.height * CGFloat(pictureHeight)
    }

    /// The shown screen's frame in global points, or (no screen list) the main screen at 1920 wide with the picture's
    /// shape.
    static func screenFrame(shown: CGRect?, pictureWidth: Int, pictureHeight: Int) -> CGRect {
        if let shown, shown.height > 0 { return shown }
        guard pictureWidth > 0 else { return CGRect(x: 0, y: 0, width: 1920, height: 1080) }
        return CGRect(x: 0, y: 0, width: 1920, height: 1920 * CGFloat(pictureHeight) / CGFloat(pictureWidth))
    }
}
