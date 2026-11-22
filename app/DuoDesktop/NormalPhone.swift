import SwiftUI
import UIKit

// Duo Desktop on a normal iPhone (normal iPhone layout build (change)). The owner 2026-11-22: "The entire point of
// this app is to have precision control from a separate input device, i.e. the trackpad." / "I think we can use the
// dual desktop layup on a regular phone. It just has a much smaller trackpad and many fewer shortcut keys. The
// display on the Mac is square." The drawing is the specification: screenshots/normal-phone/R8-V1-light.png.

/// Which kind of iPhone the app runs on. The iPhone Duo is told apart by its hardware model identifier, never by a
/// size class or a screen size: on the Duo's outside screen the width is compact exactly as on a normal iPhone in
/// portrait, so the size class cannot tell them apart. The identifier is fixed in the hardware (`hw.machine`; in
/// the simulator, the `SIMULATOR_MODEL_IDENTIFIER` the runtime sets: "iPhone19,4" for the iPhone Duo simulator),
/// the same on both of the Duo's screens, folded or open, and it never changes while the app runs, so a Duo can
/// never be taken for a normal iPhone. (UIKit's hinge API, `UIHingeInteraction`, iOS 27.1, reports only through a
/// view's update handler after it is on screen, so it cannot decide the first frame; it is not used.)
enum PhoneKind {
    /// Every iPhone Duo model identifier. A new Duo model is added here.
    static let duoModels: Set<String> = ["iPhone19,4"]

    /// The pure decision, for the tests: a normal iPhone is an iPhone whose model is not a Duo.
    static func isNormalPhone(model: String, idiom: UIUserInterfaceIdiom) -> Bool {
        idiom == .phone && !duoModels.contains(model)
    }

    /// This device's model identifier.
    static var modelIdentifier: String {
        if let sim = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"], !sim.isEmpty { return sim }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    /// Decided once per launch.
    @MainActor static let current: Bool = isNormalPhone(model: modelIdentifier, idiom: UIDevice.current.userInterfaceIdiom)

    /// Sideways on a normal iPhone: how far the horizontal layout keeps its controls in from each side. Only the
    /// Dynamic Island's side gets the window's safe-area inset (HIG Layout: keep controls out of the sensor
    /// housing's area); the other side keeps the Duo's own 10 pt edge.
    @MainActor static func sidewaysInsets() -> (leading: CGFloat, trailing: CGFloat) {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let window = scene.windows.first(where: \.isKeyWindow) ?? scene.windows.first else { return (0, 0) }
        let inset = window.safeAreaInsets
        switch scene.effectiveGeometry.interfaceOrientation {
        case .landscapeRight: return (inset.left, 0)    // top of the phone (the island) on the left
        case .landscapeLeft: return (0, inset.right)    // the island on the right
        default: return (0, 0)
        }
    }
}

/// The normal iPhone's upright layout, top to bottom under the top row: the Mac picture, square and full width
/// (Follow Pointer), then the band (Click full height at the outer left edge, a column of Right click, "…", Scroll,
/// then the trackpad), then our own keyboard (the system keyboard only in the Terminal view). Sizes from the drawing
/// at 402 pt wide (Click 80, column 50, 6 and 8 pt gaps, the band 126 tall), scaled with the width so smaller and Max phones lay out the same way. Every touch
/// area is 44 pt or more (HIG Buttons: "a hit region of at least 44x44 pt"). When the screen is too short to keep
/// the picture square above a band of three 44 pt rows, the picture gives way first; the band never does.
struct NormalPhoneLayout: Equatable {
    static let drawnWidth: CGFloat = 402
    static let margin: CGFloat = 8
    static let gap: CGFloat = 6
    static let split: CGFloat = 8
    /// The drawing's 6 pt between the picture and the band and between the band and our keyboard.
    static let pad: CGFloat = 6
    /// Our own keyboard, upright (`TouchKeyboardLayout.Sizes.portrait`): 190 pt tall at every width (keys 40,
    /// rows 48 apart, so each key's touch area is 48 tall). Its own 6 pt top inset is the gap under the band.
    static func ownKeyboardHeight(width: CGFloat) -> CGFloat {
        TouchKeyboardLayout.height(width: width, sizes: .portrait)
    }
    /// One column cell drawn 38 tall; with half of each 6 pt gap above and below it touches 44.
    static let cellHeight: CGFloat = 38
    static let minTouch: CGFloat = 44
    /// The band's least height: three cells and two gaps.
    static let minBand: CGFloat = 3 * cellHeight + 2 * gap
    /// The "…" page: 3 rows of 8.
    static let moreColumns = 8

    let size: CGSize
    let keyboardInset: CGFloat
    /// The gap between the band and the keyboard: `pad` over the system keyboard (Terminal view); 0 over our own
    /// keyboard, whose first row already sits 6 pt down.
    var keyboardGap: CGFloat = NormalPhoneLayout.pad

    private var k: CGFloat { size.width / Self.drawnWidth }
    var keyboardTop: CGFloat { size.height - keyboardInset }
    /// Square when it fits; otherwise as tall as leaves the band its least height.
    var picture: CGRect {
        let room = keyboardTop - Self.pad - keyboardGap - Self.minBand
        return CGRect(x: 0, y: 0, width: size.width, height: max(0, min(size.width, room)).rounded(.down))
    }
    var pictureIsSquare: Bool { picture.height >= size.width }
    var band: CGRect {
        let top = picture.maxY + Self.pad
        return CGRect(x: Self.margin, y: top, width: size.width - 2 * Self.margin,
                      height: max(Self.minBand, keyboardTop - keyboardGap - top))
    }
    var clickWidth: CGFloat { max(Self.minTouch, (80 * k).rounded()) }
    var columnWidth: CGFloat { max(Self.minTouch, (50 * k).rounded()) }
    var click: CGRect { CGRect(x: band.minX, y: band.minY, width: clickWidth, height: band.height) }
    var column: CGRect {
        CGRect(x: click.maxX + Self.gap, y: band.minY, width: columnWidth, height: band.height)
    }
    /// The column's three cells, top to bottom: Right click, "…", Scroll (the owner: "Scroll should be on bottom. Right
    /// click is the least used").
    func cell(_ i: Int) -> CGRect {
        let h = (band.height - 2 * Self.gap) / 3
        return CGRect(x: column.minX, y: band.minY + CGFloat(i) * (h + Self.gap), width: column.width, height: h)
    }
    var trackpad: CGRect {
        let x = column.maxX + Self.split
        return CGRect(x: x, y: band.minY, width: band.maxX - x, height: band.height)
    }
    /// A cell's touch height: its drawn height plus the gaps it shares.
    var cellTouchHeight: CGFloat { cell(0).height + Self.gap }
    /// The "…" page's key size.
    var moreKey: CGSize {
        let w = ((band.width - CGFloat(Self.moreColumns - 1) * Self.gap) / CGFloat(Self.moreColumns)).rounded(.down)
        return CGSize(width: w, height: ((band.height - 2 * Self.gap) / 3).rounded(.down))
    }
    /// The Terminal view: the terminal takes the picture's and the band's space except the one row of terminal keys
    /// (`keysRow` tall, at the band's bottom, on the keyboard), as on the Duo. The pad above the band stays between
    /// the terminal and the row.
    func terminalHeight(keysRow: CGFloat) -> CGFloat { picture.height + max(0, band.height - keysRow) }
    /// Where the row of terminal keys starts inside the band.
    func terminalKeysTop(keysRow: CGFloat) -> CGFloat { max(0, band.height - keysRow) }
    /// Where the band's keyboard-coloured panel starts in the Terminal view, from the picture's top: where the
    /// terminal ends, so the panel never covers the terminal's last rows (build 51 started it at the picture's
    /// bottom edge and hid about 80 pt of the terminal behind it).
    func terminalPanelTop(keysRow: CGFloat) -> CGFloat { picture.height + terminalKeysTop(keysRow: keysRow) }
    var moreKeyTouch: CGSize { CGSize(width: moreKey.width + Self.gap, height: moreKey.height + Self.gap) }

    /// The "…" page, by key id (`SpecialKeysLayout.cell`); "back" is the lit way back, in the "…" button's spot.
    static let moreTable: [[String]] = [
        ["copy", "paste", "cut", "undo", "redo", "selectall", "save", "find"],
        ["escape", "tab", "back", "control", "option", "command", "shift", "fblock"],
        ["switchapp", "spotlight", "close", "quit", "left", "up", "down", "right"],
    ]
}

/// The normal iPhone's band: the drawing's Click, column and trackpad, or the "…" page in its place. Reuses the
/// app's own click buttons, keys and trackpad (no second copy); modifiers latch in the session's keyboard engine,
/// so they stay held after going back.
struct NormalPhoneBand: View {
    @Bindable var state: KeyboardState
    let pad: TrackpadEngine
    let layout: NormalPhoneLayout
    let trackpadDimmed: Bool
    @Binding var more: Bool

    var body: some View {
        let origin = layout.band.origin
        ZStack(alignment: .topLeading) {
            if more { morePage } else { normal(origin) }
        }
        .frame(width: layout.band.width, height: layout.band.height, alignment: .topLeading)
    }

    @ViewBuilder private func normal(_ o: CGPoint) -> some View {
        ClickButton(pad: pad, button: .left)
            .frame(width: layout.click.width, height: layout.click.height)
            .offset(x: layout.click.minX - o.x, y: 0)
        ClickButton(pad: pad, button: .right).place(layout.cell(0), o)
        Button {
            KeyFeedback.keyDown()
            more = true
        } label: { EmptyView() }
            .buttonStyle(KeyButtonStyle(content: .symbol("ellipsis")))
            .accessibilityLabel("More Keys")
            .accessibilityIdentifier("moreKeys")
            .place(layout.cell(1), o)
        ClickButton(pad: pad, button: .scroll).place(layout.cell(2), o)
        TrackpadView(engine: pad)
            .background(KeyLook.keyFill, in: RoundedRectangle(cornerRadius: TrackpadView.cornerRadius, style: .continuous))
            .opacity(trackpadDimmed ? 0.4 : 1)
            .allowsHitTesting(!trackpadDimmed)
            .place(layout.trackpad, o)
    }

    private var morePage: some View {
        let size = layout.moreKey
        return VStack(alignment: .leading, spacing: NormalPhoneLayout.gap) {
            ForEach(Array(NormalPhoneLayout.moreTable.enumerated()), id: \.offset) { _, row in
                HStack(spacing: NormalPhoneLayout.gap) {
                    ForEach(row, id: \.self) { id in
                        Group {
                            if id == "back" {
                                Button {
                                    KeyFeedback.keyDown()
                                    more = false
                                } label: { EmptyView() }
                                    .buttonStyle(KeyButtonStyle(content: .symbol("chevron.backward"), lit: true))
                                    .accessibilityLabel("Back to Trackpad")
                                    .accessibilityIdentifier("moreBack")
                            } else {
                                KeyCell(state: state, cell: SpecialKeysLayout.cell(id, functionKeys: state.functionKeys))
                            }
                        }
                        .frame(width: size.width, height: size.height)
                    }
                }
            }
        }
    }
}

private extension View {
    func place(_ r: CGRect, _ o: CGPoint) -> some View {
        frame(width: r.width, height: r.height).offset(x: r.minX - o.x, y: r.minY - o.y)
    }
}

/// The normal iPhone's top row: back, the name bubble, the one view button, across the full width (the row sits
/// under the status bar, not beside the clock as on the open Duo). The bubble takes what the two round buttons, the
/// bar's side margins and its two fixed spacers leave (the owner 2026-11-22, on build 51's three view buttons: "This should
/// be a drop down menu, as there isn't enough horizontal space").
enum NormalPhoneTopRow {
    static let sideMargin: CGFloat = 16
    static let spacer: CGFloat = 12
    /// `selectorWidth`: the view button's width; one round button, as wide as the back button.
    static func nameMax(rowWidth: CGFloat, selectorWidth: CGFloat = TopRow.height) -> CGFloat {
        max(80, rowWidth - 2 * sideMargin - TopRow.height - selectorWidth - 2 * spacer - slack)
    }
    /// What the bar keeps free beside its glass (build 56, every part on the bar's own glass): at 402 pt an
    /// over-long two-line name sent the whole row into "•••" with 8 and with 24; with 40 it ends at x 366 (measured,
    /// `TopRowTests.testTopBarHasNoGlassInsideGlass`).
    static let slack: CGFloat = 40
}

/// The normal iPhone's view button (a `TopBarItem`: the bar draws its round glass), showing the current view's
/// symbol. With two or more
/// views it opens a menu of them, each with its symbol and name, the current one checked. HIG Pop-up buttons: "A
/// pop-up button displays a menu of mutually exclusive options", and after a choice "the button can update its
/// content to indicate the current selection"; built as a SwiftUI `Menu` holding an inline `Picker` (HIG Menus),
/// which draws the check. With one view there is nothing to choose, so it is plain: the symbol only, not a button
/// (HIG Pop-up buttons are for a choice among options). The bar's round glass, as wide as back (HIG Buttons: at least 44).
struct ViewMenuButton: View {
    @Binding var view: SessionView
    let choices: [SessionView]

    /// One menu row: what it shows.
    struct Item: Equatable {
        let view: SessionView
        let title: String
        let symbol: String
        let checked: Bool
    }

    /// The menu's rows, in the switch's order; empty when there is nothing to choose (one view).
    static func items(choices: [SessionView], current: SessionView) -> [Item] {
        guard opensMenu(choices) else { return [] }
        return choices.map { Item(view: $0, title: $0.title, symbol: $0.systemImage, checked: $0 == current) }
    }

    static func opensMenu(_ choices: [SessionView]) -> Bool { choices.count > 1 }

    /// The symbol on the button: the current view's (the first choice if the current one is not offered).
    static func shown(choices: [SessionView], current: SessionView) -> SessionView {
        choices.contains(current) ? current : choices.first ?? current
    }

    var body: some View {
        let shown = Self.shown(choices: choices, current: view)
        if Self.opensMenu(choices) {
            Menu {
                Picker("View", selection: $view) {
                    ForEach(choices) { v in
                        Label(v.title, systemImage: v.systemImage)
                            .tag(v)
                            .accessibilityIdentifier("viewMenu.\(v.rawValue)")
                    }
                }
                .pickerStyle(.inline)
            } label: {
                symbol(shown)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("View")
            .accessibilityValue(shown.title)
            .accessibilityIdentifier("viewMenu")
        } else {
            symbol(shown)
                .accessibilityElement()
                .accessibilityLabel(shown.title)
                .accessibilityIdentifier("viewMenu")
        }
    }

    private func symbol(_ v: SessionView) -> some View {
        Image(systemName: v.systemImage)
            .font(.system(size: 17, weight: .medium))
            .foregroundStyle(Color.primary)
            // A system bar button's content size (the back button's, measured: 36 x 36); the bar draws the same
            // round glass around it as around back, and its touch area is the bar's 44 pt glass.
            .frame(width: TopRow.itemContent, height: TopRow.itemContent)
            .contentShape(Circle())
    }
}
