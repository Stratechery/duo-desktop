import Foundation
import UIKit

/// Simulator-only switches for scripted checks against Glass Act's test host, which a headless Simulator cannot
/// otherwise drive (no Simulator.app to unfold the Duo or tap). Compiled out of device builds.
enum SimulatorSwitches {
    #if targetEnvironment(simulator)
    private static let args = CommandLine.arguments
    private static let env = ProcessInfo.processInfo.environment

    /// `--outer-picture PATH`: the outer view draws this image over the live picture, at the picture's place and
    /// size (a lock-screen picture for screenshots; the test host cannot show the Mac's lock screen).
    static let outerPicture: UIImage? = {
        guard let i = args.firstIndex(of: "--outer-picture"), i + 1 < args.count else { return nil }
        return UIImage(contentsOfFile: args[i + 1])
    }()

    /// `--force-open-layout`: show the open-screen UI even in compact width (the folded Duo).
    static let forceOpenLayout = args.contains("--force-open-layout")

    /// `--no-app-lock`: this run skips the Touch ID lock (on by default), so scripted runs and UI tests can reach
    /// the Macs. Device builds have no such switch.
    static let noAppLock = args.contains("--no-app-lock")

    /// `--slide-slowdown N`: the crossing slide runs N times slower, so a screenshot can catch it mid-way.
    static var slideSlowdown: Double {
        guard let i = args.firstIndex(of: "--slide-slowdown"), i + 1 < args.count, let n = Double(args[i + 1]) else { return 1 }
        return max(1, n)
    }

    /// `--test-unlock-word WORD`: at launch, "Unlock Automatically" is turned on for "Test host" with this MADE-UP
    /// word (the auto-unlock proof against the test host; never a real password).
    static var testUnlockWord: String? {
        guard let i = args.firstIndex(of: "--test-unlock-word"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// `--keyboard-up`: horizontal, raise the system keyboard (with its Mac keys row) once in session.
    static let keyboardUp = args.contains("--keyboard-up")

    /// `--show-key-info`: on the Mac list, opens the key reference panel, for a screenshot.
    static let showKeyInfo = args.contains("--show-key-info")

    /// `--hold-command-shift`: once in session, taps Command and Shift (held for the next key or click, as two
    /// taps by hand would), so the held look can be screenshotted.
    static let holdCommandShift = args.contains("--hold-command-shift")

    /// `--open-app-switcher`: once in session (upright), taps the Apps key, so the app switcher's held look
    /// (Apps and Command held) can be screenshotted.
    static let openAppSwitcher = args.contains("--open-app-switcher")

    /// `--open-overview`: once the Mac's screen list shows more than one screen, open All Screens (for the
    /// snapshot proof's screenshot).
    static let openOverview = args.contains("--open-overview")

    /// `--more-on`: once in session (upright), turns "…" on, so the "more" keys can be screenshotted.
    static let moreOn = args.contains("--more-on")

    /// `--top-row-name "<Mac>|<Screen>"`: the session's top row shows this name (and this screen, with the menu
    /// indicator, when given), for screenshots of long real names the test host does not have.
    static var topRowPreview: (mac: String, screen: String?)? {
        guard let i = args.firstIndex(of: "--top-row-name"), i + 1 < args.count else { return nil }
        let parts = args[i + 1].split(separator: "|", maxSplits: 1).map(String.init)
        return (parts[0], parts.count > 1 ? parts[1] : nil)
    }

    /// `--leave-after S`: S seconds into the session, leaves it the way the Leave button does (the release-path
    /// check: does a held Command go up on a normal leave).
    static var leaveAfter: Double? {
        guard let i = args.firstIndex(of: "--leave-after"), i + 1 < args.count else { return nil }
        return Double(args[i + 1])
    }

    /// `--keyboard-inset N`: upright, lay out as if the system keyboard reached N pt above the bottom safe area
    /// (the owner's real Duo: 293, which gives the 3 x 8 grid; this simulator's keyboard is 277). Layout only; the
    /// simulator's own keyboard stays as it is, so the band ends a little above it.
    static var keyboardInset: CGFloat? {
        guard let i = args.firstIndex(of: "--keyboard-inset"), i + 1 < args.count, let v = Double(args[i + 1])
        else { return nil }
        return CGFloat(v)
    }

    /// `--add-computer WAY` (`screenSharing`, `terminal`, `jetkvm`): the list opens with Add Computer showing, Start
    /// With on WAY (pictures). The older `--add-mac` (Screen Sharing) and `--add-terminal "Name|address|user"`
    /// (Terminal, with those fields) still work. `--add-mac-address A` types A in Screen Sharing's address.
    static var addComputerWay: WayIn? {
        if let i = args.firstIndex(of: "--add-computer"), i + 1 < args.count { return WayIn(rawValue: args[i + 1]) }
        if args.contains("--add-mac") { return .screenSharing }
        if args.contains("--add-terminal") { return .terminal }
        return nil
    }
    /// `--add-fields "Name|address|user|jetkvm address"` (or `--add-terminal "Name|address|user"`): made-up fields
    /// for the Add sheet's pictures.
    static var addFields: (name: String, address: String, user: String, kvmAddress: String)? {
        guard let i = args.firstIndex(where: { $0 == "--add-fields" || $0 == "--add-terminal" }), i + 1 < args.count
        else { return nil }
        let p = args[i + 1].split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        guard p.count >= 3 else { return nil }
        return (p[0], p[1], p[2], p.count > 3 ? p[3] : "")
    }
    /// `--add-press`: Add is pressed 1.5 s after the sheet opens (pictures of the in-place result).
    static let addPress = args.contains("--add-press")
    /// `--add-way WAY` with `--mac-settings NAME`: that computer's ⓘ page opens with Add WAY showing.
    static var addWayOnSettings: WayIn? {
        guard let i = args.firstIndex(of: "--add-way"), i + 1 < args.count else { return nil }
        return WayIn(rawValue: args[i + 1])
    }
    /// `--open-computer NAME`: open that computer without Screen Sharing at launch (its terminal or JetKVM view).
    static var openComputer: String? {
        guard let i = args.firstIndex(of: "--open-computer"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    static var addMacAddress: String? {
        guard let i = args.firstIndex(of: "--add-mac-address"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// `--hold-key-look ID` (README pictures): our horizontal keyboard draws key ID (e.g. `c-g`) pressed, with its
    /// pop-up, and keeps it so. Look only; nothing is typed.
    static var holdKeyLook: String? {
        guard let i = args.firstIndex(of: "--hold-key-look"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    /// `--kb-page numbers|symbols` and `--kb-shift` (pictures): our keyboard opens on that page / with shift on.
    static var keyboardPage: TouchKeyboardLayout.Page? {
        guard let i = args.firstIndex(of: "--kb-page"), i + 1 < args.count else { return nil }
        return TouchKeyboardLayout.Page(rawValue: args[i + 1])
    }
    static let keyboardShift = args.contains("--kb-shift")

    /// `--settings-at-end` (README pictures): a Mac's settings open scrolled to the end.
    static let settingsAtEnd = args.contains("--settings-at-end")
    /// `--home-picker`: a Mac's settings open on the Home Network list (Touch ID clarity pictures).
    static let openHomePicker = args.contains("--home-picker")
    /// `--app-lock-passed`: Require Touch ID on and already passed, for pictures (the simulator has no finger).
    static let appLockPassed = args.contains("--app-lock-passed")
    /// `--unlock-method faceID|touchID|opticID|passcode`: the app names this method instead of reading the device
    /// (Face ID wording pictures; the simulator's enrolled state is not settable per run). nil: read it.
    static var unlockMethod: UnlockMethod? {
        guard let i = args.firstIndex(of: "--unlock-method"), i + 1 < args.count else { return nil }
        return UnlockMethod(rawValue: args[i + 1])
    }
    /// `--confirm-lock-off`: the Mac list opens with the turn-off warning showing (Face ID wording pictures).
    static let confirmLockOff = args.contains("--confirm-lock-off")
    /// `--lock-no-prompt`: locked at launch without the system's prompt, so the lock screen can be pictured.
    static let lockNoPrompt = args.contains("--lock-no-prompt")
    /// `--biometry-denied`: Face ID shows as turned off for the app in Settings (the simulator never asks the
    /// first-use question, so "Don't Allow" cannot be answered there; first-launch Face ID pictures).
    static let biometryDenied = args.contains("--biometry-denied")

    /// `--show-about` (README pictures): the Mac list opens with About showing.
    static let showAbout = args.contains("--show-about")

    /// `--choose-screen N` (README pictures): 4 s into the session, the Mac's screen N is chosen.
    static var chooseScreen: UInt32? {
        guard let i = args.firstIndex(of: "--choose-screen"), i + 1 < args.count else { return nil }
        return UInt32(args[i + 1])
    }

    /// `--pointer-walk "T:DX,DY,N;…"` (README pictures): T seconds into the session, N trackpad moves of DX,DY
    /// through the real trackpad engine (as `--edge-demo`), 0.05 s apart, so Follow Pointer can be shown following.
    static var pointerWalk: [(at: Double, dx: Double, dy: Double, n: Int)] {
        guard let i = args.firstIndex(of: "--pointer-walk"), i + 1 < args.count else { return [] }
        return args[i + 1].split(separator: ";").compactMap { seg in
            let ts = seg.split(separator: ":")
            let v = ts.count == 2 ? ts[1].split(separator: ",").compactMap { Double($0) } : []
            guard let t = ts.first.flatMap({ Double($0) }), v.count == 3 else { return nil }
            return (t, v[0], v[1], Int(v[2]))
        }
    }

    /// `--choose-view NAME` (a `SessionView` raw value): the session switches to that view after it opens.
    static var chooseView: SessionView? {
        guard let i = args.firstIndex(of: "--choose-view"), i + 1 < args.count else { return nil }
        return SessionView(rawValue: args[i + 1])
    }

    /// `--mac-settings NAME`: the Mac list opens on that Mac's settings, for a screenshot.
    @MainActor static var showMacSettings: String? {
        guard let i = args.firstIndex(of: "--mac-settings"), i + 1 < args.count else { return nil }
        return MacStore.shared.entries.first { $0.name == args[i + 1] }?.id
    }

    /// `DUO_TEST_SIGNIN=user:password` (set with SIMCTL_CHILD_): signs in to the test host without typing.
    static var testSignIn: (String, String)? {
        guard let v = env["DUO_TEST_SIGNIN"], let i = v.firstIndex(of: ":") else { return nil }
        return (String(v[..<i]), String(v[v.index(after: i)...]))
    }

    /// `--input-demo`: once in session, drives the keyboard and trackpad engines (not touches) through the
    /// acceptance list: "Hi!", a Command-latched key, a click, a right click, a scroll and a drag.
    @MainActor static var inputDemo: ((SessionModel) -> Void)? {
        guard args.contains("--input-demo") else { return nil }
        return { model in
            guard let controller = model.controller else { return }
            let keys = MacKeyboardEngine(sink: controller)
            let pad = TrackpadEngine(sink: controller)
            pad.modifierWrap = { keys.withModifiers($0) }
            if let g = model.grid { pad.setCanvas(width: g.width, height: g.height) }
            pad.hostPointer(x: 400, y: 400)
            func key(_ id: String, _ rows: [[MacKey]] = MacKeyboardLayout.letters) -> MacKey {
                rows.joined().first { $0.id == id }!
            }
            func tap(_ k: MacKey) { keys.keyDown(k); keys.keyUp(k) }
            let steps: [() -> Void] = [
                { keys.tapModifier(.shift); tap(key("h")) },
                { tap(key("i")) },
                { tap(key("!", MacKeyboardLayout.symbols)) },
                { keys.tapModifier(.command); tap(key("s")) },
                { pad.move(dx: 100, dy: 50, dt: 1) },
                { pad.tap(button: 0, at: .zero, time: 20) },
                { pad.move(dx: 100, dy: 0, dt: 1); pad.tap(button: 1, at: .zero, time: 30) },
                { for _ in 0..<10 { pad.scroll(dx: 0, dy: -12) } },
                { pad.beginDrag() },
                { pad.move(dx: 60, dy: 40, dt: 1) },
                { pad.move(dx: 60, dy: 40, dt: 1) },
                { pad.endDrag() },
            ]
            for (i, step) in steps.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2 + Double(i) * 0.4) {
                    model.note("input demo step \(i)")
                    step()
                }
            }
        }
    }

    /// `--screen-tour`: once in session, the shape proof (project notes): choose screen 2, choose it
    /// again, open and close All Screens, choose screen 1, choose 2 again; the log shows one decision per change.
    @MainActor static var screenTour: ((SessionModel) -> Void)? {
        guard args.contains("--screen-tour") else { return nil }
        return { model in
            let steps: [(Double, String, () -> Void)] = [
                (3, "choose screen 2", { model.chooseScreen(2) }),
                (5, "choose screen 2 again", { model.chooseScreen(2) }),
                (7, "open All Screens", { model.showOverview() }),
                (9, "close All Screens on screen 2", { model.chooseScreen(2) }),
                (11, "choose screen 1", { model.chooseScreen(1) }),
                (13, "choose screen 2", { model.chooseScreen(2) }),
            ]
            for (at, name, step) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { model.note("screen tour: \(name)"); step() }
            }
        }
    }
    // Live check on a real JetKVM (project notes). A headless simulator cannot type into
    // a field or tap, so these run the same actions the fingers would. No secret passes through an argument.

    /// `--add-kvm-password-file PATH`: the Add sheet's JetKVM Password field starts with this file's contents (read
    /// here, never logged), so Add saves it to the Keychain exactly as a typed password.
    static var addKVMPasswordFromFile: String? {
        guard let i = args.firstIndex(of: "--add-kvm-password-file"), i + 1 < args.count,
              let s = try? String(contentsOfFile: args[i + 1], encoding: .utf8) else { return nil }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// `--keychain-report NAME`: at launch, logs whether the Keychain holds a JetKVM password for the computer NAME
    /// ("yes"/"no" only), or that no such computer is in the list.
    static var keychainReport: String? {
        guard let i = args.firstIndex(of: "--keychain-report"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }
    /// `--leave-reopen A,B`: a computer open on its own screen goes back to the list A s after launch (the back
    /// button's action) and is opened again B s after launch (the list row's action).
    static var leaveReopen: (leave: Double, reopen: Double)? {
        guard let i = args.firstIndex(of: "--leave-reopen"), i + 1 < args.count else { return nil }
        let p = args[i + 1].split(separator: ",").compactMap { Double($0) }
        return p.count == 2 ? (p[0], p[1]) : nil
    }
    /// `--lock-after N`: the app locks N s after launch (as after 5 minutes away).
    static var lockAfter: Double? {
        guard let i = args.firstIndex(of: "--lock-after"), i + 1 < args.count else { return nil }
        return Double(args[i + 1])
    }
    /// `--press-remove WAY` on a computer's ⓘ page (`--mac-settings`): presses Remove for that way in 2 s after the
    /// page opens, then the alert's Remove 2 s later.
    static var pressRemove: WayIn? {
        guard let i = args.firstIndex(of: "--press-remove"), i + 1 < args.count else { return nil }
        return WayIn(rawValue: args[i + 1])
    }
    #else
    static let addKVMPasswordFromFile: String? = nil
    static let keychainReport: String? = nil
    static let leaveReopen: (leave: Double, reopen: Double)? = nil
    static let lockAfter: Double? = nil
    static let pressRemove: WayIn? = nil
    @MainActor static var screenTour: ((SessionModel) -> Void)? { nil }
    static let addComputerWay: WayIn? = nil
    static let addFields: (name: String, address: String, user: String, kvmAddress: String)? = nil
    static let addPress = false
    static let addWayOnSettings: WayIn? = nil
    static let openComputer: String? = nil
    static let openOverview = false
    static let outerPicture: UIImage? = nil
    static let addMacAddress: String? = nil
    static let showMacSettings: String? = nil
    static let chooseView: SessionView? = nil
    static let forceOpenLayout = false
    static let noAppLock = false
    static let slideSlowdown: Double = 1
    static let testUnlockWord: String? = nil
    static let testSignIn: (String, String)? = nil
    static let keyboardUp = false
    static let keyboardPage: TouchKeyboardLayout.Page? = nil
    static let keyboardShift = false
    static let showKeyInfo = false
    static let holdCommandShift = false
    static let openAppSwitcher = false
    static let moreOn = false
    static let topRowPreview: (mac: String, screen: String?)? = nil
    static let leaveAfter: Double? = nil
    static let keyboardInset: CGFloat? = nil
    static let holdKeyLook: String? = nil
    static let showAbout = false
    static let settingsAtEnd = false
    static let openHomePicker = false
    static let appLockPassed = false
    static let confirmLockOff = false
    static let lockNoPrompt = false
    static let biometryDenied = false
    static let chooseScreen: UInt32? = nil
    static let pointerWalk: [(at: Double, dx: Double, dy: Double, n: Int)] = []
    @MainActor static var inputDemo: ((SessionModel) -> Void)? { nil }
    #endif
}
