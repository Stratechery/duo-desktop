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
    @State private var lock = AppLock(bypass: SimulatorSwitches.noAppLock, passedForPicture: SimulatorSwitches.appLockPassed)
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var coldTried = false

    var body: some View {
        Group {
            // A normal iPhone (not a Duo, by its model identifier: `PhoneKind`): its own layout, upright and sideways;
            // never the outer screen's views. The Duo goes on exactly as before, below.
            if let computer = openComputer, !(sizeClass == .compact && !PhoneKind.current && !SimulatorSwitches.forceOpenLayout) {
                // A computer opened in Terminal or JetKVM from the list: its own screen, no Glass Act session, whether
                // or not it also has Screen Sharing. Not on the Duo's outer screen, which is for a Mac's dialogs.
                ownScreen(computer)
            } else if PhoneKind.current && !SimulatorSwitches.forceOpenLayout {
                if model.showsSession, let grid = model.shownGrid {
                    SessionScreen(model: model, grid: grid, normalPhone: true)
                } else {
                    MacListScreen(model: model, list: list, lock: lock)
                }
            } else if sizeClass == .compact && !SimulatorSwitches.forceOpenLayout {
                //  The session's Mac when there is one; otherwise the old one line.
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
            // Project notes (computers-m3) 2: the list's Screen Sharing icon starts the Glass Act session from the
            // address the check found; opening Terminal or JetKVM ends any Glass Act session or attempt first. A
            // Terminal or JetKVM screen's view switch can start it in Follow Pointer.
            ComputerNav.shared.startScreenSharing = { [model, list] e, view in
                model.connect(to: e, via: list.chosen[e.id])
                if model.mac?.id == e.id { model.openView = view }
            }
            ComputerNav.shared.endScreenSharing = { [model] in model.disconnect() }
            // A computer left the list (removed here or from another iPhone): its open connection ends.
            list.store.onGone = { [model] id in
                if model.mac?.id == id { model.disconnect() }
                if ComputerNav.shared.openID == id { ComputerNav.shared.close() }
            }
            // The list sync (plan Part A): on by default; it never starts a connection or reads a password.
            Task { await CloudComputerSync.shared.start() }
            // One Touch ID: the saved Mac passwords are read with the app lock's own context.
            model.autoUnlockContext = { [lock] in lock.autoUnlockContext }
            // The PCs' saved passwords are read with the same context (Remote Desktop milestone 3).
            RDPSignIn.appLockContext = { [lock] in MainActor.assumeIsolated { lock.autoUnlockContext } }
            // Review fixes: the Terminal and JetKVM links follow the same lock.
            lock.onAccessChange = { AppAccess.set($0) }
            AppAccess.set(lock.access)
            model.note("window on the \(sizeClass == .compact ? "outer" : "open") screen, session \(ObjectIdentifier(model).hashValue)")
            // Asked only once the scene is active, so the window is on screen first (first-launch Face ID fix).
            if !SimulatorSwitches.lockNoPrompt { await lock.autoUnlockIfDue(sceneActive: scenePhase == .active) }
            connectColdOnOuterScreen()
        }
        // Folding or unfolding: held input is let go; the picture keeps coming (the outer screen shows it too).
        .onChange(of: sizeClass) { _, _ in
            // A normal iPhone turning (a Max goes compact to regular) keeps held modifiers (SessionScreen).
            guard !PhoneKind.current else { return }
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
                // Active after only inactive (a system alert such as Face ID's own) is not a return: the lock
                // neither re-locks nor asks again (`AppLock.willEnterForeground`, `takeAutoAsk`).
                lock.willEnterForeground()
                model.willEnterForeground(locked: lock.locked)
                CloudComputerSync.shared.fetchNow()
                if !SimulatorSwitches.lockNoPrompt { Task { await lock.autoUnlockIfDue(sceneActive: true) } }
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

    /// The computer open on its own screen, if one is (`ComputerNav`).
    private var openComputer: MacEntry? {
        ComputerNav.shared.openID.flatMap { list.store.entry($0) }
    }

    @ViewBuilder private func ownScreen(_ e: MacEntry) -> some View {
        switch ComputerNav.shared.way {
        case .terminal?:
            #if DUO_TERMINAL
            TerminalOnlyScreen(entry: e, store: list.store) { ComputerNav.shared.close() }
                .id(e.id)
            #else
            EmptyView()
            #endif
        case .jetkvm?:
            #if DUO_JETKVM
            JetKVMOnlyScreen(entry: e, store: list.store) { ComputerNav.shared.close() }
                .id(e.id)
            #else
            EmptyView()
            #endif
        case .screenSharing? where e.hasRemoteDesktop:
            #if DUO_RDP
            RemoteDesktopScreen(entry: e, store: list.store) { ComputerNav.shared.close() }
                .id(e.id)
            #else
            EmptyView()
            #endif
        default:
            EmptyView()
        }
    }

    /// Opened cold on the outer screen with one Mac: connect to it (more than one: the list). Once per launch, after
    /// the lock. Needing a sign-in or approval leaves the outer screen's one line.
    private func connectColdOnOuterScreen() {
        guard !coldTried, !PhoneKind.current, sizeClass == .compact, !SimulatorSwitches.forceOpenLayout, !lock.locked,
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
        #if targetEnvironment(simulator)
        // `--rdp-demo` with `--open-computer NAME` (simulator only, milestone 2 pictures): a made-up PC of that name
        // is added if missing, so its Remote Desktop screen can be shown. Nothing connects (`SimulatorSwitches.rdpDemo`).
        if SimulatorSwitches.rdpDemo || SimulatorSwitches.rdpPrompt != nil, let name = SimulatorSwitches.openComputer,
           !list.store.computers.contains(where: { $0.name == name }) {
            var pc = MacEntry(name: name)
            pc.screenSharing = false
            pc.remoteDesktop = true
            pc.rdpUser = "someone"
            pc.set(.tailscale, "pc.example.invalid")
            list.store.add(pc)
        }
        // `--sideways` (simulator only, normal-iPhone pictures): turns the app sideways as the phone would (no
        // script can turn the simulator itself).
        if args.contains("--sideways"),
           let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight)) { _ in }
        }
        #endif
        if let name = SimulatorSwitches.openComputer, let e = list.store.computers.first(where: { $0.name == name }),
           let way = SimulatorSwitches.openWay ?? e.waysInThisBuild.first(where: { $0 != .screenSharing }) {
            ComputerNav.shared.open(e, in: way)
            if let lr = SimulatorSwitches.leaveReopen {
                DispatchQueue.main.asyncAfter(deadline: .now() + lr.leave) {
                    model.note("live check: back to the list")
                    #if DUO_JETKVM
                    JetKVMLink.for(mac: e.id).parts.releaseAll(); JetKVMLink.for(mac: e.id).disconnect()
                    #endif
                    ComputerNav.shared.close()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + lr.reopen) {
                    model.note("live check: opening it again"); ComputerNav.shared.open(e, in: way)
                }
            }
        }
        #if DUO_JETKVM && targetEnvironment(simulator)
        if let name = SimulatorSwitches.keychainReport {
            if let e = list.store.computers.first(where: { $0.name == name }) {
                let has = KeychainJetKVMPasswords.shared.password(mac: e.id) != nil
                model.note("live check: Keychain JetKVM password for \(name): \(has ? "yes" : "no")")
            } else {
                // The Keychain item is per computer id; with the computer gone, look for any JetKVM password left.
                model.note("live check: \(name) is not in the list; JetKVM passwords left in the Keychain: \(KeychainJetKVMPasswords.shared.count())")
            }
        }
        #endif
        if let after = SimulatorSwitches.lockAfter {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { model.note("live check: locking"); lock.lockNow() }
        }
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
