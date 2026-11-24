import SwiftUI
import UIKit
import XCTest
@testable import DuoDesktop

/// Made-up computers like the owner's list; nothing is dialled. Pictures only when `TEST_RUNNER_DUO_SNAPSHOT_DIR` is set
/// (`DUO_SNAPSHOT_PREFIX` names them, e.g. "before-").
@MainActor
final class ListRowSpacingTests: XCTestCase {
    // MARK: the owner's kind of list

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

    static var computers: [MacEntry] {
        var nas = terminalOnly("NAS Box"); nas.unameSystem = .linux
        var towerPC = terminalOnly("Tower PC"); towerPC.remoteDesktop = true
        let unknown = terminalOnly("New Server")
        return [mac("Office Mac Mini", jetkvm: true), mac("Classroom Mac Mini", jetkvm: false),
                mac("MacBook Air", jetkvm: false), nas, mac("Lounge Mac Mini", jetkvm: true),
                towerPC, unknown]
    }

    static func row(_ e: MacEntry) -> ComputerListRow {
        ComputerListRow(entry: e, columns: WayIn.inThisBuild,
                        look: { e.opens($0) ? .setUp : .notSetUp }, light: .reachable,
                        openDefault: {}, settings: {}, open: { _ in }, add: { _ in })
    }

    // MARK: Claims

    /// The row's right-hand part is the light, five 44 pt columns and one 8 pt gap: the name gets the rest. At the
    /// open Duo's width and a normal iPhone's the row stays one line, and every row is the same width whatever its
    /// system, so the columns line up.
    func testRowsStayOneLineAndLineUp() {
        for w: CGFloat in [402, 669] {
            let rowWidth = w - 2 * 20 - 28
            var heights: [CGFloat] = []
            for e in Self.computers {
                let size = UIHostingController(rootView: Self.row(e))
                    .sizeThatFits(in: CGSize(width: rowWidth, height: .greatestFiniteMagnitude))
                heights.append(size.height)
                XCTAssertLessThanOrEqual(size.height, 50, "\(e.name) at \(w)")
            }
        }
        let widths = Self.computers.map {
            UIHostingController(rootView: Self.row($0).fixedSize()).sizeThatFits(in: CGSize(width: 2000, height: 200)).width
                - ($0.name as NSString).size(withAttributes: [.font: UIFont.preferredFont(forTextStyle: .body)]).width
        }
        XCTAssertLessThan((widths.max() ?? 0) - (widths.min() ?? 0), 1, "\(widths)")
    }

    /// Part 2: every JetKVM candidate is a real SF Symbol in this Xcode's set.
    func testJetKVMCandidatesResolve() {
        for c in Self.jetkvmCandidates { XCTAssertNotNil(UIImage(systemName: c.symbol), c.symbol) }
    }

    // MARK: Pictures

    static func render<V: View>(_ view: V, _ size: CGSize, _ style: UIUserInterfaceStyle, scale: CGFloat = 3,
                                to name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["DUO_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_DUO_SNAPSHOT_DIR to render")
        }
        let prefix = ProcessInfo.processInfo.environment["DUO_SNAPSHOT_PREFIX"] ?? ""
        let host = UIHostingController(rootView: view.frame(width: size.width, height: size.height))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.overrideUserInterfaceStyle = style
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        window.rootViewController!.addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = true
        host.view.frame = CGRect(origin: .zero, size: size)
        window.rootViewController!.view.addSubview(host.view)
        host.didMove(toParent: window.rootViewController)
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
            host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: dir + "/" + prefix + name))
        window.isHidden = true
    }

    static func styleName(_ s: UIUserInterfaceStyle) -> String { s == .dark ? "dark" : "light" }

    /// The list as in the owner's screenshot: title, seven computers, the footer.
    func testRenderList() throws {
        for w: CGFloat in [402, 669] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let view = VStack(alignment: .leading, spacing: 0) {
                    Text("Computers").font(.largeTitle.bold()).padding(.leading, 20).padding(.top, 12)
                    List {
                        Section {
                            ForEach(Self.computers, id: \.id) { e in
                                Self.row(e).listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 8))
                            }
                        } footer: { Text(ListWords.footer) }
                    }
                    .listStyle(.insetGrouped)
                }
                .background(Color(.systemGroupedBackground))
                try Self.render(view, CGSize(width: w, height: 560), style,
                                to: "list-\(Int(w))pt-\(Self.styleName(style)).png")
            }
        }
    }

    // MARK: Part 2: JetKVM candidates (pictures only; the app keeps cable.connector)

    struct Candidate { let symbol: String; let why: String }
    static let jetkvmCandidates: [Candidate] = [
        .init(symbol: "cable.connector", why: "today: the upright plug"),
        .init(symbol: "cable.connector.horizontal", why: "the plug lying sideways"),
        .init(symbol: "keyboard", why: "keyboard, video, mouse"),
        .init(symbol: "keyboard.macwindow", why: "a window over a keyboard"),
        .init(symbol: "mediastick", why: "a small stick plugged into HDMI"),
        .init(symbol: "cable.connector.video", why: "a video cable's plug"),
    ]

    /// A row as the list draws it, with `jetkvm` in the JetKVM column (the app's own pieces).
    struct CandidateRow: View {
        let name: String
        let jetkvm: String
        let has: Bool
        var body: some View {
            HStack(spacing: ComputerListRow.columnGap) {
                HStack(spacing: 10) {
                    ComputerLightView(light: .reachable, name: name)
                    Text(name).lineLimit(1)
                    Spacer(minLength: 0)
                }
                ComputerSystemWord(system: .mac).padding(.horizontal, ComputerListRow.wordGap)
                WayIconButton(way: .screenSharing, name: name, look: .setUp) {}
                WayIconButton(way: .terminal, name: name, look: .setUp) {}
                WayIconButton(way: .jetkvm, name: name, look: has ? .setUp : .notSetUp, symbol: jetkvm) {}
                InfoColumn()
            }
        }
    }

    struct InfoColumn: View {
        var body: some View {
            Image(systemName: "info.circle").font(.title3).foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
        }
    }

    func testRenderJetKVMCandidates() throws {
        let found = Self.jetkvmCandidates.filter { UIImage(systemName: $0.symbol) != nil }
        for style in [UIUserInterfaceStyle.light, .dark] {
            let view = List {
                ForEach(found, id: \.symbol) { c in
                    Section {
                        CandidateRow(name: "Office Mac Mini", jetkvm: c.symbol, has: true)
                        CandidateRow(name: "Classroom Mac Mini", jetkvm: c.symbol, has: false)
                    } header: {
                        Text("\(c.symbol) — \(c.why)").textCase(nil)
                    }
                    .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 8))
                }
            }
            .listStyle(.insetGrouped)
            .environment(\.defaultMinListRowHeight, 44)
            .background(Color(.systemGroupedBackground))
            try Self.render(view, CGSize(width: 669, height: CGFloat(found.count) * 140 + 40), style,
                            to: "jetkvm-candidates-\(Self.styleName(style)).png")
        }
    }

    // MARK: Part 3: the system as gray words (pictures only; not in the app)

    enum Variant: String, CaseIterable {
        case a = "A-symbols", bFootnote = "B-text-column", bCaption = "B-text-column-caption",
             c = "C-second-line", dSame = "D-after-name", dSmaller = "D-after-name-callout"
        var label: String {
            switch self {
            case .a: "A: the app's row (now the gray word)"
            case .bFootnote: "B: gray word column, .footnote"
            case .bCaption: "B: gray word column, .caption"
            case .c: "C: second line, .subheadline"
            case .dSame: "D: after the name, same size (.body)"
            case .dSmaller: "D: after the name, one step smaller (.callout)"
            }
        }
    }

    static func word(_ s: ComputerSystem?) -> String {
        switch s { case .mac: "macOS"; case .windows: "Windows"; case .linux: "Linux"; case nil: "" }
    }

    /// The row with the system as words in place of the mark. The icons and (i) are the app's own, in the same
    /// columns as A.
    struct WordsRow: View {
        let entry: MacEntry
        let variant: Variant
        var word: String { ListRowSpacingTests.word(entry.system) }

        var body: some View {
            HStack(spacing: ComputerListRow.columnGap) {
                HStack(spacing: 10) {
                    ComputerLightView(light: .reachable, name: entry.name)
                    name
                }
                if variant == .bFootnote || variant == .bCaption {
                    let font: Font = variant == .bFootnote ? .footnote : .caption
                    // As wide as the longest word; the words end at one edge just left of the icons.
                    ZStack(alignment: .trailing) {
                        ForEach(["macOS", "Windows", "Linux"], id: \.self) { Text($0).font(font).hidden() }
                        Text(word).font(font).foregroundStyle(.secondary)
                    }
                    .lineLimit(1).fixedSize()
                    .padding(.horizontal, ComputerListRow.wordGap)
                }
                ForEach(WayIn.inThisBuild) { way in
                    WayIconButton(way: way, name: entry.name, look: entry.opens(way) ? .setUp : .notSetUp,
                                  symbol: entry.symbol(way)) {}
                }
                InfoColumn()
            }
        }

        @ViewBuilder var name: some View {
            switch variant {
            case .c:
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name).lineLimit(1)
                    if !word.isEmpty { Text(word).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            case .dSame, .dSmaller:
                // The name keeps its room (layout priority); the gray word gets what is left, and drops whole
                // rather than ending in "…" when it does not fit.
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(entry.name).lineLimit(1).layoutPriority(1)
                    ViewThatFits(in: .horizontal) {
                        Text(word).font(variant == .dSame ? .body : .callout).foregroundStyle(.secondary)
                            .lineLimit(1).fixedSize()
                        Color.clear.frame(width: 0, height: 0)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                Text(entry.name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder static func variantRows(_ v: Variant) -> some View {
        ForEach(computers, id: \.id) { e in
            Group {
                if v == .a { row(e) } else { WordsRow(entry: e, variant: v) }
            }
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 8))
        }
    }

    func testRenderSystemVariants() throws {
        for w: CGFloat in [402, 669] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                for v in Variant.allCases {
                    let view = List {
                        Section { Self.variantRows(v) } header: { Text(v.label).textCase(nil) }
                    }
                    .listStyle(.insetGrouped)
                    .background(Color(.systemGroupedBackground))
                    try Self.render(view, CGSize(width: w, height: 470), style,
                                    to: "system-\(v.rawValue)-\(Int(w))-\(Self.styleName(style)).png")
                }
            }
            let sheet = List {
                ForEach([Variant.a, .bFootnote, .c, .dSmaller], id: \.self) { v in
                    Section { Self.variantRows(v) } header: { Text(v.label).textCase(nil) }
                }
            }
            .listStyle(.insetGrouped)
            .background(Color(.systemGroupedBackground))
            try Self.render(sheet, CGSize(width: w, height: 1640), .light, scale: 2,
                            to: "system-compare-\(Int(w))-light.png")
        }
    }

    /// The largest standard text size (xxxLarge) on a normal iPhone, A as built and B, and one accessibility size.
    func testRenderLargestText() throws {
        for (size, tag) in [(DynamicTypeSize.xxxLarge, "xxxLarge"), (.accessibility1, "accessibility1")] {
            for v in [Variant.a, .bFootnote, .dSmaller] {
                let view = List {
                    Section { Self.variantRows(v) } header: { Text("\(v.label), \(tag)").textCase(nil) }
                }
                .listStyle(.insetGrouped)
                .background(Color(.systemGroupedBackground))
                .environment(\.dynamicTypeSize, size)
                try Self.render(view, CGSize(width: 402, height: 820), .light,
                                to: "largest-text-\(tag)-\(v.rawValue)-402-light.png")
            }
        }
    }
}
