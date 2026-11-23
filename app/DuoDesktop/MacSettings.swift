import GlassActSession
import GlassActTransport
import Security
import SwiftUI
import UIKit

// The Mac list's two screens (project notes §5.2, §5.3): Add Mac (a sheet, HIG Modality:
// "a distinct, narrowly scoped task") and a Mac's settings (pushed from the row's ⓘ). Terminal and JetKVM plug in
// here when they are built; until then they are left out (no dead switches).

/// What a typed address means: host and port (`host` or `host:port`, port 4433 when none).
struct TypedAddress: Equatable {
    let host: String
    let port: UInt16

    init?(_ text: String, tailnetSuffix: String?) {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !t.contains(" ") else { return nil }
        var port: UInt16 = 4433
        if let colon = t.lastIndex(of: ":"), let p = UInt16(t[t.index(after: colon)...]) {
            port = p
            t = String(t[..<colon])
        }
        while t.hasSuffix(".") { t.removeLast() }
        guard !t.isEmpty else { return nil }
        // A bare Tailscale name (my-mac) is saved in full, so it keeps working whatever the search
        // domains (plan §1): the tailnet's suffix comes from a Tailscale address already in the list.
        if !t.contains("."), t != "localhost", let suffix = tailnetSuffix { t += "." + suffix }
        host = t
        self.port = port
    }

    /// "example-tailnet.ts.net" from any stored `*.ts.net` address.
    static func tailnetSuffix(in macs: [MacEntry]) -> String? {
        for m in macs {
            guard let a = m.tailscale?.lowercased(), a.hasSuffix(".ts.net"), let dot = a.firstIndex(of: ".") else { continue }
            return String(a[a.index(after: dot)...])
        }
        return nil
    }
}

/// The check that a Glass Act Host answers at an address, and the key it showed (plan §5.2).
@MainActor @Observable
final class AddressCheck {
    enum State: Equatable {
        case idle
        case checking
        /// A Glass Act Host answered and showed this key.
        case found(key: String)
        case noAnswer
    }

    private(set) var state: State = .idle
    private(set) var checked: TypedAddress?
    private var generation = 0

    func run(_ address: TypedAddress, identity: SecIdentity?) {
        generation += 1
        let g = generation
        checked = address
        state = .checking
        // No pin: this only learns the key (and spots a Mac already in the list). The key is then stored with the
        // entry and every later connection to any of its addresses is held to it.
        MacList.check(host: address.host, port: address.port, pin: "", identity: identity, timeout: 4) { [weak self] outcome in
            guard let self, self.generation == g else { return }
            if outcome.response != nil, let key = outcome.hostFingerprint {
                self.state = .found(key: key)
            } else {
                self.state = .noAnswer
            }
        }
    }

    func reset() {
        generation += 1
        state = .idle
        checked = nil
    }
}

struct AddMacSheet: View {
    let store: MacStore
    let identity: SecIdentity?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var nearby = NearbyHosts()
    @State private var check = AddressCheck()
    @State private var typed = SimulatorSwitches.addMacAddress ?? ""
    @State private var picked: NearbyHost?
    @State private var name = ""
    @State private var nameEdited = false
    @State private var lookedLong = false
    @State private var sameMac: MacEntry?
    @FocusState private var addressFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if nearby.isBlocked {
                        Text("Duo Desktop can’t look on this network. Turn on Local Network for Duo Desktop in Settings.")
                        Button("Open Settings") {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        }
                    } else if nearby.hosts.isEmpty {
                        Text(lookedLong ? "No Macs found." : "Looking…").foregroundStyle(.secondary)
                    } else {
                        ForEach(nearby.hosts) { host in
                            Button { pick(host) } label: {
                                HStack {
                                    Label(host.name, systemImage: host.symbol).foregroundStyle(.primary)
                                    Spacer()
                                    if picked == host { Image(systemName: "checkmark").foregroundStyle(.tint) }
                                }
                            }
                            .accessibilityIdentifier("nearby.\(host.name)")
                        }
                    }
                } header: {
                    Text("On This Network")
                } footer: {
                    Text("Only Macs with “Visible to Nearby Viewers” on are listed.")
                }

                Section {
                    TextField("Name or address", text: $typed)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .focused($addressFocused)
                        .onSubmit(checkTyped)
                        .accessibilityIdentifier("addAddress")
                    if picked == nil { checkLine }
                } header: {
                    Text("Or Type an Address")
                } footer: {
                    Text("A Tailscale name (my-mac) or a home name (My-Mac.local).")
                }

                Section("Name") {
                    TextField("Name", text: Binding(get: { name }, set: { name = $0; nameEdited = true }))
                        .accessibilityIdentifier("addName")
                }
            }
            .navigationTitle("Add Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", action: add).disabled(!canAdd).accessibilityIdentifier("addConfirm")
                }
            }
            .alert("Same Mac", isPresented: Binding(get: { sameMac != nil }, set: { if !$0 { sameMac = nil } }),
                   presenting: sameMac) { existing in
                Button("Add Address") { addAddress(to: existing) }
                Button("Cancel", role: .cancel) {}
            } message: { existing in
                Text("This is “\(existing.name)”, already in your list. Add this address to it?")
            }
        }
        .onAppear {
            // Asking for Local Network here, where the reason is plain (HIG Privacy; plan §5).
            nearby.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { lookedLong = true }
            if !typed.isEmpty { checkTyped() }
        }
        .onChange(of: typed) { _, _ in
            if picked != nil { picked = nil }
            check.reset()
        }
        .onChange(of: check.state) { _, state in
            if case .found = state, !nameEdited, name.isEmpty, let a = check.checked {
                name = picked?.name ?? Self.suggestedName(a.host)
            }
        }
    }

    @ViewBuilder private var checkLine: some View {
        switch check.state {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: 8) { ProgressView(); Text("Checking…") }.foregroundStyle(.secondary)
        case .found:
            Label("Found Glass Act Host", systemImage: "checkmark").foregroundStyle(.green)
                .accessibilityIdentifier("addFound")
        case .noAnswer:
            Text("No Glass Act Host answered at this address.").foregroundStyle(.secondary)
            // Reviewer finding 2: the first home-network try can fail before the Local Network question is answered,
            // and the check does not wait for it. An explicit retry, without editing the address.
            Button("Check Again", action: checkTyped).accessibilityIdentifier("addCheckAgain")
        }
    }

    private var canAdd: Bool {
        if case .found = check.state, !name.trimmingCharacters(in: .whitespaces).isEmpty { return true }
        return false
    }

    private func checkTyped() {
        guard let a = TypedAddress(typed, tailnetSuffix: TypedAddress.tailnetSuffix(in: store.macs)) else { return }
        picked = nil
        check.run(a, identity: identity)
    }

    private func pick(_ host: NearbyHost) {
        addressFocused = false
        typed = ""
        picked = host
        if !nameEdited { name = host.name }
        check.run(TypedAddress(host: host.host, port: host.port), identity: identity)
    }

    private func add() {
        guard case let .found(key) = check.state, let a = check.checked else { return }
        if let existing = store.entry(withKey: key) {
            sameMac = existing
            return
        }
        var e = MacEntry(name: name.trimmingCharacters(in: .whitespaces), port: a.port)
        e.set(AddressKind.of(a.host), a.host)
        e.key = key
        store.add(e)
        dismiss()
    }

    private func addAddress(to existing: MacEntry) {
        guard let a = check.checked else { return }
        store.update(existing.id) { $0.set(AddressKind.of(a.host), a.host) }
        dismiss()
    }

    /// "My-Mac.local" → "My-Mac"; "other-mac.example-tailnet.ts.net" → "other-mac".
    static func suggestedName(_ host: String) -> String {
        if host == "localhost" { return "Test host" }
        return String(host.split(separator: ".").first ?? Substring(host))
    }
}

extension TypedAddress {
    init(host: String, port: UInt16) {
        var h = host
        while h.hasSuffix(".") { h.removeLast() }
        self.host = h
        self.port = port
    }
}

/// A Mac's settings (plan §5.3), with what exists today: name, the two addresses, port, the Mac's key, remove.
struct MacSettingsScreen: View {
    let store: MacStore
    let id: String
    let chosen: AddressKind?
    /// The app lock: Unlock Automatically's "Turn On Require Touch ID" row (nil: the stored setting is read only).
    var lock: AppLock? = nil
    /// This iPhone's Glass Act identity, for the home address picker's key checks.
    var identity: SecIdentity? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MacEntry?
    @State private var port = ""
    @State private var forgetting = false
    @State private var removing: MacEntry?
    /// Only `--home-picker` (simulator pictures) opens the list without a tap.
    @State private var homePickerBySwitch = SimulatorSwitches.openHomePicker

    var body: some View {
      ScrollViewReader { proxy in
        Form {
            if let entry = store.entry(id) {
                Section("Name") {
                    TextField("Name", text: field(\.name)).accessibilityIdentifier("settingsName")
                }
                Section {
                    // Touch ID clarity A (the owner 2026-11-22: "Shouldn't I be able to just select a Mac that is
                    // broadcasting instead of typing a name?"): the home address is chosen from the Macs nearby
                    // (HIG Lists: a row with a disclosure indicator opens a list to choose from, as Settings › Wi-Fi).
                    NavigationLink {
                        HomeAddressPicker(store: store, id: id, identity: identity) {
                            draft?.home = store.entry(id)?.home
                        }
                    } label: {
                        LabeledContent("Home Network") {
                            Text(draft?.home ?? "Choose…")
                                .foregroundStyle(draft?.home == nil ? Color.accentColor : .secondary)
                        }
                    }
                    .accessibilityIdentifier("settingsHome")
                    LabeledContent("Tailscale") {
                        TextField(HomeAddressRules.tailscalePlaceholder, text: address(.tailscale))
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                            .accessibilityIdentifier("settingsTailscale")
                    }
                    LabeledContent("Port") {
                        TextField("4433", text: $port).multilineTextAlignment(.trailing).keyboardType(.numberPad)
                            .onSubmit(save)
                    }
                } header: {
                    Text("Addresses")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(HomeAddressRules.addressesFooter)
                        if let last = entry.lastAddress { Text("Last used: \(last.label).") }
                        if draft.map({ $0.addresses.isEmpty }) == true { Text("At least one address is needed.") }
                    }
                }
                AutoUnlockSection(store: store, id: id, lock: lock)
                #if DUO_TERMINAL
                TerminalSettingsSection(store: store, id: id)
                #endif
                #if DUO_JETKVM
                JetKVMSettingsSection(store: store, id: id)
                #endif
                Section {
                    LabeledContent("Key", value: entry.key.map(QUICIdentity.keyString) ?? "Not yet seen")
                        .font(.body.monospaced())
                    if entry.key != nil {
                        Button("Forget Key", role: .destructive) { forgetting = true }
                    }
                } header: {
                    Text("Mac’s Key")
                } footer: {
                    // Reviewer wording correction: reinstalling Glass Act Host keeps the Mac's key.
                    Text("Forget only if you know this Mac’s Glass Act identity was reset or replaced.")
                }
                .id("settings.macKey")
                Section {
                    Button("Remove Mac", role: .destructive) { removing = entry }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationDestination(isPresented: $homePickerBySwitch) {
            HomeAddressPicker(store: store, id: id, identity: identity) { draft?.home = store.entry(id)?.home }
        }
        .onAppear {
            // `--settings-at-end` (simulator only, README pictures): scrolls down to the Mac's key (Terminal and
            // JetKVM above it), as a finger would.
            guard SimulatorSwitches.settingsAtEnd else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { proxy.scrollTo("settings.macKey", anchor: .bottom) }
        }
      }
        .navigationTitle(draft?.name ?? store.entry(id)?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            draft = store.entry(id)
            port = draft.map { String($0.port) } ?? ""
        }
        .onDisappear(perform: save)
        .alert("Forget the key for “\(draft?.name ?? "")”?", isPresented: $forgetting) {
            Button("Forget", role: .destructive) {
                store.update(id) { $0.key = nil; $0.lastAddress = nil }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next connection trusts whatever key the Mac shows.")
        }
        .modifier(RemoveMacAlert(mac: $removing) { e in
            store.remove(e.id)
            dismiss()
        })
    }

    private func field(_ path: WritableKeyPath<MacEntry, String>) -> Binding<String> {
        Binding(get: { draft?[keyPath: path] ?? "" }, set: { draft?[keyPath: path] = $0; save() })
    }

    private func address(_ kind: AddressKind) -> Binding<String> {
        Binding(get: { (kind == .home ? draft?.home : draft?.tailscale) ?? "" },
                set: { draft?.set(kind, $0); save() })
    }

    /// Edits save as they are made, except an entry left with no address or no name (the old values stay).
    private func save() {
        guard var d = draft, store.entry(id) != nil else { return }
        if let p = UInt16(port), p > 0 { d.port = p }
        let name = d.name.trimmingCharacters(in: .whitespaces)
        store.update(id) { e in
            if !name.isEmpty { e.name = name }
            if !d.addresses.isEmpty {
                if e.home != d.home || e.tailscale != d.tailscale { e.lastAddress = nil }
                e.home = d.home
                e.tailscale = d.tailscale
            }
            e.port = d.port
        }
    }
}

/// "Remove “my-mac”?" (plan §5.3; HIG Alerts: a Cancel button, a one-word destructive action).
struct RemoveMacAlert: ViewModifier {
    @Binding var mac: MacEntry?
    let remove: (MacEntry) -> Void

    func body(content: Content) -> some View {
        content.alert("Remove “\(mac?.name ?? "")”?", isPresented: Binding(get: { mac != nil }, set: { if !$0 { mac = nil } }),
                      presenting: mac) { e in
            Button("Remove", role: .destructive) { remove(e) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(mac?.isTerminal == true ? "Its settings are deleted from this iPhone. The computer is not changed."
                 : "Its key and settings are deleted from this iPhone. The Mac is not changed.")
        }
    }
}
