import Foundation
import NIOCore

/// The terminal's link to one Mac, kept up: connects, opens the PTY running tmux (or a plain shell), and when the
/// transport closes, connects again and reattaches (M4, engine side). A refused host key or sign-in stops it; it
/// does not retry those.
public final class TerminalLink: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case idle, connecting, connected, waiting(retryIn: Double), stopped(String)
        /// Review fixes (review finding 3): held by the app lock; no connect, retry or input until it opens.
        case held
    }

    public struct Target: Sendable {
        public var host: String, port: Int, user: String, hostKeyID: String
        /// Sign in with Tailscale SSH (`none`) instead of the phone's key (terminal-only computers).
        public var tailscale: Bool
        public init(host: String, port: Int = 22, user: String, hostKeyID: String, tailscale: Bool = false) {
            self.host = host; self.port = port; self.user = user; self.hostKeyID = hostKeyID; self.tailscale = tailscale
        }
    }

    let target: Target
    let key: PhoneKey
    let hostKeys: HostKeyStore
    /// What the PTY runs; nil = the login shell the computer starts (no tmux).
    let command: String?
    public var onOutput: @Sendable ([UInt8]) -> Void = { _ in }
    public var onState: @Sendable (State) -> Void = { _ in }
    /// Touch ID clarity B: each failed attempt's error (a refused sign-in too, just before `.stopped`), so the
    /// app can say why in plain words (wrong user name, Remote Login off, not reachable, key not installed).
    public var onAttemptFailed: @Sendable (Error) -> Void = { _ in }
    /// Review fixes (review finding 3): asked before every connect and retry, and before input is sent. The app
    /// passes its lock state; false = wait (parked, no attempt) until `wake()`.
    public var mayConnect: @Sendable () -> Bool = { true }
    /// The server's sign-in banner, if it sends one (Tailscale check mode would send its link this way).
    public var onBanner: @Sendable (String) -> Void = { _ in }
    /// The server's identification line, each time a connect gets it (before the sign-in finishes).
    public var onServerLine: @Sendable (String) -> Void = { _ in }
    /// When set, the first time a sign-in succeeds the link asks the computer what it is with `uname -s`, on a separate
    /// exec channel of the same connection (no PTY), so the session on screen never sees it, and reports the output
    /// here. Asked once per link; never on a Windows server (it has no `uname`).
    public var onSystemAnswer: (@Sendable (String) -> Void)?
    private var askedSystem = false

    /// Review fixes 2 (review finding 3): how one attempt connects. The real one is SSH; tests stub it to hold a
    /// connect in flight across a lock. It must honour `attempt` (cancelled = close and throw).
    public lazy var connector: @Sendable (Target, PhoneKey, HostKeyStore, SSHConnectAttempt) async throws
        -> TerminalLinkTransport = { [weak self] t, key, hostKeys, attempt in
            let banner = self?.onBanner
            let serverLine = self?.onServerLine
            return try await SSHConnection.connect(host: t.host, port: t.port, user: t.user,
                                                   signIn: t.tailscale ? .tailscale : .key(key),
                                                   hostKeys: hostKeys, hostKeyID: t.hostKeyID, attempt: attempt,
                                                   onBanner: { banner?($0) }, onServerLine: { serverLine?($0) })
        }

    private let lock = NSLock()
    private var wanted = false
    /// Which run loop owns the link; `start` after `stop` makes a new one and the old one's work is dropped.
    private var generation = 0
    /// The connect in flight, kept so the lock can cancel it (it is not yet `connection`).
    private var pending: SSHConnectAttempt?
    private var connection: TerminalLinkTransport?
    private var shell: TerminalLinkShell?
    private var size = (cols: 80, rows: 24)
    private var attempt = 0
    public private(set) var connects = 0
    /// Every SSH connect started (counted before the TCP connect), for the lock's focused check.
    public var connectAttempts: Int { lock.withLock { attempts } }
    private var attempts = 0
    private var held = false
    private var parked: CheckedContinuation<Void, Never>?

    public init(target: Target, key: PhoneKey, hostKeys: HostKeyStore, command: String? = ShellCommand.tmuxOrShell) {
        self.target = target; self.key = key; self.hostKeys = hostKeys; self.command = command
    }

    public func start() {
        let g = lock.withLock { () -> Int? in
            if wanted { return nil }
            wanted = true; generation += 1; return generation
        }
        if let g { Task { await self.run(g) } }
    }

    public func stop() {
        let (c, a, p) = lock.withLock { () -> (TerminalLinkTransport?, SSHConnectAttempt?, CheckedContinuation<Void, Never>?) in
            wanted = false; generation += 1
            defer { parked = nil; pending = nil }
            return (connection, pending, parked)
        }
        a?.cancel()
        c?.closeTransport()
        p?.resume()
        onState(.idle)
    }

    /// The app locked: close the link now and make no connect, retry or input until `resume()`.
    public func hold() {
        let (c, a) = lock.withLock { () -> (TerminalLinkTransport?, SSHConnectAttempt?) in
            held = true; return (connection, pending)
        }
        a?.cancel() // a connect still in flight (review fixes 2)
        c?.closeTransport()
    }

    /// The same app unlock that opened the app: reconnect (and reattach) if the link is wanted.
    public func resume() {
        lock.withLock { held = false }
        wake()
    }

    /// `mayConnect` may have turned true: a parked link tries again now.
    public func wake() {
        let p = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { parked = nil }; return parked }
        p?.resume()
    }

    private var open: Bool { !lock.withLock { held } && mayConnect() }

    public func send(_ bytes: [UInt8]) {
        guard open else { return } // nothing typed reaches the Mac while the app is locked
        lock.withLock { shell }?.send(bytes)
    }

    public func resize(cols: Int, rows: Int) {
        let s = lock.withLock { () -> TerminalLinkShell? in size = (cols, rows); return shell }
        s?.resize(cols: cols, rows: rows)
    }

    /// The test switch (reviewer correction 3): drops the SSH transport as a lost link would; the link reconnects.
    public func dropTransportForTest() { lock.withLock { connection }?.closeTransport() }

    public var isConnected: Bool { lock.withLock { shell != nil } }

    /// Still this run's link, wanted, not held, and the app open: the check made right before every step that
    /// reaches the Mac (review fixes 2).
    private func mayProceed(_ g: Int, _ a: SSHConnectAttempt? = nil) -> Bool {
        let mine = lock.withLock { wanted && generation == g && !held }
        return mine && a?.isCancelled != true && mayConnect()
    }

    private func owns(_ g: Int) -> Bool { lock.withLock { wanted && generation == g } }

    private func run(_ g: Int) async {
        while owns(g) {
            if !open {
                onState(.held)
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    let now = lock.withLock { () -> Bool in
                        if !wanted || generation != g || (!held && mayConnect()) { return true }
                        parked = c; return false
                    }
                    if now { c.resume() }
                }
                continue
            }
            let a = SSHConnectAttempt()
            let go = lock.withLock { () -> Bool in
                guard wanted, generation == g, !held else { return false }
                pending = a; attempts += 1; return true
            }
            guard go else { continue }
            onState(.connecting)
            do {
                let c = try await connector(target, key, hostKeys, a)
                // Kept at once, so a lock from here on closes it; then checked before anything is opened.
                let kept = lock.withLock { () -> Bool in
                    if pending === a { pending = nil }
                    guard wanted, generation == g, !held, !a.isCancelled else { return false }
                    connection = c; return true
                }
                guard kept, mayProceed(g, a) else {
                    c.closeTransport()
                    lock.withLock { if connection === c { connection = nil } }
                    continue
                }
                let sz = lock.withLock { size }
                let out = onOutput
                // 4: no tmux line ever goes to a Windows PC. Its server said so in its first line, so the PTY gets the
                // PC's own shell (the SSH `shell` request), whatever was asked.
                let cmd = SSHServerLine.isWindows(c.serverLine) ? nil : command
                let sh = try await c.openShell(pty: sz, command: cmd, onData: { out($0) },
                                               proceed: { [weak self] in self?.mayProceed(g, a) ?? false })
                let live = lock.withLock { () -> Bool in
                    guard connection === c, wanted, generation == g, !held else { return false }
                    shell = sh; attempt = 0; connects += 1; return true
                }
                // Locked while it was opening: close at once; the loop then parks.
                if live && mayConnect() {
                    onState(.connected)
                    askSystem(c, g, a)
                } else { c.closeTransport() }
                await c.waitClosed()
                lock.withLock { if connection === c { connection = nil; shell = nil } }
            } catch let e as HostKeyChanged {
                lock.withLock { if pending === a { pending = nil } }
                guard owns(g) else { break }
                lock.withLock { wanted = false }
                onState(.stopped(e.description)); return
            } catch let e as SSHSignInRefused where !a.isCancelled {
                lock.withLock { if pending === a { pending = nil } }
                guard owns(g) else { break }
                lock.withLock { wanted = false }
                onAttemptFailed(e)
                onState(.stopped(target.tailscale
                    ? "Tailscale refused “\(target.user)” for this iPhone."
                    : "The Mac did not accept this phone's key. Add it in the Mac's settings.")); return
            } catch {
                lock.withLock { if pending === a { pending = nil } }
                // Cancelled by the lock: no wait, the loop parks at once.
                if a.isCancelled || !mayProceed(g) { continue }
                if owns(g) { onAttemptFailed(error) }
            }
            guard owns(g) else { break }
            let wait = lock.withLock { () -> Double in attempt += 1; return min(0.25 * pow(2, Double(attempt - 1)), 8) }
            onState(.waiting(retryIn: wait))
            try? await Task.sleep(nanoseconds: UInt64(wait * 1e9))
        }
    }
}

extension TerminalLink {
    /// The one `uname -s` (see `onSystemAnswer`), in its own task so the session is not held up by it.
    fileprivate func askSystem(_ c: TerminalLinkTransport, _ g: Int, _ a: SSHConnectAttempt) {
        guard let report = onSystemAnswer, !SSHServerLine.isWindows(c.serverLine) else { return }
        let first = lock.withLock { () -> Bool in defer { askedSystem = true }; return !askedSystem }
        guard first else { return }
        Task { [weak self] in
            guard let out = try? await c.runQuietly("uname -s", proceed: { self?.mayProceed(g, a) ?? false }) else {
                self?.lock.withLock { self?.askedSystem = false } // not answered: ask again at the next sign-in
                return
            }
            report(out)
        }
    }
}

/// Review fixes 2: what `TerminalLink` needs of one connection, so a test can hold a connect or an open across a lock.
/// `proceed` is asked before each step that reaches the Mac (channel, PTY, command).
public protocol TerminalLinkTransport: AnyObject, Sendable {
    func openShell(pty: (cols: Int, rows: Int), command: String?, onData: @escaping @Sendable ([UInt8]) -> Void,
                   proceed: @escaping @Sendable () -> Bool) async throws -> TerminalLinkShell
    func closeTransport()
    func waitClosed() async
    /// The server's identification line, when known (`SSHServerLine`).
    var serverLine: String? { get }
    /// Runs one command on its own exec channel (no PTY) and returns what it printed.
    func runQuietly(_ command: String, proceed: @escaping @Sendable () -> Bool) async throws -> String
}

public extension TerminalLinkTransport {
    var serverLine: String? { nil }
    func runQuietly(_ command: String, proceed: @escaping @Sendable () -> Bool) async throws -> String {
        throw CancellationError()
    }
}

public protocol TerminalLinkShell: AnyObject, Sendable {
    func send(_ bytes: [UInt8])
    func resize(cols: Int, rows: Int)
}

extension SSHShell: TerminalLinkShell {}

extension SSHConnection: TerminalLinkTransport {
    public func openShell(pty: (cols: Int, rows: Int), command: String?, onData: @escaping @Sendable ([UInt8]) -> Void,
                          proceed: @escaping @Sendable () -> Bool) async throws -> TerminalLinkShell {
        try await open(pty: pty, command: command, onData: onData, proceed: proceed)
    }
    public func waitClosed() async { try? await closed.get() }
    public func runQuietly(_ command: String, proceed: @escaping @Sendable () -> Bool) async throws -> String {
        let box = OutputBox()
        let ch = try await open(pty: nil, command: command, onData: { box.add($0) }, proceed: proceed)
        try await ch.closed.get()
        return String(decoding: box.bytes, as: UTF8.self)
    }
}
