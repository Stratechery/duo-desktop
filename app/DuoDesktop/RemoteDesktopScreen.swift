// A PC's Remote Desktop screen. Milestone 1: the password typed each time (saved passwords are milestone 3), the
// takeover notice before each connect, a plain first-use trust prompt, and the PC's picture where a Mac's picture goes.
// Milestone 2: the SAME controls a Mac's session has, in the same places, driving the PC through `RDPInput`: the
// trackpad, the button column, the keys and Duo Desktop's keyboard, the system keyboard as Unicode, ⌃ ⌥ ⌘ as Ctrl, Alt
// and ⊞; Whole Screen and Follow Pointer; sideways as for a Mac. Laid out as the JetKVM-only screen is (the same parts
// the Mac session uses). Milestone 3: the saved password (Remember Password, behind the app lock), so a remembered PC
// connects with no typing; the full trust prompt; plain failure words; and coming back from the background reconnects
// to the same Windows session with no prompt. Linked only with DUO_RDP.
#if DUO_RDP
import AVFoundation
import SwiftUI
import UIKit

/// The session's input engines: the Mac session's own (`SessionParts`) on an `RDPInput`.
@MainActor
final class RDPControls {
    let input = RDPInput()
    let parts: SessionParts
    let keyboard: TouchKeyboardModel

    init(screen: RDPScreen) {
        parts = SessionParts(sink: input)
        keyboard = TouchKeyboardModel(engine: parts.keyboard.engine)
        let w = Int(screen.width), h = Int(screen.height)
        input.canvas = (w, h)
        parts.setCanvas(width: w, height: h, fullWidth: w)
        parts.trackpad.adopt(x: w / 2, y: h / 2)
        let input = input
        parts.keyboard.engine.typeText = { [weak input] c in input?.type(c) }
        // Milestone 4: the band's keys send Windows shortcuts and show Ctrl, Alt, ⊞ and Ctrl Alt Del.
        parts.keyboard.engine.target = .windows
    }

    /// Lets go of every held key, modifier and button on the PC.
    func releaseAll() {
        parts.releaseAll()
        input.releaseAll()
    }
}

struct RemoteDesktopScreen: View {
    let entry: MacEntry
    let store: MacStore
    let leave: () -> Void

    enum Phase: Equatable {
        case password
        case connecting
        case live
        case ended(String?)
    }

    @State private var phase: Phase = .password
    @State private var password = ""
    @State private var takeover = false
    @State private var trustFingerprint: String?
    @State private var session: RemoteDesktopSession?
    @State private var picture = RDPPictureView()
    /// The session thread waits here for the trust answer.
    @State private var trustAnswer = TrustAnswer()
    /// Remember Password, as shown under the password field (the PC's setting; on by default).
    @State private var remember = true
    /// Said above the password field: why it is asked again (e.g. the saved one was not accepted).
    @State private var notice: String?
    /// The password this screen signed in with, in memory only while the screen is open, so coming back from the
    /// background needs no prompt even with Remember Password off. Dropped on leaving and on a wrong password.
    @State private var held = RDPHeld()
    /// The app left while the picture was live: coming back reconnects (plan §3).
    @State private var resumeOnReturn = false
    @State private var controls: RDPControls
    /// Whole Screen or Follow Pointer (a normal iPhone upright: Follow Pointer, as for a Mac).
    @State private var view: SessionView
    @State private var keyboardInset: CGFloat = 0
    @State private var more = false
    @State private var typing = true
    @State private var wideTyping = false
    @State private var wideNow = false
    @AppStorage(TrackpadSide.storageKey) private var trackpadSide: TrackpadSide = .standard
    private let normalPhone = PhoneKind.current

    init(entry: MacEntry, store: MacStore, leave: @escaping () -> Void) {
        self.entry = entry
        self.store = store
        self.leave = leave
        _controls = State(initialValue: RDPControls(screen: (store.entry(entry.id) ?? entry).rdpScreen))
        _view = State(initialValue: PhoneKind.current ? .centred : .regular)
    }

    private var current: MacEntry { store.entry(entry.id) ?? entry }
    private var live: Bool { phase == .live || SimulatorSwitches.rdpDemo }
    private var parts: SessionParts { controls.parts }
    /// Duo Desktop's keyboard works live and at the password prompt (the band and trackpad only live).
    private var keyboardOn: Bool { live || phase == .password }

    var body: some View {
        NavigationStack {
            SessionGeometry { proxy, wide in
                Group {
                    if wide { wideLayout(proxy.size) }
                    else if normalPhone { phoneLayout(proxy.size) }
                    else { duoLayout(proxy.size) }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .onChange(of: wide, initial: true) { _, now in
                    if wideNow != now { wideNow = now }
                    // Turning lets go of every held key and button and puts the keyboard away (as a Mac's session).
                    controls.releaseAll()
                    wideTyping = false
                    picture.follow = !now && view == .centred
                }
            }
            .background { KeyboardGuideReader { keyboardInset = $0 }.ignoresSafeArea() }
            .ignoresSafeArea(.keyboard)
            .background(wideNow ? Color.black : RDPTopBar.behind.colour)
            .statusBarHidden(wideNow)
            .persistentSystemOverlays(wideNow ? .hidden : .automatic)
            .modifier(RDPTopBar(entry: current, normalPhone: normalPhone, hidden: wideNow,
                                view: Binding(get: { view }, set: { choose($0) }), back: goBack))
        }
        .alert("Connect to \(entry.name)?", isPresented: $takeover) {
            Button("Connect") { connect(with: pendingPassword(), typed: pendingTyped) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(RDPTrust.takeoverText(entry.name))
        }
        .alert("Trust \(entry.name)?", isPresented: Binding(get: { trustFingerprint != nil },
                                                            set: { if !$0 { answerTrust(false) } })) {
            Button("Trust and Connect") { answerTrust(true) }
            Button("Cancel", role: .cancel) { answerTrust(false) }
        } message: {
            Text(RDPTrust.firstUseText(name: entry.name, address: hostAddress ?? "", fingerprint: trustFingerprint ?? ""))
        }
        .onAppear { wire(); start() }
        .onDisappear { controls.releaseAll(); session?.stop(); held.password = nil }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            controls.releaseAll()
        }
        // Leaving for the background (iOS stops the link) or locking: Windows keeps the session, disconnected; coming
        // back reconnects to it (plan §3).
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            leaveForNow()
        }
        .onReceive(NotificationCenter.default.publisher(for: AppAccess.changed)) { note in
            guard let st = note.object as? AppAccess.State else { return }
            if st == .locked { leaveForNow() } else if st == .open { comeBack() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            if AppAccess.isOpen { comeBack() }
        }
        .onChange(of: phase, initial: true) { _, now in
            // At the password prompt, Duo Desktop's keyboard types into the Password field and Return connects.
            // (`--rdp-demo` shows the live desktop over the password phase: its keys go to the PC, as live.)
            controls.input.prompt = now == .password && !SimulatorSwitches.rdpDemo ? { key in
                if key.apply(to: &password) { askThenConnect() }
            } : nil
        }
        .onChange(of: trackpadSide) { _, _ in controls.releaseAll() }
        .onChange(of: view) { _, new in
            controls.releaseAll()
            more = false
            picture.follow = !wideNow && new == .centred
        }
    }

    /// The pointer drawn on the picture, and Follow Pointer, from the position sent and the one the PC reports.
    private func wire() {
        let pic = picture
        picture.canvas = controls.input.canvas
        picture.follow = view == .centred
        controls.input.onPointer = { [weak pic] x, y in pic?.pointer(x: x, y: y) }
        pic.pointer(x: controls.input.canvas.width / 2, y: controls.input.canvas.height / 2)
        #if targetEnvironment(simulator)
        if SimulatorSwitches.rdpDemo { pic.showDemo() }
        if SimulatorSwitches.rdpDemo, SimulatorSwitches.keyboardUp {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { wideTyping = true }
        }
        // `--more-on` (milestone 4 pictures): the "…" page shown (normal iPhone).
        if SimulatorSwitches.rdpDemo, SimulatorSwitches.moreOn {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                more = true
                // `--fkeys-on` also: the F-keys half (normal iPhone: "…" then its own "more" key).
                if ProcessInfo.processInfo.arguments.contains("--fkeys-on") { controls.parts.keyboard.functionKeys = true }
            }
        }
        #endif
    }

    // MARK: Layouts (as JetKVMOnlyScreen and SessionScreen)

    /// The picture area: the PC's picture, and over it, while not live, the sign-in / connecting / ended panel.
    private func pictureArea() -> some View {
        ZStack {
            Color.black
            RDPPicture(view: picture)
                .opacity(live ? 1 : 0)
                .accessibilityIdentifier("rdpPicture")
            if !live { panel }
        }
        .clipped()
    }

    private func wideLayout(_ size: CGSize) -> some View {
        let insets = normalPhone ? PhoneKind.sidewaysInsets() : (leading: 0, trailing: 0)
        let layout = HorizontalLayout(size: size, side: trackpadSide, leadingInset: insets.leading,
                                      trailingInset: insets.trailing, normalPhone: normalPhone, typing: wideTyping)
        return pictureArea()
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .topLeading) {
                if live {
                    HorizontalControls(model: nil, parts: parts, keyboard: controls.keyboard, layout: layout,
                                       typing: $wideTyping, back: goBack)
                }
            }
            .background {
                MacTypingField(up: Binding(get: { wideTyping }, set: { _ in }), state: parts.keyboard,
                               pinned: false, macKeysBar: false, clickOnly: true)
                    .frame(width: 1, height: 1)
            }
    }

    private func phoneLayout(_ size: CGSize) -> some View {
        let phone = NormalPhoneLayout(size: size, keyboardInset: NormalPhoneLayout.ownKeyboardHeight(width: size.width),
                                      keyboardGap: 0)
        return VStack(spacing: 0) {
            pictureArea()
                .frame(width: phone.picture.width, height: phone.picture.height)
                .background {
                    // At every phase, as for a Mac: our own keyboard types at the prompt too (`keyboardOn`).
                    MacTypingField(up: $typing, state: parts.keyboard, pinned: true, macKeysBar: false,
                                   clickOnly: true)
                        .frame(width: 1, height: 1)
                }
            NormalPhoneBand(state: parts.keyboard, pad: parts.trackpad, layout: phone, trackpadDimmed: false,
                            more: $more)
                .allowsHitTesting(live)
                .opacity(live ? 1 : 0.5)
                .padding(.top, NormalPhoneLayout.pad)
                .frame(width: size.width, alignment: .top)
                .background(alignment: .top) {
                    Rectangle().fill(KeyLook.panel).frame(height: size.height).ignoresSafeArea(edges: .bottom)
                }
                .zIndex(1)
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) {
            TouchKeyboardView(model: controls.keyboard, width: size.width, sizes: .portrait)
                .frame(width: size.width, height: phone.keyboardInset, alignment: .top)
                .allowsHitTesting(keyboardOn)
                .opacity(keyboardOn ? 1 : 0.5)
                .accessibilityIdentifier("phoneKeyboard")
        }
    }

    private func duoLayout(_ size: CGSize) -> some View {
        let upright = SessionLayout.Upright(size: size, keyboardInset: SimulatorSwitches.keyboardInset ?? keyboardInset,
                                            side: trackpadSide, shape: .sixteenNine)
        return VStack(spacing: 0) {
            pictureArea()
                .frame(width: upright.picture.width, height: upright.picture.height)
                .background {
                    // Upright on the Duo the system keyboard stays up for the whole session, as for a Mac, from
                    // the sign-in prompt on: at the prompt it types into the Password field (`RDPInput.prompt`).
                    // Build 81 raised it only once live, so the prompt had no keyboard and the band stretched down.
                    MacTypingField(up: $typing, state: parts.keyboard, pinned: true, macKeysBar: false)
                        .frame(width: 1, height: 1)
                }
            HStack(alignment: .bottom, spacing: SessionLayout.Upright.split) {
                if trackpadSide == .left { trackpad(upright) }
                SpecialKeysView(state: parts.keyboard, pad: parts.trackpad, metrics: upright.keyMetrics,
                                side: trackpadSide, shape: .sixteenNine)
                    .frame(width: upright.keys.width, height: upright.keys.height,
                           alignment: trackpadSide == .left ? .bottomTrailing : .bottomLeading)
                if trackpadSide == .right { trackpad(upright) }
            }
            .allowsHitTesting(live)
            .opacity(live ? 1 : 0.5)
            .padding(.top, upright.spacing.pad)
            .frame(width: size.width, alignment: .top)
            .background(alignment: .top) {
                Rectangle().fill(KeyLook.panel).frame(height: size.height).ignoresSafeArea(edges: .bottom)
            }
            .padding(.top, upright.band.minY - upright.spacing.pad - upright.picture.maxY)
            .zIndex(1)
            Spacer(minLength: 0)
        }
    }

    private func trackpad(_ upright: SessionLayout.Upright) -> some View {
        TrackpadView(engine: parts.trackpad)
            .frame(width: upright.trackpad.width, height: upright.trackpad.height)
            .background(KeyLook.keyFill, in: RoundedRectangle(cornerRadius: TrackpadView.cornerRadius, style: .continuous))
    }

    @ViewBuilder private var panel: some View {
        VStack(spacing: 16) {
            switch phase {
            case .password:
                Text("Sign in to \(entry.name) as \(current.rdpUser ?? "")")
                    .font(.headline).foregroundStyle(.white).multilineTextAlignment(.center)
                if let notice {
                    Text(notice).font(.callout).foregroundStyle(.white).multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                        .accessibilityIdentifier("rdpNotice")
                }
                SecureField("Password", text: $password)
                    .textContentType(.password)
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(.secondarySystemBackground)))
                    .frame(maxWidth: 360)
                    .submitLabel(.go)
                    .onSubmit(askThenConnect)
                    // Upright, Duo Desktop's keyboard types into it (`RDPInput.prompt`), so it never takes the
                    // keyboard itself; sideways (no keyboard under the picture) a tap raises the system keyboard.
                    .allowsHitTesting(wideNow)
                    .accessibilityIdentifier("rdpPassword")
                Button("Connect", action: askThenConnect)
                    .buttonStyle(.borderedProminent)
                    .disabled(password.isEmpty)
                    .accessibilityIdentifier("rdpConnect")
                Toggle("Remember Password", isOn: $remember)
                    .disabled(!lockOn)
                    .foregroundStyle(.white)
                    .frame(maxWidth: 360)
                    .accessibilityIdentifier("rdpRemember")
                Text(lockOn ? RDPSignIn.pinRule
                     : RDPSignIn.rememberFooter(appLockOn: false, lockHint: UnlockMethod.current.turnOnRequiredHint))
                    .font(.footnote).foregroundStyle(.white.opacity(0.7)).multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Text("\(current.rdpScreen.size.label), text at \(current.rdpScreen.textSize.label)")
                    .font(.footnote).foregroundStyle(.white.opacity(0.7))
            case .connecting:
                ProgressView().tint(.white)
                Text("Connecting to \(entry.name)…").foregroundStyle(.white)
            case let .ended(why):
                Text(why ?? "Disconnected.").foregroundStyle(.white).multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                    .accessibilityIdentifier("rdpEnded")
                Button("Try Again") { start() }
                    .buttonStyle(.borderedProminent)
                OtherWaysOffer(entry: current, current: .screenSharing, onDark: true) { session?.stop() }
            case .live:
                EmptyView()
            }
        }
        .padding(24)
    }

    // MARK: Actions

    /// The view switch: Whole Screen and Follow Pointer change this screen's view; Terminal or JetKVM leave for
    /// their own screens (as `WayViewSwitch`).
    private func choose(_ v: SessionView) {
        guard v != view else { return }
        if v.way == .screenSharing { view = v; return }
        controls.releaseAll()
        session?.stop()
        ComputerNav.shared.open(current, view: v)
    }

    private var lockOn: Bool { RDPSignIn.canRemember(appLockOn: AppLock.isOn(in: .standard)) }
    private var hostAddress: String? { current.address(.tailscale) ?? current.address(.home) }

    /// Opening the screen, or Try Again: a remembered password connects with no typing; else the password field.
    private func start() {
        #if targetEnvironment(simulator)
        if let p = SimulatorSwitches.rdpPrompt { showPicturePrompt(p); return }
        #endif
        remember = lockOn && RDPSignIn.rememberOn(current)
        if let pw = held.password ?? RDPSignIn.saved(for: current, context: RDPSignIn.appLockContext()) {
            askThenConnect(password: pw, typed: false)
        } else {
            phase = .password
        }
    }

    /// The password waiting for the takeover alert's Connect (in memory only, cleared at connect).
    @State private var pending = RDPHeld()
    @State private var pendingTyped = true
    private func pendingPassword() -> String { defer { pending.password = nil }; return pending.password ?? "" }

    private func askThenConnect() { askThenConnect(password: password, typed: true) }

    private func askThenConnect(password pw: String, typed: Bool) {
        guard !pw.isEmpty else { return }
        if typed {
            // Remember Password as chosen under the field becomes the PC's setting.
            if lockOn, remember != RDPSignIn.rememberOn(current) { store.update(entry.id) { $0.rdpRememberPassword = remember } }
            if !remember { store.rdpPasswords.delete(pcID: entry.id) }
        }
        if RDPSignIn.asksTakeover(skip: current.rdpSkipTakeover == true, resuming: false) {
            pending.password = pw
            pendingTyped = typed
            takeover = true
        } else {
            connect(with: pw, typed: typed)
        }
    }

    /// The app left while live: let go of everything and leave the session (Windows keeps it, disconnected).
    private func leaveForNow() {
        guard phase == .live || phase == .connecting else { return }
        resumeOnReturn = true
        controls.releaseAll()
        session?.stop()
    }

    /// Back in front and unlocked: the same session, no prompt (no takeover notice, no password) when the password
    /// is to hand; else the password field.
    private func comeBack() {
        guard resumeOnReturn, AppAccess.isOpen else { return }
        resumeOnReturn = false
        switch RDPReturn.onReturn(wasLive: true, held: held.password,
                                  saved: { RDPSignIn.saved(for: current, context: RDPSignIn.appLockContext()) }) {
        case let .reconnect(pw): connect(with: pw, typed: false)
        case .askPassword: notice = nil; phase = .password
        case .nothing: break
        }
    }

    private func connect(with pw: String, typed: Bool) {
        // Nothing reaches the PC while the app is locked (as the JetKVM).
        guard AppAccess.isOpen, let host = hostAddress else {
            phase = .ended("Unlock the app, and check the PC's address in its settings.")
            return
        }
        guard !pw.isEmpty else { phase = .password; return }
        let e = current
        let s = RemoteDesktopSession(.init(e, host: host, password: pw))
        password = ""
        let answer = trustAnswer
        let controls = controls
        let held = held
        let keep = RDPSignIn.shouldSave(typed: typed, accepted: true, remember: typed ? remember : false,
                                        appLockOn: lockOn)
        s.onState = { [weak s] st in
            // A session this screen already left (e.g. before coming back) says nothing more.
            guard let s, session === s else { return }
            switch st {
            case .connecting: phase = .connecting
            case .live:
                phase = .live
                notice = nil
                controls.input.output = s
                held.password = pw
                // Saved only once Windows has accepted it: a wrong password is never kept.
                if keep { _ = store.rdpPasswords.save(pw, pcID: e.id) }
            case let .ended(why, kind):
                controls.releaseAll()
                controls.input.output = nil
                session = nil
                if kind == .wrongPassword {
                    // Never tried twice: the saved or held one goes, and the field asks again with the reason.
                    held.password = nil
                    if !typed { store.rdpPasswords.delete(pcID: e.id) }
                    notice = typed ? why : "Windows did not accept the saved password. Type it again. " + RDPSignIn.pinRule
                    phase = .password
                } else {
                    phase = .ended(why)
                }
            }
        }
        s.onFrame = { [picture] pb in picture.show(pb) }
        s.onPointerMoved = { [picture] x, y in
            // The PC moved the pointer itself: the trackpad carries on from there, and Follow Pointer follows it.
            controls.parts.trackpad.adopt(x: x, y: y)
            picture.pointer(x: x, y: y)
        }
        s.askTrust = { fp in
            DispatchQueue.main.async { trustFingerprint = fp }
            return answer.wait()
        }
        s.trusted = { fp in store.update(e.id) { $0.rdpCertificate = fp } }
        session = s
        phase = .connecting
        s.start()
    }

    #if targetEnvironment(simulator)
    /// `--rdp-prompt WHAT` (simulator pictures): one prompt or failure message, made-up words, nothing connected.
    private func showPicturePrompt(_ what: String) {
        let name = entry.name, port = current.rdpPortValue
        let fp = (0..<32).map { String(format: "%02X", ($0 * 37 + 11) % 256) }.joined(separator: ":")
        func failed(_ k: RDPFailure.Kind) { phase = .ended(RDPFailure.words(k, name: name, port: port)) }
        switch what {
        case "trust": phase = .connecting; trustFingerprint = fp
        case "changed": failed(.certificateChanged)
        case "wrong-password":
            notice = RDPFailure.words(.wrongPassword, name: name, port: port); phase = .password
        case "not-allowed": failed(.notAllowed)
        case "rdp-off": failed(.remoteDesktopOff)
        case "not-reachable": failed(.notReachable)
        default: phase = .password
        }
    }
    #endif

    private func answerTrust(_ ok: Bool) {
        guard trustFingerprint != nil else { return }
        trustFingerprint = nil
        trustAnswer.give(ok)
    }

    private func goBack() {
        controls.releaseAll()
        resumeOnReturn = false
        held.password = nil
        session?.stop()
        trustAnswer.give(false)
        leave()
    }
}

/// The top bar, as a Mac session's: the Duo has Apple's own bar (`DuoTitleBar`: back, the name as the title, "Remote
/// Desktop" as the subtitle) and the views switch as its one trailing item; a normal iPhone the same bar with its views
/// drop-down. Hidden sideways.
struct RDPTopBar: ViewModifier {
    /// Upright the screen paints the system background behind the bar.
    static let behind = BarBackdrop.app
    let entry: MacEntry
    let normalPhone: Bool
    let hidden: Bool
    @Binding var view: SessionView
    let back: () -> Void

    private var choices: [SessionView] { SessionView.choices(for: entry, normalPhone: normalPhone) }

    func body(content: Content) -> some View {
        // One bar for the Duo and a normal iPhone; only the views control differs.
        content
            .modifier(DuoTitleBar(title: entry.name, subtitle: "Remote Desktop", hidden: hidden, behind: Self.behind, back: back) {
                EmptyView()
            })
            .toolbar {
                // The Duo always shows its switch; a normal iPhone's drop-down only when there is a choice.
                if !normalPhone || choices.count > 1 {
                    TopBarViewsItem { ViewSwitch(view: $view, choices: choices, normalPhone: normalPhone) }
                }
                TopBarStandIn(width: SimulatorSwitches.topBarReserve ?? 0)
            }
    }
}

/// A password kept in memory only (never saved by this object), held by reference so SwiftUI does not copy it about.
final class RDPHeld {
    var password: String?
}

/// The trust prompt's answer, handed from the main thread to the waiting session thread.
final class TrustAnswer: @unchecked Sendable {
    private let sema = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var value = false
    func give(_ ok: Bool) { lock.withLock { value = ok }; sema.signal() }
    func wait() -> Bool { sema.wait(); return lock.withLock { value } }
}

/// The PC's picture: an AVSampleBufferDisplayLayer (as the JetKVM's picture) placed by `RDPFollow`: aspect fit with
/// black edges (Whole Screen), or zoomed with the pointer kept in the middle (Follow Pointer). Our pointer arrow is
/// drawn over it at the position sent (Windows sends its pointer's shape apart from the picture).
final class RDPPictureView: UIView {
    private let video = VideoView()
    private let arrow = UIImageView()
    var canvas = (width: 1920, height: 1080) { didSet { setNeedsLayout() } }
    var follow = false { didSet { if follow != oldValue { setNeedsLayout() } } }
    private var pointerAt = (x: 960, y: 540)

    private final class VideoView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var display: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        clipsToBounds = true
        video.display.videoGravity = .resize
        addSubview(video)
        let cfg = UIImage.SymbolConfiguration(pointSize: 16, weight: .regular)
        arrow.image = UIImage(systemName: "cursorarrow", withConfiguration: cfg)?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        arrow.layer.shadowColor = UIColor.black.cgColor
        arrow.layer.shadowOpacity = 1
        arrow.layer.shadowRadius = 0.5
        arrow.layer.shadowOffset = .zero
        arrow.sizeToFit()
        addSubview(arrow)
    }
    required init?(coder: NSCoder) { fatalError() }

    func pointer(x: Int, y: Int) {
        pointerAt = (x, y)
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let f = RDPFollow.pictureFrame(canvasWidth: canvas.width, canvasHeight: canvas.height, in: bounds.size,
                                       screenScale: window?.screen.scale ?? 3, follow: follow,
                                       pointer: pointerAt)
        video.frame = f
        guard f.width > 0 else { return }
        let k = f.width / CGFloat(canvas.width)
        // The arrow's tip sits about 3 pt in from its image's top-left corner.
        arrow.frame.origin = CGPoint(x: f.minX + CGFloat(pointerAt.x) * k - 3, y: f.minY + CGFloat(pointerAt.y) * k - 2)
    }

    func show(_ pb: CVPixelBuffer) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        let display = video.display
        if display.sampleBufferRenderer.status == .failed { display.sampleBufferRenderer.flush() }
        display.sampleBufferRenderer.enqueue(sample)
    }

    #if targetEnvironment(simulator)
    /// `--rdp-demo` (simulator only, screenshots): a made-up Windows desktop, so the controls can be pictured
    /// without a PC. Nothing connects.
    func showDemo() {
        let size = CGSize(width: canvas.width, height: canvas.height)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let img = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            UIColor(red: 0.0, green: 0.35, blue: 0.65, alpha: 1).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor(white: 0.12, alpha: 0.95).setFill()
            ctx.fill(CGRect(x: 0, y: size.height - 96, width: size.width, height: 96))
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 360, y: 160, width: 1200, height: 640))
            UIColor(white: 0.93, alpha: 1).setFill()
            ctx.fill(CGRect(x: 360, y: 160, width: 1200, height: 64))
            let title: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 30), .foregroundColor: UIColor.black]
            ("Untitled - Notepad" as NSString).draw(at: CGPoint(x: 384, y: 176), withAttributes: title)
            let body: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedSystemFont(ofSize: 36, weight: .regular),
                                                      .foregroundColor: UIColor.black]
            ("Typed on the phone, sent as Unicode." as NSString).draw(at: CGPoint(x: 392, y: 260), withAttributes: body)
            let start: [NSAttributedString.Key: Any] = [.font: UIFont.boldSystemFont(ofSize: 44), .foregroundColor: UIColor.white]
            ("⊞" as NSString).draw(at: CGPoint(x: size.width / 2 - 20, y: size.height - 76), withAttributes: start)
        }
        guard let cg = img.cgImage else { return }
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                                      kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        CVPixelBufferCreate(nil, canvas.width, canvas.height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let pb else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        if let c = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: canvas.width, height: canvas.height,
                             bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) {
            c.draw(cg, in: CGRect(x: 0, y: 0, width: canvas.width, height: canvas.height))
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        // Shown again after layout, so the layer has a size when the frame arrives.
        show(pb)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.show(pb) }
    }
    #endif
}

struct RDPPicture: UIViewRepresentable {
    let view: RDPPictureView
    func makeUIView(context: Context) -> RDPPictureView { view }
    func updateUIView(_ uiView: RDPPictureView, context: Context) {}
}
#endif
