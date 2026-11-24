import GlassActCore
import GlassActSession
import SwiftUI
import UIKit

// MARK: - The list

struct MacListScreen: View {
    @Bindable var model: SessionModel
    let list: MacList
    let lock: AppLock
    @State private var showAbout = SimulatorSwitches.showAbout
    @State private var showAdd = SimulatorSwitches.addComputerWay != nil
    @State private var settingsFor: String? = SimulatorSwitches.showMacSettings
    @State private var removing: MacEntry?
    /// A gray icon was tapped: that way in's Add sheet for that computer.
    @State private var addingWay: AddWayTarget?
    @State private var confirmLockOff = false
    @AppStorage(TrackpadSide.storageKey) private var trackpadSide: TrackpadSide = .standard
    @AppStorage(KeyFeedback.hapticsKey) private var keyboardHaptics = false

    var body: some View {
        NavigationStack {
            List {
                if list.store.computers.isEmpty {
                    // Plan §5.1: a new install (or the public build) starts here.
                    Section {
                        ContentUnavailableView {
                            Label("No Computers Yet", systemImage: "desktopcomputer")
                        } description: {
                            Text(ListWords.emptyDescription)
                        } actions: {
                            addMenu(prominent: true)
                        }
                    }
                } else {
                    // One list, no sections, in the order added. Milestone 3 and project notes (name-opens-default):
                    // one line each, the light, the name (its Opens In way), the three way-in icons, then the (i)
                    // (`ComputerListRow`).
                    Section {
                        ForEach(list.store.computers) { e in
                            ComputerListRow(entry: e, columns: WayIn.inThisBuild,
                                            look: { WayLook.of(e, $0, mac: list.reach[e.id], reach: ComputerReach.shared) },
                                            light: ComputerLight.of(e, mac: list.reach[e.id], reach: ComputerReach.shared),
                                            openDefault: { ComputerNav.shared.openDefault(e) },
                                            settings: { settingsFor = e.id },
                                            open: { open(e, in: $0) },
                                            add: { addingWay = AddWayTarget(id: e.id, way: $0) })
                            // Shorter rows: the icons' own 44 pt touch targets give the height, so the list's extra top
                            // and bottom padding goes; the last icon's target reaches close to the edge.
                            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 8))
                            .swipeActions(edge: .trailing) {
                                Button("Remove", role: .destructive) { removing = e }
                            }
                        }
                    } footer: {
                        Text(ListWords.footer)
                    }
                }

                if model.phase != .idle {
                    Section {
                        HStack(spacing: 12) {
                            ProgressView()
                            Text(progressText).foregroundStyle(.secondary)
                            Spacer()
                            Button("Cancel", role: .cancel) { model.disconnect() }
                        }
                        if case let .awaitingApproval(code) = model.phase {
                            LabeledContent("Code", value: code).font(.body.monospaced())
                        }
                        // Project notes (computers-m3) 2: while Screen Sharing is still trying, the computer's other ways in
                        // are right here ("Open in JetKVM Instead"); choosing one ends this attempt.
                        if let e = model.mac.flatMap({ list.store.entry($0.id) }) {
                            OtherWaysOffer(entry: e, current: .screenSharing) { model.disconnect() }
                        }
                    }
                }

                // Touch ID clarity: its own titled section right under the Macs, with what depends on it in the footer
                // (HIG Lists and tables: group related settings under a header; footers explain).
                Section {
                    Toggle(isOn: Binding(get: { lock.required }, set: { on in
                        if !on, AutoUnlockRules.lockOffWarning(list.macs) != nil {
                            confirmLockOff = true // HIG Alerts: confirm an action that deletes something
                        } else {
                            Task { await lock.setRequired(on) }
                        }
                    })) {
                        Label(UnlockMethod.current.settingName, systemImage: UnlockMethod.current.symbol)
                    }
                    .disabled(lock.busy)
                    .accessibilityIdentifier("requireTouchID")
                } header: {
                    Text("Security")
                } footer: {
                    Text(lock.message ?? AutoUnlockRules.securityFooter)
                }
                .id("security")

                // List sync: one switch, its footer says what syncs and what not.
                SyncSection(sync: ComputerSync.shared)

                Section {
                    TrackpadSidePicker(side: $trackpadSide, style: .segmented)
                } footer: {
                    Text("Which side of the keys the trackpad is on, with the iPhone upright.")
                }

                // The shortcut reference lives here only.
                Section {
                    KeyboardShortcutsRow()
                }

                Section {
                    Toggle("Keyboard Haptics", isOn: $keyboardHaptics)
                        .accessibilityIdentifier("keyboardHaptics")
                } footer: {
                    Text("A light tap when you press our keys, the click buttons or the trackpad.")
                }

                // This phone" information at the bottom."
                Section {
                    LabeledContent("Key") {
                        Text(model.viewerKeyString.isEmpty ? "None" : model.viewerKeyString)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .accessibilityIdentifier("viewerKey")
                    }
                    // Two different stores: the phone's own key, and the Macs' keys it has trusted.
                    LabeledContent("Key kept in", value: model.viewerKeySource.isEmpty ? "—" : model.viewerKeySource)
                    LabeledContent("Computers’ keys kept in", value: "The list, in this app")
                } header: {
                    Text("This iPhone")
                }

            }
            // HIG Toolbars, Titles: "Don't title windows with your app name" (DESIGN rule 7). The large title
            // sits under the clock's row; the About button is a system toolbar item in that row (rule 1).
            .navigationTitle(ListWords.title)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { addMenu(prominent: false) }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("About", systemImage: "info.circle") { showAbout = true }
                }
            }
            .sheet(isPresented: $showAbout) { AboutView() }
            .sheet(isPresented: $showAdd, onDismiss: probe) { AddComputerSheet(store: list.store, identity: model.identity) }
            // A gray icon: that way in's Add sheet, the same sheet as the settings page's "Add Terminal…" row.
            .sheet(item: $addingWay, onDismiss: probe) { t in
                AddComputerSheet(store: list.store, identity: model.identity, existingID: t.id, fixedWay: AddWay(t.way))
            }
            .navigationDestination(item: $settingsFor) { id in
                ComputerSettingsScreen(store: list.store, id: id, chosen: list.chosen[id], lock: lock,
                                       identity: model.identity)
            }
            .modifier(RemoveMacAlert(mac: $removing, asksWhere: { list.store.sync?.asksOnRemove($0) ?? false }) { e, everywhere in
                list.store.remove(e.id, everywhere: everywhere)
            })
            .alert(UnlockMethod.current.turnOffAlertTitle, isPresented: $confirmLockOff) {
                Button("Turn Off", role: .destructive) {
                    Task {
                        await lock.setRequired(false)
                        if !lock.required { AutoUnlockSetting.appLockTurnedOff(store: list.store) }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(AutoUnlockRules.lockOffWarning(list.macs) ?? "")
            }
            .onChange(of: settingsFor) { _, new in if new == nil { probe() } }
            .refreshable { probe() }
            .onAppear {
                probe()
                if SimulatorSwitches.confirmLockOff, AutoUnlockRules.lockOffWarning(list.macs) != nil {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { confirmLockOff = true }
                }
            }
            .onChange(of: model.phase) { _, new in if new == .idle { probe() } }
            .alert(model.notice?.title ?? "", isPresented: Binding(get: { model.notice != nil },
                                                                    set: { if !$0 { model.notice = nil } })) {
                if model.notice?.offersForgetKey == true {
                    Button("Forget Saved Key", role: .destructive) { model.forgetSavedKey() }
                }
                // Project notes (computers-m3) 2: Screen Sharing did not open; the computer's other ways in, right here.
                // The notice's own words stay (a sign-in or identity failure is said plainly: review finding 3).
                if let e = model.notice?.computerID.flatMap({ list.store.entry($0) }) {
                    ForEach(ComputerNav.others(e, than: .screenSharing)) { w in
                        Button(e.insteadTitle(w)) { model.notice = nil; ComputerNav.shared.open(e, in: w) }
                    }
                }
                Button("OK", role: .cancel) {}
            } message: {
                Text(model.notice?.text ?? "")
            }
            .sheet(isPresented: Binding(get: { model.phase == .signingIn },
                                        set: { if !$0 && model.phase == .signingIn { model.cancelSignIn() } })) {
                SignInSheet(model: model)
            }
        }
    }

    private var progressText: String {
        switch model.phase {
        case .connecting: "Connecting to \(model.mac?.name ?? "the Mac")…"
        case .awaitingApproval: "Waiting for the Mac to allow this iPhone…"
        case .signingIn: "Signing in…"
        case let .reconnecting(attempt): "Reconnecting (try \(attempt))…"
        case .loadingPicture: "Waiting for the picture…"
        default: ""
        }
    }

    private func probe() {
        list.probeAll(identity: model.identity)
        ComputerReach.shared.probeAll(list.store.computers)
    }

    /// An icon the computer has: open it exactly that way (Screen Sharing: the Glass Act session, from the address the
    /// check found; Terminal and JetKVM: their own screens, no Glass Act session).
    private func open(_ e: MacEntry, in way: WayIn) {
        ComputerNav.shared.open(e, in: way)
    }

    /// ＋: Add Computer, one sheet. HIG Toolbars: a toolbar's ＋ adds an item.
    @ViewBuilder private func addMenu(prominent: Bool) -> some View {
        if prominent {
            Button("Add Computer") { showAdd = true }.buttonStyle(.borderedProminent)
                .accessibilityIdentifier("addComputer")
        } else {
            Button("Add Computer", systemImage: "plus") { showAdd = true }
                .accessibilityIdentifier("addMac")
        }
    }

}

/// The list's words that cover both kinds. Mac-only screens keep "Mac". The way in a gray icon adds, on which computer
/// (the list's Add sheet).
struct AddWayTarget: Identifiable, Hashable {
    let id: String
    let way: WayIn
}

enum ListWords {
    static let title = "Computers"
    /// What can be added in this build (Screen Sharing always; Terminal and JetKVM with their switches).
    static var emptyDescription: String {
        var ways = ["a Mac running Glass Act Host"]
        if WayIn.inThisBuild.contains(.terminal) { ways.append("a computer you reach over SSH") }
        if RDPScreen.inThisBuild { ways.append("a Windows PC with Remote Desktop") }
        if WayIn.inThisBuild.contains(.jetkvm) { ways.append("a computer with a JetKVM") }
        let list = ways.count > 1 ? ways.dropLast().joined(separator: ", ") + ", or " + ways.last! : ways[0]
        return "Add \(list)."
    }
    /// The footer says what the light, the name, the icons and the (i) do.
    static let footer = "Tap a name to open it in its Opens In choice, or an icon to open it that way; a gray icon adds "
        + "that way in. Tap ⓘ for its settings. Green: it answers. Yellow: it answers but needs you first (a sign-in, "
        + "or allowing it on the Mac). Red: it does not answer. An exclamation mark means that way in is not answering."
}

/// The outer screen's words and colours for a Mac (on hold, unchanged). The open screen's row is `ComputerListRow`.
enum MacRow {
    /// The outer screen's compact list's second line (which address answered; on hold, unchanged).
    static func secondLine(mac: MacEntry, reach: MacList.Reach, chosen: AddressKind?) -> String {
        if let chosen, reach.answered { return chosen.label }
        switch reach {
        case .checking: return "Checking…"
        case .wrongMac: return reach.label
        case .notChecked: return mac.addresses.first?.kind.label ?? ""
        default: return "Not reachable"
        }
    }

    static func color(for reach: MacList.Reach) -> Color {
        switch reach {
        case .ready: .green
        case .signInNeeded, .askOnMac: .orange
        default: .gray
        }
    }
}

/// First sign-in to a Mac: its account name and password, once. The password is never stored.
struct SignInSheet: View {
    @Bindable var model: SessionModel
    @FocusState private var focus: Field?
    private enum Field { case user, password }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $model.signInUser)
                        .textContentType(.username)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .focused($focus, equals: .user)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $model.signInPassword)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(.go)
                        .onSubmit { model.signIn() }
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Sign in with an account on “\(model.mac?.name ?? "this Mac")”. "
                             + "The Mac then knows this iPhone, and the password is not kept.")
                        if let code = model.verificationCode {
                            Text("Code: \(code)").font(.footnote.monospaced())
                        }
                        if let error = model.signInError {
                            Text(error).foregroundStyle(.red)
                        }
                    }
                }
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // System roles: the glass close and confirm buttons (DESIGN rules 14, 24).
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { model.cancelSignIn() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.signInBusy { ProgressView() } else {
                        // White on the orange confirm fill, forced.
                        Button(role: .confirm) { model.signIn() } label: {
                            Text("Sign In").foregroundStyle(.white)
                        }
                        .disabled(!model.canSignIn)
                    }
                }
            }
            .onAppear { focus = .user }
            .onDisappear { model.signInPassword = "" }
        }
        .presentationDetents([.medium])
    }
}

// MARK: - The session (open screen: upright with keyboard and trackpad, horizontal with touch)

struct SessionScreen: View {
    @Bindable var model: SessionModel
    let grid: TileGrid
    @State private var parts: SessionParts
    /// Horizontal: our keyboard is up (the column's Keyboard button).
    @State private var typing = false
    @State private var touchKeyboard: TouchKeyboardModel
    /// The system keyboard's height above the bottom safe area, from the keyboard layout guide.
    @State private var keyboardInset: CGFloat = 0
    /// Which side the trackpad is on, upright (the More menu and the Mac list set it).
    @AppStorage(TrackpadSide.storageKey) private var trackpadSide: TrackpadSide = .standard
    /// Regular or centred (upright only). Starts Whole Screen every session (`SessionModel.openView`).
    @State private var view: SessionView
    /// While a finger is on the trackpad, the layout's shape held as it was (an edge crossing onto a screen of
    /// another shape changes the layout only when the finger lifts: plan item 13).
    @State private var heldShape: PictureShape?
    /// A normal iPhone (`PhoneKind`): its own upright layout (`NormalPhoneLayout`); sideways the Duo's horizontal one.
    let normalPhone: Bool
    /// Normal iPhone, upright: the "…" page shows in place of the band.
    @State private var morePage = false
    /// Normal iPhone, JetKVM view: our keyboard typing into the JetKVM's keys (made when that view is chosen).
    @State private var kvmKeyboard: TouchKeyboardModel?
    /// Normal iPhone, upright: the model behind our keyboard, on the keys in use (`inputParts`).
    private var phoneKeyboard: TouchKeyboardModel {
        #if DUO_JETKVM
        if view.isJetKVM, let k = kvmKeyboard, k.engine === jetkvm.parts.keyboard.engine { return k }
        #endif
        return touchKeyboard
    }
    /// A normal iPhone's view button: Follow Pointer, then Terminal and JetKVM for a Mac with them on.
    private var phoneChoices: [SessionView] {
        SessionView.normalPhoneChoices(terminal: model.terminalOffered, jetkvm: model.jetkvmOffered)
    }

    #if DUO_TERMINAL
    /// This Mac's terminal (Terminal view).
    private var terminal: TerminalSession { TerminalSession.for(mac: model.mac?.id ?? "") }
    #endif

    /// The keys, trackpad and typing in use: the JetKVM's own set in the JetKVM view (they drive the JetKVM, not
    /// Glass Act), the session's otherwise.
    private func inputParts(wide: Bool) -> SessionParts {
        #if DUO_JETKVM
        if !wide && view.isJetKVM { return jetkvm.parts }
        #endif
        return parts
    }
    #if DUO_JETKVM
    /// This Mac's JetKVM (JetKVM view).
    private var jetkvm: JetKVMLink { JetKVMLink.for(mac: model.mac?.id ?? "") }
    #endif

    init(model: SessionModel, grid: TileGrid, normalPhone: Bool = false) {
        self.model = model
        self.grid = grid
        self.normalPhone = normalPhone
        // A normal iPhone has one view, Follow Pointer.
        _view = State(initialValue: normalPhone ? .centred : model.openView)
        // Through the model's gate: open only while the picture is live (nothing queued while rejoining).
        let parts = SessionParts(sink: model.input)
        _parts = State(initialValue: parts)
        _touchKeyboard = State(initialValue: TouchKeyboardModel(engine: parts.keyboard.engine))
    }

    /// A pinch on the picture: one step between the views (`PinchLadder`); the selector and the screen menu show
    /// the result at once (they read `view` and `model.showsOverview`). Horizontal has only the whole screen.
    private func pinchStep(_ step: PinchStep, wide: Bool) {
        // A normal iPhone upright has only Follow Pointer: nothing to step to.
        if normalPhone && !wide { return }
        let outcome = PinchLadder.next(from: wide ? .regular : view, step: step, multiScreen: model.multiScreen,
                                       overview: model.showsOverview, followPointerOffered: !wide)
        model.note("pinch \(step) on \(wide ? "horizontal" : view.rawValue): \(outcome)")
        switch outcome {
        case .view(let new):
            view = new
            model.openView = new
            model.storeView(new)
        case .allScreens:
            model.showOverview()
        case .nothing:
            break
        }
    }

    /// Normal iPhone, Terminal view: how far the panel moves down, so it starts where the terminal ends. 0 otherwise,
    /// and always 0 in a version built without the Terminal switch.
    private func terminalPanelDrop(_ phone: NormalPhoneLayout) -> CGFloat {
        #if DUO_TERMINAL
        if view.isTerminal { return phone.terminalPanelTop(keysRow: TerminalKeysBand.height) - phone.picture.height }
        #endif
        return 0
    }

    /// Terminal view: the band's height the terminal takes, so the one row of keys sits on the keyboard.
    private func terminalExtra(_ upright: SessionLayout.Upright) -> CGFloat {
        #if DUO_TERMINAL
        if view.isTerminal { return TerminalKeysBand.terminalExtra(bandHeight: upright.band.height) }
        #endif
        return 0
    }

    var body: some View {
        // The system navigation bar is the screen's top row: on the open Duo it shares the row with the clock and
        // status icons, and its buttons are Liquid Glass. The Mac picture starts directly below it.
        NavigationStack {
            SessionGeometry { proxy, wide in
                let insets = normalPhone && wide ? PhoneKind.sidewaysInsets() : (leading: 0, trailing: 0)
                let horizontal = HorizontalLayout(size: proxy.size, side: trackpadSide,
                                                  leadingInset: insets.leading, trailingInset: insets.trailing,
                                                  normalPhone: normalPhone && wide,
                                                  typing: model.keyboardRules.up)
                // A normal iPhone types on our own keyboard (its height is known) in the Mac and JetKVM views; the
                // Terminal view keeps the system keyboard the terminal takes, as on the Duo.
                let phone = NormalPhoneLayout(size: proxy.size,
                                              keyboardInset: view.isTerminal
                                                ? SimulatorSwitches.keyboardInset ?? keyboardInset
                                                : NormalPhoneLayout.ownKeyboardHeight(width: proxy.size.width),
                                              keyboardGap: view.isTerminal ? NormalPhoneLayout.pad : 0)
                let upright = SessionLayout.Upright(size: proxy.size,
                                                    keyboardInset: SimulatorSwitches.keyboardInset ?? keyboardInset,
                                                    side: trackpadSide, shape: shape)
                // One canvas in one place in the tree, so turning the phone keeps the same picture view.
                VStack(spacing: 0) {
                    // Size and counter from the same place (the model), read together (build 4: the freeze after a size change).
                    CanvasHost(controller: model.pictureController, grid: model.shownGrid ?? grid,
                               generation: model.gridGeneration,
                               parts: parts, directTouch: true, followPointer: !wide && (view == .centred || normalPhone),
                               typingVisibleHeight: wide && model.keyboardRules.up ? horizontal.panelTop : nil,
                               typingAimY: wide && model.keyboardRules.up ? model.typingAimY : nil,
                               onPinch: { step in pinchStep(step, wide: wide) })
                        .allowsHitTesting(model.flow.acceptsInput)
                        // Not live: the last picture, dimmed, with a quiet status (or the failure and Try Again).
                        .overlay { if model.flow.showsHeldPicture { NotLiveOverlay(model: model) } }
                        // All Screens (M4): every screen over the picture; a tap chooses one, never a click on the Mac.
                        .overlay { if model.showsOverview && model.multiScreen { ScreenOverview(model: model) } }
                        // An edge crossing names the new screen for about a second (plan item 13).
                        .overlay(alignment: .top) {
                            if let name = model.crossingName {
                                // Appears with the crossing slide (fades with Reduce Motion as well).
                                Text(name)
                                    .transition(.opacity)
                                    .font(.headline)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                                    .glassEffect(.regular, in: .capsule)
                                    .padding(.top, wide ? 24 : 12)
                                    .accessibilityIdentifier("crossingLabel")
                                    .allowsHitTesting(false)
                            }
                        }
                        .frame(width: wide ? nil : normalPhone ? phone.picture.width : upright.picture.width,
                               height: wide ? nil : normalPhone ? phone.picture.height : upright.picture.height)
                        .frame(maxWidth: wide ? .infinity : nil, maxHeight: wide ? .infinity : nil)
                        // The black stops at the picture: it must not run up behind the top row.
                        .background(Color.black, ignoresSafeAreaEdges: [])
                        // Terminal: the terminal in the picture's place, over the kept picture (Terminal.swift). It
                        // also takes the band's height above the one row of terminal keys, reaching down past the
                        // picture's bottom edge.
                        .overlay(alignment: .top) {
                            #if DUO_TERMINAL
                            if !wide && view == .terminal {
                                TerminalPanel(session: terminal, entry: model.mac.flatMap { model.store.entry($0.id) },
                                              store: model.store)
                                    .frame(height: normalPhone
                                           // A normal iPhone: the picture's and the band's space, less the one row.
                                           ? phone.terminalHeight(keysRow: TerminalKeysBand.height)
                                           : upright.picture.height
                                             + TerminalKeysBand.terminalExtra(bandHeight: upright.band.height))
                            }
                            #endif
                        }
                        .overlay {
                            #if DUO_JETKVM
                            // JetKVM: its picture in the picture's place, aspect-fitted (open screen, upright only).
                            if !wide && view == .jetkvm {
                                JetKVMPanel(link: jetkvm, entry: model.mac.flatMap { model.store.entry($0.id) })
                            }
                            #endif
                        }
                        // The buttons float over the picture (or its black bar) and take no layout space. Horizontal:
                        // the glass column and trackpad, and with the Keyboard button on, our own keyboard and its key
                        // row, over the whole-screen picture.
                        .overlay(alignment: .topLeading) {
                            if wide {
                                HorizontalControls(model: model, parts: parts, keyboard: touchKeyboard,
                                                   layout: horizontal,
                                                   // The Keyboard button goes through the keyboard rules: it
                                                   // always wins (`AutoKeyboard`).
                                                   typing: Binding(get: { model.keyboardRules.up }, set: { up in
                                                       if up != model.keyboardRules.up { model.keyboardButton() }
                                                   }))
                            }
                        }
                        // The one hidden input for the system keyboard, both layouts: on request over the
                        // picture when horizontal, up for the whole session when upright.
                        .background {
                            // In the Terminal view the terminal itself takes the system keyboard.
                            if wide || !view.isTerminal {
                            // Horizontal types on our own keyboard, so the system keyboard never comes up there.
                            // Sideways the responder holds only the clear click view while our keyboard is up,
                            // so our keys' system clicks play (`KeyFeedback`); a system hide changes nothing.
                            // A normal iPhone upright types on our own keyboard too: the responder holds only
                            // the clear click view, so the system keyboard never comes up there.
                            MacTypingField(up: wide ? Binding(get: { model.keyboardRules.up }, set: { _ in })
                                               : $typing,
                                           state: inputParts(wide: wide).keyboard, pinned: !wide, macKeysBar: false,
                                           clickOnly: wide || normalPhone)
                                .frame(width: 1, height: 1)
                            }
                        }
                    if !wide && normalPhone {
                        // The normal iPhone's band (NormalPhone.swift), on the same keyboard-coloured panel. The
                        // Terminal view: the one row of terminal keys on the keyboard, the terminal taking the rest
                        // (as on the Duo). The JetKVM view: the same band, driving the JetKVM (`inputParts`).
                        Group { if view.isTerminal {
                            #if DUO_TERMINAL
                            TerminalKeysBand(session: terminal)
                                .frame(width: phone.band.width, height: TerminalKeysBand.height)
                            #endif
                        } else {
                            let input = inputParts(wide: wide)
                            NormalPhoneBand(state: input.keyboard, pad: input.trackpad, layout: phone,
                                            trackpadDimmed: model.showsOverview, more: $morePage)
                        } }
                            .allowsHitTesting(model.flow.acceptsInput || view.isJetKVM)
                            .opacity(model.flow.showsHeldPicture && !view.isJetKVM ? 0.5 : 1)
                            .padding(.top, NormalPhoneLayout.pad)
                            .frame(width: proxy.size.width, alignment: .top)
                            .background(alignment: .top) {
                                Rectangle().fill(KeyLook.panel)
                                    .frame(height: proxy.size.height)
                                    .ignoresSafeArea(edges: .bottom)
                            }
                            // Terminal: the panel starts where the terminal ends (it reaches past the picture's
                            // bottom edge), so it never covers the terminal's last rows.
                            .padding(.top, terminalPanelDrop(phone))
                            .zIndex(1)
                        Spacer(minLength: 0)
                    } else if !wide {
                        //  The band fills from the picture to the top of the system keyboard; the click buttons and
                        // keys fill its height.: with the trackpad on the left, the halves swap; the keys keep their
                        // order (`TrackpadSide`).
                        Group { if view.isTerminal {
                            #if DUO_TERMINAL
                            TerminalKeysBand(session: terminal)
                                .frame(width: upright.band.width, height: TerminalKeysBand.height)
                            #endif
                        } else {
                        HStack(alignment: .bottom, spacing: SessionLayout.Upright.split) {
                            let parts = inputParts(wide: wide)
                            if trackpadSide == .left { trackpad(upright, parts: parts) }
                            SpecialKeysView(state: parts.keyboard, pad: parts.trackpad, metrics: upright.keyMetrics,
                                            side: trackpadSide, shape: shape)
                                .frame(width: upright.keys.width, height: upright.keys.height,
                                       alignment: trackpadSide == .left ? .bottomTrailing : .bottomLeading)
                            if trackpadSide == .right { trackpad(upright, parts: parts) }
                        }
                        } }
                        // In place while not live, but off: dimmed the way the system dims unavailable controls.
                        // Not dimmed during the brief check on return (no flicker), only off.
                        .allowsHitTesting(model.flow.acceptsInput || view.isJetKVM)
                        .opacity(model.flow.showsHeldPicture && !view.isJetKVM ? 0.5 : 1)
                        // The band sits on a panel the colour of the system keyboard's, running on down behind the
                        // keyboard, so band and keyboard read as one keyboard. Square top corners, flush with the
                        // picture's bottom edge, so no background shows at the corners. The panel also runs behind the
                        // system keyboard's own rounded top corners.
                        .padding(.top, upright.spacing.pad)
                        .frame(width: proxy.size.width, alignment: .top)
                        .background(alignment: .top) {
                            Rectangle().fill(KeyLook.panel)
                                .frame(height: proxy.size.height)
                                .ignoresSafeArea(edges: .bottom)
                        }
                        // Negative only when the keyboard is too tall even for the band's minimum: then the band
                        // sits over the picture's bottom edge, which keeps its full width (Upright.overlapsPicture).
                        .padding(.top, upright.band.minY - upright.spacing.pad - upright.picture.maxY
                                 + terminalExtra(upright))
                        .zIndex(1)
                        Spacer(minLength: 0)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                // A normal iPhone upright, Mac and JetKVM views: our own keyboard (the sideways view's, laid out at
                // the drawing's portrait sizes), always showing, on the panel under the band; its keys' pop-ups
                // rise over the band. It types into the keys in use (the JetKVM's in the JetKVM view).
                .overlay(alignment: .bottom) {
                    if normalPhone && !wide && !view.isTerminal {
                        TouchKeyboardView(model: phoneKeyboard, width: proxy.size.width, sizes: .portrait)
                            .frame(width: proxy.size.width, height: phone.keyboardInset, alignment: .top)
                            .allowsHitTesting(model.flow.acceptsInput || view.isJetKVM)
                            .opacity(model.flow.showsHeldPicture && !view.isJetKVM ? 0.5 : 1)
                            .accessibilityIdentifier("phoneKeyboard")
                    }
                }
                .background(wide ? Color.black : SessionTopRow.behind.colour)
                .ignoresSafeArea(edges: wide ? .all : [])
                .statusBarHidden(wide)
                .persistentSystemOverlays(wide ? .hidden : .automatic)
                .overlay {
                    if let text = model.unlockNotice { UnlockNoticeBanner(text: text) { model.dismissUnlockNotice() } }
                }
                .modifier(SessionTopRow(model: model, title: model.mac?.name ?? "Mac", notice: model.hostNotice,
                                        hidden: wide,
                                        view: Binding(get: { view }, set: { new in
                                            view = new
                                            model.openView = new
                                            model.storeView(new)
                                        }),
                                        leave: { model.disconnect() }, preview: SimulatorSwitches.topRowPreview,
                                        rowWidth: proxy.size.width,
                                        fixedChoices: normalPhone ? phoneChoices : nil,
                                        viewMenu: normalPhone))
                // Turning the phone lets go of every held key and button, and puts the keyboard away.
                .onChange(of: wide) { _, _ in
                    typing = false
                    model.keyboardRulesReset()
                    if normalPhone {
                        // A normal iPhone keeps its held modifiers across the turn; the mouse buttons and touch still
                        // let go.
                        parts.trackpad.releaseAll()
                        parts.touch.releaseAll()
                        parts.canvas?.layoutChanged()
                        morePage = false
                    } else {
                        parts.layoutChanged()
                    }
                }
                // Flipping the band lets go of every held key and button, as turning the phone does; the session
                // carries on.
                .onChange(of: trackpadSide) { _, _ in parts.releaseAll() }
                // Changing view lets go of held keys and buttons too.
                .onChange(of: view) { _, new in
                    parts.releaseAll()
                    morePage = false
                    #if DUO_JETKVM
                    if normalPhone && new.isJetKVM && kvmKeyboard?.engine !== jetkvm.parts.keyboard.engine {
                        kvmKeyboard = TouchKeyboardModel(engine: jetkvm.parts.keyboard.engine)
                    }
                    jetkvm.parts.releaseAll()
                    #endif
                }
                #if targetEnvironment(simulator)
                .onAppear {
                    guard SimulatorSwitches.keyboardUp else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        typing = true
                        if !model.keyboardRules.up { model.keyboardButton() }
                    }
                }
                .onAppear {
                    guard SimulatorSwitches.holdCommandShift else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        let k = parts.keyboard.engine
                        k.tapModifier(.command)
                        k.tapModifier(.shift)
                    }
                }
                .onAppear {
                    // `--edge-demo`: the real trackpad engine (the simulator's synthetic drags never reach the pad):
                    // 20 slow moves right (into the wall), then 30 left (across onto the neighbour).
                    guard ProcessInfo.processInfo.arguments.contains("--edge-demo") else { return }
                    let pad = parts.trackpad
                    for i in 0..<50 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 6 + Double(i) * 0.15 + (i >= 20 ? 3 : 0)) {
                            pad.move(dx: i < 20 ? 40 : -40, dy: 0, dt: 1)
                        }
                    }
                }
                .onAppear {
                    // `--choose-screen N` (simulator only, README pictures): what choosing screen N in the name
                    // bubble's menu does, once the session is up.
                    guard let n = SimulatorSwitches.chooseScreen else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { model.chooseScreen(n) }
                }
                .onAppear {
                    // `--pointer-walk` (simulator only, README pictures): moves through the real trackpad engine.
                    let pad = parts.trackpad
                    for w in SimulatorSwitches.pointerWalk {
                        for i in 0..<w.n {
                            DispatchQueue.main.asyncAfter(deadline: .now() + w.at + Double(i) * 0.05) {
                                pad.move(dx: w.dx, dy: w.dy, dt: 1)
                            }
                        }
                    }
                }
                .onAppear {
                    // `--choose-view NAME`: what a tap on that choice in the view switch does, once the session is up
                    // (a headless simulator cannot tap). Opening still starts in Whole Screen.
                    guard let v = SimulatorSwitches.chooseView, !wide else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                        guard (normalPhone ? phoneChoices
                               : SessionView.choices(terminal: model.terminalOffered, jetkvm: model.jetkvmOffered))
                            .contains(v) else { model.note("choose view: \(v.rawValue) not offered"); return }
                        view = v
                        model.openView = v
                        model.storeView(v)
                    }
                }
                .onAppear {
                    guard SimulatorSwitches.moreOn, !wide else { return }
                    // A normal iPhone: a second after `--choose-view` (changing view closes the "…" page).
                    DispatchQueue.main.asyncAfter(deadline: .now() + (normalPhone ? 5 : 4)) {
                        // A normal iPhone: `--more-on` opens its "…" page.
                        if normalPhone { morePage = true } else { parts.keyboard.functionKeys = true }
                    }
                }
                .onAppear {
                    guard SimulatorSwitches.openAppSwitcher, !wide else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 4) { parts.keyboard.engine.tapAppSwitcher() }
                }
                #endif
            }
            // The keyboard layout guide: how much of the bottom the system keyboard covers (upright layout only).
            .background { KeyboardGuideReader { keyboardInset = $0 }.ignoresSafeArea() }
            // Horizontal: the system keyboard overlaps the picture; the picture never moves or shrinks for it. Upright
            // lays out above the keyboard itself, from the keyboard layout guide.
            .ignoresSafeArea(.keyboard)
            .background(Color(.systemBackground))
        }
        // The pointer's bounds follow the negotiated canvas on every geometry change (review finding 1).
        .onChange(of: model.gridGeneration) { _, _ in
            if let g = model.grid { parts.setCanvas(width: g.width, height: g.height, fullWidth: model.fullCanvasWidth) }
        }
        .onAppear {
            parts.setCanvas(width: grid.width, height: grid.height, fullWidth: model.fullCanvasWidth)
            parts.keyboard.sendClipboard = { [weak model] text in model?.sendClipboard(text) }
            let p = parts
            model.releaseHeldInput = { [weak p] in p?.releaseAll() }
            model.heldInputOwner = ObjectIdentifier(p)
            // After a screen switch the pad carries on from where the Host put the pointer (the new screen's middle).
            model.onScreenSwitched = { [weak p] x, y in
                p?.trackpad.adopt(x: x, y: y)
                p?.canvas?.noteLocalCursor(x, y)
            }
            // Crossing an edge (plan item 13): a push past the edge asks the session; the pad carries on from where
            // the Host put the pointer on the new screen (Follow Pointer follows it there).
            p.trackpad.onFingerDown = { down in heldShape = down ? model.layoutShape : nil }
            p.trackpad.onPushPastEdge = { [weak model] x, y, w, h in
                model?.pushPastEdge(x: x, y: y, width: w, height: h) ?? false
            }
            // The crossing slide.
            model.onCrossingShown = { [weak p] dx, dy in p?.canvas?.crossingSlide(dx: CGFloat(dx), dy: CGFloat(dy)) }
            model.onSwitchEnded = { [weak p] point in
                guard let p else { return }
                p.trackpad.switchEnded(at: point)
                if let point {
                    p.touch.setCanvas(width: point.width, height: point.height)
                    p.canvas?.noteLocalCursor(point.x, point.y)
                }
            }
        }
        .onDisappear {
            parts.releaseAll()
            if model.heldInputOwner == ObjectIdentifier(parts) {
                model.releaseHeldInput = nil
                model.heldInputOwner = nil
            }
            model.onScreenSwitched = nil
            model.onSwitchEnded = nil
            model.onCrossingShown = nil
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            parts.releaseAll()
        }
    }

    /// The layout's shape (16:9 or 16:10): the session model decides it once per shown screen; the view only reads
    /// it (held as it was while a finger is on the trackpad).
    private var shape: PictureShape { heldShape ?? model.layoutShape }

    private func trackpad(_ upright: SessionLayout.Upright, parts: SessionParts) -> some View {
        TrackpadView(engine: parts.trackpad)
            .frame(width: upright.trackpad.width, height: upright.trackpad.height)
            .background(KeyLook.keyFill, in: RoundedRectangle(cornerRadius: TrackpadView.cornerRadius,
                                                              style: .continuous))
            // Dimmed and off while All Screens shows (plan item 6); the keys still type.
            .opacity(model.showsOverview ? 0.4 : 1)
            .allowsHitTesting(!model.showsOverview)
    }
}

/// The session screen's geometry. Horizontal is decided from the scene's shape, never from a screen's numbers.
/// Horizontal, the reader drops every safe area, so the picture is aspect-fitted to the FULL screen and centred (black
/// bars only above and below); upright keeps the safe area below the top row. The shape gives the same answer either
/// way, so the state settles after one pass.
struct SessionGeometry<Content: View>: View {
    @ViewBuilder let content: (GeometryProxy, Bool) -> Content
    @State private var wideScene = false

    var body: some View {
        GeometryReader { proxy in
            let wide = SessionLayout.isHorizontal(proxy.size)
            content(proxy, wide)
                .onChange(of: wide, initial: true) { _, now in
                    if wideScene != now { wideScene = now }
                }
        }
        // All regions, the keyboard's too: the picture never moves or shrinks when the keyboard comes up.
        .ignoresSafeArea(wideScene ? .all : [], edges: .all)
    }
}

/// The session's top row, upright: back to the Macs list (which disconnects), the Mac's name bubble, and the view
/// selector, as system toolbar items. The system puts them in the clock's row on the open Duo and draws
/// them in Liquid Glass (DESIGN rules 1-5); nothing here draws a bar or a background. Horizontal hides the whole
/// bar (rule 6): the picture is full screen and its own two glass buttons stay visible over it.
///
/// No More (…) menu. Its items now live: About Duo Desktop (with the picture's rate) on the Mac list; Trackpad
/// Left/Right on the Mac list; Disconnect is the back button.
struct SessionTopRow: ViewModifier {
    /// Upright the session screen paints the system background behind the bar.
    static let behind = BarBackdrop.app
    @Bindable var model: SessionModel
    let title: String
    let notice: String?
    let hidden: Bool
    @Binding var view: SessionView
    let leave: () -> Void
    /// Tests and simulator screenshots: show this name (and this screen, with the menu) instead of the session's.
    var preview: (mac: String, screen: String?)? = nil
    /// Tests: each part's frame in the window as it is laid out ("name": the name's glass pill, "selector").
    var report: ((String, CGRect) -> Void)? = nil
    /// The row's width (the screen's, upright), for the name bubble's widest size.
    var rowWidth: CGFloat = 669
    /// Tests only: the view switch's choices (the probe's model offers neither Terminal nor JetKVM).
    var choicesForTest: [SessionView]? = nil
    /// A normal iPhone: only the views that work there (Follow Pointer).
    var fixedChoices: [SessionView]? = nil
    /// A normal iPhone: the view control is one drop-down button (`ViewMenuButton`) in place of the Duo's four-across
    /// switch. Everything else in the bar is the Duo's (`DuoTitleBar`).
    var viewMenu = false

    /// The screen's name on a multi-screen Mac, nil on a one-screen Mac (or an older Host).
    private var screenName: String? {
        if let preview { return preview.screen }
        guard model.multiScreen else { return nil }
        return model.showsOverview ? "All Screens" : model.shownScreen?.name ?? ""
    }

    /// The Duo bar's second line: what is being shown. With no screen's name to show (a one-screen Mac, an older Host)
    /// the line is the way in's name, "Screen Sharing", so the bar looks the same on every computer.
    static func shownLine(view: SessionView, screen: String?) -> String {
        #if DUO_TERMINAL
        if view == .terminal { return "Terminal" }
        #endif
        #if DUO_JETKVM
        if view == .jetkvm { return "JetKVM" }
        #endif
        if let screen, !screen.isEmpty { return screen }
        return WayIn.screenSharing.label
    }

    private var choices: [SessionView] {
        if let choicesForTest { return choicesForTest }
        if let fixedChoices { return fixedChoices }
        return SessionView.choices(terminal: model.terminalOffered, jetkvm: model.jetkvmOffered)
    }

    /// Tests and simulator only: room taken at the bar's right, standing in for the clock area's live activities
    /// (`TopBarStandIn`).
    var standIn: CGFloat = SimulatorSwitches.topBarReserve ?? 0

    func body(content: Content) -> some View {
        // Back, the computer's name as the bar's own title with the screens as its title menu, the views as one
        // trailing item. The system sizes, shortens and moves them; nothing of ours watches the bar. The normal iPhone
        // has the same bar; only its views control differs, one drop-down button (`ViewSwitch`).
        content
            .modifier(DuoTitleBar(title: preview?.mac ?? title,
                                  subtitle: Self.shownLine(view: view, screen: screenName), notice: notice,
                                  hidden: hidden, hasMenu: screenName != nil, behind: Self.behind, back: leave) {
                ScreenMenuItems(model: model)
            })
            .toolbar {
                TopBarViewsItem {
                    ViewSwitch(view: $view, choices: choices, normalPhone: viewMenu)
                        .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { report?("selector", $0) }
                }
                TopBarStandIn(width: standIn)
            }
    }
}

/// What a session screen paints behind its top bar, upright (the bar is hidden sideways). The one rule for the bar's
/// colours: the bar follows what is truly behind it. Build 83 forced the dark look on Terminal, JetKVM and Remote
/// Desktop alike, but only the Terminal screen is black there; JetKVM and Remote Desktop paint the system background,
/// so in light mode their bar drew white on white.
enum BarBackdrop {
    /// The system background: white in light mode, black in dark. The bar keeps the app's own look.
    case app
    /// Always black (the Terminal screen): the bar takes the dark look in light mode too, so the caret, the title
    /// and the second line draw light on the black (build 81 drew them dark on black).
    case black

    /// The scheme the bar's items take; nil keeps the app's.
    var scheme: ColorScheme? { self == .black ? .dark : nil }
    /// The colour the screen paints behind the bar.
    var colour: Color { self == .black ? .black : Color(.systemBackground) }
}

/// The Duo's top bar on the session, Terminal and JetKVM screens, Apple's way. Back on the left; the computer's name is
/// the bar's own title (`navigationTitle`), which the system sizes and shortens first when room is short; what the name
/// opens (a multi-screen Mac's screens) is Apple's title menu (`toolbarTitleMenu`); the subtitle (Apple's second line)
/// is what is shown (a screen's name, "Terminal", "JetKVM"), and a problem notice takes that line, in orange, while it
/// lasts. Each screen adds its views switch (`TopBarViewsItem`) and any other parts as trailing items. HIG, Designing
/// for iPhone Duo: "Use the system overflow menu." and "In general, don't override the default bar placement." No width
/// of ours decides what shows.
struct DuoTitleBar<Items: View>: ViewModifier {
    let title: String
    /// The second line: what is shown. nil: one line.
    var subtitle: String? = nil
    var notice: String? = nil
    let hidden: Bool
    /// Whether the title opens a menu (`items`); without one the title is plain.
    var hasMenu = false
    /// What the screen paints behind the bar (its own background there, not the picture below). The bar's
    /// words, caret and selector follow it by the system's own scheme (`BarBackdrop.scheme`).
    var behind: BarBackdrop = .app
    let back: () -> Void
    @ViewBuilder let items: () -> Items

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            // Apple: "On iOS and iPadOS, the subtitle is displayed with the navigation title in the navigation bar."
            // A notice takes the line while it lasts (it matters more than the screen's name, which the title menu
            // still ticks); the system sizes and shortens both lines.
            .navigationSubtitle(Self.line(subtitle: subtitle, notice: notice))
            .navigationBarTitleDisplayMode(.inline)
            // Apple's title menu only when there is something to list: an attached menu draws its chevron even when
            // empty. It hangs on a clear background, not on `content`, so a screen count arriving adds or removes the
            // menu without rebuilding the session view.
            .background { if hasMenu { Color.clear.toolbarTitleMenu { items() } } }
            .toolbar {
                // The back caret drawn bare, no glass of its own, so the bar's left is caret + title and its only
                // bubble is the views switch on the right. This screen is the root of its own NavigationStack (swapped
                // in, not pushed), so there is no system back button to restyle; this is our own standard Button, with
                // Apple's toolbar item modifier `sharedBackgroundVisibility(.hidden)` (iOS 26). 44 pt tap target.
                ToolbarItem(placement: .topBarLeading) {
                    BackToMacsButton(action: back, label: "Back")
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .sharedBackgroundVisibility(.hidden)
            }
            .toolbar(hidden ? .hidden : .visible, for: .navigationBar)
            .toolbarColorScheme(behind.scheme, for: .navigationBar)
    }

    /// The second line's text: the notice in orange if there is one, else what is shown, else nothing.
    static func line(subtitle: String?, notice: String?) -> Text {
        if let notice { return Text(notice).foregroundStyle(.orange) }
        return Text(subtitle ?? "")
    }
}

/// The views switch as the Duo bar's one trailing item, kept in sight longest (`visibilityPriority(.high)`): when
/// room is short the system shortens the title first, then moves this into its own "…" and brings it back when room
/// returns. Apple, visibilityPriority(_:): "When toolbar space is limited, items with a lower priority move into the
/// overflow menu before items with a higher priority."
struct TopBarViewsItem<Content: View>: ToolbarContent {
    @ViewBuilder let content: () -> Content

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) { content() }
            .visibilityPriority(.high)
            .sharedBackgroundVisibility(.visible)
    }
}

/// Simulator and tests only (`--top-bar-reserve N`): an empty, glassless part of N pt at the bar's right that takes
/// room from the leading parts, standing in for live activities beside the clock (the simulator cannot draw them).
/// Pinned, so it truly takes room: a plain trailing item went into the system's "…" itself. N = 0 (every real phone):
/// nothing.
struct TopBarStandIn: ToolbarContent {
    let width: CGFloat

    var body: some ToolbarContent {
        if width > 0 {
            ToolbarItem(placement: .topBarPinnedTrailing) { Color.clear.frame(width: width, height: 1) }
                .sharedBackgroundVisibility(.hidden)
        }
    }
}

/// One part of the session's top bar, the same for the open Duo and the normal iPhone (back, the name bubble, the
/// views). The part takes the bar's own glass and draws none of its own. HIG Toolbars, Best practices: "Reduce the use
/// of toolbar backgrounds and tinted controls. Any custom backgrounds and appearances you use might overlay or
/// interfere with background effects that the system provides." HIG Materials, Liquid Glass: "Standard components from
/// system frameworks pick up the appearance and behavior of this material automatically." A part that also drew a
/// `glassEffect` showed a second shape inside the bar's. `TopRowTests.testTopBarHasNoGlassInsideGlass` fails if any
/// part draws its own glass again.
struct TopBarItem<Content: View>: ToolbarContent {
    @ViewBuilder let content: () -> Content

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { content() }
            .sharedBackgroundVisibility(.visible)
    }
}

/// The one button that leaves the Mac and goes back to the Mac list: the standard back chevron, upright (in the bar)
/// and sideways (top-left corner) alike. HIG Toolbars: "the standard Back button lets them retrace their steps through
/// a hierarchy of information, and the standard Close button closes a modal view." The symbol's 20 pt minimum frame
/// keeps the sideways glass circle the size it was.
struct BackToMacsButton: View {
    let action: () -> Void
    /// What VoiceOver says. The Duo's bare caret says "Back".
    var label: String = "Back to Macs"

    var body: some View {
        Button(action: action) {
            Label {
                Text("Macs")
            } icon: {
                Image(systemName: "chevron.backward").frame(minWidth: 20, minHeight: 20)
            }
            .labelStyle(.iconOnly)
        }
        .accessibilityLabel(label)
        .accessibilityIdentifier("backToMacs")
    }
}

/// The views control on the top bar, the ONE control for every view of a computer: the Mac session, and the Terminal
/// and JetKVM screens opened from the list's icons. On the Duo always the switch (`ViewSelector`), which the system
/// moves into its "…" when room is short; on a normal iPhone one view button with the same choices as a menu
/// (`ViewMenuButton`).
struct ViewSwitch: View {
    @Binding var view: SessionView
    let choices: [SessionView]
    let normalPhone: Bool

    var body: some View {
        if normalPhone { ViewMenuButton(view: $view, choices: choices) }
        else { ViewSelector(view: $view, choices: choices) }
    }
}

/// The views control on a Terminal or JetKVM screen opened from the list: the same `ViewSwitch` with the same choices
/// that computer's Screen Sharing session shows (Whole Screen and Follow Pointer when it has Screen Sharing, then
/// Terminal, then JetKVM), shown whenever it has more than one way in. The current view is this screen's. Choosing
/// another lets go of this one (`leave`) and opens that: Whole Screen or Follow Pointer start the Screen Sharing
/// session in that view; Terminal or JetKVM open their own screens. Milestone 3's rule stays: a list icon opens exactly
/// its way in; this switch changes it from inside.
struct WayViewSwitch: View {
    let entry: MacEntry
    let current: SessionView
    let normalPhone: Bool
    let leave: () -> Void

    static func shows(_ e: MacEntry) -> Bool { e.waysInThisBuild.count > 1 }

    var choices: [SessionView] { SessionView.choices(for: entry, normalPhone: normalPhone) }

    var body: some View {
        if Self.shows(entry) {
            ViewSwitch(view: Binding(get: { current }, set: { choose($0) }), choices: choices,
                       normalPhone: normalPhone)
        }
    }

    private func choose(_ v: SessionView) {
        guard v != current else { return }
        leave()
        ComputerNav.shared.open(entry, view: v)
    }
}

/// The view selector: Whole Screen and Follow Pointer, side by side in one glass capsule. Each choice is a 44 pt target
/// (HIG Buttons: at least 44x44 pt) with no gap between them; the chosen one sits on the orange accent fill with a
/// white symbol. Was two toolbar toggles in one group: about 121 pt wide; now 88 pt.
struct ViewSelector: View {
    @Binding var view: SessionView
    /// Each choice is as tall as the system's own toolbar buttons (`TopRow.height`) and as wide.
    static let target: CGFloat = TopRow.height
    /// The chosen circle scales with the target (36 in 44 before).
    static let fill: CGFloat = (36 * TopRow.height / 44).rounded()
    /// The choices shown: Terminal only for a Mac with Terminal on.
    var choices: [SessionView] = SessionView.choices(terminal: false)
    var width: CGFloat { Self.target * CGFloat(choices.count) }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(choices) { v in
                let chosen = view == v
                Button {
                    view = v
                } label: {
                    // A title with each symbol (HIG, Designing for iPhone Duo: "Include a title even when an item
                    // shows a symbol, because the system uses the title in overflow menus and expanded forms.").
                    Label {
                        Text(v.title)
                    } icon: {
                        Image(systemName: v.systemImage)
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(chosen ? Color.white : Color.primary)
                            .frame(width: Self.fill, height: Self.fill)
                            .background { if chosen { Circle().fill(Color.accentColor) } }
                            .frame(width: Self.target, height: Self.target)
                            .contentShape(Rectangle())
                    }
                    .labelStyle(.iconOnly)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(v.title)
                .accessibilityAddTraits(chosen ? [.isSelected] : [])
                .accessibilityIdentifier("sessionView.\(v.rawValue)")
            }
        }
        .frame(width: width, height: Self.target)
        // No glass here: it is a `TopBarItem`, so the bar draws its one capsule.
    }
}

/// The top row's one height. The system draws its toolbar buttons (back, info) as round glass 48 pt tall on iOS 26 and
/// later (measured in the simulator: 144 px at 3x, the same as the Mac list's system button group); our own glass parts
/// (the selector, the name) take the same height, so all four sit on one line, top and bottom. HIG Toolbars: items in a
/// toolbar share one consistent size.
enum TopRow {
    static let height: CGFloat = 48
    /// A one-symbol part's content (the normal iPhone's view button): the system back button's own content size
    /// in the bar (measured 36 x 36); the bar adds its glass around it, so both draw the same circle.
    static let itemContent: CGFloat = 36
}

enum SessionLayout {
    /// The Duo held horizontally (wider than tall): the whole Mac screen, touch is the mouse.
    static func isHorizontal(_ size: CGSize) -> Bool { size.width > size.height }

    /// The upright layout, top to bottom: the Mac picture (16:9), the middle band (click buttons and special keys
    /// left, trackpad right) and, under everything, the iOS system keyboard. `size` is the safe area below the
    /// screen's top row (the system navigation bar, in the clock's row), so the picture's top edge is that row's
    /// bottom; `keyboardInset` is how far the keyboard reaches above its bottom. Nothing is placed below
    /// `keyboardTop`.
    ///
    /// The picture is ALWAYS the full width. The band takes the height left above the keyboard, and its 4 rows of keys
    /// fill it: the keys grow or shrink with the band, down to `minKeyHeight`. At that floor, as the space gets shorter
    /// still, the band's padding gives way (8 → 2), then the gap between rows (6 → 4); below that the band sits over
    /// the picture's bottom edge (`overlapsPicture`) rather than shrink the keys or the picture.
    ///
    /// On this Duo (835 pt below the top row, a 376 pt picture, so the room above the keyboard is 459 - keyboard):
    /// - the owner's phone (keyboard 293 pt): 166 pt of room, a 150 pt band, 33 pt keys with 6 pt gaps;
    /// - this simulator (277 pt): 182 pt of room, a 166 pt band, 37 pt keys;
    /// - the floor with standard spacing (154 pt of room): keyboard up to 305 pt;
    /// - the floor at minimum spacing (136 pt): up to 323 pt; from 326 pt the band overlaps the picture.
    struct Upright {
        static let margin: CGFloat = 8
        static let split: CGFloat = 8
        static let bandPad: CGFloat = 8
        static let minBandPad: CGFloat = 2
        /// The smallest gap between key rows.
        static let minRowGap: CGFloat = 4
        /// The smallest key height: the owner's phone gets 33 pt, so 30 pt leaves room for a slightly taller keyboard
        /// (a suggestion bar, a bigger text size) before anything else gives way. Glyphs stay at their size.
        static let minKeyHeight: CGFloat = 30
        /// The 16:9 band's rows.
        static let rows = SpecialKeysLayout.rowCount

        let size: CGSize
        let keyboardInset: CGFloat
        /// Right: keys left, trackpad right (the standard). Left: the halves swap. Sizes are the same either way.
        var side: TrackpadSide = .standard
        /// The shape of the picture the Mac sends. 16:10: the picture is full width and taller, and the band has 3 rows
        /// (`SixteenTenKeysLayout`). 16:9 is today's layout, untouched.
        var shape: PictureShape = .sixteenNine

        /// The band's rows: 4 for 16:9, 3 for 16:10.
        var rows: Int { shape == .sixteenTen ? SixteenTenKeysLayout.rowCount : Self.rows }

        var keyboardTop: CGFloat { size.height - keyboardInset }
        /// In the safe area's coordinates: y 0 is the bottom of the top row. Full width, in the picture's shape.
        var picture: CGRect {
            CGRect(x: 0, y: 0, width: size.width, height: (size.width * shape.heightOverWidth).rounded(.down))
        }
        private static func floorHeight(rows: Int, rowGap: CGFloat) -> CGFloat {
            KeyMetrics.band(rows: rows, keyHeight: minKeyHeight, rowGap: rowGap)
        }
        private func floorHeight(rowGap: CGFloat) -> CGFloat { Self.floorHeight(rows: rows, rowGap: rowGap) }
        /// The smallest height the 16:9 band needs: keys at the floor, minimum padding and minimum row gap.
        static var minimumRoom: CGFloat { floorHeight(rows: rows, rowGap: minRowGap) + 2 * minBandPad }
        /// The height between the picture and the keyboard.
        private var room: CGFloat { keyboardTop - picture.maxY }
        /// Padding above and below the band, and the gap between key rows: the standard ones while the keys are
        /// above their floor; otherwise the padding gives way first, then the row gap, each to its minimum.
        var spacing: (pad: CGFloat, rowGap: CGFloat) {
            let full = floorHeight(rowGap: KeyMetrics.gap)
            if room >= full + 2 * Self.bandPad { return (Self.bandPad, KeyMetrics.gap) }
            if room >= full + 2 * Self.minBandPad { return (((room - full) / 2).rounded(.down), KeyMetrics.gap) }
            let gaps = CGFloat(rows - 1)
            let gap = ((room - 2 * Self.minBandPad - CGFloat(rows) * Self.minKeyHeight) / gaps).rounded(.down)
            return (Self.minBandPad, min(KeyMetrics.gap, max(Self.minRowGap, gap)))
        }
        /// True when even the floor at minimum spacing does not fit: the band then covers the picture's bottom edge.
        var overlapsPicture: Bool { band.minY < picture.maxY }
        var band: CGRect {
            let sp = spacing
            // Normally from the picture down to the keyboard; never shorter than the keys at their floor.
            let height = max(floorHeight(rowGap: sp.rowGap), room - 2 * sp.pad)
            let top = keyboardTop - sp.pad - height
            return CGRect(x: Self.margin, y: top, width: size.width - 2 * Self.margin, height: height)
        }
        private var keysWidth: CGFloat { ((band.width - Self.split) / 2).rounded(.down) }
        private var trackpadWidth: CGFloat { band.width - keysWidth - Self.split }
        var keys: CGRect {
            let b = band
            let x = side == .right ? b.minX : b.maxX - keysWidth
            return CGRect(x: x, y: b.minY, width: keysWidth, height: b.height)
        }
        var trackpad: CGRect {
            let b = band
            let x = side == .right ? b.maxX - trackpadWidth : b.minX
            return CGRect(x: x, y: b.minY, width: trackpadWidth, height: b.height)
        }
        /// The keys' height and the gap between rows: the 4 rows fill the band, top and bottom level with the
        /// trackpad's. The key height is whole points, never under `minKeyHeight`; the points it leaves over go
        /// into the three gaps, evenly.
        var rowMetrics: (keyHeight: CGFloat, rowGap: CGFloat) {
            Self.rowMetrics(bandHeight: band.height, rowGap: spacing.rowGap, rows: rows)
        }
        static func rowMetrics(bandHeight: CGFloat, rowGap: CGFloat,
                               rows: Int = Upright.rows) -> (keyHeight: CGFloat, rowGap: CGFloat) {
            let n = CGFloat(rows), gaps = n - 1
            let key = max(minKeyHeight, ((bandHeight - gaps * rowGap) / n).rounded(.down))
            return (key, max(rowGap, (bandHeight - n * key) / gaps))
        }
        var keyMetrics: KeyMetrics {
            let r = rowMetrics
            return SpecialKeysView.metrics(width: keys.width, rowGap: r.rowGap, keyHeight: r.keyHeight)
        }
    }
}

/// The session's input engines, made once per session screen.
@MainActor
final class SessionParts {
    let keyboard: KeyboardState
    let trackpad: TrackpadEngine
    /// Touch on the picture is the pointer, in both layouts (Apple's touch-display MacBook mapping).
    let touch: DirectTouchEngine
    weak var canvas: CanvasView?

    init(sink: any InputSink) {
        let keys = MacKeyboardEngine(sink: sink)
        keyboard = KeyboardState(engine: keys)
        trackpad = TrackpadEngine(sink: sink)
        touch = DirectTouchEngine(sink: sink)
        trackpad.modifierWrap = { [weak keys] body in
            if let keys { keys.withModifiers(body) } else { body() }
        }
        touch.modifierWrap = { [weak keys] body in
            if let keys { keys.withModifiers(body) } else { body() }
        }
        touch.keys = keys
        trackpad.onPointer = { [weak self] x, y in self?.canvas?.noteLocalCursor(x, y) }
        touch.onPointer = { [weak self] x, y in
            self?.canvas?.noteLocalCursor(x, y)
            self?.trackpad.adopt(x: x, y: y)
        }
    }

    /// Both pointer engines follow the negotiated canvas.
    func setCanvas(width: Int, height: Int, fullWidth: Int? = nil) {
        trackpad.setCanvas(width: width, height: height, fullWidth: fullWidth)
        touch.setCanvas(width: width, height: height, fullWidth: fullWidth)
    }

    /// The phone turned between upright and horizontal: nothing stays held across the switch.
    func layoutChanged() {
        releaseAll()
        canvas?.layoutChanged()
    }

    /// Lifts every held key, latched modifier and button, and stops a scroll glide.
    func releaseAll() {
        keyboard.engine.releaseAll()
        trackpad.releaseAll()
        touch.releaseAll()
    }
}

/// Over the last picture while a session is rejoined: dimmed, a small status, or the failure with Try Again. It
/// takes the picture's touches, so nothing reaches the Mac.
struct NotLiveOverlay: View {
    @Bindable var model: SessionModel

    var body: some View {
        ZStack {
            Color.black.opacity(0.45)
            if model.flow.stage == .failed {
                VStack(spacing: 10) {
                    Text("Couldn’t reconnect to “\(model.mac?.name ?? "the Mac")”")
                        .font(.headline)
                    Text("Check that the Mac is on and on the tailnet.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button { model.retryRejoin() } label: {
                        // White on the orange accent fill, forced.
                        Text("Try Again").foregroundStyle(.white)
                    }
                        .buttonStyle(.glassProminent)
                        .padding(.top, 4)
                }
                .multilineTextAlignment(.center)
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .glassEffect(.regular, in: .rect(cornerRadius: 22))
                .padding(16)
            } else {
                Label {
                    Text("Reconnecting…")
                } icon: {
                    ProgressView().controlSize(.small)
                }
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .capsule)
            }
        }
        .environment(\.colorScheme, .dark)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(model.flow.stage == .failed ? "Not connected" : "Reconnecting")
    }
}

private struct CanvasHost: UIViewRepresentable {
    let controller: ViewerController?
    let grid: TileGrid
    let generation: Int
    let parts: SessionParts
    let directTouch: Bool
    var followPointer = false
    var typingVisibleHeight: CGFloat? = nil
    var typingAimY: CGFloat? = nil
    var onPinch: ((PinchStep) -> Void)? = nil

    final class Coordinator { var generation = -1 }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> CanvasView {
        let v = CanvasView(controller: controller, grid: grid)
        context.coordinator.generation = generation
        parts.canvas = v
        let trackpad = parts.trackpad
        v.onHostCursor = { x, y in trackpad.hostPointer(x: x, y: y) }
        v.touchEngine = parts.touch
        v.directTouch = directTouch
        v.followPointer = followPointer
        v.typingVisibleHeight = typingVisibleHeight
        v.typingAimY = typingAimY
        v.onPinchStep = onPinch
        return v
    }

    func updateUIView(_ v: CanvasView, context: Context) {
        v.directTouch = directTouch
        v.followPointer = followPointer
        v.typingVisibleHeight = typingVisibleHeight
        v.typingAimY = typingAimY
        v.onPinchStep = onPinch
        v.attach(controller)
        v.follow(grid: grid, generation: generation, lastGeneration: &context.coordinator.generation)
    }

    static func dismantleUIView(_ v: CanvasView, coordinator: Coordinator) { v.stopPresenting() }
}

/// The upright session's two views: the regular one (whole Mac screen) and centred (a quarter of the screen following
/// the pointer). Remembered per Mac.
enum SessionView: String, CaseIterable, Identifiable {
    case regular, centred
    #if DUO_TERMINAL
    /// The terminal (Terminal.swift), offered only for a Mac whose Terminal switch is on (`choices(terminal:)`).
    case terminal
    #endif
    #if DUO_JETKVM
    /// The JetKVM's picture with our trackpad and keys (JetKVM.swift), offered only for a Mac with JetKVM on.
    case jetkvm
    #endif

    var id: String { rawValue }
    var title: String {
        switch self {
        case .regular: "Whole Screen"
        case .centred: "Follow Pointer"
        #if DUO_TERMINAL
        case .terminal: "Terminal"
        #endif
        #if DUO_JETKVM
        case .jetkvm: "JetKVM"
        #endif
        }
    }
    var systemImage: String {
        switch self {
        case .regular: "rectangle"
        case .centred: "scope"
        #if DUO_TERMINAL
        case .terminal: "apple.terminal"
        #endif
        #if DUO_JETKVM
        // The list's JetKVM symbol (one definition: `WayIn.symbol`, the HDMI stick).
        case .jetkvm: WayIn.jetkvm.symbol
        #endif
        }
    }
    /// The Terminal view (always false in the plain version).
    var isTerminal: Bool {
        #if DUO_TERMINAL
        self == .terminal
        #else
        false
        #endif
    }
    /// The JetKVM view (always false without DUO_JETKVM).
    var isJetKVM: Bool {
        #if DUO_JETKVM
        self == .jetkvm
        #else
        false
        #endif
    }
    static func storageKey(mac: String) -> String { "sessionView.\(mac)" }
    /// The Mac's remembered view, or Regular when none is stored (or one no longer offered, such as the scrapped
    /// "twoPads").
    static func stored(mac: String, in defaults: UserDefaults = .standard) -> SessionView {
        defaults.string(forKey: storageKey(mac: mac)).flatMap(SessionView.init(rawValue:)) ?? .regular
    }
    func store(mac: String, in defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: Self.storageKey(mac: mac))
    }
}

/// The Trackpad selector: Left or Right, the system's two-choice control, a segmented control in the Mac list's
/// settings (HIG Segmented controls: a small set of mutually exclusive choices). Its only place since the session's
/// More menu went: a setting changed now and then, not in the session's top row.
struct TrackpadSidePicker: View {
    enum Style { case segmented }
    @Binding var side: TrackpadSide
    let style: Style

    var body: some View {
        switch style {
        case .segmented:
            LabeledContent("Trackpad") {
                picker.pickerStyle(.segmented).fixedSize()
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var picker: some View {
        Picker(selection: $side) {
            ForEach(TrackpadSide.allCases) { Text($0.title).tag($0) }
        } label: {
            Label("Trackpad", systemImage: "rectangle.split.2x1")
        }
        .accessibilityIdentifier("trackpadSide")
    }
}

/// The screen menu's items, the same in the top row's name and the horizontal screens button (plan item 3):
/// "All Screens" first, then each screen, a checkmark on the current one (toggles in a menu show the system check).
struct ScreenMenuItems: View {
    @Bindable var model: SessionModel

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { model.showsOverview }, set: { if $0 { model.showOverview() } })) {
                Label("All Screens", systemImage: "rectangle.3.group")
            }
        }
        Section {
            ForEach(model.screens) { s in
                Toggle(isOn: Binding(get: { !model.showsOverview && model.shownScreenID == s.id },
                                     set: { if $0 { model.chooseScreen(s.id) } })) {
                    Text(s.name)
                }
            }
        }
    }
}

/// All Screens (plan item 1): every screen as its small picture, placed and sized as on the Mac, each with its
/// name; the one in use outlined in the accent orange. Touching one chooses it (never a click on the Mac); the
/// picture becomes that screen once the Host answers. Opaque, so no touch reaches the picture under it.
struct ScreenOverview: View {
    @Bindable var model: SessionModel

    var body: some View {
        GeometryReader { geo in
            let rects = ScreenOverviewLayout.place(model.screens, in: geo.size, labelHeight: 0)
            ZStack(alignment: .topLeading) {
                Color.black
                ForEach(model.screens) { s in
                    if let r = rects[s.id] {
                        Button { model.chooseScreen(s.id) } label: { tile(s, size: r.size) }
                            .buttonStyle(.plain)
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                            .accessibilityLabel(s.name)
                            .accessibilityIdentifier("screenTile.\(s.id)")
                    }
                }
            }
        }
        .contentShape(Rectangle())
    }

    private func tile(_ s: MacScreen, size: CGSize) -> some View {
        let inUse = s.id == model.shownScreenID
        return ZStack(alignment: .bottom) {
            // The Host's snapshot (refreshed every few seconds), else the list's small picture, else grey.
            if let image = model.screenSnapshots[s.id] ?? s.thumbnail {
                Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: size.width, height: size.height).clipped()
            } else {
                Color(white: 0.2)
            }
            Text(s.name)
                .font(.caption.weight(.semibold)).foregroundStyle(.white).lineLimit(1)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.black.opacity(0.6), in: Capsule())
                .padding(4)
            if model.choosingScreenID == s.id {
                ProgressView().tint(.white).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay {
            RoundedRectangle(cornerRadius: 3)
                .strokeBorder(inUse ? Color.accentColor : Color.white.opacity(0.25), lineWidth: inUse ? 3 : 1)
        }
        // 1-pixel gaps between touching screens, so each reads as its own.
        .padding(1)
    }
}

// The view switch's choices; Terminal only in the DUO_TERMINAL build, for a Mac with Terminal on.
extension SessionView {
    /// The choices in the view switch for a Mac.
    static func choices(terminal: Bool, jetkvm: Bool = false) -> [SessionView] {
        var c: [SessionView] = [.regular, .centred]
        #if DUO_TERMINAL
        if terminal { c.append(.terminal) }
        #endif
        #if DUO_JETKVM
        // Fourth, after Terminal, only for a Mac with JetKVM on.
        if jetkvm { c.append(.jetkvm) }
        #endif
        return c
    }

    /// A normal iPhone's view button: the Duo's choices, per Mac and by the same settings switches, less Whole Screen
    /// (the normal iPhone's Mac view is Follow Pointer only: "The display on the Mac is square").
    static func normalPhoneChoices(terminal: Bool, jetkvm: Bool = false) -> [SessionView] {
        choices(terminal: terminal, jetkvm: jetkvm).filter { $0 != .regular }
    }

    /// A computer's views by its ways in, as its Screen Sharing session's switch shows them: Whole Screen and Follow
    /// Pointer for Screen Sharing (a normal iPhone: Follow Pointer only), then Terminal, then JetKVM, each only when
    /// the computer has that way in and this build shows it.
    static func choices(for e: MacEntry, normalPhone: Bool) -> [SessionView] {
        var c: [SessionView] = []
        if e.opens(.screenSharing) { c += normalPhone ? [.centred] : [.regular, .centred] }
        #if DUO_TERMINAL
        if e.opens(.terminal) { c.append(.terminal) }
        #endif
        #if DUO_JETKVM
        if e.opens(.jetkvm) { c.append(.jetkvm) }
        #endif
        return c
    }

    /// The way in a view belongs to.
    var way: WayIn {
        switch self {
        case .regular, .centred: .screenSharing
        #if DUO_TERMINAL
        case .terminal: .terminal
        #endif
        #if DUO_JETKVM
        case .jetkvm: .jetkvm
        #endif
        }
    }

    /// A stored choice that is no longer offered (Terminal turned off since) falls back to Whole Screen.
    static func resolve(stored: String?, terminal: Bool, jetkvm: Bool = false) -> SessionView {
        guard let v = stored.flatMap(SessionView.init(rawValue:)), choices(terminal: terminal, jetkvm: jetkvm).contains(v) else {
            return .regular
        }
        return v
    }
}
