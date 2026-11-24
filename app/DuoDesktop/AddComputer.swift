import GlassActSession
import GlassActTransport
import Security
import SwiftUI
import UIKit

// Add Computer. One sheet (HIG Sheets: "a distinct, narrowly scoped task"): Name, then Start With, a segmented control
// (HIG Segmented controls: closely related, mutually exclusive choices that change what the view below shows), then
// only that way in's fields. Add checks that one way in and says what happened in place (HIG: validate in place, say
// how to fix it). The same sheet, from a computer's ⓘ page, adds one more way in to that computer.

/// Set when a check's deadline passed, read by the check that it cut short.
@MainActor final class DeadlineFlag { var passed = false }

/// Start With's choices: the ways in, with Remote Desktop beside Screen Sharing in a Remote Desktop build. Remote
/// Desktop fills Screen Sharing's slot on the computer (`MacEntry.remoteDesktop`): a computer has one or the other.
enum AddWay: String, Identifiable, Hashable, CaseIterable {
    case screenSharing, remoteDesktop, terminal, jetkvm

    init(_ way: WayIn) {
        switch way {
        case .screenSharing: self = .screenSharing
        case .terminal: self = .terminal
        case .jetkvm: self = .jetkvm
        }
    }

    var id: String { rawValue }
    /// The computer's way in this fills.
    var slot: WayIn {
        switch self {
        case .screenSharing, .remoteDesktop: .screenSharing
        case .terminal: .terminal
        case .jetkvm: .jetkvm
        }
    }
    var label: String { self == .remoteDesktop ? "Remote Desktop" : slot.label }

    /// What this build's Start With lists.
    static var inThisBuild: [AddWay] {
        var w = WayIn.inThisBuild.map(AddWay.init)
        if RDPScreen.inThisBuild { w.insert(.remoteDesktop, at: 1) }
        return w
    }
}

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
    @State private var way: AddWay
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
    // Remote Desktop (a Windows PC): Address, Port, User Name; the name is the sheet's own.
    @State private var pc: RDPForm

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

    init(store: MacStore, identity: SecIdentity?, existingID: String? = nil, fixedWay: AddWay? = nil) {
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
        // A PC starts from a PC's choices (`correctForPC`), whatever was saved before it was known to be one.
        let c = e.map { x -> MacEntry in var y = x; y.correctForPC(); return y }
        _signIn = State(initialValue: c?.terminalSignIn ?? .tailscale)
        _opens = State(initialValue: c?.terminalOpens ?? .tmux)
        _kvmAddress = State(initialValue: fields?.kvmAddress ?? e?.jetkvmAddress ?? "")
        _kvmPassword = State(initialValue: SimulatorSwitches.addKVMPasswordFromFile ?? "")
        // Remote Desktop added later starts from the computer's address and its last Remote Desktop fields.
        var pc = e.map(RDPForm.init) ?? RDPForm()
        if let fields { pc.address = fields.address; pc.user = fields.user }
        _pc = State(initialValue: pc)
    }

    /// The computer this sheet changes: the one from the ⓘ page, or the one its first Add saved. after a failed check
    /// the plan's "saved anyway" holds, so the computer is in the list; a corrected try updates that SAME computer,
    /// never a second one.
    private var existing: MacEntry? { (existingID ?? added).flatMap { store.entry($0) } }
    /// Add ran and its check is still out.
    private var checking: Bool { added != nil && result == nil }
    /// Add ran and its check passed: nothing is left to change here.
    private var passed: Bool { result?.ok == true }
    /// Add ran and its check failed: the fields stay editable and the button reads Try Again.
    private var failed: Bool { added != nil && result?.ok == false }
    /// The ways this build can add.
    private var choices: [AddWay] { AddWay.inThisBuild }

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
                            startWithPicker
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
                case .remoteDesktop: remoteDesktopFields
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
                                Text(Self.savedAnyway)
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
                     : "This Glass Act Host for Duo Desktop is “\(other.name)”, already in your list.")
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

    /// Start With: a segmented control for up to three choices; four (a Remote Desktop build) do not fit its labels on
    /// an iPhone's width, so a menu row (HIG Pickers: a menu for a short list in a form).
    @ViewBuilder private var startWithPicker: some View {
        let picker = Picker("Start With", selection: $way) {
            ForEach(choices) { Text($0.label).tag($0) }
        }
        if choices.count > 3 { picker.pickerStyle(.menu) } else { picker.pickerStyle(.segmented) }
    }

    static func footer(_ way: AddWay) -> String {
        switch way {
        case .screenSharing: "Screen Sharing: a Mac running Glass Act Host for Duo Desktop."
        case .remoteDesktop: "Remote Desktop: a Windows PC with Remote Desktop turned on."
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
            // No glass host" installed. But I could have added jetkvm". The sheet says so and offers the other ways in,
            // keeping what was typed.
            Section {
                Label("No Glass Act Host for Duo Desktop answered at \(check.checked?.host ?? "this address").",
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
                Text("No Glass Act Host for Duo Desktop")
            } footer: {
                Text(existingID == nil && choices.count > 1
                     ? "The computer can still be added another way; what you typed is kept. Screen Sharing can be added later, once Glass Act Host for Duo Desktop is on it."
                     : "Check that Glass Act Host for Duo Desktop is running on the Mac. The first try on a home network can fail before Local Network is allowed.")
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
            Label("Found Glass Act Host for Duo Desktop", systemImage: "checkmark").foregroundStyle(.green)
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
    private func switchTo(_ w: AddWay) {
        if w == .terminal, address.trimmingCharacters(in: .whitespaces).isEmpty, let h = check.checked?.host {
            address = h
        }
        if w == .remoteDesktop, pc.address.trimmingCharacters(in: .whitespaces).isEmpty, let h = check.checked?.host {
            pc.address = h
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
            result = AddCheckResult(ok: true, text: "Found Glass Act Host for Duo Desktop. Screen Sharing is added.")
        } else {
            let n = name.trimmingCharacters(in: .whitespaces)
            var e = MacEntry(name: n.isEmpty ? (picked?.name ?? Self.suggestedName(a.host)) : n, port: a.port)
            e.set(AddressKind.of(a.host), a.host)
            e.key = key
            // No `screenSharing` set: the store's carry-over writes a Mac's defaults exactly as before (Screen
            // Sharing, and for a Terminal added later SSH port 22, this iPhone's key, tmux).
            store.addNew(e, startWith: .screenSharing)
            added = e.id
            result = AddCheckResult(ok: true, text: "Found Glass Act Host for Duo Desktop. \(e.name) is added.")
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
                Text("Add asks the Mac’s Glass Act Host for Duo Desktop to add this iPhone’s key to that account, then signs in with it. If the Host can’t, you can sign in once with the account’s password instead.")
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
                if isPC {
                    // A PC's one way in and its one shell, as plain lines.
                    PCTerminalRows()
                } else {
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
                }
            } header: {
                Text("Sign In")
            } footer: {
                Text(isPC ? PCTerminalRows.footer : Self.terminalSignInFooter)
            }
            if signIn == .phoneKey, let k = try? TerminalKeys.phoneKey() {
                PhoneKeySection(line: k.authorizedKeysLine(comment: "duo-desktop"))
            }
        }
        #endif
    }

    /// This computer's Terminal is a PC's (`MacEntry.isPC`): Remote Desktop is a way in, or a check heard Windows.
    private var isPC: Bool { existing?.isPC ?? false }

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
            steps = ["Asking Glass Act Host for Duo Desktop to add this iPhone’s key…"]
            let typed = t(user)
            // The sheet gets the key added itself: over the running session, or a short link opened for this.
            TerminalKeyByHost.askOpening(entry: e, store: store, identity: identity,
                                         asking: { steps.append("Glass Act Host for Duo Desktop is asking on the Mac: approve it there.") }) { o in
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
                x.correctForPC()
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
        let r = await TerminalComputerCheck.check(e, store: store)
        // The check may have found a PC (its server's first line): the sheet shows a PC's choices from now on.
        if let now = store.entry(id), now.isPC { signIn = .phoneKey; opens = .loginShell }
        keyHelp = r.passwordCanAddKey ? .password : (r.keyByHandOnly ? .copyOnly : .none)
        result = AddCheckResult(ok: r.ok, text: r.ok ? "\(r.text) \(e.name) is added." : r.text)
    }

    /// What the Host said, in plain words, pure for tests.
    static func hostSteps(_ o: TerminalKeyByHost.LinkOutcome, typed: String) -> [String] {
        switch o {
        case let .answered(.answered(r)):
            switch r.status {
            case .installed, .alreadyThere:
                var out = ["Glass Act Host for Duo Desktop added this iPhone’s key for “\(r.userName)”."]
                if !r.userName.isEmpty, r.userName != typed {
                    out.append("The Host runs as “\(r.userName)”, so the key went to that account, not “\(typed)”.")
                }
                if !r.remoteLoginOn { out.append("Remote Login looks off on the Mac: its SSH port is not listening.") }
                return out
            case .refused, .askingOnMac:
                return ["Glass Act Host for Duo Desktop did not add the key: \(r.reason)."]
            }
        case .answered(.olderHost):
            return ["This Mac’s Glass Act Host for Duo Desktop is older and can’t add the key."]
        case .answered(.noSession):
            return ["No link to Glass Act Host for Duo Desktop to ask."]
        case let .noLink(why):
            return [why]
        }
    }

    /// The one-time password sign-in.
    private func installByPassword() async {
        guard let id = added, let e = store.entry(id), AppAccess.isOpen else { return }
        let pw = sshPassword
        sshPassword = ""
        installing = true
        installNote = nil
        defer { installing = false }
        let r = await TerminalKeyByPassword.install(e, user: e.sshUser ?? user, password: pw)
        if r.windows {
            store.update(id) { $0.terminalSystem = .windows; $0.correctForPC() }
            signIn = .phoneKey; opens = .loginShell
        }
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
                // 
                Text("Duo Desktop signs in to \(existing?.name ?? "the computer") once as “\(existing?.sshUser ?? user)” with this password, adds this iPhone’s key to the account’s list of allowed keys and signs out. The password is used for that one sign-in and is never kept or logged. After that, Sign In With is This iPhone’s Key.")
            }
        case .copyOnly:
            if let installNote {
                Section { Label(installNote, systemImage: "xmark.octagon.fill").foregroundStyle(.red) }
            }
            // Once Sign In With is This iPhone's Key the fields already show the key; never two copies.
            if signIn != .phoneKey, let k = try? TerminalKeys.phoneKey() {
                PhoneKeySection(line: k.authorizedKeysLine(comment: "duo-desktop"))
            }
        }
        #endif
    }

    /// Under a failed check: the check's words already say what to do.
    static let savedAnyway = "Saved anyway. When that is done, tap Try Again. Or tap Done and fix it later in the computer’s settings (ⓘ)."
    /// Under Sign In for a computer without Glass Act Host: one line per choice, when to pick it.
    static let terminalSignInFooter = """
        Tailscale: pick this if the computer has Tailscale SSH turned on.
        This iPhone’s Key: pick this for any other computer, including a Windows PC.
        tmux: pick this for a Mac or Linux computer, to come back to the same session after the link drops.
        Login Shell: pick this for a Windows PC, or for a fresh prompt each time.
        """

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

    // MARK: Remote Desktop

    @ViewBuilder private var remoteDesktopFields: some View {
        #if DUO_RDP
        RDPAddressFields(form: $pc, prefix: "addPC", header: "Address")
        Section {
            LabeledContent("User Name") {
                TextField("Required", text: $pc.user)
                    .multilineTextAlignment(.trailing)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().textContentType(.username)
                    .accessibilityIdentifier("addPCUser")
            }
        } header: {
            Text("Sign In")
        } footer: {
            Text(RDPForm.passwordFoot)
        }
        Section {
        } footer: {
            Text(RDPForm.needs)
        }
        #endif
    }

    /// Saves the PC (new, or Remote Desktop added to this computer) and closes: nothing is contacted here; the list's
    /// light shows whether the PC answers.
    private func saveRemoteDesktop() {
        #if DUO_RDP
        var f = pc
        f.name = existingID == nil ? name : (existing?.name ?? name)
        if let p = f.problem { problem = p; return }
        problem = nil
        if let e = existing {
            store.update(e.id) { f.addWay(to: &$0) }
        } else {
            f.add(to: store)
        }
        dismiss()
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
        case .remoteDesktop:
            saveRemoteDesktop()
        }
    }
}
