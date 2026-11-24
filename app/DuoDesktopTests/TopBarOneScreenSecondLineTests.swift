import SwiftUI
import UIKit
import XCTest
@testable import DuoDesktop

/// Every session bar has a second line; a PC looks like a PC in the list; a PC's remove message says what this iPhone
/// really forgets.
@MainActor
final class TopBarOneScreenSecondLineTests: XCTestCase {

    // MARK: 1. The second line, by computer and view

    func testSecondLineByComputerAndView() {
        // A one-screen Mac (no screen name), both Screen Sharing views: the way in's name.
        XCTAssertEqual(SessionTopRow.shownLine(view: .regular, screen: nil), "Screen Sharing")
        XCTAssertEqual(SessionTopRow.shownLine(view: .centred, screen: nil), "Screen Sharing")
        // A multi-screen Mac whose screen has no name yet: the same, not an empty line.
        XCTAssertEqual(SessionTopRow.shownLine(view: .regular, screen: ""), "Screen Sharing")
        // A multi-screen Mac keeps its screen's name (and All Screens).
        XCTAssertEqual(SessionTopRow.shownLine(view: .regular, screen: "Main"), "Main")
        XCTAssertEqual(SessionTopRow.shownLine(view: .centred, screen: "All Screens"), "All Screens")
        #if DUO_TERMINAL
        XCTAssertEqual(SessionTopRow.shownLine(view: .terminal, screen: nil), "Terminal")
        XCTAssertEqual(SessionTopRow.shownLine(view: .terminal, screen: "Main"), "Terminal")
        #endif
        #if DUO_JETKVM
        XCTAssertEqual(SessionTopRow.shownLine(view: .jetkvm, screen: nil), "JetKVM")
        XCTAssertEqual(SessionTopRow.shownLine(view: .jetkvm, screen: "Main"), "JetKVM")
        #endif
        // The words are the app's own: the list's name for the way in.
        XCTAssertEqual(SessionTopRow.shownLine(view: .regular, screen: nil), WayIn.screenSharing.label)
    }

    /// On a live bar: a one-screen Mac shows "Screen Sharing" under its name, with no title menu (no arrow).
    func testOneScreenBarHasSecondLineAndNoMenu() async throws {
        let bar = try await TopBarSecondLineTests.show(name: "One Screen Mac", screen: nil)
        defer { bar.window.isHidden = true }
        XCTAssertEqual(bar.item.title, "One Screen Mac")
        try await TopBarSecondLineTests.expect(bar.item, "Screen Sharing", "one-screen Mac: second line")
        XCTAssertNil(bar.item.titleMenuProvider, "no menu, so no arrow")
    }

    // MARK: 2. What a tap on the title opens

    /// Apple's title menu: UIKit's `titleMenuProvider` is "a menu that is displayed from the title". What takes a tap
    /// at the centre of the name's text, of the arrow, and of the second line. Found on iOS 27.2: the name and the
    /// arrow are one system title control that shows the menu on a tap (`showsMenuAsPrimaryAction`); the second line
    /// (Apple's subtitle view) sits outside that control, so a tap there opens nothing. That is Apple's layout; we
    /// leave it (no title of our own).
    func testNameAndArrowAreOneMenuTarget() async throws {
        let bar = try await TopBarSecondLineTests.show(name: "office-mini", screen: "Main")
        defer { bar.window.isHidden = true }
        let nav = try XCTUnwrap(TopRowTests.find(UINavigationBar.self, in: bar.window))
        XCTAssertNotNil(bar.item.titleMenuProvider)
        nav.layoutIfNeeded()
        func hit(_ v: UIView) throws -> UIView {
            try XCTUnwrap(nav.hitTest(v.convert(CGPoint(x: v.bounds.midX, y: v.bounds.midY), to: nav), with: nil))
        }
        let labels = Self.all(UILabel.self, in: nav)
        let name = try XCTUnwrap(labels.first { $0.text == "office-mini" && !$0.isHidden }, "name label")
        let line = try XCTUnwrap(labels.first { $0.text == "Main" && !$0.isHidden }, "second line label")
        let nameHit = try hit(name)
        let lineHit = try hit(line)
        print("DUO-TEST name hit: \(Self.chain(nameHit))")
        print("DUO-TEST line hit: \(Self.chain(lineHit))")
        let control = try XCTUnwrap(Self.menuOwner(nameHit) as? UIControl, "a tap on the name's text reaches the menu")
        XCTAssertTrue(control.showsMenuAsPrimaryAction, "one tap opens it (not a long press)")
        let arrow = try XCTUnwrap(Self.all(UIImageView.self, in: control).first { !$0.isHidden && $0.bounds.width > 0 },
                                  "the arrow is inside the same control")
        XCTAssertTrue(Self.menuOwner(try hit(arrow)) === control, "a tap on the arrow: the same control")
        print("DUO-TEST title control \(type(of: control)) frame \(control.convert(control.bounds, to: nav)); " +
              "name \(name.convert(name.bounds, to: nav)); arrow \(arrow.convert(arrow.bounds, to: nav)); " +
              "second line \(line.convert(line.bounds, to: nav))")
        XCTAssertFalse(Self.menuOwner(lineHit) === control,
                       "Apple's second line is outside the title control (recorded, not ours)")
    }

    // MARK: 3. A PC in the list

    static func pc(jetkvm: Bool = false, terminal: Bool = false) -> MacEntry {
        var e = MacEntry(name: "Test PC")
        e.screenSharing = false
        e.remoteDesktop = true
        e.rdpUser = "tester"
        e.home = "example-pc"
        e.terminal = terminal
        e.jetkvm = jetkvm
        return e
    }

    func testRowSymbolByKind() {
        let mac = MacEntry(name: "Mac").carriedOver()
        let pc = Self.pc()
        XCTAssertEqual(mac.symbol(.screenSharing), "display", "a Mac: its screen, as before")
        // The PC's mark is its own.
        XCTAssertEqual(pc.symbol(.screenSharing), "display", "a PC: the same screen as a Mac")
        for way in [WayIn.terminal, .jetkvm] {
            XCTAssertEqual(pc.symbol(way), mac.symbol(way), "\(way): the same icon on both")
        }
        // A computer with neither: the gray add icon stays the screen.
        var none = MacEntry(name: "SSH box")
        none.screenSharing = false
        none.terminal = true
        XCTAssertEqual(none.symbol(.screenSharing), "display")
    }

    func testPCRemoveMessage() {
        let pc = Self.pc()
        let here = RemoveMacAlert.message(pc, asksWhere: false)
        XCTAssertEqual(here, "This iPhone forgets its trust in the PC’s certificate. The PC is not changed.")
        let both = RemoveMacAlert.message(pc, asksWhere: true)
        XCTAssertTrue(both.hasPrefix("All Devices removes it from every iPhone using your iCloud."),
                      "the iCloud words only when the buttons ask where")
        XCTAssertTrue(both.hasSuffix("This iPhone forgets its trust in the PC’s certificate. The PC is not changed."))
        for text in [here, both] {
            XCTAssertFalse(text.contains("password"), "no PC password is saved")
            XCTAssertFalse(text.contains("Mac"), text)
        }
        XCTAssertEqual(RemoveMacAlert.message(Self.pc(jetkvm: true, terminal: true), asksWhere: false),
                       "This iPhone forgets its trust in the PC’s certificate, the JetKVM password and the Terminal’s trusted keys. The PC is not changed.")
        // A Mac's message is unchanged.
        XCTAssertEqual(RemoveMacAlert.message(MacEntry(name: "Mac").carriedOver(), asksWhere: false),
                       "Its key and settings are deleted from this iPhone. The Mac is not changed.")
    }

    // MARK: Pictures

    /// Pictures (TEST_RUNNER_DUO_BAR_SHOTS=<folder>): the session bar for a one-screen and a multi-screen Mac, as the
    /// Duo draws it and as a normal iPhone draws it (its name bubble and view menu), at this simulator's width.
    func testPictures() async throws {
        guard let dir = ProcessInfo.processInfo.environment["DUO_BAR_SHOTS"] else { throw XCTSkip("no folder set") }
        for (tag, screen) in [("one-screen", nil), ("multi-screen", "Main")] as [(String, String?)] {
            for phone in [false, true] {
                let window = try await Self.showBar(name: tag == "one-screen" ? "One Screen Mac" : "office-mini",
                                                    screen: screen, normalPhone: phone)
                try TopBarSecondLineTests.picture(window, to: dir, "\(phone ? "phone" : "duo-bar")-\(tag)")
                window.isHidden = true
            }
        }
    }

    private struct Bar: View {
        let name: String
        let screen: String?
        let normalPhone: Bool
        @State private var view = SessionView.regular
        var body: some View {
            NavigationStack {
                Color.black.modifier(SessionTopRow(model: SessionModel(), title: name, notice: nil, hidden: false,
                                                   view: $view, leave: {}, preview: (name, screen),
                                                   choicesForTest: normalPhone ? nil : SessionView.choices(terminal: true, jetkvm: true),
                                                   fixedChoices: normalPhone ? [.regular, .centred] : nil,
                                                   viewMenu: normalPhone))
            }
        }
    }

    static func showBar(name: String, screen: String?, normalPhone: Bool) async throws -> UIWindow {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: scene.screen.bounds.width, height: 900)
        window.rootViewController = UIHostingController(rootView: Bar(name: name, screen: screen, normalPhone: normalPhone))
        window.makeKeyAndVisible()
        try await Task.sleep(for: .seconds(1))
        return window
    }

    // MARK: - Helpers

    static func all<T: UIView>(_ type: T.Type, in view: UIView) -> [T] {
        ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { all(type, in: $0) }
    }

    /// The nearest view from `v` up that carries a menu: a control showing a menu, or a context-menu interaction.
    static func menuOwner(_ v: UIView) -> UIView? {
        var cur: UIView? = v
        while let c = cur {
            if let control = c as? UIControl, control.showsMenuAsPrimaryAction || control.isContextMenuInteractionEnabled { return c }
            if c.interactions.contains(where: { $0 is UIContextMenuInteraction }) { return c }
            if c is UINavigationBar { return nil }
            cur = c.superview
        }
        return nil
    }

    static func chain(_ v: UIView) -> String {
        var parts: [String] = []
        var cur: UIView? = v
        while let c = cur, !(c is UINavigationBar) {
            let menu = (c as? UIControl).map { "ctl menu=\($0.showsMenuAsPrimaryAction)/\($0.isContextMenuInteractionEnabled)" } ?? ""
            let inter = c.interactions.map { String(describing: type(of: $0)) }.joined(separator: ",")
            parts.append("\(type(of: c))[\(menu) \(inter)]")
            cur = c.superview
        }
        return parts.joined(separator: " < ")
    }
}
