@testable import DuoTerminalKit
import CryptoKit
import NIOCore
import NIOPosix
import NIOSSH
import XCTest

/// Project notes 5, at the engine level: a real SSH handshake against a local test SSH server (swift-nio-ssh,
/// on 127.0.0.1, this process) that takes ONE made-up password (or none at all) and runs each exec request with
/// /bin/zsh against a made-up home folder. Nothing on this Mac's own accounts is touched.
final class KeyInstallTests: XCTestCase {
    final class MemoryStore: HostKeyStore, @unchecked Sendable {
        var keys: [String: String] = [:]
        func hostKey(for id: String) -> String? { keys[id] }
        func setHostKey(_ key: String, for id: String) { keys[id] = key }
    }

    let line = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTY= duo-desktop-test"

    /// The right password adds the key once (twice: already there); the wrong one says so; a server that takes no
    /// password says that; a home that cannot be written says that; and a `none` (Tailscale) sign-in to this
    /// ordinary server is told apart from a Tailscale refusal.
    func testPasswordSignInAddsTheKey() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("duo-kih-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let server = try await TestSSHServer.start(password: "made-up-only", home: home)
        defer { server.stop() }
        let store = MemoryStore()
        func install(_ pw: String) async -> KeyInstallByPassword.Outcome {
            await KeyInstallByPassword.run(host: "127.0.0.1", port: server.port, user: "tester", password: pw,
                                           keyLine: line, hostKeys: store, hostKeyID: "ssh:test:\(server.port)")
        }
        let wrong = await install("not-it")
        XCTAssertEqual(wrong, .wrongPassword)
        let first = await install("made-up-only")
        XCTAssertEqual(first, .added(alreadyThere: false))
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".ssh/authorized_keys"), encoding: .utf8), line + "\n")
        let again = await install("made-up-only")
        XCTAssertEqual(again, .added(alreadyThere: true))
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".ssh/authorized_keys"), encoding: .utf8), line + "\n")

        // Tailscale's `none` against this ordinary server: not a refusal by Tailscale.
        do {
            _ = try await SSHConnection.connect(host: "127.0.0.1", port: server.port, user: "tester", signIn: .tailscale,
                                                hostKeys: store, hostKeyID: "ssh:test:\(server.port)", timeout: .seconds(5))
            XCTFail("signed in with none")
        } catch let n as SSHNotTailscale {
            XCTAssertTrue(n.offersPassword)
            XCTAssertTrue(n.offersKey)
        }

        // A home folder that cannot be written.
        let locked = FileManager.default.temporaryDirectory.appendingPathComponent("duo-kil-\(UUID())")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        let s2 = try await TestSSHServer.start(password: "made-up-only", home: locked)
        defer { s2.stop() }
        let r = await KeyInstallByPassword.run(host: "127.0.0.1", port: s2.port, user: "tester", password: "made-up-only",
                                               keyLine: line, hostKeys: store, hostKeyID: "ssh:test:\(s2.port)")
        guard case let .cannotWrite(detail) = r else { return XCTFail("\(r)") }
        XCTAssertTrue(detail.localizedCaseInsensitiveContains("permission denied"), detail)

        // A server that takes keys only.
        let s3 = try await TestSSHServer.start(password: nil, home: home)
        defer { s3.stop() }
        let r3 = await KeyInstallByPassword.run(host: "127.0.0.1", port: s3.port, user: "tester", password: "made-up-only",
                                                keyLine: line, hostKeys: store, hostKeyID: "ssh:test:\(s3.port)")
        XCTAssertEqual(r3, .passwordNotAllowed)
    }

    func testWindowsOutputIsNamed() {
        XCTAssertEqual(KeyInstallByPassword.outcome(output: "'umask' is not recognized as an internal or external command,\r\n", status: 1), .windows)
        XCTAssertEqual(KeyInstallByPassword.outcome(output: "duo-key-added\n", status: 0), .added(alreadyThere: false))
    }

    /// Tailscale's refusal is still Tailscale's (banner first), and a second call after `none` is ordinary SSH.
    func testNoneAnsweredByOrdinarySSHIsNotTailscale() throws {
        let loop = EmbeddedEventLoopShim.make()
        let d = SignInDelegate(user: "lab", signIn: .tailscale)
        let first = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        d.nextAuthenticationType(availableMethods: .all, nextChallengePromise: first)
        _ = try first.futureResult.wait()
        let second = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        d.nextAuthenticationType(availableMethods: [.publicKey, .password], nextChallengePromise: second)
        XCTAssertThrowsError(try second.futureResult.wait()) { e in
            let n = e as? SSHNotTailscale
            XCTAssertEqual(n?.offersPassword, true)
            XCTAssertEqual(SSHFailureKind.of(e), .signInRefused)
        }
    }
}

enum EmbeddedEventLoopShim {
    static func make() -> EventLoop { MultiThreadedEventLoopGroup.singleton.next() }
}

// MARK: - A local test SSH server

final class TestSSHServer: @unchecked Sendable {
    let channel: Channel
    var port: Int { channel.localAddress?.port ?? 0 }
    init(channel: Channel) { self.channel = channel }
    func stop() { channel.close(promise: nil) }

    static func start(password: String?, home: URL) async throws -> TestSSHServer {
        let hostKey = NIOSSHPrivateKey(p256Key: P256.Signing.PrivateKey())
        let ch = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { child in
                child.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(
                        role: .server(.init(hostKeys: [hostKey], userAuthDelegate: PasswordOnly(password: password))),
                        allocator: child.allocator,
                        inboundChildChannelInitializer: { sub, _ in
                            sub.eventLoop.makeCompletedFuture {
                                try sub.pipeline.syncOperations.addHandler(ExecHandler(home: home))
                            }.flatMap { sub.setOption(ChannelOptions.allowRemoteHalfClosure, value: true) }
                        })
                    try child.pipeline.syncOperations.addHandler(ssh)
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        return TestSSHServer(channel: ch)
    }

    final class PasswordOnly: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
        let password: String?
        init(password: String?) { self.password = password }
        var supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods {
            password == nil ? .publicKey : [.publicKey, .password]
        }
        func requestReceived(request: NIOSSHUserAuthenticationRequest,
                             responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
            if case let .password(p) = request.request, let password, p.password == password {
                responsePromise.succeed(.success)
            } else {
                responsePromise.succeed(.failure)
            }
        }
    }

    /// Runs one exec request with /bin/zsh, HOME = the made-up home, sends stdout and stderr and the exit status.
    final class ExecHandler: ChannelDuplexHandler, @unchecked Sendable {
        typealias InboundIn = SSHChannelData
        typealias OutboundIn = SSHChannelData
        typealias OutboundOut = SSHChannelData
        let home: URL
        init(home: URL) { self.home = home }
        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            guard let exec = event as? SSHChannelRequestEvent.ExecRequest else {
                context.fireUserInboundEventTriggered(event); return
            }
            if exec.wantReply { context.channel.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = ["-c", exec.command]
            p.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
            let out = Pipe(); p.standardOutput = out; p.standardError = out
            try? p.run(); p.waitUntilExit()
            let bytes = out.fileHandleForReading.readDataToEndOfFile()
            let ch = context.channel
            var buf = ch.allocator.buffer(capacity: bytes.count)
            buf.writeBytes(bytes)
            ch.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buf)), promise: nil)
            ch.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: Int(p.terminationStatus)), promise: nil)
            ch.close(promise: nil)
        }
    }
}
