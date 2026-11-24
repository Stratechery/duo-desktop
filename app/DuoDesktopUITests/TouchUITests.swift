import XCTest

// UI-level touch tests: real touches on the Mac picture in the simulator, checked against what Glass Act's test host
// received. Needs the patched test host running and logging
// (`patches/testhost-input-log-and-release.patch`); its log path comes in as DUO_HOST_LOG (set with
// TEST_RUNNER_DUO_HOST_LOG). Run with the DuoDesktopUITests scheme; the unit tests do not need the host.

/// The test host's stdout: "glassact-testhost: [time] input: …" lines.
final class HostLog {
    let path: String
    private var mark = 0
    init(path: String) { self.path = path }
    func all() -> [String] {
        ((try? String(contentsOfFile: path, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
    func markNow() { mark = all().count }
    /// Input lines since the last mark.
    func newInput() -> [String] { all().dropFirst(mark).filter { $0.contains("] input:") } }
    /// Waits until `done` holds for the new input lines (or the timeout), then returns them.
    @discardableResult
    func wait(_ timeout: TimeInterval = 6, until done: ([String]) -> Bool) -> [String] {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if done(newInput()) { return newInput() }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return newInput()
    }
}

final class TouchUITests: XCTestCase {
    private var app: XCUIApplication!
    private var log: HostLog!

    override func setUpWithError() throws {
        continueAfterFailure = true
        guard let path = ProcessInfo.processInfo.environment["DUO_HOST_LOG"] else {
            throw XCTSkip("DUO_HOST_LOG not set: start the patched test host and pass TEST_RUNNER_DUO_HOST_LOG")
        }
        log = HostLog(path: path)
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() {
        app?.terminate()
        XCUIDevice.shared.orientation = .portrait
    }

    /// Launches into a session with the test host and returns the picture.
    private func start(horizontal: Bool, extra: [String] = []) -> XCUIElement {
        app = XCUIApplication()
        app.launchArguments = ["--no-app-lock", "--connect", "Test host"] + extra
        app.launchEnvironment["DUO_TEST_SIGNIN"] = "test:duotest"
        log.markNow()
        app.launch()
        // The session's first input is the connect release (five modifier key ups).
        let first = log.wait(20) { $0.contains { $0.contains("key fn (0x3f) up") } }
        XCTAssertTrue(first.contains { $0.contains("key fn (0x3f) up") }, "no session (connect release not seen)")
        if horizontal {
            XCUIDevice.shared.orientation = .landscapeLeft
            Thread.sleep(forTimeInterval: 2)
        }
        let picture = app.otherElements["Mac screen"].firstMatch
        XCTAssertTrue(picture.waitForExistence(timeout: 10), "no Mac picture")
        Thread.sleep(forTimeInterval: 1)
        log.markNow()
        return picture
    }

    private func point(_ e: XCUIElement, _ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        e.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    private func attach(_ name: String, _ lines: [String]) {
        let a = XCTAttachment(string: lines.joined(separator: "\n"))
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        print("DUO-UI \(name):\n" + lines.joined(separator: "\n"))
    }

    // MARK: Our horizontal keyboard's pop-up, seen while a real touch is down. Each key is held for 2.5 s; the screen
    // is captured from outside (`xcrun simctl io … screenshot`) while it is down. The marker file
    // (TEST_RUNNER_DUO_PRESS_MARK) names the key being held, so the capture loop labels the pictures.

    func testKeyPopupShownWhileHeldHorizontal() throws {
        let mark = ProcessInfo.processInfo.environment["DUO_PRESS_MARK"]
        // The simulator Duo starts folded and cannot be unfolded by command: the open layout on the outer screen.
        _ = start(horizontal: true, extra: ["--force-open-layout"])
        if let mark { try? "state".write(toFile: mark, atomically: true, encoding: .utf8) }
        Thread.sleep(forTimeInterval: 1)
        if let mark { try? "-".write(toFile: mark, atomically: true, encoding: .utf8) }
        let kb = app.descendants(matching: .any)["keyboardButton"].firstMatch
        guard kb.waitForExistence(timeout: 5) else {
            throw XCTSkip("no horizontal layout: the simulator Duo is folded (its outer screen stays upright); unfold it")
        }
        kb.tap()
        Thread.sleep(forTimeInterval: 1.5)
        for id in ["c-t", "c-q", "c-p", "c-a", "c-l", "shift", "delete"] {
            let key = app.descendants(matching: .any)["touchKey-\(id)"].firstMatch
            XCTAssertTrue(key.waitForExistence(timeout: 5), "no key \(id)")
            if let mark { try? id.write(toFile: mark, atomically: true, encoding: .utf8) }
            key.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 2.5)
            if let mark { try? "-".write(toFile: mark, atomically: true, encoding: .utf8) }
            Thread.sleep(forTimeInterval: 0.6)
        }
    }

    // MARK: Hold, then drag: left down, drag moves, left up; no right click.

    private func holdThenDrag(horizontal: Bool) {
        let pic = start(horizontal: horizontal)
        point(pic, 0.3, 0.5).press(forDuration: 1.0, thenDragTo: point(pic, 0.6, 0.6))
        let lines = log.wait { $0.contains { $0.contains("left up") } }
        attach("hold-then-drag \(horizontal ? "horizontal" : "upright")", lines)
        XCTAssertTrue(lines.contains { $0.contains("left down") })
        let up = lines.first { $0.contains("left up") } ?? ""
        let moves = Int(up.components(separatedBy: "after ").last?.components(separatedBy: " ").first ?? "") ?? 0
        XCTAssertGreaterThan(moves, 0, "no drag moves between down and up: \(up)")
        XCTAssertFalse(lines.contains { $0.contains("right down") })
        XCTAssertFalse(lines.contains { $0.contains("scroll") })
    }
    func testHoldThenDragUpright() { holdThenDrag(horizontal: false) }
    func testHoldThenDragHorizontal() { holdThenDrag(horizontal: true) }

    // Three-finger swipes: not here. XCUITest has no public multi-finger swipe, and driving XCTest's private event
    // synthesis (XCPointerEventPath) crashed the test runner on iOS 27.2. Covered at the engine level by
    // TouchLikeMacBookProTests; by hand on the device.

    // MARK: Edge swipes: in from the top → pointer to the top edge; from the bottom → bottom edge. No scroll.

    private func edges(horizontal: Bool) {
        let pic = start(horizontal: horizontal)
        let f = pic.frame
        let inset = 4 / f.height
        for (name, from, to) in [("top", inset, 0.4), ("bottom", 1 - inset, 0.6)] {
            log.markNow()
            point(pic, 0.5, from).press(forDuration: 0.05, thenDragTo: point(pic, 0.5, to))
            let lines = log.wait(4) { $0.contains { $0.contains("(\(name) edge)") } }
            attach("edge \(name) \(horizontal ? "horizontal" : "upright")", lines)
            XCTAssertTrue(lines.contains { $0.contains("(\(name) edge)") }, "\(name): pointer not sent to the edge")
            XCTAssertFalse(lines.contains { $0.contains("scroll") }, "\(name): scrolled instead")
        }
    }
    func testEdgeSwipesUpright() { edges(horizontal: false) }
    func testEdgeSwipesHorizontal() { edges(horizontal: true) }

    // MARK: Pinch zooms the picture on the phone: nothing goes to the Mac.

    private func pinch(horizontal: Bool) {
        let pic = start(horizontal: horizontal)
        pic.pinch(withScale: 2.5, velocity: 2)
        Thread.sleep(forTimeInterval: 1)
        let zoomed = XCUIScreen.main.screenshot()
        let shot = XCTAttachment(screenshot: zoomed)
        shot.name = "pinched \(horizontal ? "horizontal" : "upright")"
        shot.lifetime = .keepAlways
        add(shot)
        let lines = log.wait(2) { _ in false }
        attach("pinch \(horizontal ? "horizontal" : "upright")", lines)
        XCTAssertFalse(lines.contains { $0.contains("down") || $0.contains("scroll") }, "pinch sent input to the Mac")
        // The zoom itself is not asserted: XCUIScreen shots came back byte-identical before and after (the Metal
        // picture is not in them). The screenshot is attached for a look.
        pic.pinch(withScale: 0.3, velocity: -2)
    }
    func testPinchUpright() { pinch(horizontal: false) }
    func testPinchHorizontal() { pinch(horizontal: true) }

    // MARK: Apps switcher open (Command held), then a touch on the picture picks: click, then Command up.

    func testAppSwitcherPickedByTouchOnPictureUpright() {
        app = nil
        let pic = start(horizontal: false, extra: ["--open-app-switcher"])
        let opened = log.wait(10) { $0.contains { $0.contains("key tab (0x30) up") } }
        XCTAssertTrue(opened.contains { $0.contains("key command (0x37) down") }, "switcher did not open")
        log.markNow()
        point(pic, 0.5, 0.5).tap()
        let lines = log.wait { $0.contains { $0.contains("key command (0x37) up") } }
        attach("apps picked by touch", lines)
        let order = ["left down", "left up", "key command (0x37) up"].map { s in lines.firstIndex { $0.contains(s) } }
        XCTAssertFalse(order.contains(nil), "missing events: \(lines)")
        if !order.contains(nil) { XCTAssertEqual(order.map { $0! }, order.map { $0! }.sorted(), "wrong order") }
    }

    // MARK: Click buttons

    /// Left click held by one finger while another moves on the trackpad: button down, drag moves, button up, in
    /// that order. XCUITest has no public API for two fingers on two elements at once, so both fingers go in one
    /// synthesized event record (XCTest's private `XCSynthesizedEventRecord` / `XCPointerEventPath`): finger 1
    /// down on Left click at 0 s, up at 2.4 s; finger 2 on the trackpad from 0.6 s, moving until 1.8 s.
    func testLeftClickHeldWhileTrackpadMovesDrags() throws {
        // 2026-11-20: on iOS 27.2 the record synthesizes without an error but no touch reaches the app (the host
        // logged nothing). Not yet working; the order is proven at the engine level
        // (TrackpadTests.testLeftClickButtonHeldWhileMovingDrags).
        throw XCTSkip("two-finger synthesis delivers no touches on iOS 27.2 (see comment)")
        _ = start(horizontal: false)
        let left = app.descendants(matching: .any)["leftClick"].firstMatch
        let pad = app.descendants(matching: .any)["Trackpad"].firstMatch
        XCTAssertTrue(left.waitForExistence(timeout: 5), "no Left click button")
        XCTAssertTrue(pad.exists, "no trackpad")
        let thumb = point(left, 0.5, 0.5).screenPoint
        let from = point(pad, 0.3, 0.5).screenPoint, to = point(pad, 0.7, 0.6).screenPoint
        log.markNow()
        try TwoFingers.run([
            [(thumb, 0), (thumb, 2.4)],
            [(from, 0.6), (CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2), 1.2), (to, 1.8), (to, 1.9)],
        ])
        let lines = log.wait { $0.contains { $0.contains("left up") } }
        attach("left click held, trackpad moved", lines)
        let down = lines.firstIndex { $0.contains("left down") }
        let up = lines.firstIndex { $0.contains("left up") }
        XCTAssertNotNil(down, "no left down")
        XCTAssertNotNil(up, "no left up")
        if let down, let up { XCTAssertLessThan(down, up) }
        let upLine = up.map { lines[$0] } ?? ""
        let moves = Int(upLine.components(separatedBy: "after ").last?.components(separatedBy: " ").first ?? "") ?? 0
        XCTAssertGreaterThan(moves, 0, "no drag moves between down and up: \(upLine)")
        XCTAssertFalse(lines.contains { $0.contains("right down") })
    }

    /// Right click sends a right button down and up.
    func testRightClickButtonSendsARightClick() {
        _ = start(horizontal: false)
        let right = app.descendants(matching: .any)["rightClick"].firstMatch
        XCTAssertTrue(right.waitForExistence(timeout: 5), "no Right click button")
        log.markNow()
        right.tap()
        let lines = log.wait { $0.contains { $0.contains("right up") } }
        attach("right click button", lines)
        let order = ["right down", "right up"].map { s in lines.firstIndex { $0.contains(s) } }
        XCTAssertFalse(order.contains(nil), "missing events: \(lines)")
        if !order.contains(nil) { XCTAssertLessThan(order[0]!, order[1]!) }
        XCTAssertFalse(lines.contains { $0.contains("left down") })
    }

    /// Trackpad on the left (the stored setting, given here through the launch arguments' defaults): the trackpad
    /// is left of the keys, the three buttons at the far right with Left over Right over Scroll; Right click still
    /// right-clicks; a tap of Scroll alone sends nothing.
    func testTrackpadOnTheLeftAndTheScrollButton() {
        _ = start(horizontal: false, extra: ["-trackpadSide", "left"])
        let left = app.descendants(matching: .any)["leftClick"].firstMatch
        let right = app.descendants(matching: .any)["rightClick"].firstMatch
        let scroll = app.descendants(matching: .any)["scrollButton"].firstMatch
        let pad = app.descendants(matching: .any)["Trackpad"].firstMatch
        let copy = app.buttons["Copy"].firstMatch
        XCTAssertTrue(scroll.waitForExistence(timeout: 5), "no Scroll button")
        XCTAssertLessThan(pad.frame.maxX, copy.frame.minX, "trackpad not left of the keys")
        XCTAssertGreaterThan(left.frame.minX, copy.frame.maxX, "buttons not right of the keys")
        // The keys keep their order (they do not flip): Copy is left of Paste.
        let paste = app.buttons["Paste"].firstMatch
        XCTAssertLessThan(copy.frame.maxX, paste.frame.minX, "keys flipped")
        XCTAssertLessThan(left.frame.maxY, right.frame.minY)
        XCTAssertLessThan(right.frame.maxY, scroll.frame.minY)
        XCTAssertEqual(left.frame.height, right.frame.height * 2 + 1, accuracy: 10)
        XCTAssertEqual(scroll.label, "Scroll")
        log.markNow()
        scroll.tap()
        Thread.sleep(forTimeInterval: 1.5)
        attach("scroll tapped alone", log.newInput())
        XCTAssertTrue(log.newInput().isEmpty, "Scroll alone sent: \(log.newInput())")
        right.tap()
        let lines = log.wait { $0.contains { $0.contains("right up") } }
        attach("right click, trackpad on the left", lines)
        XCTAssertTrue(lines.contains { $0.contains("right down") })
    }
}

/// Several fingers at once through XCTest's private event synthesis. Each path: down at its first point and
/// time, moves through the rest, lifts at its last time.
enum TwoFingers {
    struct Failed: Error { let why: String }

    static func run(_ paths: [[(CGPoint, Double)]]) throws {
        guard let recordClass = NSClassFromString("XCSynthesizedEventRecord") as? NSObject.Type,
              let pathClass = NSClassFromString("XCPointerEventPath") as? NSObject.Type else {
            throw Failed(why: "XCTest event classes not found")
        }
        typealias InitPath = @convention(c) (AnyObject, Selector, CGPoint, Double) -> AnyObject
        typealias Move = @convention(c) (AnyObject, Selector, CGPoint, Double) -> Void
        typealias Lift = @convention(c) (AnyObject, Selector, Double) -> Void
        typealias InitRecord = @convention(c) (AnyObject, Selector, NSString, Int) -> AnyObject
        typealias Add = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        typealias Synth = @convention(c) (AnyObject, Selector, UnsafeMutablePointer<NSError?>?) -> Bool

        func imp<T>(_ obj: AnyObject, _ sel: String, _: T.Type) throws -> (T, Selector) {
            let s = NSSelectorFromString(sel)
            guard let o = obj as? NSObject, o.responds(to: s) else { throw Failed(why: "no \(sel)") }
            return (unsafeBitCast(o.method(for: s), to: T.self), s)
        }
        let recAlloc = recordClass.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
        let (initRec, s1) = try imp(recAlloc, "initWithName:interfaceOrientation:", InitRecord.self)
        let record = initRec(recAlloc, s1, "two fingers", UIInterfaceOrientation.portrait.rawValue)
        let (add, s2) = try imp(record, "addPointerEventPath:", Add.self)
        for steps in paths {
            let pAlloc = pathClass.perform(NSSelectorFromString("alloc"))!.takeUnretainedValue()
            let (initPath, s3) = try imp(pAlloc, "initForTouchAtPoint:offset:", InitPath.self)
            let path = initPath(pAlloc, s3, steps[0].0, steps[0].1)
            let (move, s4) = try imp(path, "moveToPoint:atOffset:", Move.self)
            for step in steps.dropFirst().dropLast() { move(path, s4, step.0, step.1) }
            let (lift, s5) = try imp(path, "liftUpAtOffset:", Lift.self)
            lift(path, s5, steps.last!.1)
            add(record, s2, path)
        }
        let (synth, s6) = try imp(record, "synthesizeWithError:", Synth.self)
        var error: NSError?
        guard synth(record, s6, &error) else { throw Failed(why: "synthesize: \(String(describing: error))") }
    }
}

/// Every picture size the Host can send, through changes mid-session. Needs the test host with the picture-size patch,
/// started with `--size 1920x1080 --picture-steps 4:960x540,55:1366x767,105:1920x1080,155:960x540` (seconds after the
/// viewer's geometry settles); DUO_PICTURE_STEPS=1 (TEST_RUNNER_DUO_PICTURE_STEPS) turns this test on, and the other UI
/// tests run against a host without steps.
final class PictureSizeUITests: XCTestCase {
    private var app: XCUIApplication!
    private var log: HostLog!
    static let steps: [(Int, Int)] = [(960, 540), (1366, 767), (1920, 1080), (960, 540)]

    override func setUpWithError() throws {
        continueAfterFailure = true
        let env = ProcessInfo.processInfo.environment
        guard let path = env["DUO_HOST_LOG"], env["DUO_PICTURE_STEPS"] == "1" else {
            throw XCTSkip("needs the test host with --picture-steps (DUO_PICTURE_STEPS=1, DUO_HOST_LOG)")
        }
        log = HostLog(path: path)
        XCUIDevice.shared.orientation = .portrait
    }

    override func tearDown() { app?.terminate() }

    private func point(_ e: XCUIElement, _ x: CGFloat, _ y: CGFloat) -> XCUICoordinate {
        e.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y))
    }

    private func attach(_ name: String, _ lines: [String]) {
        let a = XCTAttachment(string: lines.joined(separator: "\n"))
        a.name = name
        a.lifetime = .keepAlways
        add(a)
        print("DUO-UI \(name):\n" + lines.joined(separator: "\n"))
    }

    /// "… down at X,Y …" → (X, Y), the Mac screen point the test host mapped it to.
    private func at(_ line: String) -> (Int, Int)? {
        guard let r = line.range(of: " at ") else { return nil }
        let xy = line[r.upperBound...].prefix { $0 != " " }.split(separator: ",").compactMap { Int($0) }
        return xy.count == 2 ? (xy[0], xy[1]) : nil
    }

    /// The picture's own readout (simulator builds): "picture WxH; pointer fx,fy".
    private func readout(_ pic: XCUIElement) -> (size: String, x: Double, y: Double) {
        let v = (pic.value as? String) ?? ""
        let parts = v.components(separatedBy: "; pointer ")
        let f = parts.count == 2 ? parts[1].split(separator: ",").compactMap { Double($0) } : []
        return (parts.first?.replacingOccurrences(of: "picture ", with: "") ?? v,
                f.first ?? -1, f.count > 1 ? f[1] : -1)
    }

    func testPointerClicksDragsAndTouchAtEveryPictureSize() {
        app = XCUIApplication()
        app.launchArguments = ["--no-app-lock", "--connect", "Test host"]
        app.launchEnvironment["DUO_TEST_SIGNIN"] = "test:duotest"
        log.markNow()
        app.launch()
        let pic = app.otherElements["Mac screen"].firstMatch
        XCTAssertTrue(pic.waitForExistence(timeout: 20), "no Mac picture")
        let pad = app.descendants(matching: .any)["Trackpad"].firstMatch
        let left = app.descendants(matching: .any)["leftClick"].firstMatch
        let right = app.descendants(matching: .any)["rightClick"].firstMatch
        XCTAssertTrue(pad.waitForExistence(timeout: 10), "no trackpad")

        // DUO_PICTURE_STEPS_MAX=N: only the first N sizes (the before-the-fix reproduction).
        let maxSteps = Int(ProcessInfo.processInfo.environment["DUO_PICTURE_STEPS_MAX"] ?? "") ?? Self.steps.count
        for (w, h) in Self.steps.prefix(maxSteps) {
            // Wait for the host to switch to this picture size.
            let deadline = Date().addingTimeInterval(70)
            var seen = false
            while Date() < deadline {
                if log.all().contains(where: { $0.contains("picture → \(w)×\(h)") }) && !seenBefore(w, h) {
                    seen = true; break
                }
                Thread.sleep(forTimeInterval: 0.3)
            }
            XCTAssertTrue(seen, "test host never switched to \(w)x\(h)")
            markSeen(w, h)
            Thread.sleep(forTimeInterval: 2)
            let tag = "\(w)x\(h)"

            // The picture view takes the new size.
            XCTAssertTrue(readout(pic).size == tag || (pic.value as? String) == nil,
                          "\(tag): picture view still at \(readout(pic).size)")

            // Trackpad to the bottom-right corner: the host sees the picture's last pixel; the phone draws the
            // pointer at the picture's right edge.
            log.markNow()
            for _ in 0..<3 { pad.swipeRight(); pad.swipeDown() }
            var lines = log.wait(5) { $0.contains { $0.contains("bottom+right edge") } }
            attach("\(tag) trackpad to bottom-right", lines)
            XCTAssertTrue(lines.contains { $0.contains("bottom+right edge") }, "\(tag): pointer never reached the corner")
            Thread.sleep(forTimeInterval: 0.3)
            let r = readout(pic)
            XCTAssertGreaterThan(r.x, 0.99, "\(tag): pointer drawn at \(r.x) across, not the right edge")
            XCTAssertGreaterThan(r.y, 0.99, "\(tag): pointer drawn at \(r.y) down")
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "\(tag) pointer at bottom-right"
            shot.lifetime = .keepAlways
            add(shot)

            // A trackpad tap, Left click and Right click: all at the pointer (the picture's last pixel).
            let corner = "[picture px \(w - 1),\(h - 1) of \(w)×\(h)]"
            for (name, act, down) in [("trackpad tap", { pad.tap() }, "left down"),
                                      ("Left click", { left.tap() }, "left down"),
                                      ("Right click", { right.tap() }, "right down")] as [(String, () -> Void, String)] {
                Thread.sleep(forTimeInterval: 0.6) // not a double click
                log.markNow()
                act()
                lines = log.wait(5) { $0.contains { $0.contains(down) } }
                attach("\(tag) \(name)", lines)
                XCTAssertTrue(lines.contains { $0.contains(down) && $0.contains(corner) },
                              "\(tag) \(name): not clicked at the pointer: \(lines)")
            }

            // Trackpad to the top-left corner.
            log.markNow()
            for _ in 0..<3 { pad.swipeLeft(); pad.swipeUp() }
            lines = log.wait(5) { $0.contains { $0.contains("top+left edge") } }
            attach("\(tag) trackpad to top-left", lines)
            XCTAssertTrue(lines.contains { $0.contains("top+left edge") }, "\(tag): pointer never reached top-left")

            // A direct tap on the picture clicks under the finger (Mac screen 1920 x 1080).
            Thread.sleep(forTimeInterval: 0.6)
            log.markNow()
            point(pic, 0.75, 0.5).tap()
            lines = log.wait(5) { $0.contains { $0.contains("left up") } }
            attach("\(tag) direct tap", lines)
            let tap = lines.first { $0.contains("left down") }.flatMap(at)
            XCTAssertNotNil(tap, "\(tag): no click from a direct tap")
            if let tap {
                XCTAssertEqual(Double(tap.0), 1440, accuracy: 30, "\(tag): tap landed at x \(tap.0)")
                XCTAssertEqual(Double(tap.1), 540, accuracy: 30, "\(tag): tap landed at y \(tap.1)")
            }

            // Touch and hold, then drag on the picture: down under the first touch, up under the last.
            Thread.sleep(forTimeInterval: 0.6)
            log.markNow()
            point(pic, 0.6, 0.4).press(forDuration: 1.0, thenDragTo: point(pic, 0.9, 0.7))
            lines = log.wait(6) { $0.contains { $0.contains("left up") } }
            attach("\(tag) drag", lines)
            let d = lines.first { $0.contains("left down") }.flatMap(at)
            let upLine = lines.first { $0.contains("left up") } ?? ""
            let u = at(upLine)
            XCTAssertNotNil(d, "\(tag): no drag down"); XCTAssertNotNil(u, "\(tag): no drag up")
            if let d, let u {
                XCTAssertEqual(Double(d.0), 1152, accuracy: 40, "\(tag): drag began at x \(d.0)")
                XCTAssertEqual(Double(u.0), 1728, accuracy: 40, "\(tag): drag ended at x \(u.0)")
                XCTAssertEqual(Double(u.1), 756, accuracy: 40, "\(tag): drag ended at y \(u.1)")
            }
            let moves = Int(upLine.components(separatedBy: "after ").last?.components(separatedBy: " ").first ?? "") ?? 0
            XCTAssertGreaterThan(moves, 0, "\(tag): no drag moves")
        }
    }

    private var seenCount: [String: Int] = [:]
    private func key(_ w: Int, _ h: Int) -> String { "\(w)x\(h)" }
    /// The same size can come twice (960 x 540 at the start and the end): wait for the next occurrence.
    private func seenBefore(_ w: Int, _ h: Int) -> Bool {
        let n = log.all().filter { $0.contains("picture → \(w)×\(h)") }.count
        return n <= (seenCount[key(w, h)] ?? 0)
    }
    private func markSeen(_ w: Int, _ h: Int) {
        seenCount[key(w, h)] = log.all().filter { $0.contains("picture → \(w)×\(h)") }.count
    }
}
