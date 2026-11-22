import DuoTerminalKit
import Foundation

// The live check for M2/M4 on a Mac of your own: a throwaway file key, a host-key file.
//   duo-ssh-probe pubkey   <keyfile>
//   duo-ssh-probe exec     <host> <user> <keyfile> <hostkeys.json> <command>...
//   duo-ssh-probe reattach <host> <user> <keyfile> <hostkeys.json>
let a = CommandLine.arguments
func say(_ s: String) { print(s); fflush(stdout) }

func runExec(_ host: String, _ user: String, _ key: PhoneKey, _ store: HostKeyStore, _ cmds: [String]) async throws {
    let c = try await SSHConnection.connect(host: host, user: user, signIn: .key(key), hostKeys: store,
                                            hostKeyID: sshHostKeyID(mac: host))
    for cmd in cmds {
        let r = try await c.run(cmd)
        say("$ \(cmd)   [exit \(r.status)]\n\(r.output)")
    }
    c.closeTransport()
}

func waitFor(_ what: String, seconds: Double, _ ok: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if ok() { return true }; try? await Task.sleep(nanoseconds: 100_000_000) }
    say("timed out waiting for \(what)"); return false
}

final class Screen: @unchecked Sendable {
    let lock = NSLock(); var text = ""
    func add(_ b: [UInt8]) { lock.withLock { text += String(decoding: b, as: UTF8.self) } }
    func take() -> String { lock.withLock { let t = text; text = ""; return t } }
    func peek() -> String { lock.withLock { text } }
}

do {
    switch a.count > 1 ? a[1] : "" {
    case "pubkey":
        say(try PhoneKey.file(URL(fileURLWithPath: a[2])).authorizedKeysLine(comment: a.count > 3 ? a[3] : "duo"))
    case "exec":
        try await runExec(a[2], a[3], PhoneKey.file(URL(fileURLWithPath: a[4])),
                          FileHostKeyStore(url: URL(fileURLWithPath: a[5])), Array(a[6...]))
    case "reattach":
        let (host, user) = (a[2], a[3])
        let key = try PhoneKey.file(URL(fileURLWithPath: a[4]))
        let store = FileHostKeyStore(url: URL(fileURLWithPath: a[5]))
        let screen = Screen()
        let link = TerminalLink(target: .init(host: host, user: user, hostKeyID: sshHostKeyID(mac: host)),
                                key: key, hostKeys: store)
        link.onOutput = { screen.add($0) }
        link.onState = { say("  [link] \($0)") }
        link.resize(cols: 100, rows: 30)
        link.start()
        guard await waitFor("first connect", seconds: 15, { link.isConnected }) else { exit(2) }
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        link.send(Array("top -s 1\r".utf8))
        guard await waitFor("top on screen", seconds: 10, { screen.peek().contains("Processes:") }) else { exit(2) }
        func facts() async throws -> String {
            let c = try await SSHConnection.connect(host: host, user: user, signIn: .key(key), hostKeys: store,
                                                    hostKeyID: sshHostKeyID(mac: host))
            defer { c.closeTransport() }
            return try await c.run("PATH=$PATH:/opt/homebrew/bin; echo session=$(tmux display -p -t duo '#{session_id} created #{session_created}'); echo top_pid=$(pgrep -x top | tr '\\n' ' '); echo clients=$(tmux list-clients -t duo | wc -l)").output
        }
        let before = try await facts()
        say("BEFORE drop (connect #\(link.connects)):\n\(before)")
        _ = screen.take()
        say("closing the transport with the test switch at \(Date())")
        let t0 = Date()
        link.dropTransportForTest()
        guard await waitFor("disconnect", seconds: 5, { !link.isConnected }) else { exit(2) }
        guard await waitFor("reconnect", seconds: 20, { link.isConnected && link.connects >= 2 }) else { exit(2) }
        guard await waitFor("top redrawn", seconds: 10, { screen.peek().contains("Processes:") }) else { exit(2) }
        say(String(format: "reattached and top redrawn %.2f s after the drop (connect #%d)", Date().timeIntervalSince(t0), link.connects))
        let after = try await facts()
        say("AFTER reconnect:\n\(after)")
        say(before == after ? "SAME session, SAME top pid" : "DIFFERENT")
        link.send(Array("q".utf8))
        try? await Task.sleep(nanoseconds: 500_000_000)
        link.stop()
    default:
        say("usage: see the top of main.swift"); exit(64)
    }
} catch {
    say("error: \(error)"); exit(1)
}
