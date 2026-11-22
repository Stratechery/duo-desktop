import CryptoKit
import DuoTerminalKit
import Foundation
import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest

final class EngineTests: XCTestCase {
    final class MemoryStore: HostKeyStore, @unchecked Sendable {
        var keys: [String: String] = [:]
        func hostKey(for id: String) -> String? { keys[id] }
        func setHostKey(_ key: String, for id: String) { keys[id] = key }
    }

    /// Reviewer correction 1: key A is trusted on first use; key B for the same Mac is refused and A stays stored.
    func testChangedHostKeyIsRefusedAndTheStoredKeyStays() throws {
        let loop = EmbeddedEventLoop()
        let a = NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey()).publicKey   // made-up keys
        let b = NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey()).publicKey
        let store = MemoryStore()
        let id = sshHostKeyID(mac: "test-mac")
        let v = TOFUHostKeyValidator(store: store, id: id)

        let first = loop.makePromise(of: Void.self)
        v.validateHostKey(hostKey: a, validationCompletePromise: first)
        XCTAssertNoThrow(try first.futureResult.wait())
        XCTAssertEqual(store.keys[id], String(openSSHPublicKey: a))

        let again = loop.makePromise(of: Void.self)
        v.validateHostKey(hostKey: a, validationCompletePromise: again)
        XCTAssertNoThrow(try again.futureResult.wait())

        let changed = loop.makePromise(of: Void.self)
        v.validateHostKey(hostKey: b, validationCompletePromise: changed)
        XCTAssertThrowsError(try changed.futureResult.wait()) { XCTAssertTrue($0 is HostKeyChanged) }
        XCTAssertEqual(store.keys[id], String(openSSHPublicKey: a), "the stored key stays")
        // Separate from the Glass Act key and per port 22.
        XCTAssertEqual(id, "ssh:test-mac:22")
    }

    /// Touch ID clarity B: nothing listening on the SSH port (Remote Login off) is told apart from other failures.
    func testClosedPortIsConnectionRefused() async throws {
        let key = try PhoneKey.file(FileManager.default.temporaryDirectory.appendingPathComponent("duo-closed-\(UUID())"))
        do {
            _ = try await SSHConnection.connect(host: "127.0.0.1", port: 1, user: "made-up-user", signIn: .key(key),
                                                hostKeys: MemoryStore(), hostKeyID: "ssh:closed:1", timeout: .seconds(3))
            XCTFail("connected to a closed port")
        } catch {
            XCTAssertEqual(SSHFailureKind.of(error), .connectionRefused, "\(error)")
        }
        XCTAssertEqual(SSHFailureKind.of(SSHSignInRefused()), .signInRefused)
        XCTAssertEqual(SSHFailureKind.of(CancellationError()), .notReachable)
    }

    /// A made-up user name against this Mac's own sshd is a refused sign-in (what the owner saw as "no indication").
    func testMadeUpUserIsSignInRefusedLive() async throws {
        guard ProcessInfo.processInfo.environment["DUO_LIVE_SSH"] == "1" else { throw XCTSkip("live only") }
        let key = try PhoneKey.file(FileManager.default.temporaryDirectory.appendingPathComponent("duo-user-\(UUID())"))
        do {
            _ = try await SSHConnection.connect(host: "127.0.0.1", user: "made-up-user", signIn: .key(key),
                                                hostKeys: MemoryStore(), hostKeyID: "ssh:live-user:22")
            XCTFail("signed in as a made-up user")
        } catch {
            XCTAssertEqual(SSHFailureKind.of(error), .signInRefused, "\(error)")
        }
    }

    /// A refused host key stops the connection before sign-in, so no shell can open: a real handshake against
    /// this Mac's own sshd with a made-up stored key. Skipped when Remote Login is not reachable.
    func testRefusedHostKeyOpensNoShellLive() async throws {
        guard ProcessInfo.processInfo.environment["DUO_LIVE_SSH"] == "1" else { throw XCTSkip("live only") }
        let store = MemoryStore()
        let id = sshHostKeyID(mac: "127.0.0.1")
        let madeUp = String(openSSHPublicKey: NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey()).publicKey)
        store.keys[id] = madeUp
        let key = try PhoneKey.file(FileManager.default.temporaryDirectory.appendingPathComponent("duo-refuse-\(UUID())"))
        do {
            _ = try await SSHConnection.connect(host: "127.0.0.1", user: NSUserName(), signIn: .key(key),
                                                hostKeys: store, hostKeyID: id)
            XCTFail("connected despite a changed host key")
        } catch {
            XCTAssertTrue(error is HostKeyChanged, "\(error)")
        }
        XCTAssertEqual(store.keys[id], madeUp)
    }

    func testAuthorizedKeysAppendNeverDuplicates() {
        let line = "ecdsa-sha2-nistp256 AAAAE2VjZHNh duo-desktop"
        let once = AuthorizedKeys.appending(line, to: "ssh-ed25519 AAAAother laptop")!
        XCTAssertEqual(once, "ssh-ed25519 AAAAother laptop\n\(line)\n")
        XCTAssertNil(AuthorizedKeys.appending(line, to: once))
        XCTAssertNil(AuthorizedKeys.appending("ecdsa-sha2-nistp256 AAAAE2VjZHNh other-comment", to: once))
        XCTAssertEqual(AuthorizedKeys.appending(line, to: ""), "\(line)\n")
    }

    /// The command the password sign-in runs on the Mac, run here against a made-up home folder: makes ~/.ssh (700)
    /// and the file (600), keeps the existing line, adds the key once, and twice is still once.
    func testInstallCommandOnAFakeHome() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("duo-home-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let line = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY= duo-desktop-test"
        let cmd = try XCTUnwrap(AuthorizedKeys.installCommand(line))
        func run() throws -> String {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/zsh"); p.arguments = ["-c", cmd]
            p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            let o = Pipe(); p.standardOutput = o
            try p.run(); p.waitUntilExit()
            return String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        }
        XCTAssertEqual(try run(), "duo-key-added\n")
        let ssh = home.appendingPathComponent(".ssh"), file = ssh.appendingPathComponent("authorized_keys")
        XCTAssertEqual(try String(contentsOf: file), line + "\n")
        XCTAssertEqual(try run(), "duo-key-already-there\n")
        XCTAssertEqual(try String(contentsOf: file), line + "\n")
        let perms = { (u: URL) in (try FileManager.default.attributesOfItem(atPath: u.path)[.posixPermissions] as! NSNumber).intValue }
        XCTAssertEqual(try perms(ssh), 0o700)
        XCTAssertEqual(try perms(file), 0o600)
        // An existing file without a final line end keeps its line intact.
        try "ssh-ed25519 AAAAother laptop".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertEqual(try run(), "duo-key-added\n")
        XCTAssertEqual(try String(contentsOf: file), "ssh-ed25519 AAAAother laptop\n\(line)\n")
        XCTAssertNil(AuthorizedKeys.installCommand("ecdsa-sha2-nistp256 AAAA x'; rm -rf ~"))
    }

    func testPasteNeverPressesReturn() {
        XCTAssertEqual(PasteRule.prepare("printf 'duo-paste\\n'\n"), "printf 'duo-paste\\n'")
        XCTAssertEqual(PasteRule.prepare("a\r\n\n"), "a")
        XCTAssertEqual(PasteRule.prepare("two\nlines"), "two\nlines")
    }
}

// MARK: - Review fixes (review finding 3): the link obeys the app lock

/// A link to a closed local port fails and retries quickly, so attempts are easy to count. Held (locked), it makes
/// none; resumed (the same unlock), it tries again; refused by `mayConnect` (away), it parks; `wake()` resumes it.
final class TerminalLinkLockTests: XCTestCase {
    private func closedPortLink() throws -> TerminalLink {
        TerminalLink(target: .init(host: "127.0.0.1", port: 9, user: "nobody", hostKeyID: "lock-test"),
                     key: try PhoneKey.file(FileManager.default.temporaryDirectory
                                            .appendingPathComponent("duo-lock-test-\(UUID().uuidString).key")),
                     hostKeys: EngineTests.MemoryStore())
    }

    private func settle(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    func testHeldLinkMakesNoAttemptsUntilResumed() throws {
        let link = try closedPortLink()
        link.hold()
        link.start()
        settle(1.0)
        XCTAssertEqual(link.connectAttempts, 0, "a held link connected")
        link.resume()
        settle(1.0)
        XCTAssertGreaterThan(link.connectAttempts, 0, "the unlock did not resume it")
        // Locked again mid-retry: no more attempts.
        link.hold()
        settle(0.3)
        let atHold = link.connectAttempts
        settle(1.5)
        XCTAssertEqual(link.connectAttempts, atHold, "retried while held")
        link.stop()
    }

    func testMayConnectFalseParksAndWakeResumes() throws {
        let link = try closedPortLink()
        let gate = Gate()
        link.mayConnect = { gate.open }
        link.start()
        settle(1.0)
        XCTAssertEqual(link.connectAttempts, 0)
        gate.open = true
        link.wake()
        settle(1.0)
        XCTAssertGreaterThan(link.connectAttempts, 0)
        link.stop()
    }
}

// MARK: - Review fixes 2 (review finding 3, re-review): a lock during START-UP

/// the reviewer's focused check: suspend the connect, lock (`mayConnect` false + `hold`), release the connect. No PTY or
/// command may start, and the connection must be closed. Also the same across a stalled open (after the channel,
/// before the PTY and command).
final class TerminalLinkStartupLockTests: XCTestCase {
    final class StubShell: TerminalLinkShell, @unchecked Sendable {
        func send(_ bytes: [UInt8]) {}
        func resize(cols: Int, rows: Int) {}
    }

    /// Counts what reaches "the Mac". `openShell` asks `proceed` before the PTY and before the command, as the real
    /// one does; `stallOpen` holds it between the channel and the PTY.
    final class StubTransport: TerminalLinkTransport, @unchecked Sendable {
        private let l = NSLock()
        private var _opens = 0, _ptys = 0, _commands = 0, _closed = false
        let stallOpen: Bool
        private var stalled: CheckedContinuation<Void, Never>?
        private var closedWaiters: [CheckedContinuation<Void, Never>] = []
        init(stallOpen: Bool = false) { self.stallOpen = stallOpen }
        var opens: Int { l.withLock { _opens } }
        var ptys: Int { l.withLock { _ptys } }
        var commands: Int { l.withLock { _commands } }
        var closed: Bool { l.withLock { _closed } }
        var isStalled: Bool { l.withLock { stalled != nil } }
        func releaseOpen() { l.withLock { () -> CheckedContinuation<Void, Never>? in defer { stalled = nil }; return stalled }?.resume() }

        func openShell(pty: (cols: Int, rows: Int), command: String, onData: @escaping @Sendable ([UInt8]) -> Void,
                       proceed: @escaping @Sendable () -> Bool) async throws -> TerminalLinkShell {
            l.withLock { _opens += 1 }
            guard proceed() else { throw CancellationError() }
            if stallOpen { await withCheckedContinuation { c in l.withLock { stalled = c } } }
            guard proceed() else { throw CancellationError() }
            l.withLock { _ptys += 1 }
            guard proceed() else { throw CancellationError() }
            l.withLock { _commands += 1 }
            return StubShell()
        }
        func closeTransport() {
            let w = l.withLock { () -> [CheckedContinuation<Void, Never>] in _closed = true; defer { closedWaiters = [] }; return closedWaiters }
            w.forEach { $0.resume() }
        }
        func waitClosed() async {
            await withCheckedContinuation { c in
                let now = l.withLock { () -> Bool in if _closed { return true }; closedWaiters.append(c); return false }
                if now { c.resume() }
            }
        }
    }

    /// Holds each connect until released.
    final class SuspendedConnector: @unchecked Sendable {
        private let l = NSLock()
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var _calls = 0
        var calls: Int { l.withLock { _calls } }
        func connect() async { await withCheckedContinuation { c in l.withLock { _calls += 1; waiting.append(c) } } }
        func release() { l.withLock { () -> [CheckedContinuation<Void, Never>] in defer { waiting = [] }; return waiting }.forEach { $0.resume() } }
    }

    private func link() throws -> TerminalLink {
        TerminalLink(target: .init(host: "stub", user: "nobody", hostKeyID: "startup-lock-test"),
                     key: try PhoneKey.file(FileManager.default.temporaryDirectory
                                            .appendingPathComponent("duo-startup-lock-\(UUID().uuidString).key")),
                     hostKeys: EngineTests.MemoryStore())
    }

    private func settle(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    private func until(_ cond: () -> Bool, _ seconds: Double = 3) {
        let end = Date().addingTimeInterval(seconds)
        while !cond() && Date() < end { settle(0.02) }
    }

    func testLockDuringSuspendedConnectOpensNoPTYAndClosesIt() throws {
        let link = try link()
        let gate = Gate(); gate.open = true
        let connector = SuspendedConnector()
        let transport = StubTransport()
        link.mayConnect = { gate.open }
        link.connector = { _, _, _, _ in await connector.connect(); return transport }
        link.start()
        until { connector.calls == 1 }
        XCTAssertEqual(connector.calls, 1, "the connect never started")
        gate.open = false
        link.hold()
        connector.release()
        until { transport.closed }
        settle(0.3)
        XCTAssertEqual(transport.opens, 0, "PTY/command started after hold")
        XCTAssertEqual(transport.ptys + transport.commands, 0)
        XCTAssertTrue(transport.closed, "the connection that finished after the lock was not closed")
        XCTAssertFalse(link.isConnected)
        XCTAssertEqual(connector.calls, 1, "connected again while held")
        link.stop()
    }

    func testLockDuringStalledOpenSendsNoPTYOrCommandAndClosesIt() throws {
        let link = try link()
        let gate = Gate(); gate.open = true
        let transport = StubTransport(stallOpen: true)
        link.mayConnect = { gate.open }
        link.connector = { _, _, _, _ in transport }
        link.start()
        until { transport.isStalled }
        XCTAssertTrue(transport.isStalled, "the open never started")
        gate.open = false
        link.hold()
        XCTAssertTrue(transport.closed, "hold did not close the connection being opened")
        transport.releaseOpen()
        settle(0.3)
        XCTAssertEqual(transport.ptys, 0, "PTY requested after hold")
        XCTAssertEqual(transport.commands, 0, "shell/tmux command sent after hold")
        XCTAssertFalse(link.isConnected)
        link.stop()
    }

    func testUnlockAfterStartupLockConnectsNormally() throws {
        let link = try link()
        let gate = Gate(); gate.open = true
        let connector = SuspendedConnector()
        let first = StubTransport(), second = StubTransport()
        let which = Gate()
        link.mayConnect = { gate.open }
        link.connector = { _, _, _, _ in
            if which.open { return second }
            await connector.connect(); return first
        }
        link.start()
        until { connector.calls == 1 }
        gate.open = false
        link.hold()
        connector.release()
        until { first.closed }
        which.open = true
        gate.open = true
        link.resume()
        until { link.isConnected }
        XCTAssertTrue(link.isConnected, "the unlock did not connect")
        XCTAssertEqual(second.commands, 1)
        XCTAssertEqual(first.opens, 0)
        link.stop()
    }
}

private final class Gate: @unchecked Sendable {
    private let l = NSLock()
    private var value = false
    var open: Bool {
        get { l.withLock { value } }
        set { l.withLock { value = newValue } }
    }
}
