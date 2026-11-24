import Foundation
import Network
import SwiftUI

// One list of computers. Milestone 3 as changed by project notes (name-opens-default): one line per computer, a light,
// the name (tap: its Opens In way), the same three way-in icons on every row (Screen Sharing, Terminal, JetKVM), then
// the (i) (its settings). An icon the computer has opens it exactly that way; a gray one adds that way in. In every
// build: the checks need neither the Terminal nor the JetKVM code.

// MARK: - Reach: does each way in answer? A plain TCP connect, every time the list appears

/// The Terminal and JetKVM icons' "answering" state, per computer and way in. "Reachable" only, never "signed in"
/// (review finding 3): the check opens a TCP connection to the SSH port or the JetKVM's web port and closes it. No SSH,
/// no password read, no JetKVM viewer (that would take over whoever is watching it). Screen Sharing's own check is
/// Glass Act's sign-in query (`MacList`).
@MainActor @Observable
final class ComputerReach {
    enum State: Equatable {
        case checking, ready, notReachable
        var reachable: Bool { self == .ready }
    }

    static let shared = ComputerReach()
    private(set) var states: [String: State] = [:]
    private var generation = 0
    /// Tests swap the connect.
    @ObservationIgnored var check: (String, UInt16, TimeInterval, @escaping @Sendable (Bool) -> Void) -> Void = TCPCheck.check

    private static func key(_ id: String, _ way: WayIn) -> String { "\(id).\(way.rawValue)" }
    func state(_ id: String, _ way: WayIn) -> State { states[Self.key(id, way)] ?? .checking }

    /// Where the check for one way in connects (Terminal: the SSH port; JetKVM: its web port). nil for Screen
    /// Sharing (Glass Act's own check) and for a way in with no address.
    nonisolated static func target(_ e: MacEntry, _ way: WayIn) -> (host: String, port: UInt16)? {
        switch way {
        case .terminal:
            guard let host = e.address(.tailscale) ?? e.address(.home) else { return nil }
            return (host, e.sshPortValue)
        case .jetkvm:
            guard let host = e.jetkvmHost else { return nil }
            let https = e.jetkvmAddress?.lowercased().hasPrefix("https://") == true
            return (host, https ? 443 : 80)
        case .screenSharing:
            // A PC's Remote Desktop: a TCP connect to its port (3389), no sign-in.
            guard e.hasRemoteDesktop, let host = e.address(.tailscale) ?? e.address(.home) else { return nil }
            return (host, e.rdpPortValue)
        }
    }

    /// Checks every Terminal and JetKVM way in this build has, on every computer (with Screen Sharing or not).
    func probeAll(_ entries: [MacEntry]) {
        generation += 1
        let g = generation
        for e in entries {
            for way in e.waysInThisBuild where way != .screenSharing || e.hasRemoteDesktop {
                let k = Self.key(e.id, way)
                // The simulator checks these too, as build 59 did (the live Linux-server proof needs it).
                guard let t = Self.target(e, way) else { states[k] = .notReachable; continue }
                // Keep the last answer while rechecking (as the Mac rows do), so a tap right after a session works.
                if states[k] == nil { states[k] = .checking }
                check(t.host, t.port, 2) { [weak self] ok in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            guard let self, self.generation == g else { return }
                            self.states[k] = ok ? .ready : .notReachable
                        }
                    }
                }
            }
        }
    }
}

/// One TCP connect, answered once: true when the port took the connection within `timeout`.
enum TCPCheck {
    static func check(host: String, port: UInt16, timeout: TimeInterval, done: @escaping @Sendable (Bool) -> Void) {
        guard let p = NWEndpoint.Port(rawValue: port) else { done(false); return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        let once = Once(done)
        c.stateUpdateHandler = { st in
            switch st {
            case .ready: once.fire(true); c.cancel()
            case .failed, .waiting: once.fire(false); c.cancel()
            default: break
            }
        }
        let q = DispatchQueue(label: "tcp-check")
        c.start(queue: q)
        q.asyncAfter(deadline: .now() + timeout) { once.fire(false); c.cancel() }
    }

    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var f: (@Sendable (Bool) -> Void)?
        init(_ f: @escaping @Sendable (Bool) -> Void) { self.f = f }
        func fire(_ v: Bool) { lock.withLock { () -> (@Sendable (Bool) -> Void)? in defer { f = nil }; return f }?(v) }
    }
}


// MARK: - A way in's icon and words

extension WayIn {
    /// The list's icon for this way in (HIG SF Symbols). Screen Sharing: a display (the Mac's own screen); Terminal:
    /// the terminal window, as in the session's view switch; JetKVM: the little box that plugs into HDMI, which is what
    /// a JetKVM is. The one definition: the session's view switch and drop-down use it too (`SessionView.systemImage`).
    var symbol: String {
        switch self {
        case .screenSharing: "display"
        case .terminal: "apple.terminal"
        case .jetkvm: "mediastick"
        }
    }

    /// VoiceOver for a list icon: "Open Guest Mac Mini in Terminal" / "Add Terminal to Guest Mac Mini".
    func openLabel(_ name: String) -> String { "Open \(name) in \(label)" }
    func addLabel(_ name: String) -> String { "Add \(label) to \(name)" }
    /// The waiting/failure screens' offer (PLAN: "Open in JetKVM instead").
    var insteadTitle: String { "Open in \(label) Instead" }
}

extension MacEntry {
    /// "Open in … Instead" as this computer has the way in: a PC's Screen Sharing slot is Remote Desktop.
    func insteadTitle(_ way: WayIn) -> String { "Open in \(label(way)) Instead" }
}

/// How one way-in icon looks on a computer's row:
/// - not set up: gray; tap adds it;
/// - set up: the app's colour; tap opens it that way;
/// - set up but not answering right now: the app's colour still (it is set up, and a tap still tries it), with a
///   small exclamation-mark badge on the icon. A shape, not only a colour (HIG Color: "Avoid relying solely on color
///   to differentiate between objects ... you can use text labels or glyph shapes"), and never gray, which means
///   "not set up". VoiceOver reads it as the icon's value ("Not answering").
/// While a check is running, or where it is not made (the simulator's Glass Act check), it shows as set up.
enum WayLook: Equatable {
    case notSetUp
    /// Set up on another iPhone (list sync), but its password is not on this one: gray, and a tap opens its Add sheet
    /// to type it here, as a gray icon does.
    case needsSetUpHere
    case setUp
    /// Set up, but its check did not answer; the words say why (VoiceOver).
    case notAnswering(String)

    static let notAnsweringWords = "Not answering"
    static let needsSetUpHereWords = "Needs setting up here"

    /// Gray icons: a tap opens that way in's Add sheet.
    var isGray: Bool { self == .notSetUp || self == .needsSetUpHere }

    /// The look of `way` on `entry`: Screen Sharing from the Glass Act check, Terminal and JetKVM from the TCP check.
    @MainActor static func of(_ entry: MacEntry, _ way: WayIn, mac: MacList.Reach?, reach: ComputerReach,
                              secrets: DeviceSecretKeeping = DeviceSecrets.shared) -> WayLook {
        guard entry.opens(way) else { return .notSetUp }
        if way == .jetkvm, entry.jetkvmPassword == true, !secrets.hasJetKVMPassword(entry.id) { return .needsSetUpHere }
        switch way {
        case .screenSharing where entry.hasRemoteDesktop:
            return reach.state(entry.id, way) == .notReachable ? .notAnswering(notAnsweringWords) : .setUp
        case .screenSharing:
            switch mac ?? .checking {
            case .notReachable: return .notAnswering(notAnsweringWords)
            case .wrongMac: return .notAnswering(MacList.Reach.wrongMac.label)
            default: return .setUp
            }
        case .terminal, .jetkvm:
            return reach.state(entry.id, way) == .notReachable ? .notAnswering(notAnsweringWords) : .setUp
        }
    }
}

// MARK: - The light at the start of a row

/// The light at the start of a computer's row. The look is the earlier rows' dot (builds 61-65: an 8 pt filled circle);
/// the checks are the ones the icons' badges already use, so it adds no network traffic. Per way in:
/// - Screen Sharing, Glass Act's sign-in query: this iPhone is let in = green; the Host answers but wants a sign-in
///   with the Mac's password, someone at the Mac to allow it, or takes no new viewers = yellow; no answer, or a
///   different Mac's key = red.
/// - Terminal and JetKVM, a TCP connect: the port takes it = green; it does not = red. A connect cannot tell whether
///   the key, the Tailscale sign-in or the JetKVM password will work, so these are never yellow.
/// The computer's light is the best of its ways in: green if any is green, else yellow if any is yellow, else gray
/// while any is still being checked (or is never checked, as the simulator's Glass Act check of other hosts), else
/// red. Gray is never red. Colour is not the only signal: each state has its own VoiceOver label.
enum ComputerLight: Equatable {
    /// Not checked yet (or not checked at all): neutral gray.
    case notChecked
    case reachable
    /// Answers, but the app cannot get in until the owner does something; the words say what.
    case needsSignIn(String)
    case notReachable

    var color: Color {
        switch self {
        case .notChecked: .gray
        case .reachable: .green
        case .needsSignIn: .yellow
        case .notReachable: .red
        }
    }

    /// VoiceOver's label for the light.
    var label: String {
        switch self {
        case .notChecked: "Not checked yet"
        case .reachable: "Reachable"
        case let .needsSignIn(why): "Reachable, \(why)"
        case .notReachable: "Not reachable"
        }
    }

    /// One way in's light from its check.
    static func of(screenSharing r: MacList.Reach?) -> ComputerLight {
        switch r ?? .checking {
        case .ready: .reachable
        case .signInNeeded: .needsSignIn("sign in needed")
        case .askOnMac: .needsSignIn("asks on the Mac")
        case .closed: .needsSignIn("not taking new viewers")
        case .notReachable, .wrongMac: .notReachable
        case .checking, .notChecked: .notChecked
        }
    }

    static func of(_ r: ComputerReach.State) -> ComputerLight {
        switch r {
        case .ready: .reachable
        case .notReachable: .notReachable
        case .checking: .notChecked
        }
    }

    /// The computer's light: the best of its ways in (see the type's comment).
    static func combined(_ ways: [ComputerLight]) -> ComputerLight {
        if ways.contains(.reachable) { return .reachable }
        if let y = ways.first(where: { if case .needsSignIn = $0 { true } else { false } }) { return y }
        if ways.contains(.notChecked) || ways.isEmpty { return .notChecked }
        return .notReachable
    }

    /// The light of `entry`'s row, from the same checks as its icons.
    @MainActor static func of(_ entry: MacEntry, mac: MacList.Reach?, reach: ComputerReach) -> ComputerLight {
        combined(entry.waysInThisBuild.map { way in
            way == .screenSharing && !entry.hasRemoteDesktop ? of(screenSharing: mac) : of(reach.state(entry.id, way))
        })
    }
}

/// The light itself: the earlier rows' dot (`circle.fill`, 8 pt), with its own VoiceOver label.
struct ComputerLightView: View {
    let light: ComputerLight
    let name: String

    var body: some View {
        Image(systemName: "circle.fill")
            .font(.system(size: 8))
            .foregroundStyle(light.color)
            .accessibilityLabel(light.label)
            .accessibilityIdentifier("light.\(name)")
    }
}

// MARK: - The row

/// One computer in the list, on one line: the light, the name (tap: the computer in its Opens In way), the way-in icons
/// in fixed columns, then the (i) (its settings). The (i) sits after the icons, at the row's trailing end, as Settings
/// › Wi-Fi puts it after a network's lock and signal icons.
struct ComputerListRow: View {
    let entry: MacEntry
    /// The icons, in the same columns on every row: the ways in this build has (all three in the full build).
    let columns: [WayIn]
    let look: (WayIn) -> WayLook
    let light: ComputerLight
    /// The name: open the computer in its Opens In way.
    let openDefault: () -> Void
    let settings: () -> Void
    let open: (WayIn) -> Void
    let add: (WayIn) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 44

    /// At the accessibility text sizes the row stacks: the light and name on their own line, the icons and the (i)
    /// under it (one line does not leave the name room once the icons have grown with the text).
    static func stacks(_ size: DynamicTypeSize) -> Bool { size.isAccessibilitySize }

    /// The way-in icons and the (i) sit in columns of one width (`side`: the HIG's 44 pt touch target, growing with the
    /// text), each centred in its column, with no gap between columns, so their centres are one `side` apart: an even
    /// rhythm whatever each symbol's own width. `wordGap` is the only other space: one standard 8 pt (the HIG's default
    /// spacing) on each side of the gray system word.
    static let columnGap: CGFloat = 0
    static let wordGap: CGFloat = 8
    /// The name keeps at least this much room on one line (about seven letters at the body size); with less, the row
    /// stacks as at the accessibility sizes (the largest standard text sizes on a normal iPhone).
    @ScaledMetric(relativeTo: .body) private var nameMinimum: CGFloat = 80
    @State private var rowWidth: CGFloat = 0

    /// The width the one-line row needs besides the name, without the system word (which drops first): the light
    /// and its gap, the way-in columns and the (i).
    private var fixedWidth: CGFloat {
        let column = max(44, side)
        return 10 + 10 + CGFloat(columns.count + 1) * column + CGFloat(columns.count) * Self.columnGap
    }

    private var stacked: Bool {
        Self.stacks(typeSize) || (rowWidth > 0 && rowWidth - fixedWidth < nameMinimum)
    }

    var body: some View {
        Group {
            if stacked {
                VStack(alignment: .leading, spacing: 0) {
                    nameLine
                    // The word, if it fits, just left of the icons, as on one line; otherwise it drops.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Self.columnGap) { word; icons; Spacer(minLength: 0); infoButton }
                        HStack(spacing: Self.columnGap) { icons; Spacer(minLength: 0); infoButton }
                    }
                }
                // At these sizes the list's own side margin all but goes; keep the name off the card's edge.
                .padding(.leading, Self.stacks(typeSize) ? 12 : 0)
                .padding(.vertical, 6)
            } else {
                // The first line is used only when its ideal width (the whole name, the word, the icons) fits the row;
                // otherwise the word goes entirely and the name takes its room, shortened by the system only if it
                // still does not fit. The icons and (i) stay at the trailing edge either way.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: Self.columnGap) { nameLine; word; icons; infoButton }
                    HStack(spacing: Self.columnGap) { nameLine; icons; infoButton }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { rowWidth = $0 }
    }

    private var nameLine: some View {
        HStack(spacing: 10) {
            ComputerLightView(light: light, name: entry.name)
            Button(action: openDefault) {
                HStack(spacing: 0) {
                    // One line at the usual text sizes (a long name ends in "…"; VoiceOver reads it whole); up to
                    // three when the row stacks at the accessibility sizes.
                    Text(entry.name)
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(stacked ? 3 : 1)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The divider starts where the name starts.
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
            // The system is read with the name ("Tower PC, Windows PC"); the mark itself is hidden.
            .accessibilityLabel(entry.system.map { "\(entry.name), \($0.spoken)" } ?? entry.name)
            .accessibilityHint(entry.defaultWay.map { "Opens it in \($0.label)." } ?? "")
            .accessibilityIdentifier("computerName.\(entry.name)")
        }
    }

    /// The system's info button. HIG Lists and tables: "An info button shows details about a list item; it doesn't
    /// support navigation", which is what the settings page is. At least 44 × 44 pt to touch (HIG Buttons).
    private var infoButton: some View {
        Button("Settings for \(entry.name)", systemImage: "info.circle", action: settings)
            .labelStyle(.iconOnly)
            .font(.title3)
            .frame(width: max(44, side), height: max(44, side))
            .contentShape(Rectangle())
            .buttonStyle(.borderless)
            .accessibilityIdentifier("macSettings.\(entry.name)")
    }

    private var word: some View {
        ComputerSystemWord(system: entry.system).padding(.horizontal, Self.wordGap)
    }

    @ViewBuilder private var icons: some View {
        ForEach(columns) { way in
            let l = look(way)
            WayIconButton(way: way, name: entry.name, look: l, symbol: entry.symbol(way)) {
                if l.isGray { add(way) } else { open(way) }
            }
        }
    }
}

/// The system as a gray word: "macOS", "Windows" or "Linux" in the secondary colour at `.footnote`, in a column as wide
/// as the longest word so every word ends at the same edge just left of the icons; empty while the system is not known.
/// Information, not a button: hidden from VoiceOver, since the name already reads the system ("Tower PC, Windows PC").
struct ComputerSystemWord: View {
    let system: ComputerSystem?

    var body: some View {
        ZStack(alignment: .trailing) {
            ForEach(ComputerSystem.allCases, id: \.self) { Text($0.word).hidden() }
            Text(system?.word ?? "").foregroundStyle(.secondary)
        }
        .font(.footnote)
        .lineLimit(1)
        .fixedSize()
        .accessibilityHidden(true)
        .preference(key: SystemWordShown.self, value: system != nil)
    }
}

/// Whether a row is showing its system word (true only when the word is laid out, not dropped). Read by the tests.
struct SystemWordShown: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) { value = value || nextValue() }
}

extension ComputerSystem {
    /// The list's gray word.
    var word: String {
        switch self {
        case .mac: "macOS"
        case .windows: "Windows"
        case .linux: "Linux"
        }
    }

    /// What VoiceOver says after the name.
    var spoken: String {
        switch self {
        case .mac: "Mac"
        case .windows: "Windows PC"
        case .linux: "Linux"
        }
    }
}

/// One way-in icon: at least 44 × 44 pt to touch (HIG Buttons: "a button needs a hit region of at least 44x44 pt"),
/// growing with Dynamic Type, with its own VoiceOver label.
struct WayIconButton: View {
    let way: WayIn
    let name: String
    let look: WayLook
    /// The icon.
    var symbol: String? = nil
    let action: () -> Void
    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 20
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 44

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol ?? way.symbol)
                .font(.system(size: glyph))
                // Gray is the system's tertiary label gray, never the app's colour faded (which read as orange).
                .foregroundStyle(look.isGray ? Color(.tertiaryLabel) : Color.accentColor)
                .overlay(alignment: .bottomTrailing) {
                    if case .notAnswering = look {
                        Image(systemName: "exclamationmark.circle.fill")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red)
                            .font(.system(size: glyph * 0.6, weight: .bold))
                            .background(Circle().fill(Color(.secondarySystemGroupedBackground)).padding(-1.5))
                            .offset(x: glyph * 0.3, y: glyph * 0.25)
                            .accessibilityIdentifier("wayBadge.\(way.rawValue).\(name)")
                    }
                }
                .frame(width: max(44, side), height: max(44, side))
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(look == .notSetUp ? way.addLabel(name)
                            : look == .needsSetUpHere ? "Set up \(way.label) on this iPhone for \(name)" : way.openLabel(name))
        .accessibilityValue(Self.value(look))
        .accessibilityIdentifier("way.\(way.rawValue).\(name)")
    }

    static func value(_ look: WayLook) -> String {
        if case let .notAnswering(why) = look { return why }
        if look == .needsSetUpHere { return WayLook.needsSetUpHereWords }
        return ""
    }
}

// MARK: - Opening a computer in one way in

/// The computer open on its own screen, and in which way in. Project notes (computers-m3) 2: each list icon opens exactly its
/// own way in, with no "first that answers" order. Terminal and JetKVM open here, on their own screens, with no Glass
/// Act session, whether or not the computer also has Screen Sharing; Screen Sharing starts the Glass Act session.
/// Outside the build switches, so every build reads it; a way in the build cannot show is never opened.
@MainActor @Observable final class ComputerNav {
    static let shared = ComputerNav()
    /// The open computer's id (nil: the list or a Glass Act session).
    private(set) var openID: String?
    private(set) var way: WayIn?
    /// Set by the root view: start a Glass Act session to this computer, in this view (Whole Screen from the list;
    /// the chosen one from a Terminal or JetKVM screen's view switch); end any session or attempt.
    @ObservationIgnored var startScreenSharing: (MacEntry, SessionView) -> Void = { _, _ in }
    @ObservationIgnored var endScreenSharing: () -> Void = {}

    /// Opens `e` in exactly `way` (nothing when this build cannot, or the computer does not have it).
    func open(_ e: MacEntry, in way: WayIn) {
        guard e.opens(way) else { return }
        switch way {
        case .screenSharing where e.hasRemoteDesktop:
            // A PC opens on its own screen, with no Glass Act session.
            endScreenSharing()
            self.way = way
            openID = e.id
        case .screenSharing:
            close()
            startScreenSharing(e, .regular)
        case .terminal, .jetkvm:
            endScreenSharing()
            self.way = way
            openID = e.id
        }
    }

    /// Opens `e` in the way in `view` belongs to: Whole Screen or Follow Pointer start the Screen Sharing session in
    /// that view.
    func open(_ e: MacEntry, view: SessionView) {
        guard e.opens(view.way) else { return }
        if view.way == .screenSharing, !e.hasRemoteDesktop {
            close()
            startScreenSharing(e, view)
        } else {
            open(e, in: view.way)
        }
    }

    /// A tap on the name: `e` in its Opens In way (`MacEntry.defaultWay`). Screen Sharing starts in Whole Screen, as
    /// from its icon. When that way does not answer, its waiting or failure screen offers the others, as from an icon.
    func openDefault(_ e: MacEntry) {
        guard let way = e.defaultWay else { return }
        open(e, in: way)
    }

    func close() {
        openID = nil
        way = nil
    }

    /// The other ways in a screen offers when its own does not answer (or as a switch), in column order.
    static func others(_ e: MacEntry, than way: WayIn) -> [WayIn] {
        e.waysInThisBuild.filter { $0 != way }
    }
}

/// "Open in JetKVM Instead" and the like, for the computer's other ways in (PLAN: "When the way in that was tapped
/// does not answer, the waiting/failure screen offers the computer's other ways in right there"). `leave` first lets
/// go of the way in that did not answer.
struct OtherWaysOffer: View {
    let entry: MacEntry
    let current: WayIn
    var onDark = false
    let leave: () -> Void

    var body: some View {
        ForEach(ComputerNav.others(entry, than: current)) { w in
            Button {
                leave()
                ComputerNav.shared.open(entry, in: w)
            } label: {
                Label(entry.insteadTitle(w), systemImage: entry.symbol(w))
            }
            .buttonStyle(.bordered)
            .tint(onDark ? .white : .accentColor)
            .accessibilityIdentifier("openInstead.\(w.rawValue)")
        }
    }
}
