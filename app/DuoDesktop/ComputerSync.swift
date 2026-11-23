import Foundation
import GlassActTransport
import Observation
import Security

// The computer list syncing through iCloud (project notes, Part A, with the reviewer's corrections
// in its §A9). the owner 2026-11-22: "CloudKit"; "Newest wins"; on removing, "Maybe ask if it deletes everywhere?"; "On".
//
// This file holds the rules and nothing of CloudKit, so the tests can run them with two lists and a pretend iCloud:
// - `SyncedComputer`: the fields that sync (the A3 allow-list). Passwords, private keys and Keychain items are not in
//   it, and never can be: it is built field by field from `MacEntry`, which itself holds none of them.
// - `CloudComputer`: one record in iCloud: the user's edit time and the fields, or a dated removal mark.
// - `ComputerSync`: newest change wins per computer, the first join, removal from all devices or this iPhone only, and
//   which iCloud account the state belongs to. `CloudComputerSync` (CloudComputerSync.swift) carries records to and
//   from CloudKit.

/// The fields of a computer that sync (plan §A3, an allow-list). Everything else stays on this iPhone: last used,
/// last address, view, Unlock Automatically, the hidden mark, and every secret (which live in the Keychain only).
/// The choices are stored as their raw words, so a record from a newer build with a choice this one lacks still reads.
struct SyncedComputer: Codable, Equatable {
    var name: String
    var home: String?
    var tailscale: String?
    var port: UInt16
    /// The Mac's Glass Act key (a fingerprint of its public key, not a secret): the second iPhone checks the Mac
    /// against it from the first connection.
    var key: String?
    var screenSharing: Bool
    var terminal: Bool
    var sshUser: String?
    var sshPort: UInt16?
    var terminalSignIn: String?
    var terminalOpens: String?
    var jetkvm: Bool
    var jetkvmAddress: String?
    /// Whether the JetKVM has a password (typed on some iPhone). Only this yes/no syncs; the password stays in that
    /// iPhone's Keychain. Another iPhone without it shows JetKVM as "needs setting up here".
    var jetkvmPassword: Bool?
    var opensIn: String?
    var layout: String

    init(_ e: MacEntry) {
        name = e.name
        home = e.home
        tailscale = e.tailscale
        port = e.port
        key = e.key
        screenSharing = e.hasScreenSharing
        terminal = e.hasTerminal
        sshUser = e.sshUser
        sshPort = e.sshPort
        terminalSignIn = e.terminalSignIn?.rawValue
        terminalOpens = e.terminalOpens?.rawValue
        jetkvm = e.jetkvm ?? false
        jetkvmAddress = e.jetkvmAddress
        jetkvmPassword = e.jetkvmPassword
        opensIn = e.opensIn?.rawValue
        layout = e.layout
    }

    /// Writes these fields into `e`, keeping its own (id, last used, last address, view, Unlock Automatically).
    /// Screen Sharing taken away elsewhere takes this iPhone's per-Mac state with it, as Remove Screen Sharing does.
    func apply(to e: inout MacEntry) {
        e.name = name
        e.home = home
        e.tailscale = tailscale
        e.port = port
        e.key = key
        e.screenSharing = screenSharing
        e.terminal = terminal
        e.sshUser = sshUser
        e.sshPort = sshPort
        e.terminalSignIn = terminalSignIn.flatMap(TerminalSignIn.init(rawValue:)) ?? e.terminalSignIn
        e.terminalOpens = terminalOpens.flatMap(TerminalOpens.init(rawValue:)) ?? e.terminalOpens
        e.jetkvm = jetkvm
        e.jetkvmAddress = jetkvmAddress
        e.jetkvmPassword = jetkvmPassword
        e.opensIn = opensIn.flatMap(WayIn.init(rawValue:))
        e.layout = layout
        e.kind = screenSharing ? nil : .terminal
        if !screenSharing {
            e.lastAddress = nil
            e.view = nil
            e.autoUnlock = nil
        }
    }

    /// A new list entry from these fields: its id is the sync id (it was never on this iPhone before).
    func newEntry(id: String, editedAt: Date) -> MacEntry {
        var e = MacEntry(id: id, name: name)
        apply(to: &e)
        e.editedAt = Self.stored(editedAt)
        return e
    }

    /// An edit time as the list keeps it: "the earliest time" (an entry saved before sync) stays no time at all.
    static func stored(_ editedAt: Date) -> Date? { editedAt == .distantPast ? nil : editedAt }
}

/// One record in iCloud (record type `Computer`, all of it in one encrypted field): when the person last changed the
/// computer, and its fields; or, after Remove from All Devices, only the time of that removal.
struct CloudComputer: Codable, Equatable {
    var editedAt: Date
    /// nil: removed from all devices at `editedAt` (a dated mark, so an older offline edit cannot bring it back).
    var computer: SyncedComputer?

    var removed: Bool { computer == nil }
}

/// When two copies of one computer are the same computer (plan §A9.1). Only evidence for the same way in counts:
/// - two Glass Act keys decide alone: the same key is the same Mac; two different keys are never joined;
/// - otherwise a shared address with the same port (Screen Sharing), a shared address with the same SSH port
///   (Terminal), or the same JetKVM address.
enum ComputerIdentity {
    static func same(_ a: SyncedComputer, _ b: SyncedComputer) -> Bool {
        if let ka = a.key, let kb = b.key { return ka == kb }
        let shared = !Set(addresses(a)).isDisjoint(with: addresses(b))
        if a.screenSharing && b.screenSharing && a.port == b.port && shared { return true }
        if a.terminal && b.terminal && (a.sshPort ?? 22) == (b.sshPort ?? 22) && shared { return true }
        if a.jetkvm && b.jetkvm, let ja = jetkvmHost(a), ja == jetkvmHost(b) { return true }
        return false
    }

    private static func addresses(_ c: SyncedComputer) -> [String] {
        [c.home, c.tailscale].compactMap { a in
            let t = a?.trimmingCharacters(in: .whitespaces).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return t?.isEmpty == false ? t : nil
        }
    }

    private static func jetkvmHost(_ c: SyncedComputer) -> String? {
        var e = MacEntry(name: "")
        e.jetkvm = true
        e.jetkvmAddress = c.jetkvmAddress
        return e.jetkvmHost?.lowercased()
    }
}

/// The secrets this iPhone keeps for a computer, outside the build switches (review finding 2: a build without JetKVM
/// must still delete a JetKVM password when its computer is removed). Only whether an item exists is ever asked; no
/// password is read for that.
protocol DeviceSecretKeeping: AnyObject {
    func hasJetKVMPassword(_ id: String) -> Bool
    func deleteJetKVMPassword(_ id: String)
}

final class DeviceSecrets: DeviceSecretKeeping {
    static let shared = DeviceSecrets()
    /// The same item `KeychainJetKVMPasswords` keeps (JetKVM.swift).
    private let jetkvmService = (Bundle.main.bundleIdentifier ?? "duodesktop") + ".jetkvm-password"

    private func jetkvmQuery(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: jetkvmService,
         kSecAttrAccount as String: id]
    }

    func hasJetKVMPassword(_ id: String) -> Bool {
        var q = jetkvmQuery(id)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess
    }

    func deleteJetKVMPassword(_ id: String) {
        SecItemDelete(jetkvmQuery(id) as CFDictionary)
    }
}

/// The sync rules and this iPhone's sync state (plan §A5, §A6, §A9).
@MainActor @Observable
final class ComputerSync {
    /// What the switch's footer says.
    enum Status: Equatable {
        case off
        /// This build has no iCloud entitlement (built without `DUO_SYNC`): the list is local.
        case notInThisBuild
        case simulator
        case checking
        case signedOut
        /// A different iCloud account than the one this list synced with: nothing moves until the person says so.
        case otherAccount
        /// iCloud did not answer or refused; the words say why. The list stays on this iPhone.
        case notNow(String)
        case on

        var words: String {
            switch self {
            case .off: "Off. Your computers stay on this iPhone."
            case .notInThisBuild: "This version of the app does not sync. Your computers stay on this iPhone."
            case .simulator: "Not checked in the Simulator. Your computers stay on this iPhone."
            case .checking: "Checking iCloud…"
            case .signedOut: "Sign in to iCloud to sync. Until then your computers stay on this iPhone only."
            case .otherAccount: "A different iCloud account is signed in. Nothing is synced until you choose to."
            case let .notNow(why): why + " Your computers stay on this iPhone."
            case .on: "On."
            }
        }
    }

    /// What is kept between launches (a file beside the list; never synced).
    struct State: Codable, Equatable {
        /// The iCloud account this state belongs to (its user record name; nil before the first sign-in seen).
        var account: String?
        /// A different account seen since; nothing moves until the person chooses "Sync with This iCloud Account".
        var otherAccount: String?
        /// Computers removed from this iPhone only, by sync id: kept, hidden, still updated from iCloud, never sent.
        var hidden: [String: MacEntry] = [:]
        /// Removal marks (Remove from All Devices), by sync id: the time of that removal.
        var removedAt: [String: Date] = [:]
        /// Changes not yet in iCloud, by sync id. Kept here, not only in the engine, so they survive the engine
        /// losing its own pending list (an account change does that).
        var unsent: Set<String> = []
        /// Sync ids iCloud has (sent or fetched). Only a computer not in iCloud yet can join another (first join).
        var inCloud: Set<String> = []
        /// The first fetch for this account is done: local computers are sent only after it, so they can join.
        var joined = false
        /// The zone `Computers` exists in iCloud.
        var zoneMade = false
        /// CloudKit's own saved state (CKSyncEngine.State.Serialization, JSON) and each record's change tag.
        var engine: Data?
        var tags: [String: Data] = [:]
    }

    static let enabledKey = "syncComputersWithICloud"
    /// The switch's footer (plan §A6).
    static let footer = "Names, addresses and user names sync. Passwords and this iPhone’s keys stay on this iPhone."

    static let shared = ComputerSync(store: .shared,
                                     url: AppPaths.dataDirectory.appendingPathComponent("duo-sync.json"),
                                     defaults: .standard)

    let store: MacStore
    private(set) var state: State
    var status: Status = .checking
    private let url: URL?
    private let defaults: UserDefaults
    /// Told when sync ids have something to send (the CloudKit side adds them to its engine).
    @ObservationIgnored var onUnsent: (Set<String>) -> Void = { _ in }
    /// Told when a sync id no longer needs sending (it joined another computer).
    @ObservationIgnored var onDropped: (String) -> Void = { _ in }

    init(store: MacStore, url: URL?, defaults: UserDefaults) {
        self.store = store
        self.url = url
        self.defaults = defaults
        if let url, let d = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(State.self, from: d) {
            state = s
        } else {
            state = State()
        }
        store.sync = self
    }

    // MARK: The switch

    /// On by default (the owner 2026-11-22: "On").
    var enabled: Bool {
        get {
            access(keyPath: \.enabled)
            return defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        }
        set {
            withMutation(keyPath: \.enabled) { defaults.set(newValue, forKey: Self.enabledKey) }
        }
    }

    // MARK: Local changes (from MacStore)

    func syncID(_ e: MacEntry) -> String { e.syncID ?? e.id }

    /// A synced field of `e` changed here (or it was added).
    func changed(_ e: MacEntry) {
        let sid = syncID(e)
        state.removedAt[sid] = nil
        state.unsent.insert(sid)
        save()
        onUnsent([sid])
    }

    /// Remove from All Devices: a dated removal mark replaces it.
    func removedEverywhere(_ e: MacEntry, at time: Date) {
        let sid = syncID(e)
        state.hidden[sid] = nil
        state.removedAt[sid] = time
        state.unsent.insert(sid)
        save()
        onUnsent([sid])
    }

    /// Remove from This iPhone Only: kept, hidden, with nothing of this iPhone's own in it.
    func hiddenHere(_ e: MacEntry) {
        var h = e
        h.lastUsed = nil
        h.lastAddress = nil
        h.view = nil
        h.autoUnlock = nil
        state.hidden[syncID(e)] = h
        save()
    }

    var hiddenCount: Int { state.hidden.count }

    /// Add Computer typed a computer this iPhone hid: that hidden one, taken out of hiding (plan §A9.1: re-adding finds
    /// the same computer and does not make a second one). nil when none matches.
    func takeHidden(matching e: MacEntry) -> (syncID: String, entry: MacEntry)? {
        let c = SyncedComputer(e)
        guard let (sid, h) = state.hidden.first(where: { ComputerIdentity.same(SyncedComputer($0.value), c) }) else { return nil }
        state.hidden[sid] = nil
        save()
        return (sid, h)
    }

    /// Whether removing this computer asks All Devices / This iPhone Only: whenever sync is on (in a build that can
    /// sync), or iCloud has it.
    func asksOnRemove(_ e: MacEntry) -> Bool {
        (enabled && status != .notInThisBuild) || state.inCloud.contains(syncID(e))
    }

    // MARK: What goes to iCloud

    /// The record for a sync id now: the computer (shown or hidden) or its removal mark; nil when this iPhone has
    /// nothing for it. Entries saved before sync have no edit time: they go as "the earliest time", never a new one.
    func record(for sid: String) -> CloudComputer? {
        if let e = store.entry(syncID: sid) ?? state.hidden[sid] {
            return CloudComputer(editedAt: e.editedAt ?? .distantPast, computer: SyncedComputer(e))
        }
        if let t = state.removedAt[sid] { return CloudComputer(editedAt: t, computer: nil) }
        return nil
    }

    /// iCloud took `sent` for `sid`. Still unsent if it changed again since.
    func sent(_ sid: String, _ sent: CloudComputer?) {
        state.inCloud.insert(sid)
        if let sent, record(for: sid) == sent { state.unsent.remove(sid) }
        save()
    }

    // MARK: What comes from iCloud

    /// A record from iCloud. Newest edit wins, the whole computer (the owner: "Newest wins"); on a tie, iCloud's copy wins,
    /// so two iPhones end with the same entry.
    func received(_ sid: String, _ remote: CloudComputer) {
        state.inCloud.insert(sid)
        defer { save() }
        if let e = store.entry(syncID: sid) {
            if remote.editedAt >= (e.editedAt ?? .distantPast) {
                state.unsent.remove(sid)
                if let c = remote.computer {
                    store.applyRemote(e.id, c, editedAt: remote.editedAt)
                } else {
                    state.removedAt[sid] = remote.editedAt
                    store.dropRemote(e.id)
                }
            } else {
                resend(sid)
            }
        } else if let h = state.hidden[sid] {
            if remote.editedAt >= (h.editedAt ?? .distantPast) {
                state.unsent.remove(sid)
                if let c = remote.computer {
                    var n = h
                    c.apply(to: &n)
                    n.editedAt = SyncedComputer.stored(remote.editedAt)
                    state.hidden[sid] = n
                } else {
                    state.hidden[sid] = nil
                    state.removedAt[sid] = remote.editedAt
                }
            } else {
                resend(sid)
            }
        } else if let t = state.removedAt[sid] {
            if let c = remote.computer, remote.editedAt > t {
                // Edited after it was removed: newest wins, so it is back.
                state.removedAt[sid] = nil
                state.unsent.remove(sid)
                store.insertRemote(c.newEntry(id: sid, editedAt: remote.editedAt))
            } else if remote.computer != nil || remote.editedAt < t {
                resend(sid)
            } else {
                state.unsent.remove(sid)
            }
        } else if let c = remote.computer {
            if let twin = store.entries.first(where: { !state.inCloud.contains(syncID($0)) && ComputerIdentity.same(SyncedComputer($0), c) }) {
                // First join (plan §A9.1): this iPhone's copy keeps its own id, and with it its passwords and pins; it
                // takes the sync id. Then newest wins between the two.
                let old = syncID(twin)
                state.unsent.remove(old)
                onDropped(old)
                store.setSyncID(twin.id, sid)
                if remote.editedAt >= (twin.editedAt ?? .distantPast) {
                    store.applyRemote(twin.id, c, editedAt: remote.editedAt)
                } else {
                    resend(sid)
                }
            } else {
                store.insertRemote(c.newEntry(id: sid, editedAt: remote.editedAt))
            }
        } else {
            state.removedAt[sid] = remote.editedAt
        }
    }

    /// iCloud no longer has a record (the app never deletes one, so it was lost): this iPhone's copy is sent again,
    /// removal marks included.
    func lostInCloud(_ sid: String) {
        state.inCloud.remove(sid)
        state.tags[sid] = nil
        if record(for: sid) != nil { resend(sid) }
        save()
    }

    /// The zone itself is gone from iCloud (for example iCloud data was reset): everything is sent again.
    func zoneLost() {
        state.inCloud = []
        state.tags = [:]
        state.zoneMade = false
        state.unsent.formUnion(allSyncIDs)
        save()
    }

    /// The first fetch for this account is done: every computer iCloud does not have yet is sent now.
    func joinDone() {
        state.joined = true
        state.unsent.formUnion(allSyncIDs.subtracting(state.inCloud))
        save()
        onUnsent(state.unsent)
    }

    private var allSyncIDs: Set<String> {
        Set(store.entries.map(syncID)).union(state.hidden.keys).union(state.removedAt.keys)
    }

    private func resend(_ sid: String) {
        state.unsent.insert(sid)
        onUnsent([sid])
    }

    // MARK: The iCloud account (plan §A9.3)

    /// The signed-in account (its user record name; nil when signed out). True when sync may run for it.
    @discardableResult
    func account(_ id: String?) -> Bool {
        guard let id else {
            status = .signedOut
            return false
        }
        if state.account == nil {
            state.account = id
            state.joined = false
        }
        guard state.account == id else {
            state.otherAccount = id
            status = .otherAccount
            save()
            return false
        }
        state.otherAccount = nil
        save()
        return true
    }

    /// "Sync with This iCloud Account": the person chose to join this iPhone's list with the other account's. What
    /// belonged to the old account (its change tags, removal marks and the computers hidden for it) is dropped; the
    /// list itself is kept and joined like a first sync.
    func adoptOtherAccount() {
        guard let other = state.otherAccount else { return }
        state = State(account: other)
        store.clearSyncIDs()
        save()
    }

    func saveEngine(_ data: Data?) {
        state.engine = data
        save()
    }

    func saveTag(_ sid: String, _ tag: Data?) {
        state.tags[sid] = tag
        save()
    }

    func zoneMade(_ made: Bool) {
        state.zoneMade = made
        save()
    }

    private func save() {
        guard let url else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            SessionModel.log.error("couldn't save the sync state: \(error.localizedDescription, privacy: .public)")
        }
    }
}
