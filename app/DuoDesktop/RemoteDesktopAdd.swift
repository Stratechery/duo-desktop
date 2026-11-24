import SwiftUI

// A Windows PC's Remote Desktop fields and settings. A PC is added through the one Add Computer sheet, Start With ›
// Remote Desktop, and Remote Desktop can be added to an existing computer from its ⓘ page the same way. Missing fields
// are said in place (HIG: validate in place, say how to fix it). The password is typed at the first connect and, with
// Remember Password (milestone 3), kept in the Keychain behind the app lock (RemoteDesktopSignIn.swift).

/// The PC's fields, pure (tests): what the sheet and the ⓘ page save.
struct RDPForm: Equatable {
    var name = ""
    var address = ""
    var port = "3389"
    var user = ""
    var size: RDPScreen.Size = .default
    var textSize: RDPScreen.TextSize = .default

    init() {}

    init(_ e: MacEntry) {
        name = e.name
        address = e.address(.tailscale) ?? e.address(.home) ?? ""
        port = String(e.rdpPortValue)
        user = e.rdpUser ?? ""
        size = e.rdpSize ?? .default
        textSize = e.rdpTextSize ?? .default
    }

    private static func t(_ s: String) -> String { s.trimmingCharacters(in: .whitespaces) }

    /// nil when the fields can be saved; else what is missing, in plain words (the Terminal sheet's wording).
    var problem: String? {
        if Self.t(name).isEmpty { return "Type a name." }
        if Self.t(address).isEmpty { return "Type the PC’s address." }
        if Self.t(address).contains(" ") { return "An address has no spaces." }
        if Self.t(user).isEmpty { return "Type the user name to sign in as." }
        guard let p = UInt16(Self.t(port)), p > 0 else { return "The port is a number from 1 to 65535." }
        _ = p
        return nil
    }

    /// Writes the fields into a PC entry (nothing else of it changes).
    func apply(to e: inout MacEntry) {
        e.name = Self.t(name)
        e.home = nil; e.tailscale = nil
        let a = Self.t(address)
        if !a.isEmpty { e.set(AddressKind.of(a), a) }
        e.rdpPort = UInt16(Self.t(port)) ?? 3389
        e.rdpUser = Self.t(user)
        e.rdpSize = size
        e.rdpTextSize = textSize
    }

    /// Remote Desktop added to an existing computer (its ⓘ page): its address joins the computer's (the Terminal shares
    /// them), the port and user name are set, Size and Text Size keep what it had. Its name and other ways in stay.
    func addWay(to e: inout MacEntry) {
        let a = Self.t(address)
        e.screenSharing = false
        e.remoteDesktop = true
        e.set(AddressKind.of(a), a)
        e.rdpPort = UInt16(Self.t(port)) ?? 3389
        e.rdpUser = Self.t(user)
    }

    /// A new PC: Remote Desktop in the Screen Sharing slot (`remoteDesktop`, never Glass Act), nothing else.
    func newEntry() -> MacEntry {
        var e = MacEntry(name: "")
        e.screenSharing = false
        e.terminal = false
        e.jetkvm = false
        e.remoteDesktop = true
        apply(to: &e)
        e.kind = .terminal  // older builds read only `kind`: "no Glass Act" (as `MacStore.update` keeps it)
        return e
    }

    /// Saves a new PC through the list (its Opens In starts as Screen Sharing, the PC's one way in). Returns its id,
    /// or nil with nothing saved when a field is missing.
    @MainActor @discardableResult
    func add(to store: MacStore) -> String? {
        guard problem == nil else { return nil }
        let e = newEntry()
        store.addNew(e, startWith: .screenSharing)
        return e.id
    }

    /// The foot of the sheet: what the PC needs (plan §5, Microsoft's own steps).
    static let needs = "The PC needs Windows Pro, Enterprise or Education (Home can’t be connected to). On the PC, an administrator opens Start > Settings > System > Remote Desktop and turns on Enable Remote Desktop. The user name must be allowed to connect: administrators are, others are added there under Remote Desktop users."
    static let addressFoot = "The PC’s Tailscale name (my-pc) if it is on your tailnet, or its home name (my-pc.local). Never open port 3389 on your router."
    static let passwordFoot = "You type the password the first time you connect. Connecting signs out whoever is using the PC’s screen. \(RDPSignIn.pinRule)"
}

#if DUO_RDP

/// Address and Port, the same rows in the sheet and on the ⓘ page.
struct RDPAddressFields: View {
    @Binding var form: RDPForm
    let prefix: String
    let header: String
    var body: some View {
        Section {
            TextField("my-pc", text: $form.address)
                .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                .accessibilityIdentifier("\(prefix)Address")
            LabeledContent("Port") {
                TextField("3389", text: $form.port).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                    .accessibilityIdentifier("\(prefix)Port")
            }
        } header: {
            Text(header)
        } footer: {
            Text(RDPForm.addressFoot)
        }
    }
}

/// The PC's Remote Desktop settings on its ⓘ page, under the header Remote Desktop: Address, Port, User Name, Screen (Size, Text Size; used at the
/// next connect) and "Don't Ask Again for This PC". Edits save as they are made, except a field left blank or
/// wrong (the saved value stays, as the Terminal's section does). The Name is the page's own first row.
struct RemoteDesktopSettingsSection: View {
    let store: MacStore
    let id: String
    @State private var form = RDPForm()
    @State private var forgetting = SimulatorSwitches.rdpPrompt == "forget"

    var body: some View {
        if let e = store.entry(id) {
            RDPAddressFields(form: Binding(get: { form }, set: { form = $0; save() }), prefix: "settingsPC",
                             header: "Remote Desktop")
                .onAppear { form = RDPForm(e) }
            Section {
                LabeledContent("User Name") {
                    TextField("Required", text: Binding(get: { form.user }, set: { form.user = $0; save() }))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("settingsPCUser")
                }
                // Milestone 3: Remember Password, only behind the app lock; turning it off deletes the saved one.
                Toggle("Remember Password", isOn: Binding(get: { lockOn && RDPSignIn.rememberOn(e) }, set: { v in
                    store.update(id) { $0.rdpRememberPassword = v }
                    if !v { store.rdpPasswords.delete(pcID: id) }
                }))
                .disabled(!lockOn)
                .accessibilityIdentifier("settingsPCRemember")
            } header: {
                Text("Sign In")
            } footer: {
                Text(RDPForm.passwordFoot + "\n\n" + RDPSignIn.rememberFooter(appLockOn: lockOn,
                                                                            lockHint: UnlockMethod.current.turnOnRequiredHint))
            }
            Section {
                if let fp = e.rdpCertificate {
                    LabeledContent("SHA-256") {
                        Text(fp).font(.caption.monospaced()).multilineTextAlignment(.trailing).textSelection(.enabled)
                    }
                    Button("Forget Certificate", role: .destructive) { forgetting = true }
                        .accessibilityIdentifier("settingsPCForgetCertificate")
                } else {
                    Text("None trusted yet. The app shows the PC’s certificate the next time you connect.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Certificate")
            } footer: {
                Text("The app connects only while the PC shows the certificate you trusted.")
            }
            .confirmationDialog("Forget \(e.name)’s certificate?", isPresented: $forgetting, titleVisibility: .visible) {
                Button("Forget Certificate", role: .destructive) { store.update(id) { $0.rdpCertificate = nil } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(RDPTrust.forgetText)
            }
            Section {
                Picker("Size", selection: Binding(get: { e.rdpSize ?? .default },
                                                  set: { v in store.update(id) { $0.rdpSize = v } })) {
                    ForEach(RDPScreen.Size.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settingsPCSize")
                Picker("Text Size", selection: Binding(get: { e.rdpTextSize ?? .default },
                                                       set: { v in store.update(id) { $0.rdpTextSize = v } })) {
                    ForEach(RDPScreen.TextSize.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("settingsPCTextSize")
            } header: {
                Text("Screen")
            } footer: {
                Text("The screen Windows draws for this iPhone. A change is used the next time you connect.")
            }
            Section {
                Toggle("Don’t Ask Again for This PC", isOn: Binding(get: { e.rdpSkipTakeover ?? false },
                                                                    set: { v in store.update(id) { $0.rdpSkipTakeover = v } }))
                    .accessibilityIdentifier("settingsPCSkipTakeover")
            } footer: {
                Text("When off, the app reminds you before each connect that it signs out whoever is using the PC’s screen.")
            }
        }
    }

    private var lockOn: Bool { RDPSignIn.canRemember(appLockOn: AppLock.isOn(in: .standard)) }

    /// Writes the typed fields while they can be saved (the name is the page's own).
    private func save() {
        guard var e = store.entry(id) else { return }
        var f = form
        f.name = e.name
        guard f.problem == nil else { return }
        f.apply(to: &e)
        store.update(id) { $0 = e }
    }
}

#endif
