import GlassActSession
import GlassActWire

/// What the app may ask a Host for its picture (DESIGN §4.10, `HELLO_OK` geometry). The ONLY place in the app
/// that makes a geometry request. Scale (2) at 1920 x 1080: the Host scales its capture of the main display and
/// leaves the display alone. Native (3): nothing changes. Never Client Resolution (1: switches the physical
/// display's mode) and never Virtual Display (4: makes a display and mirrors every other one onto it, which on
/// this Mac would take over its second screen). A test proves 1 and 4 cannot be sent.
protocol GeometrySink: AnyObject {
    func setRequestedGeometry(mode: UInt8, widthPoints: Int, heightPoints: Int, scale: Int)
}

extension ViewerController: GeometrySink {}

enum GeometryGuard {
    static let width = 1920
    static let height = 1080
    static let allowedModes: Set<UInt8> = [GeometryMode.scale, GeometryMode.native]

    /// Whether `mode` may ever leave this app.
    static func isAllowed(_ mode: UInt8) -> Bool { allowedModes.contains(mode) }

    /// Sends the handshake geometry request if `mode` is allowed; refuses (and sends nothing) otherwise.
    @discardableResult
    static func request(mode: UInt8, on sink: any GeometrySink) -> Bool {
        guard isAllowed(mode) else { return false }
        sink.setRequestedGeometry(mode: mode, widthPoints: width, heightPoints: height, scale: 1)
        return true
    }

    /// The app's one request: Scale at 1920 x 1080.
    static func requestStandard(on sink: any GeometrySink) {
        request(mode: GeometryMode.scale, on: sink)
    }
}
