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

// `TerminalSignIn` and `TerminalOpens` are in MacList.swift, outside the Terminal switch, so every build keeps them.

extension TerminalOpens {
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
        var e = MacEntry(name: name.trimmingCharacters(in: .whitespaces))
        e.kind = .terminal
        e.screenSharing = false
        e.terminal = true
        e.sshPort = port
        let a = address.trimmingCharacters(in: .whitespaces)
        e.set(AddressKind.of(a), a)
        e.sshUser = user.trimmingCharacters(in: .whitespaces)
        e.terminalSignIn = signIn
        e.terminalOpens = opens
        return e
    }

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

// The list check (`ComputerReach`, `TCPCheck`) is in Computers.swift, outside the Terminal switch.

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
/// Terminal review: the check stops when the app locks. The pending connect is cancelled at once, and a
/// sign-in that still finishes after the lock is closed and not reported as signed in.
enum TerminalComputerCheck {
    /// Connect and sign in with this attempt, then close (tests swap it).
    typealias Connector = @Sendable (_ host: String, _ port: Int, _ user: String, _ signIn: SSHSignIn, _ hostKeyID: String,
                                     _ attempt: SSHConnectAttempt) async throws -> Void

    static let lockedText = "Not checked: the app locked."

    static let connectAndClose: Connector = { host, port, user, signIn, hostKeyID, attempt in
        let c = try await SSHConnection.connect(host: host, port: port, user: user, signIn: signIn,
                                                hostKeys: TerminalKeys.hostKeys, hostKeyID: hostKeyID,
                                                timeout: .seconds(5), attempt: attempt, signInTimeout: .seconds(15))
        c.closeTransport()
    }

    @MainActor static func run(_ e: MacEntry, connector: Connector = connectAndClose) async -> (ok: Bool, text: String) {
        guard AppAccess.isOpen else { return (false, lockedText) }
        guard let host = e.terminalAddress, let user = e.sshUser else { return (false, "No address or user name.") }
        let tailscale = e.signIn == .tailscale
        let attempt = SSHConnectAttempt()
        let watch = NotificationCenter.default.addObserver(forName: AppAccess.changed, object: nil, queue: nil) { n in
            if (n.object as? AppAccess.State) == .locked { attempt.cancel() }
        }
        defer { NotificationCenter.default.removeObserver(watch) }
        let stopped = { attempt.isCancelled || AppAccess.state == .locked }
        do {
            let signIn: SSHSignIn = tailscale ? .tailscale : .key(try TerminalKeys.phoneKey())
            try await connector(host, Int(e.sshPortValue), user, signIn,
                                sshHostKeyID(mac: e.id, port: Int(e.sshPortValue)), attempt)
            if stopped() { return (false, lockedText) }
            return (true, "Signed in to \(e.name) as \(user).")
        } catch let changed as HostKeyChanged {
            return stopped() ? (false, lockedText) : (false, changed.description)
        } catch {
            if stopped() { return (false, lockedText) }
            let p = TerminalComputerProblem.diagnose(error, user: user, host: host, port: Int(e.sshPortValue), tailscale: tailscale)
            return (false, p.text)
        }
    }
}

// The list row (`ComputerRow`) is in Computers.swift.

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

// MARK: - The Terminal section of a computer without Screen Sharing (its ⓘ page)

/// A Terminal-only (or Terminal and JetKVM) computer's Terminal: its address, port, user name, sign-in and Opens,
/// the phone's key, and the computer's SSH key. Edits go straight into the list.
struct TerminalComputerSection: View {
    let store: MacStore
    let id: String
    @State private var keyForgotten = false
    @State private var address = ""

    var body: some View {
        if let e = store.entry(id) {
            Section {
                // Saved as typed, except blank (the Terminal would have nowhere to go; Remove Terminal does that).
                TextField("my-server", text: Binding(get: { address }, set: { v in
                    address = v
                    if !v.trimmingCharacters(in: .whitespaces).isEmpty { store.update(id) { $0.setTerminalAddress(v) } }
                }))
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .accessibilityIdentifier("settingsTerminalAddress")
                LabeledContent("Port") {
                    TextField("22", text: bind(String(e.sshPortValue)) { v in
                        if let p = UInt16(v), p > 0 { store.update(id) { $0.sshPort = p } }
                    })
                    .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                }
            } header: {
                Text("Terminal")
            }
            .onAppear { address = e.terminalAddress ?? "" }
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
                let stored = TerminalKeys.hostKeys.hostKey(for: sshHostKeyID(mac: id, port: Int(e.sshPortValue))) != nil && !keyForgotten
                LabeledContent("Computer’s Key", value: stored ? "Kept from the first sign-in" : "Not yet seen")
                if stored {
                    Button("Forget Computer’s Key", role: .destructive) {
                        UserDefaults.standard.removeObject(forKey: "terminalHostKey.\(sshHostKeyID(mac: id, port: Int(e.sshPortValue)))")
                        keyForgotten = true
                    }
                }
            } footer: {
                Text("The next sign-in keeps whatever key the computer offers. Forget it only if you know why it changed.")
            }
        }
    }

    private func bind(_ value: String, _ set: @escaping (String) -> Void) -> Binding<String> {
        Binding(get: { value }, set: set)
    }
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
