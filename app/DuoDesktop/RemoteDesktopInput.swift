// A PC's pointer and keys: `RDPInput` takes the same events our trackpad, button column, keys and keyboards make for a
// Mac (`InputSink`) and turns them into Remote Desktop input events (MS-RDPBCGR 2.2.8.1.1.3.1.1: mouse, keyboard scan
// code, Unicode). The mapping is in every build, so tests prove it without a PC; only the session that sends the events
// (`RemoteDesktopSession`) needs DUO_RDP.
import CoreGraphics
import Foundation
import GlassActSession

/// One Remote Desktop input event, as FreeRDP's `freerdp_input_send_*` take them.
enum RDPEvent: Equatable, CustomStringConvertible {
    /// TS_POINTER_EVENT: pointerFlags and a position in the session's desktop.
    case mouse(flags: UInt16, x: UInt16, y: UInt16)
    /// TS_KEYBOARD_EVENT: keyboardFlags (extended, release) and a set-1 scan code.
    case key(flags: UInt16, code: UInt8)
    /// TS_UNICODE_KEYBOARD_EVENT: one UTF-16 unit, pressed or released.
    case unicode(flags: UInt16, code: UInt16)

    var description: String {
        switch self {
        case let .mouse(f, x, y): String(format: "mouse(%04X,%d,%d)", f, x, y)
        case let .key(f, c): String(format: "key(%04X,%02X)", f, c)
        case let .unicode(f, c): String(format: "unicode(%04X,%04X)", f, c)
        }
    }
}

/// FreeRDP's input.h flags (macros Swift cannot import).
enum RDPFlags {
    static let move: UInt16 = 0x0800
    static let down: UInt16 = 0x8000
    static let left: UInt16 = 0x1000
    static let right: UInt16 = 0x2000
    static let wheel: UInt16 = 0x0200
    static let hWheel: UInt16 = 0x0400
    static let wheelNegative: UInt16 = 0x0100
    static let keyExtended: UInt16 = 0x0100
    static let keyRelease: UInt16 = 0x8000
}

/// Where `RDPInput` sends its events: the live session, or a recorder in tests.
protocol RDPOutput: AnyObject {
    func send(_ event: RDPEvent)
}

/// Mac key codes (the ones our keys send, US ANSI `kVK_*`) → PC set-1 scan codes (US keyboard), and the characters
/// the system keyboard's keys stand for (sent as Unicode, so they arrive as typed whatever the PC's layout).
enum RDPKeys {
    struct Scan: Equatable { var code: UInt8; var extended = false }

    static let ctrl = Scan(code: 0x1D)
    static let alt = Scan(code: 0x38)
    static let shift = Scan(code: 0x2A)
    /// The left Windows key (⊞): E0 5B.
    static let windows = Scan(code: 0x5B, extended: true)

    /// ⌃ → Ctrl, ⌥ → Alt, ⌘ → ⊞ (plan §2 "Keys"), ⇧ → Shift; right-hand ones too. fn (63) has no PC key.
    static let modifiers: [UInt16: Scan] = [
        59: ctrl, 62: Scan(code: 0x1D, extended: true),
        58: alt, 61: Scan(code: 0x38, extended: true),
        55: windows, 54: Scan(code: 0x5C, extended: true),
        56: shift, 60: Scan(code: 0x36),
    ]

    static let keys: [UInt16: Scan] = {
        var m: [UInt16: Scan] = [:]
        let plain: [(UInt16, UInt8)] = [
            (0, 0x1E), (1, 0x1F), (2, 0x20), (3, 0x21), (4, 0x23), (5, 0x22), (6, 0x2C), (7, 0x2D), (8, 0x2E),
            (9, 0x2F), (11, 0x30), (12, 0x10), (13, 0x11), (14, 0x12), (15, 0x13), (16, 0x15), (17, 0x14),
            (18, 0x02), (19, 0x03), (20, 0x04), (21, 0x05), (22, 0x07), (23, 0x06), (24, 0x0D), (25, 0x0A),
            (26, 0x08), (27, 0x0C), (28, 0x09), (29, 0x0B), (30, 0x1B), (31, 0x18), (32, 0x16), (33, 0x1A),
            (34, 0x17), (35, 0x19), (36, 0x1C), (37, 0x26), (38, 0x24), (39, 0x28), (40, 0x25), (41, 0x27),
            (42, 0x2B), (43, 0x33), (44, 0x35), (45, 0x31), (46, 0x32), (47, 0x34), (48, 0x0F), (49, 0x39),
            (50, 0x29), (51, 0x0E), (53, 0x01), (57, 0x3A),
            // F1-F12
            (122, 0x3B), (120, 0x3C), (99, 0x3D), (118, 0x3E), (96, 0x3F), (97, 0x40), (98, 0x41), (100, 0x42),
            (101, 0x43), (109, 0x44), (103, 0x57), (111, 0x58),
        ]
        for (k, s) in plain { m[k] = Scan(code: s) }
        // Home, End, Page Up, Page Down, Delete (⌦), arrows, Print Screen: the E0 (extended) keys.
        let extended: [(UInt16, UInt8)] = [
            (115, 0x47), (119, 0x4F), (116, 0x49), (121, 0x51), (117, 0x53),
            (123, 0x4B), (124, 0x4D), (125, 0x50), (126, 0x48),
            // Print Screen (the PC "…" page's PrtSc, sent as the Mac's F13 position): E0 37.
            (105, 0x37),
        ]
        for (k, s) in extended { m[k] = Scan(code: s, extended: true) }
        return m
    }()

    /// (Mac key code, shifted) → the character it types on a US layout (`MacTyping.keys`, turned round).
    static let characters: [Int: Character] = {
        var m: [Int: Character] = [:]
        // Printable ASCII only: the named keys' labels (←, ⏎, ⌫) are not text; they go as scan codes.
        for (c, key) in MacTyping.keys where c.isASCII && (c == " " || !c.isWhitespace) {
            let shifted = key.ownFlags & MacKeyFlags.shift != 0
            m[Int(key.code) << 1 | (shifted ? 1 : 0)] = c
        }
        return m
    }()

    static func character(code: UInt16, shifted: Bool) -> Character? {
        characters[Int(code) << 1 | (shifted ? 1 : 0)]
    }
}

/// The Remote Desktop session's `InputSink`. Positions arrive in the session's desktop pixels (the trackpad's canvas
/// is the size the app asked Windows for), so they go over the wire as they are, which RDP accepts directly.
final class RDPInput: InputSink {
    weak var output: (any RDPOutput)?
    /// Points of our scroll per wheel notch (Windows: 120 units a notch). The JetKVM's 12 points a step.
    static let pointsPerNotch = 12.0
    /// Each wheel event carries at most this much (9-bit signed rotation); smaller steps scroll smoothly.
    static let unitsPerEvent = 120
    var canvas = (width: 1920, height: 1080)
    /// The pointer position last sent (Follow Pointer follows it).
    private(set) var pointer: (x: Int, y: Int)?
    var onPointer: ((Int, Int) -> Void)?
    /// Locked: nothing reaches the PC (as the JetKVM). Tests set it to always open.
    var isOpen: () -> Bool = { AppAccess.isOpen }

    private var scroll = (x: 0.0, y: 0.0)
    /// Modifier keys down now (Mac code), pressed on the PC as Ctrl, Alt, ⊞ or Shift.
    private var modifiersDown: Set<UInt16> = []
    /// What each held key's down sent, so its up releases the same thing.
    private enum Sent { case unicode(UInt16), scan(RDPKeys.Scan, withShift: Bool) }
    private var held: [UInt16: Sent] = [:]
    /// At the sign-in prompt (set by the screen while the Password field shows): Duo Desktop's keyboard types into
    /// the Password field instead of the PC, and Return connects. Nothing reaches the PC while it is set.
    var prompt: ((RDPPromptKey) -> Void)?
    /// Shift held at the prompt (the band is off there, but a latched Shift may still arrive).
    private var promptShift: Set<UInt16> = []

    func sendInput(kind: UInt8, x: Int, y: Int, a: Int, b: Int) {
        if let prompt {
            promptInput(kind: kind, code: UInt16(truncatingIfNeeded: x),
                        flags: UInt32(bitPattern: Int32(truncatingIfNeeded: a)), to: prompt)
            return
        }
        guard isOpen() else { return }
        switch kind {
        case InputKind.move:
            out(.mouse(flags: RDPFlags.move, x: clampX(x), y: clampY(y)))
            note(x, y)
        case InputKind.buttonDown, InputKind.buttonUp:
            let button = b == 1 ? RDPFlags.right : RDPFlags.left
            out(.mouse(flags: button | (kind == InputKind.buttonDown ? RDPFlags.down : 0), x: clampX(x), y: clampY(y)))
            note(x, y)
        case InputKind.scrollPoints:
            pointer = (Int(clampX(x)), Int(clampY(y)))
            scrollBy(a: Double(a), b: Double(b))
        case InputKind.keyDown:
            keyDown(code: UInt16(truncatingIfNeeded: x), flags: UInt32(bitPattern: Int32(truncatingIfNeeded: a)))
        case InputKind.keyUp:
            keyUp(code: UInt16(truncatingIfNeeded: x))
        default:
            break
        }
    }

    /// Text the Mac keys cannot type (é, emoji, any character): Unicode key presses, one per UTF-16 unit.
    func type(_ c: Character) {
        if let prompt { prompt(.text(c)); return }
        guard isOpen() else { return }
        for u in String(c).utf16 {
            out(.unicode(flags: 0, code: u))
            out(.unicode(flags: RDPFlags.keyRelease, code: u))
        }
    }

    /// A key at the prompt: a character key types its character (shifted by its own Shift flag or a held Shift),
    /// ⌫ deletes the last one, Return (or Enter) connects. Other keys, and all pointer events, do nothing.
    private func promptInput(kind: UInt8, code: UInt16, flags: UInt32, to prompt: (RDPPromptKey) -> Void) {
        let shiftKeys: Set<UInt16> = [56, 60]
        switch kind {
        case InputKind.keyDown:
            if shiftKeys.contains(code) { promptShift.insert(code); return }
            if code == 36 || code == 76 { prompt(.submit); return }
            if code == 51 { prompt(.delete); return }
            let shifted = flags & MacKeyFlags.shift != 0 || !promptShift.isEmpty
            let command = KeyMap.Modifier([.control, .option, .command]).eventFlags
            guard flags & command == 0, let c = RDPKeys.character(code: code, shifted: shifted) else { return }
            prompt(.text(c))
        case InputKind.keyUp:
            promptShift.remove(code)
        default:
            break
        }
    }

    private func out(_ e: RDPEvent) { output?.send(e) }
    private func clampX(_ x: Int) -> UInt16 { UInt16(max(0, min(canvas.width - 1, x))) }
    private func clampY(_ y: Int) -> UInt16 { UInt16(max(0, min(canvas.height - 1, y))) }
    private func note(_ x: Int, _ y: Int) {
        let p = (Int(clampX(x)), Int(clampY(y)))
        pointer = p
        onPointer?(p.0, p.1)
    }

    /// Scroll: our points follow the fingers, as the Mac view posts them (content moves with the fingers). Windows'
    /// wheel has no natural flip, so fingers moving down (b > 0) is a wheel turned forward (positive, content down),
    /// and fingers moving right (a > 0) is the horizontal wheel turned left (negative, content right).
    private func scrollBy(a: Double, b: Double) {
        let k = Double(Self.unitsPerEvent) / Self.pointsPerNotch
        scroll.x += a * k
        scroll.y += b * k
        let vy = Int(scroll.y), vx = Int(scroll.x)
        scroll.y -= Double(vy)
        scroll.x -= Double(vx)
        wheel(RDPFlags.wheel, units: vy)
        wheel(RDPFlags.hWheel, units: -vx)
    }

    private func wheel(_ kind: UInt16, units: Int) {
        var left = units
        while left != 0 {
            let step = max(-Self.unitsPerEvent, min(Self.unitsPerEvent, left))
            left -= step
            let flags = step < 0 ? kind | RDPFlags.wheelNegative | UInt16((0x100 - (-step)) & 0xFF)
                                 : kind | UInt16(step & 0xFF)
            out(.mouse(flags: flags, x: clampX(pointer?.x ?? 0), y: clampY(pointer?.y ?? 0)))
        }
    }

    private func press(_ s: RDPKeys.Scan, up: Bool) {
        out(.key(flags: (s.extended ? RDPFlags.keyExtended : 0) | (up ? RDPFlags.keyRelease : 0), code: s.code))
    }

    /// A key down. Modifiers go as their PC keys. A character key with no Ctrl, Alt or ⊞ held goes as Unicode (the
    /// character it types on a US Mac, shifted by its own Shift flag). Everything else (named keys, shortcuts) goes
    /// as scan codes; a key's own Shift flag (a capital, a shifted symbol) is pressed as Shift around it.
    private func keyDown(code: UInt16, flags: UInt32) {
        if let m = RDPKeys.modifiers[code] {
            guard !modifiersDown.contains(code) else { return }
            modifiersDown.insert(code)
            press(m, up: false)
            return
        }
        let shifted = flags & MacKeyFlags.shift != 0
        let command = KeyMap.Modifier([.control, .option, .command]).eventFlags
        let chord = flags & command != 0 || modifiersDown.contains { $0 != 56 && $0 != 60 }
        if !chord, let c = RDPKeys.character(code: code, shifted: shifted), let u = String(c).utf16.first {
            // A repeat (another down while held) is pressed again, as a held key repeats.
            held[code] = .unicode(u)
            out(.unicode(flags: 0, code: u))
            return
        }
        guard let s = RDPKeys.keys[code] else { return }
        let shiftHeld = modifiersDown.contains(56) || modifiersDown.contains(60)
        let addShift = shifted && !shiftHeld
        if case .scan? = held[code] {
            press(s, up: false) // a repeat: the key again, Shift (if added) still down
            return
        }
        if addShift { press(RDPKeys.shift, up: false) }
        held[code] = .scan(s, withShift: addShift)
        press(s, up: false)
    }

    private func keyUp(code: UInt16) {
        if let m = RDPKeys.modifiers[code] {
            guard modifiersDown.remove(code) != nil else { return }
            press(m, up: true)
            return
        }
        switch held.removeValue(forKey: code) {
        case let .unicode(u)?:
            out(.unicode(flags: RDPFlags.keyRelease, code: u))
        case let .scan(s, withShift)?:
            press(s, up: true)
            if withShift { press(RDPKeys.shift, up: true) }
        case nil:
            break
        }
    }

    /// Everything up (view left, phone turned, app in the background): held keys, then modifiers. Mouse buttons
    /// are let go by the trackpad engine's own `releaseAll`, which sends their ups through here.
    func releaseAll() {
        for code in Array(held.keys) { keyUp(code: code) }
        for code in Array(modifiersDown) { keyUp(code: code) }
        scroll = (0, 0)
        promptShift = []
    }
}

/// What Duo Desktop's keyboard does to the Password field at the sign-in prompt (`RDPInput.prompt`).
enum RDPPromptKey: Equatable {
    case text(Character)
    case delete
    case submit

    /// Applies the key to the field's text; true when it was Return (connect).
    @discardableResult
    func apply(to text: inout String) -> Bool {
        switch self {
        case let .text(c): text.append(c)
        case .delete: if !text.isEmpty { text.removeLast() }
        case .submit: return true
        }
        return false
    }
}

/// Where the PC's picture sits in its view (the Mac view's rules, `PictureFit`): Whole Screen aspect-fits it with
/// black edges; Follow Pointer zooms it (`PictureFit.centredZoom`) with the pointer in the middle, stopping at the
/// desktop's edges.
enum RDPFollow {
    static func pictureFrame(canvasWidth: Int, canvasHeight: Int, in bounds: CGSize, screenScale: CGFloat,
                             follow: Bool, pointer: (x: Int, y: Int)) -> CGRect {
        guard follow else {
            return PictureFit.frame(canvasWidth: canvasWidth, canvasHeight: canvasHeight, in: bounds,
                                    screenScale: screenScale)
        }
        let zoom = PictureFit.centredZoom
        let pan = PictureFit.pan(centring: CGFloat(pointer.x), CGFloat(pointer.y), canvasWidth: canvasWidth,
                                 canvasHeight: canvasHeight, in: bounds, screenScale: screenScale, zoom: zoom)
        return PictureFit.zoomed(canvasWidth: canvasWidth, canvasHeight: canvasHeight, in: bounds,
                                 screenScale: screenScale, zoom: zoom, pan: pan).frame
    }
}
