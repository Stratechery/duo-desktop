#if DUO_TERMINAL
// Terminal-only computers: a computer with a terminal and nothing else, such as a Linux server. Its own kind of list
// entry, its own reach check (a plain TCP connect to the SSH port) and its own screen, so nothing of the Glass Act
// session (`SessionModel`) is involved. Behind DUO_TERMINAL with the rest of the terminal.
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
    /// A PC's are fixed (`correctForPC`): this iPhone's key and its own shell, whatever an older save says.
    var signIn: TerminalSignIn { isPC ? .phoneKey : terminalSignIn ?? .tailscale }
    var opens: TerminalOpens { isPC ? .loginShell : terminalOpens ?? .tmux }

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
    /// The computer refused this iPhone's key for that user; `offersPassword`: it takes a password, so the Add sheet
    /// can add the key with one password sign-in.
    case keyRefused(user: String, offersPassword: Bool)
    /// A Tailscale sign-in reached an ordinary SSH server (no Tailscale banner; it listed publickey/password). Not
    /// Tailscale's refusal: no tailnet rule is involved.
    case ordinarySSH(user: String, offersPassword: Bool)
    /// Nothing is listening on the port.
    case nothingOnPort(Int)
    /// No answer at all.
    case notReachable(host: String)
    /// The computer took the connection but never finished the sign-in.
    case signInTimedOut

    /// Where the words are read. The Add sheet has the one-time password sign-in ("Sign In and Add Key") and the key
    /// right below; the computer's settings and the Terminal screen do not have the password sign-in.
    enum Place { case addSheet, elsewhere }

    static func diagnose(_ error: Error, user: String, host: String, port: Int, tailscale: Bool) -> TerminalComputerProblem {
        if error is SSHSignInTimedOut { return .signInTimedOut }
        if let n = error as? SSHNotTailscale { return .ordinarySSH(user: user, offersPassword: n.offersPassword) }
        switch SSHFailureKind.of(error) {
        case .signInRefused:
            let r = error as? SSHSignInRefused
            return tailscale ? .tailscaleRefused(user: user, said: r?.reason)
                             : .keyRefused(user: user, offersPassword: r?.offersPassword ?? false)
        case .connectionRefused: return .nothingOnPort(port)
        case .notReachable: return .notReachable(host: host)
        }
    }

    /// What is wrong in one short sentence, then exactly what to do, naming each control by the name on screen.
    var text: String { text(.elsewhere) }

    func text(_ place: Place) -> String {
        let byPassword = { (user: String) in
            "Type the password for “\(user)” below and tap Sign In and Add Key. Duo Desktop adds the key for you."
        }
        switch self {
        case let .tailscaleRefused(user, said):
            return "Tailscale did not let this iPhone sign in as “\(user)”. Check User Name. If it is right, your Tailscale settings must allow this iPhone to sign in as that user."
                + (said.map { " (Tailscale: \($0.replacingOccurrences(of: "tailscale: ", with: "")))" } ?? "")
        case let .keyRefused(user, offersPassword):
            let wrong = "This computer does not have this iPhone’s key for “\(user)” yet."
            if place == .addSheet, offersPassword { return wrong + " " + byPassword(user) }
            return wrong + " Tap Copy This iPhone’s Key and add it to the computer’s list of allowed keys for “\(user)”."
        case let .ordinarySSH(user, offersPassword):
            let wrong = "This computer does not use Tailscale SSH."
            if place == .addSheet, offersPassword { return wrong + " " + byPassword(user) }
            return wrong + " Set Sign In With to This iPhone’s Key. "
                + (offersPassword || place == .elsewhere
                   ? "Then tap Copy This iPhone’s Key and add it to the computer’s list of allowed keys for “\(user)”."
                   : "It does not take passwords, so add the key yourself: tap Copy This iPhone’s Key and add it to the computer’s list of allowed keys for “\(user)”.")
        case let .nothingOnPort(port):
            return "Nothing answers on port \(port). Check Port, and that the computer’s SSH server is turned on."
        case let .notReachable(host):
            return "Can’t reach \(host). Check the address, and that this iPhone and the computer are on the same Tailscale or home network."
        case .signInTimedOut:
            return "The computer answered but did not finish signing in. Check that its SSH server is working, then try again."
        }
    }

    /// The made-up failure of `--fake-sign-in-failure` (simulator pictures only).
    static func fake(user: String) -> TerminalComputerProblem? {
        switch SimulatorSwitches.fakeSignInFailure {
        case "ordinary-no-password": .ordinarySSH(user: user, offersPassword: false)
        case "ordinary-password": .ordinarySSH(user: user, offersPassword: true)
        case "key-refused": .keyRefused(user: user, offersPassword: false)
        case "nothing-on-port": .nothingOnPort(22)
        case "tailscale-refused": .tailscaleRefused(user: user, said: nil)
        default: nil
        }
    }

    var retries: Bool {
        switch self {
        case .nothingOnPort, .notReachable, .signInTimedOut: true
        default: false
        }
    }

    /// Fixed in the computer's settings (Sign In With, User Name, the key): the Terminal screen's notice offers them.
    var opensSettings: Bool { !retries }
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
    /// `serverLine` is called with the server's first line when it comes (before the sign-in).
    typealias Connector = @Sendable (_ host: String, _ port: Int, _ user: String, _ signIn: SSHSignIn, _ hostKeyID: String,
                                     _ attempt: SSHConnectAttempt,
                                     _ serverLine: @escaping @Sendable (String) -> Void) async throws -> Void

    static let lockedText = "Not checked: the app locked."
    static var deadlineSeconds: Double = 25
    static func timedOutText(_ host: String) -> String {
        "No answer from \(host) within \(Int(deadlineSeconds)) seconds. Check the address, and that this iPhone and the computer are on the same Tailscale or home network."
    }

    static let connectAndClose: Connector = { host, port, user, signIn, hostKeyID, attempt, serverLine in
        let c = try await SSHConnection.connect(host: host, port: port, user: user, signIn: signIn,
                                                hostKeys: TerminalKeys.hostKeys, hostKeyID: hostKeyID,
                                                timeout: .seconds(5), attempt: attempt, signInTimeout: .seconds(15),
                                                onServerLine: serverLine)
        c.closeTransport()
    }

    @MainActor static func run(_ e: MacEntry, connector: Connector = connectAndClose) async -> (ok: Bool, text: String) {
        let r = await check(e, connector: connector)
        return (r.ok, r.text)
    }

    /// What the check found, and whether the key can be added with one password sign-in.
    struct Outcome: Equatable {
        var ok: Bool
        var text: String
        var problem: TerminalComputerProblem? = nil
        /// The server refused the key (or `none`) and takes a password: the sheet offers the one-time sign-in.
        var passwordCanAddKey = false
        /// It refused and takes no password: the key is shown to copy, the only fallback.
        var keyByHandOnly = false
    }

    /// What the server's first line says the computer is.
    static func system(_ line: String) -> TerminalSystem {
        SimulatorSwitches.sshSaysWindows || SSHServerLine.isWindows(line) ? .windows : .other
    }

    /// Checks `e` and, with `store`, remembers what its server said it is and corrects a PC's saved choices
    /// (`correctForPC`). A PC found by this check is checked again at once with this iPhone's key, when it was asked
    /// for Tailscale (which a PC does not have).
    @MainActor static func check(_ e: MacEntry, store: MacStore?, connector: Connector = connectAndClose) async -> Outcome {
        let seen = ServerLineSeen()
        var o = await check(e, connector: connector, seen: seen)
        guard let store, let line = seen.line else { return o }
        let was = e.signIn
        store.update(e.id) { $0.terminalSystem = system(line); $0.correctForPC() }
        if let now = store.entry(e.id), now.signIn != was, AppAccess.isOpen {
            o = await check(now, connector: connector, seen: ServerLineSeen())
        }
        return o
    }

    @MainActor static func check(_ e: MacEntry, connector: Connector = connectAndClose,
                                 seen: ServerLineSeen = ServerLineSeen()) async -> Outcome {
        let r = await runInner(e, connector: connector, seen: seen)
        var o = Outcome(ok: r.ok, text: r.text, problem: r.problem)
        switch r.problem {
        case let .ordinarySSH(_, pw)?: o.passwordCanAddKey = pw; o.keyByHandOnly = !pw
        case .keyRefused?: o.passwordCanAddKey = r.offersPassword; o.keyByHandOnly = !r.offersPassword
        default: break
        }
        return o
    }

    @MainActor private static func runInner(_ e: MacEntry, connector: Connector, seen: ServerLineSeen)
        async -> (ok: Bool, text: String, problem: TerminalComputerProblem?, offersPassword: Bool) {
        let plain = { (ok: Bool, text: String) in (ok, text, TerminalComputerProblem?.none, false) }
        guard AppAccess.isOpen else { return plain(false, lockedText) }
        guard let host = e.terminalAddress, let user = e.sshUser else { return plain(false, "Type the computer’s address and User Name.") }
        if let p = TerminalComputerProblem.fake(user: user) {
            let pw: Bool = { if case let .ordinarySSH(_, x) = p { return x }; return false }()
            return (false, p.text(.addSheet), p, pw)
        }
        let tailscale = e.signIn == .tailscale
        let attempt = SSHConnectAttempt()
        let watch = NotificationCenter.default.addObserver(forName: AppAccess.changed, object: nil, queue: nil) { n in
            if (n.object as? AppAccess.State) == .locked { attempt.cancel() }
        }
        defer { NotificationCenter.default.removeObserver(watch) }
        // Project notes 2: the whole check ends by a deadline, whatever hangs (name lookup, a server
        // that never finishes the handshake), with a plain message.
        let timedOut = DeadlineFlag()
        let deadline = Task { @MainActor in
            try? await Task.sleep(for: .seconds(deadlineSeconds))
            if !Task.isCancelled { timedOut.passed = true; attempt.cancel() }
        }
        defer { deadline.cancel() }
        let stopped = { attempt.isCancelled || AppAccess.state == .locked }
        let late = { timedOut.passed && AppAccess.isOpen }
        do {
            let signIn: SSHSignIn = tailscale ? .tailscale : .key(try TerminalKeys.phoneKey())
            try await connector(host, Int(e.sshPortValue), user, signIn,
                                sshHostKeyID(mac: e.id, port: Int(e.sshPortValue)), attempt, { seen.line = $0 })
            if late() { return plain(false, timedOutText(host)) }
            if stopped() { return plain(false, lockedText) }
            return plain(true, "Signed in to \(e.name) as \(user)" + (tailscale ? "." : " with this iPhone’s key."))
        } catch let changed as HostKeyChanged {
            return stopped() ? plain(false, late() ? timedOutText(host) : lockedText) : plain(false, changed.description)
        } catch {
            if late() { return plain(false, timedOutText(host)) }
            if stopped() { return plain(false, lockedText) }
            let p = TerminalComputerProblem.diagnose(error, user: user, host: host, port: Int(e.sshPortValue), tailscale: tailscale)
            return (false, p.text(.addSheet), p, (error as? SSHSignInRefused)?.offersPassword ?? false)
        }
    }
}

/// The server's first line, as one check saw it.
final class ServerLineSeen: @unchecked Sendable {
    private let lock = NSLock()
    private var _line: String?
    var line: String? { get { lock.withLock { _line } } set { lock.withLock { _line = newValue } } }
}

// The list row (`ComputerRow`) is in Computers.swift.

// MARK: - Adding this iPhone's key with one password sign-in

///  The app signs in once with the account's password, adds this iPhone's key (`AuthorizedKeys.installCommand`, the
/// Host path's idempotent command) and signs out; the computer then signs in with the key. The password goes only into
/// that one sign-in: never stored, never logged.
@MainActor enum TerminalKeyByPassword {
    struct Outcome: Equatable {
        var ok: Bool
        var text: String
        /// The server takes no password: the key is shown to copy (the only fallback).
        var keyByHandOnly = false
        /// The sign-in found a Windows PC.
        var windows = false
    }

    static func install(_ e: MacEntry, user: String, password: String) async -> Outcome {
        guard AppAccess.isOpen else { return Outcome(ok: false, text: TerminalComputerCheck.lockedText) }
        guard let host = e.terminalAddress else { return Outcome(ok: false, text: "No address.") }
        let line: String
        do { line = try TerminalKeys.phoneKey().authorizedKeysLine(comment: "duo-desktop") } catch {
            return Outcome(ok: false, text: "This iPhone has no key: \(error)")
        }
        let attempt = SSHConnectAttempt()
        let watch = NotificationCenter.default.addObserver(forName: AppAccess.changed, object: nil, queue: nil) { n in
            if (n.object as? AppAccess.State) == .locked { attempt.cancel() }
        }
        defer { NotificationCenter.default.removeObserver(watch) }
        let port = Int(e.sshPortValue)
        let r = await KeyInstallByPassword.run(host: host, port: port, user: user, password: password, keyLine: line,
                                               hostKeys: TerminalKeys.hostKeys,
                                               hostKeyID: sshHostKeyID(mac: e.id, port: port), attempt: attempt)
        if attempt.isCancelled || !AppAccess.isOpen { return Outcome(ok: false, text: TerminalComputerCheck.lockedText) }
        return outcome(r, user: user, name: e.name)
    }

    /// The words for each outcome (pure, tests).
    static func outcome(_ r: KeyInstallByPassword.Outcome, user: String, name: String) -> Outcome {
        // What is wrong, then what to do. Every case the app cannot finish itself shows the key to copy
        // (`keyByHandOnly`), and the words say where it goes, in terms right for a Mac, Linux and Windows alike (no
        // file paths: a Windows administrator's list is in another place).
        let copy = "Tap Copy This iPhone’s Key below and add it to the computer’s list of allowed keys for “\(user)”. Then tap Try Again."
        switch r {
        case let .added(already):
            return Outcome(ok: true, text: already ? "This iPhone’s key was already on \(name) for “\(user)”."
                                                   : "Added this iPhone’s key on \(name) for “\(user)”.")
        case .wrongPassword:
            return Outcome(ok: false, text: "\(name) did not accept that password for “\(user)”. Type it again and tap Sign In and Add Key.")
        case .passwordNotAllowed:
            return Outcome(ok: false, text: "\(name) does not take passwords, so Duo Desktop can’t add the key itself. " + copy,
                           keyByHandOnly: true)
        case let .cannotWrite(detail):
            return Outcome(ok: false, text: "Signed in, but Duo Desktop could not save the key on \(name) (\(detail)). " + copy,
                           keyByHandOnly: true)
        case .windows:
            return Outcome(ok: false, text: "\(name) is a Windows PC, and Duo Desktop can’t add the key there yet. " + copy,
                           keyByHandOnly: true, windows: true)
        case let .failed(why):
            return Outcome(ok: false, text: "Could not sign in to \(name) with the password (\(why)). Check the password and tap Sign In and Add Key again.")
        }
    }
}

/// A PC's Sign In With and Opens: one way in and one shell, as plain lines, not pickers. Windows' SSH server starts the
/// PC's default shell (PowerShell, or Command Prompt where the PC is set so); the app cannot tell which before signing
/// in, so the footer says both.
struct PCTerminalRows: View {
    static let shell = "PowerShell"
    static let footer = "A Windows PC opens PowerShell or Command Prompt, as the PC is set. Its session ends when the link drops: the app reconnects to a fresh prompt. Duo Desktop signs in to a PC with this iPhone’s key."
    var body: some View {
        LabeledContent("Sign In With", value: TerminalSignIn.phoneKey.label)
            .accessibilityIdentifier("pcSignIn")
        LabeledContent("Opens", value: Self.shell)
            .accessibilityIdentifier("pcOpens")
    }
}

/// This iPhone's public key, shown with a Copy button.
struct PhoneKeySection: View {
    let line: String
    /// Where the key goes, true for a Mac, Linux and Windows.
    static let footer = "The computer lets in only the keys on its list of allowed keys for each account (usually a file named authorized_keys). Add this whole line to that list, on a line of its own."
    var body: some View {
        Section {
            Text(line).font(.caption.monospaced()).textSelection(.enabled).lineLimit(3).truncationMode(.middle)
            Button("Copy This iPhone’s Key") { UIPasteboard.general.string = line }
                .accessibilityIdentifier("copyPhoneKey")
        } header: {
            Text("This iPhone’s Key")
        } footer: {
            Text(Self.footer)
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
                if e.isPC {
                    PCTerminalRows()
                } else {
                    Picker("Sign In With", selection: Binding(get: { e.signIn }, set: { v in store.update(id) { $0.terminalSignIn = v } })) {
                        ForEach(TerminalSignIn.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                    Picker("Opens", selection: Binding(get: { e.opens }, set: { v in store.update(id) { $0.terminalOpens = v } })) {
                        ForEach(TerminalOpens.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.menu)
                }
                if let p = TerminalComputerProblems.shared.problems[id] {
                    Label(p.text, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        .accessibilityIdentifier("terminalComputerProblem")
                }
            } header: {
                Text("Sign In")
            } footer: {
                if e.isPC {
                    Text(PCTerminalRows.footer)
                } else if e.opens == .loginShell {
                    Text("A dropped link ends a login shell; the app reconnects to a fresh prompt.")
                }
            }
            // Opening a PC's settings corrects a Tailscale or tmux choice saved before it was known to be a PC.
            .onAppear { store.update(id) { $0.correctForPC() } }
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

/// A computer open in Terminal from the list, with no Glass Act session, whether or not it also has Screen Sharing: the
/// terminal fills the screen, with the key band over the system keyboard. The top bar has the back caret, a name bubble
/// ("Terminal" under the name, no screen menu), the view button when the computer has other ways in (`WayViewSwitch`,
/// the session's own views control). No Hide Keyboard. While it cannot connect, the status offers the computer's other
/// ways in ("Open in JetKVM Instead").
struct TerminalOnlyScreen: View {
    let entry: MacEntry
    let store: MacStore
    let leave: () -> Void
    @State private var session: TerminalSession
    /// The status has stayed up a while (not connected): offer the other ways in.
    @State private var offerOthers = false
    /// The notice text closed with its close button (it comes back when the words change, and goes when it signs in).
    @State private var dismissed: String?
    @State private var showSettings = false
    /// How long "not connected" lasts before the other ways in are offered (a refused sign-in or a dead address shows
    /// its words by then; a link that is only slow to come up does not flash the offer).
    static let offerAfterSeconds = 4.0

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
                        if let s = session.status, s != dismissed {
                            TerminalNotice(text: s, entry: current, offerOthers: offerOthers,
                                           settings: problem?.opensSettings == true,
                                           openSettings: { showSettings = true },
                                           close: { dismissed = s },
                                           leave: leaveTerminal)
                        }
                    }
                // The key row on the app's keyboard gray (`KeyLook.panel`, the Screen Sharing session's band panel),
                // running edge to edge and on down behind the system keyboard (every safe area, the keyboard's
                // included), so no white or black shows at the sides, under the row or outside the keyboard's rounded
                // top corners.
                TerminalKeysBand(session: session)
                    .background { Rectangle().fill(KeyLook.panel).ignoresSafeArea() }
            }
            .background(TerminalTopBar.behind.colour)
            .modifier(TerminalTopBar(entry: current, views: views,
                                     back: { leaveTerminal(); leave() }))
            .sheet(isPresented: $showSettings, onDismiss: {
                // A changed Sign In With, User Name or Opens connects again (`connectComputer` skips an unchanged one).
                dismissed = nil
                if !current.hasScreenSharing { session.connectComputer(current, learned: learn, answered: learnSystem) }
            }) {
                NavigationStack {
                    ComputerSettingsScreen(store: store, id: entry.id, chosen: nil)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) { Button("Done") { showSettings = false } }
                        }
                }
            }
        }
        .onAppear {
            session.whenAppOpen { [session, entry, store] in
                if entry.hasScreenSharing {
                    // A Mac with Glass Act Host: its Terminal exactly as in its session (this iPhone's key, the
                    // Host asked for the key only over a running session, which there is none of here).
                    TerminalKeyByHost.thenConnect(session, entry: entry, store: store)
                } else {
                    store.update(entry.id) { $0.correctForPC() }
                    session.connectComputer(store.entry(entry.id) ?? entry, learned: learn, answered: learnSystem)
                }
            }
        }
        .task(id: session.status == nil) {
            offerOthers = false
            guard session.status != nil else { return }
            try? await Task.sleep(for: .seconds(Self.offerAfterSeconds))
            if !Task.isCancelled, session.status != nil { offerOthers = true }
        }
    }

    /// The server said what the computer is: remembered, and a PC's saved choices corrected (`correctForPC`). When that
    /// changes how it signs in (Tailscale was saved), it connects again with this iPhone's key.
    private func learn(_ s: TerminalSystem) {
        guard current.terminalSystem != s else { return }
        let was = current.signIn
        store.update(entry.id) { $0.terminalSystem = s; $0.correctForPC() }
        if current.signIn != was { session.connectComputer(current, learned: learn, answered: learnSystem) }
    }

    /// The computer said what it is: remembered for the list's mark, and synced.
    private func learnSystem(_ s: ComputerSystem) {
        guard current.unameSystem != s else { return }
        store.update(entry.id) { $0.unameSystem = s }
    }

    /// Why the last sign-in failed, when it is a terminal-only computer's.
    private var problem: TerminalComputerProblem? { TerminalComputerProblems.shared.problems[entry.id] }

    /// The computer as saved now (its ways in may have changed in its settings).
    private var current: MacEntry { store.entry(entry.id) ?? entry }

    /// The views control.
    private var views: WayViewSwitch {
        WayViewSwitch(entry: current, current: .terminal, normalPhone: PhoneKind.current, leave: leaveTerminal)
    }

    private func leaveTerminal() { session.disconnect() }
}

/// The notice over the terminal while it is not connected. Always on the terminal's dark look, so it is drawn in the
/// dark appearance: Apple's regular material with primary label text, and standard bordered buttons tinted white (build
/// 81's glass took the light appearance over black: black text on grey, a dim orange button). A standard close button
/// (`ButtonRole.close`) hides it; it also goes by itself once the sign-in works. The other ways in are named as this
/// computer has them (a PC's is Remote Desktop, never Screen Sharing).
struct TerminalNotice: View {
    let text: String
    let entry: MacEntry
    let offerOthers: Bool
    /// The fix is in the computer's settings (Sign In With, User Name, the key).
    let settings: Bool
    let openSettings: () -> Void
    let close: () -> Void
    let leave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Text(text).font(.subheadline).foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("terminalStatus")
                Button(role: .close, action: close)
                    .buttonStyle(.bordered).buttonBorderShape(.circle).controlSize(.small)
                    .accessibilityIdentifier("terminalNoticeClose")
            }
            if settings || offerOthers {
                HStack(spacing: 8) {
                    if settings {
                        Button("Open Settings", systemImage: "gearshape", action: openSettings)
                            .buttonStyle(.bordered).tint(.white)
                            .accessibilityIdentifier("terminalOpenSettings")
                    }
                    if offerOthers { OtherWaysOffer(entry: entry, current: .terminal, onDark: true, leave: leave) }
                }
                .controlSize(.small)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
        .environment(\.colorScheme, .dark)
        .padding(8)
    }
}

/// The Terminal screen's top bar. The Duo: back, the computer's name as the bar's title (`DuoTitleBar`), then the views
/// switch as the trailing item. A normal iPhone: the same bar, with its views drop-down.
struct TerminalTopBar: ViewModifier {
    /// The Terminal screen is black behind the bar in light and dark mode alike.
    static let behind = BarBackdrop.black
    let entry: MacEntry
    let views: WayViewSwitch
    let back: () -> Void

    /// The line under the name: a PC's shell ("PowerShell") instead of "Terminal".
    static func subtitle(_ e: MacEntry) -> String { e.isPC ? PCTerminalRows.shell : "Terminal" }

    func body(content: Content) -> some View {
        // One bar for the Duo and a normal iPhone; `views` is the normal iPhone's drop-down there.
        content
            .modifier(DuoTitleBar(title: entry.name, subtitle: Self.subtitle(entry), hidden: false, behind: Self.behind, back: back) { EmptyView() })
            .toolbar {
                if WayViewSwitch.shows(views.entry) { TopBarViewsItem { views } }
                TopBarStandIn(width: SimulatorSwitches.topBarReserve ?? 0)
            }
    }
}
#endif
