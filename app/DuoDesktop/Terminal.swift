#if DUO_TERMINAL
// The whole terminal sits behind DUO_TERMINAL (the owner 2026-11-21: the terminal and KVM are the "super version",
// separate from the plain Glass Act version), as do its few hooks in shared files.
import DuoTerminalKit
import GlassActSession
import GlassActWire
import SwiftTerm
import SwiftUI
import UIKit

// The Terminal view, milestone M1 (project notes): SwiftTerm draws the terminal in the picture's
// place; the system keyboard and the band's terminal keys type into it. No network yet: what is typed is fed back
// to the terminal (a local echo, a drawing test only). M2 replaces `TerminalSession.deliver` with the SSH channel.

// MARK: - The rule: Terminal is offered only for a Mac whose Terminal switch is on

extension MacEntry {
    /// The Terminal switch in the Mac's settings, off by default; entries saved before it existed read as off.
    var terminalOn: Bool {
        get { terminal ?? false }
        set { terminal = newValue }
    }
}

// MARK: - The local echo (M1)

enum TerminalEcho {
    /// What the terminal shows for bytes typed into it while there is no Mac on the other end. Return starts a new
    /// line, delete rubs out one character, and every other control byte is shown as caret notation (`^[` for
    /// esc), so the band's esc and arrows show their escape codes instead of moving the cursor.
    static func display(_ input: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        for b in input {
            switch b {
            case 0x0d, 0x0a: out += [0x0d, 0x0a]
            case 0x7f, 0x08: out += [0x08, 0x20, 0x08]
            case 0x00..<0x20: out += [UInt8(ascii: "^"), b + 0x40]
            default: out.append(b)
            }
        }
        return out
    }
}

/// Paste inserts and never presses Return (reviewer correction 2 to the plan): trailing line ends are dropped, and the
/// text goes through the terminal's own paste path (bracketed when the program asked for it).
enum TerminalPaste {
    static func prepare(_ text: String) -> String { PasteRule.prepare(text) }
}

// MARK: - The band's terminal keys

enum TerminalKey: String, CaseIterable, Identifiable {
    case esc, tab, ctrl, left, up, down, right, ctrlC, paste

    var id: String { rawValue }

    var label: String {
        switch self {
        case .esc: "esc"
        case .tab: "tab"
        case .ctrl: "ctrl"
        case .left: "←"
        case .up: "↑"
        case .down: "↓"
        case .right: "→"
        case .ctrlC: "⌃C"
        case .paste: "Paste"
        }
    }

    var accessibilityLabel: String {
        switch self {
        case .left: "Left arrow"
        case .up: "Up arrow"
        case .down: "Down arrow"
        case .right: "Right arrow"
        case .ctrlC: "Control C"
        default: label
        }
    }

    /// The bytes the key sends (nil: ctrl and Paste act on the terminal instead). Arrows follow the
    /// terminal's cursor-key mode (`applicationCursor`), as a hardware keyboard's do.
    func bytes(applicationCursor: Bool = false) -> [UInt8]? {
        let csi: [UInt8] = applicationCursor ? [0x1b, UInt8(ascii: "O")] : [0x1b, UInt8(ascii: "[")]
        switch self {
        case .esc: return [0x1b]
        case .tab: return [0x09]
        case .up: return csi + [UInt8(ascii: "A")]
        case .down: return csi + [UInt8(ascii: "B")]
        case .right: return csi + [UInt8(ascii: "C")]
        case .left: return csi + [UInt8(ascii: "D")]
        case .ctrlC: return [0x03]
        case .ctrl, .paste: return nil
        }
    }

    /// One row (the owner 2026-11-21: "I think the terminal shortcut keys are too big. Let's pick the most important ones
    /// and make it only one row"). Dropped: | ~ / - ` (the system keyboard's 123 page), ⌃D (ctrl then d) and Copy
    /// (selecting text in the terminal shows the system's Copy).
    static let row: [TerminalKey] = [.esc, .tab, .ctrl, .left, .up, .down, .right, .ctrlC, .paste]
}


// MARK: - One terminal per Mac, kept while the app runs

@MainActor @Observable
final class TerminalSession: NSObject, TerminalViewDelegate {
    private static var byMac: [String: TerminalSession] = [:]
    static func `for`(mac: String) -> TerminalSession {
        if let s = byMac[mac] { return s }
        let s = TerminalSession()
        byMac[mac] = s
        return s
    }

    /// The band's ctrl, held for the next key like the other modifiers; SwiftTerm lets go of it after one key.
    var ctrl = false {
        didSet { view.controlModifier = ctrl }
    }

    @ObservationIgnored lazy var view: TerminalView = {
        let v = TerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        v.terminalDelegate = self
        // The band holds the terminal keys; SwiftTerm's own key row over the keyboard is not shown.
        v.inputAccessoryView = nil
        v.optionAsMetaKey = false
        v.accessibilityIdentifier = "terminal"
        NotificationCenter.default.addObserver(forName: .terminalViewControlModifierReset, object: v, queue: .main) {
            [weak self] _ in MainActor.assumeIsolated { if self?.ctrl == true { self?.ctrl = false } }
        }
        return v
    }()

    /// The SSH link to the Mac (M2): the PTY runs tmux's `duo` session; it reconnects and reattaches by itself.
    @ObservationIgnored private var link: TerminalLink?
    @ObservationIgnored private var linkKey: String?
    /// The terminal's last size in characters (SwiftTerm's `getTerminal()` is not public in 1.99.3).
    @ObservationIgnored private var size = (cols: 80, rows: 24)
    /// One line about the link, shown over the terminal when it is not connected.
    var status: String?
    /// Why the last attempt failed, in plain words (nil while it is fine or still trying the first time).
    var problem: TerminalProblem?

    /// After the Mac's settings changed (from the problem's button): forget the old link and connect again.
    func retry(_ entry: MacEntry?, store: MacStore) {
        link?.stop()
        link = nil
        linkKey = nil
        problem = nil
        status = nil
        whenAppOpen { [weak self] in
            guard let self else { return }
            TerminalKeyByHost.thenConnect(self, entry: entry, store: store)
        }
    }
    /// Review fixes (review finding 3): the Terminal view asked to connect while the app was not open (locked, or
    /// back before the lock decided). Run once the same unlock opens it; nothing (no key read, no Host request, no
    /// SSH) happens before.
    @ObservationIgnored private var whenOpen: (() -> Void)?
    @ObservationIgnored private var accessWatch: NSObjectProtocol?

    override init() {
        super.init()
        accessWatch = NotificationCenter.default.addObserver(forName: AppAccess.changed, object: nil, queue: .main) {
            [weak self] note in
            guard let state = note.object as? AppAccess.State else { return }
            MainActor.assumeIsolated { self?.accessChanged(state) }
        }
    }

    /// Locked: the link closes and holds. Open: it resumes (reconnect, reattach) and any deferred start runs.
    /// Away: the link's own `mayConnect` stops new attempts; a live link is kept.
    func accessChanged(_ state: AppAccess.State) {
        Self.apply(state, to: link)
        if state == .open, let start = whenOpen {
            whenOpen = nil
            start()
        }
    }

    /// The link's side of `accessChanged` (also the focused check's).
    nonisolated static func apply(_ state: AppAccess.State, to link: TerminalLink?) {
        switch state {
        case .locked: link?.hold()
        case .open: link?.resume()
        case .away: break
        }
    }

    /// Runs `start` now if the app is open, else once the unlock opens it (the latest request wins).
    func whenAppOpen(_ start: @escaping () -> Void) {
        if AppAccess.isOpen { whenOpen = nil; start() } else { whenOpen = start }
    }

    /// Connects to the Mac in `entry` (its tailnet name, its SSH user, the phone's key), once per Mac and target.
    func connect(_ entry: MacEntry?) {
        let hostUser = entry.flatMap { TerminalKeyByHost.states.state(for: $0.id)?.user }.flatMap { $0.isEmpty ? nil : $0 }
        guard let entry, let user = entry.sshUser ?? hostUser else {
            status = "Set this Mac's SSH user name in its settings."; problem = nil; return
        }
        guard let host = entry.address(.tailscale) ?? entry.address(.home) else { status = "This Mac has no address."; return }
        let k = "\(user)@\(host)"
        guard linkKey != k else { return }
        guard AppAccess.isOpen else { whenOpen = { [weak self] in self?.connect(entry) }; return }
        link?.stop()
        do {
            let key = try TerminalKeys.phoneKey()
            let l = TerminalLink(target: .init(host: host, user: user, hostKeyID: sshHostKeyID(mac: entry.id)),
                                 key: key, hostKeys: TerminalKeys.hostKeys)
            l.onOutput = { [weak self] b in DispatchQueue.main.async { self?.view.feed(byteArray: b[...]) } }
            // Touch ID clarity B (the owner: "I typed the wrong name, but I never got any indication it wouldn't
            // work"): each failure is told in plain words, also on the Mac's settings line (`TerminalProblems`).
            let macID = entry.id
            l.onAttemptFailed = { [weak self] error in
                let kind = SSHFailureKind.of(error)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        let p = TerminalProblem.diagnose(kind, user: user, host: host,
                                                         keyState: TerminalKeyByHost.states.state(for: macID))
                        self?.problem = p
                        TerminalProblems.shared.set(p, for: macID)
                    }
                }
            }
            l.onState = { [weak self] st in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        switch st {
                        case .connected:
                            self?.status = nil; self?.problem = nil
                            TerminalProblems.shared.set(nil, for: macID)
                        case .connecting, .waiting:
                            if let p = self?.problem { self?.status = p.text + (p.retries ? " Trying again…" : "") }
                            else { self?.status = "Connecting to \(entry.name)…" }
                        case .stopped(let why): self?.status = self?.problem?.text ?? why
                        case .idle, .held: break
                        }
                    }
                }
            }
            l.resize(cols: size.cols, rows: size.rows)
            l.mayConnect = { AppAccess.isOpen }
            link = l; linkKey = k
            l.start()
        } catch {
            status = "This phone's key is not available (\(error))."
        }
    }

    /// A terminal-only computer (project notes, terminal-only computers, M2): no Glass Act Host behind it, so no key request;
    /// signs in with Tailscale (`none`) or this iPhone's key, and opens tmux `duo` (or a login shell with a notice
    /// when the computer has no tmux), or the login shell itself. Reconnects and rejoins as a Mac's terminal does.
    func connectComputer(_ entry: MacEntry) {
        guard let user = entry.sshUser, !user.isEmpty else {
            status = "Set the user name in \(entry.name)’s settings."; problem = nil; return
        }
        guard let host = entry.address(.tailscale) ?? entry.address(.home) else {
            status = "\(entry.name) has no address."; return
        }
        let tailscale = entry.signIn == .tailscale
        let k = "\(user)@\(host):\(entry.sshPortValue):\(tailscale):\(entry.opens.rawValue)"
        guard linkKey != k else { return }
        guard AppAccess.isOpen else { whenOpen = { [weak self] in self?.connectComputer(entry) }; return }
        link?.stop()
        do {
            let key = try TerminalKeys.phoneKey()
            let l = TerminalLink(target: .init(host: host, port: Int(entry.sshPortValue), user: user,
                                               hostKeyID: sshHostKeyID(mac: entry.id, port: Int(entry.sshPortValue)),
                                               tailscale: tailscale),
                                 key: key, hostKeys: TerminalKeys.hostKeys, command: entry.opens.command)
            l.onOutput = { [weak self] b in DispatchQueue.main.async { self?.view.feed(byteArray: b[...]) } }
            let id = entry.id, name = entry.name
            l.onBanner = { text in
                // M2 proof: Tailscale sends no banner in accept mode; anything it does send is shown in the
                // terminal itself, so a check-mode sign-in link would be seen.
                let lines = Array(("\r\n" + text.replacingOccurrences(of: "\n", with: "\r\n")).utf8)
                DispatchQueue.main.async { MainActor.assumeIsolated { TerminalComputerBanners.shared.last[id] = text } }
                DispatchQueue.main.async { [weak self] in self?.view.feed(byteArray: lines[...]) }
            }
            l.onAttemptFailed = { [weak self] error in
                let p = TerminalComputerProblem.diagnose(error, user: user, host: host, port: Int(entry.sshPortValue),
                                                         tailscale: tailscale)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        self?.status = p.text + (p.retries ? " Trying again…" : "")
                        TerminalComputerProblems.shared.set(p, for: id)
                    }
                }
            }
            l.onState = { [weak self] st in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        switch st {
                        case .connected:
                            self?.status = nil; self?.problem = nil
                            TerminalComputerProblems.shared.set(nil, for: id)
                        case .connecting, .waiting:
                            if TerminalComputerProblems.shared.problems[id] == nil { self?.status = "Connecting to \(name)…" }
                        case .stopped(let why):
                            self?.status = TerminalComputerProblems.shared.problems[id]?.text ?? why
                        case .idle, .held: break
                        }
                    }
                }
            }
            l.resize(cols: size.cols, rows: size.rows)
            l.mayConnect = { AppAccess.isOpen }
            link = l; linkKey = k
            l.start()
        } catch {
            status = "This iPhone’s key is not available (\(error))."
        }
    }

    /// Leaving a terminal-only computer (the back button): the link closes; tmux keeps the session on the computer.
    func disconnect() {
        link?.stop()
        link = nil
        linkKey = nil
        status = nil
    }

    /// Bytes typed into the terminal (keyboard, band, paste) go to the Mac; no local echo while there is a link.
    /// Without a link (no SSH user yet) nothing is sent.
    func deliver(_ bytes: [UInt8]) {
        guard AppAccess.isOpen else { return } // review fixes: no input while the app is locked
        link?.send(bytes)
    }

    #if targetEnvironment(simulator)
    /// The simulator's test switch for M4: closes the transport as a lost link would.
    func dropTransportForTest() { link?.dropTransportForTest() }
    #endif

    func press(_ key: TerminalKey) {
        switch key {
        case .ctrl: ctrl.toggle()
        case .paste:
            if let text = UIPasteboard.general.string { view.pasteText(TerminalPaste.prepare(text)) }
        // Arrows through SwiftTerm's own senders, which follow the terminal's cursor-key mode.
        case .up: view.sendKeyUp(); ctrl = false
        case .down: view.sendKeyDown(); ctrl = false
        case .left: view.sendKeyLeft(); ctrl = false
        case .right: view.sendKeyRight(); ctrl = false
        default:
            if let b = key.bytes() { view.send(b) }
            ctrl = false
        }
    }

    // TerminalViewDelegate
    nonisolated func send(source: TerminalView, data: ArraySlice<UInt8>) {
        let bytes = Array(data)
        MainActor.assumeIsolated { deliver(bytes) }
    }
    /// The PTY on the Mac follows the terminal view's size.
    nonisolated func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
        MainActor.assumeIsolated { size = (newCols, newRows); link?.resize(cols: newCols, rows: newRows) }
    }
    nonisolated func setTerminalTitle(source: TerminalView, title: String) {}
    nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    nonisolated func scrolled(source: TerminalView, position: Double) {}
    nonisolated func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {}
    nonisolated func bell(source: TerminalView) {}
    nonisolated func clipboardCopy(source: TerminalView, content: Data) {
        if let s = String(data: content, encoding: .utf8) { UIPasteboard.general.string = s }
    }
    nonisolated func clipboardRead(source: TerminalView) -> Data? { nil }
    nonisolated func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
    nonisolated func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}

// MARK: - The views

/// The terminal in the picture's place. It takes the system keyboard while shown.
struct TerminalPanel: View {
    let session: TerminalSession
    let entry: MacEntry?
    let store: MacStore
    @State private var showSettings = false

    var body: some View {
        TerminalHost(session: session)
            .overlay(alignment: .top) {
                if let s = session.status {
                    VStack(spacing: 8) {
                        Text(s).font(.footnote).multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("terminalStatus")
                        // HIG Alerts/Feedback: say what happened and offer the one way to fix it, right there.
                        if session.problem?.opensSettings == true, entry != nil {
                            Button("Open \(entry?.name ?? "Mac") Settings") { showSettings = true }
                                .buttonStyle(.glassProminent)
                                .accessibilityIdentifier("terminalOpenSettings")
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .glassEffect(.regular, in: .rect(cornerRadius: 16)).padding(8)
                }
            }
            .sheet(isPresented: $showSettings, onDismiss: { session.retry(entry.flatMap { store.entry($0.id) }, store: store) }) {
                if let entry {
                    NavigationStack {
                        ComputerSettingsScreen(store: store, id: entry.id, chosen: nil)
                            .toolbar {
                                ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } }
                            }
                    }
                }
            }
            .onAppear {
                // Review fixes (review finding 3): the Host key request and the SSH link wait for the app lock.
                session.whenAppOpen { [session, entry, store] in TerminalKeyByHost.thenConnect(session, entry: entry, store: store) }
            }
    }
}

struct TerminalHost: UIViewRepresentable {
    let session: TerminalSession

    func makeUIView(context: Context) -> UIView {
        let box = UIView()
        box.backgroundColor = .black
        let v = session.view
        v.removeFromSuperview()
        v.translatesAutoresizingMaskIntoConstraints = false
        box.addSubview(v)
        NSLayoutConstraint.activate([
            v.leadingAnchor.constraint(equalTo: box.leadingAnchor, constant: 4),
            v.trailingAnchor.constraint(equalTo: box.trailingAnchor, constant: -4),
            v.topAnchor.constraint(equalTo: box.topAnchor, constant: 4),
            v.bottomAnchor.constraint(equalTo: box.bottomAnchor),
        ])
        DispatchQueue.main.async { _ = v.becomeFirstResponder() }
        return box
    }

    func updateUIView(_ box: UIView, context: Context) {}

    static func dismantleUIView(_ box: UIView, coordinator: ()) {
        box.subviews.forEach { $0.resignFirstResponder() }
    }
}

/// The band in the Terminal view: one row of equal keys directly above the system keyboard, drawn like the Mac
/// keys row (`MacKeysBar`: KeyLook keys, `KeyMetrics.height` tall) on the band's keyboard-coloured panel. Each key
/// takes touches over the row's full `height` (HIG: 44 pt targets). The terminal takes the rest of the band.
struct TerminalKeysBand: View {
    @Bindable var session: TerminalSession

    /// The row's height: the touch height of its keys.
    static let height: CGFloat = 44
    /// The points of the band the terminal takes: everything but the row (never negative).
    static func terminalExtra(bandHeight: CGFloat) -> CGFloat { max(0, bandHeight - height) }

    var body: some View {
        HStack(spacing: KeyMetrics.gap) {
            ForEach(TerminalKey.row) { key in
                let on = key == .ctrl && session.ctrl
                Button { session.press(key) } label: {
                    Text(key.label)
                        .font(.system(size: key.label.count > 2 ? KeyLook.wordSize : KeyLook.glyphSize))
                        .lineLimit(1).minimumScaleFactor(0.6)
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity)
                        .frame(height: KeyMetrics.height)
                        .background(on ? Color.accentColor : KeyLook.keyFill, in: KeyLook.shape)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(key.accessibilityLabel)
                .accessibilityAddTraits(on ? [.isSelected] : [])
                .accessibilityIdentifier("terminalKey.\(key.rawValue)")
            }
        }
        .frame(height: Self.height)
        .padding(.horizontal, 6)
        #if targetEnvironment(simulator)
        .onAppear { TerminalDemo.run(session) }
        #endif
    }
}

/// The Terminal section of a Mac's ⓘ page (a computer with Screen Sharing; shown once Terminal is added. Milestone 2
/// took its switch away: the page's Add Terminal… row and Remove Terminal do that now).
struct TerminalSettingsSection: View {
    let store: MacStore
    let id: String
    @State private var installing = false

    var body: some View {
        if let entry = store.entry(id) {
            Section {
                if entry.terminalOn {
                    let hostUser = TerminalKeyByHost.states.state(for: id)?.user ?? ""
                    LabeledContent("SSH User Name") {
                        TextField("Not set", text: Binding(get: { store.entry(id)?.sshUser ?? "" }, set: { v in
                            let t = v.trimmingCharacters(in: .whitespaces)
                            store.update(id) { $0.sshUser = t.isEmpty ? nil : t }
                        }))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .accessibilityIdentifier("settingsSSHUser")
                    }
                    // Touch ID clarity B: the account the Host reported, and an in-place warning on a different
                    // name (HIG: validate in place, say how to fix it, offer the fix).
                    if !hostUser.isEmpty {
                        Text("This Mac’s Host runs as \(hostUser).").foregroundStyle(.secondary)
                            .accessibilityIdentifier("settingsHostUser")
                    }
                    if let w = SSHUserRules.warning(typed: entry.sshUser, hostUser: hostUser) {
                        Label(w, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .accessibilityIdentifier("settingsSSHUserWarning")
                        Button("Use \(hostUser)") { store.update(id) { $0.sshUser = hostUser } }
                            .accessibilityIdentifier("settingsUseHostUser")
                    }
                    if let p = TerminalProblems.shared.problems[id] {
                        Label(p.text, systemImage: "xmark.octagon.fill")
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("settingsTerminalProblem")
                    }
                }
            } header: {
                Text("Terminal")
            } footer: {
                Text("Terminal is in the view switch for this Mac. It signs in over SSH as the user name above.")
            }
            if entry.terminalOn {
                Section {
                    if TerminalKeyByHost.states.askingOnMac.contains(id) {
                        // Review fixes 2: the Host is asking its user once (an approval from before it recorded this).
                        Text("Approve on the Mac").accessibilityIdentifier("settingsTerminalKeyState")
                    } else if let line = TerminalKeyByHost.settingsLine(TerminalKeyByHost.states.state(for: id)) {
                        Text(line).accessibilityIdentifier("settingsTerminalKeyState")
                    }
                    Button("Add This Phone's Key to the Mac…") { installing = true }
                        .accessibilityIdentifier("settingsTerminalAddKey")
                    if let k = try? TerminalKeys.phoneKey() {
                        Text(k.authorizedKeysLine(comment: "duo-desktop"))
                            .font(.caption.monospaced()).textSelection(.enabled)
                        Button("Copy This Phone's Key") { UIPasteboard.general.string = k.authorizedKeysLine(comment: "duo-desktop") }
                    }
                } header: {
                    Text("This Phone's SSH Key")
                } footer: {
                    Text("Duo Desktop asks the Mac's Host to add this key. If the Host is too old to do that, add it with the Mac's password or copy it.")
                }
                .sheet(isPresented: $installing) { TerminalKeyInstallSheet(entry: entry) }
            }
        }
    }
}

// MARK: - The Host adds the phone's key (the owner 2026-11-21: "Yes re terminal key install.")

/// Carries the request to the Host and its answer back: the Glass Act session (ViewerController).
@MainActor protocol TerminalKeyChannel: AnyObject {
    var onTerminalKeyResult: ((WireTerminalKeyResult) -> Void)? { get set }
    func installTerminalKey(requestID: UInt32, keyLine: String, sent: @escaping @Sendable (Bool) -> Void)
}

extension ViewerController: TerminalKeyChannel {}

/// What one Mac's Host last said about this phone's terminal key. Kept per Mac.
struct TerminalKeyState: Codable, Equatable {
    enum Answer: String, Codable { case installed, alreadyThere, refused, olderHost }
    var answer: Answer
    var remoteLoginOn = true
    var tmuxPresent = true
    var user = ""
    var reason = ""

    init(answer: Answer, remoteLoginOn: Bool = true, tmuxPresent: Bool = true, user: String = "", reason: String = "") {
        self.answer = answer
        self.remoteLoginOn = remoteLoginOn
        self.tmuxPresent = tmuxPresent
        self.user = user
        self.reason = reason
    }

    init(_ r: WireTerminalKeyResult) {
        let a: Answer = switch r.status {
        case .installed: .installed
        case .alreadyThere: .alreadyThere
        case .refused, .askingOnMac: .refused // askingOnMac is never recorded (TerminalKeyByHost.send)
        }
        self.init(answer: a, remoteLoginOn: r.remoteLoginOn, tmuxPresent: r.tmuxPresent, user: r.userName,
                  reason: r.reason)
    }

    var keyOnMac: Bool { answer == .installed || answer == .alreadyThere }
}

/// The states, per Mac, in the app's defaults; observed by the settings.
@MainActor @Observable final class TerminalKeyStates {
    @ObservationIgnored let defaults: UserDefaults
    private var cache: [String: TerminalKeyState] = [:]
    /// Macs whose Host is asking its user right now whether this phone may add its key (review fixes 2).
    var askingOnMac: Set<String> = []
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func state(for mac: String) -> TerminalKeyState? {
        if let s = cache[mac] { return s }
        guard let d = defaults.data(forKey: "terminalKeyState.\(mac)") else { return nil }
        return try? JSONDecoder().decode(TerminalKeyState.self, from: d)
    }

    func set(_ s: TerminalKeyState, for mac: String) {
        cache[mac] = s
        if let d = try? JSONEncoder().encode(s) { defaults.set(d, forKey: "terminalKeyState.\(mac)") }
    }
}

@MainActor enum TerminalKeyByHost {
    static var states = TerminalKeyStates()

    /// The running Glass Act session and its Mac (set by SessionModel when it dials).
    struct Live { let macID: String; weak var controller: (any TerminalKeyChannel)? }
    static var live: Live?

    /// How long to wait for the Host's answer before treating it as a Host that does not know the request.
    static var waitSeconds = 4.0
    /// Review fixes 2: once the Host says it is asking its user, how long to wait for that person's answer.
    static var askingWaitSeconds = 180.0

    enum Outcome: Equatable {
        case answered(WireTerminalKeyResult)
        /// No answer in time: a Host from before this request. The password sheet and copy button remain.
        case olderHost
        /// No running session to this Mac to carry the request.
        case noSession
    }

    /// Asks the Host of `macID` (only over its running session) to add this phone's key; records what it said and
    /// fills the SSH user name from its answer when the name is empty.
    static func ask(macID: String, store: MacStore, asking: @escaping @MainActor () -> Void = {},
                    done: @escaping @MainActor (Outcome) -> Void) {
        guard let live, live.macID == macID, let controller = live.controller,
              let key = try? TerminalKeys.phoneKey() else { done(.noSession); return }
        send(controller: controller, keyLine: key.authorizedKeysLine(comment: "duo-desktop"), asking: {
            states.askingOnMac.insert(macID)
            asking()
        }) { outcome in
            states.askingOnMac.remove(macID)
            record(outcome, macID: macID, store: store)
            done(outcome)
        }
    }

    /// The request itself, over any channel (tests use a fake that answers, or one that never does).
    /// The Host may first say it is asking its user (`.askingOnMac`, an approval from before it recorded SSH-key
    /// permission): `asking` runs, and the wait for the real answer becomes `askingWaitSeconds`.
    static func send(controller: some TerminalKeyChannel, keyLine: String, asking: @escaping @MainActor () -> Void = {},
                     done: @escaping @MainActor (Outcome) -> Void) {
        let id = UInt32.random(in: 1...UInt32.max)
        var finished = false
        var deadline = 0 // only the newest deadline counts
        let finish: @MainActor (Outcome) -> Void = { o in
            guard !finished else { return }
            finished = true
            done(o)
        }
        let wait: @MainActor (Double, Outcome) -> Void = { seconds, o in
            deadline += 1
            let mine = deadline
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                MainActor.assumeIsolated { if mine == deadline { finish(o) } }
            }
        }
        controller.onTerminalKeyResult = { r in
            guard r.requestID == id else { return }
            MainActor.assumeIsolated {
                guard !finished else { return }
                if r.status == .askingOnMac {
                    wait(askingWaitSeconds, .answered(WireTerminalKeyResult(
                        requestID: id, status: .refused, remoteLoginOn: r.remoteLoginOn, tmuxPresent: r.tmuxPresent,
                        userName: r.userName, reason: "no answer on the Mac")))
                    asking()
                } else {
                    finish(.answered(r))
                }
            }
        }
        controller.installTerminalKey(requestID: id, keyLine: keyLine) { sent in
            if !sent { MainActor.assumeIsolated { finish(.noSession) } }
        }
        wait(waitSeconds, .olderHost)
    }

    static func record(_ outcome: Outcome, macID: String, store: MacStore) {
        switch outcome {
        case let .answered(r):
            let s = TerminalKeyState(r)
            states.set(s, for: macID)
            if s.keyOnMac, !s.user.isEmpty, (store.entry(macID)?.sshUser ?? "").isEmpty {
                store.update(macID) { $0.sshUser = s.user }
            }
        case .olderHost:
            states.set(TerminalKeyState(answer: .olderHost), for: macID)
        case .noSession:
            break
        }
    }

    /// The Terminal view: ask the Host first unless it already said the key is there, then connect.
    static func thenConnect(_ session: TerminalSession, entry: MacEntry?, store: MacStore) {
        guard let entry else { session.connect(nil); return }
        if states.state(for: entry.id)?.keyOnMac == true && entry.sshUser != nil {
            session.connect(entry); return
        }
        session.status = "Asking \(entry.name) to add this phone's key…"
        ask(macID: entry.id, store: store, asking: { session.status = "Approve on the Mac" }) { outcome in
            if case let .answered(r) = outcome, r.status == .refused {
                session.status = "\(entry.name) did not add the key: \(r.reason)."
            }
            session.connect(store.entry(entry.id) ?? entry)
        }
    }

    /// The settings line: the key is on this Mac, or what is missing.
    static func settingsLine(_ s: TerminalKeyState?) -> String? {
        guard let s else { return nil }
        switch s.answer {
        case .olderHost:
            return "This Mac's Host can't add the key. Add it with the Mac's password, or copy it."
        case .refused:
            return "The Mac did not add the key: \(s.reason)."
        case .installed, .alreadyThere:
            var missing: [String] = []
            // Reviewer: the Host only sees that the SSH port is listening, not the Remote Login setting itself.
            if !s.remoteLoginOn { missing.append("This Mac's SSH port is not listening (turn on Remote Login)") }
            if !s.tmuxPresent { missing.append("tmux is not installed") }
            return missing.isEmpty ? "Key installed on this Mac" : "Key installed on this Mac. " + missing.joined(separator: ". ") + "."
        }
    }
}

// MARK: - Why a terminal sign-in failed (Touch ID clarity B)

/// The SSH user name check, pure (tests).
enum SSHUserRules {
    /// A warning when the typed name differs from the account the Host runs as (nil: no warning).
    static func warning(typed: String?, hostUser: String) -> String? {
        let t = (typed ?? "").trimmingCharacters(in: .whitespaces)
        guard !hostUser.isEmpty, !t.isEmpty, t != hostUser else { return nil }
        return "The Host on this Mac runs as \(hostUser). Terminal signs in as that user unless Remote Login allows \(t)."
    }
}

/// One failed terminal sign-in, in plain words, with what to do.
enum TerminalProblem: Equatable {
    /// The Mac refused the key for the typed name; the Host runs as another account (its key went there).
    case wrongUser(typed: String, hostUser: String)
    /// The Mac refused the key and the Host never said it installed it.
    case keyNotInstalled
    /// The Mac refused the key for the right name: it was removed, or the Mac no longer takes it.
    case keyRefused(user: String)
    /// Nothing answers on the SSH port.
    case remoteLoginOff
    /// No answer at all.
    case notReachable(host: String)

    static func diagnose(_ kind: SSHFailureKind, user: String, host: String, keyState: TerminalKeyState?) -> TerminalProblem {
        switch kind {
        case .signInRefused:
            if let h = keyState?.user, !h.isEmpty, h != user { return .wrongUser(typed: user, hostUser: h) }
            if keyState?.keyOnMac != true { return .keyNotInstalled }
            return .keyRefused(user: user)
        case .connectionRefused:
            return .remoteLoginOff
        case .notReachable:
            return keyState?.remoteLoginOn == false ? .remoteLoginOff : .notReachable(host: host)
        }
    }

    var text: String {
        switch self {
        case let .wrongUser(typed, hostUser):
            "Wrong user name: the Mac refused the sign-in as “\(typed)”. This phone’s key was added for “\(hostUser)”, the account the Host runs as. Change the SSH user name in this Mac’s settings."
        case .keyNotInstalled:
            "This phone’s key is not installed on the Mac. Add it in this Mac’s settings."
        case let .keyRefused(user):
            "The Mac refused this phone’s key for “\(user)”. Add the key again in this Mac’s settings."
        case .remoteLoginOff:
            "Remote Login is off: the Mac is not taking SSH sign-ins. Turn it on in the Mac’s System Settings › General › Sharing."
        case let .notReachable(host):
            "Can’t reach \(host) for SSH. Check that this iPhone can reach the Mac."
        }
    }

    /// The link keeps trying (the Mac may come back); a refused sign-in stops it.
    var retries: Bool {
        switch self {
        case .remoteLoginOff, .notReachable: true
        default: false
        }
    }

    /// Fixed from this Mac's settings (user name, key).
    var opensSettings: Bool { !retries }
}

/// The last problem per Mac, for the Mac's settings line (kept while the app runs).
@MainActor @Observable final class TerminalProblems {
    static let shared = TerminalProblems()
    private(set) var problems: [String: TerminalProblem] = [:]
    func set(_ p: TerminalProblem?, for mac: String) {
        if problems[mac] != p { problems[mac] = p }
    }
}

// MARK: - The phone's key and the Macs' host keys

@MainActor enum TerminalKeys {
    /// The phone's SSH key: Secure Enclave where there is one, Keychain otherwise. The simulator build is unsigned
    /// (no Keychain access group), so there it is a file; `--terminal-key-file <path>` names one for the live check.
    static func phoneKey() throws -> PhoneKey {
        #if targetEnvironment(simulator)
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--terminal-key-file"), i + 1 < args.count {
            return try PhoneKey.file(URL(fileURLWithPath: args[i + 1]))
        }
        let dir = URL.applicationSupportDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return try PhoneKey.file(dir.appendingPathComponent("terminal-ssh-key"))
        #else
        return try PhoneKey.device()
        #endif
    }

    /// The Macs' SSH host keys, one per Mac on port 22, apart from their Glass Act keys.
    static let hostKeys: HostKeyStore = DefaultsHostKeyStore()
}

final class DefaultsHostKeyStore: HostKeyStore, @unchecked Sendable {
    func hostKey(for id: String) -> String? { UserDefaults.standard.string(forKey: "terminalHostKey.\(id)") }
    func setHostKey(_ key: String, for id: String) { UserDefaults.standard.set(key, forKey: "terminalHostKey.\(id)") }
}

/// Adds the phone's key to the Mac by signing in once with the Mac's password (the owner 2026-11-21: "signing in with
/// your Mac username and password is reasonable"). The password lives only in this sheet's state and is cleared
/// as soon as the sign-in is done; it is never stored or logged.
struct TerminalKeyInstallSheet: View {
    let entry: MacEntry
    @Environment(\.dismiss) private var dismiss
    @State private var user: String
    @State private var password = ""
    @State private var working = false
    @State private var result: String?

    init(entry: MacEntry) {
        self.entry = entry
        _user = State(initialValue: entry.sshUser ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("User Name", text: $user)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                    SecureField("Password", text: $password).textContentType(.password)
                } footer: {
                    Text("Signs in to \(entry.name) once to add this phone's key. The password is not kept.")
                }
                if let result { Section { Text(result) } }
            }
            .navigationTitle("Add Key to Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { password = ""; dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await install() } }
                        .disabled(working || user.isEmpty || password.isEmpty)
                }
            }
        }
    }

    private func install() async {
        guard let host = entry.address(.tailscale) ?? entry.address(.home) else { result = "This Mac has no address."; return }
        working = true
        let pw = password
        password = ""
        defer { working = false }
        do {
            let key = try TerminalKeys.phoneKey()
            guard let cmd = AuthorizedKeys.installCommand(key.authorizedKeysLine(comment: "duo-desktop")) else { return }
            let c = try await SSHConnection.connect(host: host, user: user, signIn: .password(pw),
                                                    hostKeys: TerminalKeys.hostKeys,
                                                    hostKeyID: sshHostKeyID(mac: entry.id))
            defer { c.closeTransport() }
            let r = try await c.run(cmd)
            result = r.status == 0 ? "This phone's key is on \(entry.name). The terminal signs in with it from now on."
                                   : "The Mac did not take the key (exit \(r.status))."
        } catch {
            result = "\(error)"
        }
    }
}

#if targetEnvironment(simulator)
/// `--terminal-demo`: once connected, runs `hostname` and `ls ~/Desktop` in the shell, for the M2 screenshot.
@MainActor enum TerminalDemo {
    private static var done = false
    static func run(_ s: TerminalSession) {
        let args = CommandLine.arguments
        // `--terminal-demo-text TEXT`: type this instead (the terminal-only pictures).
        let text = args.firstIndex(of: "--terminal-demo-text").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        guard args.contains("--terminal-demo") || text != nil, !done else { return }
        done = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { s.view.send(txt: (text ?? "hostname; ls ~/Desktop") + "\r") }
    }
}
#endif
#endif
