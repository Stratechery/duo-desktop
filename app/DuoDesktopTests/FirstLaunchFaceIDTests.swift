import LocalAuthentication
import XCTest
@testable import DuoDesktop

/// First-launch Face ID fix: the app lock's state machine around the system's own Face ID alerts. Those alerts (the
/// first-use "Allow … to use Face ID?" question, "Face Not Recognized", the passcode pad) make the scene inactive and
/// then active again. The app used to treat every active-after-inactive as a return: it asked again by itself, so
/// cancelling or refusing put the request straight back up (reproduced in the simulator: two requests after one Cancel,
/// the Unlock button dimmed).
@MainActor
final class FirstLaunchFaceIDTests: XCTestCase {
    private func defaults() -> UserDefaults {
        let name = "FirstLaunchFaceIDTests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }
    private struct Cancelled: Error {}

    /// The cause: active after only inactive (a system alert answered Cancel / Don't Allow) must not ask again.
    func testSystemAlertAnsweredDoesNotAskAgain() async {
        var asked = 0
        let lock = AppLock(defaults: defaults()) { _ in asked += 1; return .failure(Cancelled()) }
        await lock.autoUnlockIfDue(sceneActive: true) // launch: once
        XCTAssertEqual(asked, 1)
        XCTAssertNotNil(lock.message, "the cancel is said on the lock screen")
        // The alert went away: the scene comes back active, never having gone to the background.
        lock.willEnterForeground()
        await lock.autoUnlockIfDue(sceneActive: true)
        lock.willEnterForeground()
        await lock.autoUnlockIfDue(sceneActive: true)
        XCTAssertEqual(asked, 1, "no request by itself after the person answered the system's alert")
        XCTAssertTrue(lock.locked)
        XCTAssertFalse(lock.busy, "the Unlock button is usable")
        await lock.unlock() // the button
        XCTAssertEqual(asked, 2, "the button still asks")
    }

    /// Inactive while a request is pending (the first-use question is up) must not start a second one or re-lock.
    func testInactiveWhilePendingStartsNothing() async {
        var asked = 0
        var finish: CheckedContinuation<Void, Never>?
        let lock = AppLock(defaults: defaults()) { _ in
            asked += 1
            await withCheckedContinuation { finish = $0 }
            return .success(nil)
        }
        let first = Task { await lock.autoUnlockIfDue(sceneActive: true) }
        while finish == nil { await Task.yield() }
        XCTAssertTrue(lock.busy)
        // The alert makes the scene inactive and active again, more than once, while the request is pending.
        for _ in 0..<3 {
            lock.willEnterForeground()
            await lock.autoUnlockIfDue(sceneActive: true)
            await lock.unlock()
        }
        XCTAssertEqual(asked, 1, "one request only")
        finish?.resume()
        await first.value
        XCTAssertFalse(lock.locked, "the one request unlocks")
        lock.willEnterForeground()
        XCTAssertFalse(lock.locked, "active after inactive never re-locks")
    }

    /// While a request is pending (the first-time question up), nothing the screens read about the unlock method
    /// calls LocalAuthentication; it is read again once the request is over.
    func testNoDeviceReadWhilePending() async {
        var finish: CheckedContinuation<Void, Never>?
        let lock = AppLock(defaults: defaults()) { _ in
            await withCheckedContinuation { finish = $0 }
            return .success(nil)
        }
        let first = Task { await lock.autoUnlockIfDue(sceneActive: true) }
        while finish == nil { await Task.yield() }
        let before = UnlockMethod.Device.readCount
        for _ in 0..<5 { // what a redraw of the lock screen and the Mac list reads
            _ = UnlockMethod.current
            _ = UnlockMethod.hardware
            _ = UnlockMethod.refused
            _ = AppLock.deviceCanAuthenticate()
            _ = AppLock.describe(Cancelled())
            lock.willEnterForeground()
        }
        XCTAssertEqual(UnlockMethod.Device.readCount, before, "no LocalAuthentication call while a request is pending")
        finish?.resume()
        await first.value
        XCTAssertEqual(UnlockMethod.Device.readCount, before + 1, "read again once, after the request")
    }

    /// Launch: nothing is asked before the scene is active (the window on screen), and it is asked once after.
    func testLaunchAsksOnlyWhenActiveAndOnce() async {
        var asked = 0
        let lock = AppLock(defaults: defaults()) { _ in asked += 1; return .failure(Cancelled()) }
        await lock.autoUnlockIfDue(sceneActive: false)
        XCTAssertEqual(asked, 0, "not before the window is active")
        await lock.autoUnlockIfDue(sceneActive: true)
        await lock.autoUnlockIfDue(sceneActive: true)
        XCTAssertEqual(asked, 1, "once")
    }

    /// A real return from the background while locked asks once more (the phone locked, or the person left while
    /// the alert was up), and after 5 minutes away an unlocked app locks and asks once.
    func testRealReturnAsksOnce() async {
        var asked = 0
        var answer: Result<LAContext?, Error> = .failure(Cancelled())
        let lock = AppLock(defaults: defaults()) { _ in asked += 1; return answer }
        await lock.autoUnlockIfDue(sceneActive: true)
        let t0 = Date(timeIntervalSince1970: 0)
        lock.didEnterBackground(now: t0)
        lock.willEnterForeground(now: t0.addingTimeInterval(5))
        await lock.autoUnlockIfDue(sceneActive: true)
        await lock.autoUnlockIfDue(sceneActive: true)
        XCTAssertEqual(asked, 2, "one more, after the real return")
        answer = .success(nil)
        await lock.unlock()
        XCTAssertFalse(lock.locked)
        lock.didEnterBackground(now: t0)
        lock.willEnterForeground(now: t0.addingTimeInterval(299))
        await lock.autoUnlockIfDue(sceneActive: true)
        XCTAssertEqual(asked, 3, "under 5 minutes: stays open, nothing asked")
        lock.didEnterBackground(now: t0)
        lock.willEnterForeground(now: t0.addingTimeInterval(300))
        XCTAssertTrue(lock.locked)
        await lock.autoUnlockIfDue(sceneActive: true)
        XCTAssertEqual(asked, 4, "5 minutes away: locked and asked once")
    }

    /// Face ID refused for the app: named plainly, with the way to turn it on.
    func testRefusedFaceIDIsSaid() {
        XCTAssertEqual(UnlockMethod.refused(code: .biometryNotAvailable, type: .faceID), .faceID)
        XCTAssertNil(UnlockMethod.refused(code: .biometryNotEnrolled, type: .faceID), "not set up is another case")
        XCTAssertNil(UnlockMethod.refused(code: .biometryNotAvailable, type: .none), "no hardware: nothing refused")
        XCTAssertNil(UnlockMethod.refused(code: nil, type: .faceID))
        XCTAssertEqual(UnlockMethod.faceID.refusedText,
                       "Face ID is off for Duo Desktop, so it uses your passcode. To use Face ID, turn it on in Settings > Duo Desktop.")
    }
}
