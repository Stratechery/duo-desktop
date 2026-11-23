import Foundation

/// Project notes 5 (the owner: "doing a hand crafted fix isn't very sustainable..."): on a computer with
/// ordinary SSH, sign in ONCE with the account's password, add this iPhone's key to `~/.ssh/authorized_keys` with the
/// same idempotent command the Host path uses (`AuthorizedKeys.installCommand`), sign out. From then on the app signs
/// in with the key. The password is passed straight to the one sign-in and is never stored or logged here.
public enum KeyInstallByPassword {
    public enum Outcome: Equatable, Sendable {
        /// The key was added (or was already there).
        case added(alreadyThere: Bool)
        /// The server does not take a password sign-in (only then is the key shown to copy by hand).
        case passwordNotAllowed
        /// The server refused the password for that user.
        case wrongPassword
        /// Signed in, but the key could not be written (a home folder that cannot be written, a full disk…).
        case cannotWrite(detail: String)
        /// Signed in to a Windows computer: its OpenSSH reads administrators_authorized_keys for admins, and our
        /// POSIX command does not run there. Not handled yet.
        case windows
        /// Anything else (no answer, a changed host key…), in the engine's words.
        case failed(String)
    }

    /// Signs in with the password, runs the install command, closes. `connect` is swappable for tests.
    public static func run(host: String, port: Int, user: String, password: String, keyLine: String,
                           hostKeys: HostKeyStore, hostKeyID: String,
                           attempt: SSHConnectAttempt? = nil) async -> Outcome {
        guard let cmd = AuthorizedKeys.installCommand(keyLine) else { return .failed("This iPhone’s key line is not valid.") }
        let c: SSHConnection
        do {
            c = try await SSHConnection.connect(host: host, port: port, user: user, signIn: .password(password),
                                                hostKeys: hostKeys, hostKeyID: hostKeyID, timeout: .seconds(8),
                                                attempt: attempt, signInTimeout: .seconds(20))
        } catch let r as SSHSignInRefused {
            return r.offersPassword ? .wrongPassword : .passwordNotAllowed
        } catch {
            return .failed(String(describing: error))
        }
        defer { c.closeTransport() }
        do {
            let r = try await c.run(cmd)
            return outcome(output: r.output, status: r.status)
        } catch {
            return .failed(String(describing: error))
        }
    }

    /// What the install command's output and exit status mean (pure, tests).
    public static func outcome(output: String, status: Int) -> Outcome {
        if output.contains("duo-key-already-there") { return .added(alreadyThere: true) }
        if output.contains("duo-key-added"), status == 0 { return .added(alreadyThere: false) }
        // cmd.exe: "'umask' is not recognized as an internal or external command"; PowerShell: "The term 'umask' is
        // not recognized as …".
        if output.localizedCaseInsensitiveContains("is not recognized as") { return .windows }
        let first = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return .cannotWrite(detail: first.isEmpty ? "exit \(status)" : first)
    }
}
