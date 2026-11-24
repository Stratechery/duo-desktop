import XCTest
import NIOCore
import NIOEmbedded
import CryptoKit
@testable import DuoTerminalKit

/// The server's first line tells a Windows PC, and no tmux line reaches one.
final class ServerLineTests: XCTestCase {
    func testWindowsServerLineIsAPC() {
        XCTAssertTrue(SSHServerLine.isWindows("SSH-2.0-OpenSSH_for_Windows_9.5"))
        XCTAssertFalse(SSHServerLine.isWindows("SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5"))
        XCTAssertFalse(SSHServerLine.isWindows("SSH-2.0-OpenSSH_9.8"))
        XCTAssertFalse(SSHServerLine.isWindows("SSH-2.0-Tailscale"))
        XCTAssertFalse(SSHServerLine.isWindows(nil))
    }

    func testFindsTheLineAfterOtherLinesAndOnlyWhenWhole() {
        XCTAssertNil(SSHServerLine.find(in: Array("SSH-2.0-OpenSSH_for_Win".utf8)))
        XCTAssertEqual(SSHServerLine.find(in: Array("hello\r\nSSH-2.0-OpenSSH_for_Windows_9.5\r\n\0\0".utf8)),
                       "SSH-2.0-OpenSSH_for_Windows_9.5")
    }

    /// The reader passes every byte on unchanged, in two pieces, and reports the line once.
    func testReaderPassesBytesThroughAndReportsOnce() throws {
        final class Seen: @unchecked Sendable { var lines: [String] = [] }
        let seen = Seen()
        let ch = EmbeddedChannel(handler: ServerLineReader { seen.lines.append($0) })
        let a = Array("SSH-2.0-OpenSSH_for_".utf8), b = Array("Windows_9.5\r\nrest".utf8)
        try ch.writeInbound(ByteBuffer(bytes: a))
        try ch.writeInbound(ByteBuffer(bytes: b))
        try ch.writeInbound(ByteBuffer(bytes: Array("SSH-2.0-again\r\n".utf8)))
        var out: [UInt8] = []
        while let buf: ByteBuffer = try ch.readInbound() { out += buf.readableBytesView }
        XCTAssertEqual(out, a + b + Array("SSH-2.0-again\r\n".utf8))
        XCTAssertEqual(seen.lines, ["SSH-2.0-OpenSSH_for_Windows_9.5"])
    }

    // MARK: no tmux to a PC

    final class Shell: TerminalLinkShell, @unchecked Sendable {
        func send(_ bytes: [UInt8]) {}
        func resize(cols: Int, rows: Int) {}
    }

    final class Transport: TerminalLinkTransport, @unchecked Sendable {
        let serverLine: String?
        private let l = NSLock()
        private var _commands: [String?] = []
        private var waiters: [CheckedContinuation<Void, Never>] = []
        init(serverLine: String?) { self.serverLine = serverLine }
        var commands: [String?] { l.withLock { _commands } }
        func openShell(pty: (cols: Int, rows: Int), command: String?, onData: @escaping @Sendable ([UInt8]) -> Void,
                       proceed: @escaping @Sendable () -> Bool) async throws -> TerminalLinkShell {
            l.withLock { _commands.append(command) }
            return Shell()
        }
        func closeTransport() { l.withLock { () -> [CheckedContinuation<Void, Never>] in defer { waiters = [] }; return waiters }.forEach { $0.resume() } }
        func waitClosed() async { await withCheckedContinuation { c in l.withLock { waiters.append(c) } } }
        private var _quiet: [String] = []
        var quiet: [String] { l.withLock { _quiet } }
        var answer = "Linux\n"
        func runQuietly(_ command: String, proceed: @escaping @Sendable () -> Bool) async throws -> String {
            l.withLock { _quiet.append(command) }
            return answer
        }
    }

    /// TMPDIR when set (a sandboxed run cannot write the system's temporary folder), else the system's.
    static var tmp: URL {
        ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0) } ?? FileManager.default.temporaryDirectory
    }

    private func commandSent(serverLine: String?) throws -> String?? {
        // Written here first: `PhoneKey.file`'s atomic write goes through the system's temporary folder.
        let url = Self.tmp.appendingPathComponent("duo-server-line-\(UUID().uuidString).key")
        try P256.Signing.PrivateKey().rawRepresentation.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let link = TerminalLink(target: .init(host: "stub", user: "nobody", hostKeyID: "server-line-test"),
                                key: try PhoneKey.file(url),
                                hostKeys: EngineTests.MemoryStore(), command: ShellCommand.tmuxOrShellComputer)
        let t = Transport(serverLine: serverLine)
        link.connector = { _, _, _, _ in t }
        link.start()
        let end = Date().addingTimeInterval(3)
        while t.commands.isEmpty && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        link.stop()
        t.closeTransport()
        return t.commands.first
    }

    func testNoTmuxCommandIsSentToAWindowsServer() throws {
        let sent = try commandSent(serverLine: "SSH-2.0-OpenSSH_for_Windows_9.5")
        XCTAssertNotNil(sent, "no shell was opened")
        XCTAssertEqual(sent!, nil, "a command was sent to a Windows PC instead of the shell request")
    }

    func testMacAndLinuxStillGetTmux() throws {
        for line in ["SSH-2.0-OpenSSH_9.8", "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5", nil] {
            XCTAssertEqual(try commandSent(serverLine: line)!, ShellCommand.tmuxOrShellComputer, "\(line ?? "nil")")
        }
    }

    // MARK: what the computer is, asked once on its own channel

    private func asked(serverLine: String?) throws -> (Transport, [String]) {
        let url = Self.tmp.appendingPathComponent("duo-uname-\(UUID().uuidString).key")
        try P256.Signing.PrivateKey().rawRepresentation.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let link = TerminalLink(target: .init(host: "stub", user: "nobody", hostKeyID: "uname-test"),
                                key: try PhoneKey.file(url),
                                hostKeys: EngineTests.MemoryStore(), command: ShellCommand.tmuxOrShellComputer)
        let t = Transport(serverLine: serverLine)
        let answers = Answers()
        link.onSystemAnswer = { answers.add($0) }
        link.connector = { _, _, _, _ in t }
        link.start()
        let end = Date().addingTimeInterval(2)
        while (t.commands.isEmpty || answers.all.isEmpty) && Date() < end {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        link.stop()
        t.closeTransport()
        return (t, answers.all)
    }

    final class Answers: @unchecked Sendable {
        private let l = NSLock(); private var a: [String] = []
        func add(_ s: String) { l.withLock { a.append(s) } }
        var all: [String] { l.withLock { a } }
    }

    func testUnameIsAskedOnItsOwnChannelOnce() throws {
        let (t, answers) = try asked(serverLine: "SSH-2.0-OpenSSH_9.6p1 Ubuntu-3ubuntu13.5")
        XCTAssertEqual(t.quiet, ["uname -s"], "asked once, as an exec of its own")
        XCTAssertEqual(t.commands, [ShellCommand.tmuxOrShellComputer], "the session on screen is untouched")
        XCTAssertEqual(answers, ["Linux\n"])
    }

    func testUnameIsNeverAskedOfAWindowsServer() throws {
        let (t, answers) = try asked(serverLine: "SSH-2.0-OpenSSH_for_Windows_9.5")
        XCTAssertEqual(t.quiet, [])
        XCTAssertEqual(answers, [])
    }
}
