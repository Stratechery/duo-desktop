#if DUO_JETKVM
import JetKVMClient
#endif
import GlassActTransport
import LocalAuthentication
import XCTest
@testable import DuoDesktop

/// project notes, one computer with any connection, milestone 2: Add Computer with Start With, Add… rows and removal on
/// the ⓘ page, a JetKVM-only computer that opens. One test per claim; made-up names only.
@MainActor
final class ComputersM2Tests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!
    private var access: AppAccess.State = .locked

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "ComputersM2Tests.\(UUID().uuidString)")
        access = AppAccess.state
        AppAccess.set(.open)
    }

    override func tearDown() async throws {
        AppAccess.set(access)
        ComputerNav.shared.close()
    }

    private func store() -> MacStore {
        MacStore(url: dir.appendingPathComponent("macs.json"), defaults: defaults,
                 knownHosts: KnownHosts(url: dir.appendingPathComponent("known_hosts")))
    }

    /// A computer as the Add sheet saves one that starts with JetKVM.
    private func jetkvmOnly(_ name: String) -> MacEntry {
        var e = MacEntry(name: name)
        e.screenSharing = false
        e.terminal = false
        e.jetkvm = true
        e.jetkvmAddress = "kvm.example.invalid"
        return e
    }

    /// Claim: a computer added by JetKVM alone (no Glass Act Host) is saved, shows in the Computers list with
    /// "JetKVM", stays out of everything Glass Act reads, and its JetKVM icon opens it on its own screen; a
    /// Terminal-only computer's Terminal icon opens its terminal. A build without the JetKVM keeps it saved but does
    /// not list it.
    func testJetKVMOnlyComputerIsAddedListedAndOpens() throws {
        let s = store()
        let k = jetkvmOnly("Corner Test Mac")
        s.add(k)
        let saved = try XCTUnwrap(store().entry(k.id), "saved to the file")
        XCTAssertEqual(saved.setUpWays, [.jetkvm])
        XCTAssertFalse(s.macs.contains { $0.id == k.id }, "no Glass Act reader sees it")
        #if DUO_JETKVM
        XCTAssertTrue(s.computers.contains { $0.id == k.id })
        XCTAssertEqual(saved.waysInThisBuild, [.jetkvm])
        ComputerNav.shared.open(saved, in: .jetkvm)
        XCTAssertEqual(ComputerNav.shared.openID, k.id)
        XCTAssertEqual(ComputerNav.shared.way, .jetkvm)
        #else
        XCTAssertFalse(s.computers.contains { $0.id == k.id }, "this build cannot show it: kept, not listed")
        XCTAssertFalse(saved.opens(.jetkvm))
        #endif

        let t = MacEntry.makeTerminalOnly(name: "Lab Test Server")
        s.add(t)
        #if DUO_TERMINAL
        XCTAssertTrue(try XCTUnwrap(s.entry(t.id)).opens(.terminal))
        #endif
    }

    /// Claim: on the ⓘ page any way in can be removed while another remains, and removing the last one removes the
    /// computer. Removing Screen Sharing deletes the Mac's saved unlock password and turns Unlock Automatically
    /// off (so nothing of it is left for the Touch ID sweep, which only walks computers with Screen Sharing);
    /// removing the last way in also deletes the computer's JetKVM password.
    func testRemovingWaysInThenTheLastRemovesTheComputer() throws {
        let passwords = RecordingPasswords()
        let s = store()
        s.passwords = passwords
        #if DUO_JETKVM
        let kvm = MemoryKVMPasswords()
        let savedKVM = JetKVMSettings.passwords
        JetKVMSettings.passwords = kvm
        defer { JetKVMSettings.passwords = savedKVM }
        #endif
        var e = MacEntry(name: "Studio Test Mac")
        e.set(.home, "studio.local")
        e.key = "AB12"
        e.autoUnlock = true
        e.terminal = true
        e.sshUser = "me"
        e.jetkvm = true
        e.jetkvmAddress = "kvm.example.invalid"
        s.add(e)
        #if DUO_JETKVM
        kvm.items[e.id] = "made-up"
        #endif

        XCTAssertFalse(s.removeWay(.screenSharing, from: e.id))
        var now = try XCTUnwrap(s.entry(e.id), "still in the list")
        XCTAssertEqual(now.setUpWays, [.terminal, .jetkvm])
        XCTAssertNil(now.key)
        XCTAssertNil(now.autoUnlock)
        XCTAssertEqual(now.home, "studio.local", "the Terminal keeps the shared address")
        XCTAssertEqual(passwords.deleted, [e.id], "the Mac's unlock password is deleted")
        XCTAssertFalse(s.macs.contains { $0.id == e.id })

        XCTAssertFalse(s.removeWay(.terminal, from: e.id))
        now = try XCTUnwrap(s.entry(e.id))
        XCTAssertEqual(now.setUpWays, [.jetkvm])

        XCTAssertTrue(s.removeWay(.jetkvm, from: e.id), "the last way in removes the computer")
        XCTAssertNil(s.entry(e.id))
        XCTAssertNil(store().entry(e.id), "gone from the file too")
        #if DUO_JETKVM
        XCTAssertNil(kvm.items[e.id], "its JetKVM password is deleted")
        #endif
    }

    /// Claim: the Add sheet's Glass Act check never asks while the app is locked (Screen Sharing's Add check, with
    /// the Terminal's and the JetKVM's).
    func testScreenSharingAddCheckDoesNotAskWhileLocked() {
        AppAccess.set(.locked)
        let check = AddressCheck()
        check.run(TypedAddress(host: "127.0.0.1", port: 9), identity: nil)
        XCTAssertEqual(check.state, .locked)
    }

    #if DUO_JETKVM
    /// Claim: the Add sheet's JetKVM sign-in check stops when the app locks (build 59 review, applied to the
    /// new JetKVM check): the pending sign-in is cancelled at once, and one that still finishes after the lock is
    /// not reported as signed in. It never starts while locked.
    func testJetKVMAddCheckStopsWhenTheAppLocks() async throws {
        let gate = Gate()
        let started = expectation(description: "sign-in started")
        let check = Task { @MainActor in
            await JetKVMAddCheck.run(name: "Test", host: "kvm.example.invalid", password: "made-up") { _, _ in
                started.fulfill()
                await gate.wait()
                gate.sawCancelled = Task.isCancelled
            }
        }
        await fulfillment(of: [started], timeout: 2)
        AppAccess.set(.locked)
        gate.open()
        let r = await check.value
        XCTAssertFalse(r.ok)
        XCTAssertEqual(r.text, JetKVMAddCheck.lockedText)
        XCTAssertTrue(gate.sawCancelled, "the sign-in was cancelled when the app locked")

        let second = Gate()
        let locked = await JetKVMAddCheck.run(name: "Test", host: "kvm.example.invalid", password: "made-up") { _, _ in
            second.sawCancelled = true
        }
        XCTAssertFalse(second.sawCancelled, "nothing starts while locked")
        XCTAssertEqual(locked.text, JetKVMAddCheck.lockedText)
    }
    #endif
}

extension MacEntry {
    /// A Terminal-only computer as the Add sheet saves one (made-up fields), in every build.
    static func makeTerminalOnly(name: String) -> MacEntry {
        var e = MacEntry(name: name)
        e.screenSharing = false
        e.terminal = true
        e.sshPort = 22
        e.set(.tailscale, "lab-server")
        e.sshUser = "lab"
        e.terminalSignIn = .tailscale
        e.terminalOpens = .tmux
        return e
    }
}

private final class RecordingPasswords: MacPasswordKeeping {
    var deleted: [String] = []
    func save(_ password: Data, macID: String) -> Bool { true }
    func delete(macID: String) { deleted.append(macID) }
    func read(macID: String, context: LAContext) -> Data? { nil }
}

#if DUO_JETKVM
private final class MemoryKVMPasswords: JetKVMPasswordStore {
    var items: [String: String] = [:]
    func password(mac: String) -> String? { items[mac] }
    func setPassword(_ password: String?, mac: String) { items[mac] = password }
}
#endif

/// Holds a stubbed sign-in until the test opens it.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiter: CheckedContinuation<Void, Never>?
    private var opened = false
    var sawCancelled = false

    func wait() async {
        await withCheckedContinuation { c in
            let now = lock.withLock { () -> Bool in
                if opened { return true }
                waiter = c
                return false
            }
            if now { c.resume() }
        }
    }

    func open() {
        let w = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            opened = true
            defer { waiter = nil }
            return waiter
        }
        w?.resume()
    }
}
