import SwiftUI
import UIKit
import XCTest
@testable import DuoDesktop

/// Project notes (session-top-bar-narrow-first) (2026-11-23, the owner: "Ok on the bar fix"): the session top bar starts narrow (back,
/// the name, one view button) and widens to the full switch only once it has seen the wide form shown whole.
///
/// The probe tests lay out the SYSTEM's own navigation bar in a window as wide as this simulator's screen, with
/// `TopBarStandIn` taking room at the right the way the live activities beside the clock do on the owner's phone. Stand-in
/// 0 is the bare simulator; 54 is the 467 -> 413 pt difference measured between the bare open simulator and the owner's
/// screenshots. The simulator here is not the unfolded Duo (no tool can unfold it), so the widths are this screen's;
/// the project's own check covers the unfolded simulator (project notes).
@MainActor
final class TopBarNarrowFirstTests: XCTestCase {

    /// RULE: the steps never end on a folded form while a smaller one is left, the wide form is tried once, and a
    /// fold always steps down (wide -> narrow -> floor), never up.
    func testRuleStepsDownOnAFoldAndTriesWideOnce() {
        XCTAssertEqual(TopBarFit.next(after: .narrow, folded: false, tried: false), .wide, "narrow whole: try wide")
        XCTAssertNil(TopBarFit.next(after: .narrow, folded: false, tried: true), "tried once: stay narrow")
        XCTAssertNil(TopBarFit.next(after: .wide, folded: false, tried: true), "wide whole: stay wide")
        XCTAssertEqual(TopBarFit.next(after: .wide, folded: true, tried: true), .narrow, "wide folded: back to narrow")
        XCTAssertEqual(TopBarFit.next(after: .narrow, folded: true, tried: true), .floor, "narrow folded: name floor")
        XCTAssertNil(TopBarFit.next(after: .floor, folded: true, tried: true), "floor: nothing smaller")
        XCTAssertNil(TopBarFit.next(after: .floor, folded: false, tried: false), "floor never widens")
    }

    /// RULE (real system bar, the session's row and the Terminal screen's shape): with short and long names, three-way
    /// (four views) and two-way, Screen Sharing and Terminal (three views) computers, bare and with the stand-in: once settled the bar is never
    /// folded into "…"; it is wide exactly when the wide form was seen whole, else one view button.
    func testNeverEllipsisWideWhenItFitsOneButtonWhenNot() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        if scene.effectiveGeometry.interfaceOrientation.isLandscape { throw XCTSkip("needs the simulator upright") }
        let width = scene.screen.bounds.width
        var widened = 0, stayedNarrow = 0
        for standIn: CGFloat in [0, 54] {
            for name in ["Studio Mac", "Guest's Mac mini"] {
                for choices in [SessionView.choices(terminal: true, jetkvm: true), SessionView.choices(terminal: true, jetkvm: false)] {
                    for terminalShape in [false, true] {
                        let fit = TopBarFit()
                        let parts = TopRowPartsLog()
                        let probe = NarrowFirstProbe(fit: fit, parts: parts, name: name, choices: choices,
                                                     standIn: standIn, rowWidth: width, hideKeyboard: terminalShape)
                        let host = UIHostingController(rootView: probe)
                        let window = UIWindow(windowScene: scene)
                        window.frame = CGRect(x: 0, y: 0, width: width, height: scene.screen.bounds.height)
                        window.rootViewController = host
                        window.makeKeyAndVisible()
                        for _ in 0..<40 where !fit.settled { try await Task.sleep(for: .milliseconds(50)) }
                        try await Task.sleep(for: .milliseconds(300))
                        let what = "\(name), \(choices.count) views, stand-in \(standIn), \(terminalShape ? "Terminal" : "session")"
                        let nPartsWhole = terminalShape ? 4 : 3
                        let bar = try XCTUnwrap(Self.find(UINavigationBar.self, in: host.view), what)
                        print("DUO-TEST narrow-first \(what): form \(fit.form), log \(fit.log), bar alpha \(bar.alpha)")
                        XCTAssertTrue(fit.settled, "\(what): settled")
                        XCTAssertEqual(bar.alpha, 1, "\(what): the bar is shown after the try")
                        XCTAssertFalse(TopBarFold.folded(rowWidth: width, parts: nPartsWhole), "\(what): never \"…\"")
                        XCTAssertNotNil(parts.frames["back"], "\(what): back shows")
                        XCTAssertEqual(fit.log.first, "narrow", "\(what): narrow first")
                        XCTAssertEqual(fit.log.last, "whole", "\(what): last seen whole")
                        XCTAssertLessThanOrEqual(fit.log.filter { $0 == "wide" }.count, 1, "\(what): one try at most")
                        if fit.wide {
                            widened += 1
                            XCTAssertEqual(fit.log.suffix(1), ["whole"], "\(what): wide only when seen whole")
                            XCTAssertEqual(try XCTUnwrap(parts.frames["views"], what).width,
                                           ViewSelector.target * CGFloat(choices.count), accuracy: 0.5, "\(what): full switch")
                        } else {
                            stayedNarrow += 1
                            // Narrow only after the wide try folded; the floor only after the narrow form folded.
                            let joined = fit.log.joined(separator: " ")
                            XCTAssertTrue(joined.contains("wide folded narrow") || joined.contains("narrow folded floor"),
                                          "\(what): stepped down only after a fold (\(joined))")
                            XCTAssertLessThan(try XCTUnwrap(parts.frames["views"], what).width, 60, "\(what): one view button")
                        }
                        window.isHidden = true
                    }
                }
            }
        }
        print("DUO-TEST narrow-first: \(widened) wide, \(stayedNarrow) narrow or floor")
    }

    static func find<T: UIView>(_ type: T.Type, in view: UIView) -> T? {
        if let v = view as? T { return v }
        for s in view.subviews { if let v = find(type, in: s) { return v } }
        return nil
    }
}

@MainActor private final class TopRowPartsLog { var frames: [String: CGRect] = [:] }

/// The session's real row (`SessionTopRow`) or, with `hideKeyboard`, the Terminal screen's shape (back, the name,
/// `WayViewSwitch`'s control, Hide Keyboard) on the same `NarrowFirstBar`; the JetKVM screen's bar has the
/// session's shape (back, the name, the views).
private struct NarrowFirstProbe: View {
    let fit: TopBarFit
    let parts: TopRowPartsLog
    let name: String
    let choices: [SessionView]
    let standIn: CGFloat
    let rowWidth: CGFloat
    let hideKeyboard: Bool
    @State private var view: SessionView = .regular

    var body: some View {
        NavigationStack {
            if hideKeyboard {
                Color.black
                    .navigationTitle(name)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        TopBarItem { BackToMacsButton(action: {}).onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { parts.frames["back"] = $0 } }
                        ToolbarSpacer(.fixed, placement: .topBarLeading)
                        TopBarItem { TopRowName(mac: name, screen: "Terminal", notice: nil, maxWidth: fit.nameMax) }
                        ToolbarItem(placement: .principal) { Color.clear.frame(width: 0, height: 0) }
                            .sharedBackgroundVisibility(.hidden)
                        ToolbarSpacer(.fixed, placement: .topBarLeading)
                        TopBarItem {
                            ViewSwitch(view: $view, choices: choices,
                                       usesMenu: WayViewSwitch.usesMenu(normalPhone: false, wide: fit.wide))
                                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .global) }) { parts.frames["views"] = $0 }
                        }
                        ToolbarSpacer(.fixed, placement: .topBarLeading)
                        TopBarItem {
                            Label("Hide Keyboard", systemImage: "keyboard.chevron.compact.down").labelStyle(.iconOnly)
                                .frame(width: TopRow.itemContent, height: TopRow.itemContent)
                        }
                        TopBarStandIn(width: standIn)
                    }
                    .modifier(NarrowFirstBar(fit: fit, rowWidth: rowWidth, parts: 4, hidden: false, enabled: true,
                                             canWiden: true))
            } else {
                Color.black
                    .modifier(SessionTopRow(model: SessionModel(), title: name, notice: nil, hidden: false,
                                            view: $view, leave: {}, preview: (name, nil),
                                            report: { k, f in parts.frames[k == "selector" ? "views" : k] = f },
                                            rowWidth: rowWidth, choicesForTest: choices, fit: fit,
                                            standIn: standIn, widenAnyWidth: true))
            }
        }
    }
}
