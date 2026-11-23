import SwiftUI
import UIKit
import XCTest
@testable import DuoDesktop

/// Project notes (name-opens-default) 1: the row (light, name, three icons, (i)) stays one line at every width the app runs at:
/// a normal iPhone (402 pt), the folded Duo's open-screen layout (466 pt) and the open Duo (669 pt). The simulator on
/// the test Mac runs only the Duo and cannot unfold it, so the row is measured, and pictured, in a window of each
/// width. Pictures only when `TEST_RUNNER_DUO_SNAPSHOT_DIR` is set.
@MainActor
final class ListRowWidthTests: XCTestCase {
    private static let widths: [CGFloat] = [402, 466, 669]

    private func entry(_ name: String, _ ways: Set<WayIn>) -> MacEntry {
        var e = MacEntry(name: name)
        e.set(.tailscale, "made-up")
        e.screenSharing = ways.contains(.screenSharing)
        e.terminal = ways.contains(.terminal)
        e.jetkvm = ways.contains(.jetkvm)
        e.jetkvmAddress = ways.contains(.jetkvm) ? "kvm.example.invalid" : nil
        e.kind = e.hasScreenSharing ? nil : .terminal
        return e
    }

    private var rows: [(MacEntry, ComputerLight)] {
        [(entry("Guest Mac Mini", [.screenSharing, .terminal, .jetkvm]), .reachable),
         (entry("Studio Mac", [.screenSharing]), .needsSignIn("sign in needed")),
         (entry("Guest’s Windows Gaming PC in the Basement", [.jetkvm]), .notReachable),
         (entry("New Mac", [.screenSharing]), .notChecked)]
    }

    private func row(_ e: MacEntry, _ light: ComputerLight) -> ComputerListRow {
        ComputerListRow(entry: e, columns: WayIn.inThisBuild,
                        look: { e.opens($0) ? .setUp : .notSetUp }, light: light,
                        openDefault: {}, settings: {}, open: { _ in }, add: { _ in })
    }

    /// One line: each row is no taller than its 44 pt touch targets (plus a little), even with a long name, at
    /// every width. The row's width is the screen less the inset-grouped list's margins and the row's insets.
    func testRowIsOneLineAtEveryWidth() {
        for w in Self.widths {
            let rowWidth = w - 2 * 20 - 28
            for (e, light) in rows {
                let host = UIHostingController(rootView: row(e, light))
                let size = host.sizeThatFits(in: CGSize(width: rowWidth, height: .greatestFiniteMagnitude))
                XCTAssertLessThanOrEqual(size.height, 50, "\(e.name) at \(w) pt: \(size)")
                XCTAssertLessThanOrEqual(size.width, rowWidth + 0.5, "\(e.name) at \(w) pt")
            }
        }
    }

    /// Pictures of the real list rows at each width, light and dark (for looking at; the screenshots on the Duo
    /// simulator are in a private test script).
    func testRenderRows() throws {
        guard let dir = ProcessInfo.processInfo.environment["DUO_SNAPSHOT_DIR"] else {
            throw XCTSkip("set TEST_RUNNER_DUO_SNAPSHOT_DIR to render")
        }
        for w in Self.widths {
            for style in [UIUserInterfaceStyle.light, .dark] {
                let size = CGSize(width: w, height: 400)
                let view = List {
                    Section {
                        ForEach(self.rows, id: \.0.id) { e, light in
                            self.row(e, light).listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 8))
                        }
                    } footer: {
                        Text(ListWords.footer)
                    }
                }
                .listStyle(.insetGrouped)
                .frame(width: size.width, height: size.height)
                let host = UIHostingController(rootView: view)
                let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
                let window = UIWindow(windowScene: scene)
                window.frame = CGRect(origin: .zero, size: size)
                window.windowLevel = .alert + 1
                window.overrideUserInterfaceStyle = style
                window.rootViewController = host
                window.makeKeyAndVisible()
                host.view.frame = CGRect(origin: .zero, size: size)
                RunLoop.main.run(until: Date().addingTimeInterval(1.0))
                host.view.layoutIfNeeded()
                let format = UIGraphicsImageRendererFormat()
                format.scale = 3
                let image = UIGraphicsImageRenderer(size: size, format: format).image { _ in
                    host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
                }
                let name = "rows-\(Int(w))pt-\(style == .dark ? "dark" : "light").png"
                try XCTUnwrap(image.pngData()).write(to: URL(fileURLWithPath: dir + "/" + name))
                window.isHidden = true
            }
        }
    }
}
