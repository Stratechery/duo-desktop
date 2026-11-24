import GlassActCore
import GlassActSession
import UIKit

/// The phone's clipboard in a session, through Glass Act's own clipboard sync (`ViewerController.pasteboard`, CLIPBOARD
/// message, UTF-8 text only — the library carries text and nothing else).
///
/// - Mac → phone: automatic. The library calls `setText`; writing the pasteboard never asks (Apple's UIPasteboard
///   page describes alerts only for apps that "get" or "pull" content).
/// - Phone → Mac: the Paste key is the system paste control, which reads with no prompt. Automatic sync of the
///   phone's copies is a switch, off by default (`autoSend`): iOS gives an app no way to read its "Paste from
///   Other Apps" setting, so the person turns this on after setting that to Allow. Until then nothing is read
///   on its own, so no prompt appears.
/// - Polling the change count, the type list and `hasStrings` read no content; Apple lists `types` and
///   `hasStrings` among the calls that "avoid user notifications and alerts".
/// - Password-manager items (nspasteboard.org markers, `ClipboardSync.mayShare`) are never sent.
/// - Nothing is kept by the app, and nothing is logged.
final class DuoPasteboard: ViewerPasteboard {
    static let autoSendKey = "sendPhoneCopiesAutomatically"

    /// The owner's switch in About: send the phone's copies to the Mac on their own.
    static var autoSend: Bool {
        get { UserDefaults.standard.bool(forKey: autoSendKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoSendKey) }
    }

    let pasteboard: UIPasteboard
    let autoSendAllowed: () -> Bool

    init(pasteboard: UIPasteboard = .general, autoSendAllowed: @escaping () -> Bool = { DuoPasteboard.autoSend }) {
        self.pasteboard = pasteboard
        self.autoSendAllowed = autoSendAllowed
    }

    var changeCount: Int { MainActor.assumeIsolated { pasteboard.changeCount } }

    /// Called by the library only after the change count moved (a copy in another app, or this one coming back
    /// to the front after one). Reads content only when the owner has turned automatic sending on.
    func shareableText() -> String? {
        MainActor.assumeIsolated {
            guard autoSendAllowed(), pasteboard.hasStrings,
                  ClipboardSync.mayShare(types: pasteboard.types) else { return nil }
            return pasteboard.string
        }
    }

    func setText(_ text: String) {
        MainActor.assumeIsolated { pasteboard.string = text }
    }
}
