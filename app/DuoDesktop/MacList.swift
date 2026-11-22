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

/// One Mac, stored on the phone (plan §4). The id is fixed, so renaming the Mac or changing its addresses keeps
/// everything. The Mac's key lives here, not with an address: every address is checked against the same key.
struct MacEntry: Identifiable, Hashable, Codable {
    var id: String = UUID().uuidString
    var name: String
    var home: String?
    var tailscale: String?
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
    #if DUO_TERMINAL
    /// The Terminal switch (Terminal.swift: `terminalOn`); nil in entries saved before it existed, read as off.
    var terminal: Bool?
    /// The Mac account the terminal signs in as over SSH (M2 on).
    var sshUser: String?
    #endif
    #if DUO_JETKVM
    /// The JetKVM switch (JetKVM.swift: `jetkvmOn`); nil in entries saved before it existed, read as off.
    var jetkvm: Bool?
    /// The JetKVM's address (its password is in the Keychain, never here).
    var jetkvmAddress: String?
    #endif

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
/// phone's settings (reviewer wording correction).
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

    private(set) var macs: [MacEntry] = []
    private let url: URL
    private let defaults: UserDefaults
    /// What happened at load, for the log ("loaded 4", "carried over 4").
    private(set) var loadNote = ""

    init(url: URL, defaults: UserDefaults, knownHosts: KnownHosts) {
        self.url = url
        self.defaults = defaults
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([MacEntry].self, from: data) {
            macs = list
            loadNote = "loaded \(list.count) Macs"
        } else {
            // No stored list: nothing is invented (a stored list, such as one carried over by an earlier build, is
            // kept untouched above).
            macs = Self.starting
            loadNote = "no stored list: \(macs.count) Macs"
        }
    }

    func entry(_ id: String) -> MacEntry? { macs.first { $0.id == id } }

    /// The entry already holding this Mac key, if any ("Same Mac twice", plan §5.2).
    func entry(withKey key: String) -> MacEntry? { macs.first { $0.key != nil && $0.key == key } }

    func add(_ e: MacEntry) {
        macs.append(e)
        save()
    }

    func update(_ id: String, _ change: (inout MacEntry) -> Void) {
        guard let i = macs.firstIndex(where: { $0.id == id }) else { return }
        var e = macs[i]
        change(&e)
        guard e != macs[i] else { return }
        macs[i] = e
        save()
    }

    /// Where the Macs' passwords are (tests pass their own).
    @ObservationIgnored var passwords: MacPasswordKeeping = MacPasswordKeychain.shared

    func remove(_ id: String) {
        // Removing the Mac deletes its saved password (project notes).
        passwords.delete(macID: id)
        AutoUnlockFailures.set(id, failed: false, in: defaults)
        macs.removeAll { $0.id == id }
        save()
        #if DUO_JETKVM
        JetKVMSettings.macRemoved(id)
        #endif
    }

    private func save() {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(macs).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
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
        /// The Simulator never dials the real Macs (overnight builds keep off real Macs).
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
