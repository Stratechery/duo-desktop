import Foundation
import GlassActTransport
import GlassActWire
import Observation
import Security

/// Which of a Mac's two addresses (project notes §2).
enum AddressKind: String, Codable, CaseIterable, Hashable {
    case home, tailscale

    var label: String {
        switch self {
        case .home: "Home network"
        case .tailscale: "Tailscale"
        }
    }

    /// Where a typed or found address is filed: `.local`, `localhost` or a private home address is Home, anything
    /// else Tailscale (plan §5.2).
    static func of(_ host: String) -> AddressKind {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if h == "localhost" || h.hasSuffix(".local") { return .home }
        let parts = h.split(separator: ".").compactMap { Int($0) }
        if parts.count == 4 {
            switch (parts[0], parts[1]) {
            case (10, _), (127, _), (192, 168): return .home
            case (172, 16...31): return .home
            default: return .tailscale
            }
        }
        return .tailscale
    }
}

/// What a list entry was before one computer could have several ways in (project notes, terminal-only computers, §1): a Mac
/// running Glass Act Host, or a computer reached only over SSH. Entries saved before this existed have no kind and
/// read as a Mac. Now only read for the carry-over, and still written so an older build reads the list as before.
enum EntryKind: String, Codable, Hashable {
    case mac, terminal
}

/// One way in to a computer (project notes, one computer with any connection), in the fallback order.
enum WayIn: String, Codable, CaseIterable, Hashable, Identifiable {
    case screenSharing, terminal, jetkvm

    var id: String { rawValue }

    var label: String {
        switch self {
        case .screenSharing: "Screen Sharing"
        case .terminal: "Terminal"
        case .jetkvm: "JetKVM"
        }
    }

    /// The ways in this build can show (review finding 4: the plain, Terminal-only, JetKVM-only and full builds). A
    /// way in a build cannot show keeps its saved settings; it is only not offered.
    static var inThisBuild: [WayIn] {
        var w: [WayIn] = [.screenSharing]
        #if DUO_TERMINAL
        w.append(.terminal)
        #endif
        #if DUO_JETKVM
        w.append(.jetkvm)
        #endif
        return w
    }
}

/// How a computer's Terminal signs in. Outside the Terminal switch so a build without it keeps the setting.
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

/// What a computer's Terminal opens. Outside the Terminal switch so a build without it keeps the setting.
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
}

/// One computer, stored on the phone (plan §4; project notes, one computer with any connection). The id is fixed, so renaming it
/// or changing its addresses keeps everything (SSH trust, JetKVM and unlock passwords are keyed by it). A computer
/// has any of three ways in: Screen Sharing (Glass Act Host), Terminal (SSH) and JetKVM. Every field is stored in
/// every build, so a build without the Terminal or the JetKVM keeps their settings.
struct MacEntry: Identifiable, Hashable, Codable {
    var id: String = UUID().uuidString
    var name: String
    var home: String?
    var tailscale: String?
    /// Glass Act's port (Screen Sharing). The Terminal's port is `sshPort`.
    var port: UInt16 = 4433
    /// The Mac's Glass Act key (SHA-256 of its public key), learned the first time either address answers.
    var key: String?
    /// The address that worked last (used when both answer: the owner agreed 2026-11-21).
    var lastAddress: AddressKind?
    /// The session view last used on this Mac (SessionView raw value).
    var view: String?
    /// "Unlock Automatically" is on (the password itself is only in the Keychain, `MacPasswordKeychain`).
    var autoUnlock: Bool?
    /// The slot for a custom layout per Mac; only "standard" exists.
    var layout: String = "standard"
    var lastUsed: Date?
    /// Before ways in: nil = a Mac, `.terminal` = terminal only. Read by `carriedOver()`; kept written for older builds.
    var kind: EntryKind?
    /// Screen Sharing is set up (Glass Act Host). nil only in entries saved before ways in (see `carriedOver()`).
    var screenSharing: Bool?
    /// The Terminal is set up (the Mac's Terminal switch, `terminalOn`); nil read as off.
    var terminal: Bool?
    /// The account the Terminal signs in as over SSH.
    var sshUser: String?
    /// The Terminal's SSH port (22 when nil).
    var sshPort: UInt16?
    /// How the Terminal signs in and what it opens.
    var terminalSignIn: TerminalSignIn?
    var terminalOpens: TerminalOpens?
    /// JetKVM is set up (the JetKVM switch, `jetkvmOn`); nil read as off.
    var jetkvm: Bool?
    /// The JetKVM's address (its password is in the Keychain, never here).
    var jetkvmAddress: String?

    /// The entry in today's shape (review finding 1, the exact mapping). Already carried over: unchanged.
    /// - A Mac (no kind, or `.mac`): Screen Sharing with its own address, port and key; Terminal and JetKVM as its
    ///   switches were. Its Terminal keeps what it always did: SSH port 22, this iPhone's key, tmux.
    /// - A terminal-only computer: Terminal only, with its own SSH port, sign-in and Opens (absent sign-in was read
    ///   as Tailscale, absent Opens as tmux); Glass Act's port goes back to its default for Screen Sharing later.
    func carriedOver() -> MacEntry {
        guard screenSharing == nil else { return self }
        var e = self
        if kind == .terminal {
            e.screenSharing = false
            e.terminal = true
            e.sshPort = port
            e.port = MacEntry(name: "").port
            e.terminalSignIn = terminalSignIn ?? .tailscale
            e.terminalOpens = terminalOpens ?? .tmux
        } else {
            e.screenSharing = true
            e.sshPort = sshPort ?? 22
            e.terminalSignIn = terminalSignIn ?? .phoneKey
            e.terminalOpens = terminalOpens ?? .tmux
        }
        e.kind = e.screenSharing == true ? nil : .terminal
        return e
    }

    var hasScreenSharing: Bool { screenSharing ?? (kind != .terminal) }
    var hasTerminal: Bool { terminal ?? false }
    /// The JetKVM switch is on and its address is set (what the view switch has always required).
    var hasJetKVM: Bool { (jetkvm ?? false) && jetkvmHost != nil }

    /// The ways in this computer has, in the fallback order.
    var waysIn: [WayIn] {
        WayIn.allCases.filter {
            switch $0 {
            case .screenSharing: hasScreenSharing
            case .terminal: hasTerminal
            case .jetkvm: hasJetKVM
            }
        }
    }

    /// The ways in this computer has that this build can show.
    var waysInThisBuild: [WayIn] { waysIn.filter(WayIn.inThisBuild.contains) }

    /// The list row's second line: what it has, in order ("Screen Sharing · Terminal · JetKVM").
    var waysLine: String { waysInThisBuild.map(\.label).joined(separator: " · ") }

    /// The ways in that are set up, in any build (the JetKVM counts once its switch is on, address or not). The ⓘ
    /// page shows a section for each; removing the last of these removes the computer (milestone 2).
    var setUpWays: [WayIn] {
        WayIn.allCases.filter {
            switch $0 {
            case .screenSharing: hasScreenSharing
            case .terminal: hasTerminal
            case .jetkvm: jetkvm ?? false
            }
        }
    }

    /// Milestone 2's minimum opening rule for a computer without Screen Sharing: the first way in this build has
    /// after Screen Sharing (Terminal, then JetKVM). nil: it has Screen Sharing (a Glass Act session), or nothing
    /// this build can open. Opens In and the full rules are milestone 3.
    var opensOnItsOwn: WayIn? {
        guard !hasScreenSharing else { return nil }
        return waysInThisBuild.first { $0 != .screenSharing }
    }

    /// This entry with one way in taken away (the ⓘ page's Remove). Screen Sharing takes its key, last address,
    /// saved view and Unlock Automatically with it (the unlock password itself is deleted by `MacStore.removeWay`);
    /// the addresses stay, since the Terminal shares them. Terminal and JetKVM keep their typed fields, so adding
    /// them back starts filled in (the JetKVM's password is deleted by `MacStore.removeWay`).
    func removing(_ way: WayIn) -> MacEntry {
        var e = self
        switch way {
        case .screenSharing:
            e.screenSharing = false
            e.key = nil
            e.lastAddress = nil
            e.view = nil
            e.autoUnlock = nil
        case .terminal:
            e.terminal = false
        case .jetkvm:
            e.jetkvm = false
        }
        e.kind = e.hasScreenSharing ? nil : .terminal
        return e
    }

    /// The Terminal's SSH port.
    var sshPortValue: UInt16 { sshPort ?? 22 }

    /// The JetKVM's address as typed (host name or IP; a scheme or path is ignored), nil when blank.
    var jetkvmHost: String? {
        guard let raw = jetkvmAddress?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        var h = raw
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        return h.isEmpty ? nil : h
    }

    func address(_ kind: AddressKind) -> String? {
        let a = (kind == .home ? home : tailscale)?.trimmingCharacters(in: .whitespaces)
        return a?.isEmpty == false ? a : nil
    }

    /// The addresses this entry has, Tailscale first.
    var addresses: [(kind: AddressKind, host: String)] {
        [AddressKind.tailscale, .home].compactMap { k in address(k).map { (k, $0) } }
    }

    mutating func set(_ kind: AddressKind, _ host: String?) {
        let v = host?.trimmingCharacters(in: .whitespaces)
        let value = v?.isEmpty == false ? v : nil
        if kind == .home { home = value } else { tailscale = value }
    }
}

/// The list's own file in the app's storage (plan §3). Not synchronised anywhere; the OS backup follows the
/// phone's settings (Reviewer wording correction).
@MainActor @Observable
final class MacStore {
    /// A fresh install starts with no Macs (the owner 2026-11-21: "There absolutely should not be any hard coding of
    /// [a Mac], even to start the list. This app needs to be usable by someone else on their Macs."). Only the
    /// simulator gets this Mac's own test host, so screen proofs can run; a device build has none.
    static var starting: [MacEntry] {
        #if targetEnvironment(simulator)
        var e = MacEntry(name: "Test host", port: 4533)
        e.set(.home, "localhost")
        return [e]
        #else
        return []
        #endif
    }

    static let shared = MacStore(
        url: AppPaths.dataDirectory.appendingPathComponent("duo-macs.json"),
        defaults: .standard,
        knownHosts: KnownHosts(url: AppPaths.dataDirectory.appendingPathComponent(IdentityFiles.knownHosts)))

    /// Every entry, in the order added (what the file holds).
    private(set) var entries: [MacEntry] = []
    /// The computers with Screen Sharing only: everything Glass Act (probes, sessions, the outer screen, cold
    /// connect, key matching, auto-unlock) reads this, so a computer without Glass Act never reaches any of it.
    var macs: [MacEntry] { entries.filter(\.hasScreenSharing) }
    /// The Computers list (project notes, one computer with any connection): every computer with a way in this build can show, in
    /// the order added. One this build cannot show at all stays saved, untouched, and out of the list.
    var computers: [MacEntry] { entries.filter { !$0.waysInThisBuild.isEmpty } }
    /// The computers without Screen Sharing (they open on their own screens, not in a Glass Act session).
    var withoutScreenSharing: [MacEntry] { computers.filter { !$0.hasScreenSharing } }
    private let url: URL
    private let defaults: UserDefaults
    /// What happened at load, for the log ("loaded 4", "carried over 4").
    private(set) var loadNote = ""

    init(url: URL, defaults: UserDefaults, knownHosts: KnownHosts) {
        self.url = url
        self.defaults = defaults
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([MacEntry].self, from: data) {
            // Every entry in today's shape (project notes, one computer with any connection: nothing re-added, no new sign-ins),
            // saved back at once when anything was carried over.
            entries = list.map { $0.carriedOver() }
            let carried = zip(list, entries).filter { $0 != $1 }.count
            loadNote = "loaded \(list.count) entries" + (carried > 0 ? ", carried over \(carried)" : "")
            if carried > 0 { save() }
        } else {
            // No stored list: nothing is invented (a stored list, such as one carried over by an earlier build, is
            // kept untouched above).
            entries = Self.starting.map { $0.carriedOver() }
            loadNote = "no stored list: \(entries.count) Macs"
        }
    }

    func entry(_ id: String) -> MacEntry? { entries.first { $0.id == id } }

    /// The entry already holding this Mac key, if any ("Same Mac twice", plan §5.2).
    func entry(withKey key: String) -> MacEntry? { macs.first { $0.key != nil && $0.key == key } }

    func add(_ e: MacEntry) {
        entries.append(e.carriedOver())
        save()
    }

    func update(_ id: String, _ change: (inout MacEntry) -> Void) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        var e = entries[i]
        change(&e)
        // Older builds read only `kind`: keep it saying whether Glass Act is there.
        e.kind = e.hasScreenSharing ? nil : .terminal
        guard e != entries[i] else { return }
        entries[i] = e
        save()
    }

    /// Where the Macs' passwords are (tests pass their own).
    @ObservationIgnored var passwords: MacPasswordKeeping = MacPasswordKeychain.shared

    func remove(_ id: String) {
        // Removing the Mac deletes its saved password (project notes).
        passwords.delete(macID: id)
        AutoUnlockFailures.set(id, failed: false, in: defaults)
        entries.removeAll { $0.id == id }
        save()
        #if DUO_JETKVM
        JetKVMSettings.macRemoved(id)
        #endif
    }

    /// Takes one way in away from a computer (the ⓘ page). The last way in removes the computer itself (the page
    /// asks first). Returns true when the computer was removed.
    @discardableResult
    func removeWay(_ way: WayIn, from id: String) -> Bool {
        guard let e = entry(id), e.setUpWays.contains(way) else { return false }
        if e.setUpWays == [way] {
            remove(id)
            return true
        }
        switch way {
        case .screenSharing:
            // As removing the Mac did (project notes): its saved password goes with its Screen Sharing.
            passwords.delete(macID: id)
            AutoUnlockFailures.set(id, failed: false, in: defaults)
        case .jetkvm:
            #if DUO_JETKVM
            JetKVMSettings.macRemoved(id)
            #endif
        case .terminal:
            break
        }
        update(id) { $0 = $0.removing(way) }
        return false
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            SessionModel.log.error("couldn't save the Mac list: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The list as shown: each Mac's entry, checked live on all its addresses with Glass Act's sign-in query, which
/// carries no credentials, always against the entry's own key.
@MainActor @Observable
final class MacList {
    enum Reach: Equatable {
        case checking
        case ready
        case signInNeeded
        case askOnMac
        case closed
        case notReachable
        /// An address answered with a different Mac key than the entry's: refused (plan §2).
        case wrongMac
        /// The Simulator never dials the real Macs (overnight builds keep off the real Macs).
        case notChecked

        var label: String {
            switch self {
            case .checking: "Checking…"
            case .ready: "Ready"
            case .signInNeeded: "Sign in needed"
            case .askOnMac: "Asks on the Mac"
            case .closed: "Not taking new viewers"
            case .notReachable: "Not reachable"
            case .wrongMac: "This isn’t the Mac you added."
            case .notChecked: "Not checked in the Simulator"
            }
        }

        /// A Glass Act Host with the right key answered.
        var answered: Bool { [.ready, .signInNeeded, .askOnMac, .closed].contains(self) }
        var reachable: Bool { answered }
    }

    let store: MacStore
    var macs: [MacEntry] { store.macs }
    private(set) var reach: [String: Reach] = [:]
    /// Which address each Mac answered on (the second line of its row, and where Connect dials).
    private(set) var chosen: [String: AddressKind] = [:]
    private var perAddress: [String: [AddressKind: Reach]] = [:]
    private var generation = 0

    init(store: MacStore = .shared) { self.store = store }

    func probeAll(identity: SecIdentity?) {
        generation += 1
        let g = generation
        for mac in macs {
            perAddress[mac.id] = [:]
            let addresses = mac.addresses.filter { Self.mayProbe($0.host) }
            if addresses.isEmpty {
                reach[mac.id] = mac.addresses.isEmpty ? .notReachable : .notChecked
                chosen[mac.id] = nil
                continue
            }
            // Keep the last answer on screen while rechecking: setting every row back to "Checking…" disabled
            // the rows each time the list appeared (after every session), so taps in that moment did nothing.
            if reach[mac.id] == nil || reach[mac.id] == .notReachable { reach[mac.id] = .checking }
            for (kind, host) in addresses {
                Self.check(host: host, port: mac.port, pin: mac.key ?? "", identity: identity, timeout: 2) {
                    [weak self] outcome in
                    guard let self, self.generation == g else { return }
                    self.perAddress[mac.id, default: [:]][kind] = Self.reach(for: outcome)
                    let all = self.perAddress[mac.id] ?? [:]
                    let last = self.store.entry(mac.id)?.lastAddress
                    let pick = Self.choose(all, expected: addresses.count, last: last)
                    self.reach[mac.id] = pick.reach
                    self.chosen[mac.id] = pick.kind
                }
            }
        }
    }

    /// Simulator runs only dial this Mac's own test hosts.
    static func mayProbe(_ host: String) -> Bool {
        #if targetEnvironment(simulator)
        return host == "localhost" || host.hasPrefix("127.")
        #else
        return true
        #endif
    }

    /// From each address's answer so far, what the row shows and which address Connect uses: an address that
    /// answered with the right key wins; when both answered, the one that worked last (the owner agreed 2026-11-21);
    /// a wrong key at an address that is the only answer refuses the Mac.
    static func choose(_ answers: [AddressKind: Reach], expected: Int, last: AddressKind?) -> (reach: Reach, kind: AddressKind?) {
        let good = AddressKind.allCases.filter { answers[$0]?.answered == true }
        if let last, good.contains(last) { return (answers[last]!, last) }
        if let first = good.first {
            // Wait for the other address when it might be the one used last.
            if answers.count < expected, let last, answers[last] == nil { return (.checking, nil) }
            return (answers[first]!, first)
        }
        if answers.count < expected { return (.checking, nil) }
        if answers.values.contains(.wrongMac) { return (.wrongMac, nil) }
        return (.notReachable, nil)
    }

    static func reach(for outcome: SignInClient.Outcome) -> Reach {
        if outcome.hostKeyMismatch { return .wrongMac }
        switch outcome.response?.status {
        case .approved?: return .ready
        case .signInAvailable?: return .signInNeeded
        case .askOnHost?: return .askOnMac
        case .closed?: return .closed
        default: return .notReachable
        }
    }

    /// One Glass Act sign-in query (no password), answered on the main actor.
    static func check(host: String, port: UInt16, pin: String, identity: SecIdentity?, timeout: TimeInterval,
                      _ done: @escaping @MainActor (SignInClient.Outcome) -> Void) {
        SignInClient.send(SignInRequest(op: .query, device: SessionModel.deviceName), host: host, port: port,
                          pinnedFingerprint: pin, identity: identity, timeout: timeout) { outcome in
            DispatchQueue.main.async { MainActor.assumeIsolated { done(outcome) } }
        }
    }
}
