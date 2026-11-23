import GlassActSession
import GlassActTransport
import Security
import SwiftUI
import UIKit

// Add Computer (project notes, one computer with any connection, milestone 2). the owner 2026-11-22: "You should choose to add
// a computer and then choose what to start with: screen sharing or terminal or jetkvm. Then you can add the others".
// One sheet (HIG Sheets: "a distinct, narrowly scoped task"): Name, then Start With, a segmented control (HIG
// Segmented controls: closely related, mutually exclusive choices that change what the view below shows), then
// only that way in's fields. Add checks that one way in and says what happened in place (HIG: validate in place,
// say how to fix it). The same sheet, from a computer's ⓘ page, adds one more way in to that computer.

/// Set when a check's deadline passed (project notes 2), read by the check that it cut short.
@MainActor final class DeadlineFlag { var passed = false }

/// What the Add check said, in place.
struct AddCheckResult: Equatable {
    let ok: Bool
    let text: String
}

struct AddComputerSheet: View {
    let store: MacStore
    let identity: SecIdentity?
    /// From a computer's ⓘ page: that computer (no Name, no Start With: the way in is `fixedWay`).
    let existingID: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var name: String
    @State private var way: WayIn
    // Screen Sharing (Glass Act Host), as the Add Mac sheet before it.
    @State private var nearby = NearbyHosts()
    @State private var check = AddressCheck()
    @State private var typed: String
    @State private var picked: NearbyHost?
    @State private var lookedLong = false
    @State private var sameMac: MacEntry?
    /// Add was pressed before the Glass Act check finished: add as soon as it finds the Host.
    @State private var addWhenFound = false
    // Terminal (SSH), as the Add Terminal Computer sheet before it.
    @State private var address: String
    @State private var port: String
    @State private var user: String
    @State private var signIn: TerminalSignIn
    @State private var opens: TerminalOpens
    // JetKVM.
    @State private var kvmAddress: String
    @State private var kvmPassword = ""

    // Project notes 5/6: the Terminal check's steps, said in place, and the one-time password sign-in that
    // adds this iPhone's key when the computer does not accept it yet.
    @State private var steps: [String] = []
    @State private var keyHelp: KeyHelp = .none
    @State private var sshPassword = ""
    @State private var installing = false
    @State private var installNote: String?
    @State private var appOpen = AppAccess.isOpen
    enum KeyHelp { case none, password, copyOnly }

    @State private var problem: String?
    /// After Add: the computer is saved and its check runs and reports here.
    @State private var added: String?
    @State private var result: AddCheckResult?

    init(store: MacStore, identity: SecIdentity?, existingID: String? = nil, fixedWay: WayIn? = nil) {
        self.store = store
        self.identity = identity
        self.existingID = existingID
        let e = existingID.flatMap { store.entry($0) }
        let fields = SimulatorSwitches.addFields
        _name = State(initialValue: fields?.name ?? "")
        _way = State(initialValue: fixedWay ?? SimulatorSwitches.addComputerWay ?? .screenSharing)
        _typed = State(initialValue: SimulatorSwitches.addMacAddress ?? "")
        // A way in added later starts from what the computer already has (the Terminal shares its addresses).
        _address = State(initialValue: fields?.address ?? e.flatMap { $0.address(.tailscale) ?? $0.address(.home) } ?? "")
        _port = State(initialValue: String(e?.sshPort ?? 22))
        _user = State(initialValue: fields?.user ?? e?.sshUser ?? "")
        _signIn = State(initialValue: e?.terminalSignIn ?? .tailscale)
        _opens = State(initialValue: e?.terminalOpens ?? .tmux)
        _kvmAddress = State(initialValue: fields?.kvmAddress ?? e?.jetkvmAddress ?? "")
        _kvmPassword = State(initialValue: SimulatorSwitches.addKVMPasswordFromFile ?? "")
    }

    /// The computer this sheet changes: the one from the ⓘ page, or the one its first Add saved. Order
    /// computers-m2-fixes 2: after a failed check the plan's "saved anyway" holds, so the computer is in the list; a
    /// corrected try updates that SAME computer, never a second one.
    private var existing: MacEntry? { (existingID ?? added).flatMap { store.entry($0) } }
    /// Add ran and its check is still out.
    private var checking: Bool { added != nil && result == nil }
    /// Add ran and its check passed: nothing is left to change here.
    private var passed: Bool { result?.ok == true }
    /// Add ran and its check failed: the fields stay editable and the button reads Try Again.
    private var failed: Bool { added != nil && result?.ok == false }
    /// The ways this build can add (review finding 4: never one the build cannot show).
    private var choices: [WayIn] { WayIn.inThisBuild }

    var body: some View {
        NavigationStack {
          ScrollViewReader { proxy in
            Form {
                if existingID == nil {
                    Section("Name") {
                        TextField("Studio Mac", text: $name).accessibilityIdentifier("addName")
                    }
                    if choices.count > 1 {
                        Section {
                            Picker("Start With", selection: $way) {
                                ForEach(choices) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .accessibilityIdentifier("addStartWith")
                            // Once saved, the computer has this way in; a different one is added from its ⓘ page.
                            .disabled(added != nil)
                        } header: {
                            Text("Start With")
                        } footer: {
                            Text(Self.footer(way) + " You can add the other ways in later, in the computer’s settings (ⓘ).")
                        }
                    }
                }
                switch way {
                case .screenSharing: screenSharingFields
                case .terminal: terminalFields
                case .jetkvm: jetkvmFields
                }
                if let problem {
                    Section {
                        Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            .accessibilityIdentifier("addProblem")
                    }
                }
                if added != nil {
                    Section("Check") {
                        ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                            Text(step).foregroundStyle(.secondary).accessibilityIdentifier("addStep")
                        }
                        if let r = result {
                            Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(r.ok ? Color.green : Color.red)
                                .accessibilityIdentifier("addCheck")
                                .id("addCheck")
                            if !r.ok {
                                Text("Saved anyway. Change what is wrong above and tap Try Again, or fix it later in the computer’s settings (ⓘ).")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            HStack { ProgressView(); Text("Checking…").foregroundStyle(.secondary) }
                        }
                    }
                    if way == .terminal, failed { keyHelpSections }
                }
            }
            // Only while the check is out, and after it passed. A failed check leaves every field editable.
            .disabled(checking || passed)
            .onChange(of: result) { _, r in
                // Project notes: the check's answer is scrolled into view (it sits under the fields).
                guard r != nil else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation { proxy.scrollTo("addCheck", anchor: .top) }
                }
            }
            .onChange(of: check.state) { _, state in
                // The answer to Add is shown where it can be seen (it sits below the Macs nearby).
                if state == .noAnswer {
                    // After the section is drawn, so the scroll reaches its last row.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        withAnimation { proxy.scrollTo("addNoHost", anchor: .top) }
                    }
                }
            }
          }
            .onReceive(NotificationCenter.default.publisher(for: AppAccess.changed)) { _ in
                // The app lock does not cover a sheet: the password prompt hides and forgets what was typed.
                appOpen = AppAccess.isOpen
                if !appOpen { sshPassword = "" }
            }
            .navigationTitle(existingID == nil ? "Add Computer" : "Add \(way.label)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if added == nil {
                    ToolbarItem(placement: .cancellationAction) { Button(role: .cancel) { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(role: .confirm) { add() } label: { Text("Add").foregroundStyle(.white) }
                            .disabled(addWhenFound && check.state == .checking)
                            .accessibilityIdentifier("addConfirm")
                    }
                } else if failed || checking {
                    // Saved, and the check failed (or a second try is out): Done keeps it as it is; Try Again
                    // saves what was changed into the same computer and checks again.
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done") { dismiss() }.accessibilityIdentifier("addDone")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(role: .confirm) { add() } label: { Text("Try Again").foregroundStyle(.white) }
                            .disabled(checking)
                            .accessibilityIdentifier("addConfirm")
                    }
                } else {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }.disabled(result == nil)
                            .accessibilityIdentifier("addDone")
                    }
                }
            }
            .alert("Same Mac", isPresented: Binding(get: { sameMac != nil }, set: { if !$0 { sameMac = nil } }),
                   presenting: sameMac) { other in
                if existingID == nil { Button("Add Address") { addAddress(to: other) } }
                Button(existingID == nil ? "Cancel" : "OK", role: .cancel) {}
            } message: { other in
                Text(existingID == nil ? "This is “\(other.name)”, already in your list. Add this address to it?"
                     : "This Glass Act Host is “\(other.name)”, already in your list.")
            }
        }
        .onAppear {
            if way == .screenSharing { startLooking() }
            if !typed.isEmpty { checkTyped() }
            if SimulatorSwitches.addPress { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { add() } }
        }
        .onChange(of: way) { _, new in
            problem = nil
            if new == .screenSharing { startLooking() }
        }
        .onChange(of: typed) { _, new in
            // Picking a Mac nearby empties the typed address; that keeps the pick and its check.
            guard !new.isEmpty || picked == nil else { return }
            picked = nil
            addWhenFound = false
            check.reset()
        }
        .onChange(of: check.state) { _, state in
            switch state {
            case let .found(key):
                if addWhenFound { addWhenFound = false; saveScreenSharing(key: key) }
            case .noAnswer, .locked:
                addWhenFound = false
            default:
                break
            }
        }
    }

    static func footer(_ way: WayIn) -> String {
        switch way {
        case .screenSharing: "Screen Sharing: a Mac running Glass Act Host."
        case .terminal: "Terminal: any computer you reach over SSH."
        case .jetkvm: "JetKVM: any computer with a JetKVM plugged in, even with nothing installed on it."
        }
    }

    // MARK: Screen Sharing

    @ViewBuilder private var screenSharingFields: some View {
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
                .onSubmit(checkTyped)
                .accessibilityIdentifier("addAddress")
            if picked == nil { checkLine }
        } header: {
            Text("Or Type an Address")
        } footer: {
            Text("A Tailscale name (my-mac) or a home name (My-Mac.local).")
        }
        if check.state == .noAnswer {
            // The owner 2026-11-22: "I tried to add a Mac and it errored out with "no glass host" installed. But I could
            // have added jetkvm". The sheet says so and offers the other ways in, keeping what was typed.
            Section {
                Label("No Glass Act Host answered at \(check.checked?.host ?? "this address").",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("addNoHost")
                    .id("addNoHost")
                Button("Check Again", action: recheck).accessibilityIdentifier("addCheckAgain")
                if existingID == nil {
                    ForEach(choices.filter { $0 != .screenSharing }) { w in
                        Button("Add with \(w.label) Instead") { switchTo(w) }
                            .accessibilityIdentifier("addInstead.\(w.rawValue)")
                    }
                }
            } header: {
                Text("No Glass Act Host")
            } footer: {
                Text(existingID == nil && choices.count > 1
                     ? "The computer can still be added another way; what you typed is kept. Screen Sharing can be added later, once Glass Act Host is on it."
                     : "Check that Glass Act Host is running on the Mac. The first try on a home network can fail before Local Network is allowed.")
            }
        }
    }

    @ViewBuilder private var checkLine: some View {
        switch check.state {
        case .idle, .noAnswer:
            EmptyView()
        case .checking:
            HStack(spacing: 8) { ProgressView(); Text("Checking…") }.foregroundStyle(.secondary)
        case .found:
            Label("Found Glass Act Host", systemImage: "checkmark").foregroundStyle(.green)
                .accessibilityIdentifier("addFound")
        case .locked:
            Text(AddressCheck.lockedText).foregroundStyle(.secondary)
        }
    }

    private func startLooking() {
        // Asking for Local Network here, where the reason is plain (HIG Privacy; plan §5).
        nearby.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { lookedLong = true }
    }

    private func checkTyped() {
        guard let a = TypedAddress(typed, tailnetSuffix: TypedAddress.tailnetSuffix(in: store.macs)) else { return }
        picked = nil
        check.run(a, identity: identity)
    }

    private func recheck() {
        if let a = check.checked { check.run(a, identity: identity) } else { checkTyped() }
    }

    private func pick(_ host: NearbyHost) {
        typed = ""
        picked = host
        if name.trimmingCharacters(in: .whitespaces).isEmpty { name = host.name }
        check.run(TypedAddress(host: host.host, port: host.port), identity: identity)
    }

    /// No Host: carry on with another way in. Everything typed stays; the Terminal starts at the typed address.
    private func switchTo(_ w: WayIn) {
        if w == .terminal, address.trimmingCharacters(in: .whitespaces).isEmpty, let h = check.checked?.host {
            address = h
        }
        if name.trimmingCharacters(in: .whitespaces).isEmpty, let h = check.checked?.host {
            name = Self.suggestedName(h)
        }
        way = w
    }

    private func saveScreenSharing(key: String) {
        guard let a = check.checked else { return }
        if let other = store.entry(withKey: key), other.id != existingID {
            sameMac = other
            return
        }
        problem = nil
        if let id = existingID {
            store.update(id) { e in
                e.screenSharing = true
                e.set(AddressKind.of(a.host), a.host)
                e.port = a.port
                e.key = key
            }
            added = id
            result = AddCheckResult(ok: true, text: "Found Glass Act Host. Screen Sharing is added.")
        } else {
            let n = name.trimmingCharacters(in: .whitespaces)
            var e = MacEntry(name: n.isEmpty ? (picked?.name ?? Self.suggestedName(a.host)) : n, port: a.port)
            e.set(AddressKind.of(a.host), a.host)
            e.key = key
            // No `screenSharing` set: the store's carry-over writes a Mac's defaults exactly as before (Screen
            // Sharing, and for a Terminal added later SSH port 22, this iPhone's key, tmux).
            store.addNew(e, startWith: .screenSharing)
            added = e.id
            result = AddCheckResult(ok: true, text: "Found Glass Act Host. \(e.name) is added.")
        }
    }

    private func addAddress(to other: MacEntry) {
        guard let a = check.checked else { return }
        store.update(other.id) { $0.set(AddressKind.of(a.host), a.host) }
        dismiss()
    }

    /// "My-Mac.local" → "My-Mac"; "other-mac.example-tailnet.ts.net" → "other-mac".
    static func suggestedName(_ host: String) -> String {
        if host == "localhost" { return "Test host" }
        return String(host.split(separator: ".").first ?? Substring(host))
    }

    // MARK: Terminal

    @ViewBuilder private var terminalFields: some View {
        #if DUO_TERMINAL
        if existing?.hasScreenSharing == true {
            // A Mac with Glass Act Host: its Terminal works as it always has (SSH port 22, this iPhone's key, which
            // its Host adds); only the account is asked.
            Section {
                LabeledContent("User Name") {
                    TextField("Required", text: $user)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                        .accessibilityIdentifier("addTerminalUser")
                }
            } header: {
                Text("Sign In")
            } footer: {
                Text("Add asks the Mac’s Glass Act Host to add this iPhone’s key to that account, then signs in with it. If the Host can’t, you can sign in once with the account’s password instead.")
            }
        } else {
            Section {
                TextField("my-server", text: $address)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityIdentifier("addTerminalAddress")
                LabeledContent("Port") {
                    TextField("22", text: $port).keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        .accessibilityIdentifier("addTerminalPort")
                }
            } header: {
                Text("Address")
            } footer: {
                Text("A Tailscale name (my-server) or a home name (server.local).")
            }
            Section {
                LabeledContent("User Name") {
                    TextField("Required", text: $user)
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                        .accessibilityIdentifier("addTerminalUser")
                }
                Picker("Sign In With", selection: $signIn) {
                    ForEach(TerminalSignIn.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("addTerminalSignIn")
                Picker("Opens", selection: $opens) {
                    ForEach(TerminalOpens.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .accessibilityIdentifier("addTerminalOpens")
            } header: {
                Text("Sign In")
            } footer: {
                Text("Tailscale: for a computer with Tailscale SSH on; nothing to install. This iPhone’s Key: the computer must list the key below. tmux keeps the session when the link drops; Login Shell is whatever the computer starts.")
            }
            if signIn == .phoneKey, let k = try? TerminalKeys.phoneKey() {
                PhoneKeySection(line: k.authorizedKeysLine(comment: "duo-desktop"))
            }
        }
        #endif
    }

    private func saveTerminal() {
        #if DUO_TERMINAL
        let t = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
        if let e = existing, e.hasScreenSharing {
            guard !t(user).isEmpty else { problem = "Type the user name to sign in as."; return }
            problem = nil
            // Project notes 6: a Mac's Terminal signs in with this iPhone's key, never Tailscale's `none`
            // (a Mac whose Screen Sharing was added later kept the Tailscale default, hence "Tailscale refused").
            store.update(e.id) { $0.terminal = true; $0.sshUser = t(user); $0.terminalSignIn = .phoneKey }
            added = e.id
            result = nil
            keyHelp = .none
            installNote = nil
            steps = ["Asking Glass Act Host to add this iPhone’s key…"]
            let typed = t(user)
            // The sheet gets the key added itself: over the running session, or a short link opened for this.
            TerminalKeyByHost.askOpening(entry: e, store: store, identity: identity,
                                         asking: { steps.append("Glass Act Host is asking on the Mac: approve it there.") }) { o in
                steps.append(contentsOf: Self.hostSteps(o, typed: typed))
                steps.append("Signing in as \(typed)…")
                Task { await runTerminalCheck(e.id) }
            }
            return
        }
        if let p = TerminalComputerForm.problem(name: existingID == nil ? name : (existing?.name ?? name),
                                                address: address, user: user, port: port) {
            problem = p
            return
        }
        problem = nil
        let p = UInt16(t(port)) ?? 22
        if let e = existing {
            let rename = existingID == nil ? t(name) : nil
            store.update(e.id) { x in
                if let rename { x.name = rename }
                x.terminal = true
                x.setTerminalAddress(address)
                x.sshPort = p
                x.sshUser = t(user)
                x.terminalSignIn = signIn
                x.terminalOpens = opens
            }
            added = e.id
        } else {
            let e = MacEntry.terminalComputer(name: name, address: address, port: p, user: user, signIn: signIn, opens: opens)
            store.addNew(e, startWith: .terminal)
            added = e.id
        }
        if let id = added { result = nil; Task { await runTerminalCheck(id) } }
        #endif
    }

    #if DUO_TERMINAL
    private func runTerminalCheck(_ id: String) async {
        guard let e = store.entry(id) else { return }
        let r = await TerminalComputerCheck.check(e)
        keyHelp = r.passwordCanAddKey ? .password : (r.keyByHandOnly ? .copyOnly : .none)
        result = AddCheckResult(ok: r.ok, text: r.ok ? "\(r.text) \(e.name) is added." : r.text)
    }

    /// What the Host said, in plain words (project notes 6), pure for tests.
    static func hostSteps(_ o: TerminalKeyByHost.LinkOutcome, typed: String) -> [String] {
        switch o {
        case let .answered(.answered(r)):
            switch r.status {
            case .installed, .alreadyThere:
                var out = ["Glass Act Host added this iPhone’s key for “\(r.userName)”."]
                if !r.userName.isEmpty, r.userName != typed {
                    out.append("The Host runs as “\(r.userName)”, so the key went to that account, not “\(typed)”.")
                }
                if !r.remoteLoginOn { out.append("Remote Login looks off on the Mac: its SSH port is not listening.") }
                return out
            case .refused, .askingOnMac:
                return ["Glass Act Host did not add the key: \(r.reason)."]
            }
        case .answered(.olderHost):
            return ["This Mac’s Glass Act Host is older and can’t add the key."]
        case .answered(.noSession):
            return ["No link to Glass Act Host to ask."]
        case let .noLink(why):
            return [why]
        }
    }

    /// The one-time password sign-in (project notes 5).
    private func installByPassword() async {
        guard let id = added, let e = store.entry(id), AppAccess.isOpen else { return }
        let pw = sshPassword
        sshPassword = ""
        installing = true
        installNote = nil
        defer { installing = false }
        let r = await TerminalKeyByPassword.install(e, user: e.sshUser ?? user, password: pw)
        guard r.ok else {
            installNote = r.text
            if r.keyByHandOnly { keyHelp = .copyOnly }
            return
        }
        // From now on it signs in with the key.
        store.update(id) { $0.terminalSignIn = .phoneKey }
        steps.append(r.text)
        steps.append("Signing in with this iPhone’s key…")
        signIn = .phoneKey
        result = nil
        keyHelp = .none
        await runTerminalCheck(id)
    }
    #endif

    @ViewBuilder private var keyHelpSections: some View {
        #if DUO_TERMINAL
        switch keyHelp {
        case .none:
            EmptyView()
        case .password:
            Section {
                if appOpen {
                    SecureField("Password for \(existing?.sshUser ?? user)", text: $sshPassword)
                        .textContentType(.password)
                        .accessibilityIdentifier("addSSHPassword")
                    Button {
                        Task { await installByPassword() }
                    } label: {
                        HStack {
                            Text("Sign In and Add Key")
                            if installing { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(sshPassword.isEmpty || installing)
                    .accessibilityIdentifier("addSSHInstall")
                } else {
                    Text("Unlock Duo Desktop to type the password.").foregroundStyle(.secondary)
                }
                if let installNote {
                    Label(installNote, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        .accessibilityIdentifier("addSSHInstallNote")
                }
            } header: {
                Text("Add This iPhone’s Key")
            } footer: {
                // the owner 2026-11-21: "signing in with your Mac username and password is reasonable".
                Text("Duo Desktop signs in to \(existing?.name ?? "the computer") once as “\(existing?.sshUser ?? user)” with this password, adds this iPhone’s key to ~/.ssh/authorized_keys and signs out. The password is used for that one sign-in and is never kept or logged. After that, Terminal signs in with the key.")
            }
        case .copyOnly:
            if let installNote {
                Section { Label(installNote, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
            }
            if let k = try? TerminalKeys.phoneKey() {
                PhoneKeySection(line: k.authorizedKeysLine(comment: "duo-desktop"))
            }
        }
        #endif
    }

    // MARK: JetKVM

    @ViewBuilder private var jetkvmFields: some View {
        #if DUO_JETKVM
        Section {
            LabeledContent("Address") {
                TextField("jetkvm.local", text: $kvmAddress)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL)
                    .accessibilityIdentifier("addJetKVMAddress")
            }
            LabeledContent("Password") {
                SecureField(added != nil && JetKVMSettings.passwords.password(mac: added ?? "") != nil
                            ? "Saved (type to change)" : "Optional", text: $kvmPassword)
                    .multilineTextAlignment(.trailing)
                    .textContentType(.password)
                    .accessibilityIdentifier("addJetKVMPassword")
            }
        } header: {
            Text("JetKVM")
        } footer: {
            Text("The JetKVM’s own address, as in its web page, and its password (blank if it has none). The password is kept in this iPhone’s Keychain only. Add signs in to check it and takes over nobody who is watching.")
        }
        #endif
    }

    private func saveJetKVM() {
        #if DUO_JETKVM
        let t = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
        if existingID == nil, t(name).isEmpty { problem = "Type a name."; return }
        if t(kvmAddress).isEmpty { problem = "Type the JetKVM’s address."; return }
        if t(kvmAddress).contains(" ") { problem = "An address has no spaces."; return }
        problem = nil
        let id: String
        if let e = existing {
            let rename = existingID == nil ? t(name) : nil
            store.update(e.id) { x in
                if let rename { x.name = rename }
                x.jetkvm = true
                x.jetkvmAddress = t(kvmAddress)
            }
            id = e.id
        } else {
            var e = MacEntry(name: t(name))
            e.screenSharing = false
            e.terminal = false
            e.jetkvm = true
            e.jetkvmAddress = t(kvmAddress)
            store.addNew(e, startWith: .jetkvm)
            id = e.id
        }
        // A second try with the Password field left empty keeps the password the first try saved.
        let retry = added != nil && kvmPassword.isEmpty
        let pw = retry ? JetKVMSettings.passwords.password(mac: id) : (kvmPassword.isEmpty ? nil : kvmPassword)
        if !retry {
            JetKVMSettings.passwords.setPassword(pw, mac: id)
            // Only whether it has one syncs (list sync): another iPhone then knows to ask for it there.
            store.update(id) { $0.jetkvmPassword = pw != nil }
        }
        kvmPassword = ""
        added = id
        result = nil
        guard let e = store.entry(id), let host = e.jetkvmHost else { return }
        Task {
            let r = await JetKVMAddCheck.run(name: e.name, host: host, password: pw)
            result = AddCheckResult(ok: r.ok, text: r.text)
        }
        #endif
    }

    // MARK: Add

    private func add() {
        switch way {
        case .screenSharing:
            if case let .found(key) = check.state { saveScreenSharing(key: key); return }
            if picked == nil, check.checked == nil,
               TypedAddress(typed, tailnetSuffix: TypedAddress.tailnetSuffix(in: store.macs)) == nil {
                problem = "Choose a Mac on this network, or type its address."
                return
            }
            problem = nil
            addWhenFound = true
            if check.state != .checking {
                if picked != nil || check.checked != nil { recheck() } else { checkTyped() }
            }
        case .terminal:
            saveTerminal()
        case .jetkvm:
            saveJetKVM()
        }
    }
}
