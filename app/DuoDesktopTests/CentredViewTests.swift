import XCTest
@testable import DuoDesktop

/// Zoomed views part 1 (project notes): the centred view's viewport, its
/// follow and clamp, the touch mapping in the zoomed picture at both stream sizes, and the per-Mac switch.
final class CentredViewTests: XCTestCase {
    /// The owner's upright picture frame (669 x 376 pt at 3x).
    let bounds = CGSize(width: 669, height: 376)
    let scale: CGFloat = 3

    /// The zoomed frame and the canvas part it shows, centred on (x, y), at a stream size.
    private func view(_ x: CGFloat, _ y: CGFloat, w: Int, h: Int) -> (frame: CGRect, viewport: CGRect) {
        let z = PictureFit.centredZoom
        let pan = PictureFit.pan(centring: x, y, canvasWidth: w, canvasHeight: h, in: bounds, screenScale: scale, zoom: z)
        let f = PictureFit.zoomed(canvasWidth: w, canvasHeight: h, in: bounds, screenScale: scale, zoom: z, pan: pan).frame
        return (f, PictureFit.viewport(picture: f, canvasWidth: w, in: bounds))
    }

    /// Where canvas point (x, y) is drawn in the view.
    private func drawn(_ x: CGFloat, _ y: CGFloat, in f: CGRect, w: Int) -> CGPoint {
        let k = f.width / CGFloat(w)
        return CGPoint(x: f.minX + x * k, y: f.minY + y * k)
    }

    func testViewportIsAQuarterOfTheScreenAtBothStreamSizes() {
        for (w, h) in [(1920, 1080), (960, 540)] {
            let v = view(CGFloat(w) / 2, CGFloat(h) / 2, w: w, h: h).viewport
            XCTAssertEqual(v.width, CGFloat(w) / 2, accuracy: 1.5, "\(w)")
            XCTAssertEqual(v.height, CGFloat(h) / 2, accuracy: 1.5, "\(w)")
        }
    }

    func testPointerStaysInTheCentreAwayFromTheEdges() {
        for (w, h) in [(1920, 1080), (960, 540)] {
            let s = CGFloat(w) / 1920
            for p in [CGPoint(x: 780, y: 350), CGPoint(x: 960, y: 540), CGPoint(x: 1400, y: 700)] {
                let x = p.x * s, y = p.y * s
                let d = drawn(x, y, in: view(x, y, w: w, h: h).frame, w: w)
                XCTAssertEqual(d.x, bounds.width / 2, accuracy: 0.5, "\(w) \(p)")
                XCTAssertEqual(d.y, bounds.height / 2, accuracy: 0.5, "\(w) \(p)")
            }
        }
    }

    /// At each edge and corner the view stops at the screen's edge (no empty area) and the pointer leaves the
    /// centre, reaching the picture's edge at the screen's edge.
    func testViewportStopsAtEachEdgeAndCorner() {
        for (w, h) in [(1920, 1080), (960, 540)] {
            let W = CGFloat(w), H = CGFloat(h)
            for p in [CGPoint(x: 0, y: H / 2), CGPoint(x: W - 1, y: H / 2), CGPoint(x: W / 2, y: 0),
                      CGPoint(x: W / 2, y: H - 1), CGPoint(x: 0, y: 0), CGPoint(x: W - 1, y: H - 1),
                      CGPoint(x: 70 * W / 1920, y: 45 * H / 1080)] {
                let (f, v) = view(p.x, p.y, w: w, h: h)
                XCTAssertGreaterThanOrEqual(v.minX, -0.01, "\(w) \(p)")
                XCTAssertGreaterThanOrEqual(v.minY, -0.01, "\(w) \(p)")
                XCTAssertLessThanOrEqual(v.maxX, W + 0.01, "\(w) \(p)")
                XCTAssertLessThanOrEqual(v.maxY, H + 0.01, "\(w) \(p)")
                XCTAssertLessThanOrEqual(f.minX, 0.01); XCTAssertGreaterThanOrEqual(f.maxX, bounds.width - 0.01)
                XCTAssertLessThanOrEqual(f.minY, 0.01); XCTAssertGreaterThanOrEqual(f.maxY, bounds.height - 0.01)
                // The pointer is drawn where it is, inside the view.
                let d = drawn(p.x, p.y, in: f, w: w)
                XCTAssertTrue(CGRect(origin: .zero, size: bounds).insetBy(dx: -1, dy: -1).contains(d), "\(w) \(p)")
            }
            // Corners: the pointer is at the view's own corner.
            let tl = drawn(0, 0, in: view(0, 0, w: w, h: h).frame, w: w)
            XCTAssertEqual(tl.x, 0, accuracy: 0.5); XCTAssertEqual(tl.y, 0, accuracy: 0.5)
            let br = drawn(W, H, in: view(W - 1, H - 1, w: w, h: h).frame, w: w)
            XCTAssertEqual(br.x, bounds.width, accuracy: 0.5); XCTAssertEqual(br.y, bounds.height, accuracy: 0.5)
        }
    }

    /// A touch on the zoomed picture lands on the Mac point drawn under the finger, at both stream sizes.
    func testTouchOnTheZoomedPictureMapsToTheRightMacPoint() {
        for (w, h) in [(1920, 1080), (960, 540)] {
            let s = CGFloat(w) / 1920
            for centre in [CGPoint(x: 780, y: 350), CGPoint(x: 100, y: 1000)] {
                let f = view(centre.x * s, centre.y * s, w: w, h: h).frame
                for target in [CGPoint(x: 600, y: 300), CGPoint(x: 900, y: 500), CGPoint(x: 400, y: 800)] {
                    let tx = target.x * s, ty = target.y * s
                    let finger = drawn(tx, ty, in: f, w: w)
                    guard CGRect(origin: .zero, size: bounds).contains(finger) else { continue }
                    let p = DirectTouchEngine.canvasPoint(finger, picture: f, canvasWidth: w, canvasHeight: h)
                    XCTAssertNotNil(p)
                    XCTAssertEqual(CGFloat(p!.0), tx, accuracy: 1, "\(w) \(centre) \(target)")
                    XCTAssertEqual(CGFloat(p!.1), ty, accuracy: 1, "\(w) \(centre) \(target)")
                }
            }
        }
    }

    func testViewChoiceIsRememberedPerMac() {
        let d = UserDefaults(suiteName: "CentredViewTests")!
        d.removePersistentDomain(forName: "CentredViewTests")
        XCTAssertEqual(SessionView.stored(mac: "my-mac:4433", in: d), .regular)
        SessionView.centred.store(mac: "my-mac:4433", in: d)
        XCTAssertEqual(SessionView.stored(mac: "my-mac:4433", in: d), .centred)
        XCTAssertEqual(SessionView.stored(mac: "other-mac:4433", in: d), .regular)
        // The scrapped two-pad view, stored by build 14, falls back to the regular view.
        d.set("twoPads", forKey: SessionView.storageKey(mac: "other-mac:4433"))
        XCTAssertEqual(SessionView.stored(mac: "other-mac:4433", in: d), .regular)
        var all: [SessionView] = [.regular, .centred]
        #if DUO_TERMINAL
        all.append(.terminal)
        #endif
        #if DUO_JETKVM
        all.append(.jetkvm)
        #endif
        XCTAssertEqual(SessionView.allCases, all)
    }
}
