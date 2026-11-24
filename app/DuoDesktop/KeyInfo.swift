import SwiftUI
import UIKit

/// What each extra key does on the Mac. One plain line per key, used three ways: the info bubble's list, each key's
/// spoken (VoiceOver) hint, and the tests. The list is built from the same rows that draw the keys
/// (`SpecialKeysLayout.rows`, `MacKeysBar.keys`), so it cannot drift from the screen.
enum KeyInfo {
    /// One line of the bubble.
    struct Entry: Identifiable {
        let cell: MacKeyboardLayout.Cell
        let name: String
        let description: String
        var id: String { cell.id }
    }

    struct Section: Identifiable {
        let title: String
        let entries: [Entry]
        var id: String { title }
    }

    /// The key's name: the shortcut's title, or the spoken name of a key.
    static func name(_ cell: MacKeyboardLayout.Cell) -> String {
        switch cell {
        case let .key(k): KeyCap.accessibilityName(k, more: false)
        case let .shortcut(s): s.title
        case .gap: ""
        }
    }

    /// One plain line on what the key does on the Mac. `more`: the "more" block is showing (only the "more" key
    /// itself reads differently then).
    static func description(_ cell: MacKeyboardLayout.Cell, more: Bool = false) -> String {
        switch cell {
        case .gap: return ""
        case let .shortcut(s): return shortcutDescription(s) + " (" + keysSpoken(s) + ")"
        case let .key(k): return keyDescription(k, more: more)
        }
    }

    /// "Command-C", "Shift-Command-Z", "Command-Space".
    static func keysSpoken(_ s: MacShortcut) -> String {
        var t = ""
        if s.modifiers.contains(.shift) { t += "Shift-" }
        if s.modifiers.contains(.option) { t += "Option-" }
        if s.modifiers.contains(.control) { t += "Control-" }
        if s.modifiers.contains(.command) { t += "Command-" }
        let key: String = switch s.code {
        case 49: "Space"
        case 48: "Tab"
        default: MacTyping.keys.first { $0.value.code == s.code && $0.value.ownFlags == 0 && $0.key.isLetter }
            .map { $0.key.uppercased() } ?? "?"
        }
        return t + key
    }

    private static func shortcutDescription(_ s: MacShortcut) -> String {
        switch s.id {
        case "copy": "copies the selection"
        case "paste": "sends this phone's clipboard to the Mac and pastes it"
        case "cut": "cuts the selection"
        case "undo": "undoes the last change"
        case "redo": "redoes what you undid"
        case "selectall": "selects everything"
        case "save": "saves the document"
        case "find": "finds text in the window"
        case "switchapp": "keeps the app switcher open: pick with the arrows or a tap, then Apps or Return; esc cancels"
        case "spotlight": "opens Spotlight search"
        case "close": "closes the window"
        case "quit": "quits the app"
        default: ""
        }
    }

    private static func keyDescription(_ k: MacKey, more: Bool) -> String {
        if k.id.hasPrefix("F"), let n = Int(k.id.dropFirst()) {
            return "the Mac's F\(n) key; what it does depends on the app"
        }
        switch k.id {
        case "escape": return "cancels or closes what is open"
        case "tab": return "moves to the next field"
        case "forwarddelete": return "deletes the character to the right"
        case "fblock":
            return more
                ? "puts back the shortcuts and the arrows"
                : "swaps the shortcuts for F1 to F12 and the arrows for home, page up, page down and end"
        // The modifiers' spoken hint is the pop-up's wording, nothing about combining.
        case "control", "option", "command", "shift": return KeyCap.accessibilityName(k, more: false)
        case "left": return "moves left one character"
        case "right": return "moves right one character"
        case "up": return "moves up one line"
        case "down": return "moves down one line"
        case "home": return "goes to the top of the document"
        case "end": return "goes to the end of the document"
        case "pageup": return "scrolls up one screen"
        case "pagedown": return "scrolls down one screen"
        default: return ""
        }
    }

    /// The four modifier keys share one rule and one sentence: a tap holds it for the next key or click, any of them
    /// can be held together, a second tap lets it go, and after that key or click they all let go.
    /// `MacKeyboardEngine.tapModifier` is that rule, the same for all four.
    static let modifierIDs: Set<String> = ["control", "option", "command", "shift"]

    private static func entries(_ cells: [MacKeyboardLayout.Cell]) -> [Entry] {
        cells.compactMap { cell in
            if case .gap = cell { return nil }
            return Entry(cell: cell, name: name(cell), description: description(cell))
        }
    }

    /// The upright band: every key in on-screen order (row by row, left to right), then the keys the "more" key
    /// puts in their place, in their on-screen order.
    static func uprightSections() -> [Section] {
        let off = Array(SpecialKeysLayout.rows(functionKeys: false).joined())
        let on = Array(SpecialKeysLayout.rows(functionKeys: true).joined())
        let swapped = zip(off, on).filter { $0.id != $1.id }.map(\.1)
        return [Section(title: "Keys", entries: entries(off)),
                Section(title: "After More", entries: entries(swapped))]
    }

    /// The pop-up's few words for a key: what the key IS or does on the Mac, nothing about how keys behave or combine.
    /// A key whose face is a word gets only the explanation after it; a key whose face is a symbol gets its name too.
    /// VoiceOver keeps the fuller line from `description`.
    static func short(_ cell: MacKeyboardLayout.Cell) -> String {
        switch cell {
        case .gap: return ""
        case let .shortcut(s):
            let k = "(" + keysGlyphs(s) + ")"
            switch s.id {
            case "copy": return "Copy " + k
            case "paste": return "Paste this phone's clipboard " + k
            case "cut": return "Cut " + k
            case "undo": return "Undo " + k
            case "redo": return "Redo " + k
            case "selectall": return "select everything " + k
            case "save": return "Save " + k
            case "find": return "search in this window " + k
            case "switchapp": return "app switcher: stays open " + k
            case "spotlight": return "Spotlight: search the Mac " + k
            case "close": return "Close this window " + k
            case "quit": return "Quit the app in front " + k
            default: return s.title + " " + k
            }
        case let .key(k):
            if k.id.hasPrefix("F"), Int(k.id.dropFirst()) != nil { return "the Mac's function keys" }
            switch k.id {
            case "escape": return "Escape: cancel or close"
            case "tab": return "Tab: next field"
            case "forwarddelete": return "delete to the right"
            case "fblock": return "show F keys and home/end/page"
            case "control", "option", "command", "shift": return KeyCap.accessibilityName(k, more: false)
            case "left", "right", "up", "down": return "move the cursor"
            case "home": return "Home: top"
            case "end": return "End: bottom"
            case "pageup": return "Page up"
            case "pagedown": return "Page down"
            default: return KeyCap.accessibilityName(k, more: false)
            }
        }
    }

    /// "⌘C", "⇧⌘Z", "⌘Space": the Mac's own way of writing a shortcut.
    static func keysGlyphs(_ s: MacShortcut) -> String {
        var t = ""
        if s.modifiers.contains(.control) { t += "⌃" }
        if s.modifiers.contains(.option) { t += "⌥" }
        if s.modifiers.contains(.shift) { t += "⇧" }
        if s.modifiers.contains(.command) { t += "⌘" }
        let spoken = keysSpoken(s)
        return t + (spoken.split(separator: "-").last.map(String.init) ?? "")
    }

    /// One line of the pop-up: one key, or F1 to F12 together (12 keys of one kind, one line).
    struct Line: Identifiable {
        let face: KeyFaceContent
        let text: String
        /// The keys this line covers.
        let ids: [String]
        var id: String { ids.joined(separator: ",") }
    }

    static func face(_ cell: MacKeyboardLayout.Cell) -> KeyFaceContent? {
        switch cell {
        case let .key(k): KeyCap.face(k)
        case let .shortcut(s): ShortcutKey.face(s)
        case .gap: nil
        }
    }

    /// Keys of one kind shown on one line: F1 to F12, and the four plain arrows.
    private static func group(_ cell: MacKeyboardLayout.Cell) -> (face: String, text: String)? {
        guard case let .key(k) = cell else { return nil }
        if k.id.hasPrefix("F"), Int(k.id.dropFirst()) != nil { return ("F1–F12", short(cell)) }
        if ["left", "up", "down", "right"].contains(k.id) { return ("←↑↓→", short(cell)) }
        return nil
    }

    /// Where the keys behind "more" start in `lines(sections)`, or nil when there are none.
    static func moreStart(_ sections: [Section], clicks: Bool = false) -> Int? {
        guard sections.count > 1 else { return nil }
        return lines(Array(sections.prefix(1)), clicks: clicks).count
    }

    /// The three buttons' lines, first, as they are the band's first cells. project notes: the feature in one plain
    /// line.
    static var autoUnlockLine: Line { Line(face: .symbol("lock.open"),
                                     text: UnlockMethod.current.keyInfoAutoUnlock,
                                     ids: ["auto-unlock"]) }

    static let clickLines: [Line] = [
        Line(face: .symbol("cursorarrow.click"), text: "Left click (hold it to drag)", ids: ["click-left"]),
        Line(face: .symbol("contextualmenu.and.cursorarrow"), text: "Right click", ids: ["click-right"]),
        Line(face: .symbol("arrow.up.and.down"),
             text: "Scroll (hold it and move one finger on the trackpad)", ids: ["click-scroll"]),
    ]

    /// The pop-up's lines: every section's keys in order; F1-F12 and the arrows each folded into one line, where
    /// the first of them is.
    static func lines(_ sections: [Section], clicks: Bool = false) -> [Line] {
        var out: [Line] = clicks ? clickLines : []
        var groupAt: [String: Int] = [:]
        for entry in sections.flatMap(\.entries) {
            if let g = group(entry.cell) {
                if let i = groupAt[g.face] {
                    out[i] = Line(face: out[i].face, text: out[i].text, ids: out[i].ids + [entry.id])
                } else {
                    groupAt[g.face] = out.count
                    out.append(Line(face: .text(g.face), text: g.text, ids: [entry.id]))
                }
                continue
            }
            guard let f = face(entry.cell) else { continue }
            out.append(Line(face: f, text: short(entry.cell), ids: [entry.id]))
        }
        return out
    }

    /// The horizontal layout: only its row's keys, in order.
    static var horizontalSections: [Section] {
        [Section(title: "Keys", entries: entries(MacKeysBar.keys.map { .key($0) }))]
    }
}

/// The key reference, from one plain row on the Mac list: the click buttons and every key of the upright band. It sends
/// nothing to any Mac. HIG Lists and tables: a row that opens more information; HIG Sheets: a reference read for a
/// moment opens as a sheet with a Done button, like About. It was the info button in every session's top row and a
/// keyboard button in the Mac list's toolbar.
struct KeyboardShortcutsRow: View {
    @State private var showing = false

    var body: some View {
        Button {
            showing = true
        } label: {
            Label("Keyboard Shortcuts", systemImage: "keyboard")
                .foregroundStyle(.primary)
        }
        .accessibilityIdentifier("keyboardShortcuts")
        .accessibilityHint("Explains the click buttons and each extra key")
        .sheet(isPresented: $showing) { KeyInfoSheet() }
        #if targetEnvironment(simulator)
        .onAppear {
            guard SimulatorSwitches.showKeyInfo else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { showing = true }
        }
        #endif
    }
}

/// The key reference sheet: the shortcut keys and nothing else. Two columns: each line is the key as the band draws it
/// (`KeyFace`, small) with its few words beside it; the groups flow down the left column, then the right, in the band's
/// order. HIG Layout: adapt to the width and to Dynamic Type, so at the accessibility text sizes it falls back to one
/// column; the sheet scrolls when it is taller than the screen. The same sheet opens from the Mac list and from a
/// session.
struct KeyInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    /// The small key grows with the text size.
    @ScaledMetric(relativeTo: .subheadline) private var keyWidth: CGFloat = 46
    @ScaledMetric(relativeTo: .subheadline) private var keyHeight: CGFloat = 30

    struct Group: Identifiable {
        let title: String
        let lines: [KeyInfo.Line]
        var id: String { title }
    }

    /// The sheet's sections: the two click buttons, the keys, then the keys behind "more".
    static func groups() -> [Group] {
        let sections = KeyInfo.uprightSections()
        let keys = KeyInfo.lines(sections, clicks: false)
        let more = KeyInfo.moreStart(sections, clicks: false) ?? keys.count
        return [Group(title: "Buttons", lines: KeyInfo.clickLines),
                Group(title: "Keys", lines: Array(keys.prefix(more))),
                Group(title: "After More (⋯)", lines: Array(keys.dropFirst(more))),
                // Project notes: the info sheet's one plain line about the feature.
                Group(title: "Locked Mac", lines: [KeyInfo.autoUnlockLine])]
            .filter { !$0.lines.isEmpty }
    }

    /// One item of a column: a group's title or one of its lines.
    enum Item: Identifiable {
        case title(String)
        case line(KeyInfo.Line)
        var id: String {
            switch self {
            case let .title(t): "title-" + t
            case let .line(l): l.id
            }
        }
    }

    /// The items in order, split into `count` columns of about the same number of items: the left column first,
    /// then the right. A title never ends a column (it moves to the top of the next one).
    static func columns(_ count: Int) -> [[Item]] {
        let items = groups().flatMap { g in [Item.title(g.title)] + g.lines.map(Item.line) }
        guard count > 1 else { return [items] }
        var cut = (items.count + 1) / 2
        if cut > 0, case .title = items[cut - 1] { cut -= 1 }
        return [Array(items.prefix(cut)), Array(items.dropFirst(cut))]
    }

    var body: some View {
        let columns = Self.columns(typeSize.isAccessibilitySize ? 1 : 2)
        NavigationStack {
            ScrollView {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(columns.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(columns[i]) { item in row(item) }
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 16)
            }
            // The band's panel colour, so the small keys look as they do on the band (white keys on light grey).
            .background(KeyLook.panel)
            .navigationTitle("Keys")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder private func row(_ item: Item) -> some View {
        switch item {
        case let .title(t):
            Text(t)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 8)
                .accessibilityAddTraits(.isHeader)
        case let .line(line):
            HStack(spacing: 10) {
                KeyFace(content: line.face)
                    .frame(width: keyWidth, height: keyHeight)
                    .accessibilityHidden(true)
                Text(line.text)
                    .font(.subheadline)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder static func glyph(_ face: KeyFaceContent) -> some View {
        switch face {
        case let .text(t): Text(t).font(.body.weight(.semibold))
        case let .symbol(name): Image(systemName: name).font(.title3)
        }
    }
}
