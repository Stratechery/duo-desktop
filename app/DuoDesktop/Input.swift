import Foundation
import GlassActSession

/// Where input goes: Glass Act's `ViewerController.sendInput` (§3.5 INPUT, 0x0E), or a recorder in tests.
/// Kinds (§3.8, and the Host's code, `Apps/Host/HostController.swift:1128-1171` at the pinned commit):
/// 1 move, 2 button down, 3 button up (a = click count, b = button: 0 left, 1 right), 7 scroll in points
/// (a = horizontal, b = vertical), 5 key down, 6 key up (x = key code, a = CGEventFlags).
protocol InputSink: AnyObject {
    func sendInput(kind: UInt8, x: Int, y: Int, a: Int, b: Int)
}

extension ViewerController: InputSink {}

enum InputKind {
    static let move: UInt8 = 1
    static let buttonDown: UInt8 = 2
    static let buttonUp: UInt8 = 3
    static let keyDown: UInt8 = 5
    static let keyUp: UInt8 = 6
    static let scrollPoints: UInt8 = 7
}

/// One INPUT message, for tests and the log.
struct InputEvent: Equatable, CustomStringConvertible {
    var kind: UInt8, x: Int, y: Int, a: Int, b: Int
    var description: String { "k\(kind)(\(x),\(y),\(a),\(b))" }
}

/// Holds a sink weakly, so a view's engines never keep a finished session alive.
final class InputRelay: InputSink {
    weak var target: (any InputSink)?
    func sendInput(kind: UInt8, x: Int, y: Int, a: Int, b: Int) {
        target?.sendInput(kind: kind, x: x, y: y, a: a, b: b)
    }
}

/// Belt and braces at the start of every session (the owner 2026-11-20, "yes, check that"): before anything else, a key
/// up for each modifier (⌃ ⌥ ⇧ ⌘ fn), flags 0. If a crash or a killed app left one down on a Mac whose Host did not
/// let it go, the new session lifts it. Glass Act's own Host already releases what a session held when it ends
/// (`HostController.releaseHeldInput`, pinned commit); this covers any Host that does not. A stray key up is
/// harmless on the Mac. Mouse buttons are not sent: an up needs a point, and the Host's own release covers them.
enum ConnectRelease {
    static func send(to sink: any InputSink) {
        for m in KeyMap.Modifier.order {
            guard let code = m.keyCode else { continue }
            sink.sendInput(kind: InputKind.keyUp, x: Int(code), y: 0, a: 0, b: 0)
        }
    }
}

/// The session screen's one door to the Mac. Open only while the picture is live: while a session is being
/// rejoined, taps, keys and trackpad go nowhere (nothing is queued for later), so the Mac never receives input the
/// user made against an old picture.
final class InputGate: InputSink {
    private(set) weak var target: (any InputSink)?
    var isOpen: Bool { target != nil }
    func open(to sink: any InputSink) { target = sink }
    func close() { target = nil }
    /// Every input that reaches the Mac, by kind (the session's keyboard rules watch clicks, moves and keys).
    var onSent: ((UInt8) -> Void)?
    func sendInput(kind: UInt8, x: Int, y: Int, a: Int, b: Int) {
        guard let target else { return }
        target.sendInput(kind: kind, x: x, y: y, a: a, b: b)
        onSent?(kind)
    }
}
