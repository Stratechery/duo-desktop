import SwiftUI
import UIKit
import XCTest
@testable import DuoDesktop

/// Every session kind's bar on a normal iPhone is the Duo's (`DuoTitleBar`): the bare back caret, the computer's name
/// over the second line as Apple's own title, and the views as one drop-down bubble at the right. The broken bar drew
/// the name in a leading bubble too narrow for it, so the text ran over the back caret and the views bubble.
@MainActor
final class NormalIPhoneTopBarTests: XCTestCase {

    enum Kind: String, CaseIterable { case screenSharing, terminal, jetkvm, remoteDesktop }

    static let names = ["Mac", "basement-mac-mini", "Guest Mac Studio in the Basement"]   // the last is 31 characters

    /// The computer each kind is shown for: one with every way in its kind allows, so the views control is there.
    static func entry(_ kind: Kind, name: String) -> MacEntry {
        var e = MacEntry(name: name)
        e.set(.tailscale, "192.0.2.60")
        e.terminal = true
        e.sshUser = "guest"
        e.jetkvm = true
        e.jetkvmAddress = "192.0.2.61"
        if kind == .remoteDesktop {
            e.screenSharing = false
            e.remoteDesktop = true
            e.kind = .terminal
        } else {
            e.screenSharing = true
        }
        return e
    }

    /// The backdrop each kind's screen states for its bar.
    static func behind(_ kind: Kind) -> BarBackdrop {
        switch kind {
        case .screenSharing: return SessionTopRow.behind
        case .terminal:
            #if DUO_TERMINAL
            return TerminalTopBar.behind
            #else
            return .app
            #endif
        case .jetkvm:
            #if DUO_JETKVM
            return JetKVMTopBar.behind
            #else
            return .app
            #endif
        case .remoteDesktop:
            #if DUO_RDP
            return RDPTopBar.behind
            #else
            return .app
            #endif
        }
    }

    private struct Bar: View {
        let kind: Kind
        let name: String
        let normalPhone: Bool
        @State private var view = SessionView.centred

        var body: some View {
            NavigationStack { content }
        }

        @ViewBuilder private var content: some View {
            let e = NormalIPhoneTopBarTests.entry(kind, name: name)
            // What each real screen paints under its bar, upright: the backdrop it states (`BarBackdrop`), the same
            // value the screen itself paints and hands its bar.
            let screen = Color.black.background(NormalIPhoneTopBarTests.behind(kind).colour)
            switch kind {
            case .screenSharing:
                screen.modifier(SessionTopRow(model: SessionModel(), title: name, notice: nil, hidden: false,
                                              view: $view, leave: {}, preview: (name, nil),
                                              choicesForTest: SessionView.choices(terminal: true, jetkvm: true)
                                                  .filter { !normalPhone || $0 != .regular },
                                              viewMenu: normalPhone))
            case .terminal:
                #if DUO_TERMINAL
                screen.modifier(TerminalTopBar(entry: e, views: WayViewSwitch(entry: e, current: .terminal,
                                                                              normalPhone: normalPhone, leave: {}),
                                               back: {}))
                #else
                screen
                #endif
            case .jetkvm:
                #if DUO_JETKVM
                screen.modifier(JetKVMTopBar(entry: e, views: WayViewSwitch(entry: e, current: .jetkvm,
                                                                            normalPhone: normalPhone, leave: {}),
                                             normalPhone: normalPhone, hidden: false, back: {}))
                #else
                screen
                #endif
            case .remoteDesktop:
                #if DUO_RDP
                screen.modifier(RDPTopBar(entry: e, normalPhone: normalPhone, hidden: false, view: $view, back: {}))
                #else
                screen
                #endif
            }
        }
    }

    struct Shown { let window: UIWindow; let nav: UINavigationBar }

    static func show(_ kind: Kind, name: String, normalPhone: Bool, width: CGFloat,
                     style: UIUserInterfaceStyle) async throws -> Shown {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        if scene.effectiveGeometry.interfaceOrientation.isLandscape { throw XCTSkip("needs the simulator upright") }
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = style
        window.frame = CGRect(x: 0, y: 0, width: width, height: 400)
        window.rootViewController = UIHostingController(rootView: Bar(kind: kind, name: name, normalPhone: normalPhone))
        window.makeKeyAndVisible()
        try await Task.sleep(for: .milliseconds(800))
        return Shown(window: window, nav: try XCTUnwrap(TopRowTests.find(UINavigationBar.self, in: window)))
    }

    /// The title's drawn label (the name), in window points.
    static func title(_ name: String, in nav: UINavigationBar) -> CGRect? {
        TopBarOneScreenSecondLineTests.all(UILabel.self, in: nav)
            .first { !$0.isHidden && $0.text == name }
            .map { $0.convert($0.bounds, to: nil) }
    }

    /// Fails on the broken layout: the name must be the bar's own title and must not touch the back item or the
    /// views item; no bubble of its own (the broken bar's name bubble, drawn too narrow, made the third).
    func testTitleNeverOverlapsBackOrViews() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let width = scene.screen.bounds.width
        guard width < 500 else { throw XCTSkip("needs a normal iPhone simulator (screen \(width) pt)") }
        var ran = 0
        for kind in Kind.allCases {
            for name in Self.names {
                let bar = try await Self.show(kind, name: name, normalPhone: true, width: width, style: .light)
                defer { bar.window.isHidden = true }
                guard bar.nav.topItem?.title == name else {
                    // A build without this kind's code draws no bar for it.
                    continue
                }
                ran += 1
                let what = "\(kind) '\(name)'"
                // The bar's item platters: back's (drawn bare, `sharedBackgroundVisibility(.hidden)`) and the views'.
                // The broken bar had three: back, a name bubble too narrow for its text, the views.
                let items = TopRowTests.barGlass(in: bar.nav).filter { $0.minY < 140 }.sorted { $0.minX < $1.minX }
                let label = try XCTUnwrap(Self.title(name, in: bar.nav), "\(what): the name is the bar's own title")
                print("DUO-TEST normal-iphone bar \(what): title \(label) items \(items)")
                XCTAssertEqual(items.count, 2, "\(what): back and the views, no name bubble")
                for item in items {
                    XCTAssertFalse(label.intersects(item), "\(what): the title \(label) overlaps an item \(item)")
                }
                if let back = items.first { XCTAssertLessThan(back.maxX, label.minX, "\(what): back is left of the name") }
                if let views = items.last { XCTAssertGreaterThan(views.minX, label.maxX, "\(what): the views are right of the name") }
            }
        }
        XCTAssertGreaterThan(ran, 0)
    }

    /// The normal iPhone's views control lists every view that computer has, each with its symbol and name, the
    /// current one ticked; the button shows the current view's symbol.
    func testDropDownListsEveryView() {
        let choices = SessionView.normalPhoneChoices(terminal: true, jetkvm: true)
        let items = ViewMenuButton.items(choices: choices, current: .centred)
        XCTAssertEqual(items.map(\.view), choices)
        XCTAssertEqual(items.filter(\.checked).map(\.view), [.centred])
        XCTAssertEqual(items.map(\.symbol), choices.map(\.systemImage))
        XCTAssertEqual(ViewMenuButton.shown(choices: choices, current: .centred), .centred)
    }

    /// Pictures (TEST_RUNNER_DUO_BAR_SHOTS=<folder>): every kind, the three names, light and dark, at this
    /// simulator's width (normal iPhone) and at the open Duo's 669 pt (its own bar, to show it did not change).
    func testPictures() async throws {
        guard let dir = ProcessInfo.processInfo.environment["DUO_BAR_SHOTS"] else { throw XCTSkip("no folder set") }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let phoneWidth = scene.screen.bounds.width
        for (form, width, phone) in [("iphone", phoneWidth, true), ("duo-669", 669, false)] as [(String, CGFloat, Bool)] {
            for kind in Kind.allCases {
                for (n, name) in Self.names.enumerated() {
                    for (look, style) in [("light", UIUserInterfaceStyle.light), ("dark", .dark)] {
                        let bar = try await Self.show(kind, name: name, normalPhone: phone, width: width, style: style)
                        try TopBarSecondLineTests.picture(bar.window, to: dir,
                                                          "\(form)-\(kind.rawValue)-name\(n + 1)-\(look)")
                        bar.window.isHidden = true
                    }
                }
            }
        }
    }
}
