import GlassActSession
import SwiftUI
import UIKit

/// Observable wrapper the keyboard view redraws from (latches, layer).
@MainActor @Observable
final class KeyboardState {
    let engine: MacKeyboardEngine
    /// The upright band shows its "more" block (F1-F12, navigation) in place of the shortcuts.
    var functionKeys = false
    private(set) var revision = 0

    init(engine: MacKeyboardEngine) {
        self.engine = engine
        engine.onChange = { [weak self] in self?.revision += 1 }
    }

    /// The Paste key: the phone's clipboard text to the Mac's clipboard, then ⌘V there. Set by the session.
    var sendClipboard: (String) -> Void = { _ in }

    func pasteToMac(_ text: String) {
        sendClipboard(text)
        // The clipboard message and the keys share the session's ordered control stream, so ⌘V lands after it.
        engine.sendShortcut(.paste)
    }

    func latch(_ m: KeyMap.Modifier) -> MacKeyboardEngine.Latch {
        _ = revision
        return engine.latch(of: m)
    }

    /// The Apps key holds Command down with the Mac's app switcher open.
    var switcherOpen: Bool {
        _ = revision
        return engine.switcherOpen
    }
}

/// Key sizes: one grid of equal keys (the owner 2026-11-20, of the horizontal Mac keys row: "look modern and
/// correct"). Every key is `keyWidth` x `keyHeight` with `gap` between keys both ways; keys keep their size and
/// never shrink to fit more in (the "more" key swaps a block instead).
struct KeyMetrics: Equatable {
    /// Between keys, both ways: the horizontal row's spacing.
    static let gap: CGFloat = 6
    /// The horizontal row's key height; the upright grid uses it whenever the band has room.
    static let height: CGFloat = 38

    let keyWidth: CGFloat
    let keyHeight: CGFloat
    /// Between rows: `gap`, less only when the upright band is short (down to `SessionLayout.Upright.minRowGap`),
    /// more when the upright rows leave spare points.
    var rowGap: CGFloat = KeyMetrics.gap

    /// Units of keys plus the gaps between them.
    func width(units: Double) -> CGFloat {
        CGFloat(units) * keyWidth + CGFloat(max(units - 1, 0)) * Self.gap
    }
    func height(rows: Int) -> CGFloat { CGFloat(rows) * keyHeight + CGFloat(max(rows - 1, 0)) * rowGap }
    func rowWidth(_ cells: [MacKeyboardLayout.Cell]) -> CGFloat { width(units: cells.reduce(0) { $0 + $1.width }) }

    /// Height of `rows` rows of keys at `keyHeight`.
    static func band(rows: Int, keyHeight: CGFloat, rowGap: CGFloat = gap) -> CGFloat {
        CGFloat(rows) * keyHeight + CGFloat(rows - 1) * rowGap
    }
}

/// The upright layout's keys half: the three buttons at the outer edge, then the 24 Mac keys the iOS system
/// keyboard lacks (`SpecialKeysLayout.table`), on one 8 x 4 grid that fills the band's height. Trackpad on the
/// right (the standard): buttons at the far left, under the left thumb. Trackpad on the left: the keys in the same
/// order, then the buttons at the far right, under the right thumb (`TrackpadSide`). VoiceOver reads it left to right, as drawn.
struct SpecialKeysView: View {
    @Bindable var state: KeyboardState
    let pad: TrackpadEngine
    let metrics: KeyMetrics
    var side: TrackpadSide = .standard
    /// 16:10 picture: 3 rows, and "more" covers the click column (`SixteenTenKeysLayout`).
    var shape: PictureShape = .sixteenNine

    /// The grid's key size in this space: the 8 columns share the width; the 4 rows share the band's height
    /// (`SessionLayout.Upright.rowMetrics`).
    static func metrics(width: CGFloat, rowGap: CGFloat = KeyMetrics.gap, keyHeight: CGFloat) -> KeyMetrics {
        let cols = CGFloat(SpecialKeysLayout.gridColumns)
        let w = ((width - (cols - 1) * KeyMetrics.gap) / cols).rounded(.down)
        return KeyMetrics(keyWidth: max(w, 1), keyHeight: keyHeight, rowGap: rowGap)
    }

    var body: some View {
        if shape == .sixteenTen {
            if state.functionKeys { sixteenTenMore } else { sixteenTenNormal }
        } else {
            sixteenNine
        }
    }

    /// 16:10, normal: the click column (Left click 2 rows, Right click and Scroll in row 3) at the outer edge and
    /// 3 rows of 6 keys; the same sides rule as 16:9, the keys never flip.
    private var sixteenTenNormal: some View {
        HStack(alignment: .top, spacing: KeyMetrics.gap) {
            if side == .right { ShortClickColumn(pad: pad, metrics: metrics, side: side) }
            rows(SixteenTenKeysLayout.rows(functionKeys: false), keyWidth: nil, gap: KeyMetrics.gap)
            if side == .left { ShortClickColumn(pad: pad, metrics: metrics, side: side) }
        }
    }

    /// 16:10, "more" on: 3 rows of 10 narrower keys over the click column and the keys.
    private var sixteenTenMore: some View {
        let width = metrics.width(units: SpecialKeysLayout.units)
        return rows(SixteenTenKeysLayout.rows(functionKeys: true),
                    keyWidth: SixteenTenKeysLayout.moreKeyWidth(in: width), gap: SixteenTenKeysLayout.moreGap)
            .frame(width: width, alignment: .leading)
    }

    private func rows(_ rows: [[MacKeyboardLayout.Cell]], keyWidth: CGFloat?, gap: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: metrics.rowGap) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: gap) {
                    ForEach(row) { cell in
                        KeyCell(state: state, cell: cell)
                            .frame(width: keyWidth ?? metrics.width(units: cell.width), height: metrics.keyHeight)
                    }
                }
            }
        }
    }

    private var sixteenNine: some View {
        HStack(alignment: .top, spacing: KeyMetrics.gap) {
            if side == .right { buttons }
            VStack(alignment: .leading, spacing: metrics.rowGap) {
                ForEach(Array(SpecialKeysLayout.rows(functionKeys: state.functionKeys).enumerated()),
                        id: \.offset) { _, row in
                    HStack(spacing: KeyMetrics.gap) {
                        ForEach(row) { cell in
                            KeyCell(state: state, cell: cell)
                                .frame(width: metrics.width(units: cell.width), height: metrics.keyHeight)
                        }
                    }
                }
            }
            if side == .left { buttons }
        }
    }

    private var buttons: some View { ClickColumn(pad: pad, metrics: metrics) }
}

/// The click buttons' column (Right click, Scroll, Left click, top to bottom) in the regular band.
struct ClickColumn: View {
    let pad: TrackpadEngine
    let metrics: KeyMetrics

    var body: some View {
        VStack(spacing: metrics.rowGap) {
            ForEach(ClickButtonsLayout.stack, id: \.button) { item in
                ClickButton(pad: pad, button: item.button)
                    .frame(height: metrics.height(rows: item.rows))
            }
        }
        .frame(width: metrics.width(units: Double(ClickButtonsLayout.columns)))
    }
}

/// The click column in the 16:10 band: Scroll (outer edge) and Right click side by side in the top row, then Left
/// click 2 rows tall under them, each one key wide (mock-up `screenshots/view-16x10-v2-normal-2026-11-21.png`).
struct ShortClickColumn: View {
    let pad: TrackpadEngine
    let metrics: KeyMetrics
    let side: TrackpadSide

    var body: some View {
        // Right click and Scroll on top, the two-row Left click under them (the owner 2026-11-21, build 27: the click
        // column matches the horizontal view's order, Left click at the bottom).
        VStack(spacing: metrics.rowGap) {
            HStack(spacing: KeyMetrics.gap) {
                ForEach(ClickButtonsLayout.sixteenTenThirdRow(side: side), id: \.self) { b in
                    ClickButton(pad: pad, button: b)
                }
            }
            .frame(height: metrics.keyHeight)
            ClickButton(pad: pad, button: .left).frame(height: metrics.height(rows: 2))
        }
        .frame(width: metrics.width(units: Double(ClickButtonsLayout.columns)))
    }
}

/// A band button. Left and Right click: the Mac's mouse button down while the finger is down, up when it lifts,
/// at the pointer, so holding Left click while the other hand moves on the trackpad drags. Scroll: while it is
/// held, one finger on the trackpad scrolls the Mac instead of moving the pointer; alone it does nothing. Same
/// flat key look. Each shows a symbol: Right click and Scroll since build 6; Left click `cursorarrow.click` since
/// build 33 (the owner 2026-11-21, on the candidates picture: "I think the cursor with the broken circle is okay.");
/// VoiceOver names each and the Keys sheet lists them.
struct ClickButton: View {
    let pad: TrackpadEngine
    let button: BandButton
    /// The horizontal view's column: regular glass instead of the flat key fill (plan decision 5).
    var glass = false
    /// The horizontal view's full-screen state: almost clear, drawn by us (`ClearLook`).
    var clear = false
    /// The horizontal view: the button's shape (the Click button follows the screen's corner); nil = the key shape.
    var shape: AnyShape? = nil
    @State private var pressed = false

    var title: String {
        switch button {
        case .left: "Left click"
        case .right: "Right click"
        case .scroll: "Scroll"
        }
    }

    var hint: String {
        switch button {
        case .left: "The Mac's left button. Hold it and move on the trackpad to drag."
        case .right: "The Mac's right button."
        case .scroll: "Hold it and move one finger on the trackpad to scroll."
        }
    }

    var identifier: String {
        switch button {
        case .left: "leftClick"
        case .right: "rightClick"
        case .scroll: "scrollButton"
        }
    }

    var body: some View {
        KeyFace(content: face, pressed: pressed, glass: glass, clear: clear, shape: shape)
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressed { down() } }
                .onEnded { _ in up() })
            .accessibilityElement()
            .accessibilityLabel(title)
            .accessibilityHint(hint)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier(identifier)
            .accessibilityAction {
                // A click from VoiceOver; Scroll alone does nothing, so its action is empty.
                guard let b = mouseButton else { return }
                pad.pressButton(b, time: ProcessInfo.processInfo.systemUptime)
                pad.releaseButton(b)
            }
            .onDisappear { if pressed { up() } }
    }

    /// The face: the same symbol look as the other symbol keys, for all three.
    var face: KeyFaceContent {
        switch button {
        case .left: .symbol("cursorarrow.click")
        case .right: .symbol("contextualmenu.and.cursorarrow")
        case .scroll: .symbol("arrow.up.and.down")
        }
    }

    /// The Mac's mouse button number, for the two click buttons.
    private var mouseButton: Int? {
        switch button {
        case .left: 0
        case .right: 1
        case .scroll: nil
        }
    }

    private func down() {
        pressed = true
        KeyFeedback.tap()
        if let b = mouseButton { pad.pressButton(b, time: ProcessInfo.processInfo.systemUptime) } else { pad.pressScroll() }
    }

    private func up() {
        pressed = false
        if let b = mouseButton { pad.releaseButton(b) } else { pad.releaseScroll() }
    }
}

/// The keys' look, one recipe for both layouts: the iOS 27 system keyboard's own (the owner 2026-11-20, from his first
/// session on the real Duo: "Can we make our extra keyboard have the same flat gray look as the built in
/// keyboard? I think you did the iOS 26 look not the ios27 look"). Flat filled rounded rectangles, no glass, rim,
/// outline or shadow, on a flat panel the colour of the keyboard's. iOS offers apps no keyboard key colour or
/// material (HIG Virtual keyboards names none; `UIInputView.Style.keyboard` draws only the panel), so the values
/// are sampled: the owner's real-Duo screenshot (dark) and the iOS 27.2 iPhone Duo simulator's keyboard (dark and light)
/// agree to within one level. The system draws every key, shift, 123 and return included, in ONE shade.
/// - key:    light #FFFFFF, dark #444444 (sampled);
/// - panel:  light #E2E3E8, dark #202020 (sampled);
/// - glyph:  the label colour, black / white, regular weight (as the system's letters);
/// - pressed: light #B8BBC3, dark #6B6B6B (chosen: the system shows a letter's press as a pop-up, which a Mac key
///   has no use for, so a pressed key darkens in light and lightens in dark, the way iOS's own non-letter keys did);
/// - held (a modifier from its tap until it lets go, "more" on): the accent fill and a white glyph, unchanged.
enum KeyLook {
    /// Continuous corners, compared against the system keys' corners in the simulator screenshot.
    static let cornerRadius: CGFloat = 12
    /// The band's panel: its top corners, the size of the system keyboard panel's own.
    static let panelCornerRadius: CGFloat = 24
    /// A glyph (⌘ ⇧ ← ⎋ …) and an SF Symbol; a short word (fn, F12, Find) a little smaller, as the system
    /// keyboard does with its words.
    static let glyphSize: CGFloat = 18
    static let wordSize: CGFloat = 14
    static var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }
    static var panelShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: panelCornerRadius, topTrailingRadius: panelCornerRadius,
                               style: .continuous)
    }

    private static func gray(_ v: Int) -> UIColor {
        UIColor(red: CGFloat(v) / 255, green: CGFloat(v) / 255, blue: CGFloat(v) / 255, alpha: 1)
    }
    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> UIColor {
        UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
    private static func dynamic(light: UIColor, dark: UIColor) -> Color {
        Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
    static let keyFill = dynamic(light: gray(255), dark: gray(0x44))
    static let pressedFill = dynamic(light: rgb(0xB8, 0xBB, 0xC3), dark: gray(0x6B))
    static let panel = dynamic(light: rgb(0xE2, 0xE3, 0xE8), dark: gray(0x20))
}

/// What a key shows: ONE thing — a glyph, an SF Symbol, or a short word.
enum KeyFaceContent: Equatable {
    case text(String)
    case symbol(String)

    /// A label with letters in it is a word (fn, F12, esc); arrows and ⌘ ⇧ ⎋ … are glyphs.
    var isWord: Bool {
        if case let .text(t) = self { return t.contains { $0.isLetter } }
        return false
    }
}

/// The one key component: shape, corner, fill, label style. Every key in both layouts draws through it.
struct KeyFace: View {
    let content: KeyFaceContent
    var lit = false
    /// The finger is on it.
    var pressed = false
    /// Off for now (the other shortcuts while the app switcher is open): the glyph is faded.
    var dimmed = false
    /// Regular Liquid Glass instead of the flat fill (the horizontal view's column); pressed shows as a grey tint.
    var glass = false
    /// Our horizontal keyboard's letters: the system keyboard's letter size, not the Mac keys' glyph size.
    var textSize: CGFloat? = nil
    /// Almost clear, drawn by us (the horizontal view's full-screen state; `ClearLook`).
    var clear = false
    /// The glass or clear face's shape; nil = the key shape.
    var shape: AnyShape? = nil

    var body: some View {
        let shape = shape ?? AnyShape(KeyLook.shape)
        if clear {
            glyph
                .foregroundStyle(Color.primary)
                .modifier(ClearLook.Halo())
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clearSurface(shape, pressed: pressed)
        } else if glass {
            // The column while our keyboard is up. Drawn by us in the keys' own fill, not the system's Liquid Glass
            // (the owner 2026-11-21: the Keyboard, Right click and Scroll buttons "sort of fade out ... non-highlighted.
            // And after about like 5 seconds, it comes back", seen only on the phone). Glass is drawn by the system
            // and changes with what is behind it and with the window's state; a plain fill cannot fade.
            glyph
                .foregroundStyle(Color.primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(shape.fill(pressed ? KeyLook.pressedFill : KeyLook.keyFill))
                .contentShape(shape)
        } else {
            flat
        }
    }

    @ViewBuilder private var glyph: some View {
        switch content {
        case let .text(t):
            Text(t)
                .font(.system(size: textSize ?? (content.isWord ? KeyLook.wordSize : KeyLook.glyphSize),
                              weight: .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 3)
        case let .symbol(name):
            Image(systemName: name).font(.system(size: (textSize ?? KeyLook.glyphSize) - 2, weight: .regular))
        }
    }

    private var flat: some View {
        Group {
            switch content {
            case let .text(t):
                Text(t)
                    .font(.system(size: textSize ?? (content.isWord ? KeyLook.wordSize : KeyLook.glyphSize),
                                  weight: .regular))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .padding(.horizontal, 3)
            case let .symbol(name):
                Image(systemName: name).font(.system(size: (textSize ?? KeyLook.glyphSize) - 2, weight: .regular))
            }
        }
        // White on the accent fill; otherwise the label colour, as the system keys' letters.
        .foregroundStyle(lit ? Color.white : Color.primary)
        .opacity(dimmed ? 0.3 : 1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A held modifier (or "more" on) is a solid accent key with a white glyph, clearly unlike the grey keys.
        .background(KeyLook.shape.fill(lit ? Color.accentColor : pressed ? KeyLook.pressedFill : KeyLook.keyFill))
        .contentShape(KeyLook.shape)
    }
}

/// A key drawn by `KeyFace` that shows its press, for the one-press shortcut keys (Buttons).
struct KeyButtonStyle: ButtonStyle {
    let content: KeyFaceContent
    var lit = false
    var dimmed = false

    func makeBody(configuration: Configuration) -> some View {
        KeyFace(content: content, lit: lit, pressed: configuration.isPressed && !dimmed, dimmed: dimmed)
    }
}

/// One cell of the upright grid.
private struct KeyCell: View {
    let state: KeyboardState
    let cell: MacKeyboardLayout.Cell

    var body: some View {
        switch cell {
        case let .key(key): KeyCap(state: state, key: key)
        case .gap: Color.clear
        case let .shortcut(sc) where sc == .paste:
            PasteKey(dimmed: state.switcherOpen) { text in state.pasteToMac(text) }.disabled(state.switcherOpen)
        case let .shortcut(sc):
            // While the app switcher is open, Apps shows held and the other shortcuts are off (Quit would quit the
            // highlighted app).
            ShortcutKey(shortcut: sc, lit: sc == .switchApp && state.switcherOpen,
                        disabled: sc != .switchApp && state.switcherOpen) { state.engine.sendShortcut(sc) }
        }
    }
}

/// A one-press Mac shortcut: an SF Symbol, or a short word where the symbol would be ambiguous; never both. The
/// name is the accessibility label.
struct ShortcutKey: View {
    let shortcut: MacShortcut
    var lit = false
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button {
            KeyFeedback.keyDown()
            action()
        } label: {
            EmptyView()
        }
        .buttonStyle(KeyButtonStyle(content: Self.face(shortcut), lit: lit, dimmed: disabled))
        .disabled(disabled)
        .accessibilityLabel(shortcut.title)
        .accessibilityHint(KeyInfo.description(.shortcut(shortcut)))
        .accessibilityAddTraits(lit ? .isSelected : [])
    }

    static func face(_ s: MacShortcut) -> KeyFaceContent {
        s.symbol.map(KeyFaceContent.symbol) ?? .text(s.face)
    }

}

/// The Paste key: an ordinary key, like its neighbours, that opens the system paste control in a small popover.
/// The paste control (`UIPasteControl`) is what lets the app read the phone's clipboard with no prompt (Apple,
/// UIPasteControl: "Use this class to paste without a user prompt"), but it is a secure control the app may not
/// restyle or cover: Apple's configuration takes only a display mode, corner style and two base colours
/// (UIPasteControl.Configuration), and in the iPhone Duo simulator it drew as a blank tile. So it is shown on its
/// own, as Apple draws it, one tap after the key. Its tap sends the text to the Mac's clipboard, then ⌘V.
struct PasteKey: View {
    var dimmed = false
    let send: (String) -> Void
    @State private var showing = false

    var body: some View {
        Button {
            KeyFeedback.keyDown()
            showing = true
        } label: {
            EmptyView()
        }
        .buttonStyle(KeyButtonStyle(content: ShortcutKey.face(.paste), dimmed: dimmed))
        .accessibilityLabel("Paste")
        .accessibilityHint(KeyInfo.description(.shortcut(.paste)))
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            PasteControl { text in
                showing = false
                send(text)
            }
            .frame(width: 120, height: 44)
            .padding(12)
            .presentationCompactAdaptation(.popover)
        }
    }
}

/// `UIPasteControl` around a target that accepts text (as Glass Act's iPad app does), in Apple's own look.
struct PasteControl: UIViewRepresentable {
    let send: (String) -> Void

    final class Target: UIView {
        var send: (String) -> Void = { _ in }

        override init(frame: CGRect) {
            super.init(frame: frame)
            pasteConfiguration = UIPasteConfiguration(forAccepting: NSString.self)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override func paste(itemProviders: [NSItemProvider]) {
            guard let provider = itemProviders.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else { return }
            _ = provider.loadObject(ofClass: NSString.self) { [weak self] object, _ in
                guard let text = object as? String else { return }
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.send(text) } }
            }
        }
    }

    func makeUIView(context: Context) -> Target {
        let target = Target()
        target.send = send
        let config = UIPasteControl.Configuration()
        config.displayMode = .iconAndLabel
        config.cornerStyle = .capsule
        let control = UIPasteControl(configuration: config)
        control.target = target
        control.translatesAutoresizingMaskIntoConstraints = false
        target.addSubview(control)
        NSLayoutConstraint.activate([
            control.leadingAnchor.constraint(equalTo: target.leadingAnchor),
            control.trailingAnchor.constraint(equalTo: target.trailingAnchor),
            control.topAnchor.constraint(equalTo: target.topAnchor),
            control.bottomAnchor.constraint(equalTo: target.bottomAnchor),
        ])
        target.accessibilityLabel = "Paste to Mac"
        return target
    }

    func updateUIView(_ v: Target, context: Context) { v.send = send }
}

struct KeyCap: View {
    let state: KeyboardState
    let key: MacKey
    @State private var pressed = false
    /// The finger is still on the key (the "more" key, which acts on the lift, lets go if it slides off).
    @State private var onKey = true
    @State private var repeatTimer: Timer?
    @State private var size: CGSize = .zero

    /// Whether the key shows held (accent fill, white glyph): a modifier from its tap until it lets go, Command
    /// while the Apps key holds the app switcher open, or the "more" key while its block shows.
    static func isLit(_ key: MacKey, state: KeyboardState) -> Bool {
        if case let .modifier(m) = key.role {
            return state.latch(m) != .off || (m == .command && state.switcherOpen)
        }
        return key.role == .functionBlock && state.functionKeys
    }

    var body: some View {
        let lit = Self.isLit(key, state: state)
        KeyFace(content: Self.face(key), lit: lit, pressed: pressed && onKey)
            .background(GeometryReader { g in Color.clear.preference(key: KeySizeKey.self, value: g.size) })
            .onPreferenceChange(KeySizeKey.self) { size = $0 }
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    if !pressed { down() }
                    let now = KeyPressRules.inside(v.location, size: size)
                    if now != onKey { onKey = now }
                }
                .onEnded { _ in up() })
            .accessibilityElement()
            .accessibilityLabel(Self.accessibilityName(key, more: state.functionKeys))
            .accessibilityHint(KeyInfo.description(.key(key), more: state.functionKeys))
            .accessibilityAddTraits(.isKeyboardKey)
            .accessibilityAddTraits(lit ? .isSelected : [])
            .onDisappear { if pressed { up() } }
    }

    /// The Mac glyph as text, or the SF Symbol that draws the same glyph where the system font draws it small
    /// (⇥) or the key has no glyph character ("more").
    static func face(_ key: MacKey) -> KeyFaceContent {
        if key.role == .functionBlock { return .symbol("ellipsis") }
        switch key.label {
        case "⇥": return .symbol("arrow.right.to.line")
        default: return .text(key.label)
        }
    }

    /// Spoken names for the glyph keys.
    static func accessibilityName(_ key: MacKey, more: Bool) -> String {
        switch key.id {
        case "shift", "shift-right": "Shift"
        case "control", "control-2": "Control"
        case "option", "option-2", "option-right": "Option"
        case "command", "command-2", "command-right": "Command"
        case "fn": "Function"
        case "escape": "Escape"
        case "tab": "Tab"
        case "forwarddelete": "Forward Delete"
        case "home": "Home"
        case "end": "End"
        case "pageup": "Page Up"
        case "pagedown": "Page Down"
        case "left": "Left Arrow"
        case "right": "Right Arrow"
        case "up": "Up Arrow"
        case "down": "Down Arrow"
        case "fblock": more ? "More, on" : "More"
        default: key.label
        }
    }

    /// Mac keys (arrows, esc, ⌦ …) go down on the Mac while the finger is down, as before; a modifier latches on
    /// touch down, as the system keyboard's shift; "more" switches on the lift, and not if the finger slid off.
    static func edge(_ key: MacKey) -> KeyEdge {
        key.role == .functionBlock ? .up : .down
    }

    private func down() {
        pressed = true
        onKey = true
        KeyFeedback.keyDown()
        if case let .modifier(m) = key.role { state.engine.tapModifier(m) }
        guard case .key = key.role else { return }
        state.engine.keyDown(key)
        guard key.repeats else { return }
        repeatTimer = Timer.scheduledTimer(withTimeInterval: MacKeyboardEngine.repeatDelay, repeats: false) { _ in
            MainActor.assumeIsolated {
                guard pressed else { return }
                state.engine.keyRepeat(key)
                repeatTimer = Timer.scheduledTimer(withTimeInterval: MacKeyboardEngine.repeatInterval,
                                                   repeats: true) { _ in
                    MainActor.assumeIsolated { state.engine.keyRepeat(key) }
                }
            }
        }
    }

    private func up() {
        let lifted = onKey
        pressed = false
        onKey = true
        repeatTimer?.invalidate()
        repeatTimer = nil
        switch key.role {
        case .key: state.engine.keyUp(key)
        case .modifier, .layer: break
        case .functionBlock: if lifted { state.functionKeys.toggle() }
        }
    }
}

private struct KeySizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
