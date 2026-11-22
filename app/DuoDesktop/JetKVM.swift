#if DUO_JETKVM
// The JetKVM view (the owner 2026-11-21: "Native view for JetKVM."). Everything here is compiled only with DUO_JETKVM;
// the WebRTC framework is linked only then (project-jetkvm.yml). The engine is jetkvm-client (JetKVMClient).
//
// Pointer: RELATIVE moves only. A Mac can map the JetKVM's absolute pointer to a different display than the one
// the JetKVM captures (project notes: absolute moves landed on the second display), so
// our trackpad sends deltas and clicks happen wherever the Mac's pointer is.
import AVFoundation
import CoreMedia
import Foundation
import JetKVMClient
import JetKVMProtocol
import Security
import SwiftUI
import UIKit
import WebRTC

// MARK: - Settings

extension MacEntry {
    /// The JetKVM switch in the Mac's settings, off by default; entries saved before it existed read as off.
    var jetkvmOn: Bool {
        get { jetkvm ?? false }
        set { jetkvm = newValue }
    }

    /// The JetKVM's address as typed (host name or IP; a scheme or path is ignored), nil when blank.
    var jetkvmHost: String? {
        guard let raw = jetkvmAddress?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        var h = raw
        if let r = h.range(of: "://") { h = String(h[r.upperBound...]) }
        if let slash = h.firstIndex(of: "/") { h = String(h[..<slash]) }
        return h.isEmpty ? nil : h
    }
}

/// Where JetKVM passwords live. The app uses the Keychain; tests use memory.
protocol JetKVMPasswordStore: AnyObject {
    func password(mac: String) -> String?
    func setPassword(_ password: String?, mac: String)
}

/// The JetKVM password of each Mac, in the Keychain only: this device only, readable after first unlock, never
/// synchronised, never logged.
final class KeychainJetKVMPasswords: JetKVMPasswordStore {
    static let shared = KeychainJetKVMPasswords()
    private let service = (Bundle.main.bundleIdentifier ?? "duodesktop") + ".jetkvm-password"

    private func query(_ mac: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: mac]
    }

    func password(mac: String) -> String? {
        var q = query(mac)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    func setPassword(_ password: String?, mac: String) {
        SecItemDelete(query(mac) as CFDictionary)
        guard let password, !password.isEmpty else { return }
        var q = query(mac)
        q[kSecValueData as String] = Data(password.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        q[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess { SessionModel.log.error("JetKVM password not saved (Keychain status \(status))") }
    }
}

/// The settings rules, in one place for the screen and the tests.
@MainActor enum JetKVMSettings {
    static var passwords: any JetKVMPasswordStore = KeychainJetKVMPasswords.shared

    /// The switch: turning it off deletes the password (the address stays, as typed, for turning it back on).
    static func setOn(_ on: Bool, mac id: String, store: MacStore, passwords: (any JetKVMPasswordStore)? = nil) {
        store.update(id) { $0.jetkvmOn = on }
        if !on { (passwords ?? Self.passwords).setPassword(nil, mac: id) }
    }

    /// Removing a Mac deletes its JetKVM password (MacStore.remove calls this).
    static func macRemoved(_ id: String, passwords: (any JetKVMPasswordStore)? = nil) {
        (passwords ?? Self.passwords).setPassword(nil, mac: id)
    }

    /// JetKVM is offered in the view switch only with the switch on and an address set.
    static func offered(_ entry: MacEntry?) -> Bool {
        guard let entry else { return false }
        return entry.jetkvmOn && entry.jetkvmHost != nil
    }

    /// The password for a connection. Simulator only: `DUO_JETKVM_PASSWORD_FILE` names a file for the live check
    /// (the simulator build is unsigned, so it has no Keychain access group).
    static func password(mac: String) -> String? {
        #if targetEnvironment(simulator)
        if let path = ProcessInfo.processInfo.environment["DUO_JETKVM_PASSWORD_FILE"],
           let s = try? String(contentsOfFile: path, encoding: .utf8) {
            return s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        #endif
        return passwords.password(mac: mac)
    }
}

struct JetKVMSettingsSection: View {
    let store: MacStore
    let id: String
    @State private var password = ""
    @State private var hasPassword = false

    var body: some View {
        if let entry = store.entry(id) {
            Section {
                Toggle("JetKVM", isOn: Binding(get: { entry.jetkvmOn }, set: { on in
                    JetKVMSettings.setOn(on, mac: id, store: store)
                    if !on { password = ""; hasPassword = false }
                }))
                .accessibilityIdentifier("settingsJetKVM")
                if entry.jetkvmOn {
                    LabeledContent("Address") {
                        TextField("Not set", text: Binding(get: { store.entry(id)?.jetkvmAddress ?? "" }, set: { v in
                            let t = v.trimmingCharacters(in: .whitespaces)
                            store.update(id) { $0.jetkvmAddress = t.isEmpty ? nil : t }
                        }))
                        .multilineTextAlignment(.trailing)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("settingsJetKVMAddress")
                    }
                    NavigationLink("JetKVM Log") { JetKVMLogView(link: JetKVMLink.for(mac: id)) }
                        .accessibilityIdentifier("settingsJetKVMLog")
                    LabeledContent("Password") {
                        SecureField(hasPassword ? "Saved" : "Not set", text: $password)
                            .multilineTextAlignment(.trailing)
                            .textContentType(.password)
                            .onSubmit(savePassword)
                            .accessibilityIdentifier("settingsJetKVMPassword")
                    }
                }
            } footer: {
                Text(entry.jetkvmOn
                     ? "Adds JetKVM to the view switch for this Mac. The password is kept in this iPhone’s Keychain only. Opening the JetKVM view takes over from anyone else viewing this JetKVM."
                     : "Adds JetKVM to the view switch for this Mac.")
            }
            .onAppear { hasPassword = JetKVMSettings.passwords.password(mac: id) != nil }
            .onDisappear(perform: savePassword)
        }
    }

    private func savePassword() {
        guard !password.isEmpty, store.entry(id)?.jetkvmOn == true else { return }
        JetKVMSettings.passwords.setPassword(password, mac: id)
        password = ""
        hasPassword = true
    }
}

/// The last 30 lines of this Mac's JetKVM connection, with Copy (so the line can be pasted to whoever is helping).
/// No password; the address only as its host name.
struct JetKVMLogView: View {
    let link: JetKVMLink
    @State private var copied = false

    var body: some View {
        List {
            if link.log.isEmpty {
                Text("Nothing yet. Open the JetKVM view, then come back.").foregroundStyle(.secondary)
            }
            ForEach(Array(link.log.enumerated()), id: \.offset) { _, line in
                Text(line).font(.caption.monospaced()).textSelection(.enabled)
            }
        }
        .navigationTitle("JetKVM Log")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc") {
                    UIPasteboard.general.string = link.log.joined(separator: "\n")
                    copied = true
                }
                .disabled(link.log.isEmpty)
                .accessibilityIdentifier("jetkvmLogCopy")
            }
        }
    }
}

// MARK: - Keys: Mac key codes to USB HID usages

/// Mac virtual key codes (the ones our keyboard engine sends) to USB HID keyboard usages (page 7). Both tables
/// are public facts (Apple's kVK_ constants; the USB HID Usage Tables).
enum JetKVMKeys {
    static let usage: [UInt16: UInt8] = {
        var m: [UInt16: UInt8] = [
            0: 0x04, 11: 0x05, 8: 0x06, 2: 0x07, 14: 0x08, 3: 0x09, 5: 0x0A, 4: 0x0B, 34: 0x0C, 38: 0x0D,
            40: 0x0E, 37: 0x0F, 46: 0x10, 45: 0x11, 31: 0x12, 35: 0x13, 12: 0x14, 15: 0x15, 1: 0x16, 17: 0x17,
            32: 0x18, 9: 0x19, 13: 0x1A, 7: 0x1B, 16: 0x1C, 6: 0x1D,
            18: 0x1E, 19: 0x1F, 20: 0x20, 21: 0x21, 23: 0x22, 22: 0x23, 26: 0x24, 28: 0x25, 25: 0x26, 29: 0x27,
            36: 0x28, 53: 0x29, 51: 0x2A, 48: 0x2B, 49: 0x2C, 27: 0x2D, 24: 0x2E, 33: 0x2F, 30: 0x30, 42: 0x31,
            41: 0x33, 39: 0x34, 50: 0x35, 43: 0x36, 47: 0x37, 44: 0x38, 57: 0x39, 10: 0x64,
            122: 0x3A, 120: 0x3B, 99: 0x3C, 118: 0x3D, 96: 0x3E, 97: 0x3F, 98: 0x40, 100: 0x41, 101: 0x42,
            109: 0x43, 103: 0x44, 111: 0x45, 105: 0x68, 107: 0x69, 113: 0x6A,
            114: 0x49, 115: 0x4A, 116: 0x4B, 117: 0x4C, 119: 0x4D, 121: 0x4E,
            124: 0x4F, 123: 0x50, 125: 0x51, 126: 0x52,
            71: 0x53, 75: 0x54, 67: 0x55, 78: 0x56, 69: 0x57, 76: 0x58, 83: 0x59, 84: 0x5A, 85: 0x5B, 86: 0x5C,
            87: 0x5D, 88: 0x5E, 89: 0x5F, 91: 0x60, 92: 0x61, 82: 0x62, 65: 0x63, 81: 0x67,
            74: 0x7F, 72: 0x80, 73: 0x81,
        ]
        m.merge(modifier.mapValues { _ in 0 }) { a, _ in a }
        return m.filter { $0.value != 0 }
    }()

    /// Mac modifier key codes to HID modifier bits (fn has no USB HID usage and is dropped).
    static let modifier: [UInt16: HIDRPC.Modifiers] = [
        59: .leftControl, 56: .leftShift, 58: .leftOption, 55: .leftCommand,
        62: .rightControl, 60: .rightShift, 61: .rightOption, 54: .rightCommand,
    ]
}

// MARK: - Input: our engines' events to JetKVM HID

/// What the input adapter drives (the live session, or a recorder in tests).
protocol JetKVMOutput: AnyObject {
    func sendKeyboard(modifiers: HIDRPC.Modifiers, keys: [UInt8])
    func sendPointerDelta(dx: Int, dy: Int, buttons: HIDRPC.Buttons?)
    func sendScroll(dy: Int, dx: Int)
}

extension JetKVMSession: JetKVMOutput {}

/// Turns the Glass Act-style input our trackpad, keys band and system keyboard produce (Input.swift) into JetKVM
/// HID: moves become relative deltas, buttons are pressed where the Mac's pointer is, scroll points become wheel
/// steps, Mac key codes become one keyboard report (modifiers latch exactly as the engine sends them).
final class JetKVMInput: InputSink {
    weak var output: (any JetKVMOutput)?
    /// Points of scroll per wheel step.
    static let pointsPerStep = 12.0
    private var last: (x: Int, y: Int)?
    private var buttons: HIDRPC.Buttons = []
    private var modifiers: HIDRPC.Modifiers = []
    private var keys: [UInt8] = []
    private var scroll = (x: 0.0, y: 0.0)
    /// Called after a move when the engine's own pointer nears its canvas edge, so it can be put back in the middle
    /// (the Mac's pointer has no edge here; ours must not stop at one).
    var nearEdge: (() -> Void)?
    var canvas = (width: 1920, height: 1080)

    func sendInput(kind: UInt8, x: Int, y: Int, a: Int, b: Int) {
        guard AppAccess.isOpen else { return } // review fixes: no input reaches the JetKVM while the app is locked
        switch kind {
        case InputKind.move:
            if let l = last { move(dx: x - l.x, dy: y - l.y) }
            last = (x, y)
            let m = 200
            if x < m || y < m || x > canvas.width - m || y > canvas.height - m { nearEdge?() }
        case InputKind.buttonDown, InputKind.buttonUp:
            if let l = last, l.x != x || l.y != y { move(dx: x - l.x, dy: y - l.y) }
            last = (x, y)
            let bit: HIDRPC.Buttons = b == 1 ? .secondary : .primary
            if kind == InputKind.buttonDown { buttons.insert(bit) } else { buttons.remove(bit) }
            output?.sendPointerDelta(dx: 0, dy: 0, buttons: buttons)
        case InputKind.scrollPoints:
            scroll.x += Double(a); scroll.y += Double(b)
            let sy = Int(scroll.y / Self.pointsPerStep), sx = Int(scroll.x / Self.pointsPerStep)
            guard sx != 0 || sy != 0 else { return }
            scroll.x -= Double(sx) * Self.pointsPerStep; scroll.y -= Double(sy) * Self.pointsPerStep
            // Our points follow the fingers (the Mac view posts them as they are). A USB wheel is flipped by the
            // Mac when natural scrolling is on, the macOS default, so the steps go the other way to match the Mac
            // view there (measured live 2026-11-21: unflipped, fingers down moved the content up).
            output?.sendScroll(dy: max(-127, min(127, -sy)), dx: max(-127, min(127, -sx)))
        case InputKind.keyDown, InputKind.keyUp:
            key(code: UInt16(truncatingIfNeeded: x), down: kind == InputKind.keyDown)
        default:
            break
        }
    }

    /// The engine was put back at (x, y) without a move being meant: no delta for that jump.
    func rebase(x: Int, y: Int) { last = (x, y) }

    private func move(dx: Int, dy: Int) {
        guard dx != 0 || dy != 0 else { return }
        output?.sendPointerDelta(dx: dx, dy: dy, buttons: nil)
    }

    private func key(code: UInt16, down: Bool) {
        if let m = JetKVMKeys.modifier[code] {
            if down { modifiers.insert(m) } else { modifiers.remove(m) }
        } else if let u = JetKVMKeys.usage[code] {
            if down { if !keys.contains(u) && keys.count < 6 { keys.append(u) } } else { keys.removeAll { $0 == u } }
        } else {
            return
        }
        output?.sendKeyboard(modifiers: modifiers, keys: keys)
    }

    /// Everything up (view left, app in the background).
    func releaseAll() {
        if !buttons.isEmpty { buttons = []; output?.sendPointerDelta(dx: 0, dy: 0, buttons: []) }
        if !modifiers.isEmpty || !keys.isEmpty { modifiers = []; keys = []; output?.sendKeyboard(modifiers: [], keys: []) }
        last = nil
    }
}

// MARK: - The connection

/// One Mac's JetKVM connection, alive only while the JetKVM view is shown and the app is in front.
@MainActor @Observable
final class JetKVMLink {
    enum Status: Equatable {
        case idle, connecting, live, wrongPassword, unsupportedFirmware, takenOver, lost(String), notSet(String)
        /// The connect's step in plain words ("Signing in", "Starting the session", "Waiting for the picture").
        case step(String)
        /// The video connection did not form; the next attempt starts by itself in a few seconds.
        case retrying(attempt: Int, of: Int)
        /// Every attempt failed: the reason, with Try Again.
        case failed(String)
    }

    /// The owner 2026-11-21: the JetKVM's video "sometimes works and it sometimes doesn't", in its own web page too. When
    /// the video connection does not form (ICE failed, or no picture by the deadline), the attempt is torn down
    /// and the next starts by itself: up to `attempts`, `retryDelay` apart, each held to `attemptTimeout`.
    static let attempts = 3
    /// A test shortens it.
    var retryDelay: Duration = .seconds(3)
    static let attemptTimeout: TimeInterval = 12
    private var attempt = 1
    private var retryTask: Task<Void, Never>?

    /// The last 30 lines of what the JetKVM connection did, for the Mac's settings ("JetKVM Log", Copy). No
    /// password; the address appears only as its host name (an IP address as "the JetKVM").
    private(set) var log: [String] = []
    static let logLines = 30
    private var logName = "the JetKVM"

    func note(_ line: String, host: String? = nil) {
        var l = line
        if let host, !host.isEmpty { l = l.replacingOccurrences(of: host, with: logName) }
        let t = Date().formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        log.append("\(t) \(l)")
        if log.count > Self.logLines { log.removeFirst(log.count - Self.logLines) }
    }

    /// The address's host name for the log: the first label of a name, nothing of an IP address.
    static func logName(host: String) -> String {
        let bare = host.split(separator: ":").first.map(String.init) ?? host
        if bare.split(separator: ".").allSatisfy({ Int($0) != nil }) || host.contains("::") || host.hasPrefix("[") {
            return "the JetKVM"
        }
        return bare.split(separator: ".").first.map(String.init) ?? "the JetKVM"
    }

    /// The step names the library reports, in plain words.
    static func stepText(_ step: String) -> String {
        switch step {
        case "login": "Signing in"
        case "signaling", "video": "Starting the session"
        case "picture": "Waiting for the picture"
        default: "Connecting"
        }
    }

    /// Whether a failure is the video connection not forming (worth an automatic retry), not a wrong password,
    /// an unreachable address or unsupported firmware (no retry can fix those).
    static func retries(_ e: JetKVMError) -> Bool {
        switch e {
        case .webRTC, .timeout: true
        case .signaling(let m): m != "closed"
        default: false
        }
    }

    /// The reason in plain words, for the last attempt.
    static func reason(_ e: JetKVMError) -> String {
        switch e {
        case .unreachable(let m): "Cannot reach the JetKVM at this address. (\(m))"
        case .loginFailed(let s): "The JetKVM refused the sign-in (HTTP \(s))."
        case .timeout: "Connected to the JetKVM, but no picture arrived."
        case .webRTC(let m): "Connected to the JetKVM, but the video connection failed (\(m))."
        default: e.description
        }
    }
    private(set) var status: Status = .idle
    private(set) var session: JetKVMSession?
    /// The picture's size (from the first frame), for aspect-fitting.
    private(set) var pictureSize = CGSize(width: 16, height: 10)
    let input = JetKVMInput()
    /// Our keys band, trackpad and system keyboard, wired to the JetKVM instead of Glass Act.
    let parts: SessionParts
    private var task: Task<Void, Never>?
    private var watch: Task<Void, Never>?
    let macID: String

    private static var links: [String: JetKVMLink] = [:]
    static func `for`(mac: String) -> JetKVMLink {
        if let l = links[mac] { return l }
        let l = JetKVMLink(mac: mac)
        links[mac] = l
        return l
    }

    private init(mac: String) {
        macID = mac
        parts = SessionParts(sink: input)
        // A big virtual canvas, gain 1: the engine's position only makes deltas.
        let w = 20_000, h = 20_000
        parts.trackpad.setCanvas(width: w, height: h, fullWidth: w)
        input.canvas = (w, h)
        input.nearEdge = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.parts.trackpad.adopt(x: w / 2, y: h / 2)
                self.input.rebase(x: w / 2, y: h / 2)
            }
        }
        parts.trackpad.adopt(x: w / 2, y: h / 2)
        accessWatch = NotificationCenter.default.addObserver(forName: AppAccess.changed, object: nil, queue: .main) {
            [weak self] note in
            guard let state = note.object as? AppAccess.State else { return }
            MainActor.assumeIsolated { self?.accessChanged(state) }
        }
    }

    /// Review fixes (review finding 3): the connect asked for while the app was not open, run by the unlock.
    private var pending: MacEntry??
    private var accessWatch: NSObjectProtocol?
    /// Counted for the lock's focused check: saved-password reads and sessions started (counted when the start
    /// actually runs, after its last access check).
    private(set) var passwordReads = 0
    private(set) var starts = 0
    /// The saved password (a test passes a fake; nothing is read while the app is locked).
    var readPassword: (String) -> String? = { JetKVMSettings.password(mac: $0) }
    /// Starts the session (a test passes a fake that records the start and connects nowhere).
    var startSession: (JetKVMSession) async throws -> Void = { try await $0.connect(timeout: JetKVMLink.attemptTimeout) }

    /// Locked: the JetKVM is released now (no input reaches it) and reconnects on the same unlock if its view
    /// asked for it. Away: nothing new starts. Open: a deferred connect runs.
    func accessChanged(_ state: AppAccess.State) {
        switch state {
        case .locked:
            if session != nil, pending == nil { pending = lastEntry }
            drop()
            retryTask?.cancel(); retryTask = nil
            attempt = 1
            switch status {
            case .live, .connecting, .step, .retrying: status = .idle
            default: break
            }
        case .open:
            if let p = pending { pending = nil; connect(entry: p) }
        case .away: break
        }
    }
    private var lastEntry: MacEntry??

    func connect(entry: MacEntry?) {
        guard session == nil, retryTask == nil else { return }
        // Review fixes (review finding 3): no password read and no start while the app is not open.
        guard AppAccess.isOpen else { pending = .some(entry); return }
        pending = nil
        lastEntry = .some(entry)
        guard let entry, let host = entry.jetkvmHost else { status = .notSet("Set this Mac’s JetKVM address in its settings."); return }
        passwordReads += 1
        logName = Self.logName(host: host)
        let s = JetKVMSession(host: host, password: readPassword(entry.id))
        session = s
        input.output = s
        status = attempt > 1 ? .retrying(attempt: attempt, of: Self.attempts) : .connecting
        note("attempt \(attempt) of \(Self.attempts) to \(logName)")
        SessionModel.log.notice("JetKVM: connecting, attempt \(self.attempt)")
        s.trace = { [weak self] line in
            // Each key and pointer message is not worth a line; everything about the connection is.
            if line.hasPrefix("hid") || line.hasPrefix("rpc →") { return }
            DispatchQueue.main.async { self?.note(line, host: host) }
        }
        watch = Task { [weak self] in
            for await st in s.states {
                guard let self, self.session === s else { return }
                switch st {
                case .takenOver:
                    self.status = .takenOver; self.drop()
                    #if targetEnvironment(simulator)
                    self.checkReconnect(entry: entry)
                    #endif
                case .connecting(let step):
                    // The attempt's number stays in sight on a retry; the step shows on the first attempt.
                    if self.attempt == 1 { self.status = .step(Self.stepText(step)) }
                case .live:
                    self.status = .live
                    self.attempt = 1
                    self.note("live")
                    #if targetEnvironment(simulator)
                    if CommandLine.arguments.contains("--jetkvm-demo") { self.demo() }
                    self.check()
                    #endif
                case .failed(let e): self.failed(e, entry: entry)
                default: break
                }
            }
        }
        task = Task { [weak self] in
            for await f in s.frames {
                guard let self, self.session === s else { return }
                let size = CGSize(width: f.width, height: f.height)
                if size != self.pictureSize { self.pictureSize = size }
                break
            }
        }
        let start = startSession
        // Review fixes 2 (review finding 3): the start is kept so a lock (`drop`) cancels it, and it checks, right
        // before signing in and starting the session, that the app is still open and this is still the session.
        startTask = Task { [weak self] in
            guard let self, !Task.isCancelled, AppAccess.isOpen, self.session === s else { return }
            self.starts += 1
            do { try await start(s) } catch {
                guard self.session === s else { return }
                self.failed(error as? JetKVMError ?? .unreachable(error.localizedDescription), entry: entry)
            }
        }
    }
    private var startTask: Task<Void, Never>?

    /// One attempt failed: tear it down completely (the JetKVM released), then retry by itself while the video
    /// connection is what failed and attempts remain; otherwise show the reason.
    private func failed(_ e: JetKVMError, entry: MacEntry?) {
        let wasLive = status == .live
        note("attempt \(attempt) failed: \(e)", host: session?.host)
        drop()
        if !wasLive, Self.retries(e), attempt < Self.attempts {
            attempt += 1
            status = .retrying(attempt: attempt, of: Self.attempts)
            retryTask = Task { [weak self] in
                try? await Task.sleep(for: self?.retryDelay ?? .seconds(3))
                guard let self, !Task.isCancelled else { return }
                self.retryTask = nil
                self.connect(entry: entry)
            }
            return
        }
        attempt = 1
        if wasLive { show(e); return }
        switch e {
        case .wrongPassword: status = .wrongPassword
        case .unsupportedFirmware: status = .unsupportedFirmware
        default: status = .failed(Self.reason(e))
        }
        SessionModel.log.notice("JetKVM: \(String(describing: self.status), privacy: .public)")
    }

    private func show(_ e: JetKVMError) {
        switch e {
        case .wrongPassword: status = .wrongPassword
        case .unsupportedFirmware: status = .unsupportedFirmware
        default: status = .lost(e.description)
        }
        SessionModel.log.notice("JetKVM: \(String(describing: self.status), privacy: .public)")
    }

    /// Ends the session but keeps the status shown.
    var inProgress: Bool {
        switch status {
        case .connecting, .step, .retrying: true
        default: false
        }
    }

    private func drop() {
        input.releaseAll()
        parts.releaseAll()
        input.output = nil
        startTask?.cancel(); startTask = nil
        session?.disconnect()
        session = nil
        watch?.cancel(); task?.cancel()
    }

    /// Left the view or went to the background: release the JetKVM (and forget a connect waiting on the unlock).
    func disconnect() {
        pending = nil
        retryTask?.cancel(); retryTask = nil
        attempt = 1
        drop()
        switch status {
        case .live, .connecting, .step, .retrying: status = .idle
        default: break
        }
    }

    #if targetEnvironment(simulator)
    /// Simulator only, `--jetkvm-check NAME` (live checks; a headless simulator cannot be touched), through the same
    /// engines the touches use: `tap` (one-finger tap = click where the pointer is), `scroll` (two fingers down 300
    /// pt at +3 s, back up 300 pt at +11 s), `type` (Command-N at +3 s, the word "duo" through the system
    /// keyboard's typing path at +6 s, Command-W at +10 s, Command-Delete = Delete at +13 s).
    private func check() {
        guard let i = CommandLine.arguments.firstIndex(of: "--jetkvm-check"), i + 1 < CommandLine.arguments.count else { return }
        let name = CommandLine.arguments[i + 1]
        session?.trace = { line in SessionModel.log.notice("JetKVM trace: \(line, privacy: .public)") }
        SessionModel.log.notice("JetKVM check: device \(self.session?.deviceVersion ?? "?", privacy: .public)")
        let pad = parts.trackpad, engine = parts.keyboard.engine, input = input
        func at(_ t: Double, _ what: String, _ body: @escaping () -> Void) {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) { SessionModel.log.notice("JetKVM check: \(what, privacy: .public)"); body() }
        }
        func chord(_ code: Int) {   // Command + key, Mac key codes, through the HID key path
            input.sendInput(kind: InputKind.keyDown, x: 55, y: 0, a: 0, b: 0)
            input.sendInput(kind: InputKind.keyDown, x: code, y: 0, a: 0, b: 0)
            input.sendInput(kind: InputKind.keyUp, x: code, y: 0, a: 0, b: 0)
            input.sendInput(kind: InputKind.keyUp, x: 55, y: 0, a: 0, b: 0)
        }
        switch name {
        case "tap": at(3, "one-finger tap") { pad.tap(button: 0, at: .zero, time: Date().timeIntervalSinceReferenceDate) }
        case "scroll":
            at(3, "two fingers down 300 pt") { for _ in 0..<20 { pad.scroll(dx: 0, dy: 15) } }
            at(11, "two fingers up 300 pt") { for _ in 0..<20 { pad.scroll(dx: 0, dy: -15) } }
        case "type":
            at(3, "Command-N") { chord(45) }
            at(6, "typing \"duo\" (system keyboard path)") { for c in "duo" { _ = MacTyping.type(c, into: engine) } }
            at(10, "Command-W") { chord(13) }
            at(13, "Command-Delete (Delete)") { chord(51) }
        default: break
        }
    }

    /// `--jetkvm-check takeover`: once taken over, after 6 s runs the Reconnect button's own action.
    private func checkReconnect(entry: MacEntry?) {
        guard let i = CommandLine.arguments.firstIndex(of: "--jetkvm-check"), i + 1 < CommandLine.arguments.count,
              CommandLine.arguments[i + 1] == "takeover" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            SessionModel.log.notice("JetKVM check: Reconnect")
            self?.reconnect(entry: entry)
        }
    }

    /// Simulator only, `--jetkvm-demo` (live check): through our own trackpad engine and the keys band's path, the
    /// pointer moves right/down, shift is pressed and let go, the pointer moves back. The device's answers go to
    /// the log (hid ← lines; no secrets in them).
    private func demo() {
        session?.trace = { line in SessionModel.log.notice("JetKVM demo: \(line, privacy: .public)") }
        let pad = parts.trackpad
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            SessionModel.log.notice("JetKVM demo: trackpad move +20,+10 pt (slow)")
            for _ in 0..<10 { pad.move(dx: 2, dy: 1, dt: 0.1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            SessionModel.log.notice("JetKVM demo: shift down/up")
            self?.input.sendInput(kind: InputKind.keyDown, x: 56, y: 0, a: 0, b: 0)
            self?.input.sendInput(kind: InputKind.keyUp, x: 56, y: 0, a: 0, b: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
            SessionModel.log.notice("JetKVM demo: trackpad move back")
            for _ in 0..<10 { pad.move(dx: -2, dy: -1, dt: 0.1) }
        }
    }
    #endif

    func reconnect(entry: MacEntry?) {
        retryTask?.cancel(); retryTask = nil
        attempt = 1
        drop()
        status = .idle
        connect(entry: entry)
    }
}

// MARK: - The picture

/// The JetKVM's picture: our own view, an `AVSampleBufferDisplayLayer` fed with WebRTC's decoded frames
/// (VideoToolbox pixel buffers), aspect-fitted. WebRTC's own `RTCMTLVideoView` stayed black in the live runs even
/// with the track attached to a view of real size and frames arriving (2026-11-21, simulator); this path does not
/// depend on WebRTC's Metal renderer.
final class JetKVMPictureView: UIView, RTCVideoRenderer {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
    private var display: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    private var frames = 0
    private var warned = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        display.videoGravity = .resizeAspect
        backgroundColor = .black
        isUserInteractionEnabled = false
    }
    required init?(coder: NSCoder) { fatalError() }

    func setSize(_ size: CGSize) {}

    /// Called on WebRTC's decoding thread.
    func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        guard let pb = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer else {
            if !warned { warned = true; SessionModel.log.notice("JetKVM picture: frame is not a pixel buffer; not shown") }
            return
        }
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        if let a = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(a) > 0 {
            let d = unsafeBitCast(CFArrayGetValueAtIndex(a, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(d, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        let n = frames + 1
        frames = n
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let r = self.display.sampleBufferRenderer
            if r.status == .failed { r.flush() }
            r.enqueue(sample)
            if n == 1 || n % 600 == 0 {
                SessionModel.log.notice("JetKVM picture: frame \(n) shown, \(Int(frame.width))x\(Int(frame.height)), view \(Int(self.bounds.width))x\(Int(self.bounds.height))")
            }
        }
    }
}

/// The picture in SwiftUI. The track is passed in (read when the link turns live), so SwiftUI hands a changed
/// track to `updateUIView`.
struct JetKVMVideo: UIViewRepresentable {
    let track: RTCVideoTrack?

    final class Coordinator { var track: RTCVideoTrack? }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> JetKVMPictureView { JetKVMPictureView(frame: .zero) }

    func updateUIView(_ v: JetKVMPictureView, context: Context) {
        guard context.coordinator.track !== track else { return }
        context.coordinator.track?.remove(v)
        track?.add(v)
        context.coordinator.track = track
        SessionModel.log.notice("JetKVM picture: track \(track == nil ? "detached" : "attached", privacy: .public)")
    }

    static func dismantleUIView(_ v: JetKVMPictureView, coordinator: Coordinator) { coordinator.track?.remove(v) }
}

/// The JetKVM view's picture area: the video, and the state in plain words while not live.
struct JetKVMPanel: View {
    let link: JetKVMLink
    let entry: MacEntry?
    @Environment(\.scenePhase) private var phase

    var body: some View {
        ZStack {
            Color.black
            JetKVMVideo(track: link.status == .live ? link.session?.videoTrack : nil)
            if let message {
                VStack(spacing: 12) {
                    if link.inProgress { ProgressView().tint(.white) }
                    Text(message).font(.callout).foregroundStyle(.white).multilineTextAlignment(.center)
                    if showsReconnect {
                        Button(link.status == .takenOver ? "Reconnect" : "Try Again") { link.reconnect(entry: entry) }
                            .buttonStyle(.borderedProminent)
                            .accessibilityIdentifier("jetkvmReconnect")
                    }
                }
                .padding()
                .accessibilityIdentifier("jetkvmStatus")
            }
        }
        .onAppear { link.connect(entry: entry) }
        .onDisappear { link.disconnect() }
        .onChange(of: phase) { _, p in
            if p == .background { link.disconnect() } else if p == .active { link.connect(entry: entry) }
        }
    }

    private var message: String? {
        switch link.status {
        case .live: nil
        case .idle, .connecting: "Connecting to the JetKVM…"
        case .step(let s): "\(s)…"
        case .retrying(let n, let of): "Trying again (\(n) of \(of))…"
        case .failed(let why): "Could not connect to the JetKVM after \(JetKVMLink.attempts) tries.\n\(why)"
        case .wrongPassword: "The JetKVM refused the password. Check it in this Mac’s settings."
        case .unsupportedFirmware: "This JetKVM’s firmware is not supported by this version of Duo Desktop."
        case .takenOver: "Taken over by another viewer"
        case .lost(let why): "Lost the connection to the JetKVM.\n\(why)"
        case .notSet(let why): why
        }
    }

    private var showsReconnect: Bool {
        switch link.status {
        case .takenOver, .lost, .wrongPassword, .failed: true
        default: false
        }
    }
}
#endif
