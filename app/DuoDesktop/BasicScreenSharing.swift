// Basic Screen Sharing: a Mac's own Screen Sharing, for Macs without Glass Act Host (project notes,
// milestone 0). Linked only with the DUO_VNC switch: our copy of RoyalVNCKit (../royalvnc, MIT) and CryptoSwift.
// Milestone 0 only links the library and names it in About; nothing here connects to any computer.
#if DUO_VNC
import RoyalVNCKit

enum BasicScreenSharingEngine {
    /// The upstream RoyalVNCKit commit our copy was taken at (../royalvnc/ROYALVNC_COMMIT).
    static let royalVNCKitCommit = "090b96eddeee183e9fec293c5cd881d302a4349d"

    /// Settings for a connection to a Mac (no connection is made): the Mac's own Screen Sharing port, view only
    /// until milestone 2, and the library's clipboard polling off (plan §3 item 5).
    static func settings(host: String, port: UInt16 = 5900) -> VNCConnection.Settings {
        VNCConnection.Settings(isDebugLoggingEnabled: false,
                               hostname: host,
                               port: port,
                               isShared: true,
                               isScalingEnabled: false,
                               useDisplayLink: false,
                               inputMode: .none,
                               isClipboardRedirectionEnabled: false,
                               colorDepth: .depth24Bit,
                               frameEncodings: .default)
    }
}
#endif
