import SwiftUI
import UIKit

// Our keys' feedback, matched to the iPhone's system keyboard.
//
// SOUND. `UIDevice.playInputClick()` is the system keyboard's own click: Apple, playInputClick(): "A click plays only
// if the user has enabled keyboard clicks in Settings > Sounds, and only if the input view is itself enabled and
// visible. To enable a custom input or accessory view for input clicks ... Adopt the UIInputViewAudioFeedback
// protocol in your input view class. Implement the enableInputClicksWhenVisible delegate method to return true."
// Until build 36 no view of ours adopted it and our keys were not an input view, so the call played nothing. Now
// the hidden typing responder always carries a `ClickInputView` (upright: as its accessory over the system keyboard;
// sideways: as its input view, one clear point tall, while our keyboard is up), so the click plays and follows the
// user's Keyboard Feedback > Sound setting and the silent switch. The system keyboard uses a different click for
// delete and for the modifier keys; Apple offers apps only the one input click, so every key uses it.
//
// HAPTIC. No public API reads Settings > Sounds & Haptics > Keyboard Feedback > Haptic, so the app has its own
// switch, "Keyboard Haptics", off by default as the system's own. On: a light impact on touch down from one
// generator kept prepared (UIFeedbackGenerator.prepare(): "Call prepare() before the event ... If you might trigger
// additional feedback within the next few seconds, immediately call prepare() again"). Every control that tapped
// before (keys, the key row, the upright extra keys, the click buttons, the trackpad's tap and the picture's
// touch-and-hold) follows the one switch; off, nothing taps.
@MainActor
enum KeyFeedback {
    static let hapticsKey = "keyboardHaptics"

    /// The app's "Keyboard Haptics" switch (off by default).
    static var hapticsOn: Bool { UserDefaults.standard.bool(forKey: hapticsKey) }

    /// The system click; replaced in tests to count the requests.
    static var playClick: () -> Void = { UIDevice.current.playInputClick() }
    /// The haptic; replaced in tests.
    static var playHaptic: (UIImpactFeedbackGenerator.FeedbackStyle) -> Void = { style in
        let g = generator(style)
        g.impactOccurred()
        g.prepare()
    }

    private static var generators: [UIImpactFeedbackGenerator.FeedbackStyle: UIImpactFeedbackGenerator] = [:]
    private static func generator(_ style: UIImpactFeedbackGenerator.FeedbackStyle) -> UIImpactFeedbackGenerator {
        if let g = generators[style] { return g }
        let g = UIImpactFeedbackGenerator(style: style)
        generators[style] = g
        return g
    }

    /// Called when a keyboard or band appears and when a finger first lands, so the first tap is on time.
    static func prepare() {
        guard hapticsOn else { return }
        generator(.light).prepare()
    }

    /// A key went down: the system click, and the light tap when the app's switch is on.
    static func keyDown() {
        playClick()
        tap()
    }

    /// A tap only (the click buttons, the trackpad, a touch-and-hold): nothing when the switch is off.
    static func tap(_ style: UIImpactFeedbackGenerator.FeedbackStyle = .light) {
        guard hapticsOn else { return }
        playHaptic(style)
    }
}

/// The view that lets `playInputClick()` play: a clear input (or accessory) view that adopts
/// `UIInputViewAudioFeedback` and returns true.
final class ClickInputView: UIInputView, UIInputViewAudioFeedback {
    var enableInputClicksWhenVisible: Bool { true }

    init(height: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: 0, height: height), inputViewStyle: .default)
        backgroundColor = .clear
        allowsSelfSizing = false
        autoresizingMask = .flexibleWidth
        isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: CGSize { CGSize(width: UIView.noIntrinsicMetric, height: bounds.height) }
}

/// When a key acts, as the system keyboard: characters, space and return on touch UP (so a finger that slides off
/// takes it back); delete, shift and the page keys on touch DOWN.
enum KeyEdge: Equatable { case down, up }

enum KeyPressRules {
    /// How far outside its own frame a finger may wander before the key lets go (half the 6 pt key gap plus a
    /// little, so a finger rolling on the key does not cancel it).
    static let slop: CGFloat = 8

    static func edge(_ key: TouchKey) -> KeyEdge {
        switch key {
        case .char, .space, .ret: .up
        case .shift, .delete, .page: .down
        }
    }

    /// Whether a finger at `point` (in the key's own space) is still on a key of `size`.
    static func inside(_ point: CGPoint, size: CGSize) -> Bool {
        CGRect(origin: .zero, size: size).insetBy(dx: -slop, dy: -slop).contains(point)
    }
}

/// The enlarged letter over a pressed letter key (the iPhone keyboard's key pop-up). Drawn by us: iOS offers apps
/// no key pop-up (HIG Virtual keyboards names none). The bubble is wider and taller than the key, joined to it by a
/// neck as wide as the key; at the ends of a row it shifts inward so it stays on the keyboard.
enum KeyPopup {
    /// Bubble size against the key: 1.5 wide; it rises 1.05 key heights above the key's top.
    static let widthFactor: CGFloat = 1.5
    static let riseFactor: CGFloat = 1.05
    static let letterSize: CGFloat = 34

    /// The bubble's horizontal shift from centred over the key, keeping it within 0...`containerWidth`.
    static func shift(keyMinX: CGFloat, keyWidth: CGFloat, containerWidth: CGFloat) -> CGFloat {
        let w = keyWidth * widthFactor
        let centredMin = keyMinX + keyWidth / 2 - w / 2
        let clamped = min(max(centredMin, 0), max(containerWidth - w, 0))
        return clamped - centredMin
    }

    /// The bubble's frame in the key's own space (origin at the key's top-left).
    static func bubble(keySize: CGSize, shift: CGFloat) -> CGRect {
        let w = keySize.width * widthFactor
        let h = keySize.height * riseFactor
        return CGRect(x: keySize.width / 2 - w / 2 + shift, y: -h, width: w, height: h)
    }
}

/// The pop-up's outline: the bubble above, the key below, a smooth neck between.
struct KeyPopupShape: Shape {
    let keySize: CGSize
    let shift: CGFloat

    func path(in rect: CGRect) -> Path {
        let b = KeyPopup.bubble(keySize: keySize, shift: shift)
        let r: CGFloat = 10
        var p = Path()
        p.addRoundedRect(in: b, cornerSize: CGSize(width: r, height: r), style: .continuous)
        // The neck: from the bubble's bottom down over the key, the key's width.
        p.addRoundedRect(in: CGRect(x: 0, y: b.maxY - r, width: keySize.width, height: keySize.height + r),
                         cornerSize: CGSize(width: KeyLook.cornerRadius * 0.7, height: KeyLook.cornerRadius * 0.7),
                         style: .continuous)
        return p
    }
}

struct KeyPopupView: View {
    let letter: String
    let keySize: CGSize
    let shift: CGFloat

    var body: some View {
        let b = KeyPopup.bubble(keySize: keySize, shift: shift)
        ZStack(alignment: .topLeading) {
            KeyPopupShape(keySize: keySize, shift: shift)
                .fill(KeyLook.keyFill)
                .shadow(color: .black.opacity(0.28), radius: 2, y: 1)
            Text(letter)
                .font(.system(size: KeyPopup.letterSize, weight: .regular))
                .foregroundStyle(Color.primary)
                .frame(width: b.width, height: b.height)
                .offset(x: b.minX, y: b.minY)
        }
        .frame(width: keySize.width, height: keySize.height, alignment: .topLeading)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
