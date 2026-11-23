// The Remote Desktop engine (project notes). FreeRDP 3 and OpenSSL 3, static, from
// scripts/build-freerdp.sh, linked only with the DUO_RDP switch. The session settings and the certificate rule below
// are in every build, so a build without the switch keeps a PC's saved settings.
import CryptoKit
import Foundation
#if DUO_RDP
import FreeRDP

enum RemoteDesktopEngine {
    /// FreeRDP's own version string, e.g. "3.33.1".
    static var freeRDPVersion: String { String(cString: freerdp_get_version_string()) }
}
#endif

/// The session a PC is asked for (plan §3). Windows draws a desktop this size on its own virtual screen; the PC's
/// monitors are not resized. Default 1920 x 1080 with text at 200% (the owner 2026-11-23: "What about 1080 at 200%?", then
/// "yes 1080p at 200%"); 150% stays a choice.
struct RDPScreen: Equatable {
    enum Size: String, Codable, CaseIterable, Identifiable, Hashable {
        case hd720, hd1080, qhd1440
        static let `default` = Size.hd1080
        var id: String { rawValue }
        var pixels: (width: UInt32, height: UInt32) {
            switch self {
            case .hd720: (1280, 720)
            case .hd1080: (1920, 1080)
            case .qhd1440: (2560, 1440)
            }
        }
        var label: String { "\(pixels.width) × \(pixels.height)" }
    }

    enum TextSize: Int, Codable, CaseIterable, Identifiable, Hashable {
        case p100 = 100, p125 = 125, p150 = 150, p200 = 200
        static let `default` = TextSize.p200
        var id: Int { rawValue }
        var label: String { "\(rawValue)%" }
    }

    var size: Size = .default
    var textSize: TextSize = .default

    var width: UInt32 { size.pixels.width }
    var height: UInt32 { size.pixels.height }
    /// The desktop scale factor sent to Windows (MS-RDPBCGR TS_UD_CS_CORE desktopScaleFactor, 100-500).
    var desktopScale: UInt32 { UInt32(textSize.rawValue) }
    /// The device scale factor that goes with it. MS-RDPBCGR allows only 100, 140 or 180; Microsoft's own clients
    /// pick the step at or below the desktop scale.
    var deviceScale: UInt32 { desktopScale >= 180 ? 180 : desktopScale >= 140 ? 140 : 100 }

    /// Whether this build can open a PC (the DUO_RDP switch).
    static var inThisBuild: Bool {
        #if DUO_RDP
        true
        #else
        false
        #endif
    }
}

/// Trust on first use for a PC's certificate (plan §4): the first time, the person sees the PC's name and the
/// SHA-256 fingerprint and chooses Trust and Connect; after that only the same certificate is let through, and a
/// different one is refused in plain words (Forget Certificate is milestone 3).
enum RDPTrust: Equatable {
    /// Nothing saved yet: ask.
    case askFirstTime(fingerprint: String)
    /// The saved one: connect.
    case known
    /// Not the saved one: refuse.
    case changed(fingerprint: String)

    static func decide(saved: String?, presented: String) -> RDPTrust {
        guard let saved else { return .askFirstTime(fingerprint: presented) }
        return saved.caseInsensitiveCompare(presented) == .orderedSame ? .known : .changed(fingerprint: presented)
    }

    /// SHA-256 of the certificate, upper-case hex pairs with colons. FreeRDP hands over either the certificate in PEM
    /// (VERIFY_CERT_FLAG_FP_IS_PEM) or its own fingerprint text; PEM is hashed over its DER bytes, anything else is
    /// kept as given (normalised).
    static func fingerprint(fromFreeRDP text: String, isPEM: Bool) -> String {
        if isPEM {
            let body = text.split(separator: "\n")
                .filter { !$0.hasPrefix("-----") }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let der = Data(base64Encoded: body, options: .ignoreUnknownCharacters) {
                return SHA256.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
            }
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// The takeover notice (plan §3), said once before each connect unless the PC's settings skip it.
    static func takeoverText(_ name: String) -> String {
        "Anyone using \(name) now is disconnected from it while you are connected. Their apps stay open, and they get them back when they sign in at the PC."
    }
}
