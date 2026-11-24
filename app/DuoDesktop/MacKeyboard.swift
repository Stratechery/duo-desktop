import CoreGraphics
import Foundation
import GlassActSession

/// One key of the on-screen Mac keyboard: a physical US ANSI key (Carbon `kVK_*` code), never a character.
/// The Mac's own keyboard layout turns it into a character, as with a real keyboard.
struct MacKey: Identifiable, Equatable {
    enum Role: Equatable {
        case key
        case modifier(KeyMap.Modifier)
        /// Switches between the letters layer and the numbers/symbols layer.
        case layer
        /// Upright band: swaps the shortcut block for the F1-F12 block and back.
        case functionBlock
    }

    let id: String
    let label: String
    let code: UInt16
    /// Flags the key carries itself: Shift for a shifted symbol, Fn and numeric pad for arrows, Fn for the
    /// navigation block and F-keys (as a Mac keyboard's own events have them; `HIDKeyMap` does the same).
    let ownFlags: UInt32
    let role: Role
    let repeats: Bool
    /// Width in key units (1 = a letter key).
    let width: Double

    init(_ label: String, _ code: UInt16, id: String? = nil, flags: UInt32 = 0, role: Role = .key,
         repeats: Bool = false, width: Double = 1) {
        self.id = id ?? label
        self.label = label
        self.code = code
        ownFlags = flags
        self.role = role
        self.repeats = repeats
        self.width = width
    }

    static func == (l: MacKey, r: MacKey) -> Bool { l.id == r.id }
}

enum MacKeyFlags {
    static let shift: UInt32 = 0x0002_0000
    static let numericPad: UInt32 = 1 << 21
    static let function: UInt32 = 1 << 23
    static let arrow = function | numericPad
}

/// The US ANSI key table, as the two layers of the first upright keyboard (plan §4). No longer drawn: the iOS system
/// keyboard does the typing now, and `MacTyping` turns each typed character into the key listed here.
enum MacKeyboardLayout {
    private static func letter(_ c: String, _ code: UInt16) -> MacKey { MacKey(c, code, repeats: true) }
    private static func shifted(_ c: String, _ code: UInt16) -> MacKey {
        MacKey(c, code, flags: MacKeyFlags.shift, repeats: true)
    }

    static let shiftKey = MacKey("⇧", 56, id: "shift", role: .modifier(.shift), width: 1.5)
    static let controlKey = MacKey("⌃", 59, id: "control", role: .modifier(.control), width: 1.25)
    static let optionKey = MacKey("⌥", 58, id: "option", role: .modifier(.option), width: 1.25)
    static let commandKey = MacKey("⌘", 55, id: "command", role: .modifier(.command), width: 1.5)
    static let escape = MacKey("esc", 53, id: "escape")
    static let tab = MacKey("tab", 48, id: "tab", width: 1.5)
    static let delete = MacKey("⌫", 51, id: "delete", repeats: true, width: 2)
    static let returnKey = MacKey("⏎", 36, id: "return", width: 2)
    static let space = MacKey("space", 49, id: "space", repeats: true, width: 4.5)
    static let left = MacKey("←", 123, id: "left", flags: MacKeyFlags.arrow, repeats: true)
    static let right = MacKey("→", 124, id: "right", flags: MacKeyFlags.arrow, repeats: true)
    static let down = MacKey("↓", 125, id: "down", flags: MacKeyFlags.arrow, repeats: true)
    static let up = MacKey("↑", 126, id: "up", flags: MacKeyFlags.arrow, repeats: true)
    static let layerKey = MacKey("123", 0, id: "layer", role: .layer, width: 1.5)
    static let lettersKey = MacKey("abc", 0, id: "layer", role: .layer, width: 1.5)

    /// Every row of the main keyboard is this many key units wide (1 unit = a letter key plus its gap). Widths
    /// follow a US ANSI Mac keyboard (delete 2, tab 1.5, \\ 1.5, return 2, command 1.5) less the keys this
    /// narrow block leaves to the extra rows (` - = [ ] and caps lock).
    static let mainUnits: Double = 13

    /// The bottom row's arrows sit as ← [↑ over ↓] →; the view stacks `up`/`down`.
    static let bottomRow: [MacKey] = [layerKey, controlKey, optionKey, commandKey, space, left, up, down, right]

    static let letters: [[MacKey]] = [
        [escape] + zip(["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
                       [18, 19, 20, 21, 23, 22, 26, 28, 25, 29] as [UInt16]).map { letter($0, $1) } + [delete],
        [tab] + zip(["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
                    [12, 13, 14, 15, 17, 16, 32, 34, 31, 35] as [UInt16]).map { letter($0, $1) }
            + [MacKey("\\", 42, id: "\\", repeats: true, width: 1.5)],
        zip(["a", "s", "d", "f", "g", "h", "j", "k", "l", ";", "'"],
            [0, 1, 2, 3, 5, 4, 38, 40, 37, 41, 39] as [UInt16]).map { letter($0, $1) } + [returnKey],
        [shiftKey] + zip(["z", "x", "c", "v", "b", "n", "m", ",", ".", "/"],
                         [6, 7, 8, 9, 11, 45, 46, 43, 47, 44] as [UInt16]).map { letter($0, $1) }
            + [MacKey("⇧", 56, id: "shift-right", role: .modifier(.shift), width: 1.5)],
        bottomRow,
    ]

    static let symbols: [[MacKey]] = [
        [escape] + zip(["!", "@", "#", "$", "%", "^", "&", "*", "(", ")"],
                       [18, 19, 20, 21, 23, 22, 26, 28, 25, 29] as [UInt16]).map { shifted($0, $1) } + [delete],
        [tab] + [letter("-", 27), letter("=", 24), letter("[", 33), letter("]", 30), letter("\\", 42),
                 letter("`", 50), shifted("_", 27), shifted("+", 24), shifted("{", 33), shifted("}", 30)]
            + [MacKey("|", 42, id: "|", flags: MacKeyFlags.shift, repeats: true, width: 1.5)],
        [shifted("~", 50), shifted(":", 41), shifted("\"", 39), shifted("<", 43),
         shifted(">", 47), shifted("?", 44),
         MacKey("home", 115, id: "home", flags: MacKeyFlags.function),
         MacKey("end", 119, id: "end", flags: MacKeyFlags.function),
         MacKey("pg↑", 116, id: "pageup", flags: MacKeyFlags.function),
         MacKey("pg↓", 121, id: "pagedown", flags: MacKeyFlags.function),
         MacKey("⏎", 36, id: "return", width: 3)],
        functionKeys + [MacKey("⌦", 117, id: "forwarddelete", flags: MacKeyFlags.function, repeats: true)],
        [lettersKey] + bottomRow.dropFirst(),
    ]

    static let functionKeys: [MacKey] =
        zip((1...12).map { "F\($0)" }, [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111] as [UInt16])
            .map { MacKey($0, $1, flags: MacKeyFlags.function) }

    /// A cell of a key row: a key, a gap of `width` units (as between key groups), or a shortcut.
    enum Cell: Identifiable {
        case key(MacKey)
        case gap(Double, id: String)
        case shortcut(MacShortcut)
        var id: String {
            switch self {
            case let .key(k): "k-" + k.id
            case let .gap(_, id): "g-" + id
            case let .shortcut(s): "s-" + s.id
            }
        }
        var width: Double {
            switch self {
            case let .key(k): k.width
            case let .gap(w, _): w
            case let .shortcut(s): s.width
            }
        }
    }

}

/// The upright layout's special keys. The iOS system keyboard does the typing; these are the Mac keys it lacks.
///
/// One grid of 8 equal columns by 4 rows. The two outer columns hold the buttons (`ClickButtonsLayout`): Left click
/// rows 1-2, Right click row 3, Scroll row 4. The other 6 columns hold the 24 keys, as `table` lists them. No fn key.
/// The "more" key swaps the 12 shortcut cells for F1-F12 and the four arrows for home, page up, page down and end (the
/// Mac's own fn+arrow meanings: fn+← home, fn+↑ page up, fn+↓ page down, fn+→ end), in the same places; the rest stays.
enum SpecialKeysLayout {
    typealias Cell = MacKeyboardLayout.Cell
    /// The keys' columns (right of the click buttons) and rows.
    static let columns = 6
    static let rowCount = 4
    /// The whole grid: the click buttons' 2 columns and the keys' 6.
    static let gridColumns = ClickButtonsLayout.columns + columns
    static let units = Double(gridColumns)

    /// THE arrangement: one row per line, left to right, by key id (a shortcut's id or a key's id). Moving a key is a
    /// change to this table only.
    static let table: [[String]] = [
        ["copy", "paste", "cut", "undo", "redo", "selectall"],
        ["save", "find", "switchapp", "spotlight", "close", "quit"],
        ["escape", "tab", "left", "up", "down", "right"],
        ["control", "option", "command", "shift", "forwarddelete", "fblock"],
    ]

    /// Swaps the shortcut cells for F1-F12 and the arrows for the navigation keys, and back.
    static let moreKey = MacKey("more", 0, id: "fblock", role: .functionBlock)
    static let forwardDelete = MacKey("⌦", 117, id: "forwarddelete", flags: MacKeyFlags.function, repeats: true)
    static let home = MacKey("↖", 115, id: "home", flags: MacKeyFlags.function)
    static let end = MacKey("↘", 119, id: "end", flags: MacKeyFlags.function)
    static let pageUp = MacKey("pg↑", 116, id: "pageup", flags: MacKeyFlags.function)
    static let pageDown = MacKey("pg↓", 121, id: "pagedown", flags: MacKeyFlags.function)

    /// Every key the table may name, by id: the keys at one unit wide; tab shows the Mac's ⇥.
    private static let keysByID: [String: MacKey] = Dictionary(uniqueKeysWithValues: [
        MacKeyboardLayout.escape, MacKeyboardLayout.tab.relabeled("⇥"), forwardDelete, moreKey,
        MacKeyboardLayout.controlKey, MacKeyboardLayout.optionKey, MacKeyboardLayout.commandKey,
        MacKeyboardLayout.shiftKey, MacKeyboardLayout.left, MacKeyboardLayout.up, MacKeyboardLayout.down,
        MacKeyboardLayout.right,
    ].map { ($0.id, $0.widened(1)) })

    /// What "more" puts in a cell: F1-F12 for the shortcuts in `MacShortcut.all` order, and the fn+arrow keys.
    private static let moreSwap: [String: MacKey] = {
        var m: [String: MacKey] = ["left": home, "up": pageUp, "down": pageDown, "right": end]
        for (s, f) in zip(MacShortcut.all, MacKeyboardLayout.functionKeys) { m[s.id] = f }
        return m
    }()

    /// A PC's Print Screen (the Mac's F13 position, key code 105; `RDPKeys` sends it as E0 37).
    static let printScreen = MacKey("PrtSc", 105, id: "printscreen", flags: MacKeyFlags.function)
    /// On a PC the "…" page also has Print Screen and Task View (⊞+Tab), in esc's and tab's places (plan §2 "Keys":
    /// "adds Delete, Print Screen and ⊞+Tab"; ⌦ is already the PC's Delete).
    static func windowsMore(_ id: String) -> Cell? {
        switch id {
        case "escape": .key(printScreen.widened(1))
        case "tab": .shortcut(.windowsTaskView)
        default: nil
        }
    }

    static func cell(_ id: String, functionKeys: Bool, windows: Bool = false) -> Cell {
        if functionKeys, windows, let c = windowsMore(id) { return c }
        if functionKeys, let k = moreSwap[id] { return .key(k.widened(1)) }
        if let s = MacShortcut.all.first(where: { $0.id == id }) { return .shortcut(s) }
        guard let k = keysByID[id] else { preconditionFailure("SpecialKeysLayout.table: no key \(id)") }
        return .key(k)
    }

    /// The keys' 4 rows of 6, left to right on screen. `functionKeys`: the "more" block is showing. The order is the
    /// same with the trackpad on either side.
    static func rows(functionKeys: Bool, windows: Bool = false) -> [[Cell]] {
        table.map { row in row.map { cell($0, functionKeys: functionKeys, windows: windows) } }
    }
}

extension SpecialKeysLayout {
    /// Every key or shortcut either 16:9 grid shows (normal and "more"), by id, for the 16:10 tables: a 16:10 key
    /// is the very same key its 16:9 counterpart is, so it sends the same.
    static func anyCell(_ id: String) -> Cell {
        let all = (rows(functionKeys: false) + rows(functionKeys: true)).joined()
        guard let c = all.first(where: { $0.id == "k-" + id || $0.id == "s-" + id }) else {
            preconditionFailure("SixteenTenKeysLayout: no key \(id)")
        }
        return c
    }
}

/// The shape of the picture the Mac sends (the negotiated canvas). 16:10 gets its own upright layout; everything else
/// keeps today's 16:9 layout.
enum PictureShape: Equatable {
    case sixteenNine, sixteenTen

    /// The layout that shows the Mac's screen largest: the screen fitted into each upright layout's picture box (same
    /// width; heights 10/16 and 9/16 of it), the larger area wins, a tie goes to 16:9. In effect every screen narrower
    /// than 16:9 gets 16:10, and 16:9 or wider ties (the picture is width-bound in both) and gets 16:9. The Mac's
    /// resolution is never changed.
    static func of(width: Int, height: Int) -> PictureShape {
        guard width > 0, height > 0 else { return .sixteenNine }
        let ten = fittedArea(width: width, height: height, box: Self.sixteenTen.heightOverWidth)
        let nine = fittedArea(width: width, height: height, box: Self.sixteenNine.heightOverWidth)
        return ten > nine * (1 + 1e-9) ? .sixteenTen : .sixteenNine
    }

    /// The area of a `width` x `height` screen fitted (no crop) into a box 1 wide and `box` tall.
    static func fittedArea(width: Int, height: Int, box: CGFloat) -> CGFloat {
        let a = CGFloat(width) / CGFloat(height)
        return a >= 1 / box ? 1 / a : box * box * a
    }

    /// The upright picture's height for its (full) width.
    var heightOverWidth: CGFloat { self == .sixteenTen ? 10 / 16 : 9 / 16 }

    var label: String { self == .sixteenTen ? "16:10" : "16:9" }
}

/// The layout's shape, decided ONCE for the screen being shown and then held. Decided at the session's first picture
/// and when the shown screen changes (the user's choice, an edge crossing, or opening on the remembered screen).
/// Nothing else runs `PictureShape.of` again: not a new picture size, rotation, the keyboard, a rejoin to the same
/// screen, the overview, Follow Pointer. The session model owns it; the views only read `shape`.
struct LayoutShapeDecision: Equatable {
    enum Reason: String {
        case firstPicture = "first picture"
        case chosen = "screen chosen"
        case crossing = "edge crossing"
        case remembered = "opened on the remembered screen"
    }

    private(set) var shape: PictureShape?
    /// The screen the shape was decided for; nil until the Host names it (an older Host never does).
    private(set) var screenID: UInt32?
    /// How many times it has been decided this session (tests, log).
    private(set) var decisions = 0

    /// The session's first picture: decides only if nothing is decided yet (a rejoin keeps the decision).
    mutating func firstPicture(width: Int, height: Int) -> String? {
        guard shape == nil else { return nil }
        return decide(.of(width: width, height: height), screen: nil, reason: .firstPicture,
                      sizes: "picture \(width)x\(height)")
    }

    /// The Host's list named the shown screen: the first decision belongs to it. Never decides again.
    mutating func listed(shownID: UInt32?) {
        if shape != nil, screenID == nil { screenID = shownID }
    }

    /// A screen became the shown screen. Decides again only if it is another screen than the one decided for; the
    /// size is the Mac screen's own (the list's), else the picture's.
    mutating func shown(id: UInt32, screenSize: CGSize?, pictureWidth: Int, pictureHeight: Int,
                        reason: Reason) -> String? {
        guard id != screenID || shape == nil else { return nil }
        if let s = screenSize, s.width > 0, s.height > 0 {
            return decide(.of(width: Int(s.width), height: Int(s.height)), screen: id, reason: reason,
                          sizes: "screen \(Int(s.width))x\(Int(s.height)), picture \(pictureWidth)x\(pictureHeight)")
        }
        return decide(.of(width: pictureWidth, height: pictureHeight), screen: id, reason: reason,
                      sizes: "picture \(pictureWidth)x\(pictureHeight) (no screen size)")
    }

    private mutating func decide(_ new: PictureShape, screen: UInt32?, reason: Reason, sizes: String) -> String {
        shape = new
        screenID = screen
        decisions += 1
        return "layout shape decided: \(new.label) (\(reason.rawValue)) for screen \(screen.map(String.init) ?? "-")"
            + " from \(sizes)"
    }
}

/// The upright band's keys for a 16:10 picture: 3 rows instead of 4. The click column stays at the outer edge: Left
/// click two rows tall, Right click and Scroll side by side in the third row (`ClickButtonsLayout`'s 2 columns). "More"
/// shows 3 rows of 10 narrower keys over the click column and the keys; the trackpad stays. It stays open until … is
/// tapped again, as in 16:9.
enum SixteenTenKeysLayout {
    typealias Cell = MacKeyboardLayout.Cell
    static let rowCount = 3
    /// The 6 key columns of the normal state.
    static let normal: [[String]] = [
        ["copy", "paste", "cut", "undo", "redo", "selectall"],
        ["escape", "tab", "left", "up", "down", "right"],
        ["control", "option", "command", "shift", "forwarddelete", "fblock"],
    ]
    /// "More": 3 rows of 10 over the whole keys area.
    static let moreColumns = 10
    /// Between the "more" keys, across (narrower keys, narrower gaps).
    static let moreGap: CGFloat = 4
    static let more: [[String]] = [
        ["F1", "F2", "F3", "F4", "F5", "F6", "save", "find", "switchapp", "spotlight"],
        ["F7", "F8", "F9", "F10", "F11", "F12", "close", "quit", "escape", "tab"],
        ["control", "option", "command", "shift", "home", "pageup", "pagedown", "end", "forwarddelete", "fblock"],
    ]

    static func rows(functionKeys: Bool) -> [[Cell]] {
        (functionKeys ? more : normal).map { $0.map(SpecialKeysLayout.anyCell) }
    }

    /// A "more" key's width in a keys area `width` points wide.
    static func moreKeyWidth(in width: CGFloat) -> CGFloat {
        let n = CGFloat(moreColumns)
        return ((width - (n - 1) * moreGap) / n * 10).rounded(.down) / 10
    }
}

/// The three buttons at the band's outer edge, under the thumb, top to bottom: Left click 2 rows tall, Right click 1
/// row, Scroll 1 row; all 2 keys wide.
enum ClickButtonsLayout {
    static let columns = 2
    /// Rows each button spans, top to bottom.
    static let leftRows = 2
    static let rightRows = 1
    static let scrollRows = 1
    /// The buttons top to bottom, with the rows each spans: Right click, Scroll, then the big Left click at the bottom,
    /// as the horizontal view's column.
    static let stack: [(button: BandButton, rows: Int)] = [(.right, rightRows), (.scroll, scrollRows),
                                                           (.left, leftRows)]

    /// The 16:10 band's key-sized row (on top since build 29, the two-row Left click under it), left to right: Scroll
    /// at the screen's outer edge, Right click inside it. Trackpad Right puts the column at the far left, so Scroll is
    /// leftmost; Trackpad Left puts it at the far right, so Scroll is rightmost.
    static func sixteenTenThirdRow(side: TrackpadSide) -> [BandButton] {
        side == .right ? [.scroll, .right] : [.right, .scroll]
    }
}

/// One of the band's three buttons.
enum BandButton: CaseIterable {
    case left, right, scroll
}

/// Which side of the upright band the trackpad is on. Right is today's layout: buttons at the far left, the keys, then
/// the trackpad. Left: the trackpad, the keys in exactly the same order, then the buttons at the far right. Remembered
/// across launches in the app's defaults.
enum TrackpadSide: String, CaseIterable, Identifiable {
    case left, right

    static let storageKey = "trackpadSide"
    static let standard = TrackpadSide.right
    var id: String { rawValue }
    var title: String { self == .left ? "Left" : "Right" }

    /// The stored choice, or Right when none (or an unknown value) is stored.
    static func stored(in defaults: UserDefaults = .standard) -> TrackpadSide {
        defaults.string(forKey: storageKey).flatMap(TrackpadSide.init(rawValue:)) ?? standard
    }

    func store(in defaults: UserDefaults = .standard) { defaults.set(rawValue, forKey: Self.storageKey) }
}

extension MacKey {
    /// The same key at another width.
    func widened(_ w: Double) -> MacKey {
        MacKey(label, code, id: id, flags: ownFlags, role: role, repeats: repeats, width: w)
    }

    /// The same key with another label (the Mac's own glyph on the upright band).
    func relabeled(_ l: String) -> MacKey {
        MacKey(l, code, id: id, flags: ownFlags, role: role, repeats: repeats, width: width)
    }
}

/// A one-press Mac shortcut.
struct MacShortcut: Identifiable, Equatable {
    let id: String
    /// The name: the accessibility label, and the key's face when `symbol` is nil.
    let title: String
    /// The key's face; nil where a symbol would be ambiguous, and the key shows `face` instead.
    let symbol: String?
    /// The short word shown when there is no symbol.
    var face: String { title == "Select All" ? "All" : title }
    let code: UInt16
    let modifiers: KeyMap.Modifier
    var width: Double = 1
    /// The key's own event flags (an arrow carries fn and numeric pad, as `MacKey.ownFlags`).
    var keyFlags: UInt32 = 0

    static let copy = MacShortcut(id: "copy", title: "Copy", symbol: "doc.on.doc", code: 8, modifiers: .command)
    /// Paste is drawn as the system paste control: it sends the phone's clipboard to the Mac, then ⌘V.
    static let paste = MacShortcut(id: "paste", title: "Paste", symbol: "clipboard", code: 9,
                                   modifiers: .command)
    static let cut = MacShortcut(id: "cut", title: "Cut", symbol: "scissors", code: 7, modifiers: .command)
    static let undo = MacShortcut(id: "undo", title: "Undo", symbol: "arrow.uturn.backward", code: 6,
                                  modifiers: .command)
    static let redo = MacShortcut(id: "redo", title: "Redo", symbol: "arrow.uturn.forward", code: 6,
                                  modifiers: [.shift, .command])
    static let selectAll = MacShortcut(id: "selectall", title: "Select All", symbol: nil, code: 0,
                                       modifiers: .command)
    static let save = MacShortcut(id: "save", title: "Save", symbol: "square.and.arrow.down", code: 1,
                                  modifiers: .command)
    static let find = MacShortcut(id: "find", title: "Find", symbol: nil, code: 3,
                                  modifiers: .command)
    static let switchApp = MacShortcut(id: "switchapp", title: "Apps", symbol: nil, code: 48,
                                       modifiers: .command)
    static let spotlight = MacShortcut(id: "spotlight", title: "Spotlight", symbol: "magnifyingglass", code: 49,
                                       modifiers: .command)
    static let closeWindow = MacShortcut(id: "close", title: "Close", symbol: "xmark", code: 13,
                                         modifiers: .command)
    static let quit = MacShortcut(id: "quit", title: "Quit", symbol: "power", code: 12, modifiers: .command)

    /// Touch's three-finger swipes (`DirectTouchEngine.shortcut(for:)`): the Mac's default Mission Control
    /// shortcuts. Not keys on the band.
    static let missionControl = MacShortcut(id: "missioncontrol", title: "Mission Control", symbol: nil, code: 126,
                                            modifiers: .control, keyFlags: MacKeyFlags.arrow)
    static let appExpose = MacShortcut(id: "appexpose", title: "App Exposé", symbol: nil, code: 125,
                                       modifiers: .control, keyFlags: MacKeyFlags.arrow)
    static let spaceRight = MacShortcut(id: "spaceright", title: "Space to the right", symbol: nil, code: 124,
                                        modifiers: .control, keyFlags: MacKeyFlags.arrow)
    static let spaceLeft = MacShortcut(id: "spaceleft", title: "Space to the left", symbol: nil, code: 123,
                                       modifiers: .control, keyFlags: MacKeyFlags.arrow)

    static let all: [MacShortcut] = [copy, paste, cut, undo, redo, selectAll, save, find, switchApp, spotlight,
                                     closeWindow, quit]
}

/// Who the keys are for. A Remote Desktop PC reads ⌃ ⌥ ⌘ as Ctrl, Alt and ⊞ (`RDPKeys.modifiers`), so the band's
/// shortcut keys send Windows' own shortcuts there, not the Mac's; a Mac's session is unchanged.
enum KeyTarget: Equatable { case mac, windows }

/// The two forms Ctrl Alt Del can take over Remote Desktop (plan §2: "Milestone 4 proves which of the two ways
/// Windows accepts"). `ctrlAltDelete`: Ctrl, Alt and Delete as scan codes, what Windows' own client sends to the PC
/// for the secure attention sequence. `ctrlAltEnd`: Ctrl, Alt and End, the keys Windows' client asks a person to
/// press for it. The tap sends the remembered form; touch and hold the key picks the other, which is remembered.
enum CtrlAltDelForm: String, CaseIterable {
    case ctrlAltDelete, ctrlAltEnd

    static let defaultsKey = "rdpCtrlAltDelForm"
    static var remembered: CtrlAltDelForm {
        get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .ctrlAltDelete }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
    }
    var title: String { self == .ctrlAltDelete ? "Send Ctrl Alt Delete" : "Send Ctrl Alt End" }
    /// The third key, as a Mac key code: ⌦ (117, the PC's Delete, E0 53) or End (119, E0 4F).
    var keyCode: UInt16 { self == .ctrlAltDelete ? 117 : 119 }
}

extension MacShortcut {
    /// The Windows shortcut in each band key's place, written with the Mac modifiers `RDPInput` turns into PC keys
    /// (⌃ = Ctrl, ⌥ = Alt, ⌘ = ⊞) and US Mac key codes. Same ids and places. Apps is the app switcher held with Alt
    /// (`MacKeyboardEngine.switcherModifier`); the power key's place is Ctrl Alt Del (`ctrlAltDelID`), an action.
    static let windowsCopy = MacShortcut(id: "copy", title: "Copy", symbol: "doc.on.doc", code: 8, modifiers: .control)
    static let windowsPaste = MacShortcut(id: "paste", title: "Paste", symbol: "clipboard", code: 9,
                                          modifiers: .control)
    static let windowsCut = MacShortcut(id: "cut", title: "Cut", symbol: "scissors", code: 7, modifiers: .control)
    static let windowsUndo = MacShortcut(id: "undo", title: "Undo", symbol: "arrow.uturn.backward", code: 6,
                                         modifiers: .control)
    /// Redo is Ctrl+Y on Windows (Y = Mac key 16).
    static let windowsRedo = MacShortcut(id: "redo", title: "Redo", symbol: "arrow.uturn.forward", code: 16,
                                         modifiers: .control)
    static let windowsSelectAll = MacShortcut(id: "selectall", title: "Select All", symbol: nil, code: 0,
                                              modifiers: .control)
    static let windowsSave = MacShortcut(id: "save", title: "Save", symbol: "square.and.arrow.down", code: 1,
                                         modifiers: .control)
    static let windowsFind = MacShortcut(id: "find", title: "Find", symbol: nil, code: 3, modifiers: .control)
    /// Search: ⊞+S.
    static let windowsSearch = MacShortcut(id: "spotlight", title: "Search", symbol: "magnifyingglass", code: 1,
                                           modifiers: .command)
    /// Close: Alt+F4 (F4 = Mac key 118).
    static let windowsClose = MacShortcut(id: "close", title: "Close", symbol: "xmark", code: 118,
                                          modifiers: .option, keyFlags: MacKeyFlags.function)
    /// Task View on the PC's "…" page: ⊞+Tab.
    static let windowsTaskView = MacShortcut(id: "taskview", title: "Task View", symbol: "rectangle.split.3x1",
                                             code: 48, modifiers: .command)
    /// The id of the power key's place, which is Ctrl Alt Del on a PC.
    static let ctrlAltDelID = "quit"

    static let windowsByID: [String: MacShortcut] = Dictionary(uniqueKeysWithValues: [
        windowsCopy, windowsPaste, windowsCut, windowsUndo, windowsRedo, windowsSelectAll, windowsSave, windowsFind,
        windowsSearch, windowsClose, windowsTaskView,
    ].map { ($0.id, $0) })

    /// This key's shortcut for `target`: itself on a Mac, the Windows one in its place on a PC.
    func `for`(_ target: KeyTarget) -> MacShortcut {
        target == .windows ? Self.windowsByID[id] ?? self : self
    }
}

/// The keyboard's behaviour, apart from any view: latching modifiers, held keys, repeat, and the INPUT
/// messages they make. Main thread.
final class MacKeyboardEngine {
    /// No double-tap lock: a modifier is off or held once.
    enum Latch: Equatable { case off, once }

    /// Hold a repeating key this long before it repeats, then repeat this often (key downs only, as macOS).
    static let repeatDelay: TimeInterval = 0.5
    static let repeatInterval: TimeInterval = 0.05

    let sink: any InputSink
    private(set) var latches: [KeyMap.Modifier: Latch] = [:]
    /// The Apps key has opened the Mac's app switcher: Command is down on the Mac until it is picked or let go.
    private(set) var switcherOpen = false
    /// Keys down now (key id → code and the flags sent with its down).
    private(set) var held: [String: (code: UInt16, flags: UInt32)] = [:]
    /// Modifier keys pressed for latches during the current key or click.
    private var modifiersDown: [KeyMap.Modifier] = []
    var onChange: (() -> Void)?
    /// Typing a character no US key types (é, emoji): set only where the far end takes text (a Remote Desktop PC).
    var typeText: ((Character) -> Void)?
    /// A Mac, or a Remote Desktop PC (Windows shortcuts on the band keys). Set by the PC's screen.
    var target: KeyTarget = .mac
    /// The modifier the Apps key holds down for the app switcher: ⌘ (⌘Tab) on a Mac, ⌥ (Alt+Tab) on a PC.
    var switcherModifier: KeyMap.Modifier { target == .windows ? .option : .command }

    init(sink: any InputSink) { self.sink = sink }

    func latch(of m: KeyMap.Modifier) -> Latch { latches[m] ?? .off }

    var activeModifiers: KeyMap.Modifier {
        var m: KeyMap.Modifier = []
        for (mod, latch) in latches where latch != .off { m.insert(mod) }
        return m
    }

    /// Tap a modifier, the same rule for Control, Option, Command and Shift: off → once (held for the next key
    /// or click; any number can be held together, and they all let go after that key or click); once, tapped
    /// again → off, however quickly. While the app switcher is open, a tap on Command lets Command go (picks).
    func tapModifier(_ m: KeyMap.Modifier) {
        if switcherOpen, m == switcherModifier {
            closeAppSwitcher()
            return
        }
        latches[m] = latch(of: m) == .off ? .once : .off
        onChange?()
    }

    /// Flags that are down on the Mac apart from the latches: Command while the app switcher is open.
    private var baseFlags: UInt32 { switcherOpen ? switcherModifier.eventFlags : 0 }

    /// The Apps key. Closed: Command down, Tab down and up, Command kept down, so the Mac's app switcher stays on
    /// screen. Open: Command up, which switches to the highlighted app. One-shot latches are used up on opening.
    func tapAppSwitcher() {
        if switcherOpen { closeAppSwitcher(); return }
        guard held.isEmpty, modifiersDown.isEmpty, let cmd = switcherModifier.keyCode else { return }
        let flags = switcherModifier.eventFlags
        send(InputKind.keyDown, code: cmd, flags: flags)
        send(InputKind.keyDown, code: MacKeyboardLayout.tab.code, flags: flags)
        send(InputKind.keyUp, code: MacKeyboardLayout.tab.code, flags: flags)
        switcherOpen = true
        latches.removeAll()
        onChange?()
    }

    /// Lets Command go: the Mac switches to the highlighted app (or, after Escape, has already cancelled).
    func closeAppSwitcher() {
        guard switcherOpen, let cmd = switcherModifier.keyCode else { return }
        switcherOpen = false
        send(InputKind.keyUp, code: cmd, flags: 0)
        onChange?()
    }

    /// Presses the latched modifiers' own keys (so Mac apps that watch modifier keys see them), in a physical
    /// keyboard's order. Returns their flags. Command, already down for the open switcher, is not pressed again.
    private func pressLatchedModifiers() -> UInt32 {
        let mods = activeModifiers
        var flags: UInt32 = baseFlags
        for m in KeyMap.Modifier.order where mods.contains(m) {
            if switcherOpen, m == switcherModifier { continue }
            guard let code = m.keyCode else { continue }
            flags |= m.eventFlags
            send(InputKind.keyDown, code: code, flags: flags)
            modifiersDown.append(m)
        }
        return flags
    }

    /// Lifts the modifier keys pressed for this key or click, and clears the one-shot latches.
    private func releaseLatchedModifiers() {
        var flags: UInt32 = baseFlags
        for m in modifiersDown { flags |= m.eventFlags }
        for m in modifiersDown.reversed() {
            flags &= ~m.eventFlags
            if let code = m.keyCode { send(InputKind.keyUp, code: code, flags: flags) }
        }
        modifiersDown.removeAll()
        var changed = false
        for (m, l) in latches where l == .once {
            latches[m] = .off
            changed = true
        }
        if changed { onChange?() }
    }

    func keyDown(_ key: MacKey) {
        guard case .key = key.role, held[key.id] == nil else { return }
        // Return while the switcher is open picks the highlighted app: Command up, no Return sent.
        if switcherOpen, held.isEmpty, key.id == MacKeyboardLayout.returnKey.id {
            closeAppSwitcher()
            return
        }
        let modifierFlags = held.isEmpty ? pressLatchedModifiers() : activeModifiers.eventFlags | baseFlags
        let flags = modifierFlags | key.ownFlags
        held[key.id] = (key.code, flags)
        send(InputKind.keyDown, code: key.code, flags: flags)
    }

    /// One repeat of a held key: another key down, as macOS's own repeat.
    func keyRepeat(_ key: MacKey) {
        guard key.repeats, let h = held[key.id] else { return }
        send(InputKind.keyDown, code: h.code, flags: h.flags)
    }

    func keyUp(_ key: MacKey) {
        guard let h = held.removeValue(forKey: key.id) else { return }
        send(InputKind.keyUp, code: h.code, flags: h.flags)
        if held.isEmpty { releaseLatchedModifiers() }
        // Escape cancels the switcher on the Mac; then Command goes up.
        if key.id == MacKeyboardLayout.escape.id, held.isEmpty { closeAppSwitcher() }
    }

    /// One press of a whole shortcut: its modifiers down in keyboard order, the key down and up, the modifiers up.
    /// Latched modifiers are added (⌥ latched + Copy sends ⌥⌘C) and a one-shot latch is used up, as a key is.
    /// The Apps key opens and picks in the app switcher instead (`tapAppSwitcher`). While the switcher is open the
    /// other shortcut keys send nothing: Quit (⌘Q) would quit the highlighted app, and it sits two keys from Apps.
    /// On a PC the key's Windows shortcut goes instead (`MacShortcut.for`): copy is Ctrl+C there, not ⊞C.
    func sendShortcut(_ shortcut: MacShortcut) {
        if shortcut.id == MacShortcut.switchApp.id { tapAppSwitcher(); return }
        guard held.isEmpty, !switcherOpen else { return }
        let s = shortcut.for(target)
        let all = s.modifiers.union(activeModifiers)
        var flags: UInt32 = 0
        var pressed: [KeyMap.Modifier] = []
        for m in KeyMap.Modifier.order where all.contains(m) {
            guard let code = m.keyCode else { continue }
            flags |= m.eventFlags
            send(InputKind.keyDown, code: code, flags: flags)
            pressed.append(m)
        }
        send(InputKind.keyDown, code: s.code, flags: flags | s.keyFlags)
        send(InputKind.keyUp, code: s.code, flags: flags | s.keyFlags)
        for m in pressed.reversed() {
            flags &= ~m.eventFlags
            if let code = m.keyCode { send(InputKind.keyUp, code: code, flags: flags) }
        }
        var changed = false
        for (m, l) in latches where l == .once {
            latches[m] = .off
            changed = true
        }
        if changed { onChange?() }
    }

    /// Ctrl Alt Del on a PC, as one action: Ctrl down, Alt down, Delete (or End, `form`) down and up, Alt up, Ctrl
    /// up. Latches are not added (a held ⊞ would change it); one-shot latches are used up, as a shortcut's are.
    func sendCtrlAltDel(_ form: CtrlAltDelForm) {
        guard target == .windows, held.isEmpty, !switcherOpen,
              let ctrl = KeyMap.Modifier.control.keyCode, let alt = KeyMap.Modifier.option.keyCode else { return }
        let c = KeyMap.Modifier.control.eventFlags, a = KeyMap.Modifier.option.eventFlags
        send(InputKind.keyDown, code: ctrl, flags: c)
        send(InputKind.keyDown, code: alt, flags: c | a)
        send(InputKind.keyDown, code: form.keyCode, flags: c | a | MacKeyFlags.function)
        send(InputKind.keyUp, code: form.keyCode, flags: c | a | MacKeyFlags.function)
        send(InputKind.keyUp, code: alt, flags: c)
        send(InputKind.keyUp, code: ctrl, flags: 0)
        if latches.values.contains(.once) {
            for (m, l) in latches where l == .once { latches[m] = .off }
            onChange?()
        }
    }

    /// A trackpad click with the latched modifiers held around it (Command-click, Control-click). While the app
    /// switcher is open, the click (on an app's icon) picks: the click is sent, then Command goes up.
    func withModifiers(_ body: () -> Void) {
        let alreadyDown = !modifiersDown.isEmpty
        if !alreadyDown { _ = pressLatchedModifiers() }
        body()
        if !alreadyDown {
            releaseLatchedModifiers()
            closeAppSwitcher()
        }
    }

    /// Lifts everything: the view is going away, the app is leaving the foreground, or the session ended.
    func releaseAll() {
        for (_, h) in held { send(InputKind.keyUp, code: h.code, flags: 0) }
        held.removeAll()
        releaseLatchedModifiers()
        closeAppSwitcher()
        if latches.values.contains(where: { $0 != .off }) {
            latches.removeAll()
            onChange?()
        }
    }

    /// How many repeats a key held for `duration` seconds has sent.
    static func repeatCount(heldFor duration: TimeInterval) -> Int {
        guard duration >= repeatDelay else { return 0 }
        return Int(((duration - repeatDelay) / repeatInterval).rounded(.down)) + 1
    }

    private func send(_ kind: UInt8, code: UInt16, flags: UInt32) {
        sink.sendInput(kind: kind, x: Int(code), y: 0, a: Int(Int32(bitPattern: flags)), b: 0)
    }
}
