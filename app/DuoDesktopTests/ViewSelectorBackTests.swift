import XCTest
@testable import DuoDesktop

/// Project notes (view-selector-back). The Terminal and JetKVM screens opened from the list carry the session's own
/// views control with the session's own choices.
@MainActor
final class ViewSelectorBackTests: XCTestCase {
    private func computer(_ ways: Set<WayIn>) -> MacEntry {
        var e = MacEntry(name: "Mix")
        e.set(.tailscale, "192.0.2.60")
        e.screenSharing = ways.contains(.screenSharing)
        e.terminal = ways.contains(.terminal)
        e.sshUser = "mix"
        e.jetkvm = ways.contains(.jetkvm)
        e.jetkvmAddress = ways.contains(.jetkvm) ? "192.0.2.61" : nil
        e.kind = e.hasScreenSharing ? nil : .terminal
        return e
    }

    private let mixes: [Set<WayIn>] = [[.terminal], [.jetkvm], [.terminal, .jetkvm], [.screenSharing],
                                       [.screenSharing, .terminal], [.screenSharing, .jetkvm],
                                       [.screenSharing, .terminal, .jetkvm]]

    /// The Terminal and JetKVM screens offer exactly the choices the computer's Screen Sharing session offers (same
    /// control, same choices), on the Duo and on a normal iPhone; with no Screen Sharing, its ways in.
    func testSameChoicesAsTheSessionForEveryMix() {
        for mix in mixes {
            let e = computer(mix)
            if mix.contains(.screenSharing) {
                XCTAssertEqual(SessionView.choices(for: e, normalPhone: false),
                               SessionView.choices(terminal: e.hasTerminal, jetkvm: JetKVMSettingsProbe.offered(e)), "\(mix) Duo")
                XCTAssertEqual(SessionView.choices(for: e, normalPhone: true),
                               SessionView.normalPhoneChoices(terminal: e.hasTerminal, jetkvm: JetKVMSettingsProbe.offered(e)),
                               "\(mix) iPhone")
            }
            // Every choice belongs to a way in the computer has, and every way in it has is there.
            let ways = Set(SessionView.choices(for: e, normalPhone: false).map(\.way))
            XCTAssertEqual(ways, Set(e.waysInThisBuild), "\(mix)")
            XCTAssertEqual(WayViewSwitch.shows(e), e.waysInThisBuild.count > 1, "\(mix): shown with more than one way in")
        }
    }

    /// Choosing a view opens its way in: Whole Screen and Follow Pointer start Screen Sharing in that view; Terminal
    /// and JetKVM open their own screens. A list icon still opens exactly its way (Screen Sharing in Whole Screen).
    func testChoosingAViewOpensItsWayIn() {
        let nav = ComputerNav.shared
        let saved = (nav.startScreenSharing, nav.endScreenSharing)
        defer { nav.startScreenSharing = saved.0; nav.endScreenSharing = saved.1; nav.close() }
        var started: [SessionView] = []
        nav.startScreenSharing = { _, v in started.append(v) }
        nav.endScreenSharing = {}
        let e = computer([.screenSharing, .terminal, .jetkvm])
        nav.open(e, view: .centred)
        XCTAssertEqual(started, [.centred]); XCTAssertNil(nav.openID)
        nav.open(e, in: .screenSharing)
        XCTAssertEqual(started, [.centred, .regular], "the list's icon: Whole Screen")
        #if DUO_TERMINAL
        nav.open(e, view: .terminal)
        XCTAssertEqual(nav.way, .terminal); XCTAssertEqual(nav.openID, e.id)
        #endif
        #if DUO_JETKVM
        nav.open(e, view: .jetkvm)
        XCTAssertEqual(nav.way, .jetkvm)
        #endif
        // A way in the computer does not have opens nothing.
        nav.close()
        nav.open(computer([.terminal]), view: .regular)
        XCTAssertEqual(started.count, 2); XCTAssertNil(nav.openID)
    }
}

/// The session's JetKVM rule in every build (`JetKVMSettings` exists only with DUO_JETKVM).
@MainActor enum JetKVMSettingsProbe {
    static func offered(_ e: MacEntry) -> Bool {
        #if DUO_JETKVM
        JetKVMSettings.offered(e)
        #else
        false
        #endif
    }
}
