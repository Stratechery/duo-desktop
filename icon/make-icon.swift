// Duo Desktop's app icon, drawn in code: an orange square with the iOS continuous-corner mask, a black frame line
// close around the layout, and the layout itself (the screen on top, the band of three buttons, three rows of keys).
// The screen is black with a thin white outline and holds a white fedora with an orange band.
// Corners use the real iOS mask (continuous, radius 229 at 1024); a shape inset d is concentric at radius 229 - d.
// Z1 is the app icon (Z2 and Z3 are the same drawing with a half and a one-and-a-half key gap inside the frame line).
// Only system frameworks; nothing to install.
// Usage: DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift make-icon.swift Z1 duo-desktop-icon-1024.png
import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

func rgb(_ hex: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: 1)
}
let white = rgb(0xFFFFFF), dark = rgb(0x15161A), bg = rgb(0xFAA634)
let size: CGFloat = 1024, maskR: CGFloat = 0.2237 * 1024
let art = CGRect(x: 164, y: 167, width: 696, height: 690)
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
ctx.translateBy(x: 0, y: size); ctx.scaleBy(x: 1, y: -1)   // y grows downward

/// The iOS continuous-corner shape (same curve family as the icon mask).
func squircle(_ r: CGRect, _ radius: CGFloat) -> CGPath {
    RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: r).cgPath
}
/// Concentric with the icon mask at inset d.
func maskInset(_ d: CGFloat) -> CGPath { squircle(CGRect(x: 0, y: 0, width: size, height: size).insetBy(dx: d, dy: d), maskR - d) }
func fill(_ col: CGColor, _ r: CGRect) { ctx.setFillColor(col); ctx.fill(r) }
func fillPath(_ col: CGColor, _ p: CGPath) { ctx.setFillColor(col); ctx.addPath(p); ctx.fillPath() }
func round(_ col: CGColor, _ r: CGRect, _ radius: CGFloat) {
    fillPath(col, CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
}

// The fedora (the family's mark), with crown/brim and band colours as parameters.
func fedora(cx: CGFloat, brimBottom: CGFloat, scale s: CGFloat, body: CGColor = dark, band: CGColor = white) {
    ctx.saveGState(); ctx.translateBy(x: cx, y: brimBottom); ctx.scaleBy(x: s, y: s)
    let crown = CGMutablePath()
    crown.move(to: CGPoint(x: -160, y: -32))
    crown.addLine(to: CGPoint(x: -132, y: -162))
    crown.addQuadCurve(to: CGPoint(x: 0, y: -158), control: CGPoint(x: -72, y: -218))
    crown.addQuadCurve(to: CGPoint(x: 132, y: -162), control: CGPoint(x: 72, y: -218))
    crown.addLine(to: CGPoint(x: 160, y: -32))
    crown.closeSubpath()
    fillPath(body, crown)
    ctx.saveGState(); ctx.addPath(crown); ctx.clip()
    fill(band, CGRect(x: -212, y: -82, width: 424, height: 30))
    ctx.restoreGState()
    round(body, CGRect(x: -272, y: -50, width: 544, height: 50), 25)
    ctx.restoreGState()
}

// The layout from the hand sketch, in icon pixels at its app-icon place. Returns the top bar's rect.
@discardableResult
func duoArt(bar barCol: CGColor = white, parts: CGColor = white, outerKeyR: CGFloat? = nil, barExtra: CGFloat = 0) -> CGRect {
    let W: CGFloat = 696, G0: CGFloat = 28, m: CGFloat = 1.5
    let screenH0: CGFloat = 252, midH0: CGFloat = 150, kh0: CGFloat = 64, kg0: CGFloat = 20, rows = 3, cols = 7
    let total = screenH0 + 2 * G0 + midH0 + CGFloat(rows) * kh0 + CGFloat(rows - 1) * kg0     // 690
    let g = G0 * m, kg = kg0 * m
    let fh = (total - 2 * g - CGFloat(rows - 1) * kg) / (total - 2 * G0 - CGFloat(rows - 1) * kg0)
    let fw = (W - 2 * g) / (W - 2 * G0)
    let screenH = screenH0 * fh + barExtra, midH = midH0 * fh - barExtra, kh = kh0 * fh
    let x0 = art.minX
    var y = art.minY
    let bar = CGRect(x: x0, y: y, width: W, height: screenH)
    round(barCol, bar, 40 * fh); y += screenH + g
    let w1 = 104 * fw, w2 = 220 * fw, w3 = W - w1 - w2 - 2 * g, mr = 26 * min(fh, fw)
    round(parts, CGRect(x: x0, y: y, width: w1, height: midH), mr)
    round(parts, CGRect(x: x0 + w1 + g, y: y, width: w2, height: midH), mr)
    round(parts, CGRect(x: x0 + w1 + w2 + 2 * g, y: y, width: w3, height: midH), mr); y += midH + g
    let u = (W - CGFloat(cols - 1) * kg) / CGFloat(cols)
    let ku = u / ((W - 6 * kg0) / 7), kr = 16 * min(ku, fh)
    for row in 0..<rows {
        let widths: [CGFloat] = row < rows - 1 ? Array(repeating: 1, count: cols) : [1, 1, 3, 1, 1]
        var x = x0
        for n in widths {
            let w = n * u + (n - 1) * kg
            let key = CGRect(x: x, y: y, width: w, height: kh)
            round(parts, key, kr)
            x += w + kg
        }
        y += kh + kg
    }
    return bar
}

let hatScale: CGFloat = 442.0 / 544
func hatIn(_ bar: CGRect, body: CGColor = dark, band: CGColor = white) {
    fedora(cx: bar.midX, brimBottom: bar.midY + 189 * hatScale / 2, scale: hatScale, body: body, band: band)
}
let layoutScale: CGFloat = 0.84, barExtra: CGFloat = 24        // barExtra in layout units (20 px after scaling)
let ringW: CGFloat = 34                                         // black ring at the icon edge (2 px at 60 px)
let lineW: CGFloat = 28, lineOut: CGFloat = 70                  // frame line: 28 px wide

let args = Array(CommandLine.arguments.dropFirst())
guard args.count == 2, ["Z1", "Z2", "Z3"].contains(args[0]) else { fatalError("usage: make-duo-z-black-screen.swift <Z1|Z2|Z3> <out.png>") }
let v = "Z"
// Layout's left edge after scaling (219.7 px) and one key gap after scaling (30 layout units -> 25.2 px).
let layoutIn = size / 2 - (size / 2 - art.minX) * layoutScale, keyGap: CGFloat = 20 * 1.5 * layoutScale
let gap = keyGap * ["Z1": 1.0, "Z2": 0.5, "Z3": 1.5][args[0]]!
let lineOutT = layoutIn - gap - lineW                          // outer edge of the frame line, inset from the icon edge
fill(bg, CGRect(x: 0, y: 0, width: size, height: size))
if v != "Z" {
    // Ring: everything outside the mask inset by ringW is black, so its outer edge IS the icon edge, and the square's
    // corners outside the mask are black too (orange there bled into the ring's corners when scaled down to 60 px).
    fill(dark, CGRect(x: 0, y: 0, width: size, height: size)); fillPath(bg, maskInset(ringW))
}
ctx.setStrokeColor(v == "X" ? white : dark); ctx.setLineWidth(lineW)
ctx.addPath(maskInset(lineOutT + lineW / 2)); ctx.strokePath()
// Layout scaled about the icon centre.
ctx.saveGState()
ctx.translateBy(x: size / 2, y: size / 2); ctx.scaleBy(x: layoutScale, y: layoutScale); ctx.translateBy(x: -size / 2, y: -size / 2)
let barL = duoArt(bar: dark, barExtra: barExtra)
ctx.restoreGState()
let bar = CGRect(x: size / 2 + (barL.minX - size / 2) * layoutScale, y: size / 2 + (barL.minY - size / 2) * layoutScale,
                 width: barL.width * layoutScale, height: barL.height * layoutScale)
// The screen's outline: 14 px white, inside the bar's edge, corner concentric with the bar's own (scaled) corner.
let fhL: CGFloat = 546.0 / 594, barR = 40 * fhL * layoutScale, olW: CGFloat = 14
ctx.setStrokeColor(white); ctx.setLineWidth(olW)
ctx.addPath(CGPath(roundedRect: bar.insetBy(dx: olW / 2, dy: olW / 2), cornerWidth: barR - olW / 2,
                   cornerHeight: barR - olW / 2, transform: nil)); ctx.strokePath()
hatIn(bar, body: white, band: bg)
FileHandle.standardError.write("line outer \(lineOutT) gap \(gap) bar \(bar) art \(art.minX) -> \(size / 2 + (art.minX - size / 2) * layoutScale)\n".data(using: .utf8)!)

let image = ctx.makeImage()!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[1]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(args[1])") }
print("wrote \(args[1])")
