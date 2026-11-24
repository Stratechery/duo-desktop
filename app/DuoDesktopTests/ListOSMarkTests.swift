import SwiftUI
import UIKit
import XCTest
@testable import DuoDesktop

/// One test per claim; made-up computers only, nothing is dialled. Pictures only when `TEST_RUNNER_DUO_SNAPSHOT_DIR`
/// is set.
@MainActor
final class ListOSMarkTests: XCTestCase {
    private static func mac() -> MacEntry {
        var e = MacEntry(name: "Studio Mac")
        e.set(.tailscale, "studio.invalid")
        e.screenSharing = true
        e.terminal = true
        return e
    }

    private static func pc() -> MacEntry {
        var e = MacEntry(name: "Tower PC")
        e.set(.tailscale, "tower-pc.invalid")
        e.screenSharing = false
        e.remoteDesktop = true
        e.terminal = true
        e.kind = .terminal
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

    // MARK: Rule 3, in order

    func testGlassActIsAMac() {
        XCTAssertEqual(Self.mac().system, .mac)
        var m = Self.mac(); m.unameSystem = .linux; m.terminalSystem = .windows
        XCTAssertEqual(m.system, .mac, "Glass Act Host comes first")
    }

    func testRemoteDesktopOrAWindowsServerIsAPC() {
        XCTAssertEqual(Self.pc().system, .windows, "Remote Desktop, server not seen yet")
        var t = Self.terminalOnly("Lab"); t.terminalSystem = .windows
        XCTAssertEqual(t.system, .windows, "the SSH first line named Windows")
        var linuxRDP = Self.pc(); linuxRDP.terminalSystem = .other
        XCTAssertNil(linuxRDP.system, "the server said it is not Windows, and it has not answered uname: no guess")
        linuxRDP.unameSystem = .linux
        XCTAssertEqual(linuxRDP.system, .linux)
    }

    func testUnameAnswerOtherwise() {
        var t = Self.terminalOnly("Pi")
        XCTAssertNil(t.system, "not known yet: no mark")
        XCTAssertTrue(t.asksSystem)
        t.terminalSystem = .other
        XCTAssertTrue(t.asksSystem)
        t.unameSystem = ComputerSystem.fromUname("Linux\n")
        XCTAssertEqual(t.system, .linux)
        XCTAssertFalse(t.asksSystem, "asked once")
        XCTAssertEqual(ComputerSystem.fromUname("Darwin\n"), .mac)
        XCTAssertEqual(ComputerSystem.fromUname("Last login: today\nDarwin\r\n"), .mac)
        XCTAssertNil(ComputerSystem.fromUname("FreeBSD\n"))
        XCTAssertNil(ComputerSystem.fromUname(""))
        var w = Self.terminalOnly("PC"); w.terminalSystem = .windows
        XCTAssertFalse(w.asksSystem, "a Windows server has no uname")
        XCTAssertFalse(Self.mac().asksSystem)
    }

    func testUnameAnswerIsSyncedInItsOwnField() throws {
        var e = Self.terminalOnly("Pi"); e.unameSystem = .linux
        let c = CloudComputer(editedAt: Date(timeIntervalSince1970: 1), computer: SyncedComputer(e))
        let fields = try XCTUnwrap(CloudComputerSync.fields(c))
        XCTAssertNotNil(fields[CloudComputerSync.unameSystemField])
        XCTAssertFalse(String(decoding: fields[CloudComputerSync.payloadField]!, as: UTF8.self).contains("unameSystem"))
        var other = Self.terminalOnly("Pi")
        CloudComputerSync.decode(fields.mapValues { Optional($0) })?.computer?.apply(to: &other)
        XCTAssertEqual(other.unameSystem, .linux)
        var older = fields; older[CloudComputerSync.unameSystemField] = nil
        var mine = Self.terminalOnly("Pi"); mine.unameSystem = .mac
        CloudComputerSync.decode(older.mapValues { Optional($0) })?.computer?.apply(to: &mine)
        XCTAssertEqual(mine.unameSystem, .mac, "a record only an older build saved keeps this iPhone's answer")
    }

    // MARK: Rule 1: the same screen symbol

    func testScreenSymbolIsTheSameForAMacAndAPC() {
        XCTAssertEqual(Self.mac().symbol(.screenSharing), Self.pc().symbol(.screenSharing))
        XCTAssertEqual(Self.pc().symbol(.screenSharing), WayIn.screenSharing.symbol)
    }

    // MARK: Rule 2: the system's column is the same width in every row

    func testWordColumnIsOneWidth() {
        let widths = ([nil] + ComputerSystem.allCases.map { Optional($0) }).map { s -> CGFloat in
            UIHostingController(rootView: ComputerSystemWord(system: s)).sizeThatFits(in: CGSize(width: 500, height: 500)).width
        }
        XCTAssertEqual(Set(widths).count, 1, "\(widths)")
    }

    func testIconsLineUpInEveryRow() {
        // The same computer as each system, and unknown: the row's own width does not change, so the icons and the
        // (i), laid out from the trailing edge, sit in the same place in every row.
        let widths = ([nil] + ComputerSystem.allCases.map { Optional($0) }).map { s -> CGFloat in
            var e = Self.terminalOnly("Same Name")
            e.unameSystem = s == .windows ? nil : s
            if s == .windows { e.terminalSystem = .windows }
            XCTAssertEqual(e.system, s)
            return UIHostingController(rootView: Self.row(e, .reachable).fixedSize())
                .sizeThatFits(in: CGSize(width: 1000, height: 200)).width
        }
        XCTAssertEqual(Set(widths).count, 1, "\(widths)")
    }

    func testVoiceOverReadsTheSystemWithTheName() {
        XCTAssertEqual(ComputerSystem.windows.spoken, "Windows PC")
        XCTAssertEqual(ComputerSystem.mac.spoken, "Mac")
        XCTAssertEqual(ComputerSystem.linux.spoken, "Linux")
    }

    // MARK: Pictures

    private static var rows: [(MacEntry, ComputerLight)] {
        var pi = terminalOnly("Garage Pi"); pi.unameSystem = .linux; pi.jetkvm = true; pi.jetkvmAddress = "kvm.invalid"
        let unknown = terminalOnly("New Server")
        return [(mac(), .reachable), (pc(), .reachable), (pi, .notReachable), (unknown, .notChecked)]
    }

    private static func row(_ e: MacEntry, _ light: ComputerLight) -> ComputerListRow {
        ComputerListRow(entry: e, columns: WayIn.inThisBuild,
                        look: { e.opens($0) ? .setUp : .notSetUp }, light: light,
                        openDefault: {}, settings: {}, open: { _ in }, add: { _ in })
    }

    private func render<V: View>(_ view: V, _ size: CGSize, _ style: UIUserInterfaceStyle, scale: CGFloat,
                                 to name: String) throws {
        guard let dir = ProcessInfo.processInfo.environment["DUO_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_DUO_SNAPSHOT_DIR to render")
        }
        let host = UIHostingController(rootView: view.frame(width: size.width, height: size.height))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        // A window wider than the simulator's screen is drawn shifted; the host is laid out at its own size inside
        // a plain container view instead, and only it is drawn.
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
        try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: dir + "/" + name))
        window.isHidden = true
    }

    func testRenderList() throws {
        for w: CGFloat in [402, 669] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let view = VStack(alignment: .leading, spacing: 0) {
                    Text("Computers").font(.largeTitle.bold()).padding(.leading, 20).padding(.top, 12)
                    List {
                        Section {
                            ForEach(Self.rows, id: \.0.id) { e, light in
                                Self.row(e, light).listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 8))
                            }
                        } footer: { Text(ListWords.footer) }
                    }
                    .listStyle(.insetGrouped)
                }
                .background(Color(.systemGroupedBackground))
                try render(view, CGSize(width: w, height: 520), style, scale: 3,
                           to: "list-\(Int(w))pt-\(style == .dark ? "dark" : "light").png")
            }
        }
    }

    func testRenderZoomedRows() throws {
        for (e, light) in Self.rows {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let view = Self.row(e, light).padding(.horizontal, 12)
                    .background(Color(.secondarySystemGroupedBackground))
                let slug = e.system?.rawValue ?? "unknown"
                try render(view, CGSize(width: 402, height: 56), style, scale: 6,
                           to: "row-\(slug)-\(style == .dark ? "dark" : "light").png")
            }
        }
    }
}
