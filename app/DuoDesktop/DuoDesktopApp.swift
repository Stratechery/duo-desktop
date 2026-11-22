import GlassActSession
import SwiftUI

/// Duo Desktop: a Glass Act viewer for the iPhone Duo's open screen. The Mac's main display in a 16:9 frame,
/// a Mac keyboard on the left and a trackpad on the right. Built on Glass Act's GlassActViewer library.
@main
struct DuoDesktopApp: App {
    var body: some Scene {
        WindowGroup { RootView() }
    }
}

struct RootView: View {
    @State private var model = SessionModel.app
    @State private var list = MacList()
    @State private var lock = AppLock(bypass: SimulatorSwitches.noAppLock)
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var coldTried = false

    var body: some View {
        Group {
            // Apple: compact width is the outer screen, regular the open one. Never detect the screen itself.
            if sizeClass == .compact && !SimulatorSwitches.forceOpenLayout {
                // The owner 2026-11-21: "If you open it on the outer screen, the app should be centered in the middle of
                // the back screen where those annoying GUI permissions dialogues always pop up." The session's Mac
                // when there is one; otherwise the old one line.
                if model.showsSession, let grid = model.shownGrid {
                    OuterSessionView(model: model, grid: grid, list: list)
                } else if outerConnecting && list.macs.count <= 1 {
                    OuterConnectingView(name: model.mac?.name ?? "the Mac")
                } else if !list.macs.isEmpty {
                    // No session and more than one Mac: the list, never a guess (it shows connecting too).
                    OuterMacList(model: model, list: list)
                } else {
                    OuterScreenView()
                }
            } else if model.showsSession, let grid = model.shownGrid {
                // Live, or holding the last picture while it rejoins (ReturnFlow): the same screen either way, so
                // coming back from another app shows no list and no connecting screen.
                SessionScreen(model: model, grid: grid)
            } else {
                MacListScreen(model: model, list: list, lock: lock)
            }
        }
        // The lock covers everything, the outer screen included; nothing of the Macs shows behind it.
        .overlay {
            if lock.locked { LockedView(lock: lock) }
        }
        .onChange(of: lock.locked) { _, locked in
            if locked { model.releaseHeldInput?() } else { model.unlocked(); connectColdOnOuterScreen() }
        }
        .task {
            // One Touch ID (the owner): the saved Mac passwords are read with the app lock's own context.
            model.autoUnlockContext = { [lock] in lock.autoUnlockContext }
            // Review fixes (review finding 3): the Terminal and JetKVM links follow the same lock.
            lock.onAccessChange = { AppAccess.set($0) }
            AppAccess.set(lock.access)
            model.note("window on the \(sizeClass == .compact ? "outer" : "open") screen, session \(ObjectIdentifier(model).hashValue)")
            if lock.locked { await lock.unlock() }
            connectColdOnOuterScreen()
        }
        // Folding or unfolding: held input is let go; the picture keeps coming (the outer screen shows it too).
        .onChange(of: sizeClass) { _, _ in
            model.releaseHeldInput?()
            model.setVisible(true)
        }
        .onChange(of: scenePhase) { old, new in
            switch new {
            case .background:
                lock.didEnterBackground()
                model.didEnterBackground()
            case .active where old == .background || old == .inactive:
                // The lock decides first: after 5 minutes away the rejoin waits for Touch ID.
                lock.willEnterForeground()
                model.willEnterForeground(locked: lock.locked)
                if lock.locked { Task { await lock.unlock() } }
            default: break
            }
        }
        .onAppear { applyLaunchArguments() }
        .onChange(of: model.phase) { _, new in
            if new == .inSession, let demo = SimulatorSwitches.inputDemo { demo(model) }
            if new == .inSession, let tour = SimulatorSwitches.screenTour { tour(model) }
            if new == .inSession, let after = SimulatorSwitches.leaveAfter {
                DispatchQueue.main.asyncAfter(deadline: .now() + after) { model.disconnect() }
            }
        }
    }

    /// Opened cold on the outer screen with one Mac: connect to it (more than one: the list). Once per launch, after
    /// the lock. Needing a sign-in or approval leaves the outer screen's one line.
    private func connectColdOnOuterScreen() {
        guard !coldTried, sizeClass == .compact, !SimulatorSwitches.forceOpenLayout, !lock.locked,
              !CommandLine.arguments.contains("--connect"),
              let mac = LastMac.coldTarget(sessionMac: model.mac, idle: model.phase == .idle, macs: list.macs)
        else { return }
        coldTried = true
        model.connect(to: mac)
    }

    private var outerConnecting: Bool {
        switch model.phase {
        case .connecting, .reconnecting, .loadingPicture, .inSession: true
        default: false
        }
    }

    /// Scripted Simulator runs: `--connect "Test host"` connects to that list entry at launch.
    private func applyLaunchArguments() {
        if let word = SimulatorSwitches.testUnlockWord, let test = list.macs.first(where: { $0.name == "Test host" }) {
            let saved = AutoUnlockSetting.turnOn(word, macID: test.id, store: list.store, keychain: list.store.passwords)
            model.note("auto-unlock proof: Test host's made-up word \(saved ? "saved" : "NOT saved") in the Keychain (status \(MacPasswordKeychain.shared.lastSaveStatus))")
        }
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--connect"), i + 1 < args.count,
              let mac = list.macs.first(where: { $0.name == args[i + 1] }) else { return }
        model.connect(to: mac)
    }
}

/// The outer screen: one line, nothing connects here.
struct OuterScreenView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.portrait.on.rectangle.portrait")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Open your iPhone to use Duo Desktop")
                .font(.title3)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
