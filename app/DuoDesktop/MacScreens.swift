// A Mac with several screens. Pure parts here (the screens as the phone keeps them, the overview's layout, the per-Mac
// memory); the session model asks the Host, the views draw.
import CoreGraphics
import Foundation
import GlassActWire
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// One of the Mac's screens, from the Host's screen list. Place and size in global points (the main screen's
/// top-left is 0,0; others may be negative).
struct MacScreen: Identifiable, Equatable {
    let id: UInt32
    let name: String
    let frame: CGRect
    let isMain: Bool
    let isShown: Bool
    var thumbnail: UIImage?

    init(_ d: WireDisplay) {
        id = d.displayID
        name = d.name.isEmpty ? "Screen \(d.displayID)" : d.name
        frame = CGRect(x: Int(d.x), y: Int(d.y), width: Int(d.width), height: Int(d.height))
        isMain = d.isMain
        isShown = d.isShown
        thumbnail = Self.decode(d)
    }

    init(id: UInt32, name: String, frame: CGRect, isMain: Bool, isShown: Bool = false) {
        self.id = id
        self.name = name
        self.frame = frame
        self.isMain = isMain
        self.isShown = isShown
    }

    /// The middle of the screen, in global points: where the Host puts the pointer on a switch (plan item 7).
    var middle: (x: Int32, y: Int32) { (Int32(frame.midX.rounded(.down)), Int32(frame.midY.rounded(.down))) }

    static func == (a: MacScreen, b: MacScreen) -> Bool {
        a.id == b.id && a.name == b.name && a.frame == b.frame && a.isMain == b.isMain && a.isShown == b.isShown
    }

    /// The small picture comes from the Mac, so only the still-image formats the Host makes (WebP, AVIF/HEIF,
    /// JPEG; the format byte is advisory) are decoded, at thumbnail size, as Glass Act's own window picker does.
    static func decode(_ d: WireDisplay) -> UIImage? { decodeStill(d.thumb) }

    /// A still from the Host (the list's small picture or an All Screens snapshot), decoded only if it is one of
    /// the formats above and at most 1024 pixels a side.
    static func decodeStill(_ bytes: [UInt8]) -> UIImage? {
        let allowed: Set<String> = [UTType.webP.identifier, "public.avif", UTType.heic.identifier,
                                    UTType.heif.identifier, UTType.jpeg.identifier]
        guard !bytes.isEmpty,
              let source = CGImageSourceCreateWithData(Data(bytes) as CFData, nil),
              let type = CGImageSourceGetType(source) as String?, allowed.contains(type),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
              (1...1024).contains(w), (1...1024).contains(h),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return UIImage(cgImage: image)
    }
}

/// The overview: every screen placed and sized as on the Mac, scaled together to fit the picture area.
enum ScreenOverviewLayout {
    /// Each screen's rectangle in an area of `size`, keeping the arrangement (gaps, offsets, shapes). Room is left
    /// for each name under its screen (`labelHeight`) and a margin round the whole.
    static func place(_ screens: [MacScreen], in size: CGSize, margin: CGFloat = 16,
                      labelHeight: CGFloat = 18) -> [UInt32: CGRect] {
        guard let first = screens.first else { return [:] }
        let bounds = screens.dropFirst().reduce(first.frame) { $0.union($1.frame) }
        let room = CGSize(width: size.width - 2 * margin, height: size.height - 2 * margin - labelHeight)
        guard bounds.width > 0, bounds.height > 0, room.width > 0, room.height > 0 else { return [:] }
        let scale = min(room.width / bounds.width, room.height / bounds.height)
        let used = CGSize(width: bounds.width * scale, height: bounds.height * scale)
        let origin = CGPoint(x: (size.width - used.width) / 2, y: (size.height - labelHeight - used.height) / 2)
        var out: [UInt32: CGRect] = [:]
        for s in screens {
            out[s.id] = CGRect(x: origin.x + (s.frame.minX - bounds.minX) * scale,
                               y: origin.y + (s.frame.minY - bounds.minY) * scale,
                               width: s.frame.width * scale, height: s.frame.height * scale)
        }
        return out
    }
}

/// The last screen used on each Mac (plan item 11). Kept by name and place, not by number: macOS can renumber
/// screens after a restart or replug (plan, Risks). If that screen is gone, the main screen.
struct RememberedScreen: Codable, Equatable {
    var name: String
    var x: Int
    var y: Int

    init(_ s: MacScreen) {
        name = s.name
        x = Int(s.frame.minX)
        y = Int(s.frame.minY)
    }

    static func storageKey(mac: String) -> String { "screen.\(mac)" }

    static func stored(mac: String, in defaults: UserDefaults = .standard) -> RememberedScreen? {
        defaults.data(forKey: storageKey(mac: mac)).flatMap { try? JSONDecoder().decode(Self.self, from: $0) }
    }

    func store(mac: String, in defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.storageKey(mac: mac)) }
    }

    /// The screen to open on: the same name and place; else the same name; else main.
    static func resolve(_ remembered: RememberedScreen?, in screens: [MacScreen]) -> MacScreen? {
        if let r = remembered {
            if let s = screens.first(where: { $0.name == r.name && Int($0.frame.minX) == r.x
                                                && Int($0.frame.minY) == r.y }) { return s }
            if let s = screens.first(where: { $0.name == r.name }) { return s }
        }
        return screens.first(where: \.isMain) ?? screens.first
    }
}

/// Crossing an edge with the trackpad (plan item 13, M5). Pure: where a push past the shown screen's edge goes.
enum EdgeCrossing {
    /// Which way a push past the edge went, -1/0/1 on each axis (left/up negative). The crossing slide moves the
    /// content the other way: push right → content moves left.
    static func direction(px: Double, py: Double, width: Int, height: Int) -> (dx: Int, dy: Int) {
        (px < 0 ? -1 : px >= Double(width) ? 1 : 0, py < 0 ? -1 : py >= Double(height) ? 1 : 0)
    }

    /// Screens closer than this (global points) count as touching: macOS arranges screens edge to edge.
    static let touching: CGFloat = 1

    struct Target: Equatable {
        let screen: MacScreen
        /// Where the pointer enters, in global points: the matching spot along the shared edge, just inside.
        let x: Int32
        let y: Int32
    }

    /// The pointer pushed to canvas pixel (`px`, `py`) of a `width` x `height` picture of `shown` (outside the
    /// picture on at least one side). The neighbour on that side at that spot, or nil: a gap, an offset screen or
    /// the outside edge is a wall. Sideways first, then up or down (a push into a corner).
    static func target(from shown: MacScreen, in screens: [MacScreen], px: Double, py: Double,
                       width: Int, height: Int) -> Target? {
        guard width > 0, height > 0 else { return nil }
        let f = shown.frame
        // The spot along the edge, in global points, kept on the shown screen.
        let gx = f.minX + CGFloat(min(max(px, 0), Double(width - 1))) * f.width / CGFloat(width)
        let gy = f.minY + CGFloat(min(max(py, 0), Double(height - 1))) * f.height / CGFloat(height)
        let others = screens.filter { $0.id != shown.id }
        func along(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> Bool { v >= lo && v < hi }
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) <= touching }
        func inside(_ v: CGFloat, _ lo: CGFloat, _ hi: CGFloat) -> Int32 { Int32(min(max(v, lo), hi - 1).rounded(.down)) }
        if px < 0, let n = others.first(where: { near($0.frame.maxX, f.minX) && along(gy, $0.frame.minY, $0.frame.maxY) }) {
            return Target(screen: n, x: Int32(n.frame.maxX - 1), y: inside(gy, n.frame.minY, n.frame.maxY))
        }
        if px > Double(width - 1), let n = others.first(where: { near($0.frame.minX, f.maxX) && along(gy, $0.frame.minY, $0.frame.maxY) }) {
            return Target(screen: n, x: Int32(n.frame.minX + 1), y: inside(gy, n.frame.minY, n.frame.maxY))
        }
        if py < 0, let n = others.first(where: { near($0.frame.maxY, f.minY) && along(gx, $0.frame.minX, $0.frame.maxX) }) {
            return Target(screen: n, x: inside(gx, n.frame.minX, n.frame.maxX), y: Int32(n.frame.maxY - 1))
        }
        if py > Double(height - 1), let n = others.first(where: { near($0.frame.minY, f.maxY) && along(gx, $0.frame.minX, $0.frame.maxX) }) {
            return Target(screen: n, x: inside(gx, n.frame.minX, n.frame.maxX), y: Int32(n.frame.minY + 1))
        }
        return nil
    }

    /// A global point on `screen` in its picture's pixels (`width` x `height`).
    static func pixel(_ x: Int32, _ y: Int32, on screen: MacScreen, width: Int, height: Int) -> (Int, Int) {
        let f = screen.frame
        guard f.width > 0, f.height > 0 else { return (0, 0) }
        return (Int((CGFloat(x) - f.minX) * CGFloat(width) / f.width),
                Int((CGFloat(y) - f.minY) * CGFloat(height) / f.height))
    }
}
