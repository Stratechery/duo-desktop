import GlassActCore
import GlassActTransport
import XCTest
@testable import DuoDesktop

/// 
@MainActor
final class OpenStartTests: XCTestCase {
    private var dir: URL!
    private var defaults: UserDefaults!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: "OpenStartTests.\(UUID().uuidString)")
    }

    private func store() -> MacStore {
        let s = MacStore(url: dir.appendingPathComponent("macs.json"), defaults: defaults,
                         knownHosts: KnownHosts(url: dir.appendingPathComponent("known_hosts")))
        // Made-up Macs: the app starts with none (no Mac is built in).
        for name in ["my-mac", "other-mac"] where !s.macs.contains(where: { $0.name == name }) {
            s.add(MacEntry(name: name, tailscale: "\(name).example-tailnet.ts.net"))
        }
        return s
    }

    /// Claim: the open screen starts in Whole Screen even with Follow Pointer stored for that Mac; during the
    /// session (a fold and unfold) the view comes back as it was left; the next connect starts Whole Screen again.
    func testOpenStartIsWholeScreenEvenWithFollowPointerStored() throws {
        let s = store()
        let b = try XCTUnwrap(s.macs.first { $0.name == "other-mac" })
        let model = SessionModel(store: s)
        model.lastMacDefaults = defaults
        model.connect(to: b)
        model.storeView(.centred)
        model.openView = .centred
        model.disconnect()
        model.connect(to: b)
        XCTAssertEqual(model.storedView, .centred, "Follow Pointer is stored for this Mac")
        XCTAssertEqual(model.openView, .regular, "yet the open screen starts in Whole Screen")
        model.openView = .centred           // chosen during the session
        model.phase = .inSession
        XCTAssertEqual(model.openView, .centred, "a fold and unfold keeps the session's view")
        model.disconnect()
    }

    /// Claim: the outer screen's start is unchanged (vertical, its own opening), whatever the open screen uses.
    func testOuterStartUnchanged() {
        SessionModel.app.openView = .centred
        XCTAssertEqual(OuterMode.start, .vertical)
        XCTAssertEqual(CanvasView(controller: nil, grid: TileGrid(width: 1920, height: 1080)).outerMode, .vertical)
        SessionModel.app.openView = .regular
    }

    /// Claim: the open screen's picture after the outer view shows the whole Mac screen fitted: its own canvas
    /// (never the outer one's 1:1 place), not zoomed.
    func testOpenAfterOuterShowsTheFittedPicture() {
        let grid = TileGrid(width: 1920, height: 1080)
        let outer = CanvasView(controller: nil, grid: grid)
        outer.frame = CGRect(x: 0, y: 0, width: 466, height: 644)
        outer.fullWidth = 1920
        outer.outer = true
        outer.layoutIfNeeded()
        XCTAssertEqual(outer.pictureFrame.width, 1920, accuracy: 1, "outer: one Mac pixel per point")
        // Unfolded: the open screen's canvas, made with the session's start view (Whole Screen).
        let open = CanvasView(controller: nil, grid: grid)
        open.frame = CGRect(x: 0, y: 0, width: 590, height: 332)
        open.followPointer = SessionModel.app.openView == .centred
        open.directTouch = true
        open.layoutIfNeeded()
        let f = open.pictureFrame
        XCTAssertEqual(f.width, 590, accuracy: 1)
        XCTAssertEqual(f.height, 332, accuracy: 1)
        XCTAssertEqual(f.minX, 0, accuracy: 1)
        XCTAssertEqual(f.minY, 0, accuracy: 1)
    }
}
