import SwiftUI
import UIKit
import XCTest
@testable import DuoDesktop

/// On the Duo the session's top bar is back, the computer's name as the bar's own title with Apple's title menu for its
/// screens, and the views switch as one trailing item. These run the Duo's bar (`SessionTopRow` without the phone's
/// menu) in a window as wide as this simulator's screen; the open Duo itself cannot be unfolded here.
@MainActor
final class TopBarAppleWayTests: XCTestCase {

    /// The title is the computer's name, short or long; we draw no name pill.
    func testTitleIsTheComputersName() async throws {
        for name in ["Test host", "a-very-long-mac-name-that-cannot-fit"] {
            let bar = try await Self.show(name: name, screen: nil, choices: SessionView.choices(terminal: false))
            defer { bar.window.isHidden = true }
            XCTAssertEqual(bar.item.title, name, "the bar's title is the computer's name")
            XCTAssertNil(bar.frames["name"], "no name pill of ours")
        }
    }

    /// A one-screen computer's title has no menu (an attached menu draws a chevron even with nothing in it); a
    /// multi-screen one keeps it.
    func testOneScreenHasNoTitleMenu() async throws {
        let one = try await Self.show(name: "office-mini", screen: nil, choices: SessionView.choices(terminal: false),
                                     shot: "one-screen")
        defer { one.window.isHidden = true }
        XCTAssertNil(one.item.titleMenuProvider, "one screen: no title menu, so no chevron")
        let many = try await Self.show(name: "office-mini", screen: "Main", choices: SessionView.choices(terminal: false),
                                      shot: "multi-screen")
        defer { many.window.isHidden = true }
        XCTAssertNotNil(many.item.titleMenuProvider, "several screens: the title menu is there")
    }

    /// The Terminal view's bar has the same trailing items as the other views, and no Hide Keyboard.
    func testTerminalBarHasNoHideKeyboard() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        try TopRowTests.needsScreen(atLeast: 402, scene)
        let choices = SessionView.choices(terminal: true, jetkvm: true)
        let term = try await Self.show(name: "basement-mac-mini", screen: nil, choices: choices, view: .terminal,
                                      shot: "terminal")
        defer { term.window.isHidden = true }
        let other = try await Self.show(name: "basement-mac-mini", screen: nil, choices: choices)
        defer { other.window.isHidden = true }
        let terminal = Self.trailing(term.item), others = Self.trailing(other.item)
        print("DUO-TEST trailing items, Terminal: \(terminal), other: \(others)")
        // Accessibility is off in a unit test run, so the items are counted on the bar, not found by identifier.
        XCTAssertEqual(terminal, others, "Terminal: the same trailing items as the other views")
        XCTAssertFalse(terminal.contains("Hide Keyboard"), "no Hide Keyboard")
        XCTAssertNotNil(term.frames["selector"], "the switch is still on the bar")
    }

    /// The title menu offers what the name pill's menu did (`ScreenMenuItems`: All Screens, then each screen).
    func testTitleMenuListsTheScreenChoices() async throws {
        let bar = try await Self.show(name: "Classroom Mac mini", screen: "Studio Display (2)",
                                      choices: SessionView.choices(terminal: false))
        defer { bar.window.isHidden = true }
        let provider = try XCTUnwrap(bar.item.titleMenuProvider, "a multi-screen Mac's title opens a menu")
        let menu = try XCTUnwrap(provider([]))
        let titles = Self.titles(menu)
        print("DUO-TEST title menu: \(titles)")
        // The test's model has no screens of its own, so the pill's menu (the same `ScreenMenuItems`) shows only this.
        XCTAssertEqual(titles, ["All Screens"])
    }

    /// The switch is on the bar with every view the computer has, each with a title for the system's "…".
    func testSwitchHasEveryView() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        // The folded Duo's outer screen lays a bar out its own way (`TopRowTests.needsScreen`).
        try TopRowTests.needsScreen(atLeast: 402, scene)
        for choices in [SessionView.choices(terminal: false), SessionView.choices(terminal: true, jetkvm: true)] {
            let bar = try await Self.show(name: "Test host", screen: nil, choices: choices)
            defer { bar.window.isHidden = true }
            let ids = Set(TopRowTests.all(UIView.self, in: bar.nav).compactMap(\.accessibilityIdentifier))
            let labels = TopRowTests.all(UIView.self, in: bar.nav).compactMap(\.accessibilityLabel)
            for v in choices {
                XCTAssertTrue(ids.contains("sessionView.\(v.rawValue)"), "\(v) on the switch (\(ids))")
                XCTAssertTrue(labels.contains(v.title), "\(v) has its title")
            }
            let sel = try XCTUnwrap(bar.frames["selector"])
            XCTAssertEqual(sel.width, ViewSelector.target * CGFloat(choices.count), accuracy: 0.5, "the whole switch")
            XCTAssertTrue(ids.contains("backToMacs"), "back is there")
        }
    }

    // MARK: - Helpers

    struct Shown { let window: UIWindow; let nav: UINavigationBar; let item: UINavigationItem; let frames: [String: CGRect] }

    static func show(name: String, screen: String?, choices: [SessionView],
                     view: SessionView = .regular, shot: String? = nil) async throws -> Shown {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        if scene.effectiveGeometry.interfaceOrientation.isLandscape { throw XCTSkip("needs the simulator upright") }
        let width = scene.screen.bounds.width
        let log = FramesLog()
        let host = UIHostingController(rootView: NavigationStack {
            Color.black.modifier(SessionTopRow(model: SessionModel(), title: name, notice: nil, hidden: false,
                                               view: .constant(view), leave: {}, preview: (name, screen),
                                               report: { k, f in log.frames[k] = f }, rowWidth: width,
                                               choicesForTest: choices))
        })
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 900)
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(1))
        if let dir = ProcessInfo.processInfo.environment["DUO_BAR_SHOTS"], let shot {
            // Pictures of the Duo bar laid out at this screen's width (TEST_RUNNER_DUO_BAR_SHOTS=<folder>).
            let image = UIGraphicsImageRenderer(bounds: CGRect(x: 0, y: 0, width: width, height: 140)).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try image.pngData()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(shot + ".png"))
        }
        let nav = try XCTUnwrap(TopRowTests.find(UINavigationBar.self, in: host.view))
        let item = try XCTUnwrap(nav.topItem)
        return Shown(window: window, nav: nav, item: item, frames: log.frames)
    }

    /// The bar's trailing items (SwiftUI's toolbar items, as UIKit bar button items).
    static func trailing(_ item: UINavigationItem) -> [String] {
        let groups = item.trailingItemGroups.flatMap(\.barButtonItems)
        let items = groups.isEmpty ? (item.rightBarButtonItems ?? []) : groups
        return items.map { $0.title ?? $0.customView.map { String(describing: type(of: $0)) } ?? "item" }
    }

    static func titles(_ menu: UIMenu) -> [String] {
        menu.children.flatMap { e -> [String] in
            if let m = e as? UIMenu { return titles(m) }
            return [e.title]
        }
    }
}

@MainActor private final class FramesLog { var frames: [String: CGRect] = [:] }
