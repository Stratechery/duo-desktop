// Adapted from Glass Act Apps/iPad/SessionModel.swift at 486f11518da42d3ff7fac840a7bb9881d1425ca9.
// Glass Act is MIT licensed, Copyright (c) 2026 Brian Lopez; see Acknowledgements. Kept: connect, trust on first
// use, sign-in (§3.9), bounded redial, pause when hidden. Dropped: nearby (Bonjour), resolution choices (the
// geometry request is GeometryGuard's alone), recents, approval-by-code waits beyond the Host's own.
import GlassActAV1Decode
import GlassActCore
import GlassActSession
import GlassActTransport
import GlassActWire
import LocalAuthentication
import Observation
import Security
import UIKit
import os

@MainActor @Observable
final class SessionModel {
    enum Phase: Equatable {
        case idle
        case connecting
        case awaitingApproval(code: String)
        case signingIn
        case reconnecting(attempt: Int)
        case loadingPicture
        case inSession
    }

    struct Notice: Equatable {
        var title: String
        var text: String
        var offersForgetKey = false
        /// The computer Screen Sharing did not open: the alert offers its other ways in.
        var computerID: String? = nil
    }

    var phase: Phase = .idle {
        // "Last Mac" is stored by the session itself on every successful connect, whatever started it (list tap,
        // redial, rejoin, the outer screen's cold connect): the outer screen's cold open then always goes to the Mac
        // the phone was last on.
        didSet { if phase == .inSession, oldValue != .inSession, let mac { LastMac.store(mac, in: lastMacDefaults) } }
    }
    /// Where "last Mac" is kept (tests pass their own).
    @ObservationIgnored var lastMacDefaults: UserDefaults = .standard
    var notice: Notice?
    private(set) var mac: MacEntry?
    /// The address this session dials: the one the list found answering (MacList.choose).
    private(set) var dialHost = ""
    private(set) var dialKind: AddressKind?
    /// The stored list (plan: the Mac's key and view live in its entry).
    let store: MacStore

    var signInUser = ""
    var signInPassword = ""
    var signInError: String?
    var signInBusy = false
    var canSignIn: Bool {
        !signInBusy && !signInUser.trimmingCharacters(in: .whitespaces).isEmpty && !signInPassword.isEmpty
    }

    private(set) var controller: ViewerController?
    /// Lifts every held key, latched modifier and mouse button (the session screen's engines). Called while the
    /// connection is still up, before the session ends, before it is hidden or backgrounded, so the Mac never
    /// keeps a key or button down.
    @ObservationIgnored var releaseHeldInput: (() -> Void)?
    /// Whose `releaseHeldInput` is set (the open or the outer screen's input parts). On a fold the new screen's
    /// appear can run before the old one's disappear; the old one then must not clear the new one's hook.
    @ObservationIgnored var heldInputOwner: ObjectIdentifier?
    private(set) var grid: TileGrid?
    private(set) var gridGeneration = 0
    /// The layout's shape (16:9 or 16:10), decided once per shown screen and held (`LayoutShapeDecision`). Kept
    /// through a rejoin; cleared only when a session starts or ends.
    private(set) var shapeDecision = LayoutShapeDecision()
    var layoutShape: PictureShape { shapeDecision.shape ?? .sixteenNine }
    /// The largest picture width this Mac has sent since connecting: the full size, before any shrink on a slow
    /// link. Trackpad speed and scroll distance are kept the same at every size from it.
    private(set) var fullCanvasWidth = 0
    /// How long the Mac's control bytes go missing while live, for the return check's bound (`LinkPace`).
    private(set) var linkPace = LinkPace()
    private var paceTimer: Timer?
    private var paceInFlight = false
    private(set) var hostNotice: String?
    /// SCREEN_LOCK from the Mac's Host: true locked / at the login window, false not, nil = this Host does not say
    /// (older Host).
    private(set) var macLocked: Bool?
    /// The last TEXT_FOCUS from the Mac's Host (nil = never told).
    private(set) var textFocus: WireTextFocus?
    /// The horizontal view's keyboard rules (`AutoKeyboard`).
    private(set) var keyboardRules = AutoKeyboard()
    /// The round trip to the Mac, for the top bar.
    private(set) var throughput: String?
    /// The phone's key, short form ("ga1…"), shown on the list screen.
    private(set) var viewerKeyString = ""
    private(set) var viewerKeySource = ""

    static let log = Logger(subsystem: "com.example.duodesktop", category: "session")
    private(set) var identity: SecIdentity?
    private(set) var viewerFingerprint = ""
    private var dialPin = ""
    private var trustingOnFirstUse = false
    private var askedHowToJoin = false
    private var signInGeneration = 0
    private var signInPin = ""
    private var reconnect = ReconnectPolicy()
    private var pendingRedial: DispatchWorkItem?
    private var pollTimer: Timer?
    private var pollInFlight = false
    private var throughputTimer: Timer?
    private var resumeOnForeground = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    // MARK: Leaving and coming back (ReturnFlow)

    /// Leaving for another app and coming back: what is on screen and whether input reaches the Mac.
    private(set) var flow = ReturnFlow()
    /// The session screen's input goes through this; open only while live.
    let input = InputGate()

    // MARK: Where typing goes

    private var pictureSize: (Int, Int) { ((shownGrid ?? grid)?.width ?? 0, (shownGrid ?? grid)?.height ?? 0) }

    private var passwordPictureY: CGFloat { TypingFocusMap.passwordField.y * CGFloat(pictureSize.1) }

    func noteScreenLock(_ locked: Bool) {
        note("Mac \(locked ? "locked" : "unlocked")")
        macLocked = locked
        keyboardRules.lock(locked, passwordY: passwordPictureY)
        if locked {
            tryAutoUnlock()
        } else {
            if unlockInFlight { note("unlock: the Mac unlocked") }
            finishUnlock()
            unlockNotice = nil
        }
    }

    // MARK: Unlock automatically

    /// The Host can type the saved password (it said UNLOCK_STATE available on connect). An older Host never says.
    private(set) var hostCanUnlock = false
    /// "Could not unlock. The saved password may be wrong." after a try that did not unlock.
    private(set) var unlockNotice: String?
    /// The app lock's evaluated context while it is passed (`AppLock.autoUnlockContext`); nil = no automatic unlock.
    @ObservationIgnored var autoUnlockContext: () -> LAContext? = { nil }
    @ObservationIgnored var passwords: MacPasswordKeeping = MacPasswordKeychain.shared
    @ObservationIgnored var unlockDefaults: UserDefaults = .standard
    /// Sends the password to the Host (tests replace it).
    @ObservationIgnored var sendUnlock: (([UInt8]) -> Void)?
    private(set) var unlockInFlight = false
    @ObservationIgnored private var unlockTimeout: DispatchWorkItem?

    /// This Mac's setting is on and its last try did not fail, the Host can type and the app lock is passed: the
    /// Mac is expected to unlock by itself.
    var autoUnlockExpected: Bool {
        guard let mac else { return false }
        return AutoUnlockRules.expected(hostCanUnlock: hostCanUnlock,
                                        settingOn: store.entry(mac.id)?.autoUnlock == true,
                                        lastTryFailed: AutoUnlockFailures.failed(mac.id, in: unlockDefaults) || unlockNotice != nil,
                                        appUnlocked: autoUnlockContext() != nil)
    }

    /// The outer screen's opening, in one place: on the password field with the keyboard up only for a Mac that is
    /// locked and will NOT be unlocked automatically (setting off, an older Host, or the one try failed), and for an
    /// older Host that does not say (nil: today's way). Otherwise the dialog spot with the keyboard down.
    var outerOpensOnPassword: Bool {
        guard let locked = macLocked else { return true }
        return locked && !autoUnlockExpected
    }

    func noteUnlockState(_ state: UInt8) {
        switch state {
        case UnlockState.available:
            hostCanUnlock = true
            tryAutoUnlock()
        case UnlockState.typed:
            note("unlock: the Host typed the saved password")
        case UnlockState.notLocked:
            note("unlock: the Mac was not locked; nothing typed")
            finishUnlock()
        default:
            note("unlock: the Host could not type")
            finishUnlock()
        }
    }

    /// One try, never two in a row after a failure. Called on a lock report, on the Host saying it can type, and
    /// when the app lock is passed.
    func tryAutoUnlock() {
        guard let mac else { return }
        let context = autoUnlockContext()
        guard AutoUnlockRules.shouldTry(locked: macLocked, hostCanUnlock: hostCanUnlock,
                                        settingOn: store.entry(mac.id)?.autoUnlock == true,
                                        lastTryFailed: AutoUnlockFailures.failed(mac.id, in: unlockDefaults),
                                        inFlight: unlockInFlight, appUnlocked: context != nil),
              let context, let send = sendUnlock ?? controller.map({ c in { c.sendUnlockPassword($0) } })
        else { return }
        guard var data = passwords.read(macID: mac.id, context: context), !data.isEmpty else {
            note("unlock: the saved password could not be read; nothing sent")
            return
        }
        unlockInFlight = true
        unlockNotice = nil
        note("unlock: asking the Host to type the saved password")
        var bytes = [UInt8](data)
        send(bytes)
        data.resetBytes(in: 0..<data.count)
        for i in bytes.indices { bytes[i] = 0 }
        let macID = mac.id
        let timeout = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.unlockWaitEnded(macID: macID) } }
        unlockTimeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + AutoUnlockRules.unlockWait, execute: timeout)
    }

    /// The wait for "unlocked" is over (tests call it directly).
    func unlockWaitEnded(macID: String) {
        guard unlockInFlight, mac?.id == macID else { return }
        unlockInFlight = false
        unlockTimeout = nil
        guard macLocked == true else { return }
        // Still locked: the password is taken as wrong and never tried again until it is saved again.
        AutoUnlockFailures.set(macID, failed: true, in: unlockDefaults)
        unlockNotice = AutoUnlockRules.failedNotice
        note("unlock: still locked after \(Int(AutoUnlockRules.unlockWait)) s; not trying again")
    }

    private func finishUnlock() {
        unlockInFlight = false
        unlockTimeout?.cancel()
        unlockTimeout = nil
    }

    func dismissUnlockNotice() { unlockNotice = nil }

    private func resetUnlock() {
        finishUnlock()
        hostCanUnlock = false
        unlockNotice = nil
    }

    func noteTextFocus(_ focus: WireTextFocus) {
        textFocus = focus
        let (w, h) = pictureSize
        let screen = TypingFocusMap.screenFrame(shown: shownScreen?.frame, pictureWidth: w, pictureHeight: h)
        keyboardRules.focus(y: TypingFocusMap.pictureY(focus, screen: screen, pictureHeight: h),
                            at: ProcessInfo.processInfo.systemUptime)
    }

    /// Every input the session sends (the gate's `onSent`).
    func noteSentInput(kind: UInt8) {
        // Only a real change is stored: every pointer move comes through here.
        var rules = keyboardRules
        switch kind & InputFlags.kindMask {
        case 3: rules.userClicked(at: ProcessInfo.processInfo.systemUptime) // button up
        case 1: rules.pointerMoved()
        case 5: rules.typed()
        default: return
        }
        if rules != keyboardRules { keyboardRules = rules }
    }

    /// The horizontal Keyboard button.
    func keyboardButton() { keyboardRules.button() }
    /// The phone turned: the horizontal keyboard goes away.
    func keyboardRulesReset() { keyboardRules.reset() }

    /// Where the horizontal view aims while the keyboard is up: a picture height, or nil = the pointer.
    var typingAimY: CGFloat? {
        if case let .field(y) = keyboardRules.aim { return y }
        return nil
    }
    /// The picture's grid, kept while a session is rejoined behind its last picture.
    private(set) var shownGrid: TileGrid?
    /// The controller the picture draws from: the session's own while live or kept in the background; nil while
    /// rejoining, so the last picture stays as it was.
    var pictureController: ViewerController? {
        flow.drawsFromSession ? controller : nil
    }
    /// The session screen is up, live or holding the last picture.
    var showsSession: Bool { flow.showsSession && shownGrid != nil }
    private var rejoinTries = 0
    /// Seconds from return (or a drop) to the live picture, for the log.
    private var rejoinStartedAt: Date?
    /// The check on return that the kept session is still alive (`ReturnCheck`), polled every 50 ms.
    private var returnCheck: ReturnCheck?
    private var returnCheckTimer: Timer?
    private var returnCheckInFlight = false

    static var deviceName: String { UIDevice.current.name }

    /// The app's one session. Every window (open screen, outer screen, and any window iOS makes for a screen)
    /// shows this same session, so the two screens can never be on two different Macs.
    static let app = SessionModel()

    init(store: MacStore = .shared) {
        self.store = store
        do {
            let (identity, source) = try QUICIdentity.loadForApp(directory: AppPaths.dataDirectory,
                                                                 name: "viewer-identity", commonName: "duo-screens")
            self.identity = identity
            viewerFingerprint = try QUICIdentity.fingerprint(of: identity)
            viewerKeyString = QUICIdentity.keyString(viewerFingerprint)
            viewerKeySource = source.description
            note("viewer key \(viewerKeyString) (\(source.description))")
        } catch {
            note("identity error: \(error)")
            notice = .init(title: "This iPhone has no key", text: "Macs will refuse it. Quit Duo Desktop and try again.")
        }
    }

    func note(_ text: String) {
        Self.log.notice("\(text, privacy: .public)")
    }

    // MARK: - Connecting

    func connect(to entry: MacEntry, via kind: AddressKind? = nil) {
        guard controller == nil else { return }
        let use = kind.flatMap { entry.address($0) != nil ? $0 : nil }
            ?? entry.lastAddress.flatMap { entry.address($0) != nil ? $0 : nil }
            ?? entry.addresses.first?.kind
        guard let use, let host = entry.address(use) else { return }
        mac = entry
        // The owner 2026-11-21: a session on the open screen always STARTS in Whole Screen, whatever this Mac was left in.
        openView = .regular
        dialKind = use
        dialHost = host
        fullCanvasWidth = 0
        shapeDecision = LayoutShapeDecision()
        linkPace.reset()
        reconnect.reset()
        askedHowToJoin = false
        phase = .connecting
        dial()
    }

    private func dial() {
        guard controller == nil, let mac else { return }
        pendingRedial?.cancel()
        pendingRedial = nil
        // One key per Mac, whatever the address (plan §2): a different machine at either address is refused.
        let fingerprint = store.entry(mac.id)?.key ?? ""
        trustingOnFirstUse = fingerprint.isEmpty
        dialPin = fingerprint
        notice = nil
        note(trustingOnFirstUse ? "connecting to \(dialHost):\(mac.port), a new Mac (trust on first use)…"
                                : "connecting to \(dialHost):\(mac.port)…")

        let controller = ViewerController(host: dialHost, port: mac.port, fingerprint: fingerprint, identity: identity,
                                          videoDecoders: .glassAct(av1: false), deviceName: Self.deviceName)
        controller.onStatus = { text in Self.log.notice("\(text, privacy: .public)") }
        controller.onConnectionFailed = { [weak self, weak controller] in
            guard let self, let controller, self.controller === controller else { return }
            self.handleConnectionFailure()
        }
        controller.onHostKeyChanged = { [weak self, weak controller] expected, presented in
            guard let self, let controller, self.controller === controller else { return }
            self.handleHostKeyChanged(expected: expected, presented: presented)
        }
        controller.onHostEndedSession = { [weak self, weak controller] reason in
            guard let self, let controller, self.controller === controller else { return }
            let name = mac.name
            self.endSession()
            self.notice = .init(title: "Session ended", text: "“\(name)” ended the session: \(reason).",
                               computerID: self.mac?.id)
        }
        controller.onIncompatibleHost = { [weak self, weak controller] _ in
            guard let self, let controller, self.controller === controller else { return }
            self.endSession()
            self.notice = .init(title: "Different versions",
                                text: "“\(mac.name)” runs a different Glass Act version than this app.",
                                computerID: mac.id)
        }
        controller.onScreenLock = { [weak self, weak controller] state in
            guard let self, let controller, self.controller === controller else { return }
            self.noteScreenLock(state == ScreenLock.locked)
        }
        controller.onUnlockState = { [weak self, weak controller] state in
            guard let self, let controller, self.controller === controller else { return }
            self.noteUnlockState(state)
        }
        controller.onTextFocus = { [weak self, weak controller] focus in
            guard let self, let controller, self.controller === controller else { return }
            self.noteTextFocus(focus)
        }
        controller.onHostNotice = { [weak self, weak controller] code in
            guard let self, let controller, self.controller === controller else { return }
            switch code {
            case HostNotice.sessionOffScreen: self.hostNotice = "This Mac switched to another user."
            case HostNotice.none: self.hostNotice = nil
            default: break
            }
        }
        controller.onGeometryChanged = { [weak self, weak controller] w, h in
            guard let self, let controller, self.controller === controller,
                  let grid = controller.configuredGrid() else { return }
            self.note("canvas \(w)x\(h)")
            self.fullCanvasWidth = max(self.fullCanvasWidth, grid.width)
            self.grid = grid
            // The picture view draws from `shownGrid`: it must take the new size too, or it keeps the old one while the
            // pointer engines take the new one.
            if self.shownGrid != nil { self.shownGrid = grid }
            self.gridGeneration += 1
        }
        // Several screens (M4): the Host's list and its answer to each choice (MacScreens.swift).
        controller.onDisplayList = { [weak self, weak controller] list in
            guard let self, let controller, self.controller === controller else { return }
            self.screenListArrived(list, controller: controller)
        }
        controller.onDisplaySelected = { [weak self, weak controller] answer in
            guard let self, let controller, self.controller === controller else { return }
            self.screenChoiceAnswered(answer)
        }
        // All Screens snapshots (an older Host never sends them: the tiles stay as before).
        controller.onDisplaySnapshot = { [weak self, weak controller] snapshot in
            guard let self, let controller, self.controller === controller else { return }
            self.snapshotArrived(snapshot)
        }
        controller.setQualityPrefs(floor: 0, motionPreference: 0)
        // Shared clipboard, the library's own sync: Mac copies land on the phone; phone copies go only by the
        // Paste key, or on their own when the owner has turned that on in About (Clipboard.swift).
        controller.pasteboard = DuoPasteboard()
        self.controller = controller
        #if DUO_TERMINAL
        TerminalKeyByHost.live = .init(macID: mac.id, controller: controller) // the Host adds the terminal key
        #endif
        controller.start()
        // Handshake geometry, through the guard only: Scale at 1920 x 1080 (rides HELLO_OK, before any pixels).
        GeometryGuard.requestStandard(on: controller)
        startPolling { [weak self] in self?.configurePollFired() }
    }

    private func startPolling(_ fire: @escaping @MainActor () -> Void) {
        pollTimer?.invalidate()
        pollInFlight = false
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { _ in
            MainActor.assumeIsolated { fire() }
        }
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        pollInFlight = false
    }

    private func configurePollFired() {
        guard !pollInFlight, let controller else { return }
        pollInFlight = true
        controller.configuredGrid { [weak self] grid in
            guard let self else { return }
            self.pollInFlight = false
            guard grid != nil, self.controller === controller, self.pollTimer != nil else { return }
            self.configured()
        }
    }

    private func configured() {
        reconnect.sessionEstablished()
        rememberHostKeyIfNew()
        if let mac, let kind = dialKind {
            store.update(mac.id) { $0.lastAddress = kind; $0.lastUsed = Date() }
        }
        phase = .loadingPicture
        startPolling { [weak self] in self?.picturePollFired() }
    }

    private func picturePollFired() {
        guard !pollInFlight, let controller else { return }
        pollInFlight = true
        controller.hasPicture { [weak self] ready in
            guard let self else { return }
            self.pollInFlight = false
            guard ready, self.controller === controller, self.pollTimer != nil,
                  let grid = controller.configuredGrid() else { return }
            self.stopPolling()
            // First input of every session: let go of all modifiers (`ConnectRelease`), before any touch can send.
            ConnectRelease.send(to: controller)
            self.fullCanvasWidth = max(self.fullCanvasWidth, grid.width)
            self.grid = grid
            self.gridGeneration += 1
            // The session's first picture decides the layout's shape; a rejoin keeps what was decided.
            if let line = self.shapeDecision.firstPicture(width: grid.width, height: grid.height) { self.note(line) }
            self.phase = .inSession
            self.goLive(controller: controller, grid: grid)
            self.note("presenting canvas \(grid.width)x\(grid.height)")
            UIApplication.shared.isIdleTimerDisabled = true
            self.startThroughput()
        }
    }

    /// The picture is live (first connect or a rejoin): engines start clean, then the gate opens.
    private func goLive(controller: ViewerController, grid: TileGrid) {
        let wasRejoin = flow.showsHeldPicture
        _ = flow.wentLive()
        shownGrid = grid
        rejoinTries = 0
        // The gate is still closed: this only clears the engines' own held state, nothing reaches the Mac.
        releaseHeldInput?()
        input.open(to: controller)
        input.onSent = { [weak self] kind in self?.noteSentInput(kind: kind) }
        // A Host that lists screens: ask for the list (it opens on the remembered screen when it arrives). An older
        // Host never answers, and nothing new shows.
        restoredScreen = false
        if controller.hostSupportsDisplayList() { controller.selectDisplay(0) }
        if wasRejoin, let started = rejoinStartedAt {
            note(String(format: "rejoined: live picture %.2f s after the return", Date().timeIntervalSince(started)))
        }
        rejoinStartedAt = nil
    }

    /// Four times a second while live: how long since the Mac's last control byte (`LinkPace`).
    private func startPace() {
        paceTimer?.invalidate()
        paceInFlight = false
        paceTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.paceFired() }
        }
    }

    private func paceFired() {
        guard !paceInFlight, flow.stage == .live, let controller else { return }
        paceInFlight = true
        controller.queue.async { [weak self, engine = controller.engine] in
            let rx = engine.lastControlRxUS
            let now = MonotonicClock.nowUS
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.paceInFlight = false
                    guard self.controller === controller, self.flow.stage == .live, rx > 0, now > rx else { return }
                    self.linkPace.record(stalenessUS: now - rx)
                }
            }
        }
    }

    private func startThroughput() {
        startPace()
        throughputTimer?.invalidate()
        throughputTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let controller = self.controller else { return }
                controller.bandwidthSummary { [weak self] line in self?.throughput = line }
            }
        }
    }

    private func rememberHostKeyIfNew() {
        guard trustingOnFirstUse, let mac, let presented = controller?.observedHostFingerprint else { return }
        trustingOnFirstUse = false
        rememberKey(presented, for: mac)
    }

    /// The first key either address shows is stored in the Mac's entry, once.
    private func rememberKey(_ key: String, for mac: MacEntry) {
        guard store.entry(mac.id)?.key == nil else { return }
        store.update(mac.id) { $0.key = key }
        note("trusted new host key \(key) for “\(mac.name)” (at \(dialHost):\(mac.port))")
    }

    /// The open screen's view in THIS session. Every connect starts it at Whole Screen; a fold and unfold during the
    /// session brings it back as it was left. The outer screen never reads or writes it (it keeps its own opening:
    /// vertical, on the password field, keyboard up).
    var openView: SessionView = .regular

    /// The view last used on this Mac (stored in its entry). Recorded only; it no longer picks the start
    /// (`openView` does).
    var storedView: SessionView {
        let entry = mac.flatMap { store.entry($0.id) }
        return SessionView.resolve(stored: entry?.view, terminal: terminalOffered, jetkvm: jetkvmOffered)
    }

    /// Terminal is a choice in the view switch only for a Mac whose Terminal switch is on (always off without
    /// DUO_TERMINAL, the plain version).
    var terminalOffered: Bool {
        #if DUO_TERMINAL
        mac.flatMap { store.entry($0.id)?.terminalOn } ?? false
        #else
        false
        #endif
    }

    /// JetKVM is a choice in the view switch only for a Mac whose JetKVM switch is on (always off without
    /// DUO_JETKVM).
    var jetkvmOffered: Bool {
        #if DUO_JETKVM
        JetKVMSettings.offered(mac.flatMap { store.entry($0.id) })
        #else
        false
        #endif
    }

    func storeView(_ v: SessionView) {
        guard let mac else { return }
        store.update(mac.id) { $0.view = v.rawValue }
    }

    // MARK: - Ending

    func disconnect() {
        guard controller != nil || phase != .idle || flow.stage != .none else { return }
        note("disconnected by the user")
        endSession()
        mac = nil
    }

    private func endSession() {
        releaseHeldInput?()
        input.close()
        flow.ended()
        stopReturnCheck()
        shownGrid = nil
        rejoinStartedAt = nil
        pendingRedial?.cancel(); pendingRedial = nil
        stopPolling()
        throughputTimer?.invalidate(); throughputTimer = nil; paceTimer?.invalidate(); paceTimer = nil
        resetScreens()
        controller?.stop()
        controller = nil
        grid = nil
        shapeDecision = LayoutShapeDecision()
        hostNotice = nil
        macLocked = nil
        textFocus = nil
        resetUnlock()
        keyboardRules = AutoKeyboard()
        throughput = nil
        reconnect.reset()
        askedHowToJoin = false
        signInGeneration += 1
        signInPassword = ""
        signInError = nil
        signInBusy = false
        phase = .idle
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// The connection ends but the session screen stays: the last picture, the Mac and the keys remain for the
    /// rejoin. Held input is let go first, while the gate may still be open.
    private func endConnectionKeepingPicture() {
        releaseHeldInput?()
        input.close()
        stopReturnCheck()
        pendingRedial?.cancel(); pendingRedial = nil
        stopPolling()
        throughputTimer?.invalidate(); throughputTimer = nil; paceTimer?.invalidate(); paceTimer = nil
        resetScreens()
        controller?.stop()
        controller = nil
        grid = nil
        hostNotice = nil
        macLocked = nil
        textFocus = nil
        resetUnlock()
        keyboardRules = AutoKeyboard()
        throughput = nil
        phase = .idle
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// Dials again behind the last picture.
    private func startRejoin() {
        endConnectionKeepingPicture()
        rejoinTries = 0
        rejoinStartedAt = Date()
        notice = nil
        note("rejoining behind the last picture…")
        phase = .reconnecting(attempt: 1)
        dial()
    }

    /// A rejoin's dial failed: try again shortly, or say so plainly.
    private func rejoinDialFailed() {
        endConnectionKeepingPicture()
        rejoinTries += 1
        guard rejoinTries < ReturnFlow.rejoinAttempts else {
            note("rejoin failed after \(rejoinTries) tries")
            if flow.rejoinFailed() == .showFailure { rejoinStartedAt = nil }
            return
        }
        phase = .reconnecting(attempt: rejoinTries + 1)
        let redial = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.flow.stage == .rejoining else { return }
                self.dial()
            }
        }
        pendingRedial = redial
        DispatchQueue.main.asyncAfter(deadline: .now() + ReconnectPolicy.delaySeconds, execute: redial)
    }

    /// Try Again, after a failed rejoin.
    func retryRejoin() {
        if flow.retry() == .dial { startRejoin() }
    }

    // MARK: - Failures

    private func handleConnectionFailure() {
        guard let failed = controller else { return }
        switch flow.stage {
        case .rejoining:
            return rejoinDialFailed()
        case .live, .awayKept, .checking:
            let foreground = UIApplication.shared.applicationState != .background
            note(foreground ? "connection dropped: rejoining behind the picture"
                            : "connection dropped while away: rejoin on return")
            switch flow.connectionDropped(inForeground: foreground) {
            case .dial: startRejoin()
            case .endKeepingPicture: endConnectionKeepingPicture()
            default: break
            }
            return
        default:
            break
        }
        let wasInSession = phase == .inSession
        let code = failed.lastFailureAwaitsApproval && !wasInSession ? failed.verificationCode() : nil
        let presentedKey = failed.observedHostFingerprint
        stopPolling()
        throughputTimer?.invalidate(); throughputTimer = nil; paceTimer?.invalidate(); paceTimer = nil
        failed.stop()
        controller = nil
        if !wasInSession, !askedHowToJoin, phase == .connecting {
            askedHowToJoin = true
            askHowToJoin(code: code, presentedKey: presentedKey)
            return
        }
        continueAfterFailure(code: code, wasInSession: wasInSession)
    }

    private func continueAfterFailure(code: String?, wasInSession: Bool) {
        if let code { phase = .awaitingApproval(code: code) }
        guard let attempt = reconnect.nextAttempt() else {
            let name = mac?.name ?? "the Mac"
            endSession()
            notice = .init(title: "Couldn’t reach “\(name)”",
                           text: "Check that Glass Act Host is running on that Mac and that this iPhone is on the tailnet.",
                           computerID: mac?.id)
            return
        }
        grid = nil
        if code == nil, wasInSession || phase != .connecting { phase = .reconnecting(attempt: attempt) }
        let redial = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.dial() } }
        pendingRedial = redial
        DispatchQueue.main.asyncAfter(deadline: .now() + ReconnectPolicy.delaySeconds, execute: redial)
    }

    private func handleHostKeyChanged(expected: String, presented: String) {
        let name = mac?.name ?? "The Mac"
        endSession()
        notice = .init(title: "This isn’t the Mac you added.",
                       text: "“\(name)” at \(dialHost) presented a different key than the one saved earlier. That happens when a Mac’s "
                           + "identity is reset, and it is also what someone listening in between would look like. "
                           + "Only forget the saved key if you know why it changed.",
                       offersForgetKey: true, computerID: mac?.id)
    }

    func forgetSavedKey() {
        guard let mac else { return }
        store.update(mac.id) { $0.key = nil }
        notice = .init(title: "Saved key forgotten", text: "Connect again to trust the Mac’s new key.")
    }

    // MARK: - Signing in (§3.9)

    private func askHowToJoin(code: String?, presentedKey: String?) {
        guard let mac else { return }
        let generation = signInGeneration
        let pin = dialPin.isEmpty ? (presentedKey ?? "") : dialPin
        note("asking how new viewers join…")
        SignInClient.send(SignInRequest(op: .query, device: Self.deviceName), host: dialHost, port: mac.port,
                          pinnedFingerprint: pin, identity: identity, timeout: 5) { [weak self] outcome in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.signInGeneration == generation, self.controller == nil else { return }
                    self.handleHowToJoin(outcome, code: code, pin: pin)
                }
            }
        }
    }

    private func handleHowToJoin(_ outcome: SignInClient.Outcome, code: String?, pin: String) {
        note("join: \(outcome.response.map { "\($0.status)" } ?? "no answer (\(outcome.error ?? "?"))")")
        if outcome.hostKeyMismatch, let presented = outcome.hostFingerprint {
            return handleHostKeyChanged(expected: pin, presented: presented)
        }
        switch outcome.response?.status {
        case .signInAvailable?:
            signInPin = dialPin.isEmpty ? (outcome.hostFingerprint ?? pin) : dialPin
            signInPassword = ""
            signInError = nil
            phase = .signingIn
            if let (user, password) = SimulatorSwitches.testSignIn {
                signInUser = user
                signInPassword = password
                signIn()
            }
        case .closed?:
            let name = mac?.name ?? "the Mac"
            endSession()
            notice = .init(title: "Not accepting new viewers",
                           text: "On “\(name)”, choose who can connect in Glass Act Host › Options › New Viewers.",
                           computerID: mac?.id)
        case .askOnHost?:
            let askCode = code ?? (outcome.hostFingerprint ?? (pin.isEmpty ? nil : pin)).map {
                QUICIdentity.verificationCode(hostFingerprint: $0, viewerFingerprint: viewerFingerprint)
            }
            continueAfterFailure(code: askCode, wasInSession: false)
        default:
            continueAfterFailure(code: code, wasInSession: false)
        }
    }

    /// The code both screens can show for this Mac: the phone's key and the Mac's, checked by eye.
    var verificationCode: String? {
        let key = controller?.observedHostFingerprint ?? (signInPin.isEmpty ? nil : signInPin)
        return key.map { QUICIdentity.verificationCode(hostFingerprint: $0, viewerFingerprint: viewerFingerprint) }
    }

    func signIn() {
        guard canSignIn, let mac else { return }
        let generation = signInGeneration
        let pin = signInPin
        let request = SignInRequest(op: .signIn, user: signInUser.trimmingCharacters(in: .whitespaces),
                                    password: signInPassword, device: Self.deviceName)
        // The password is not kept: cleared the moment it is sent.
        signInPassword = ""
        signInBusy = true
        signInError = nil
        note("signing in…")
        SignInClient.send(request, host: dialHost, port: mac.port, pinnedFingerprint: pin,
                          identity: identity) { [weak self] outcome in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.signInGeneration == generation, self.phase == .signingIn else { return }
                    self.handleSignIn(outcome, pin: pin)
                }
            }
        }
    }

    func cancelSignIn() {
        note("sign-in cancelled")
        endSession()
        mac = nil
    }

    private func handleSignIn(_ outcome: SignInClient.Outcome, pin: String) {
        signInBusy = false
        note("sign in: \(outcome.response.map { "\($0.status)" } ?? "no answer (\(outcome.error ?? "?"))")")
        if outcome.hostKeyMismatch, let presented = outcome.hostFingerprint {
            return handleHostKeyChanged(expected: pin, presented: presented)
        }
        switch outcome.response?.status {
        case .approved?:
            if trustingOnFirstUse, let mac, let key = outcome.hostFingerprint {
                rememberKey(key, for: mac)
            }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            signInUser = ""
            phase = .connecting
            reconnect.reset()
            dial()
        case .wrongCredentials?:
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            signInError = "The name or password is incorrect."
        case .tooManyAttempts?:
            let minutes = max(1, (Int(outcome.response?.retryAfterSeconds ?? 60) + 59) / 60)
            signInError = minutes == 1 ? "Too many attempts. Try again in a minute."
                                       : "Too many attempts. Try again in \(minutes) minutes."
        default:
            signInError = "Couldn’t reach the Mac. Check that it is still on the network and try again."
        }
    }

    // MARK: - App lifecycle

    /// Hidden (backgrounded, or the phone closed onto its outer screen): the Mac stops sending the picture.
    func setVisible(_ visible: Bool) {
        if !visible { releaseHeldInput?() }
        controller?.windowVisibilityChanged(visible: visible)
    }

    func didEnterBackground() {
        switch flow.left() {
        case .pause:
            releaseHeldInput?()
            input.close()
            stopReturnCheck()
            controller?.windowVisibilityChanged(visible: false)
            note("left: session kept while iOS allows")
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Duo Desktop session") { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if self.flow.backgroundTimeUp() == .endKeepingPicture {
                        self.note("background time is up: session ended, last picture kept")
                        self.endConnectionKeepingPicture()
                    }
                    self.endBackgroundTask()
                }
            }
            return
        case .endKeepingPicture:
            note("left mid-rejoin: rejoin again on return")
            endConnectionKeepingPicture()
            return
        default:
            break
        }
        guard flow.stage == .none, let controller else { return }
        releaseHeldInput?()
        controller.windowVisibilityChanged(visible: false)
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Duo Desktop session") { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.controller != nil {
                    self.note("background time is up: leaving the session")
                    self.resumeOnForeground = true
                    self.endSession()
                }
                self.endBackgroundTask()
            }
        }
    }

    /// Back from another app. `locked`: the Touch ID lock is up, and the rejoin waits for it.
    func willEnterForeground(locked: Bool) {
        endBackgroundTask()
        switch flow.returned(locked: locked) {
        case .check:
            // The picture comes back as normal at once; input waits for proof the session is alive.
            controller?.windowVisibilityChanged(visible: true)
            startReturnCheck()
            return
        case .dial:
            startRejoin()
            return
        default:
            if flow.stage != .none { return }
        }
        if let controller {
            controller.windowVisibilityChanged(visible: true)
        } else if resumeOnForeground, mac != nil {
            resumeOnForeground = false
            phase = .reconnecting(attempt: 1)
            dial()
        }
    }

    // MARK: - The check on return

    private func startReturnCheck() {
        stopReturnCheck()
        let check = ReturnCheck(returnedUS: MonotonicClock.nowUS, boundUS: linkPace.returnBoundUS)
        returnCheck = check
        note(String(format: "back: checking the session is alive (up to %.2f s, from the link's pace)", check.boundSeconds))
        returnCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.returnCheckFired() }
        }
        returnCheckFired()
    }

    private func stopReturnCheck() {
        returnCheckTimer?.invalidate()
        returnCheckTimer = nil
        returnCheck = nil
        returnCheckInFlight = false
    }

    private func returnCheckFired() {
        guard !returnCheckInFlight, let check = returnCheck, let controller else { return }
        returnCheckInFlight = true
        // The stamp lives on the engine queue.
        controller.queue.async { [weak self, engine = controller.engine] in
            let rx = engine.lastControlRxUS
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.returnCheck == check, self.controller === controller else { return }
                    self.returnCheckInFlight = false
                    self.applyReturnCheck(check.verdict(lastControlRxUS: rx, nowUS: MonotonicClock.nowUS),
                                          check: check, rx: rx)
                }
            }
        }
    }

    private func applyReturnCheck(_ verdict: ReturnCheck.Verdict, check: ReturnCheck, rx: UInt64) {
        switch verdict {
        case .waiting:
            return
        case .alive:
            stopReturnCheck()
            guard flow.checkPassed() == .resume, let controller else { return }
            note(String(format: "back: session alive (Mac heard %.2f s after the return)",
                        Double(rx &- check.returnedUS) / 1_000_000))
            // The gate is still closed: this only clears the engines' own held state, nothing reaches the Mac.
            releaseHeldInput?()
            input.open(to: controller)
            input.onSent = { [weak self] kind in self?.noteSentInput(kind: kind) }
        case .dead:
            stopReturnCheck()
            note(String(format: "back: nothing from the Mac within %.2f s: rejoining behind the picture", check.boundSeconds))
            guard flow.checkTimedOut() == .dial else { return }
            startRejoin()
            // The rejoin's log line counts from the return, not from the end of the check.
            rejoinStartedAt = Date().addingTimeInterval(-Double(MonotonicClock.nowUS &- check.returnedUS) / 1_000_000)
        }
    }

    /// Touch ID passed: a rejoin waiting for it starts.
    func unlocked() {
        if flow.unlocked() == .dial { startRejoin() }
        tryAutoUnlock()
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    /// Paste text from iPhone: the phone's clipboard text becomes the Mac's, ready for ⌘V.
    // MARK: - Several screens

    /// The Mac's screens from the Host's last list; empty for an older Host. One screen = nothing new shows.
    private(set) var screens: [MacScreen] = []
    /// The overview (every screen, tap one to show it) is over the picture.
    private(set) var showsOverview = false
    /// The screen the Host shares now (its last answer or list).
    private(set) var shownScreenID: UInt32?
    /// A screen choice sent and not yet answered.
    private(set) var choosingScreenID: UInt32?
    /// After a switch: the pointer the Host placed, in the new picture's pixels, for the trackpad to carry on from.
    @ObservationIgnored var onScreenSwitched: ((Int, Int) -> Void)?
    private var overviewTimer: Timer?
    /// All Screens: a still of each screen from the Host, by screen id. Empty until the first arrives, and always with
    /// an older Host (the tile then shows as before).
    private(set) var screenSnapshots: [UInt32: UIImage] = [:]
    /// Bytes of the snapshots received since the last request (one refresh), for the log and the result.
    private(set) var snapshotBytesThisRound = 0
    /// How often the stills are asked for while All Screens shows (seconds), and their long side (pixels).
    static let snapshotInterval: TimeInterval = 3
    static let snapshotMaxSide: UInt16 = 480
    private var overviewTicks = 0
    private var restoredScreen = false
    /// The screen asked for when the session opens on the remembered screen (not the user's choice).
    private var rememberedChoiceID: UInt32?
    /// After an edge crossing (or a failed one): the pointer the Host placed on the new screen in its picture's
    /// pixels, or nil (no answer, refused). The trackpad carries on from there (`TrackpadEngine.switchEnded`).
    @ObservationIgnored var onSwitchEnded: (((x: Int, y: Int, width: Int, height: Int)?) -> Void)?
    /// Which way the last push went (-1, 0, 1 each): the slide moves the content the other way.
    private(set) var crossingDirection = (dx: 0, dy: 0)
    /// The crossing's new screen is shown: slide the old picture out and the new in (the canvas does it; visual only,
    /// it never delays the pointer). Not for a menu or overview choice.
    @ObservationIgnored var onCrossingShown: ((_ dx: Int, _ dy: Int) -> Void)?
    /// The brief label over the picture naming the screen an edge crossing went to (plan item 13).
    private(set) var crossingName: String?
    /// The crossing under way: where the pointer was sent, and when it started.
    private var crossing: (target: EdgeCrossing.Target, started: Date)?
    private var crossingTimeout: Timer?
    /// No answer this long after a crossing: the trackpad is let go again (an older Host, a lost message).
    static let crossingAnswerTimeout: TimeInterval = 3

    /// More than one screen offered: the overview, the menu indicator and the horizontal screens button show.
    var multiScreen: Bool { screens.count > 1 }
    var shownScreen: MacScreen? { screens.first { $0.id == shownScreenID } }

    /// "All Screens": the overview over the picture, its small pictures refreshed about once a second (plan
    /// decision 8). Keys still type into the Mac; taps there only choose a screen.
    func showOverview() {
        guard multiScreen, let controller else { return }
        releaseHeldInput?()
        showsOverview = true
        controller.selectDisplay(0)
        requestSnapshots(controller)
        overviewTimer?.invalidate()
        overviewTicks = 0
        overviewTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.showsOverview, let c = self.controller else { return }
                c.selectDisplay(0)
                self.overviewTicks += 1
                if self.overviewTicks % Int(Self.snapshotInterval) == 0 { self.requestSnapshots(c) }
            }
        }
    }

    /// A screen chosen from the overview or the menu: the Host shares it and puts the pointer in its middle (plan
    /// item 7). The overview stays until the Host answers; then the picture is that screen, live.
    func chooseScreen(_ id: UInt32) {
        guard multiScreen, let controller, let screen = screens.first(where: { $0.id == id }) else { return }
        if id == shownScreenID, choosingScreenID == nil {
            closeOverview()
            RememberedScreen(screen).store(mac: mac?.id ?? "")
            return
        }
        releaseHeldInput?()
        choosingScreenID = id
        note("screen choice: \(id) \(screen.name)")
        controller.selectDisplay(id, pointerAt: screen.middle)
    }

    /// The trackpad pushed the pointer to canvas (x, y) past the shown screen's edge (plan item 13). If the Mac
    /// has a screen there, the Host shares it and puts the pointer at the matching spot just inside (a drag if a
    /// button is held, so a window comes along); true. A wall: false. Held input is kept, not released.
    func pushPastEdge(x: Double, y: Double, width: Int, height: Int) -> Bool {
        guard multiScreen, !showsOverview, choosingScreenID == nil, let controller, let shown = shownScreen,
              let target = EdgeCrossing.target(from: shown, in: screens, px: x, py: y, width: width, height: height)
        else { return false }
        choosingScreenID = target.screen.id
        crossing = (target, Date())
        crossingDirection = EdgeCrossing.direction(px: x, py: y, width: width, height: height)
        // The name appears with the slide, when the Mac answers.
        note("edge crossing: \(shown.name) → \(target.screen.name) at \(target.x),\(target.y)")
        controller.selectDisplay(target.screen.id, pointerAt: (target.x, target.y))
        crossingTimeout?.invalidate()
        crossingTimeout = Timer.scheduledTimer(withTimeInterval: Self.crossingAnswerTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.crossing != nil else { return }
                self.note("edge crossing: no answer from the Mac")
                self.endCrossing(at: nil)
                self.choosingScreenID = nil
            }
        }
        return true
    }

    /// The crossing is over: the trackpad carries on, the label goes after about a second (and not before the
    /// answer, which comes with the new picture).
    private func endCrossing(at point: (x: Int, y: Int, width: Int, height: Int)?) {
        guard let c = crossing else { return }
        crossing = nil
        crossingTimeout?.invalidate()
        crossingTimeout = nil
        onSwitchEnded?(point)
        let name = crossingName
        let wait = max(0.4, 1 - Date().timeIntervalSince(c.started))
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
            guard let self, self.crossingName == name, self.crossing == nil else { return }
            self.crossingName = nil
        }
    }

    /// Ask the Host for a still of every screen. A Host that does not know the request skips it: no answer, no error.
    private func requestSnapshots(_ controller: ViewerController) {
        if snapshotBytesThisRound > 0 { note("screen snapshots: \(snapshotBytesThisRound) bytes last refresh") }
        snapshotBytesThisRound = 0
        controller.requestDisplaySnapshots(maxSide: Self.snapshotMaxSide)
    }

    /// One screen's still arrived: kept for its tile (only while the overview shows; a late one after it closed is
    /// dropped). A picture that does not decode is ignored, so the tile stays as it was.
    func snapshotArrived(_ snapshot: WireDisplaySnapshot) {
        snapshotBytesThisRound += snapshot.bytes.count
        guard showsOverview, let image = MacScreen.decodeStill(snapshot.bytes) else { return }
        screenSnapshots[snapshot.displayID] = image
    }

    private func closeOverview() {
        showsOverview = false
        overviewTimer?.invalidate()
        overviewTimer = nil
    }

    private func resetScreens() {
        closeOverview()
        endCrossing(at: nil)
        crossingName = nil
        screens = []
        screenSnapshots = [:]
        shownScreenID = nil
        choosingScreenID = nil
        rememberedChoiceID = nil
        restoredScreen = false
    }

    private func screenListArrived(_ list: [WireDisplay], controller: ViewerController) {
        let fresh = list.map(MacScreen.init)
        screens = fresh
        if choosingScreenID == nil, let shown = fresh.first(where: \.isShown) { shownScreenID = shown.id }
        // The first picture's decision belongs to the screen the Host shows (never decided again here).
        shapeDecision.listed(shownID: shownScreenID)
        guard fresh.count > 1 else { return closeOverview() }
        if SimulatorSwitches.openOverview, !restoredScreen { DispatchQueue.main.async { self.showOverview() } }
        guard !restoredScreen else { return }
        restoredScreen = true
        note("screens: " + fresh.map { "\($0.id) \($0.name) \(Int($0.frame.width))x\(Int($0.frame.height))" }
            .joined(separator: "; "))
        // Opens on the screen last used on this Mac; if it is gone, main (plan item 11).
        if let target = RememberedScreen.resolve(RememberedScreen.stored(mac: mac?.id ?? ""), in: fresh),
           target.id != shownScreenID {
            choosingScreenID = target.id
            rememberedChoiceID = target.id
            controller.selectDisplay(target.id, pointerAt: target.middle)
        }
    }

    private func screenChoiceAnswered(_ answer: WireDisplaySelection) {
        choosingScreenID = nil
        let remembered = rememberedChoiceID
        rememberedChoiceID = nil
        guard answer.succeeded else {
            note("screen choice \(answer.requestedID) not made: \(answer.status)")
            // A failed crossing: the pointer stays at the old edge; held-back ups go there (review finding 2).
            endCrossing(at: nil)
            return
        }
        shownScreenID = answer.displayID
        if let s = screens.first(where: { $0.id == answer.displayID }) {
            RememberedScreen(s).store(mac: mac?.id ?? "")
        }
        // A screen change decides the layout's shape again, from that screen's own size (the same screen keeps it).
        let reason: LayoutShapeDecision.Reason = crossing != nil ? .crossing
            : remembered == answer.displayID ? .remembered : .chosen
        if let line = shapeDecision.shown(id: answer.displayID,
                                          screenSize: screens.first(where: { $0.id == answer.displayID })?.frame.size,
                                          pictureWidth: Int(answer.pictureWidth), pictureHeight: Int(answer.pictureHeight),
                                          reason: reason) { note(line) }
        closeOverview()
        note("screen \(answer.displayID) shown, picture \(answer.pictureWidth)x\(answer.pictureHeight)")
        // The trackpad carries on from where the Host put the pointer, in the new picture's pixels.
        var placed: (x: Int, y: Int, width: Int, height: Int)?
        if answer.pointerPlaced, answer.width > 0, answer.height > 0 {
            let px = Int(answer.pointerX - answer.x) * Int(answer.pictureWidth) / Int(answer.width)
            let py = Int(answer.pointerY - answer.y) * Int(answer.pictureHeight) / Int(answer.height)
            placed = (px, py, Int(answer.pictureWidth), Int(answer.pictureHeight))
            if crossing == nil { onScreenSwitched?(px, py) }
        } else if let c = crossing, let s = screens.first(where: { $0.id == answer.displayID }) {
            let p = EdgeCrossing.pixel(c.target.x, c.target.y, on: s, width: Int(answer.pictureWidth),
                                       height: Int(answer.pictureHeight))
            placed = (p.0, p.1, Int(answer.pictureWidth), Int(answer.pictureHeight))
        }
        if let c = crossing {
            crossingName = c.target.screen.name
            onCrossingShown?(crossingDirection.dx, crossingDirection.dy)
        }
        endCrossing(at: placed)
        controller?.selectDisplay(0)
    }

    func sendClipboard(_ text: String) {
        controller?.session.sendClipboard(format: 1, data: Array(text.utf8))
    }
}
