import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// How the phone signs in: with its own key (always, once installed), or once with the Mac's password to install
/// that key. The password is used for this one sign-in and never stored or logged.
public enum SSHSignIn: Sendable {
    case key(PhoneKey)
    case password(String)
}

public struct SSHSignInRefused: Error, CustomStringConvertible, Sendable {
    public init() {}
    public var description: String { "The Mac did not accept the sign-in." }
}

final class SignInDelegate: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    let user: String
    var signIn: SSHSignIn?
    init(user: String, signIn: SSHSignIn) { self.user = user; self.signIn = signIn }

    func nextAuthenticationType(availableMethods: NIOSSHAvailableUserAuthenticationMethods,
                                nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>) {
        // One offer only; a second call means the Mac said no.
        guard let s = signIn else { nextChallengePromise.fail(SSHSignInRefused()); return }
        signIn = nil
        switch s {
        case .key(let k) where availableMethods.contains(.publicKey):
            nextChallengePromise.succeed(.init(username: user, serviceName: "",
                                               offer: .privateKey(.init(privateKey: k.sshKey))))
        case .password(let p) where availableMethods.contains(.password):
            nextChallengePromise.succeed(.init(username: user, serviceName: "", offer: .password(.init(password: p))))
        default:
            nextChallengePromise.fail(SSHSignInRefused())
        }
    }
}

/// Bytes and events from one SSH channel.
final class ChannelReader: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    let onData: @Sendable ([UInt8]) -> Void
    let onExit: @Sendable (Int) -> Void
    init(onData: @escaping @Sendable ([UInt8]) -> Void, onExit: @escaping @Sendable (Int) -> Void) {
        self.onData = onData; self.onExit = onExit
    }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let d = unwrapInboundIn(data)
        guard case .byteBuffer(var buf) = d.data, let bytes = buf.readBytes(length: buf.readableBytes) else { return }
        onData(bytes)
    }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let e = event as? SSHChannelRequestEvent.ExitStatus { onExit(e.exitStatus) }
        context.fireUserInboundEventTriggered(event)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) { context.close(promise: nil) }
}

/// One open shell or command on the Mac.
public final class SSHShell: @unchecked Sendable {
    let channel: Channel
    init(channel: Channel) { self.channel = channel }

    public func send(_ bytes: [UInt8]) {
        var buf = channel.allocator.buffer(capacity: bytes.count)
        buf.writeBytes(bytes)
        channel.writeAndFlush(SSHChannelData(type: .channel, data: .byteBuffer(buf)), promise: nil)
    }

    /// The terminal view changed size: the Mac's PTY follows.
    public func resize(cols: Int, rows: Int) {
        let e = SSHChannelRequestEvent.WindowChangeRequest(terminalCharacterWidth: cols, terminalRowHeight: rows,
                                                           terminalPixelWidth: 0, terminalPixelHeight: 0)
        channel.triggerUserOutboundEvent(e, promise: nil)
    }

    public var closed: EventLoopFuture<Void> { channel.closeFuture }
}

/// One SSH connection to one Mac (swift-nio-ssh over the tailnet; the Mac's own Remote Login on port 22).
public final class SSHConnection: @unchecked Sendable {
    public static let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    let channel: Channel
    let handler: NIOSSHHandler

    init(channel: Channel, handler: NIOSSHHandler) { self.channel = channel; self.handler = handler }

    /// Connects and signs in. The host key is checked against `hostKeys` before anything else happens: a changed
    /// key fails here with `HostKeyChanged`, so no shell can open.
    public static func connect(host: String, port: Int = 22, user: String, signIn: SSHSignIn,
                               hostKeys: HostKeyStore, hostKeyID: String,
                               timeout: TimeAmount = .seconds(10),
                               attempt: SSHConnectAttempt? = nil) async throws -> SSHConnection {
        let validator = TOFUHostKeyValidator(store: hostKeys, id: hostKeyID)
        let auth = SignInDelegate(user: user, signIn: signIn)
        let ready = group.next().makePromise(of: Void.self)
        let channel: Channel
        do {
            channel = try await ClientBootstrap(group: group)
            .connectTimeout(timeout)
            .channelOption(ChannelOptions.socket(SocketOptionLevel(IPPROTO_TCP), TCP_NODELAY), value: 1)
            .channelInitializer { ch in
                ch.eventLoop.makeCompletedFuture {
                    let ssh = NIOSSHHandler(role: .client(.init(userAuthDelegate: auth, serverAuthDelegate: validator)),
                                            allocator: ch.allocator, inboundChildChannelInitializer: nil)
                    try ch.pipeline.syncOperations.addHandler(ssh)
                    try ch.pipeline.syncOperations.addHandler(ReadyWatcher(ready: ready))
                }
            }
            .connect(host: host, port: port).get()
        } catch {
            // The TCP connect failed (refused, timed out): settle `ready` too; NIO stops a debug build on a
            // promise left unfulfilled (found by the app-lock retry test, which connects to a closed port).
            ready.fail(error)
            throw attempt?.isCancelled == true ? CancellationError() : error
        }
        // Review fixes 2 (review finding 3): the attempt holds the channel from here, so cancelling it (the app
        // locked) closes a connect still signing in; cancelled already = closed now.
        attempt?.adopt(channel)
        do {
            try await ready.futureResult.get()
        } catch {
            channel.close(promise: nil)
            throw attempt?.isCancelled == true ? CancellationError() : error
        }
        if attempt?.isCancelled == true { channel.close(promise: nil); throw CancellationError() }
        let handler = try await channel.pipeline.handler(type: NIOSSHHandler.self).get()
        return SSHConnection(channel: channel, handler: handler)
    }

    /// Runs one command (no PTY) and returns its output and exit status.
    public func run(_ command: String) async throws -> (output: String, status: Int) {
        let box = OutputBox()
        let shell = try await open(pty: nil, command: command, onData: { box.add($0) }, onExit: { box.status = $0 })
        try await shell.closed.get()
        return (String(decoding: box.bytes, as: UTF8.self), box.status)
    }

    /// Opens a session channel; with a PTY (cols × rows) when given. `command` nil = the login shell.
    public func open(pty: (cols: Int, rows: Int)?, command: String?,
                     onData: @escaping @Sendable ([UInt8]) -> Void,
                     onExit: @escaping @Sendable (Int) -> Void = { _ in },
                     proceed: @escaping @Sendable () -> Bool = { true }) async throws -> SSHShell {
        // Review fixes 2 (review finding 3): `proceed` is asked before the channel, the PTY and the command; false
        // (the app locked) closes what was opened and starts nothing on the Mac.
        guard proceed() else { throw CancellationError() }
        let promise = channel.eventLoop.makePromise(of: Channel.self)
        channel.eventLoop.execute {
            self.handler.createChannel(promise, channelType: .session) { child, type in
                guard type == .session else { return child.eventLoop.makeFailedFuture(SSHSignInRefused()) }
                return child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(ChannelReader(onData: onData, onExit: onExit))
                }.flatMap { child.setOption(ChannelOptions.allowRemoteHalfClosure, value: true) }
            }
        }
        let child = try await promise.futureResult.get()
        guard proceed() else { child.close(promise: nil); throw CancellationError() }
        if let pty {
            let req = SSHChannelRequestEvent.PseudoTerminalRequest(
                wantReply: true, term: "xterm-256color", terminalCharacterWidth: pty.cols,
                terminalRowHeight: pty.rows, terminalPixelWidth: 0, terminalPixelHeight: 0,
                terminalModes: SSHTerminalModes([:]))
            try await child.triggerUserOutboundEvent(req).get()
        }
        guard proceed() else { child.close(promise: nil); throw CancellationError() }
        if let command {
            try await child.triggerUserOutboundEvent(SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)).get()
        } else {
            try await child.triggerUserOutboundEvent(SSHChannelRequestEvent.ShellRequest(wantReply: true)).get()
        }
        return SSHShell(channel: child)
    }

    /// The test switch (Reviewer correction 3): closes the transport itself, as a lost link would.
    public func closeTransport() { channel.close(promise: nil) }
    public var closed: EventLoopFuture<Void> { channel.closeFuture }
}

/// Review fixes 2 (review finding 3): one connect in flight, cancellable from another thread. Cancelling closes the
/// channel as soon as there is one (at once if there already is); the connect then throws `CancellationError`.
public final class SSHConnectAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var channel: Channel?
    private var cancelled = false
    public init() {}
    public var isCancelled: Bool { lock.withLock { cancelled } }
    public func cancel() {
        let ch = lock.withLock { () -> Channel? in cancelled = true; return channel }
        ch?.close(promise: nil)
    }
    func adopt(_ ch: Channel) {
        let closeNow = lock.withLock { () -> Bool in channel = ch; return cancelled }
        if closeNow { ch.close(promise: nil) }
    }
}

final class OutputBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _bytes: [UInt8] = []
    private var _status = -1
    func add(_ b: [UInt8]) { lock.withLock { _bytes += b } }
    var bytes: [UInt8] { lock.withLock { _bytes } }
    var status: Int { get { lock.withLock { _status } } set { lock.withLock { _status = newValue } } }
}

/// Succeeds once the SSH handshake and sign-in are done; fails with the first error (a refused host key, a refused
/// sign-in) or when the connection closes first.
final class ReadyWatcher: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any
    let ready: EventLoopPromise<Void>
    var done = false
    init(ready: EventLoopPromise<Void>) { self.ready = ready }
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent, !done { done = true; ready.succeed(()) }
        context.fireUserInboundEventTriggered(event)
    }
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !done { done = true; ready.fail(error) }
        context.close(promise: nil)
    }
    func channelInactive(context: ChannelHandlerContext) {
        if !done { done = true; ready.fail(SSHSignInRefused()) }
        context.fireChannelInactive()
    }
}

/// Touch ID clarity B: what kind of failure one SSH attempt was, for a plain message.
public enum SSHFailureKind: Equatable, Sendable {
    /// The Mac answered and refused the sign-in (the key, for this user name).
    case signInRefused
    /// Nothing is listening on the SSH port (Remote Login off): the connection was refused.
    case connectionRefused
    /// Anything else: no route, timed out, name not found.
    case notReachable

    public static func of(_ error: Error) -> SSHFailureKind {
        if error is SSHSignInRefused { return .signInRefused }
        if let io = error as? IOError, io.errnoCode == ECONNREFUSED { return .connectionRefused }
        if let c = error as? NIOConnectionError,
           c.connectionErrors.contains(where: { ($0.error as? IOError)?.errnoCode == ECONNREFUSED }) {
            return .connectionRefused
        }
        if (error as NSError).domain == NSPOSIXErrorDomain, (error as NSError).code == Int(ECONNREFUSED) {
            return .connectionRefused
        }
        if String(describing: error).localizedCaseInsensitiveContains("connection refused") { return .connectionRefused }
        return .notReachable
    }
}
