import SwiftUI
import UIKit
import XCTest
@testable import DuoDesktop

/// Made-up computers only; nothing is dialled. Pictures only when `TEST_RUNNER_DUO_SNAPSHOT_DIR` is set.
@MainActor
final class ListSystemWordTests: XCTestCase {
    // MARK: Made-up computers

    private static func mac(_ name: String, jetkvm: Bool) -> MacEntry {
        var e = MacEntry(name: name)
        e.set(.tailscale, "made-up.invalid")
        e.screenSharing = true
        e.terminal = true
        e.jetkvm = jetkvm
        e.jetkvmAddress = jetkvm ? "kvm.invalid" : nil
        return e
    }

    private static func terminalOnly(_ name: String) -> MacEntry {
        var e = MacEntry(name: name)
        e.set(.tailscale, "box.invalid")
        e.screenSharing = false
        e.terminal = true
        e.kind = .terminal
        return e
    }

    private static func pc(_ name: String) -> MacEntry {
        var e = terminalOnly(name); e.remoteDesktop = true; return e
    }

    /// Seven computers, each name as long as one of the owner's (15, 18, 11, 7, 15, 14, 8 letters).
    static var computers: [MacEntry] {
        var lantern = terminalOnly("Lantern"); lantern.unameSystem = .linux
        return [mac("Garden Mac Mini", jetkvm: true), mac("Bookshelf Mac Mini", jetkvm: false),
                mac("MacBook Air", jetkvm: false), lantern, mac("Studio Mac Mini", jetkvm: true),
                mac("Attic Mac Mini", jetkvm: false), pc("Ironwood")]
    }

    static func row(_ e: MacEntry) -> ComputerListRow {
        ComputerListRow(entry: e, columns: WayIn.inThisBuild,
                        look: { e.opens($0) ? .setUp : .notSetUp }, light: .reachable,
                        openDefault: {}, settings: {}, open: { _ in }, add: { _ in })
    }

    // MARK: Measuring

    @MainActor final class Seen { var shown = false }

    /// Lays the row out at `width` in a real window and reads whether its word was laid out.
    private func wordShown(_ e: MacEntry, width: CGFloat, size: DynamicTypeSize = .large) throws -> Bool {
        let seen = Seen()
        let view = Self.row(e).frame(width: width).environment(\.dynamicTypeSize, size)
            .onPreferenceChange(SystemWordShown.self) { v in MainActor.assumeIsolated { seen.shown = v } }
        let host = UIHostingController(rootView: view)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = host
        window.frame = CGRect(x: 0, y: 0, width: width + 40, height: 300)
        window.makeKeyAndVisible()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        host.view.layoutIfNeeded()
        window.isHidden = true
        return seen.shown
    }

    /// The whole one-line row's ideal width with the word (the whole name, the word, the icons), and without.
    private static func idealWidths(_ e: MacEntry, size: DynamicTypeSize = .large) -> (withWord: CGFloat, without: CGFloat) {
        let big = CGSize(width: 3000, height: 300)
        let with = UIHostingController(rootView: row(e).fixedSize().environment(\.dynamicTypeSize, size))
            .sizeThatFits(in: big).width
        let word = UIHostingController(rootView: ComputerSystemWord(system: e.system)
            .environment(\.dynamicTypeSize, size)).sizeThatFits(in: big).width + 2 * ComputerListRow.wordGap
        return (with, with - word)
    }

    private static func height(_ e: MacEntry, width: CGFloat) -> CGFloat {
        UIHostingController(rootView: row(e)).sizeThatFits(in: CGSize(width: width, height: 1000)).height
    }

    // MARK: Claims

    /// The word shows when the whole name and the word both fit; just short of that the word is gone and the name is
    /// whole (the row is at least as wide as the whole name plus the icons); only narrower still is the name shortened,
    /// and then the word is still gone.
    func testWordDropsBeforeTheNameIsShortened() throws {
        let e = Self.mac("Studio Mac Mini", jetkvm: true)
        let (w1, w0) = Self.idealWidths(e)
        XCTAssertGreaterThan(w1 - w0, 40, "the word column has room of its own")
        XCTAssertTrue(try wordShown(e, width: w1 + 1), "room for both: the word shows")
        let between = (w0 + w1) / 2
        XCTAssertFalse(try wordShown(e, width: between), "the word drops whole first")
        XCTAssertGreaterThanOrEqual(between, w0, "and the name is whole: the row fits it without the word")
        XCTAssertLessThanOrEqual(Self.height(e, width: between), 50, "still one line")
        let narrow = w0 - 30
        XCTAssertFalse(try wordShown(e, width: narrow), "the name is shortened only with the word already gone")
        XCTAssertLessThanOrEqual(Self.height(e, width: narrow), 50, "one line, the name ending in …")
    }

    /// Per row, at the open Duo's width and a normal iPhone's: the word shows exactly when the whole name fits with it.
    func testEachRowDecidesFromItsOwnRoom() throws {
        for w: CGFloat in [402, 669] {
            let rowWidth = w - 2 * 20 - 28
            for e in Self.computers {
                let fits = Self.idealWidths(e).withWord <= rowWidth
                XCTAssertEqual(try wordShown(e, width: rowWidth), fits, "\(e.name) at \(w)")
            }
        }
        // At the open Duo's width every made-up computer shows its word.
        for e in Self.computers { XCTAssertTrue(try wordShown(e, width: 669 - 2 * 20 - 28), e.name) }
    }

    /// An unknown system shows no word (its column is empty).
    func testUnknownSystemHasNoWord() throws {
        let e = Self.terminalOnly("New Server")
        XCTAssertNil(e.system)
        XCTAssertFalse(try wordShown(e, width: 600))
    }

    /// The words themselves, and VoiceOver reads the system once, with the name.
    func testWordsAndVoiceOver() {
        XCTAssertEqual(ComputerSystem.allCases.map(\.word), ["macOS", "Windows", "Linux"])
        XCTAssertEqual(ComputerSystem.windows.spoken, "Windows PC")
    }

    /// No symbol-mark assets remain.
    func testNoSymbolMarkAssets() {
        XCTAssertNil(UIImage(named: "os-windows"))
        XCTAssertNil(UIImage(named: "os-linux"))
    }

    /// JetKVM's symbol is SF Symbols' `mediastick` in every place that draws it: the list icon (and the "Open in …
    /// Instead" buttons, both via `MacEntry.symbol`), the Duo's selector and the normal iPhone's drop-down (both via
    /// `SessionView.systemImage`).
    func testJetKVMIsTheHDMIStick() {
        XCTAssertEqual(WayIn.jetkvm.symbol, "mediastick")
        XCTAssertNotNil(UIImage(systemName: "mediastick"))
        XCTAssertEqual(Self.mac("X", jetkvm: true).symbol(.jetkvm), "mediastick")
        #if DUO_JETKVM
        XCTAssertEqual(SessionView.jetkvm.systemImage, "mediastick")
        let items = ViewMenuButton.items(choices: SessionView.normalPhoneChoices(terminal: false, jetkvm: true),
                                         current: .jetkvm)
        XCTAssertEqual(items.first { $0.view == .jetkvm }?.symbol, "mediastick")
        #endif
    }

    // MARK: Pictures

    private func listView(_ rows: [MacEntry], header: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Computers").font(.largeTitle.bold()).padding(.leading, 20).padding(.top, 12)
            List {
                Section {
                    ForEach(rows, id: \.id) { e in
                        Self.row(e).listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 8))
                    }
                } header: {
                    if let header { Text(header).textCase(nil) }
                } footer: { Text(ListWords.footer) }
            }
            .listStyle(.insetGrouped)
        }
        .background(Color(.systemGroupedBackground))
    }

    func testRenderList() throws {
        for w: CGFloat in [402, 669] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                try ListRowSpacingTests.render(listView(Self.computers), CGSize(width: w, height: 560), style,
                                               to: "list-\(Int(w))pt-\(ListRowSpacingTests.styleName(style)).png")
            }
        }
    }

    /// A long name: the word has dropped and the name is whole; a longer one: even the name is shortened.
    func testRenderLongNames() throws {
        var office = Self.pc("Upstairs Office PC")
        office.terminalSystem = .windows
        let dropped = [office, Self.mac("Garden Mac Mini", jetkvm: true)]
        try ListRowSpacingTests.render(listView(dropped, header: "Word dropped, name whole"),
                                       CGSize(width: 402, height: 300), .light, to: "long-name-word-dropped-402-light.png")
        let longer = [Self.mac("Downstairs Office Mac Mini Pro", jetkvm: true), Self.mac("Garden Mac Mini", jetkvm: true)]
        try ListRowSpacingTests.render(listView(longer, header: "Word gone, then the name shortened"),
                                       CGSize(width: 402, height: 300), .light, to: "long-name-shortened-402-light.png")
    }

    /// The largest standard text size and an accessibility size on a normal iPhone.
    func testRenderLargeText() throws {
        for (size, tag) in [(DynamicTypeSize.xxxLarge, "xxxLarge"), (.accessibility1, "accessibility1")] {
            try ListRowSpacingTests.render(listView(Self.computers).environment(\.dynamicTypeSize, size),
                                           CGSize(width: 402, height: 900), .light, to: "large-text-\(tag)-402-light.png")
        }
    }

    #if DUO_JETKVM && DUO_TERMINAL
    /// The Duo's four-across selector with JetKVM chosen (orange circle, white stick) and with it not chosen, and the
    /// normal iPhone's drop-down rows (the menu's own Labels, drawn as a list: the open system menu cannot be drawn
    /// in a unit test).
    func testRenderSelectorAndDropDown() throws {
        let four = SessionView.choices(terminal: true, jetkvm: true)
        for style in [UIUserInterfaceStyle.light, .dark] {
            let selector = VStack(spacing: 16) {
                ViewSelector(view: .constant(.jetkvm), choices: four)
                ViewSelector(view: .constant(.regular), choices: four)
            }
            .padding(20).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color(.systemBackground))
            try ListRowSpacingTests.render(selector, CGSize(width: 260, height: 200), style,
                                           to: "duo-selector-\(ListRowSpacingTests.styleName(style)).png")
            let items = ViewMenuButton.items(choices: SessionView.normalPhoneChoices(terminal: true, jetkvm: true),
                                             current: .jetkvm)
            let menu = List {
                ForEach(items, id: \.view) { i in
                    HStack {
                        Image(systemName: "checkmark").opacity(i.checked ? 1 : 0)
                        Label(i.title, systemImage: i.symbol)
                    }
                }
            }
            .listStyle(.insetGrouped)
            try ListRowSpacingTests.render(menu, CGSize(width: 320, height: 240), style,
                                           to: "iphone-dropdown-\(ListRowSpacingTests.styleName(style)).png")
        }
    }
    #endif
}
