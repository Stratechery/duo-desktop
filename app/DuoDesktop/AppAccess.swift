import Foundation

/// Review fixes: what the app lock allows the Terminal and JetKVM links to do right now. They are not Glass Act
/// sessions, so the lock's overlay alone did not stop them: the JetKVM view under the overlay connected (reading its
/// saved password) and the terminal kept retrying SSH. Now every connect, retry, password read and piece of input asks
/// this first, and they resume through the same successful unlock (no second prompt). Readable from any thread;
/// `RootView` feeds it from `AppLock`. Closed until the app says otherwise.
enum AppAccess {
    enum State: Equatable, Sendable {
        /// Unlocked and in front: links may connect, retry, read their passwords and send input.
        case open
        /// In the background, or back but the lock has not yet decided: nothing new starts; a live terminal link
        /// is kept (it is closed if the lock then locks).
        case away
        /// Locked: links are closed, and nothing starts until the unlock succeeds.
        case locked
    }

    static let changed = Notification.Name("DuoAppAccessChanged")
    private static let guardLock = NSLock()
    nonisolated(unsafe) private static var current: State = .locked

    static var state: State { guardLock.withLock { current } }
    static var isOpen: Bool { state == .open }

    /// Main thread. Posts `changed` (object: the new State) when it changes.
    static func set(_ new: State) {
        let changed = guardLock.withLock { () -> Bool in
            guard current != new else { return false }
            current = new
            return true
        }
        if changed { NotificationCenter.default.post(name: Self.changed, object: new) }
    }
}
