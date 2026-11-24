import Foundation
import NIOCore

/// The SSH server's own first line, its identification string (RFC 4253 §4.2: "SSH-2.0-softwareversion comments"), sent
/// before any sign-in. Windows' built-in server names itself `OpenSSH_for_Windows_…` here, so the app knows a PC before
/// anyone signs in. swift-nio-ssh reads this line but keeps it internal (`remoteVersion` is not public), so
/// `ServerLineReader` copies it on its way past.
public enum SSHServerLine {
    /// The line names Windows' own SSH server.
    public static func isWindows(_ line: String?) -> Bool {
        line?.range(of: "OpenSSH_for_Windows", options: .caseInsensitive) != nil
    }

    /// The identification line among the first bytes, once a whole `SSH-` line has arrived (the RFC lets a server
    /// send other lines first; they are skipped). nil until then.
    public static func find(in bytes: [UInt8]) -> String? {
        var start = 0
        for (i, b) in bytes.enumerated() where b == UInt8(ascii: "\n") {
            var line = String(decoding: bytes[start..<i], as: UTF8.self)
            if line.hasSuffix("\r") { line.removeLast() }
            if line.hasPrefix("SSH-") { return line }
            start = i + 1
        }
        return nil
    }
}

/// First in the pipeline, before `NIOSSHHandler`: passes every byte on unchanged, and hands the server's
/// identification line to `found` once (it then stops looking; at most 8 KiB is looked at).
final class ServerLineReader: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias InboundOut = ByteBuffer
    private var seen: [UInt8] = []
    private var done = false
    let found: @Sendable (String) -> Void
    init(found: @escaping @Sendable (String) -> Void) { self.found = found }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if !done {
            let buf = unwrapInboundIn(data)
            seen += buf.readableBytesView
            if let line = SSHServerLine.find(in: seen) { done = true; seen = []; found(line) }
            else if seen.count > 8192 { done = true; seen = [] }
        }
        context.fireChannelRead(data)
    }
}
