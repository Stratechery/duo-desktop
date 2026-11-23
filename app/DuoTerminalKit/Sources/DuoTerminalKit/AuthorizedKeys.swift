import Foundation

/// Adding the phone's key to the Mac's `~/.ssh/authorized_keys` (the owner 2026-11-21: "signing in with your Mac username
/// and password is reasonable"). Never duplicates: a key is "there" when its type and base64 body already appear
/// on a line, whatever the comment.
public enum AuthorizedKeys {
    /// The file with the line added, or nil when the key is already there.
    public static func appending(_ line: String, to existing: String) -> String? {
        guard let body = keyBody(line) else { return nil }
        for l in existing.split(whereSeparator: \.isNewline) where keyBody(String(l)) == body { return nil }
        var out = existing
        if !out.isEmpty, !out.hasSuffix("\n") { out += "\n" }
        return out + line + "\n"
    }

    /// "type base64" of a key line (options before the type are skipped).
    static func keyBody(_ line: String) -> String? {
        let f = line.split(separator: " ").map(String.init)
        guard let i = f.firstIndex(where: { $0.hasPrefix("ssh-") || $0.hasPrefix("ecdsa-") || $0.hasPrefix("sk-") }),
              i + 1 < f.count else { return nil }
        return f[i] + " " + f[i + 1]
    }

    /// The command run on the Mac (over the password sign-in) that does the same: makes `~/.ssh` (700) and the file
    /// (600) when missing, adds a line end if the file lacks one, and appends the line only if its key is not there.
    /// The line is a public key (letters, digits, + / = and a plain comment), so single quotes are safe; it is
    /// refused otherwise.
    public static func installCommand(_ line: String) -> String? {
        guard let body = keyBody(line), !line.contains("'"), !line.contains("\n") else { return nil }
        return """
        umask 077; mkdir -p ~/.ssh && chmod 700 ~/.ssh && touch ~/.ssh/authorized_keys && \
        chmod 600 ~/.ssh/authorized_keys && \
        if grep -qF '\(body)' ~/.ssh/authorized_keys; then echo duo-key-already-there; else \
        if [ -s ~/.ssh/authorized_keys ] && [ -n "$(tail -c1 ~/.ssh/authorized_keys)" ]; then echo >> ~/.ssh/authorized_keys; fi; \
        printf '%s\\n' '\(line)' >> ~/.ssh/authorized_keys && echo duo-key-added; fi
        """
    }
}

/// Paste inserts and never presses Return (reviewer correction 2): trailing line ends are dropped.
public enum PasteRule {
    public static func prepare(_ text: String) -> String {
        var t = text
        while let last = t.last, last == "\n" || last == "\r" || last == "\r\n" { t.removeLast() }
        return t
    }
}

/// What runs when the terminal opens (the owner: "Yes, on Tmux"): tmux's `duo` session, made or reattached; a plain login
/// shell with a one-line notice when the Mac has no tmux. Homebrew's folders are added because a command run over
/// SSH does not read the login profile.
public enum ShellCommand {
    public static let session = "duo"
    public static let tmuxOrShell = """
    PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"; if command -v tmux >/dev/null 2>&1; then exec tmux -u new -A -s \(session); \
    else echo 'Duo Desktop: tmux is not on this Mac, so this is a plain shell (it ends if the link drops).'; \
    exec "${SHELL:-/bin/zsh}" -l; fi
    """
    /// The same for a terminal-only computer (a Linux server): the notice names the computer, not a Mac, and the
    /// fallback shell is `/bin/sh`.
    public static let tmuxOrShellComputer = """
    PATH="$PATH:/opt/homebrew/bin:/usr/local/bin"; if command -v tmux >/dev/null 2>&1; then exec tmux -u new -A -s \(session); \
    else echo 'Duo Desktop: tmux is not on this computer, so this is a plain shell (it ends if the link drops).'; \
    exec "${SHELL:-/bin/sh}" -l; fi
    """
}
