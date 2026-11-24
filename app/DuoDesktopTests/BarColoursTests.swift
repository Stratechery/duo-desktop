import SwiftUI
import UIKit
import XCTest
@testable import DuoDesktop

/// on build 83 the JetKVM and Remote Desktop bars drew white words on a white bar in light mode (the dark look was
/// forced on them as on Terminal, whose screen alone is black behind the bar); before that, build 81's Terminal bar
/// drew dark words on black. For every session kind, light and dark, at the open Duo's 669 pt and on this simulator's
/// width as a normal iPhone: the title's and the second line's resolved colours against the colour actually drawn
/// behind the bar: the title 4.5:1 or more, the second line 3:1 or more.
@MainActor
final class BarColoursTests: XCTestCase {

    /// WCAG relative luminance of an sRGB colour.
    static func luminance(_ c: UIColor) -> CGFloat {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        func lin(_ v: CGFloat) -> CGFloat {
            let v = min(max(v, 0), 1)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    static func contrast(_ a: UIColor, _ b: UIColor) -> CGFloat {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// A text colour as drawn over `behind`: resolved in the label's own traits, its alpha blended in.
    static func drawn(_ text: UIColor, over behind: UIColor) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        text.getRed(&r, green: &g, blue: &b, alpha: &a)
        behind.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return UIColor(red: r * a + br * (1 - a), green: g * a + bg * (1 - a), blue: b * a + bb * (1 - a), alpha: 1)
    }

    /// The colour drawn at one window point (the window rendered as it shows, read from an RGBA buffer of our own).
    static func pixel(_ window: UIWindow, at p: CGPoint) -> UIColor {
        var px = [UInt8](repeating: 0, count: 4)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            // UIKit's top-left origin in a 1x1 buffer: flip, then move the point to (0, 0).
            ctx.translateBy(x: 0, y: 1)
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: -p.x, y: -p.y)
            UIGraphicsPushContext(ctx)
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            UIGraphicsPopContext()
        }
        return UIColor(red: CGFloat(px[0]) / 255, green: CGFloat(px[1]) / 255, blue: CGFloat(px[2]) / 255, alpha: 1)
    }

    func testBarWordsStandOutFromWhatIsBehindTheBar() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let phoneWidth = scene.screen.bounds.width
        var ran = 0
        var failures: [String] = []
        let name = NormalIPhoneTopBarTests.names[1]
        for (form, width, phone) in [("iphone", phoneWidth, true), ("duo-669", 669, false)] as [(String, CGFloat, Bool)] {
            for kind in NormalIPhoneTopBarTests.Kind.allCases {
                for style in [UIUserInterfaceStyle.light, .dark] {
                    let bar = try await NormalIPhoneTopBarTests.show(kind, name: name, normalPhone: phone,
                                                                     width: width, style: style)
                    defer { bar.window.isHidden = true }
                    guard bar.nav.topItem?.title == name else { continue }   // this build has no such screen
                    ran += 1
                    let what = "\(form) \(kind) \(style == .light ? "light" : "dark")"
                    let labels = TopBarOneScreenSecondLineTests.all(UILabel.self, in: bar.nav).filter { !$0.isHidden }
                    let title = try XCTUnwrap(labels.first { $0.text == name }, "\(what): the title")
                    let frame = title.convert(title.bounds, to: nil)
                    // Behind the bar: a point in the bar's height at the window's left edge, clear of the caret.
                    let behind = Self.pixel(bar.window, at: CGPoint(x: 2, y: frame.midY))
                    var checked = [title]
                    if let second = labels.first(where: { $0 !== title && $0.text == Self.secondLine(kind) }) {
                        checked.append(second)
                    }
                    for label in checked {
                        let text = Self.drawn(label.textColor.resolvedColor(with: label.traitCollection), over: behind)
                        let ratio = Self.contrast(text, behind)
                        print("DUO-TEST bar-colours \(what) '\(label.text ?? "")': text \(text) behind \(behind) \(ratio):1")
                        // The title: 4.5:1. The second line is Apple's own secondary gray, 3.44:1 on white by the
                        // system's design (unchanged here); it is held to 3:1, which white on white (1.1:1) and gray on
                        // black (1.36:1 in light mode) both fail.
                        let floor: CGFloat = label === title ? 4.5 : 3.0
                        if ratio < floor { failures.append("\(what) '\(label.text ?? "")' \(String(format: "%.2f", ratio)):1") }
                    }
                }
            }
        }
        XCTAssertGreaterThan(ran, 0)
        XCTAssertTrue(failures.isEmpty, "below 4.5:1: \(failures)")
    }

    /// The second line each kind shows for the test's computer.
    static func secondLine(_ kind: NormalIPhoneTopBarTests.Kind) -> String {
        switch kind {
        case .screenSharing: "Screen Sharing"
        case .terminal: "Terminal"
        case .jetkvm: "JetKVM"
        case .remoteDesktop: "Remote Desktop"
        }
    }
}
