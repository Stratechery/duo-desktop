import XCTest
@testable import DuoDesktop

/// Project notes (computers-m3): the one-line rows with three way-in icons, opening exactly the way in that was tapped,
/// the "open another way" offer and the view switch for every mix.
@MainActor
final class ComputersM3Tests: XCTestCase {
    override func tearDown() async throws {
        ComputerNav.shared.close()
        ComputerNav.shared.startScreenSharing = { _, _ in }
        ComputerNav.shared.endScreenSharing = {}
    }

    /// A computer with the given ways in (made-up addresses).
    private func computer(_ name: String, _ ways: Set<WayIn>) -> MacEntry {
        var e = MacEntry(name: name)
        e.set(.tailscale, "made-up-\(e.id.prefix(4))")
        e.screenSharing = ways.contains(.screenSharing)
        e.terminal = ways.contains(.terminal)
        e.sshUser = "me"
        e.jetkvm = ways.contains(.jetkvm)
        e.jetkvmAddress = ways.contains(.jetkvm) ? "kvm.example.invalid" : nil
        e.kind = e.hasScreenSharing ? nil : .terminal
        return e
    }

    /// Claim (1): every row has the same columns; a way in the computer has is "set up" and its VoiceOver label
    /// opens it; one it does not have is "not set up" (gray) and its label adds it.
    func testIconsSayWhatTheComputerHas() {
        let e = computer("Guest Mac Mini", [.screenSharing])
        let reach = ComputerReach()
        XCTAssertEqual(WayLook.of(e, .screenSharing, mac: .ready, reach: reach), .setUp)
        XCTAssertEqual(WayIconButton.value(.setUp), "")
        for way in WayIn.inThisBuild where way != .screenSharing {
            XCTAssertEqual(WayLook.of(e, way, mac: .ready, reach: reach), .notSetUp)
        }
        XCTAssertEqual(WayIn.terminal.openLabel("Guest Mac Mini"), "Open Guest Mac Mini in Terminal")
        XCTAssertEqual(WayIn.terminal.addLabel("Guest Mac Mini"), "Add Terminal to Guest Mac Mini")
        XCTAssertEqual(Set(WayIn.allCases.map(\.symbol)).count, 3, "three different icons")
    }

    /// Claim (1): "set up but not answering" is its own look, not gray (gray is "not set up"), with words for
    /// VoiceOver; a check still running shows as set up.
    func testNotAnsweringIsItsOwnLook() {
        let e = computer("Guest Mac Mini", [.screenSharing, .terminal, .jetkvm])
        let reach = ComputerReach()
        reach.check = { host, _, _, done in done(host != "kvm.example.invalid") }
        XCTAssertEqual(WayLook.of(e, .screenSharing, mac: .checking, reach: reach), .setUp)
        XCTAssertEqual(WayLook.of(e, .screenSharing, mac: .notReachable, reach: reach), .notAnswering("Not answering"))
        XCTAssertEqual(WayLook.of(e, .screenSharing, mac: .wrongMac, reach: reach),
                       .notAnswering("This isn’t the Mac you added."))
        reach.probeAll([e])
        let answered = expectation(description: "answers")
        DispatchQueue.main.async { answered.fulfill() }
        wait(for: [answered], timeout: 2)
        #if DUO_TERMINAL
        XCTAssertEqual(WayLook.of(e, .terminal, mac: nil, reach: reach), .setUp)
        #endif
        #if DUO_JETKVM
        let look = WayLook.of(e, .jetkvm, mac: nil, reach: reach)
        XCTAssertEqual(look, .notAnswering("Not answering"))
        XCTAssertNotEqual(look, .notSetUp)
        XCTAssertEqual(WayIconButton.value(look), "Not answering")
        #endif
    }

    /// Claim (2): each icon opens exactly its own way in. Terminal and JetKVM open on their own screens and start
    /// no Glass Act session, even on a computer that has Screen Sharing (they end any attempt instead); Screen
    /// Sharing starts the Glass Act session. A way in it does not have opens nothing.
    func testEachIconOpensExactlyItsOwnWayIn() {
        let e = computer("Guest Mac Mini", [.screenSharing, .terminal, .jetkvm])
        var started: [String] = []
        var ended = 0
        ComputerNav.shared.startScreenSharing = { e, _ in started.append(e.id) }
        ComputerNav.shared.endScreenSharing = { ended += 1 }
        for way in WayIn.inThisBuild where way != .screenSharing {
            ComputerNav.shared.open(e, in: way)
            XCTAssertEqual(ComputerNav.shared.way, way)
            XCTAssertEqual(ComputerNav.shared.openID, e.id)
        }
        XCTAssertEqual(started, [], "no Glass Act session for Terminal or JetKVM")
        XCTAssertEqual(ended, WayIn.inThisBuild.count - 1)
        ComputerNav.shared.open(e, in: .screenSharing)
        XCTAssertEqual(started, [e.id])
        XCTAssertNil(ComputerNav.shared.openID, "its own screen closed")
        let ssOnly = computer("Plain Mac", [.screenSharing])
        ComputerNav.shared.open(ssOnly, in: .terminal)
        XCTAssertNil(ComputerNav.shared.way, "a way in it does not have opens nothing")
    }

    /// Claim (2): the waiting/failure screens offer the computer's other ways in, and only those.
    func testOtherWaysOffered() {
        let all = computer("Guest Mac Mini", [.screenSharing, .terminal, .jetkvm])
        XCTAssertEqual(ComputerNav.others(all, than: .screenSharing), WayIn.inThisBuild.filter { $0 != .screenSharing })
        #if DUO_TERMINAL && DUO_JETKVM
        XCTAssertEqual(ComputerNav.others(all, than: .terminal), [.screenSharing, .jetkvm])
        XCTAssertEqual(WayIn.jetkvm.insteadTitle, "Open in JetKVM Instead")
        #endif
        XCTAssertEqual(ComputerNav.others(computer("Lab Server", [.terminal]), than: .terminal), [])
    }

    /// Claim (3): on a Terminal or JetKVM screen the view switch offers the computer's ways in for every mix, and
    /// shows only when there is something to choose.
    func testWaySwitchForEveryMix() {
        let mixes: [Set<WayIn>] = [[.terminal], [.jetkvm], [.terminal, .jetkvm], [.screenSharing, .terminal],
                                   [.screenSharing, .jetkvm], [.screenSharing, .terminal, .jetkvm]]
        for mix in mixes {
            let e = computer("Mix", mix)
            let shown = mix.filter(WayIn.inThisBuild.contains)
            XCTAssertEqual(WayViewSwitch.shows(e), shown.count > 1, "\(mix)")
            XCTAssertEqual(Set(e.waysInThisBuild), shown, "\(mix)")
        }
    }

    /// Claim (1), as changed by project notes (name-opens-default): the footer says what the name, the icons and the (i) do.
    func testFooter() {
        XCTAssertTrue(ListWords.footer.contains("Tap ⓘ for its settings."))
        XCTAssertTrue(ListWords.footer.hasPrefix("Tap a name to open it in its Opens In choice"))
    }
}
