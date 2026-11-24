import SwiftUI
import UIKit
import XCTest
@testable import DuoDesktop

/// The Duo's bar has Apple's two-line title. Top line the computer's name, bottom line what is shown (the Mac's screen,
/// "Terminal", "JetKVM"); a problem notice takes the bottom line while it lasts. One bar, changed in place, so the
/// tests also see the line follow a new screen or view.
@MainActor
final class TopBarSecondLineTests: XCTestCase {

    /// The rule: the screen's name in a Screen Sharing view, "Terminal" and "JetKVM" in theirs.
    func testSecondLineIsWhatIsShown() {
        XCTAssertEqual(SessionTopRow.shownLine(view: .regular, screen: "JetKVM v1"), "JetKVM v1")
        XCTAssertEqual(SessionTopRow.shownLine(view: .centred, screen: "All Screens"), "All Screens")
        XCTAssertEqual(SessionTopRow.shownLine(view: .regular, screen: nil), "Screen Sharing",
                       "a one-screen Mac: the way in's name")
        #if DUO_TERMINAL
        XCTAssertEqual(SessionTopRow.shownLine(view: .terminal, screen: "JetKVM v1"), "Terminal")
        #endif
        #if DUO_JETKVM
        XCTAssertEqual(SessionTopRow.shownLine(view: .jetkvm, screen: "JetKVM v1"), "JetKVM")
        #endif
    }

    /// On the bar itself: the subtitle is the screen, follows a new screen (as picked from the title menu) and each
    /// view, and a notice takes the line, then gives it back.
    func testBarSubtitleFollowsScreenViewAndNotice() async throws {
        let bar = try await Self.show(name: "office-mini", screen: "JetKVM v1")
        defer { bar.window.isHidden = true }
        let item = bar.item
        XCTAssertEqual(item.title, "office-mini", "top line: the computer's name")
        try await Self.expect(item, "JetKVM v1", "a screen's name under the name")
        XCTAssertNotNil(item.titleMenuProvider, "the title menu stays")

        bar.state.screen = "Studio Display (2)"
        try await Self.expect(item, "Studio Display (2)", "another screen picked: the line changes")
        bar.state.screen = "All Screens"
        try await Self.expect(item, "All Screens", "All Screens picked")

        #if DUO_TERMINAL
        bar.state.view = .terminal
        try await Self.expect(item, "Terminal", "Terminal view")
        #endif
        #if DUO_JETKVM
        bar.state.view = .jetkvm
        try await Self.expect(item, "JetKVM", "JetKVM view")
        #endif
        bar.state.view = .regular

        bar.state.notice = "This Mac switched to another user"
        try await Self.expect(item, "This Mac switched to another user", "a notice takes the line")
        bar.state.notice = nil
        try await Self.expect(item, "All Screens", "the notice gone: the screen comes back")
    }

    /// A one-screen Mac: "Screen Sharing" on the second line; a notice still shows.
    func testOneScreenOneLineNoticeStillShows() async throws {
        let bar = try await Self.show(name: "office-mini", screen: nil)
        defer { bar.window.isHidden = true }
        try await Self.expect(bar.item, "Screen Sharing", "one screen: the way in's name")
        bar.state.notice = "This Mac is locked"
        try await Self.expect(bar.item, "This Mac is locked", "the notice shows")
    }

    /// Pictures (TEST_RUNNER_DUO_BAR_SHOTS=<folder>): short and long name, each view, with and without the
    /// investigation's stand-in (120 pt pinned at the bar's right, room taken as Live Activities would).
    func testPictures() async throws {
        guard let dir = ProcessInfo.processInfo.environment["DUO_BAR_SHOTS"] else { throw XCTSkip("no folder set") }
        var views: [(String, SessionView)] = [("whole", .regular)]
        #if DUO_TERMINAL
        views.append(("terminal", .terminal))
        #endif
        #if DUO_JETKVM
        views.append(("jetkvm", .jetkvm))
        #endif
        for (nameTag, name) in [("short", "office-mini"), ("long", "Classroom Mac mini of the studio")] {
            for standIn in [CGFloat(0), 120] {
                for (viewTag, view) in views {
                    let bar = try await Self.show(name: name, screen: "JetKVM v1", view: view, standIn: standIn)
                    let shot = "\(nameTag)-\(viewTag)-\(standIn > 0 ? "standin120" : "no-standin")"
                    try Self.picture(bar.window, to: dir, shot)
                    print("DUO-TEST \(shot): title \(bar.item.title ?? "-"), subtitle \(bar.item.subtitle ?? "-"), " +
                          "trailing \(TopBarAppleWayTests.trailing(bar.item))")
                    bar.window.isHidden = true
                }
            }
        }
        let notice = try await Self.show(name: "office-mini", screen: "JetKVM v1")
        notice.state.notice = "This Mac switched to another user"
        try await Task.sleep(for: .milliseconds(500))
        try Self.picture(notice.window, to: dir, "short-notice-no-standin")
        notice.window.isHidden = true
    }

    // MARK: - Helpers

    @Observable final class BarState {
        var screen: String?
        var view: SessionView
        var notice: String?
        init(screen: String?, view: SessionView) { self.screen = screen; self.view = view }
    }

    private struct ChangingBar: View {
        let name: String
        @Bindable var state: BarState
        let choices: [SessionView]
        let standIn: CGFloat
        var body: some View {
            NavigationStack {
                Color.black.modifier(SessionTopRow(model: SessionModel(), title: name, notice: state.notice,
                                                   hidden: false, view: $state.view, leave: {},
                                                   preview: (name, state.screen), choicesForTest: choices,
                                                   standIn: standIn))
            }
        }
    }

    struct Shown { let window: UIWindow; let item: UINavigationItem; let state: BarState }

    static func show(name: String, screen: String?, view: SessionView = .regular,
                     standIn: CGFloat = 0) async throws -> Shown {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        if scene.effectiveGeometry.interfaceOrientation.isLandscape { throw XCTSkip("needs the simulator upright") }
        let width = scene.screen.bounds.width
        let state = BarState(screen: screen, view: view)
        let host = UIHostingController(rootView: ChangingBar(name: name, state: state,
                                                             choices: SessionView.choices(terminal: true, jetkvm: true),
                                                             standIn: standIn))
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: width, height: 900)
        window.rootViewController = host
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(1))
        let nav = try XCTUnwrap(TopRowTests.find(UINavigationBar.self, in: host.view))
        return Shown(window: window, item: try XCTUnwrap(nav.topItem), state: state)
    }

    /// The item's second line as UIKit holds it (plain or attributed; empty counts as none).
    static func subtitle(_ item: UINavigationItem) -> String? {
        let s = item.subtitle ?? item.attributedSubtitle.map { String($0.characters) }
        return (s?.isEmpty ?? true) ? nil : s
    }

    static func expect(_ item: UINavigationItem, _ want: String?, _ why: String) async throws {
        for _ in 0..<20 where subtitle(item) != want { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertEqual(subtitle(item), want, why)
    }

    static func picture(_ window: UIWindow, to dir: String, _ shot: String) throws {
        let image = UIGraphicsImageRenderer(bounds: CGRect(x: 0, y: 0, width: window.bounds.width, height: 140))
            .image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        try image.pngData()?.write(to: URL(fileURLWithPath: dir).appendingPathComponent(shot + ".png"))
    }
}
