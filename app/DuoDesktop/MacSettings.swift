import GlassActSession
import GlassActTransport
import Security
import SwiftUI
import UIKit

// A computer's settings (pushed from the row's ⓘ; project notes §5.3, and since
// project notes, one computer with any connection milestone 2 one section per way in), and the Glass Act address check the Add
// Computer sheet (AddComputer.swift) uses for Screen Sharing.

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
        /// The app locked: nothing is asked while it is locked, and an answer that comes back after is dropped.
        case locked
    }

    static let lockedText = "Not checked: the app locked."
    static var deadlineSeconds: Double = 10

    private(set) var state: State = .idle
    private(set) var checked: TypedAddress?
    private var generation = 0

    func run(_ address: TypedAddress, identity: SecIdentity?) {
        generation += 1
        let g = generation
        checked = address
        guard AppAccess.isOpen else { state = .locked; return }
        state = .checking
        // Project notes 2: whatever happens underneath, "Checking…" ends by a deadline as no answer.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.deadlineSeconds) { [weak self] in
            guard let self, self.generation == g, self.state == .checking else { return }
            self.generation += 1
            self.state = AppAccess.isOpen ? .noAnswer : .locked
        }
        // No pin: this only learns the key (and spots a Mac already in the list). The key is then stored with the
        // entry and every later connection to any of its addresses is held to it.
        MacList.check(host: address.host, port: address.port, pin: "", identity: identity, timeout: 4) { [weak self] outcome in
            guard let self, self.generation == g else { return }
            if !AppAccess.isOpen {
                self.state = .locked
            } else if outcome.response != nil, let key = outcome.hostFingerprint {
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

extension TypedAddress {
    init(host: String, port: UInt16) {
        var h = host
        while h.hasSuffix(".") { h.removeLast() }
        self.host = h
        self.port = port
    }
}

/// A computer's ⓘ page (project notes, one computer with any connection milestone 2): its name, then a section for each way in
/// (Screen Sharing, Terminal, JetKVM). One that is set up shows its settings, as before; one that is not shows a
/// single Add… row, which opens the Add sheet for that way in (HIG Lists: a row that starts an action reads as a
/// button). Any way in can be removed while another remains (HIG Alerts: confirm, with a one-word destructive
/// button); removing the last one removes the computer, asked first. Only the ways in this build can show appear.
struct ComputerSettingsScreen: View {
    let store: MacStore
    let id: String
    let chosen: AddressKind?
    /// The app lock: Unlock Automatically's "Turn On Require Touch ID" row (nil: the stored setting is read only).
    var lock: AppLock? = nil
    /// This iPhone's Glass Act identity, for the home address picker's key checks and Add Screen Sharing.
    var identity: SecIdentity? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MacEntry?
    @State private var port = ""
    @State private var forgetting = false
    @State private var removing: MacEntry?
    /// The way in whose Remove was tapped (asked first).
    @State private var removingWay: WayIn?
    /// The way in being added (the Add sheet).
    @State private var adding: WayIn? = SimulatorSwitches.addWayOnSettings
    /// Only `--home-picker` (simulator pictures) opens the list without a tap.
    @State private var homePickerBySwitch = SimulatorSwitches.openHomePicker

    var body: some View {
      ScrollViewReader { proxy in
        Form {
            if let entry = store.entry(id) {
                Section("Name") {
                    TextField("Name", text: field(\.name)).accessibilityIdentifier("settingsName")
                }
                if entry.hasScreenSharing {
                    screenSharing(entry)
                } else {
                    addRow(.screenSharing, footer: "For a Mac running Glass Act Host.")
                }
                #if DUO_TERMINAL
                if entry.hasTerminal {
                    if entry.hasScreenSharing {
                        TerminalSettingsSection(store: store, id: id)
                    } else {
                        TerminalComputerSection(store: store, id: id)
                    }
                    removeRow(.terminal)
                } else {
                    addRow(.terminal, footer: "Any computer you reach over SSH.")
                }
                #endif
                #if DUO_JETKVM
                if entry.jetkvm == true {
                    JetKVMSettingsSection(store: store, id: id)
                    removeRow(.jetkvm)
                } else {
                    addRow(.jetkvm, footer: "A JetKVM plugged into this computer: its screen, keyboard and mouse, with nothing installed on the computer.")
                }
                #endif
                Section {
                    Button("Remove Computer", role: .destructive) { removing = entry }
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("settingsRemoveComputer")
                }
                .id("settings.end")
            }
        }
        .navigationDestination(isPresented: $homePickerBySwitch) {
            HomeAddressPicker(store: store, id: id, identity: identity) { draft?.home = store.entry(id)?.home }
        }
        .onAppear {
            // `--press-remove WAY` (simulator only, live check): Remove for that way in, then the alert's Remove.
            if let way = SimulatorSwitches.pressRemove {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    proxy.scrollTo("settings.remove.\(way.rawValue)", anchor: .center)
                    if let e = store.entry(id), e.setUpWays == [way] { removing = e } else { removingWay = way }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                    if let e = removing { removing = nil; store.remove(e.id); dismiss() }
                    else if let w = removingWay { removingWay = nil; save(); store.removeWay(w, from: id); reload() }
                }
            }
            // `--settings-at-end` (simulator only, README pictures): scrolls down to the end, as a finger would.
            guard SimulatorSwitches.settingsAtEnd else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { proxy.scrollTo("settings.end", anchor: .bottom) }
        }
      }
        .navigationTitle(draft?.name ?? store.entry(id)?.name ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
        .onDisappear(perform: save)
        .sheet(item: $adding, onDismiss: reload) { way in
            AddComputerSheet(store: store, identity: identity, existingID: id, fixedWay: way)
        }
        .alert("Forget the key for “\(draft?.name ?? "")”?", isPresented: $forgetting) {
            Button("Forget", role: .destructive) {
                store.update(id) { $0.key = nil; $0.lastAddress = nil }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The next connection trusts whatever key the Mac shows.")
        }
        .alert("Remove \(removingWay?.label ?? "")?", isPresented: Binding(get: { removingWay != nil },
                                                                          set: { if !$0 { removingWay = nil } }),
               presenting: removingWay) { way in
            Button("Remove", role: .destructive) {
                save()
                store.removeWay(way, from: id)
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: { way in
            Text(Self.removeWayMessage(way, name: draft?.name ?? ""))
        }
        .modifier(RemoveMacAlert(mac: $removing) { e in
            store.remove(e.id)
            dismiss()
        })
    }

    static func removeWayMessage(_ way: WayIn, name: String) -> String {
        switch way {
        case .screenSharing:
            "“\(name)” stays in the list with its other ways in. Its Glass Act key and saved Mac password are deleted from this iPhone."
        case .terminal:
            "“\(name)” stays in the list with its other ways in."
        case .jetkvm:
            "“\(name)” stays in the list with its other ways in. The JetKVM password is deleted from this iPhone."
        }
    }

    /// Screen Sharing's settings, as a Mac's settings were: the addresses and port, Unlock Automatically, the Mac's
    /// key, and Remove Screen Sharing.
    @ViewBuilder private func screenSharing(_ entry: MacEntry) -> some View {
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
            Text("Screen Sharing")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text(HomeAddressRules.addressesFooter)
                if let last = entry.lastAddress { Text("Last used: \(last.label).") }
                if draft.map({ $0.addresses.isEmpty }) == true { Text("At least one address is needed.") }
            }
        }
        AutoUnlockSection(store: store, id: id, lock: lock)
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
        removeRow(.screenSharing)
    }

    /// A way in that is not set up: one row, "Add Terminal…" (an ellipsis: it opens a sheet that asks for more).
    private func addRow(_ way: WayIn, footer: String) -> some View {
        Section {
            Button("Add \(way.label)…") { adding = way }
                .accessibilityIdentifier("settingsAdd.\(way.rawValue)")
        } header: {
            Text(way.label)
        } footer: {
            Text(footer)
        }
    }

    /// Remove this way in. The last one removes the computer (the same question as Remove Computer).
    private func removeRow(_ way: WayIn) -> some View {
        Section {
            Button("Remove \(way.label)", role: .destructive) {
                if let e = store.entry(id), e.setUpWays == [way] { removing = e } else { removingWay = way }
            }
            .accessibilityIdentifier("settingsRemove.\(way.rawValue)")
        }
        .id("settings.remove.\(way.rawValue)")
    }

    private func reload() {
        draft = store.entry(id)
        port = draft.map { String($0.port) } ?? ""
    }

    private func field(_ path: WritableKeyPath<MacEntry, String>) -> Binding<String> {
        Binding(get: { draft?[keyPath: path] ?? "" }, set: { draft?[keyPath: path] = $0; save() })
    }

    private func address(_ kind: AddressKind) -> Binding<String> {
        Binding(get: { (kind == .home ? draft?.home : draft?.tailscale) ?? "" },
                set: { draft?.set(kind, $0); save() })
    }

    /// Edits save as they are made, except an entry left with no address or no name (the old values stay). The
    /// addresses and port are Screen Sharing's: written only while it is set up (a Terminal-only computer's
    /// address is edited in its own section, straight into the list).
    private func save() {
        guard let d = draft, let current = store.entry(id) else { return }
        let name = d.name.trimmingCharacters(in: .whitespaces)
        let screenSharing = current.hasScreenSharing
        let p = UInt16(port).flatMap { $0 > 0 ? $0 : nil }
        store.update(id) { e in
            if !name.isEmpty { e.name = name }
            guard screenSharing else { return }
            if !d.addresses.isEmpty {
                if e.home != d.home || e.tailscale != d.tailscale { e.lastAddress = nil }
                e.home = d.home
                e.tailscale = d.tailscale
            }
            if let p { e.port = p }
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
            Text(mac?.hasScreenSharing == false ? "Its settings are deleted from this iPhone. The computer is not changed."
                 : "Its key and settings are deleted from this iPhone. The Mac is not changed.")
        }
    }
}
