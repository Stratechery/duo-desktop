import GlassActSession
import SwiftUI
import UIKit

/// Typing on the iOS system keyboard, in both layouts. Horizontal: the keyboard comes up OVER the bottom of the picture
/// on request; the picture does not move. Upright: the keyboard is up for the whole session, under the picture and the
/// middle band. Typed characters become US ANSI key presses through the same engine as the special keys, so a held
/// modifier applies to them (command held + "c" = ⌘C).
enum MacTyping {
    /// Character → the key that types it on a US Mac layout (letters, digits, punctuation, shifted symbols).
    static let keys: [Character: MacKey] = {
        var map: [Character: MacKey] = [:]
        for key in (MacKeyboardLayout.letters + MacKeyboardLayout.symbols).joined() where key.role == .key {
            guard key.label.count == 1, let c = key.label.first, map[c] == nil else { continue }
            map[c] = key
            if c.isLetter, c.isLowercase, let upper = c.uppercased().first {
                map[upper] = MacKey(String(upper), key.code, id: "upper-" + key.id, flags: MacKeyFlags.shift)
            }
        }
        map[" "] = MacKeyboardLayout.space
        map["\n"] = MacKeyboardLayout.returnKey
        map["\t"] = MacKeyboardLayout.tab
        return map
    }()

    /// One typed character as a key down and up. A character with no US key (é, emoji) is not sent: Glass Act's
    /// viewer library has no public text-input call for the app to use.
    @discardableResult
    static func type(_ c: Character, into engine: MacKeyboardEngine) -> Bool {
        guard let key = keys[c] else {
            // A Remote Desktop PC takes any character as Unicode (`RDPInput.type`); a Mac's session has no hook.
            guard let text = engine.typeText else { return false }
            text(c)
            return true
        }
        engine.keyDown(key)
        engine.keyUp(key)
        return true
    }
}

/// An invisible responder that raises the system keyboard and turns what is typed into Mac keys.
final class MacTypingView: UIView, UIKeyInput {
    /// No system three-finger undo/redo or editing menu while this field has the keyboard: three fingers on the Mac
    /// picture are Mission Control and Spaces (`DirectTouchEngine.Swipe`), and undo belongs to the Mac (⌘Z).
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    var engine: MacKeyboardEngine?
    var state: KeyboardState? {
        didSet { rebuildAccessory() }
    }
    /// The Mac keys row above the system keyboard: horizontal only (upright has the special keys band).
    var showsMacKeysBar = true {
        didSet {
            guard showsMacKeysBar != oldValue else { return }
            rebuildAccessory()
            if isFirstResponder { reloadInputViews() }
        }
    }
    /// Sideways on our own keyboard: no system keyboard, only a clear one-point input view, so our keys' clicks
    /// can play (`KeyFeedback`). Hardware keyboard typing still arrives through `insertText`.
    var clickOnly = false {
        didSet {
            guard clickOnly != oldValue else { return }
            if isFirstResponder { reloadInputViews() }
        }
    }
    private var accessory: UIView?
    private let clickInput = ClickInputView(height: 1)

    /// Always an input-click view over the system keyboard: the Mac keys row in one, or an empty one with no
    /// height (upright), so the band's keys' clicks play (`KeyFeedback`).
    private func rebuildAccessory() {
        let host = ClickInputView(height: showsMacKeysBar && state != nil ? MacKeysBar.height : 0)
        if showsMacKeysBar, let state {
            let bar = Self.makeAccessory(state)
            bar.frame = host.bounds
            host.addSubview(bar)
        }
        accessory = host
    }

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { clickOnly ? nil : accessory }
    override var inputView: UIView? { clickOnly ? clickInput : nil }

    // Plain keys: nothing changed or completed on the phone side.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var returnKeyType: UIReturnKeyType = .default

    /// Always "has text", so the delete key keeps reaching `deleteBackward`.
    var hasText: Bool { true }

    func insertText(_ text: String) {
        guard let engine else { return }
        for c in text { MacTyping.type(c, into: engine) }
    }

    func deleteBackward() {
        guard let engine else { return }
        engine.keyDown(MacKeyboardLayout.delete)
        engine.keyUp(MacKeyboardLayout.delete)
    }

    /// The Mac keys the system keyboard lacks, in a row above it.
    private static func makeAccessory(_ state: KeyboardState) -> UIView {
        let host = UIHostingController(rootView: MacKeysBar(state: state))
        host.view.frame = CGRect(x: 0, y: 0, width: 0, height: MacKeysBar.height)
        host.view.autoresizingMask = .flexibleWidth
        host.view.backgroundColor = .clear
        host.sizingOptions = []
        return host.view
    }
}

/// esc, tab, control, option, command and the arrows, as keys of the upright keyboard (same engine, sticky
/// modifiers).
struct MacKeysBar: View {
    static let height: CGFloat = 48
    let state: KeyboardState

    static let keys: [MacKey] = [
        MacKeyboardLayout.escape, MacKeyboardLayout.tab, MacKeyboardLayout.controlKey, MacKeyboardLayout.optionKey,
        MacKeyboardLayout.commandKey, MacKeyboardLayout.left, MacKeyboardLayout.up, MacKeyboardLayout.down,
        MacKeyboardLayout.right,
    ]

    var body: some View {
        // The system keyboard's look (KeyLook): flat keys on a panel the colour of the keyboard's, with its large
        // rounded top edge, so the row reads as the keyboard's own top row. The panel runs on below the row, behind the
        // keyboard's own rounded top corners, so no picture shows between the two.
        HStack(spacing: KeyMetrics.gap) {
            ForEach(Self.keys) { key in
                KeyCap(state: state, key: key).frame(width: 52, height: KeyMetrics.height)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(alignment: .top) {
            KeyLook.panelShape.fill(KeyLook.panel)
                .frame(height: Self.height + Self.panelRunOn)
                .frame(height: Self.height, alignment: .top)
        }
    }

    /// How far the row's panel runs on below it, behind the keyboard's rounded top corners.
    static let panelRunOn: CGFloat = 40
}

/// Puts the responder in the view tree and raises or lowers the system keyboard with `up`. With `pinned`
/// (upright), the keyboard stays up: it comes back after the app returns to the front, and a hide does not
/// change `up`.
struct MacTypingField: UIViewRepresentable {
    @Binding var up: Bool
    let state: KeyboardState
    var pinned = false
    var macKeysBar = true
    /// Sideways with our own keyboard: the responder holds only the clear click view (`MacTypingView.clickOnly`).
    var clickOnly = false

    final class Coordinator: NSObject {
        var up: Binding<Bool>
        var pinned = false
        weak var view: MacTypingView?
        init(up: Binding<Bool>) { self.up = up }
        @objc func didHide() { if !pinned, up.wrappedValue { up.wrappedValue = false } }
        @objc func didBecomeActive() {
            guard pinned, let view, view.window != nil, !view.isFirstResponder else { return }
            view.becomeFirstResponder()
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(up: $up) }

    func makeUIView(context: Context) -> MacTypingView {
        let v = MacTypingView(frame: .zero)
        v.engine = state.engine
        v.showsMacKeysBar = macKeysBar
        v.clickOnly = clickOnly
        v.state = state
        v.isAccessibilityElement = false
        context.coordinator.view = v
        // Keyboard swiped away or dismissed by the system: the toggle follows (horizontal).
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.didHide),
                                               name: UIResponder.keyboardDidHideNotification, object: nil)
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.didBecomeActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
        return v
    }

    func updateUIView(_ v: MacTypingView, context: Context) {
        context.coordinator.up = $up
        context.coordinator.pinned = pinned
        v.showsMacKeysBar = macKeysBar
        v.clickOnly = clickOnly
        let want = up || pinned
        DispatchQueue.main.async {
            if want, !v.isFirstResponder { v.becomeFirstResponder() }
            if !want, v.isFirstResponder { v.resignFirstResponder() }
        }
    }

    static func dismantleUIView(_ v: MacTypingView, coordinator: Coordinator) {
        NotificationCenter.default.removeObserver(coordinator)
        v.resignFirstResponder()
    }
}

/// Reads the keyboard layout guide (`UIView.keyboardLayoutGuide`): how far the keyboard reaches above the bottom
/// safe area. Place it over the whole screen, safe areas ignored; the upright layout keeps that much clear at the
/// bottom, so nothing sits under the system keyboard.
struct KeyboardGuideReader: UIViewRepresentable {
    let onChange: (CGFloat) -> Void
    /// The keyboard guide's top in window points, when it changes (the outer screen's picture spans the window).
    var onWindowTop: ((CGFloat) -> Void)? = nil

    final class Reader: UIView {
        var onChange: (CGFloat) -> Void = { _ in }
        var onWindowTop: ((CGFloat) -> Void)?
        private var last: CGFloat = -1
        private var lastTop: CGFloat = -1
        private let marker = UIView()

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            marker.isUserInteractionEnabled = false
            marker.translatesAutoresizingMaskIntoConstraints = false
            addSubview(marker)
            NSLayoutConstraint.activate([
                marker.leadingAnchor.constraint(equalTo: leadingAnchor),
                marker.widthAnchor.constraint(equalToConstant: 1),
                marker.topAnchor.constraint(equalTo: keyboardLayoutGuide.topAnchor),
                marker.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func layoutSubviews() {
            super.layoutSubviews()
            let inset = KeyboardGuideReader.inset(keyboardTop: marker.frame.minY, bounds: bounds,
                                                  bottomSafeArea: safeAreaInsets.bottom)
            if let onWindowTop, window != nil {
                let top = marker.convert(CGPoint.zero, to: nil).y.rounded()
                if top != lastTop {
                    lastTop = top
                    DispatchQueue.main.async { onWindowTop(top) }
                }
            }
            guard inset != last else { return }
            last = inset
            let report = onChange
            DispatchQueue.main.async { report(inset) }
        }
    }

    /// The keyboard's height above the bottom safe area (0 when it is down).
    static func inset(keyboardTop: CGFloat, bounds: CGRect, bottomSafeArea: CGFloat) -> CGFloat {
        max(0, bounds.maxY - keyboardTop - bottomSafeArea).rounded()
    }

    func makeUIView(context: Context) -> Reader {
        let r = Reader()
        r.onChange = onChange
        r.onWindowTop = onWindowTop
        return r
    }

    func updateUIView(_ r: Reader, context: Context) { r.onChange = onChange; r.onWindowTop = onWindowTop }
}
