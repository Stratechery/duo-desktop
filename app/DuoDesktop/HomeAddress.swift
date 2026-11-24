import GlassActSession
import GlassActTransport
import Security
import SwiftUI
import UIKit

// Touch ID clarity A. Choosing is the main way: the Macs broadcasting Glass Act Host on this network right now (the
// same Bonjour browse as Add Mac), each checked for its key; the one whose key matches this entry is marked "This Mac"
// and listed first. Typing stays as "Enter Address" for a Mac that is not broadcasting. A Mac with a different key is
// never saved here.

/// The rules, pure (tests).
@MainActor enum HomeAddressRules {
    /// What a nearby Mac is to this entry.
    enum Match: Equatable {
        /// Its key is this entry's key.
        case thisMac
        /// Its key is another Mac's: never saved.
        case otherMac
        /// Not known yet (still checking, no answer) or this entry has no key yet.
        case unknown
    }

    static func match(entryKey: String?, foundKey: String?) -> Match {
        guard let entryKey, let foundKey else { return .unknown }
        return entryKey == foundKey ? .thisMac : .otherMac
    }

    /// Whether choosing a Mac with `foundKey` may be saved for this entry (refused only on a known other key).
    static func maySave(entryKey: String?, foundKey: String?) -> Bool {
        match(entryKey: entryKey, foundKey: foundKey) != .otherMac
    }

    /// The listed order: this Mac first, then the others by name.
    static func ordered(_ hosts: [NearbyHost], keys: [String: String], entryKey: String?) -> [NearbyHost] {
        hosts.sorted { a, b in
            let am = match(entryKey: entryKey, foundKey: keys[a.id]) == .thisMac
            let bm = match(entryKey: entryKey, foundKey: keys[b.id]) == .thisMac
            if am != bm { return am }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    /// The simulator never dials a real Mac (MacList.mayProbe), so it lists only this Mac's own test hosts.
    static func listable(_ hosts: [NearbyHost]) -> [NearbyHost] {
        hosts.filter { MacList.mayProbe($0.host) }
    }

    static let homePlaceholder = "My-Mac.local"
    static let tailscalePlaceholder = "my-mac.your-tailnet.ts.net"
    static let addressesFooter = "Home Network: choose this Mac from the Macs nearby. Tailscale: the Mac’s name in Tailscale, for when you are away. Duo Desktop tries both and uses the one that answers."
    static let nearbyFooter = "Macs show here while Glass Act Host is running on them with “Visible to Nearby Viewers” on. Choose this Mac to fill in its address."
    static let nothingNearby = "No Mac on this network is broadcasting Glass Act Host. Check that this iPhone is on the same Wi‑Fi as the Mac, and that Glass Act Host is running with “Visible to Nearby Viewers” on. Or enter the address below."
    static let typeFooter = "The Mac’s local hostname, shown on the Mac in System Settings › General › Sharing › Local hostname."

    static func otherMacText(found: String, entry: String) -> String {
        "“\(found)” is a different Mac: its key does not match “\(entry)”. The address was not saved."
    }
}

/// The list of Macs nearby for one entry's home address (pushed from the Home Network row).
struct HomeAddressPicker: View {
    let store: MacStore
    let id: String
    let identity: SecIdentity?
    /// Runs after a save, so the settings screen's draft follows.
    let saved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var nearby = NearbyHosts()
    /// Each nearby Mac's key, by its id, once its Host answered.
    @State private var keys: [String: String] = [:]
    @State private var noAnswer: Set<String> = []
    @State private var asked: Set<String> = []
    @State private var lookedLong = false
    @State private var typed = ""
    @State private var typedCheck = AddressCheck()
    @State private var refusal: String?
    @State private var note: String?

    private var entry: MacEntry? { store.entry(id) }
    private var hosts: [NearbyHost] {
        HomeAddressRules.ordered(HomeAddressRules.listable(nearby.hosts), keys: keys, entryKey: entry?.key)
    }

    var body: some View {
        Form {
            Section {
                if nearby.isBlocked {
                    Text("Duo Desktop can’t look on this network. Turn on Local Network for Duo Desktop in Settings.")
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                    }
                } else if hosts.isEmpty {
                    if lookedLong {
                        Text(HomeAddressRules.nothingNearby).foregroundStyle(.secondary)
                            .accessibilityIdentifier("homeNothingNearby")
                    } else {
                        HStack(spacing: 8) { ProgressView(); Text("Looking…") }.foregroundStyle(.secondary)
                    }
                } else {
                    ForEach(hosts) { host in
                        Button { choose(host) } label: { row(host) }
                            .accessibilityIdentifier("homeNearby.\(host.name)")
                    }
                }
            } header: {
                Text("Macs on This Network")
            } footer: {
                Text(HomeAddressRules.nearbyFooter)
            }

            Section {
                TextField(HomeAddressRules.homePlaceholder, text: $typed)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .submitLabel(.done)
                    .onSubmit(checkTyped)
                    .accessibilityIdentifier("homeTyped")
                switch typedCheck.state {
                case .checking:
                    HStack(spacing: 8) { ProgressView(); Text("Checking…") }.foregroundStyle(.secondary)
                default:
                    Button("Save Address", action: checkTyped)
                        .disabled(TypedAddress(typed, tailnetSuffix: nil) == nil)
                }
                if let note { Text(note).foregroundStyle(.secondary) }
            } header: {
                Text("Enter Address")
            } footer: {
                Text(HomeAddressRules.typeFooter)
            }

            if entry?.home != nil, entry?.tailscale != nil {
                Section {
                    Button("Remove Home Address", role: .destructive) {
                        store.update(id) { $0.home = nil; $0.lastAddress = nil }
                        saved()
                        dismiss()
                    }
                }
            }
        }
        .navigationTitle("Home Network")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            nearby.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { lookedLong = true }
            askKeys()
        }
        .onChange(of: nearby.hosts) { _, _ in askKeys() }
        .onChange(of: typedCheck.state) { _, state in typedAnswered(state) }
        .onChange(of: typed) { _, _ in note = nil }
        .alert("Different Mac", isPresented: Binding(get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(refusal ?? "")
        }
    }

    @ViewBuilder private func row(_ host: NearbyHost) -> some View {
        let match = HomeAddressRules.match(entryKey: entry?.key, foundKey: keys[host.id])
        HStack(spacing: 12) {
            Image(systemName: host.symbol).foregroundStyle(.tint).frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(host.name).foregroundStyle(.primary)
                Text(subtitle(host, match)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if entry?.home?.lowercased() == host.host.lowercased() {
                Image(systemName: "checkmark").foregroundStyle(.tint)
            }
        }
        .contentShape(Rectangle())
    }

    private func subtitle(_ host: NearbyHost, _ match: HomeAddressRules.Match) -> String {
        switch match {
        case .thisMac: return "This Mac · \(host.host)"
        case .otherMac: return "A different Mac · \(host.host)"
        case .unknown:
            if noAnswer.contains(host.id) { return "Did not answer · \(host.host)" }
            return keys[host.id] == nil ? "Checking… · \(host.host)" : host.host
        }
    }

    /// Learns each nearby Mac's key once (no pin: listing is not trust; the entry's key decides).
    private func askKeys() {
        for host in HomeAddressRules.listable(nearby.hosts) where !asked.contains(host.id) {
            asked.insert(host.id)
            MacList.check(host: host.host, port: host.port, pin: "", identity: identity, timeout: 4) { outcome in
                if outcome.response != nil, let key = outcome.hostFingerprint {
                    keys[host.id] = key
                    noAnswer.remove(host.id)
                } else {
                    noAnswer.insert(host.id)
                }
            }
        }
    }

    private func choose(_ host: NearbyHost) {
        guard let entry else { return }
        let found = keys[host.id]
        guard HomeAddressRules.maySave(entryKey: entry.key, foundKey: found) else {
            refusal = HomeAddressRules.otherMacText(found: host.name, entry: entry.name)
            return
        }
        save(host: host.host, key: found)
    }

    private func checkTyped() {
        guard let a = TypedAddress(typed, tailnetSuffix: nil) else { return }
        note = nil
        typedCheck.run(a, identity: identity)
    }

    /// A typed address: refused if a Host answers there with another Mac's key; saved if it is this Mac or does not
    /// answer right now (a Mac that is asleep or away still gets its address).
    private func typedAnswered(_ state: AddressCheck.State) {
        guard let entry, let a = typedCheck.checked else { return }
        switch state {
        case let .found(key):
            guard HomeAddressRules.maySave(entryKey: entry.key, foundKey: key) else {
                refusal = HomeAddressRules.otherMacText(found: a.host, entry: entry.name)
                typedCheck.reset()
                return
            }
            save(host: a.host, key: key)
        case .noAnswer:
            store.update(id) { $0.home = a.host; $0.lastAddress = nil }
            saved()
            note = "Saved. No Glass Act Host answered at \(a.host) just now."
        case .locked:
            note = AddressCheck.lockedText
        case .idle, .checking:
            break
        }
    }

    private func save(host: String, key: String?) {
        store.update(id) { e in
            e.home = host
            e.lastAddress = nil
            if e.key == nil, let key { e.key = key } // first key, as Add Mac does
        }
        saved()
        dismiss()
    }
}
