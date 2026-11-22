import GlassActCore
import XCTest
@testable import DuoDesktop

/// M4 (project notes): one test per claim.
final class MultiScreenTests: XCTestCase {
    /// The test host's four fake screens (glassact-testhost --displays), in global points.
    private let four = [
        MacScreen(id: 1, name: "Main", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), isMain: true),
        MacScreen(id: 2, name: "Left 16:10", frame: CGRect(x: -1680, y: 30, width: 1680, height: 1050), isMain: false),
        MacScreen(id: 3, name: "Portrait", frame: CGRect(x: 1960, y: -420, width: 1080, height: 1920), isMain: false),
        MacScreen(id: 4, name: "Top", frame: CGRect(x: 0, y: -1080, width: 1920, height: 1080), isMain: false),
    ]

    /// Claim: the overview places and sizes each screen as on the Mac, inside the area.
    func testOverviewKeepsTheArrangement() {
        let area = CGSize(width: 669, height: 376)
        let r = ScreenOverviewLayout.place(four, in: area, labelHeight: 0)
        let main = r[1]!, left = r[2]!, portrait = r[3]!, top = r[4]!
        let scale = main.width / 1920
        XCTAssertEqual(left.maxX, main.minX, accuracy: 0.01)                        // Left touches Main's left edge
        XCTAssertEqual(left.minY - main.minY, 30 * scale, accuracy: 0.01)           // a little lower
        XCTAssertEqual(portrait.minX - main.maxX, 40 * scale, accuracy: 0.01)       // the 40-point gap
        XCTAssertEqual(top.maxY, main.minY, accuracy: 0.01)                         // Top sits on Main
        XCTAssertEqual(portrait.height / portrait.width, 1920.0 / 1080, accuracy: 0.001)
        XCTAssertEqual(left.width / main.width, 1680.0 / 1920, accuracy: 0.001)
        for rect in r.values { XCTAssertTrue(CGRect(origin: .zero, size: area).contains(rect)) }
    }

    /// Claim: the last screen is remembered per Mac by name and place; renumbered still found; gone → main.
    func testRememberedScreenFallsBackToMain() {
        let defaults = UserDefaults(suiteName: "MultiScreenTests")!
        defaults.removePersistentDomain(forName: "MultiScreenTests")
        RememberedScreen(four[2]).store(mac: "mac-a", in: defaults)
        XCTAssertNil(RememberedScreen.stored(mac: "mac-b", in: defaults))
        let stored = RememberedScreen.stored(mac: "mac-a", in: defaults)
        XCTAssertEqual(RememberedScreen.resolve(stored, in: four)?.id, 3)
        let renumbered = four.map { MacScreen(id: $0.id + 10, name: $0.name, frame: $0.frame, isMain: $0.isMain) }
        XCTAssertEqual(RememberedScreen.resolve(stored, in: renumbered)?.id, 13)
        XCTAssertEqual(RememberedScreen.resolve(stored, in: [four[0], four[1]])?.id, 1)
        XCTAssertEqual(RememberedScreen.resolve(nil, in: four)?.id, 1)
    }

    /// Claim: the Host puts the pointer in the middle of the chosen screen (the point the phone sends).
    func testPointerGoesToTheMiddle() {
        XCTAssertTrue(four[1].middle == (-840, 555))
        XCTAssertTrue(four[3].middle == (960, -540))
    }

    /// Claim (build 4): a switch between two screens of different shape keeps presenting. SwiftUI updated the picture
    /// view with the new size counter but the old size, then with the new size and the same counter (seen in the
    /// simulator log). The view must end at the new size, the only size the library's frames are drawn at.
    @MainActor
    func testSwitchToADifferentShapeKeepsPresenting() {
        let main = TileGrid(width: 1920, height: 1080), left = TileGrid(width: 1680, height: 1050)
        let v = CanvasView(controller: nil, grid: main)
        var last = 1
        v.follow(grid: main, generation: 2, lastGeneration: &last)   // new counter, old size
        v.follow(grid: left, generation: 2, lastGeneration: &last)   // new size, same counter
        XCTAssertEqual(v.drawnGrid, left, "picture view still at the old size: every frame of the new screen skipped")
        v.follow(grid: main, generation: 3, lastGeneration: &last)   // and back (16:10 -> 16:9)
        XCTAssertEqual(v.drawnGrid, main)
    }
}
