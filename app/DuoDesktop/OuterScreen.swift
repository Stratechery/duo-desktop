import GlassActCore
import GlassActSession
import SwiftUI
import UIKit

/// The outer screen's two views. Vertical (the default): fixed sideways at the centre, one finger scrolls up and down
/// and a tap clicks. Free ("a traditional screen sharing app where you move the screen with two fingers and you tap
/// with one"): one finger taps or drags on the Mac, two fingers move the picture in any direction.
enum OuterMode: String, CaseIterable, Identifiable {
    case vertical, free

    var id: String { rawValue }
    /// The view the outer screen starts in. Simulator only (compiled out of device builds): `--outer-free` starts in
    /// free, for screenshots without a tap tool.
    static var start: OuterMode {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--outer-free") { return .free }
        #endif
        return .vertical
    }
    var title: String {
        switch self {
        case .vertical: "Vertical"
        case .free: "Free"
        }
    }
    /// Up-and-down for the view that only scrolls vertically (as build 22/23); the four-way arrows for the view
    /// that moves in any direction.
    var systemImage: String {
        switch self {
        case .vertical: "arrow.up.and.down"
        case .free: "arrow.up.and.down.and.arrow.left.and.right"
        }
    }
}

/// The outer screen's geometry. One Mac pixel per phone point over the whole outer display. Both views open at the
/// dialog spot: the Mac screen's horizontal centre on the display's centre (touches in the side strip register, so
/// the whole display is usable), raised to where macOS puts dialogs.
enum OuterWindow {
    /// The mockup's raised position: the window's centre at y 400 of 1080 (macOS puts dialogs high, not centred),
    /// placed at the centre of the fully touchable height, as built in build 23.
    static let raisedCentre: CGFloat = 400.0 / 1080.0

    /// The Mac screen's size in Mac pixels: the full picture width (before any slow-link shrink), same shape.
    static func macSize(gridWidth: Int, gridHeight: Int, fullWidth: Int?) -> CGSize {
        guard gridWidth > 0, gridHeight > 0 else { return .zero }
        let w = max(gridWidth, fullWidth ?? gridWidth)
        return CGSize(width: CGFloat(w), height: CGFloat(gridHeight) * CGFloat(w) / CGFloat(gridWidth))
    }

    /// Keeps the display's top-left (Mac pixels) so the display stays on the Mac screen, on each axis; a Mac screen
    /// smaller than the display on an axis is centred on it.
    static func clamp(_ o: CGPoint, mac: CGSize, display: CGSize) -> CGPoint {
        func axis(_ v: CGFloat, _ m: CGFloat, _ d: CGFloat) -> CGFloat {
            m <= d ? (m - d) / 2 : min(m - d, max(0, v))
        }
        return CGPoint(x: axis(o.x, mac.width, display.width), y: axis(o.y, mac.height, display.height))
    }

    /// The dialog spot: the Mac pixel at the display's top-left. Horizontally the Mac's centre is on the display's
    /// centre; vertically the raised centre (400/1080) sits at the touchable area's centre (build 23's height).
    static func dialogSpot(mac: CGSize, display: CGSize, touchable: CGRect) -> CGPoint {
        clamp(CGPoint(x: (mac.width - display.width) / 2, y: raisedCentre * mac.height - touchable.midY),
              mac: mac, display: display)
    }

    /// Vertical: x fixed at the Mac's centre on the display's centre; y between the Mac screen's top (at the display's
    /// top) and its bottom (at the touchable area's bottom, so the last Mac rows stay tappable; build 23). With the
    /// keyboard up the Mac's bottom stops at the keyboard's top instead, so every row can be scrolled above it, and
    /// never further: no black between the Mac's bottom and the keyboard.
    static func verticalClamp(_ o: CGPoint, mac: CGSize, display: CGSize, touchable: CGRect,
                              keyboardTop: CGFloat? = nil) -> CGPoint {
        let x = clamp(CGPoint(x: (mac.width - display.width) / 2, y: 0), mac: mac, display: display).x
        let bottom = mac.height - Self.bottom(touchable: touchable, keyboardTop: keyboardTop)
        let y = bottom <= 0 ? bottom / 2 : min(bottom, max(0, o.y))
        return CGPoint(x: x, y: y)
    }

    /// The Mac lock screen's password field, as a proportion of the Mac screen (x, y of its centre). Measured from
    /// The owner's build-28 screenshot (a real-phone screenshot, 1398 x 2034 px =
    /// 466 x 678 pt at 3x, scrolled to the bottom so Mac y 1080 is at phone y 644): the field spans phone x 154–312,
    /// y 532–559, so Mac x 881–1039 (centre 960 of 1920 = 0.5) and y 968–995 (centre 981.5 of 1080 = 0.909).
    static let passwordField = CGPoint(x: 0.5, y: 981.5 / 1080.0)

    /// The bottom of the space the picture may use: the keyboard's top while it is up, else the touchable bottom.
    static func bottom(touchable: CGRect, keyboardTop: CGFloat?) -> CGFloat {
        keyboardTop.map { min($0, touchable.maxY) } ?? touchable.maxY
    }

    /// Vertical's opening place: the Mac's centre on the display's centre. Keyboard up: the Mac's bottom edge resting
    /// on the keyboard's top, which leaves the password field (0.909 down the Mac) about 98 pt above the keys at 1080
    /// tall, 109 pt at 1200. Keyboard not up yet: the field in the middle of the touchable area.
    static func passwordSpot(mac: CGSize, display: CGSize, touchable: CGRect, keyboardTop: CGFloat?) -> CGPoint {
        if keyboardTop != nil {
            return verticalClamp(CGPoint(x: 0, y: CGFloat.greatestFiniteMagnitude), mac: mac, display: display,
                                 touchable: touchable, keyboardTop: keyboardTop)
        }
        let middle = (touchable.minY + bottom(touchable: touchable, keyboardTop: nil)) / 2
        return verticalClamp(CGPoint(x: 0, y: passwordField.y * mac.height - middle), mac: mac, display: display,
                             touchable: touchable, keyboardTop: nil)
    }

    /// How far the place last tapped (Mac y `tapY`) needs to stay above the keyboard's top so the field there reads.
    static let tapClearance: CGFloat = 44

    /// The keyboard came up (or grew): moves the picture just enough that Mac y `tapY` sits `tapClearance` above
    /// the keyboard's top; unchanged when it is already visible there.
    static func keepVisible(_ o: CGPoint, tapY: CGFloat, keyboardTop: CGFloat) -> CGPoint {
        let limit = keyboardTop - tapClearance
        let y = tapY - o.y
        return y > limit ? CGPoint(x: o.x, y: tapY - limit) : o
    }

    /// Where the whole picture sits in the view (points), on whole device pixels: one Mac pixel per point, the
    /// display's top-left at Mac pixel `origin`.
    static func pictureFrame(mac: CGSize, origin: CGPoint, screenScale: CGFloat) -> CGRect {
        let s = max(1, screenScale)
        return CGRect(x: (-origin.x * s).rounded() / s, y: (-origin.y * s).rounded() / s,
                      width: mac.width, height: mac.height)
    }

    /// The part of the Mac screen (Mac pixels) the whole display shows for a picture frame.
    static func shown(picture: CGRect, display: CGSize) -> CGRect {
        CGRect(x: -picture.minX, y: -picture.minY, width: display.width, height: display.height)
            .intersection(CGRect(origin: .zero, size: picture.size))
    }
}

/// The outer screen with a Mac to show: the picture fills the whole display; the two-way view selector sits under
/// the time and Wi-Fi. Choosing vertical brings the picture back to the dialog spot (free's way back there).
struct OuterSessionView: View {
    @Bindable var model: SessionModel
    let grid: TileGrid
    @State private var parts: SessionParts
    /// Bumped to put the picture back at the dialog spot (each appearance, each return to the app, choosing vertical).
    @State private var home = 0
    @State private var mode = OuterMode.start
    /// The iPhone's own keyboard. Up on every opening: the Mac is almost always locked when this screen is used, and
    /// the phone cannot tell (RESULT §2).
    @State private var typing = true
    /// The keyboard's height above the bottom safe area (`KeyboardGuideReader`); 0 while it is down.
    @State private var keyboardInset: CGFloat = 0
    /// The keyboard guide's top in window points (`KeyboardGuideReader.onWindowTop`).
    @State private var keyboardWindowTop: CGFloat?
    @State private var showMacs = false
    @Environment(\.scenePhase) private var scenePhase
    let list: MacList
    /// The strip's free run, display points (Apple's occlusion regions, `OuterStripLayout.run`): from where the
    /// system area ends at the top to where a region low in the column (the camera, turned) starts; the 190 floor
    /// and no bottom region until the first read.
    @State private var stripRun = OuterStripLayout.Run()
    /// A new run read while a finger is on the controls: applied when the finger lifts, so the controls never move
    /// under a touch in progress.
    @State private var pendingStripRun: OuterStripLayout.Run?
    /// Apple's active occlusion regions in display points (the full-display reader below); empty before iOS 27.1.
    @State private var occlusion: [CGRect] = []
    @GestureState private var stripTouched = false

    /// A new run from the region read: the controls move only when no finger is on them.
    private func takeStripRun(_ run: OuterStripLayout.Run) {
        #if targetEnvironment(simulator)
        if run != stripRun, run != pendingStripRun {
            print("[outer-system-area] end \(run.systemEnd) bottom region \(run.bottomRegionTop.map { "\($0)" } ?? "none")")
        }
        #endif
        if stripTouched { pendingStripRun = run } else if run != stripRun { stripRun = run; pendingStripRun = nil }
    }

    /// Opening with the keyboard up (on the password field) only when the password still has to be typed here
    /// (`SessionModel.outerOpensOnPassword`: locked and not unlocking automatically, or an older Host that does not
    /// say). Otherwise the dialog spot with the keyboard down. Simulator only: `--outer-keyboard-down` starts down.
    static func keyboardAtOpen(onPassword: Bool) -> Bool {
        #if targetEnvironment(simulator)
        if ProcessInfo.processInfo.arguments.contains("--outer-keyboard-down") { return false }
        // `--outer-keyboard-up` (README pictures): starts up, as for a locked Mac.
        if ProcessInfo.processInfo.arguments.contains("--outer-keyboard-up") { return true }
        #endif
        return onPassword
    }
    private var keyboardAtStart: Bool { Self.keyboardAtOpen(onPassword: model.outerOpensOnPassword) }

    /// The active occlusion regions in the reader's own points (the whole display); none before iOS 27.1.
    static func occlusionFrames(_ proxy: GeometryProxy) -> [CGRect] {
        guard #available(iOS 27.1, *) else { return [] }
        return proxy.reservedRegions(kind: .occlusion).filter(\.isActive).map(\.frame)
    }

    init(model: SessionModel, grid: TileGrid, list: MacList) {
        self.model = model
        self.grid = grid
        self.list = list
        _parts = State(initialValue: SessionParts(sink: model.input))
    }

    var body: some View {
        GeometryReader { proxy in
            let insets = proxy.safeAreaInsets
            // The strip beside the picture (right upright, left sideways), under the status indicators.
            let stripOnRight = insets.trailing >= insets.leading
            let strip = max(insets.trailing, insets.leading)
            // The picture fills the whole display edge to edge (the strip and bottom inset included); the safe
            // area, in the picture's own points, sets the dialog spot's height.
            let touchable = CGRect(x: insets.leading, y: insets.top, width: proxy.size.width,
                                   height: proxy.size.height)
            // The keyboard's top in the picture's points (the picture spans the whole display). Measured directly as
            // the keyboard guide's top in window points (the picture spans the window), not from safe-area sums, which
            // put it ~38 pt high sideways.
            let keyboardTop: CGFloat? = typing && keyboardInset > 0 ? keyboardWindowTop : nil
            OuterCanvasHost(controller: model.pictureController, grid: model.shownGrid ?? grid, generation: model.gridGeneration,
                            parts: parts, fullWidth: model.fullCanvasWidth, home: home, touchable: touchable,
                            mode: mode, keyboardTop: keyboardTop, opensOnPassword: model.outerOpensOnPassword)
                .allowsHitTesting(model.flow.acceptsInput)
                .overlay { if model.flow.showsHeldPicture { NotLiveOverlay(model: model) } }
                .background(Color.black)
                .padding(.top, -insets.top)
                .padding(.bottom, -insets.bottom)
                .padding(.leading, -insets.leading)
                .padding(.trailing, -insets.trailing)
                .frame(width: proxy.size.width, height: proxy.size.height)
                .overlay(alignment: .topLeading) {
                    if strip > 0 {
                        let display = CGSize(width: proxy.size.width + insets.leading + insets.trailing,
                                             height: proxy.size.height + insets.top + insets.bottom)
                        let place = OuterStripLayout.place(display: display, stripOnRight: stripOnRight,
                                                           keyboardTop: keyboardTop, systemEnd: stripRun.systemEnd,
                                                           bottomRegionTop: stripRun.bottomRegionTop)
                        OuterStrip(mode: mode, typing: typing, choose: { m in
                            // Choosing vertical (even when already chosen) returns to the opening place: the
                            // password spot with the keyboard up; choosing free keeps the picture where it is.
                            if m == .vertical { home += 1; typing = keyboardAtStart }
                            mode = m
                        }, toggleKeyboard: { typing.toggle() }, showMacs: { typing = false; showMacs = true },
                        arrangement: place.arrangement)
                        .fixedSize()
                        // Watches for a finger on the controls without taking it: a simultaneous gesture, so the
                        // buttons still get every tap; the state resets itself when the touch ends or is cancelled.
                        .simultaneousGesture(DragGesture(minimumDistance: 0).updating($stripTouched) { _, s, _ in
                            s = true
                        })
                        // `OuterStripLayout`: 16 pt below where the system area ends (measured), on its centre
                        // line, never under the keyboard. The overlay's origin is the safe area's top-left.
                        .offset(x: place.frame.minX - insets.leading, y: place.frame.minY - insets.top)
                    }
                }
                // The strip's free run from the regions in its column (the system area at the top, the camera
                // wherever it is): the controls follow it.
                .onChange(of: OuterStripLayout.run(regions: occlusion, display: CGSize(
                    width: proxy.size.width + insets.leading + insets.trailing,
                    height: proxy.size.height + insets.top + insets.bottom), stripOnRight: stripOnRight),
                          initial: true) { _, new in takeStripRun(new) }
                // The one hidden input for the iPhone's keyboard: the upright view's field (same traits, typing
                // goes straight to the Mac, nothing kept). No Mac keys row: the outer screen is 466 pt wide.
                .background {
                    MacTypingField(up: $typing, state: parts.keyboard, macKeysBar: false)
                        .frame(width: 1, height: 1)
                }
        }
        .ignoresSafeArea(.keyboard)
        // Where the system area ends: Apple's occlusion region (iOS 27.1), read from a reader that spans the whole
        // display (one that stops at the safe area does not overlap the strip and gets an empty list). The read
        // redraws this reader when the region changes (a Live Activity starting or ending), so nothing polls.
        .background {
            GeometryReader { full in
                let frames = Self.occlusionFrames(full)
                Color.clear.onChange(of: frames, initial: true) { _, new in occlusion = new }
            }
            .ignoresSafeArea()
        }
        .onChange(of: stripTouched) { _, touched in
            if !touched, let run = pendingStripRun { pendingStripRun = nil; stripRun = run }
        }
        .background {
            KeyboardGuideReader(onChange: { keyboardInset = $0 }, onWindowTop: { keyboardWindowTop = $0 })
                .ignoresSafeArea()
        }
        .background(Color(.systemBackground), ignoresSafeAreaEdges: .all)
        .sheet(isPresented: $showMacs) { OuterMacList(model: model, list: list) { showMacs = false } }
        .onChange(of: model.gridGeneration) { _, _ in
            if let g = model.grid { parts.setCanvas(width: g.width, height: g.height, fullWidth: model.fullCanvasWidth) }
        }
        .onChange(of: scenePhase) { _, new in
            if new == .active { mode = OuterMode.start; typing = keyboardAtStart; home += 1 }
        }
        // The Mac locked or unlocked, or an automatic unlock failed, while this screen is up: open again for the
        // new state.
        .onChange(of: model.macLocked) { _, _ in
            if mode == .vertical { typing = keyboardAtStart; home += 1 }
        }
        .onChange(of: model.outerOpensOnPassword) { _, _ in
            if mode == .vertical { typing = keyboardAtStart; home += 1 }
        }
        .overlay(alignment: .bottom) {
            if let text = model.unlockNotice { UnlockNoticeBanner(text: text) { model.dismissUnlockNotice() } }
        }
        .onAppear {
            mode = OuterMode.start
            typing = keyboardAtStart
            home += 1
            parts.setCanvas(width: grid.width, height: grid.height, fullWidth: model.fullCanvasWidth)
            let p = parts
            model.releaseHeldInput = { [weak p] in p?.releaseAll() }
            model.heldInputOwner = ObjectIdentifier(p)
        }
        .onDisappear {
            parts.releaseAll()
            if model.heldInputOwner == ObjectIdentifier(parts) {
                model.releaseHeldInput = nil
                model.heldInputOwner = nil
            }
        }
    }
}

/// The outer screen's controls under the time and Wi-Fi: two glass groups, each the system capsule's width (53 pt)
/// on its centre line, 16 pt apart and 16 pt below it. Group 1 the view (Vertical, Free), group 2 the actions
/// (Keyboard, Macs). HIG (Toolbars): group related items and separate groups with space; 44 pt targets (Layout).
struct OuterStrip: View {
    let mode: OuterMode
    let typing: Bool
    let choose: (OuterMode) -> Void
    let toggleKeyboard: () -> Void
    let showMacs: () -> Void

    /// Measured in the owner's build-28 screenshot (1398 x 2034 px at 3x = 466 x 678 pt): the system's capsule around the
    /// indicators spans x 392.0–445.3 pt (centre 418.7, 47.3 from the display's right edge; 53.3 wide) and ends at
    /// y 166.7. Build 28's selector sat at centre 424.2 (5.5 pt off) and started at 167.7 (touching).
    static let systemBottom: CGFloat = 166.7 // build 28's capsule; the taller one is `OuterStripLayout.reservedSystemBottom`
    static let edgeToCentre: CGFloat = 466 - 418.7
    /// The system's standard spacing between separate groups (16 pt, the iPhone's standard layout margin).
    static let gap: CGFloat = 16
    static var top: CGFloat { OuterStripLayout.top }
    static let button: CGFloat = 44
    static let padding: CGFloat = 4.5
    static let width: CGFloat = button + 2 * padding
    static let groupHeight: CGFloat = 2 * button + 4 + 2 * padding
    /// Top of the first group to the bottom of the second.
    static let height: CGFloat = 2 * groupHeight + gap

    /// How far the strip's frame moves outward from the safe area's edge so its centre sits `edgeToCentre` from
    /// the display's edge.
    static func offset(strip: CGFloat) -> CGFloat { strip - edgeToCentre + width / 2 }

    var arrangement: OuterStripLayout.Arrangement = .twoGroups

    private var actionButtons: some View {
        Group {
            OuterGlassButton(symbol: typing ? "keyboard.chevron.compact.down" : "keyboard", on: typing,
                             label: typing ? "Hide Keyboard" : "Keyboard", id: "outer.keyboard",
                             action: toggleKeyboard)
            OuterGlassButton(symbol: "desktopcomputer", on: false, label: "Macs", id: "outer.macs",
                             action: showMacs)
        }
    }

    private var modeButtons: some View {
        ForEach(OuterMode.allCases) { m in
            OuterGlassButton(symbol: m.systemImage, on: mode == m, label: m.title, id: "outerMode.\(m.rawValue)") {
                choose(m)
            }
        }
    }

    private func glass<C: View>(_ c: C) -> some View {
        c.padding(OuterStrip.padding)
            .glassEffect(.regular.tint(Color.black.opacity(0.45)), in: .capsule)
    }

    var body: some View {
        switch arrangement {
        case .twoGroups:
            VStack(spacing: Self.gap) {
                glass(VStack(spacing: 4) { modeButtons })
                glass(VStack(spacing: 4) { actionButtons })
            }
        case .oneGroup:
            glass(VStack(spacing: 4) { modeButtons; actionButtons })
        case .row:
            HStack(spacing: Self.gap) {
                glass(HStack(spacing: 4) { modeButtons })
                glass(HStack(spacing: 4) { actionButtons })
            }
        }
    }
}

/// Where the outer screen's controls go. In display points.
///
/// Defect 1: build 31 put the groups at a fixed y (183) measured from one screenshot, where the system's indicator
/// capsule ended at 166.7. In the owner's later screenshot the capsule is taller (the microphone-in-use island above
/// the time) and ends at about 189.3 (a real-phone screenshot, 568 px at 3x); the centre line is unchanged (418.7). iOS
/// exposes no frame for that capsule on this screen: the safe area gives only the strip's width,
/// `UIStatusBarManager.statusBarFrame` is the top bar (deprecated for layout, not this side strip), and no layout guide
/// covers it. So the room for its largest seen form is reserved: `reservedSystemBottom` 190 pt, then the 16 pt gap: the
/// groups start at 206.
///
/// Defect 2 (sideways, keyboard up: "it covers the keyboard button"): every arrangement is chosen for the space
/// actually above the keyboard; no control ever goes under it.
/// - Upright: one column on the capsule's centre line. Two groups (218 pt) when they fit between 206 and 8 pt above
///   the keyboard (or the display's bottom); else one group of four (197 pt); else a row of two groups (218 x 53)
///   just above the keyboard on the strip's side.
/// - Sideways: keyboard down: the same column as upright (206 + 218 = 424 of 466). Keyboard up: one row of the two
///   groups (218 x 53) along the top edge, 8 pt in, on the strip's side: the space above the keyboard is too short
///   for a column, and the middle of the picture (the password field) stays clear.
///
/// `systemEnd` is where the system area really ends, from Apple's occlusion region
/// (`systemEnd(regions:display:stripOnRight:)`), followed both ways (174 with nothing running on the simulator, 264
/// with a Live Activity). 190 is used only when there is no reading (before iOS 27.1, or no region). The groups start
/// `OuterStrip.gap` below it, and every arrangement stays clear of the system area (the strip's column from the top
/// down to `systemEnd`).
///
/// Turned with the camera at the bottom-right, the camera is a region low in the strip's column, and the controls ran
/// into it. Every region in the column now counts: those in its top half end the system area (`systemEnd`), those in
/// its bottom half end the run (`bottomRegionTop`), 16 pt above the highest of them. The ladder works in what is left;
/// nothing goes under either.
enum OuterStripLayout {
    /// The strip's free run, display points: `systemEnd` (the top regions' end, 190 without a reading) down to
    /// `bottomRegionTop` (the top of the highest region in the column's bottom half; nil when there is none).
    struct Run: Equatable {
        var systemEnd: CGFloat = OuterStripLayout.reservedSystemBottom
        var bottomRegionTop: CGFloat?
    }

    enum Arrangement: Equatable { case twoGroups, oneGroup, row }

    static let reservedSystemBottom: CGFloat = 190
    /// The first group's top with the system area at its floor (206).
    static let top: CGFloat = reservedSystemBottom + OuterStrip.gap
    static let margin: CGFloat = 8
    static let groupLong: CGFloat = 2 * OuterStrip.button + 4 + 2 * OuterStrip.padding // 101
    static let oneGroupLong: CGFloat = 4 * OuterStrip.button + 3 * 4 + 2 * OuterStrip.padding // 197
    static let twoGroupsLong: CGFloat = 2 * groupLong + OuterStrip.gap // 218

    struct Placement: Equatable {
        let arrangement: Arrangement
        /// The controls' whole frame, display points.
        let frame: CGRect
    }

    /// The system area as a rectangle in display points: the strip's column (as wide as the strip's controls, on
    /// the capsule's centre line, `margin` either side) from the top down to `systemEnd`.
    static func systemArea(display: CGSize, stripOnRight: Bool, systemEnd: CGFloat) -> CGRect {
        let centreX = stripOnRight ? display.width - OuterStrip.edgeToCentre : OuterStrip.edgeToCentre
        let half = OuterStrip.width / 2 + margin
        return CGRect(x: centreX - half, y: 0, width: 2 * half, height: max(0, systemEnd))
    }

    /// The system area's end from the occlusion regions (display points): the lowest bottom among the regions in
    /// the strip's column (the strip's side of the display, `edgeToCentre` x 2 wide). A region elsewhere is
    /// ignored. 190 when none is there or the reading is nonsense (not above 0, or more than 3/4 down the display).
    static func systemEnd(regions: [CGRect], display: CGSize, stripOnRight: Bool) -> CGFloat {
        let column = column(display: display, stripOnRight: stripOnRight)
        let ends = regions.filter { $0.intersects(column) && $0.minY < display.height / 2 }.map(\.maxY)
        guard let end = ends.max(), end.isFinite, end > 0, end <= display.height * 0.75 else { return reservedSystemBottom }
        return end
    }

    /// The strip's side of the display, `edgeToCentre` x 2 wide, full height: where the regions that count are.
    static func column(display: CGSize, stripOnRight: Bool) -> CGRect {
        let w = OuterStrip.edgeToCentre * 2
        return CGRect(x: stripOnRight ? display.width - w : 0, y: 0, width: w, height: display.height)
    }

    /// The top of the highest region in the bottom half of the strip's column (the camera when turned with it at
    /// the bottom); nil when there is none or the reading is nonsense.
    static func bottomRegionTop(regions: [CGRect], display: CGSize, stripOnRight: Bool) -> CGFloat? {
        let column = column(display: display, stripOnRight: stripOnRight)
        let tops = regions.filter { $0.intersects(column) && $0.minY >= display.height / 2 }.map(\.minY)
        guard let top = tops.min(), top.isFinite, top < display.height else { return nil }
        return top
    }

    /// The strip's free run from the occlusion regions (display points).
    static func run(regions: [CGRect], display: CGSize, stripOnRight: Bool) -> Run {
        Run(systemEnd: systemEnd(regions: regions, display: display, stripOnRight: stripOnRight),
            bottomRegionTop: bottomRegionTop(regions: regions, display: display, stripOnRight: stripOnRight))
    }

    /// The region low in the strip's column as a rectangle: the column's width (as `systemArea`) from
    /// `bottomRegionTop` to the display's bottom.
    static func bottomArea(display: CGSize, stripOnRight: Bool, bottomRegionTop: CGFloat) -> CGRect {
        let top = systemArea(display: display, stripOnRight: stripOnRight, systemEnd: 0)
        return CGRect(x: top.minX, y: bottomRegionTop, width: top.width, height: max(0, display.height - bottomRegionTop))
    }

    /// `systemEnd`: where the system area ends (`systemEnd(regions:display:stripOnRight:)`); 190 when not given.
    /// `bottomRegionTop`: where a region low in the strip's column starts (`bottomRegionTop(regions:…)`); the
    /// controls stay 16 pt above it.
    static func place(display: CGSize, stripOnRight: Bool, keyboardTop: CGFloat?,
                      systemEnd: CGFloat = reservedSystemBottom, bottomRegionTop: CGFloat? = nil) -> Placement {
        let w = OuterStrip.width
        let centreX = stripOnRight ? display.width - OuterStrip.edgeToCentre : OuterStrip.edgeToCentre
        let limit = (keyboardTop.map { min($0, display.height) } ?? display.height) - margin
        // The column's own bottom: 16 pt above a region low in it, never below the keyboard's limit.
        let columnLimit = bottomRegionTop.map { min(limit, $0 - OuterStrip.gap) } ?? limit
        let sideways = display.width > display.height
        let end = max(0, systemEnd)
        let top = end + OuterStrip.gap
        let blocked = [systemArea(display: display, stripOnRight: stripOnRight, systemEnd: end)]
            + (bottomRegionTop.map { [bottomArea(display: display, stripOnRight: stripOnRight, bottomRegionTop: $0)] } ?? [])
        // A row on the strip's side, or, when that would meet a region there, on the other side (the regions are
        // only in the strip's column). Never under a region.
        func row(y: CGFloat) -> Placement {
            let near = stripOnRight ? display.width - margin - twoGroupsLong : margin
            let far = stripOnRight ? margin : display.width - margin - twoGroupsLong
            let frame = CGRect(x: near, y: y, width: twoGroupsLong, height: w)
            if !blocked.contains(where: frame.intersects) { return Placement(arrangement: .row, frame: frame) }
            return Placement(arrangement: .row, frame: CGRect(x: far, y: y, width: twoGroupsLong, height: w))
        }
        if sideways, keyboardTop != nil { return row(y: margin) }
        if top + twoGroupsLong <= columnLimit {
            return Placement(arrangement: .twoGroups,
                             frame: CGRect(x: centreX - w / 2, y: top, width: w, height: twoGroupsLong))
        }
        if top + oneGroupLong <= columnLimit {
            return Placement(arrangement: .oneGroup,
                             frame: CGRect(x: centreX - w / 2, y: top, width: w, height: oneGroupLong))
        }
        // The row lies across the column too: it keeps clear of a region low in it as well as of the keyboard.
        return row(y: max(margin, columnLimit - w))
    }
}

/// One 44 pt glass button of the strip: white symbol; on = an accent circle (as the chosen view).
struct OuterGlassButton: View {
    let symbol: String
    let on: Bool
    let label: String
    let id: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(Color.white)
                .frame(width: OuterStrip.button, height: OuterStrip.button)
                .background { if on { Circle().fill(Color.accentColor) } }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(on ? .isSelected : [])
        .accessibilityIdentifier(id)
    }
}

/// Two choices, vertical first, in one glass capsule (build 23's place and glass): the chosen one an orange circle
/// with a white symbol; white symbols on dark-tinted glass read over white and dark pictures, light and dark mode.
struct OuterModeSelector: View {
    let mode: OuterMode
    let choose: (OuterMode) -> Void
    static let button = OuterStrip.button

    var body: some View {
        VStack(spacing: 4) {
            ForEach(OuterMode.allCases) { m in
                OuterGlassButton(symbol: m.systemImage, on: mode == m, label: m.title, id: "outerMode.\(m.rawValue)") {
                    choose(m)
                }
            }
        }
        .padding(OuterStrip.padding)
        .glassEffect(.regular.tint(Color.black.opacity(0.45)), in: .capsule)
    }
}

/// The Mac list on the outer screen: each Mac's name and state line as on the main list, a tap connects, the current
/// Mac marked, Disconnect. No add, edit or settings here (they stay on the open screen). A Mac that needs a password
/// sign-in says to open the iPhone: the sign-in sheet's two fields and the keyboard do not fit this 466 x 678 pt screen
/// together.
struct OuterMacList: View {
    @Bindable var model: SessionModel
    let list: MacList
    /// nil when the list is the outer screen itself (opened cold with no session).
    var close: (() -> Void)?
    @State private var openIPhoneFor: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(list.macs) { mac in row(mac) }
                } footer: {
                    if let name = openIPhoneFor {
                        Text("Open your iPhone to sign in to \(name).")
                    } else if list.macs.isEmpty {
                        Text("Open your iPhone to add a Mac.")
                    }
                }
                if let progress {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(progress).font(.subheadline).foregroundStyle(.secondary)
                        }
                        if case let .awaitingApproval(code) = model.phase {
                            LabeledContent("Code", value: code).font(.subheadline.monospaced())
                        }
                    }
                }
                if model.mac != nil {
                    Section {
                        Button("Disconnect", role: .destructive) { model.disconnect() }
                            .accessibilityIdentifier("outer.disconnect")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 44)
            .navigationTitle("Macs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let close {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Close", systemImage: "xmark", action: close)
                    }
                }
            }
        }
        .onAppear { list.probeAll(identity: model.identity) }
        .onChange(of: model.phase) { _, new in
            if new == .idle { list.probeAll(identity: model.identity) }
            // The sign-in sheet belongs to the open screen: say so here and stop waiting.
            if new == .signingIn, let name = model.mac?.name { openIPhoneFor = name; model.cancelSignIn() }
            if new == .inSession { close?() }
        }
    }

    private var progress: String? {
        switch model.phase {
        case .connecting: "Connecting to \(model.mac?.name ?? "the Mac")…"
        case .awaitingApproval: "Waiting for the Mac to allow this iPhone…"
        case let .reconnecting(attempt): "Reconnecting (try \(attempt))…"
        case .loadingPicture: "Waiting for the picture…"
        default: nil
        }
    }

    private func row(_ mac: MacEntry) -> some View {
        let reach = list.reach[mac.id] ?? .checking
        let current = model.mac?.id == mac.id
        return Button {
            tapped(mac, reach: reach, current: current)
        } label: {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(mac.name).font(.headline).lineLimit(1)
                    HStack(spacing: 4) {
                        if reach != .wrongMac {
                            Image(systemName: "circle.fill").font(.system(size: 7))
                                .foregroundStyle(MacRow.color(for: reach))
                        }
                        Text(reach.label)
                            .lineLimit(1)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    Text(MacRow.secondLine(mac: mac, reach: reach, chosen: list.chosen[mac.id]))
                        .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if current {
                    Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.accentColor)
                        .accessibilityLabel("Current Mac")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!current && (!reach.reachable || !idleOrLive))
        .accessibilityIdentifier("outerMac.\(mac.name)")
    }

    private var idleOrLive: Bool { model.phase == .idle || model.phase == .inSession }

    private func tapped(_ mac: MacEntry, reach: MacList.Reach, current: Bool) {
        if current { close?(); return }
        if reach == .signInNeeded { openIPhoneFor = mac.name; return }
        openIPhoneFor = nil
        if model.mac != nil { model.disconnect() }
        model.connect(to: mac, via: list.chosen[mac.id])
    }
}

/// While a cold open connects on the outer screen: the list screen's own "Connecting to …" words.
struct OuterConnectingView: View {
    let name: String
    var body: some View {
        Label { Text("Connecting to \(name)…") } icon: { ProgressView().controlSize(.small) }
            .font(.subheadline)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .glassEffect(.regular, in: .capsule)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The last Mac used, for a cold open on the outer screen.
enum LastMac {
    static let key = "lastMac"
    static func store(_ mac: MacEntry, in d: UserDefaults = .standard) { d.set(mac.id, forKey: key) }
    static func find(in macs: [MacEntry], d: UserDefaults = .standard) -> MacEntry? {
        guard let id = d.string(forKey: key) else { return nil }
        return macs.first { $0.id == id }
    }
    /// The Mac an outer-screen cold open connects to: none while the session already holds a Mac (live, rejoining, or
    /// keeping the last picture), so the cold open never replaces the Mac the inner screen was on. With more than one
    /// Mac it does not guess: the outer screen shows the Mac list.
    static func coldTarget(sessionMac: MacEntry?, idle: Bool, macs: [MacEntry],
                           d: UserDefaults = .standard) -> MacEntry? {
        guard sessionMac == nil, idle, macs.count == 1 else { return nil }
        return macs[0]
    }
}

private struct OuterCanvasHost: UIViewRepresentable {
    let controller: ViewerController?
    let grid: TileGrid
    let generation: Int
    let parts: SessionParts
    let fullWidth: Int
    let home: Int
    let touchable: CGRect
    let mode: OuterMode
    let keyboardTop: CGFloat?
    let opensOnPassword: Bool

    final class Coordinator { var generation = -1; var home = 0 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> CanvasView {
        let v = CanvasView(controller: controller, grid: grid)
        context.coordinator.generation = generation
        context.coordinator.home = home
        parts.canvas = v
        let trackpad = parts.trackpad
        v.onHostCursor = { x, y in trackpad.hostPointer(x: x, y: y) }
        v.touchEngine = parts.touch
        v.fullWidth = fullWidth
        v.outerTouchable = touchable
        v.outer = true
        v.outerMode = mode
        v.directTouch = true
        return v
    }

    func updateUIView(_ v: CanvasView, context: Context) {
        v.fullWidth = fullWidth
        v.outerTouchable = touchable
        v.switchOuterMode(to: mode)
        v.outerKeyboardTop = keyboardTop
        v.outerOpensOnPassword = opensOnPassword
        v.attach(controller)
        if context.coordinator.home != home {
            context.coordinator.home = home
            v.returnToDialogSpot()
        }
        v.follow(grid: grid, generation: generation, lastGeneration: &context.coordinator.generation)
    }

    static func dismantleUIView(_ v: CanvasView, coordinator: Coordinator) { v.stopPresenting() }
}
