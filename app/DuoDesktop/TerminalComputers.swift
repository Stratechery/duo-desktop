#if DUO_TERMINAL
// Terminal-only computers (project notes, terminal-only computers, milestones 1 and 2): a computer with a terminal
// and nothing else, such as a Linux server. Its own kind of list entry, its own reach check (a plain TCP connect to
// the SSH port) and its own screen, so nothing of the Glass Act session (`SessionModel`) is involved. Behind
// DUO_TERMINAL with the rest of the terminal.
import DuoTerminalKit
import Network
import SwiftUI
import UIKit

// MARK: - What a terminal-only entry keeps

/// How a terminal-only computer signs in.
enum TerminalSignIn: String, Codable, CaseIterable, Identifiable, Hashable {
    /// Tailscale SSH: the computer's Tailscale knows this iPhone; no key, no password (SSH `none`).
    case tailscale
    /// The iPhone's own SSH key, which the computer must list.
    case phoneKey

    var id: String { rawValue }
    var label: String {
        switch self {
        case .tailscale: "Tailscale"
        case .phoneKey: "This iPhone’s Key"
        }
    }
    /// The list row's words.
    var rowLabel: String {
        switch self {
        case .tailscale: "Tailscale sign-in"
        case .phoneKey: "This iPhone’s key"
        }
    }
}

/// What a terminal-only computer opens.
enum TerminalOpens: String, Codable, CaseIterable, Identifiable, Hashable {
    /// tmux session `duo`, rejoined when the link drops (a plain login shell with a notice when there is no tmux).
    case tmux
    /// Whatever the computer starts (PowerShell on Windows); a dropped link ends it.
    case loginShell

    var id: String { rawValue }
    var label: String {
        switch self {
        case .tmux: "tmux"
        case .loginShell: "Login Shell"
        }
    }
    var rowLabel: String {
        switch self {
        case .tmux: "tmux"
        case .loginShell: "Login shell"
        }
    }
    /// What the PTY runs; nil = the SSH `shell` request, no command (POSIX lines fail in PowerShell).
    var command: String? {
        switch self {
        case .tmux: ShellCommand.tmuxOrShellComputer
        case .loginShell: nil
        }
    }
}

extension MacEntry {
    var signIn: TerminalSignIn { terminalSignIn ?? .tailscale }
    var opens: TerminalOpens { terminalOpens ?? .tmux }

    /// A new terminal-only entry from the Add sheet's fields (already checked by `TerminalComputerForm`). The address
    /// is filed as Tailscale or Home by the same rule as a Mac's.
    static func terminalComputer(name: String, address: String, port: UInt16, user: String,
                                 signIn: TerminalSignIn, opens: TerminalOpens) -> MacEntry {
        var e = MacEntry(name: name.trimmingCharacters(in: .whitespaces), port: port)
        e.kind = .terminal
        let a = address.trimmingCharacters(in: .whitespaces)
        e.set(AddressKind.of(a), a)
        e.sshUser = user.trimmingCharacters(in: .whitespaces)
        e.terminalSignIn = signIn
        e.terminalOpens = opens
        return e
    }

    /// The row's second line: what it opens and how it signs in ("tmux · Tailscale sign-in").
    var terminalSecondLine: String { "\(opens.rowLabel) · \(signIn.rowLabel)" }

    /// The one address used (Tailscale first, as for a Mac's terminal).
    var terminalAddress: String? { address(.tailscale) ?? address(.home) }

    /// Moves the address to the field its kind belongs in.
    mutating func setTerminalAddress(_ a: String) {
        home = nil; tailscale = nil
        let t = a.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { set(AddressKind.of(t), t) }
    }
}

/// The Add sheet's check, pure (tests).
enum TerminalComputerForm {
    /// nil when the fields can be saved; else what is missing, in plain words.
    static func problem(name: String, address: String, user: String, port: String) -> String? {
        let t = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
        if t(name).isEmpty { return "Type a name." }
        if t(address).isEmpty { return "Type the computer’s address." }
        if t(address).contains(" ") { return "An address has no spaces." }
        if t(user).isEmpty { return "Type the user name to sign in as." }
        guard let p = UInt16(t(port)), p > 0 else { return "The port is a number from 1 to 65535." }
        _ = p
        return nil
    }
}

// MARK: - Reach: a plain TCP connect to the SSH port, every time the list appears

/// Each terminal-only computer's state in the list. No SSH sign-in happens until the row is tapped.
@MainActor @Observable
final class TerminalReach {
    enum State: Equatable {
        case checking, ready, notReachable
        var label: String {
            switch self {
            case .checking: "Checking…"
            case .ready: "Ready"
            case .notReachable: "Not reachable"
            }
        }
        var reachable: Bool { self == .ready }
        var color: Color { self == .ready ? .green : .gray }
    }

    static let shared = TerminalReach()
    private(set) var states: [String: State] = [:]
    private var generation = 0
    /// Tests swap the connect.
    @ObservationIgnored var check: (String, UInt16, TimeInterval, @escaping @Sendable (Bool) -> Void) -> Void = TCPCheck.check

    func state(_ id: String) -> State { states[id] ?? .checking }

    func probeAll(_ entries: [MacEntry]) {
        generation += 1
        let g = generation
        for e in entries {
            guard let host = e.terminalAddress else { states[e.id] = .notReachable; continue }
            // Keep the last answer while rechecking (as the Mac rows do), so a tap right after a session works.
            if states[e.id] == nil { states[e.id] = .checking }
            let id = e.id
            check(host, e.port, 2) { [weak self] ok in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.generation == g else { return }
                        self.states[id] = ok ? .ready : .notReachable
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

// MARK: - Why a sign-in failed, in plain words (no Glass Act Host to help)

enum TerminalComputerProblem: Equatable {
    /// Tailscale's policy does not let this iPhone in as that user (with Tailscale's own words when it sent them).
    case tailscaleRefused(user: String, said: String?)
    /// The computer refused this iPhone's key for that user.
    case keyRefused(user: String)
    /// Nothing is listening on the port.
    case nothingOnPort(Int)
    /// No answer at all.
    case notReachable(host: String)
    /// The computer took the connection but never finished the sign-in.
    case signInTimedOut

    static func diagnose(_ error: Error, user: String, host: String, port: Int, tailscale: Bool) -> TerminalComputerProblem {
        if error is SSHSignInTimedOut { return .signInTimedOut }
        switch SSHFailureKind.of(error) {
        case .signInRefused:
            return tailscale ? .tailscaleRefused(user: user, said: (error as? SSHSignInRefused)?.reason) : .keyRefused(user: user)
        case .connectionRefused: return .nothingOnPort(port)
        case .notReachable: return .notReachable(host: host)
        }
    }

    var text: String {
        switch self {
        case let .tailscaleRefused(user, said):
            "Tailscale refused “\(user)” for this iPhone. Check the user name, and that the tailnet’s SSH rules allow it."
                + (said.map { " (Tailscale: \($0.replacingOccurrences(of: "tailscale: ", with: "")))" } ?? "")
        case let .keyRefused(user):
            "The computer refused this iPhone’s key for “\(user)”. Add the key on the computer (copy it from its settings here)."
        case let .nothingOnPort(port):
            "Nothing answers on port \(port). Check that the computer’s SSH server is on."
        case let .notReachable(host):
            "Can’t reach \(host). Check that this iPhone can reach the computer."
        case .signInTimedOut:
            "The computer took the connection but did not finish the sign-in."
        }
    }

    var retries: Bool {
        switch self {
        case .nothingOnPort, .notReachable, .signInTimedOut: true
        default: false
        }
    }
}

@MainActor @Observable final class TerminalComputerProblems {
    static let shared = TerminalComputerProblems()
    private(set) var problems: [String: TerminalComputerProblem] = [:]
    func set(_ p: TerminalComputerProblem?, for id: String) {
        if problems[id] != p { problems[id] = p }
    }
}

/// The last sign-in banner each computer sent (the M2 proof: Tailscale in accept mode sends none).
@MainActor @Observable final class TerminalComputerBanners {
    static let shared = TerminalComputerBanners()
    var last: [String: String] = [:]
}

/// One SSH connection to check a computer just added: connect, sign in, close. Says what happened.
enum TerminalComputerCheck {
    @MainActor static func run(_ e: MacEntry) async -> (ok: Bool, text: String) {
        guard let host = e.terminalAddress, let user = e.sshUser else { return (false, "No address or user name.") }
        let tailscale = e.signIn == .tailscale
        do {
            let key = try TerminalKeys.phoneKey()
            let c = try await SSHConnection.connect(host: host, port: Int(e.port), user: user,
                                                    signIn: tailscale ? .tailscale : .key(key),
                                                    hostKeys: TerminalKeys.hostKeys,
                                                    hostKeyID: sshHostKeyID(mac: e.id, port: Int(e.port)),
                                                    timeout: .seconds(5), signInTimeout: .seconds(15))
            c.closeTransport()
            return (true, "Signed in to \(e.name) as \(user).")
        } catch let changed as HostKeyChanged {
            return (false, changed.description)
        } catch {
            let p = TerminalComputerProblem.diagnose(error, user: user, host: host, port: Int(e.port), tailscale: tailscale)
            return (false, p.text)
        }
    }
}

// MARK: - The list row

struct TerminalComputerRow: View {
    let entry: MacEntry
    let reach: TerminalReach.State
    let enabled: Bool
    let connect: () -> Void
    let settings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: connect) {
                HStack(spacing: 12) {
                    Image(systemName: "terminal")
                        .font(.title2)
                        .foregroundStyle(reach.reachable ? Color.accentColor : .secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.headline)
                        Text(entry.terminalSecondLine).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(reach.color)
                        Text(reach.label)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!reach.reachable || !enabled)
            .accessibilityIdentifier("terminalComputer.\(entry.name)")
            Button("Settings for \(entry.name)", systemImage: "info.circle", action: settings)
                .labelStyle(.iconOnly)
                .font(.title3)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("macSettings.\(entry.name)")
        }
    }
}

// MARK: - Add Terminal Computer (a form sheet, HIG Sheets)

struct AddTerminalComputerSheet: View {
    let store: MacStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = SimulatorSwitches.addTerminalFields?.name ?? ""
    @State private var address = SimulatorSwitches.addTerminalFields?.address ?? ""
    @State private var port = "22"
    @State private var user = SimulatorSwitches.addTerminalFields?.user ?? ""
    @State private var signIn: TerminalSignIn = .tailscale
    @State private var opens: TerminalOpens = .tmux
    @State private var problem: String?
    /// After Add: the entry is saved, and the one SSH check runs and reports here (HIG: validate in place).
    @State private var added: MacEntry?
    @State private var checkResult: (ok: Bool, text: String)?

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("Lab Server", text: $name).accessibilityIdentifier("addTerminalName")
                }
                Section {
                    TextField("my-server", text: $address)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                        .accessibilityIdentifier("addTerminalAddress")
                    LabeledContent("Port") {
                        TextField("22", text: $port).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                            .accessibilityIdentifier("addTerminalPort")
                    }
                } header: {
                    Text("Address")
                } footer: {
                    Text("A Tailscale name (my-server) or a home name (server.local).")
                }
                Section {
                    LabeledContent("User Name") {
                        TextField("Required", text: $user)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                            .accessibilityIdentifier("addTerminalUser")
                    }
                    Picker("Sign In With", selection: $signIn) {
                        ForEach(TerminalSignIn.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("addTerminalSignIn")
                    Picker("Opens", selection: $opens) {
                        ForEach(TerminalOpens.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .accessibilityIdentifier("addTerminalOpens")
                } header: {
                    Text("Sign In")
                } footer: {
                    Text("Tailscale: for a computer with Tailscale SSH on; nothing to install. This iPhone’s Key: the computer must list the key below. tmux keeps the session when the link drops; Login Shell is whatever the computer starts.")
                }
                if signIn == .phoneKey, let k = try? TerminalKeys.phoneKey() {
                    PhoneKeySection(line: k.authorizedKeysLine(comment: "duo-desktop"))
                }
                if let problem {
                    Section { Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
                if added != nil {
                    Section("Check") {
                        if let r = checkResult {
                            Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(r.ok ? Color.green : Color.red)
                                .accessibilityIdentifier("addTerminalCheck")
                            if !r.ok { Text("Saved anyway. Fix it in the computer’s settings (ⓘ).").foregroundStyle(.secondary) }
                        } else {
                            HStack { ProgressView(); Text("Checking the sign-in…").foregroundStyle(.secondary) }
                        }
                    }
                }
            }
            .disabled(added != nil && checkResult == nil)
            .navigationTitle("Add Terminal Computer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if added == nil {
                    ToolbarItem(placement: .cancellationAction) { Button(role: .cancel) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(role: .confirm) { add() } label: { Text("Add").foregroundStyle(.white) }
                            .accessibilityIdentifier("addTerminalConfirm")
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.disabled(checkResult == nil)
                            .accessibilityIdentifier("addTerminalDone")
                    }
                }
            }
        }
    }

    private func add() {
        if let p = TerminalComputerForm.problem(name: name, address: address, user: user, port: port) {
            problem = p; return
        }
        problem = nil
        let e = MacEntry.terminalComputer(name: name, address: address, port: UInt16(port.trimmingCharacters(in: .whitespaces)) ?? 22,
                                          user: user, signIn: signIn, opens: opens)
        store.add(e)
        added = e
        Task {
            let r = AppAccess.isOpen ? await TerminalComputerCheck.run(e) : (false, "Not checked while the app is locked.")
            checkResult = r
        }
    }
}

/// This iPhone's public key, shown with a Copy button.
struct PhoneKeySection: View {
    let line: String
    var body: some View {
        Section("This iPhone’s Key") {
            Text(line).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
            Button("Copy This iPhone’s Key") { UIPasteboard.general.string = line }
                .accessibilityIdentifier("copyPhoneKey")
        }
    }
}

// MARK: - Settings (from ⓘ)

struct TerminalComputerSettingsScreen: View {
    let store: MacStore
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var removing: MacEntry?
    @State private var keyForgotten = false

    var body: some View {
        if let e = store.entry(id) {
            Form {
                Section("Name") {
                    TextField("Name", text: bind(e.name) { v in store.update(id) { $0.name = v } })
                }
                Section("Address") {
                    TextField("my-server", text: bind(e.terminalAddress ?? "") { v in store.update(id) { $0.setTerminalAddress(v) } })
                        .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    LabeledContent("Port") {
                        TextField("22", text: bind(String(e.port)) { v in
                            if let p = UInt16(v), p > 0 { store.update(id) { $0.port = p } }
                        })
                        .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    }
                }
                Section {
                    LabeledContent("User Name") {
                        TextField("Required", text: bind(e.sshUser ?? "") { v in
                            let t = v.trimmingCharacters(in: .whitespaces)
                            store.update(id) { $0.sshUser = t.isEmpty ? nil : t }
                        })
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    }
                    Picker("Sign In With", selection: Binding(get: { e.signIn }, set: { v in store.update(id) { $0.terminalSignIn = v } })) {
                        ForEach(TerminalSignIn.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Picker("Opens", selection: Binding(get: { e.opens }, set: { v in store.update(id) { $0.terminalOpens = v } })) {
                        ForEach(TerminalOpens.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    if let p = TerminalComputerProblems.shared.problems[id] {
                        Label(p.text, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                            .accessibilityIdentifier("terminalComputerProblem")
                    }
                } header: {
                    Text("Sign In")
                } footer: {
                    if e.opens == .loginShell {
                        Text("A dropped link ends a login shell; the app reconnects to a fresh prompt.")
                    }
                }
                if e.signIn == .phoneKey, let k = try? TerminalKeys.phoneKey() {
                    PhoneKeySection(line: k.authorizedKeysLine(comment: "duo-desktop"))
                }
                Section {
                    let stored = TerminalKeys.hostKeys.hostKey(for: sshHostKeyID(mac: id, port: Int(e.port))) != nil && !keyForgotten
                    LabeledContent("Computer’s Key", value: stored ? "Kept from the first sign-in" : "Not yet seen")
                    if stored {
                        Button("Forget Computer’s Key", role: .destructive) {
                            UserDefaults.standard.removeObject(forKey: "terminalHostKey.\(sshHostKeyID(mac: id, port: Int(e.port)))")
                            keyForgotten = true
                        }
                    }
                } footer: {
                    Text("The next sign-in keeps whatever key the computer offers. Forget it only if you know why it changed.")
                }
                Section {
                    Button("Remove Computer", role: .destructive) { removing = e }
                }
            }
            .navigationTitle(e.name)
            .modifier(RemoveMacAlert(mac: $removing) { store.remove($0.id); dismiss() })
        }
    }

    private func bind(_ value: String, _ set: @escaping (String) -> Void) -> Binding<String> {
        Binding(get: { value }, set: set)
    }
}

// MARK: - Which terminal-only computer is open

@MainActor @Observable final class TerminalComputerNav {
    static let shared = TerminalComputerNav()
    /// The open computer's id (nil: the list).
    var openID: String?
}

// MARK: - The session screen

/// A terminal-only computer open: the terminal fills the screen, with the key band over the system keyboard. The top
/// bar has the back caret, a name bubble ("Terminal" under the name, no screen menu) and, in place of the view
/// switch, Hide Keyboard (tapping the terminal brings it back).
struct TerminalOnlyScreen: View {
    let entry: MacEntry
    let store: MacStore
    let leave: () -> Void
    @State private var session: TerminalSession

    init(entry: MacEntry, store: MacStore, leave: @escaping () -> Void) {
        self.entry = entry
        self.store = store
        self.leave = leave
        _session = State(initialValue: TerminalSession.for(mac: entry.id))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TerminalHost(session: session)
                    .overlay(alignment: .top) {
                        if let s = session.status {
                            Text(s).font(.footnote).multilineTextAlignment(.center)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                                .glassEffect(.regular, in: .rect(cornerRadius: 16)).padding(8)
                                .accessibilityIdentifier("terminalStatus")
                        }
                    }
                TerminalKeysBand(session: session)
                    .background(KeyLook.panel)
            }
            .background(Color.black)
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                TopBarItem { BackToMacsButton(action: { session.disconnect(); leave() }) }
                ToolbarSpacer(.fixed, placement: .topBarLeading)
                TopBarItem {
                    TopRowName(mac: entry.name, screen: "Terminal", notice: nil, maxWidth: 220)
                }
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 0, height: 0) }
                    .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.fixed, placement: .topBarLeading)
                TopBarItem {
                    Button {
                        _ = session.view.resignFirstResponder()
                    } label: {
                        Label("Hide Keyboard", systemImage: "keyboard.chevron.compact.down")
                            .labelStyle(.iconOnly)
                            .frame(width: TopRow.itemContent, height: TopRow.itemContent)
                    }
                    .accessibilityIdentifier("hideKeyboard")
                }
            }
        }
        .onAppear {
            session.whenAppOpen { [session, entry] in session.connectComputer(entry) }
        }
    }
}
#endif
