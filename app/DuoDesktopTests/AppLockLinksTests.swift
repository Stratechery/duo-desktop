import LocalAuthentication
import XCTest
@testable import DuoDesktop
#if DUO_TERMINAL
import DuoTerminalKit
#endif
#if DUO_JETKVM
import JetKVMProtocol
#endif

/// Review fixes: the Terminal and JetKVM links obey the app lock. the reviewer's focused check: start the optional
/// views, go to the background past the lock threshold, come back and CANCEL Touch ID while the SSH transport is lost;
/// zero SSH attempts, JetKVM password reads or JetKVM starts until the same unlock succeeds. Fake Touch ID, fake JetKVM
/// password and start, an SSH link to a closed local port. Made-up names only.
@MainActor
final class AppLockLinksTests: XCTestCase {
    private var before: AppAccess.State = .locked
    override func setUp() async throws { before = AppAccess.state }
    override func tearDown() async throws { AppAccess.set(before) }

    private struct Cancelled: Error {}
    private final class Answer { var value: Result<LAContext?, Error> = .success(nil) }

    /// A lock wired to `AppAccess` the way `RootView` wires it.
    private func wiredLock(_ answer: Answer) -> AppLock {
        let d = UserDefaults(suiteName: "AppLockLinksTests.\(UUID().uuidString)")!
        let lock = AppLock(defaults: d) { _ in answer.value }
        lock.onAccessChange = { AppAccess.set($0) }
        AppAccess.set(lock.access)
        return lock
    }

    private func spin(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    /// Lets main-actor tasks (the JetKVM start task) run; a run-loop spin inside this main-actor test does not.
    private func pause(_ seconds: Double) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1e9)) }

    func testAccessFollowsTheLock() async {
        let answer = Answer()
        let lock = wiredLock(answer)
        XCTAssertEqual(AppAccess.state, .locked, "locked at launch")
        await lock.unlock()
        XCTAssertEqual(AppAccess.state, .open)
        let t0 = Date(timeIntervalSince1970: 0)
        lock.didEnterBackground(now: t0)
        XCTAssertEqual(AppAccess.state, .away, "away: nothing new starts")
        lock.willEnterForeground(now: t0.addingTimeInterval(10))
        XCTAssertEqual(AppAccess.state, .open, "back within 5 minutes: open, no prompt")
        lock.didEnterBackground(now: t0)
        lock.willEnterForeground(now: t0.addingTimeInterval(301))
        XCTAssertEqual(AppAccess.state, .locked)
        answer.value = .failure(Cancelled())
        await lock.unlock()
        XCTAssertEqual(AppAccess.state, .locked, "cancelled Touch ID stays locked")
        answer.value = .success(nil)
        await lock.unlock()
        XCTAssertEqual(AppAccess.state, .open)
    }

    #if DUO_JETKVM
    private final class Recorder: JetKVMOutput {
        var calls = 0
        func sendKeyboard(modifiers: HIDRPC.Modifiers, keys: [UInt8]) { calls += 1 }
        func sendPointerDelta(dx: Int, dy: Int, buttons: HIDRPC.Buttons?) { calls += 1 }
        func sendScroll(dy: Int, dx: Int) { calls += 1 }
    }

    func testJetKVMReadsNoPasswordAndStartsNothingUntilTheSameUnlock() async throws {
        let answer = Answer()
        let lock = wiredLock(answer)
        await lock.unlock()
        let entry = try JSONDecoder().decode(MacEntry.self, from: Data(
            #"{"id":"LOCK-\#(UUID().uuidString)","name":"Lock Test","port":4433,"layout":"standard","jetkvm":true,"jetkvmAddress":"jetkvm.invalid"}"#.utf8))
        let link = JetKVMLink.for(mac: entry.id)
        link.readPassword = { _ in "made-up" }
        link.startSession = { _ in try await Task.sleep(nanoseconds: 60_000_000_000) } // never live, never fails
        link.connect(entry: entry) // the view is shown
        await pause(0.05)
        XCTAssertEqual(link.passwordReads, 1); XCTAssertEqual(link.starts, 1)
        // Away past the threshold, back, Touch ID cancelled; the view's return-to-front handler asks to connect.
        let t0 = Date(timeIntervalSince1970: 0)
        lock.didEnterBackground(now: t0)
        await pause(0.05)
        link.connect(entry: entry) // a return handler that runs before the lock decides
        lock.willEnterForeground(now: t0.addingTimeInterval(301))
        await pause(0.05)
        XCTAssertNil(link.session, "locked: the JetKVM is released")
        answer.value = .failure(Cancelled())
        await lock.unlock()
        link.connect(entry: entry)
        link.reconnect(entry: entry)
        await pause(0.05)
        XCTAssertEqual(link.passwordReads, 1, "password read while locked")
        XCTAssertEqual(link.starts, 1, "JetKVM started while locked")
        // The same unlock succeeds: it connects again by itself, no second prompt.
        answer.value = .success(nil)
        await lock.unlock()
        await pause(0.05)
        XCTAssertEqual(link.passwordReads, 2); XCTAssertEqual(link.starts, 2)
        link.disconnect()
    }

    /// Review fixes 2 (the outside re-review, finding 3): the app locks while a connect is starting, before its start
    /// task has run. Nothing may sign in to the JetKVM or start its session after the lock; the same unlock
    /// connects again.
    func testLockDuringJetKVMStartUpStartsNothing() async throws {
        let answer = Answer()
        let lock = wiredLock(answer)
        await lock.unlock()
        let entry = try JSONDecoder().decode(MacEntry.self, from: Data(
            #"{"id":"LOCK-\#(UUID().uuidString)","name":"Lock Test","port":4433,"layout":"standard","jetkvm":true,"jetkvmAddress":"jetkvm.invalid"}"#.utf8))
        let link = JetKVMLink.for(mac: entry.id)
        link.readPassword = { _ in "made-up" }
        var started: [AnyObject] = []
        link.startSession = { s in started.append(s); try await Task.sleep(nanoseconds: 60_000_000_000) }
        link.connect(entry: entry) // the view is shown; its start task is queued, not yet run
        XCTAssertEqual(link.passwordReads, 1)
        let t0 = Date(timeIntervalSince1970: 0)
        lock.didEnterBackground(now: t0)
        lock.willEnterForeground(now: t0.addingTimeInterval(301)) // locks before the start task runs
        XCTAssertEqual(AppAccess.state, .locked)
        await pause(0.2)
        XCTAssertEqual(link.starts, 0, "JetKVM session started after the lock")
        XCTAssertTrue(started.isEmpty, "sign-in/start reached the JetKVM after the lock")
        XCTAssertNil(link.session, "locked: the JetKVM is released")
        XCTAssertEqual(link.passwordReads, 1, "password read after the lock")
        // The same unlock connects again by itself.
        answer.value = .success(nil)
        await lock.unlock()
        await pause(0.1)
        XCTAssertEqual(link.starts, 1); XCTAssertEqual(started.count, 1)
        XCTAssertTrue(started.first === link.session, "the start ran on the current session")
        link.disconnect()
    }

    func testNoJetKVMInputWhileLocked() {
        let input = JetKVMInput()
        let rec = Recorder()
        input.output = rec
        AppAccess.set(.locked)
        input.sendInput(kind: InputKind.move, x: 100, y: 100, a: 0, b: 0)
        input.sendInput(kind: InputKind.move, x: 140, y: 100, a: 0, b: 0)
        XCTAssertEqual(rec.calls, 0)
        AppAccess.set(.open)
        input.sendInput(kind: InputKind.move, x: 180, y: 100, a: 0, b: 0)
        input.sendInput(kind: InputKind.move, x: 220, y: 100, a: 0, b: 0)
        XCTAssertGreaterThan(rec.calls, 0)
    }
    #endif

    #if DUO_TERMINAL
    private final class MemoryHostKeys: HostKeyStore, @unchecked Sendable {
        func hostKey(for id: String) -> String? { nil }
        func setHostKey(_ key: String, for id: String) {}
    }

    func testTerminalMakesNoSSHAttemptUntilTheSameUnlock() async throws {
        let answer = Answer()
        let lock = wiredLock(answer)
        await lock.unlock()
        let key = try PhoneKey.file(FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID()).key"))
        // A closed local port: every attempt fails at once and retries, so attempts are easy to count.
        let link = TerminalLink(target: .init(host: "127.0.0.1", port: 9, user: "nobody", hostKeyID: "lock-test"),
                                key: key, hostKeys: MemoryHostKeys())
        link.mayConnect = { AppAccess.isOpen } // as TerminalSession sets it
        let watch = NotificationCenter.default.addObserver(forName: AppAccess.changed, object: nil, queue: nil) { note in
            if let s = note.object as? AppAccess.State { TerminalSession.apply(s, to: link) }
        }
        defer { NotificationCenter.default.removeObserver(watch); link.stop() }
        link.start()
        spin(0.8)
        XCTAssertGreaterThan(link.connectAttempts, 0)
        let t0 = Date(timeIntervalSince1970: 0)
        lock.didEnterBackground(now: t0)
        lock.willEnterForeground(now: t0.addingTimeInterval(301))
        spin(0.3)
        let atLock = link.connectAttempts
        link.dropTransportForTest() // the SSH transport is lost while locked
        answer.value = .failure(Cancelled())
        await lock.unlock()
        spin(1.5)
        XCTAssertEqual(link.connectAttempts, atLock, "SSH retried while locked")
        answer.value = .success(nil)
        await lock.unlock()
        spin(0.8)
        XCTAssertGreaterThan(link.connectAttempts, atLock, "the unlock did not resume SSH")
    }

    func testTerminalViewStartWaitsForTheUnlock() {
        let session = TerminalSession.for(mac: "LOCK-\(UUID().uuidString)")
        AppAccess.set(.locked)
        var ran = 0
        session.whenAppOpen { ran += 1 }
        XCTAssertEqual(ran, 0, "the Host key request / SSH ran while locked")
        AppAccess.set(.open)
        spin(0.05)
        XCTAssertEqual(ran, 1)
        session.deliver([0x61]) // no link: nothing to send, and no crash
    }
    #endif
}
