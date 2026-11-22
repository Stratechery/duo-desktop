import Foundation

/// The JetKVM "hidrpc" binary data-channel messages. First byte is the message type, the rest is the payload.
/// Layouts are facts read from the device's public source (jetkvm/kvm, internal/hidrpc); this code is our own.
public enum HIDRPC {
    /// Protocol version this client speaks. The device answers our handshake with its own version byte.
    public static let supportedVersion: UInt8 = 0x01

    public enum MessageType: UInt8 {
        case handshake = 0x01
        case keyboardReport = 0x02
        case pointerReport = 0x03
        case wheelReport = 0x04
        case keypressReport = 0x05
        case mouseReport = 0x06
        case keyboardMacroReport = 0x07
        case cancelKeyboardMacroReport = 0x08
        case keypressKeepAliveReport = 0x09
        case keyboardLEDState = 0x32
        case keydownState = 0x33
        case keyboardMacroState = 0x34
    }

    /// Absolute pointer coordinates run 0...32767 on both axes (the absolute-mouse HID descriptor's range).
    public static let pointerMax: Int32 = 32767

    /// Mouse buttons bit mask.
    public struct Buttons: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let primary = Buttons(rawValue: 1 << 0)
        public static let secondary = Buttons(rawValue: 1 << 1)
        public static let middle = Buttons(rawValue: 1 << 2)
    }

    /// USB HID keyboard modifier bits.
    public struct Modifiers: OptionSet, Sendable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }
        public static let leftControl = Modifiers(rawValue: 1 << 0)
        public static let leftShift = Modifiers(rawValue: 1 << 1)
        public static let leftOption = Modifiers(rawValue: 1 << 2)
        public static let leftCommand = Modifiers(rawValue: 1 << 3)
        public static let rightControl = Modifiers(rawValue: 1 << 4)
        public static let rightShift = Modifiers(rawValue: 1 << 5)
        public static let rightOption = Modifiers(rawValue: 1 << 6)
        public static let rightCommand = Modifiers(rawValue: 1 << 7)
    }

    // MARK: Encoding (client → device)

    public static func handshake(version: UInt8 = supportedVersion) -> Data {
        Data([MessageType.handshake.rawValue, version])
    }

    /// One key down or up, by USB HID usage (page 0x07). Modifier keys (0xE0...0xE7) are sent the same way.
    public static func keypress(usage: UInt8, down: Bool) -> Data {
        Data([MessageType.keypressReport.rawValue, usage, down ? 1 : 0])
    }

    /// Full keyboard state: modifier byte + up to six held keys.
    public static func keyboardReport(modifiers: Modifiers, keys: [UInt8]) -> Data {
        var d = Data([MessageType.keyboardReport.rawValue, modifiers.rawValue])
        d.append(contentsOf: keys.prefix(6))
        return d
    }

    /// Absolute pointer. x and y are clamped to 0...32767 and sent big-endian, 4 bytes each, then the button mask.
    public static func pointer(x: Int32, y: Int32, buttons: Buttons) -> Data {
        var d = Data([MessageType.pointerReport.rawValue])
        d.append(contentsOf: bigEndian(clamp(x)))
        d.append(contentsOf: bigEndian(clamp(y)))
        d.append(buttons.rawValue)
        return d
    }

    /// Absolute pointer from a normalised position (0...1 across the picture, origin top-left).
    public static func pointer(normalizedX: Double, normalizedY: Double, buttons: Buttons) -> Data {
        pointer(x: scale(normalizedX), y: scale(normalizedY), buttons: buttons)
    }

    /// Relative mouse move, each axis -127...127.
    public static func mouse(dx: Int, dy: Int, buttons: Buttons) -> Data {
        Data([MessageType.mouseReport.rawValue, UInt8(bitPattern: int8(dx)), UInt8(bitPattern: int8(dy)), buttons.rawValue])
    }

    /// Firmware up to 0.5.10 has no binary wheel message (its hidrpc handler drops type 0x04); wheel steps go as
    /// the JSON-RPC call `wheelReport` on the `rpc` channel instead. From 0.5.11 the JSON-RPC call is gone and the
    /// binary message works (jetkvm/kvm `hidrpc.go`, `jsonrpc.go` at release/0.5.10 and release/0.5.11-dev). An
    /// unknown version uses the binary message (the current protocol).
    public static func wheelOverJSONRPC(deviceVersion: String?) -> Bool {
        guard let v = deviceVersion else { return false }
        let core = v.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? v
        let n = core.split(separator: ".").map { Int($0) ?? -1 }
        guard n.count >= 3, !n.contains(-1) else { return false }
        return (n[0], n[1], n[2]) <= (0, 5, 10)
    }

    /// The JSON-RPC wheel call for firmware up to 0.5.10 (positive y = scroll up, as a HID wheel).
    public static func wheelJSONRPC(dy: Int, dx: Int = 0, id: Int) -> String {
        "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"wheelReport\",\"params\":{\"wheelY\":\(int8(dy)),\"wheelX\":\(int8(dx))}}"
    }

    /// Wheel: vertical first, then horizontal, each -127...127 (positive y = scroll up, as a HID wheel).
    public static func wheel(dy: Int, dx: Int = 0) -> Data {
        Data([MessageType.wheelReport.rawValue, UInt8(bitPattern: int8(dy)), UInt8(bitPattern: int8(dx))])
    }

    public static func keypressKeepAlive() -> Data { Data([MessageType.keypressKeepAliveReport.rawValue]) }

    // MARK: Decoding (device → client)

    public enum Incoming: Equatable, Sendable {
        case handshake(version: UInt8)
        case keyboardLEDs(UInt8)
        case keysDown(modifiers: UInt8, keys: [UInt8])
        case macroState(running: Bool)
        case unknown(type: UInt8, payload: Data)
    }

    public static func decode(_ data: Data) -> Incoming? {
        let bytes = [UInt8](data)
        guard let first = bytes.first else { return nil }
        let payload = Array(bytes.dropFirst())
        switch MessageType(rawValue: first) {
        case .handshake:
            guard let v = payload.first else { return .unknown(type: first, payload: Data(payload)) }
            return .handshake(version: v)
        case .keyboardLEDState:
            return .keyboardLEDs(payload.first ?? 0)
        case .keydownState:
            return .keysDown(modifiers: payload.first ?? 0, keys: Array(payload.dropFirst()))
        case .keyboardMacroState:
            return .macroState(running: (payload.first ?? 0) == 1)
        default:
            return .unknown(type: first, payload: Data(payload))
        }
    }

    // MARK: Helpers

    static func clamp(_ v: Int32) -> Int32 { max(0, min(pointerMax, v)) }
    static func scale(_ n: Double) -> Int32 {
        guard n.isFinite else { return 0 }
        return clamp(Int32((max(0, min(1, n)) * Double(pointerMax)).rounded()))
    }
    static func int8(_ v: Int) -> Int8 { Int8(max(-127, min(127, v))) }
    static func bigEndian(_ v: Int32) -> [UInt8] {
        let u = UInt32(bitPattern: v)
        return [UInt8(u >> 24 & 0xFF), UInt8(u >> 16 & 0xFF), UInt8(u >> 8 & 0xFF), UInt8(u & 0xFF)]
    }
}
