import SwiftUI
import UIKit
import XCTest
@testable import DuoDesktop

/// The Duo bar's back is our own standard Button (the screen is the root of its own NavigationStack, so there is no
/// system back button) in a toolbar item with Apple's `sharedBackgroundVisibility(.hidden)`. These lay the Duo bar out
/// in a window 669 pt wide (the open Duo) and 402 pt wide, on this simulator; the open Duo itself cannot be unfolded
/// here. Pictures: TEST_RUNNER_DUO_BAR_SHOTS=<folder>.
@MainActor
final class TopBarBareBackTests: XCTestCase {

    enum Kind: String, CaseIterable { case screenSharing = "screen-sharing", terminal, jetkvm, rdp }

    /// Back has no glass of its own; the views switch keeps its bubble on the right.
    func testBackIsBare() async throws {
        for kind in Kind.allCases {
            let left = Flag()
            let bar = try await Self.show(kind, name: "office-mini", width: 669, dark: false, leave: { left.on = true })
            defer { bar.window.isHidden = true }
            let backItem = try XCTUnwrap(Self.leadingItems(bar.item).first, "\(kind): a leading item")
            XCTAssertTrue(backItem.hidesSharedBackground, "\(kind): back draws no glass bubble")
            let trailing = bar.item.trailingItemGroups.flatMap(\.barButtonItems) + (bar.item.rightBarButtonItems ?? [])
            XCTAssertTrue(trailing.contains { !$0.hidesSharedBackground }, "\(kind): the bubble on the right stays")
            // Not proven here: the "Back" label, the 44 pt target and the press. SwiftUI's toolbar button is not a
            // reachable UIKit view in a unit-test run (no customView; identifiers do not reach UIKit views, which is
            // also why TopBarAppleWayTests.testSwitchHasEveryView fails on a 402 pt screen). Needs a UI test.
            _ = left
        }
    }

    /// The pictures: each kind, light and dark, short and long name, at 669 and 402 pt.
    func testPictures() async throws {
        guard ProcessInfo.processInfo.environment["DUO_BAR_SHOTS"] != nil else { throw XCTSkip("no picture folder") }
        for kind in Kind.allCases {
            for dark in [false, true] {
                for (n, name) in [("short", "office-mini"), ("basement", "basement-mac-mini"),
                                  ("long", "basement-mac-mini-in-the-back-office")] {
                    for width in [669, 402] as [CGFloat] {
                        let shot = "\(kind.rawValue)-\(dark ? "dark" : "light")-\(n)-\(Int(width))"
                        let bar = try await Self.show(kind, name: name, width: width, dark: dark, leave: {}, shot: shot)
                        bar.window.isHidden = true
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    @MainActor final class Flag { var on = false }
    struct Shown { let window: UIWindow; let nav: UINavigationBar; let item: UINavigationItem }

    static func leadingItems(_ item: UINavigationItem) -> [UIBarButtonItem] {
        let groups = item.leadingItemGroups.flatMap(\.barButtonItems)
        return groups.isEmpty ? (item.leftBarButtonItems ?? []) : groups
    }

    /// Screen Sharing: the real session bar (`SessionTopRow`). Terminal: the Terminal screen's real bar
    /// (`TerminalTopBar`). JetKVM and Remote Desktop: their screens' Duo bar is `DuoTitleBar` with their second line
    /// and the views switch as the one trailing item (the screens' own bar types are private).
    @ViewBuilder static func bar(_ kind: Kind, name: String, leave: @escaping () -> Void) -> some View {
        let choices = SessionView.choices(terminal: true, jetkvm: true)
        switch kind {
        case .screenSharing:
            Color.black.modifier(SessionTopRow(model: SessionModel(), title: name, notice: nil, hidden: false,
                                               view: .constant(.regular), leave: leave, preview: (name, nil),
                                               report: nil, rowWidth: 669, choicesForTest: choices))
        case .terminal:
            let entry = terminalEntry(name)
            Color.black.modifier(TerminalTopBar(entry: entry, views: WayViewSwitch(entry: entry, current: .terminal,
                                                                                    normalPhone: false, leave: {}),
                                                back: leave))
        case .jetkvm, .rdp:
            let line = kind == .jetkvm ? "JetKVM" : "Remote Desktop"
            Color.black
                .modifier(DuoTitleBar(title: name, subtitle: line, hidden: false, back: leave) { EmptyView() })
                .toolbar {
                    TopBarViewsItem { ViewSelector(view: .constant(.regular), choices: choices) }
                }
        }
    }

    /// A computer with Screen Sharing, Terminal and JetKVM, so the Terminal bar shows the views switch.
    static func terminalEntry(_ name: String) -> MacEntry {
        var e = MacEntry(name: name, tailscale: "\(name).example-tailnet.ts.net")
        e.terminal = true
        e.jetkvm = true
        e.jetkvmAddress = "jetkvm.example-tailnet.ts.net"
        return e
    }

    /// The Terminal screen's real Duo bar holds back, the title and the views switch, and no Hide Keyboard.
    func testTerminalBarHasNoHideKeyboard() async throws {
        let bar = try await Self.show(.terminal, name: "basement-mac-mini", width: 669, dark: false, leave: {})
        defer { bar.window.isHidden = true }
        XCTAssertTrue(WayViewSwitch.shows(Self.terminalEntry("x")), "the test computer has several ways in")
        let trailing = bar.item.trailingItemGroups.flatMap(\.barButtonItems) + (bar.item.rightBarButtonItems ?? [])
        let titles = trailing.compactMap { $0.title ?? $0.accessibilityLabel }
        print("DUO-TEST Terminal trailing items: \(trailing.count) \(titles)")
        XCTAssertFalse(titles.contains("Hide Keyboard"), "no Hide Keyboard on the bar")
        XCTAssertEqual(trailing.filter { !$0.hidesSharedBackground }.count, 1, "one bubble on the right: the switch")
        let all = TopRowTests.all(UIView.self, in: bar.nav)
        XCTAssertFalse(all.contains { $0.accessibilityIdentifier == "hideKeyboard" }, "no Hide Keyboard view")
        XCTAssertFalse(all.contains { $0.accessibilityLabel == "Hide Keyboard" }, "no Hide Keyboard label")
    }

    static func show(_ kind: Kind, name: String, width: CGFloat, dark: Bool, leave: @escaping () -> Void,
                     shot: String? = nil) async throws -> Shown {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        if scene.effectiveGeometry.interfaceOrientation.isLandscape { throw XCTSkip("needs the simulator upright") }
        let host = UIHostingController(rootView: NavigationStack { bar(kind, name: name, leave: leave) })
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.frame = CGRect(x: 0, y: 0, width: width, height: 400)
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(1))
        if let dir = ProcessInfo.processInfo.environment["DUO_BAR_SHOTS"], let shot {
            let image = UIGraphicsImageRenderer(bounds: CGRect(x: 0, y: 0, width: width, height: 120)).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(shot + ".png"))
        }
        let nav = try XCTUnwrap(TopRowTests.find(UINavigationBar.self, in: host.view))
        return Shown(window: window, nav: nav, item: try XCTUnwrap(nav.topItem))
    }
}
