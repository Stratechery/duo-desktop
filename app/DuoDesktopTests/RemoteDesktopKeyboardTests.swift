// A PC's screen has Duo Desktop's keyboard at the open Duo's upright size, as a
// Mac's session does, at the sign-in prompt and live. One test per claim. No PC is contacted.
import GlassActTransport
import XCTest
@testable import DuoDesktop
import SwiftUI
import UIKit

@MainActor
final class RemoteDesktopKeyboardTests: XCTestCase {
    private final class Recorder: RDPOutput {
        var events: [RDPEvent] = []
        func send(_ event: RDPEvent) { events.append(event) }
    }

    private func wired() -> (RDPInput, SessionParts, Recorder) {
        let rec = Recorder()
        let input = RDPInput()
        input.isOpen = { true }
        input.output = rec
        let parts = SessionParts(sink: input)
        parts.setCanvas(width: 1920, height: 1080, fullWidth: 1920)
        let i = input
        parts.keyboard.engine.typeText = { c in i.type(c) }
        return (input, parts, rec)
    }

    /// Claim: at the password prompt, keys typed on Duo Desktop's keyboard (the same path the system keyboard's
    /// keys take, `MacTyping`) go into the Password field: characters with their capitals, ⌫ deletes, Return
    /// connects, and nothing reaches the PC.
    func testKeyTypedAtPromptReachesPasswordField() {
        let (input, parts, rec) = wired()
        var password = ""
        var connected = false
        input.prompt = { key in if key.apply(to: &password) { connected = true } }
        for c in "Pa5s!x" { _ = MacTyping.type(c, into: parts.keyboard.engine) }
        let engine = parts.keyboard.engine
        engine.keyDown(MacKeyboardLayout.delete)
        engine.keyUp(MacKeyboardLayout.delete)
        input.type("é") // a character no US key types (the typeText hook)
        XCTAssertEqual(password, "Pa5s!é")
        XCTAssertFalse(connected)
        _ = MacTyping.type("\n", into: engine)
        XCTAssertTrue(connected, "Return connects")
        XCTAssertEqual(rec.events, [], "nothing reaches the PC at the prompt")
    }

    /// Claim: live (no prompt), a typed key reaches `RDPInput` and the PC: text as Unicode, a named key as its scan
    /// code, and the band's latched Ctrl as Ctrl.
    func testKeyTypedLiveReachesRDPInput() {
        let (input, parts, rec) = wired()
        input.prompt = nil
        _ = MacTyping.type("a", into: parts.keyboard.engine)
        XCTAssertEqual(rec.events, [.unicode(flags: 0, code: 0x61), .unicode(flags: RDPFlags.keyRelease, code: 0x61)])
        rec.events = []
        let engine = parts.keyboard.engine
        engine.tapModifier(.control)
        engine.keyDown(MacKeyboardLayout.left)
        engine.keyUp(MacKeyboardLayout.left)
        XCTAssertTrue(rec.events.contains(.key(flags: 0, code: 0x1D)), "Ctrl down: \(rec.events)")
        XCTAssertTrue(rec.events.contains(.key(flags: RDPFlags.keyExtended, code: 0x4B)), "← as E0 4B: \(rec.events)")
    }

    #if DUO_RDP
    /// Claim (the layout): at the open Duo's upright size (669 x 951 pt, the iPhone Duo simulator's open screen, as
    /// `KeySizeTests.safeUpright` measures it), a PC's screen at the password prompt holds the Duo's keyboard up as
    /// a Mac's session does: one pinned `MacTypingView` is first responder with the system keyboard (no own input
    /// view) and no row above it, the exact set-up of the Mac session's upright typing field. Build 81 had none
    /// at the prompt (the field was added only once live), so the band stretched into the keyboard's place. The
    /// band and keyboard frames then come from the same `SessionLayout.Upright` with the same keyboard height.
    func testOpenDuoUprightPCPromptHasTheMacsKeyboard() throws {
        let size = CGSize(width: 669, height: 951)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let list = dir.appendingPathComponent("macs.json")
        try Data("[]".utf8).write(to: list)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "rdpkb-\(UUID().uuidString)"))
        let store = MacStore(url: list, defaults: defaults, knownHosts: KnownHosts(url: dir.appendingPathComponent("kh")))
        var e = MacEntry(name: "Windows PC")
        e.screenSharing = false
        e.remoteDesktop = true
        e.rdpUser = "someone"
        e.rdpRememberPassword = false
        e.set(.tailscale, "pc.example.invalid")
        store.add(e)

        let host = UIHostingController(rootView: RemoteDesktopScreen(entry: e, store: store, leave: {}))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(origin: .zero, size: size)
        window.windowLevel = .alert + 1
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        func typingViews(_ v: UIView) -> [MacTypingView] {
            (v as? MacTypingView).map { [$0] } ?? [] + v.subviews.flatMap(typingViews)
        }
        let fields = typingViews(window)
        XCTAssertEqual(fields.count, 1, "one hidden typing field at the prompt")
        let field = try XCTUnwrap(fields.first)
        XCTAssertTrue(field.isFirstResponder, "it holds the keyboard up at the prompt")
        XCTAssertNil(field.inputView, "the system keyboard (Duo Desktop's keyboard on the Duo), as a Mac's")
        XCTAssertEqual(field.inputAccessoryView?.frame.height ?? 0, 0, "no row above it, as a Mac's upright")

        // The Mac session's upright field (`SessionScreen`: pinned, no Mac keys row, not click-only) is set up the same.
        let mac = MacTypingView(frame: .zero)
        mac.showsMacKeysBar = false
        mac.state = SessionParts(sink: RDPInput()).keyboard
        XCTAssertEqual(mac.inputView == nil, field.inputView == nil)
        XCTAssertEqual(mac.inputAccessoryView?.frame.height, field.inputAccessoryView?.frame.height)
        XCTAssertEqual(mac.keyboardType, field.keyboardType)
        XCTAssertEqual(mac.autocorrectionType, field.autocorrectionType)

        // With that keyboard up, the layout code both screens call gives the band its normal 150 pt; build 81's prompt
        // laid out with no keyboard (0) and stretched it.
        let safe = CGSize(width: 669, height: 951 - 82 - 34)
        XCTAssertEqual(SessionLayout.Upright(size: safe, keyboardInset: 293, side: .standard, shape: .sixteenNine)
            .band.height, 150)
        XCTAssertGreaterThan(SessionLayout.Upright(size: safe, keyboardInset: 0, side: .standard, shape: .sixteenNine)
            .band.height, 300)
    }
    #endif
}
