import CoreGraphics
import WebRTC

/// I420 → RGBA CGImage (BT.601 limited range). Used for snapshots only.
enum I420 {
    static func cgImage(from b: RTCI420BufferProtocol) -> CGImage? {
        let w = Int(b.width), h = Int(b.height)
        guard w > 0, h > 0 else { return nil }
        var out = [UInt8](repeating: 255, count: w * h * 4)
        let y = b.dataY, u = b.dataU, v = b.dataV
        let sy = Int(b.strideY), su = Int(b.strideU), sv = Int(b.strideV)
        for row in 0..<h {
            for col in 0..<w {
                let Y = Double(y[row * sy + col]) - 16
                let U = Double(u[(row / 2) * su + col / 2]) - 128
                let V = Double(v[(row / 2) * sv + col / 2]) - 128
                let r = 1.164 * Y + 1.596 * V
                let g = 1.164 * Y - 0.392 * U - 0.813 * V
                let bl = 1.164 * Y + 2.017 * U
                let i = (row * w + col) * 4
                out[i] = UInt8(max(0, min(255, r)))
                out[i + 1] = UInt8(max(0, min(255, g)))
                out[i + 2] = UInt8(max(0, min(255, bl)))
            }
        }
        guard let provider = CGDataProvider(data: Data(out) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
