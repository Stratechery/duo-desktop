#if DUO_JETKVM
// A computer reached only through its JetKVM (project notes, one computer with any connection, milestone 2; the owner
// 2026-11-22: "I can't approve the permission in two Macs until you add jetkvm support"). Its Add check, and
// its own screen: the JetKVM's picture with the same keys, trackpad and typing as the JetKVM view in a Mac's
// session, with no Glass Act session or picture behind it. Behind DUO_JETKVM with the rest of the JetKVM.
import Foundation
import JetKVMClient
import JetKVMProtocol
import SwiftUI
import UIKit

// MARK: - The Add check: sign in to the JetKVM, nothing more

/// The Add Computer sheet's JetKVM check. It signs in with the password typed in the sheet (the JetKVM's own
/// `/auth/login-local`) and stops there: no signaling and no video, so nobody watching the JetKVM is taken over.
/// With no password (a JetKVM in no-password mode) it only checks that the JetKVM's web port answers. Like the
/// Terminal's check (terminal review), it never starts while the app is locked, the sign-in is cancelled
/// the moment the app locks, and one that still finishes after the lock is not reported as signed in.
enum JetKVMAddCheck {
    typealias SignIn = @Sendable (_ host: String, _ password: String?) async throws -> Void

    static let lockedText = "Not checked: the app locked."

    static let signIn: SignIn = { host, password in
        guard let password, !password.isEmpty else {
            let ok = await withCheckedContinuation { c in
                TCPCheck.check(host: host, port: 80, timeout: 5) { c.resume(returning: $0) }
            }
            if !ok { throw JetKVMError.unreachable("no answer") }
            return
        }
        guard let url = URL(string: "http://\(host)\(JetKVMSignaling.loginPath)") else {
            throw JetKVMError.unreachable("bad address")
        }
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JetKVMSignaling.loginBody(password: password)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        let resp: URLResponse
        do { (_, resp) = try await URLSession(configuration: cfg).data(for: req) } catch {
            if Task.isCancelled { throw CancellationError() }
            throw JetKVMError.unreachable(error.localizedDescription)
        }
        guard let http = resp as? HTTPURLResponse else { throw JetKVMError.loginFailed(status: 0) }
        if http.statusCode == 401 || http.statusCode == 403 { throw JetKVMError.wrongPassword }
        guard (200..<300).contains(http.statusCode) else { throw JetKVMError.loginFailed(status: http.statusCode) }
    }

    /// Project notes 2: "A check that hangs must end by a deadline with a plain message."
    static var deadlineSeconds: Double = 15
    static func timedOutText(_ host: String) -> String {
        "No answer from a JetKVM at \(host) within \(Int(deadlineSeconds)) seconds. Check the address, and that this iPhone can reach it."
    }

    @MainActor static func run(name: String, host: String, password: String?,
                               signIn: @escaping SignIn = signIn) async -> (ok: Bool, text: String) {
        guard AppAccess.isOpen else { return (false, lockedText) }
        let work = Task { try await signIn(host, password) }
        let timedOut = DeadlineFlag()
        let watch = NotificationCenter.default.addObserver(forName: AppAccess.changed, object: nil, queue: nil) { n in
            if (n.object as? AppAccess.State) == .locked { work.cancel() }
        }
        defer { NotificationCenter.default.removeObserver(watch) }
        let stopped = { work.isCancelled || AppAccess.state == .locked }
        // Whichever comes first: the sign-in's answer, or the deadline (a sign-in that ignores cancelling is left
        // to finish on its own; its answer is not used).
        let finished: Result<Void, Error> = await withCheckedContinuation { c in
            let once = DeadlineFlag()
            let resume: @MainActor (Result<Void, Error>) -> Void = { r in
                guard !once.passed else { return }
                once.passed = true
                c.resume(returning: r)
            }
            Task { @MainActor in
                do { try await work.value; resume(.success(())) } catch { resume(.failure(error)) }
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(deadlineSeconds))
                guard !once.passed else { return }
                timedOut.passed = true
                work.cancel()
                resume(.failure(CancellationError()))
            }
        }
        do {
            try finished.get()
            if timedOut.passed { return (false, timedOutText(host)) }
            if stopped() { return (false, lockedText) }
            let how = (password ?? "").isEmpty ? "The JetKVM answers (no password set)." : "Signed in to the JetKVM."
            return (true, "\(how) \(name) is added.")
        } catch {
            if timedOut.passed, AppAccess.isOpen { return (false, timedOutText(host)) }
            if stopped() { return (false, lockedText) }
            switch error as? JetKVMError {
            case .wrongPassword?: return (false, "The JetKVM refused the password.")
            case .unreachable?: return (false, "Can’t reach a JetKVM at \(host). Check the address, and that this iPhone can reach it.")
            case let .loginFailed(status)?: return (false, "The JetKVM did not accept the sign-in (HTTP \(status)).")
            default: return (false, error.localizedDescription)
            }
        }
    }
}

// MARK: - The screen of a JetKVM-only computer

/// A JetKVM-only computer open: the JetKVM's picture where a Mac's picture goes, and under it the same band and
/// typing as the JetKVM view of a Mac's session (that view's `JetKVMLink` and its keys, trackpad and keyboard):
/// - a normal iPhone: the Click/column/trackpad band and our own keyboard (as `SessionScreen`, normal iPhone);
/// - the open Duo: the special keys and trackpad band over the system keyboard (as `SessionScreen`, upright).
/// Sideways (project notes, 2026-11-22: "Give the JetKVM-only screen the same sideways overlay trackpad and button
/// column a Mac session has"): the picture full screen with the session's `HorizontalControls` over it (Keyboard,
/// the click column, the trackpad, back), driving the JetKVM. The top bar upright: back, and the name bubble with
/// "JetKVM" under the name, and the session's views control when the computer has other ways in (order
/// view-selector-back). Opened from the list's JetKVM icon on any computer, with no Glass Act session. Sideways the
/// bar hides, as in a Mac's session.
struct JetKVMOnlyScreen: View {
    let entry: MacEntry
    let store: MacStore
    let leave: () -> Void
    private let link: JetKVMLink
    @State private var keyboard: TouchKeyboardModel
    @State private var keyboardInset: CGFloat = 0
    @State private var more = false
    @State private var typing = true
    /// Sideways: our own keyboard up (the Keyboard button), as `keyboardRules.up` in a Mac's session.
    @State private var wideTyping = false
    @State private var wideNow = false
    @AppStorage(TrackpadSide.storageKey) private var trackpadSide: TrackpadSide = .standard
    private let normalPhone = PhoneKind.current
    /// The bar's width (the screen's, upright), for the views control's switch-or-menu rule.
    @State private var rowWidth: CGFloat = 669
    /// The bar's narrow-first state (project notes (session-top-bar-narrow-first)).
    @State private var fit = TopBarFit()

    init(entry: MacEntry, store: MacStore, leave: @escaping () -> Void) {
        self.entry = entry
        self.store = store
        self.leave = leave
        let l = JetKVMLink.for(mac: entry.id)
        link = l
        _keyboard = State(initialValue: TouchKeyboardModel(engine: l.parts.keyboard.engine))
    }

    var body: some View {
        NavigationStack {
            SessionGeometry { proxy, wide in
                Group {
                    if wide {
                        wideLayout(proxy.size)
                    } else if normalPhone {
                        phoneLayout(proxy.size)
                    } else {
                        duoLayout(proxy.size)
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .onChange(of: proxy.size.width, initial: true) { _, w in if !wide { rowWidth = w } }
                .onChange(of: wide, initial: true) { _, now in
                    if wideNow != now { wideNow = now }
                    // Turning lets go of every held key and button and puts the keyboard away (as a Mac's session).
                    link.parts.releaseAll()
                    wideTyping = false
                }
            }
            .background { KeyboardGuideReader { keyboardInset = $0 }.ignoresSafeArea() }
            .ignoresSafeArea(.keyboard)
            .background(wideNow ? Color.black : Color(.systemBackground))
            .statusBarHidden(wideNow)
            .persistentSystemOverlays(wideNow ? .hidden : .automatic)
            .modifier(NarrowFirstBar(fit: fit, rowWidth: rowWidth, parts: WayViewSwitch.shows(current) ? 3 : 2,
                                     hidden: wideNow, enabled: !normalPhone,
                                     canWiden: WayViewSwitch.shows(current) && TopBarFit.canWiden(rowWidth: rowWidth)))
            .navigationTitle(entry.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                TopBarItem { BackToMacsButton(action: goBack) }
                ToolbarSpacer(.fixed, placement: .topBarLeading)
                TopBarItem { TopRowName(mac: entry.name, screen: "JetKVM", notice: nil, maxWidth: views.nameMaxWidth) }
                ToolbarItem(placement: .principal) { Color.clear.frame(width: 0, height: 0) }
                    .sharedBackgroundVisibility(.hidden)
                // Project notes (view-selector-back): the same views control as the computer's Screen Sharing session (only
                // with more than one way in).
                if WayViewSwitch.shows(current) {
                    ToolbarSpacer(.fixed, placement: .topBarLeading)
                    TopBarItem { views }
                }
                TopBarStandIn(width: SimulatorSwitches.topBarReserve ?? 0)
            }
        }
        .onDisappear { link.parts.releaseAll() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            link.parts.releaseAll()
        }
        .onChange(of: trackpadSide) { _, _ in link.parts.releaseAll() }
    }

    private func goBack() { letGo(); leave() }
    /// Lets go of every held key and closes the JetKVM link (back, or another way in chosen).
    private func letGo() { link.parts.releaseAll(); link.disconnect() }
    /// The computer as saved now (its ways in may have changed in its settings).
    private var current: MacEntry { store.entry(entry.id) ?? entry }
    /// The views control (project notes (view-selector-back)).
    private var views: WayViewSwitch {
        WayViewSwitch(entry: current, current: .jetkvm, fit: fit, normalPhone: normalPhone, leave: letGo)
    }

    /// Sideways, a normal iPhone and the Duo: the picture aspect-fitted to the whole screen, and over it the Mac
    /// session's sideways controls (`HorizontalControls`) on the JetKVM's own keys and trackpad.
    private func wideLayout(_ size: CGSize) -> some View {
        let insets = normalPhone ? PhoneKind.sidewaysInsets() : (leading: 0, trailing: 0)
        let layout = HorizontalLayout(size: size, side: trackpadSide, leadingInset: insets.leading,
                                      trailingInset: insets.trailing, normalPhone: normalPhone, typing: wideTyping)
        return JetKVMPanel(link: link, entry: entry, offerFor: current, leaveForOther: letGo)
            .frame(width: size.width, height: size.height)
            .background(Color.black)
            .overlay(alignment: .topLeading) {
                HorizontalControls(model: nil, parts: link.parts, keyboard: keyboard, layout: layout,
                                   typing: $wideTyping, back: goBack)
            }
            .background {
                // The responder holds only the clear click view, so our keys' clicks play and the system keyboard
                // never comes up (as a Mac's session sideways).
                MacTypingField(up: Binding(get: { wideTyping }, set: { _ in }), state: link.parts.keyboard,
                               pinned: false, macKeysBar: false, clickOnly: true)
                    .frame(width: 1, height: 1)
            }
    }

    /// A normal iPhone upright: the picture (square when it fits), the band, our own keyboard at the bottom.
    private func phoneLayout(_ size: CGSize) -> some View {
        let phone = NormalPhoneLayout(size: size, keyboardInset: NormalPhoneLayout.ownKeyboardHeight(width: size.width),
                                      keyboardGap: 0)
        return VStack(spacing: 0) {
            JetKVMPanel(link: link, entry: entry, offerFor: current, leaveForOther: letGo)
                .frame(width: phone.picture.width, height: phone.picture.height)
                .background {
                    // The responder holds only the clear click view, so our keys' clicks play and the system
                    // keyboard never comes up (as `SessionScreen` on a normal iPhone).
                    MacTypingField(up: $typing, state: link.parts.keyboard, pinned: true, macKeysBar: false,
                                   clickOnly: true)
                        .frame(width: 1, height: 1)
                }
            NormalPhoneBand(state: link.parts.keyboard, pad: link.parts.trackpad, layout: phone,
                            trackpadDimmed: false, more: $more)
                .padding(.top, NormalPhoneLayout.pad)
                .frame(width: size.width, alignment: .top)
                .background(alignment: .top) {
                    Rectangle().fill(KeyLook.panel).frame(height: size.height).ignoresSafeArea(edges: .bottom)
                }
                .zIndex(1)
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) {
            TouchKeyboardView(model: keyboard, width: size.width, sizes: .portrait)
                .frame(width: size.width, height: phone.keyboardInset, alignment: .top)
                .accessibilityIdentifier("phoneKeyboard")
        }
    }

    /// The open Duo upright: the picture full width (16:9), the special keys and trackpad, the system keyboard.
    private func duoLayout(_ size: CGSize) -> some View {
        let upright = SessionLayout.Upright(size: size, keyboardInset: SimulatorSwitches.keyboardInset ?? keyboardInset,
                                            side: trackpadSide, shape: .sixteenNine)
        let parts = link.parts
        return VStack(spacing: 0) {
            JetKVMPanel(link: link, entry: entry, offerFor: current, leaveForOther: letGo)
                .frame(width: upright.picture.width, height: upright.picture.height)
                .background {
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
        TrackpadView(engine: link.parts.trackpad)
            .frame(width: upright.trackpad.width, height: upright.trackpad.height)
            .background(KeyLook.keyFill, in: RoundedRectangle(cornerRadius: TrackpadView.cornerRadius, style: .continuous))
    }
}
#endif
