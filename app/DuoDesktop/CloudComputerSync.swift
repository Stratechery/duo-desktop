import CloudKit
import Foundation
import SwiftUI
import UIKit

// The CloudKit side of the list sync (plan Part A, §A9.4): the user's private database, container
// `iCloud.<bundle id>`, zone `Computers`, one record per computer of type `Computer` whose only field, `payload`, is
// encrypted on the iPhone before it is sent (`encryptedValues`). Apple's CKSyncEngine moves the records; the rules
// (newest wins, removal marks, first join, accounts) are `ComputerSync`'s.
//
// It runs only in a build made with DUO_SYNC=YES (project-sync.yml), which carries the iCloud entitlements; any other
// build, and the unsigned simulator build, never touches CloudKit (a missing entitlement would stop the app).

@MainActor
final class CloudComputerSync: CKSyncEngineDelegate {
    static let zoneName = "Computers"
    static let recordType = "Computer"
    static let payloadField = "payload"
    /// The Remote Desktop fields (`SyncedRemoteDesktop`), encrypted, in a field of their own: an older build saves
    /// only `payload`, and CloudKit saves only the fields a save sets, so it leaves this one as it was.
    static let remoteDesktopField = "remoteDesktop"
    /// What the computer's Terminal is (`TerminalSystem`), in a field of its own for the same reason.
    static let terminalSystemField = "terminalSystem"
    /// What the computer answered to `uname -s` (`MacEntry.unameSystem`), in a field of its own the same way.
    static let unameSystemField = "unameSystem"

    static let shared = CloudComputerSync(core: .shared)

    let core: ComputerSync
    private var engine: CKSyncEngine?
    private var container: CKContainer?
    /// What each record held when it was handed to the engine, to tell whether it changed again before iCloud took it.
    private var sending: [String: CloudComputer] = [:]
    private let zoneID = CKRecordZone.ID(zoneName: zoneName)

    init(core: ComputerSync) {
        self.core = core
        core.onUnsent = { [weak self] ids in self?.enqueue(ids) }
        core.onDropped = { [weak self] id in self?.unqueue(id) }
    }

    /// Whether this build carries the iCloud entitlements.
    static var inThisBuild: Bool {
        #if DUO_SYNC && !targetEnvironment(simulator)
        true
        #else
        false
        #endif
    }

    // MARK: Start, stop, the switch

    func start() async {
        guard core.enabled else {
            stop()
            core.status = .off
            return
        }
        guard Self.inThisBuild else {
            #if targetEnvironment(simulator)
            core.status = .simulator
            if let demo = SimulatorSwitches.syncDemo { core.showDemo(demo) }
            #else
            core.status = .notInThisBuild
            #endif
            return
        }
        let container = self.container ?? CKContainer(identifier: "iCloud." + (Bundle.main.bundleIdentifier ?? ""))
        self.container = container
        if engine == nil { core.status = .checking }
        do {
            switch try await container.accountStatus() {
            case .available:
                let user = try await container.userRecordID()
                guard core.account(user.recordName) else { stop(); return }
                makeEngine(container)
            case .noAccount:
                core.account(nil)
                stop()
            case .temporarilyUnavailable:
                // An outage, not a new account (review finding 3): the engine, if any, keeps its state.
                core.status = .notNow("iCloud is not available right now.")
            case .restricted:
                core.status = .notNow("iCloud is restricted on this iPhone.")
            case .couldNotDetermine:
                core.status = .notNow("iCloud did not answer.")
            @unknown default:
                core.status = .notNow("iCloud did not answer.")
            }
        } catch {
            core.status = .notNow(Self.plain(error))
        }
    }

    /// The switch. Off cancels what is already queued and stops sending and receiving; nothing is deleted anywhere.
    func setEnabled(_ on: Bool) {
        core.enabled = on
        if !on { stop() }
        Task { await start() }
    }

    /// "Sync with This iCloud Account" (a different account was signed in).
    func adoptOtherAccount() {
        stop()
        core.adoptOtherAccount()
        Task { await start() }
    }

    /// Back in the foreground: look for changes now. Back in the foreground: look for changes now, and send again what
    /// iCloud has not taken, refused ones included.
    func fetchNow() {
        guard let engine else { Task { await start() }; return }
        core.retryUnsent()
        Task {
            try? await engine.fetchChanges()
            try? await engine.sendChanges()
        }
    }

    private func stop() {
        if let engine {
            Task { await engine.cancelOperations() }
        }
        engine = nil
        sending = [:]
    }

    private func makeEngine(_ container: CKContainer) {
        guard engine == nil else { core.status = .on; return }
        let saved = core.state.engine.flatMap { try? JSONDecoder().decode(CKSyncEngine.State.Serialization.self, from: $0) }
        let config = CKSyncEngine.Configuration(database: container.privateCloudDatabase, stateSerialization: saved,
                                                delegate: self)
        let e = CKSyncEngine(config)
        engine = e
        if !core.state.zoneMade { e.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))]) }
        // The app's own list of unsent changes (the engine's may have been dropped by an account change).
        if core.state.joined { enqueue(core.state.unsent) }
        UIApplication.shared.registerForRemoteNotifications()
        core.status = .on
    }

    // MARK: Queue

    private func enqueue(_ ids: Set<String>) {
        guard let engine, core.state.joined, !ids.isEmpty else { return }
        engine.state.add(pendingRecordZoneChanges: ids.map { .saveRecord(CKRecord.ID(recordName: $0, zoneID: zoneID)) })
    }

    private func unqueue(_ id: String) {
        engine?.state.remove(pendingRecordZoneChanges: [.saveRecord(CKRecord.ID(recordName: id, zoneID: zoneID))])
    }

    // MARK: CKSyncEngineDelegate

    func handleEvent(_ event: CKSyncEngine.Event, syncEngine: CKSyncEngine) async {
        guard syncEngine === engine else { return }
        switch event {
        case let .stateUpdate(u):
            core.saveEngine(try? JSONEncoder().encode(u.stateSerialization))
        case let .accountChange(a):
            switch a.changeType {
            case let .signIn(currentUser):
                if !core.account(currentUser.recordName) { stop() }
            case let .switchAccounts(_, currentUser):
                core.account(currentUser.recordName)
                stop()
            case .signOut:
                core.account(nil)
                stop()
            @unknown default:
                break
            }
        case let .fetchedDatabaseChanges(f):
            if f.deletions.contains(where: { $0.zoneID == zoneID }) {
                core.zoneLost()
                syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                enqueue(core.state.unsent)
            }
        case let .fetchedRecordZoneChanges(f):
            for m in f.modifications where m.record.recordType == Self.recordType {
                let r = m.record
                core.saveTag(r.recordID.recordName, Self.tag(r))
                if let c = Self.decode(r) { core.received(r.recordID.recordName, c) }
            }
            for d in f.deletions where d.recordID.zoneID == zoneID {
                core.lostInCloud(d.recordID.recordName)
            }
        case let .sentDatabaseChanges(s):
            if s.savedZones.contains(where: { $0.zoneID == zoneID }) { core.zoneMade(true) }
            for f in s.failedZoneSaves where f.zone.zoneID == zoneID {
                core.status = .notNow(Self.plain(f.error))
            }
        case let .sentRecordZoneChanges(s):
            for r in s.savedRecords {
                let id = r.recordID.recordName
                core.saveTag(id, Self.tag(r))
                core.sent(id, sending.removeValue(forKey: id))
                if core.state.unsent.contains(id) { enqueue([id]) }
            }
            // A save went through: an earlier refusal's "not ready" no longer holds once none is left.
            if !s.savedRecords.isEmpty, core.state.refused.isEmpty, case .notNow = core.status { core.status = .on }
            for f in s.failedRecordSaves {
                let id = f.record.recordID.recordName
                sending[id] = nil
                switch f.error.code {
                case .serverRecordChanged:
                    // Another iPhone saved it first: the newest edit wins (ComputerSync), and ours goes again only if
                    // it is the newer one, on top of iCloud's copy.
                    if let server = f.error.serverRecord {
                        core.saveTag(id, Self.tag(server))
                        if let c = Self.decode(server) { core.received(id, c) }
                    }
                    if core.state.unsent.contains(id) { enqueue([id]) }
                case .zoneNotFound:
                    core.zoneMade(false)
                    syncEngine.state.add(pendingDatabaseChanges: [.saveZone(CKRecordZone(zoneID: zoneID))])
                    enqueue([id])
                case .unknownItem:
                    // The app never deletes records (removals are dated marks), so this one was lost in iCloud: it goes
                    // again from this iPhone's copy, removal mark included (review finding 2).
                    core.lostInCloud(id)
                case .networkFailure, .networkUnavailable, .zoneBusy, .serviceUnavailable, .requestRateLimited,
                     .notAuthenticated, .accountTemporarilyUnavailable:
                    break // the engine tries again by itself
                default:
                    // Not tried again by the engine: kept unsent, sent again each time the app opens (`fetchNow`, and
                    // `makeEngine` at launch). Shown in the footer; the status stays as it is, since other computers
                    // still sync.
                    core.refused(id, Self.plain(f.error))
                    SessionModel.log.error("iCloud refused a computer: \(f.error.code.rawValue)")
                }
            }
        case .didFetchChanges:
            core.fetched()
            if !core.state.joined { core.joinDone() }
            if core.status == .checking, engine != nil { core.status = .on }
        case .willFetchChanges, .willFetchRecordZoneChanges, .didFetchRecordZoneChanges, .willSendChanges,
             .didSendChanges:
            break
        @unknown default:
            break
        }
    }

    func nextRecordZoneChangeBatch(_ context: CKSyncEngine.SendChangesContext,
                                   syncEngine: CKSyncEngine) async -> CKSyncEngine.RecordZoneChangeBatch? {
        guard core.state.joined else { return nil }
        let pending = syncEngine.state.pendingRecordZoneChanges.filter { context.options.scope.contains($0) }
        return await CKSyncEngine.RecordZoneChangeBatch(pendingChanges: pending) { id in
            await MainActor.run { self.record(id) }
        }
    }

    // MARK: Records

    private func record(_ id: CKRecord.ID) -> CKRecord? {
        let name = id.recordName
        guard let c = core.record(for: name), let fields = Self.fields(c) else { return nil }
        let r = core.state.tags[name].flatMap(Self.untag) ?? CKRecord(recordType: Self.recordType, recordID: id)
        for (key, data) in fields { r.encryptedValues[key] = data }
        sending[name] = c
        return r
    }

    static func decode(_ r: CKRecord) -> CloudComputer? {
        decode([payloadField: r.encryptedValues[payloadField] as? Data,
                remoteDesktopField: r.encryptedValues[remoteDesktopField] as? Data,
                terminalSystemField: r.encryptedValues[terminalSystemField] as? Data,
                unameSystemField: r.encryptedValues[unameSystemField] as? Data])
    }

    /// The record's encrypted fields for `c`: `payload` without the Remote Desktop fields, and those on their own
    /// (none for a removal mark). Pure, for the tests.
    static func fields(_ c: CloudComputer) -> [String: Data]? {
        var p = c
        p.computer?.remoteDesktop = nil
        p.computer?.terminalSystem = nil
        p.computer?.unameSystem = nil
        guard let payload = try? JSONEncoder().encode(p) else { return nil }
        var out = [payloadField: payload]
        if let rd = c.computer?.remoteDesktop, let data = try? JSONEncoder().encode(rd) { out[remoteDesktopField] = data }
        if let ts = c.computer?.terminalSystem { out[terminalSystemField] = Data(ts.utf8) }
        if let us = c.computer?.unameSystem { out[unameSystemField] = Data(us.utf8) }
        return out
    }

    /// A record from its encrypted fields. No Remote Desktop field (a record only older builds have saved): nil, so
    /// this iPhone's own Remote Desktop values are kept.
    static func decode(_ fields: [String: Data?]) -> CloudComputer? {
        guard let data = fields[payloadField] ?? nil,
              var c = try? JSONDecoder().decode(CloudComputer.self, from: data) else { return nil }
        if let rd = fields[remoteDesktopField] ?? nil {
            c.computer?.remoteDesktop = try? JSONDecoder().decode(SyncedRemoteDesktop.self, from: rd)
        }
        if let ts = fields[terminalSystemField] ?? nil { c.computer?.terminalSystem = String(decoding: ts, as: UTF8.self) }
        if let us = fields[unameSystemField] ?? nil { c.computer?.unameSystem = String(decoding: us, as: UTF8.self) }
        return c
    }

    /// The record's change tag and identity (its system fields), to save over it next time.
    static func tag(_ r: CKRecord) -> Data {
        let coder = NSKeyedArchiver(requiringSecureCoding: true)
        r.encodeSystemFields(with: coder)
        coder.finishEncoding()
        return coder.encodedData
    }

    static func untag(_ d: Data) -> CKRecord? {
        guard let coder = try? NSKeyedUnarchiver(forReadingFrom: d) else { return nil }
        coder.requiresSecureCoding = true
        defer { coder.finishDecoding() }
        return CKRecord(coder: coder)
    }

    /// iCloud's refusals in plain words (the switch's footer).
    static func plain(_ error: Error) -> String {
        guard let ck = error as? CKError else { return "iCloud sync stopped." }
        switch ck.code {
        case .notAuthenticated: return "Sign in to iCloud to sync."
        case .quotaExceeded: return "Your iCloud storage is full."
        case .networkFailure, .networkUnavailable: return "No connection to iCloud."
        case .badContainer, .missingEntitlement, .permissionFailure, .serverRejectedRequest, .invalidArguments:
            return "iCloud is not ready for this app yet."
        default: return "iCloud sync stopped."
        }
    }
}

/// The switch in Settings (plan §A6): "Sync Computers with iCloud", on by default, its footer saying what syncs and
/// what never does, and how sync stands.
struct SyncSection: View {
    let sync: ComputerSync

    var body: some View {
        // A build without the iCloud entitlements (the public plain build) shows nothing: it cannot sync.
        if sync.status != .notInThisBuild { section }
    }

    private var section: some View {
        Section {
            Toggle("Sync Computers with iCloud", isOn: Binding(get: { sync.enabled },
                                                               set: { CloudComputerSync.shared.setEnabled($0) }))
                .accessibilityIdentifier("syncComputers")
            if sync.enabled && sync.status == .otherAccount {
                Button("Sync with This iCloud Account") { CloudComputerSync.shared.adoptOtherAccount() }
                    .accessibilityIdentifier("syncAdoptAccount")
            }
        } header: {
            Text("iCloud")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(ComputerSync.footer)
                Text(sync.enabled ? sync.status.words : ComputerSync.Status.off.words)
                    .accessibilityIdentifier("syncStatus")
                if sync.enabled && sync.status != .simulator {
                    ForEach(sync.detailLines, id: \.self) { Text($0) }
                }
                if sync.hiddenCount > 0 {
                    Text(sync.hiddenCount == 1 ? "1 computer is removed from this iPhone only. Add it again to bring it back."
                         : "\(sync.hiddenCount) computers are removed from this iPhone only. Add one again to bring it back.")
                }
            }
        }
    }
}
