import GlassActTransport
import LocalAuthentication
import Security
import XCTest
@testable import DuoDesktop

/// The computer list syncing through iCloud (project notes; plan Part A and its §A9). One test per claim.
/// Two iPhones are two lists with their own sync state; iCloud is `PretendCloud`, which behaves as CloudKit does for
/// this app: a save over a record changed since this iPhone last saw it is refused and hands back iCloud's copy
/// (`serverRecordChanged`). Real iCloud between two phones cannot run in the simulator (see the result).
@MainActor
final class ListSyncTests: XCTestCase {
    private var dir: URL!
    private var clock = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ListSync-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: dir)
    }

    // MARK: Two iPhones and a pretend iCloud

    final class Passwords: MacPasswordKeeping {
        var items: [String: Data] = [:]
        func save(_ password: Data, macID: String) -> Bool { items[macID] = password; return true }
        func delete(macID: String) { items[macID] = nil }
        func read(macID: String, context: LAContext) -> Data? { items[macID] }
    }

    final class Secrets: DeviceSecretKeeping {
        var jetkvm: Set<String> = []
        func hasJetKVMPassword(_ id: String) -> Bool { jetkvm.contains(id) }
        func deleteJetKVMPassword(_ id: String) { jetkvm.remove(id) }
    }

    /// One iPhone: its list, its sync state (both in files, so a relaunch reads them back) and its secrets.
    final class Phone {
        let name: String
        let store: MacStore
        let sync: ComputerSync
        let passwords = Passwords()
        let secrets = Secrets()
        var gone: [String] = []
        /// The change tag this iPhone last saw for each record (CloudKit's system fields).
        var seen: [String: Int] = [:]

        @MainActor init(_ name: String, dir: URL, defaults: UserDefaults, clock: @escaping () -> Date) {
            self.name = name
            // An empty list, not the simulator's own test host (a new install's list).
            let list = dir.appendingPathComponent("\(name)-macs.json")
            if !FileManager.default.fileExists(atPath: list.path) { try? Data("[]".utf8).write(to: list) }
            store = MacStore(url: dir.appendingPathComponent("\(name)-macs.json"), defaults: defaults,
                             knownHosts: KnownHosts(url: dir.appendingPathComponent("\(name)-known_hosts")))
            sync = ComputerSync(store: store, url: dir.appendingPathComponent("\(name)-sync.json"), defaults: defaults)
            store.passwords = passwords
            store.secrets = secrets
            store.now = clock
            store.onGone = { [unowned self] id in self.gone.append(id) }
        }

        @MainActor func named(_ n: String) -> MacEntry? { store.entries.first { $0.name == n } }
    }

    /// iCloud's private database for this app: one record per sync id, with a change tag.
    final class PretendCloud {
        var records: [String: (tag: Int, value: CloudComputer)] = [:]
        private var nextTag = 1

        /// Everything iCloud has, to `phone` (a fetch).
        @MainActor func fetch(_ phone: Phone) {
            for (id, r) in records.sorted(by: { $0.key < $1.key }) where phone.seen[id] != r.tag {
                phone.seen[id] = r.tag
                phone.sync.received(id, r.value)
            }
            if !phone.sync.state.joined { phone.sync.joinDone() }
        }

        /// `phone`'s unsent changes (a send). A record changed in iCloud since the phone saw it is refused and handed
        /// back, as CKError.serverRecordChanged; the phone then sends again only if its copy still wins.
        @MainActor func send(_ phone: Phone) {
            for _ in 0..<3 {
                for id in phone.sync.state.unsent.sorted() {
                    guard let mine = phone.sync.record(for: id) else { continue }
                    if let server = records[id], phone.seen[id] != server.tag {
                        phone.seen[id] = server.tag
                        phone.sync.received(id, server.value)
                        continue
                    }
                    records[id] = (nextTag, mine)
                    phone.seen[id] = nextTag
                    nextTag += 1
                    phone.sync.sent(id, mine)
                }
            }
        }

        @MainActor func sync(_ phones: Phone...) {
            for p in phones { fetch(p); send(p) }
            for p in phones { fetch(p) }
        }

        var shown: [CloudComputer] { records.values.map(\.value).filter { !$0.removed } }
    }

    private func phone(_ name: String) -> Phone {
        Phone(name, dir: dir, defaults: UserDefaults(suiteName: "ListSync.\(name).\(UUID().uuidString)")!,
              clock: { [unowned self] in self.clock })
    }

    private func tick(_ seconds: TimeInterval = 60) { clock += seconds }

    /// A Mac with Screen Sharing, Terminal and JetKVM (made-up addresses and keys).
    private func mac(_ name: String, key: String? = "KEY-\(UUID().uuidString.prefix(6))") -> MacEntry {
        var e = MacEntry(name: name)
        e.set(.tailscale, "\(name.lowercased().replacingOccurrences(of: " ", with: "-")).example.invalid")
        e.key = key
        e.screenSharing = true
        e.terminal = true
        e.sshUser = "me"
        e.jetkvm = true
        e.jetkvmAddress = "kvm-\(name.prefix(3)).example.invalid"
        return e
    }

    // MARK: Claim 1: newest change wins, per computer

    /// The owner: "Newest wins". Two iPhones change the same computer while apart: the later change is kept whole, on both.
    /// Only synced fields are edits: this iPhone's last used, view and Unlock Automatically never make an old copy win,
    /// and they are kept when the other iPhone's copy arrives.
    func testNewestChangeWins() {
        let cloud = PretendCloud(), a = phone("A"), b = phone("B")
        a.store.add(mac("Studio"))
        cloud.sync(a, b)
        XCTAssertEqual(b.named("Studio")?.syncID ?? b.named("Studio")?.id, a.named("Studio")?.id, "B has A's computer")
        let id = a.named("Studio")!.id

        // Apart: A renames it, then B changes its port a minute later.
        tick(); a.store.update(id) { $0.name = "Studio Mac" }
        tick(); b.store.update(id) { $0.port = 5000 }
        // A opens it afterwards: last used, view and Unlock Automatically are A's own, not edits.
        tick(); a.store.update(id) { $0.lastUsed = self.clock; $0.view = "zoomed"; $0.autoUnlock = true }
        XCTAssertEqual(a.store.entry(id)?.editedAt, clock.addingTimeInterval(-120), "opening it is not an edit")

        cloud.sync(a, b)
        for p in [a, b] {
            XCTAssertEqual(p.store.entry(id)?.port, 5000, "\(p.name): B's later change won")
            XCTAssertEqual(p.store.entry(id)?.name, "Studio", "\(p.name): the whole computer, so A's earlier rename lost")
        }
        XCTAssertEqual(a.store.entry(id)?.view, "zoomed", "A's own view stays")
        XCTAssertEqual(a.store.entry(id)?.autoUnlock, true, "A's own Unlock Automatically stays")
        XCTAssertNil(b.store.entry(id)?.autoUnlock, "B never got A's Unlock Automatically")
        XCTAssertEqual(cloud.records.count, 1)
    }

    // MARK: Claim 2: removal both ways

    /// Remove from All Devices: gone from both iPhones, with each one's passwords for it; an open connection ends. An
    /// older edit from an iPhone that was offline does not bring it back (review finding 2); an edit made after does.
    func testRemoveFromAllDevices() {
        let cloud = PretendCloud(), a = phone("A"), b = phone("B")
        a.store.add(mac("Studio"))
        cloud.sync(a, b)
        let id = a.named("Studio")!.id
        _ = b.passwords.save(Data("made-up".utf8), macID: id)
        b.secrets.jetkvm.insert(id)

        // B, offline, edits at 10:00; A removes from all devices at 10:05; B comes back at 10:10.
        tick(); b.store.update(id) { $0.name = "Old edit" }
        tick(); a.store.remove(id, everywhere: true)
        XCTAssertEqual(a.gone, [id], "A's open connection to it ends")
        tick(); cloud.sync(b, a)
        XCTAssertNil(a.store.entry(id), "A: still removed")
        XCTAssertNil(b.store.entry(id), "B: the newer removal beat B's older edit")
        XCTAssertEqual(b.gone, [id], "B's open connection to it ends")
        XCTAssertTrue(b.passwords.items.isEmpty, "B's Mac password for it is deleted")
        XCTAssertTrue(b.secrets.jetkvm.isEmpty, "B's JetKVM password for it is deleted")
        XCTAssertEqual(cloud.records[id]?.value.removed, true, "iCloud keeps a dated removal mark, not the computer")
        XCTAssertTrue(cloud.shown.isEmpty)

        // A third iPhone that never saw it does not get it either.
        let c = phone("C")
        cloud.sync(c)
        XCTAssertTrue(c.store.entries.isEmpty)
    }

    /// Remove from This iPhone Only: hidden here, kept on the other iPhone; still hidden after the other iPhone edits
    /// it, after a relaunch and after sync off and on; adding it again here brings back the same computer (no second
    /// one in iCloud).
    func testRemoveFromThisIPhoneOnly() {
        let cloud = PretendCloud(), a = phone("A"), b = phone("B")
        a.store.add(mac("Studio", key: "KEY-STUDIO"))
        cloud.sync(a, b)
        let id = a.named("Studio")!.id
        _ = a.passwords.save(Data("made-up".utf8), macID: id)

        tick(); a.store.remove(id, everywhere: false)
        XCTAssertNil(a.store.entry(id))
        XCTAssertTrue(a.store.computers.isEmpty && a.store.macs.isEmpty, "out of the list, the checks and cold open")
        XCTAssertTrue(a.passwords.items.isEmpty, "A's own password for it is deleted")
        XCTAssertEqual(a.gone, [id])

        tick(); b.store.update(id) { $0.port = 5000 }
        cloud.sync(a, b)
        XCTAssertNotNil(b.store.entry(id), "still on B")
        XCTAssertNil(a.store.entry(id), "B's edit does not bring it back on A")
        XCTAssertEqual(a.sync.state.hidden[id]?.port, 5000, "A's hidden copy took B's edit")

        // Relaunch A from its files, and turn sync off and on.
        let a2 = Phone("A", dir: dir, defaults: UserDefaults(suiteName: "ListSync.A2.\(UUID().uuidString)")!,
                       clock: { [unowned self] in self.clock })
        a2.seen = a.seen
        a2.sync.enabled = false
        a2.sync.enabled = true
        cloud.sync(a2)
        XCTAssertNil(a2.store.entry(id), "still hidden after a relaunch and sync off/on")
        XCTAssertEqual(a2.sync.hiddenCount, 1)

        // Add Computer with the same Mac (same key): the hidden one comes back, under the sheet's new local id.
        tick()
        var again = MacEntry(name: "Studio again")
        again.set(.home, "studio.local")
        again.key = "KEY-STUDIO"
        a2.store.addNew(again, startWith: .screenSharing)
        cloud.sync(a2, b)
        XCTAssertEqual(a2.store.entries.count, 1)
        XCTAssertEqual(a2.store.entries.first?.syncID, id, "the same computer in iCloud")
        XCTAssertEqual(a2.store.entries.first?.hasTerminal, true, "its other ways in came back with it")
        XCTAssertEqual(a2.sync.hiddenCount, 0)
        XCTAssertEqual(cloud.records.count, 1, "no second computer in iCloud")
        XCTAssertEqual(b.store.entry(id)?.name, "Studio again", "B sees the newer edit")
    }

    // MARK: Claim 3: secrets never leave

    /// The record is an allow-list (plan §A3): no password, private key or Keychain item can be in it, and nothing of
    /// this iPhone's own (last used, last address, view, Unlock Automatically). The Keychain items stay this-device-only.
    func testSecretsNeverLeave() throws {
        let a = phone("A")
        var e = mac("Studio")
        e.lastUsed = clock
        e.lastAddress = .home
        e.view = "zoomed"
        e.autoUnlock = true
        a.store.add(e)
        let password = "made-up-mac-password-\(UUID().uuidString)"
        _ = a.passwords.save(Data(password.utf8), macID: e.id)
        a.secrets.jetkvm.insert(e.id)

        let record = try XCTUnwrap(a.sync.record(for: e.id))
        let json = String(decoding: try JSONEncoder().encode(record), as: UTF8.self)
        XCTAssertFalse(json.contains(password))
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(record.computer)) as? [String: Any])
        let allowed: Set = ["name", "home", "tailscale", "port", "key", "screenSharing", "terminal", "sshUser", "sshPort",
                            "terminalSignIn", "terminalOpens", "jetkvm", "jetkvmAddress", "jetkvmPassword", "opensIn",
                            "layout"]
        XCTAssertTrue(Set(fields.keys).isSubset(of: allowed), "only the allow-list: \(Set(fields.keys).subtracting(allowed))")
        for own in ["lastUsed", "lastAddress", "view", "autoUnlock", "id", "syncID"] {
            XCTAssertNil(fields[own], "\(own) stays on this iPhone")
        }
        // The Keychain items: never synchronizable, this device only.
        XCTAssertEqual(MacPasswordKeychain.baseQuery(macID: "x")[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertTrue([kSecAttrAccessibleWhenUnlockedThisDeviceOnly, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly]
            .contains(MacPasswordKeychain.accessibility), "this device only")
    }

    // MARK: Claim 4: signed out, and the account

    /// Signed out of iCloud: the list works on this iPhone alone and says so; the edit waits, through a relaunch, and
    /// goes when the same account is back. A different account: nothing is sent or joined until the person chooses.
    func testSignedOutAndAccounts() async {
        let a = phone("A")
        XCTAssertTrue(a.sync.account("ME"))
        a.sync.joinDone()

        XCTAssertFalse(a.sync.account(nil))
        XCTAssertEqual(a.sync.status, .signedOut)
        XCTAssertTrue(a.sync.status.words.contains("stay on this iPhone"))
        a.store.add(mac("Studio"))
        let id = a.named("Studio")!.id
        XCTAssertEqual(a.store.computers.count, 1, "works on this iPhone alone")
        XCTAssertTrue(a.sync.state.unsent.contains(id), "the edit waits")

        let a2 = Phone("A", dir: dir, defaults: UserDefaults(suiteName: "ListSync.A2.\(UUID().uuidString)")!,
                       clock: { [unowned self] in self.clock })
        XCTAssertTrue(a2.sync.state.unsent.contains(id), "still waiting after a relaunch")
        XCTAssertTrue(a2.sync.account("ME"), "same account back: it may send")
        let cloud = PretendCloud()
        cloud.send(a2)
        XCTAssertEqual(cloud.records[id]?.value.computer?.name, "Studio")

        XCTAssertFalse(a2.sync.account("SOMEONE-ELSE"), "a different account: nothing moves")
        XCTAssertEqual(a2.sync.status, .otherAccount)
        a2.sync.adoptOtherAccount()
        XCTAssertEqual(a2.sync.state.account, "SOMEONE-ELSE")
        XCTAssertFalse(a2.sync.state.joined, "joined again like a first sync")
        XCTAssertEqual(a2.store.computers.count, 1, "the list is kept")

        // The simulator build never touches CloudKit, and says so.
        let cloudSide = CloudComputerSync(core: a2.sync)
        await cloudSide.start()
        XCTAssertEqual(a2.sync.status, .simulator)
    }

    // MARK: Claim 5: a device missing a secret

    /// A synced computer whose JetKVM password is on the other iPhone only: on this one its JetKVM icon is gray,
    /// "Needs setting up here", and a tap opens its Add sheet (the gray-icon path). With the password here, or with a
    /// JetKVM that has none, it is set up.
    func testDeviceMissingASecret() throws {
        try XCTSkipUnless(WayIn.inThisBuild.contains(.jetkvm), "the JetKVM build")
        let cloud = PretendCloud(), a = phone("A"), b = phone("B")
        var e = mac("Studio")
        e.jetkvmPassword = true
        a.store.add(e)
        a.secrets.jetkvm.insert(e.id)
        cloud.sync(a, b)
        let onB = try XCTUnwrap(b.store.entry(e.id))

        XCTAssertEqual(WayLook.of(onB, .jetkvm, mac: nil, reach: ComputerReach.shared, secrets: b.secrets), .needsSetUpHere)
        XCTAssertTrue(WayLook.needsSetUpHere.isGray, "a tap opens the Add sheet, as a gray icon does")
        XCTAssertEqual(WayIconButton.value(.needsSetUpHere), "Needs setting up here")
        XCTAssertNotEqual(WayLook.of(onB, .screenSharing, mac: nil, reach: ComputerReach.shared, secrets: b.secrets),
                          .needsSetUpHere, "only the way in missing its secret")
        XCTAssertEqual(WayLook.of(a.store.entry(e.id)!, .jetkvm, mac: nil, reach: ComputerReach.shared, secrets: a.secrets),
                       .setUp, "set up on the iPhone that has the password")
        b.secrets.jetkvm.insert(e.id)
        XCTAssertEqual(WayLook.of(onB, .jetkvm, mac: nil, reach: ComputerReach.shared, secrets: b.secrets), .setUp,
                       "typed on this iPhone too")
        var noPassword = onB
        noPassword.jetkvmPassword = false
        b.secrets.jetkvm.remove(e.id)
        XCTAssertEqual(WayLook.of(noPassword, .jetkvm, mac: nil, reach: ComputerReach.shared, secrets: b.secrets), .setUp,
                       "a JetKVM with no password needs nothing here")
    }

    // MARK: Review finding 1: the first join

    /// The same Mac already on both iPhones with different ids (one Glass Act key): after the first sync there is one
    /// computer, B's copy keeps its own id and with it its passwords; iCloud has one record. Two entries at the same
    /// address with different keys are not the same Mac: both stay. Old entries with no edit time do not get one.
    func testFirstJoin() {
        let cloud = PretendCloud()
        var onA = mac("Studio", key: "KEY-STUDIO")
        var onB = mac("Studio (B)", key: "KEY-STUDIO")
        onA.editedAt = nil
        onB.editedAt = nil
        // Saved before sync: no edit time (written straight into the list's file, as an older build did).
        try? JSONEncoder().encode([onA]).write(to: dir.appendingPathComponent("A-macs.json"))
        var other = mac("Other Mac", key: "KEY-OTHER")
        other.tailscale = onB.tailscale   // the same address, but a different Mac key
        try? JSONEncoder().encode([onB, other]).write(to: dir.appendingPathComponent("B-macs.json"))
        let a1 = phone("A"), b1 = phone("B")
        _ = b1.passwords.save(Data("made-up".utf8), macID: onB.id)
        b1.secrets.jetkvm.insert(onB.id)

        cloud.sync(a1, b1)
        cloud.sync(a1, b1)
        XCTAssertEqual(b1.store.entries.count, 2, "B: Studio once, and the other Mac")
        let joined = b1.store.entry(onB.id)
        XCTAssertEqual(joined?.syncID, onA.id, "B's copy joined A's record")
        XCTAssertEqual(joined?.name, "Studio", "no edit times on either side: iCloud's copy wins the tie")
        XCTAssertNil(joined?.editedAt, "an old entry is not given an edit time")
        XCTAssertNotNil(b1.passwords.items[onB.id], "B's password is still under B's own id")
        XCTAssertTrue(b1.secrets.jetkvm.contains(onB.id))
        XCTAssertEqual(Set(a1.store.entries.map(\.name)), ["Studio", "Other Mac"])
        XCTAssertEqual(cloud.records.count, 2, "one record per computer, none twice")
    }
}
