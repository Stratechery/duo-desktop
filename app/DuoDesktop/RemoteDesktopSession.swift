// A Windows PC's own Remote Desktop, view only (project notes, milestone 1). FreeRDP 3 runs on its
// own thread: it asks Windows for the session in `RDPScreen` (default 1920 x 1080, text at 200%), checks the PC's
// certificate with `RDPTrust` (trust on first use), and hands each finished picture to the screen. No pointer and no
// keys reach the PC in this milestone (milestone 2). Linked only with the DUO_RDP switch.
#if DUO_RDP
import AVFoundation
import CoreMedia
import CoreVideo
import FreeRDP
import Foundation

final class RemoteDesktopSession: @unchecked Sendable {
    enum State: Equatable {
        case connecting
        case live
        /// Ended, with the reason in plain words (nil: left on purpose).
        case ended(String?)
    }

    struct Target {
        var host: String
        var port: UInt16
        var user: String
        var password: String
        var screen: RDPScreen
        /// The certificate saved for this PC, if any (`MacEntry.rdpCertificate`).
        var savedCertificate: String?
    }

    /// Called on the main queue.
    var onState: (State) -> Void = { _ in }
    var onFrame: (CVPixelBuffer) -> Void = { _ in }
    /// Called on the session's own thread, which waits for the answer: true lets the certificate through. The screen
    /// asks the person on the first use; a changed certificate never reaches it (refused here).
    var askTrust: (_ fingerprint: String) -> Bool = { _ in false }
    /// A first-use certificate the person trusted: the screen saves it to the PC's entry.
    var trusted: (_ fingerprint: String) -> Void = { _ in }

    private let target: Target
    private var instance: UnsafeMutablePointer<freerdp>?
    private let lock = NSLock()
    private var stopping = false
    private var refusedChange = false
    private var pool: CVPixelBufferPool?
    private var poolSize = (w: 0, h: 0)
    /// A frame is on its way to the screen: newer paints wait for the next one (the screen never queues up).
    private var framePending = false

    // FreeRDP's callbacks are plain C functions: they find their session by the instance.
    private static let registryLock = NSLock()
    nonisolated(unsafe) private static var registry: [UnsafeMutableRawPointer: RemoteDesktopSession] = [:]
    private static func session(_ i: UnsafeMutablePointer<freerdp>?) -> RemoteDesktopSession? {
        guard let i else { return nil }
        return registryLock.withLock { registry[UnsafeMutableRawPointer(i)] }
    }

    init(_ target: Target) { self.target = target }

    func start() {
        let t = Thread { [self] in run() }
        t.name = "remote-desktop"
        t.qualityOfService = .userInitiated
        t.start()
    }

    /// Leaves the session (Back, or the app locked). Windows keeps it, disconnected, with its apps running.
    func stop() {
        lock.withLock {
            stopping = true
            if let ctx = instance?.pointee.context { _ = freerdp_abort_connect_context(ctx) }
        }
    }

    private func report(_ s: State) { DispatchQueue.main.async { self.onState(s) } }

    /// The settings for `screen`, as FreeRDP's own client sets them; split out so a test can check them without a PC.
    static func apply(_ t: Target, to settings: UnsafeMutablePointer<rdpSettings>?) -> Bool {
        var ok = true
        ok = ok && freerdp_settings_set_string(settings, FreeRDP_ServerHostname, t.host)
        ok = ok && freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, UInt32(t.port))
        ok = ok && freerdp_settings_set_string(settings, FreeRDP_Username, t.user)
        ok = ok && freerdp_settings_set_string(settings, FreeRDP_Password, t.password)
        ok = ok && freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, t.screen.width)
        ok = ok && freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, t.screen.height)
        ok = ok && freerdp_settings_set_uint32(settings, FreeRDP_DesktopScaleFactor, t.screen.desktopScale)
        ok = ok && freerdp_settings_set_uint32(settings, FreeRDP_DeviceScaleFactor, t.screen.deviceScale)
        ok = ok && freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32)
        // One monitor, always (plan §2): the session's, not the PC's.
        ok = ok && freerdp_settings_set_bool(settings, FreeRDP_UseMultimon, false)
        // NLA (Windows requires it by default), with TLS as Windows' own fallback; never plain RDP security.
        ok = ok && freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, true)
        ok = ok && freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, true)
        ok = ok && freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, false)
        // Our own trust-on-first-use check decides (RDPTrust); it answers "this connection only", so FreeRDP stores none.
        ok = ok && freerdp_settings_set_bool(settings, FreeRDP_CertificateCallbackPreferPEM, true)
        // Milestone 1 draws the classic bitmap and RemoteFX updates with FreeRDP's own GDI; the graphics pipeline
        // (H.264 through VideoToolbox) needs the dynamic channels and comes with the input milestone.
        ok = ok && freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, false)
        ok = ok && freerdp_settings_set_bool(settings, FreeRDP_RemoteFxCodec, true)
        ok = ok && freerdp_settings_set_bool(settings, FreeRDP_FastPathOutput, true)
        ok = ok && freerdp_settings_set_uint32(settings, FreeRDP_KeyboardLayout, 0x409)
        // No sound, printers, drives or clipboard in this milestone.
        ok = ok && freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, false)
        ok = ok && freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, false)
        return ok
    }

    private func run() {
        guard let inst = freerdp_new() else { report(.ended("Remote Desktop could not start.")); return }
        let key = UnsafeMutableRawPointer(inst)
        Self.registryLock.withLock { Self.registry[key] = self }
        defer {
            Self.registryLock.withLock { Self.registry[key] = nil }
            lock.withLock { instance = nil }
            freerdp_context_free(inst)
            freerdp_free(inst)
        }
        inst.pointee.PostConnect = { i in
            guard let i, let ctx = i.pointee.context else { return false }
            // BGRA, so the picture goes to the screen as it is.
            guard gdi_init(i, RemoteDesktopSession.bgra32) else { return false }
            ctx.pointee.update.pointee.EndPaint = { c in
                guard let c else { return false }
                RemoteDesktopSession.session(c.pointee.instance)?.painted(c)
                return true
            }
            ctx.pointee.update.pointee.DesktopResize = { c in
                guard let c, let gdi = c.pointee.gdi, let s = c.pointee.settings else { return false }
                return ObjCBool(gdi_resize(gdi, freerdp_settings_get_uint32(s, FreeRDP_DesktopWidth),
                                  freerdp_settings_get_uint32(s, FreeRDP_DesktopHeight)))
            }
            return true
        }
        inst.pointee.PostDisconnect = { i in
            if let i { gdi_free(i) }
        }
        inst.pointee.VerifyCertificateEx = { i, _, _, _, _, _, fp, flags in
            guard let s = RemoteDesktopSession.session(i), let fp else { return 0 }
            return s.verify(String(cString: fp), isPEM: flags & DWORD(VERIFY_CERT_FLAG_FP_IS_PEM) != 0)
        }
        inst.pointee.VerifyChangedCertificateEx = { i, _, _, _, _, _, fp, _, _, _, flags in
            guard let s = RemoteDesktopSession.session(i), let fp else { return 0 }
            return s.verify(String(cString: fp), isPEM: flags & DWORD(VERIFY_CERT_FLAG_FP_IS_PEM) != 0)
        }
        inst.pointee.ContextSize = MemoryLayout<rdpContext>.size
        guard freerdp_context_new(inst), let ctx = inst.pointee.context else {
            report(.ended("Remote Desktop could not start."))
            return
        }
        guard Self.apply(target, to: ctx.pointee.settings) else { report(.ended("Remote Desktop could not start.")); return }
        let go = lock.withLock { () -> Bool in
            instance = inst
            return !stopping
        }
        guard go else { report(.ended(nil)); return }
        report(.connecting)
        guard freerdp_connect(inst) else {
            let why = lock.withLock { stopping } ? nil : failureWords(freerdp_get_last_error(ctx))
            report(.ended(why))
            return
        }
        report(.live)
        var handles = [HANDLE?](repeating: nil, count: 64)
        while !lock.withLock({ stopping }), !freerdp_shall_disconnect_context(ctx) {
            let n = freerdp_get_event_handles(ctx, &handles, 64)
            if n == 0 { break }
            _ = WaitForMultipleObjects(n, &handles, false, 100)
            if !freerdp_check_event_handles(ctx) { break }
        }
        let leftOnPurpose = lock.withLock { stopping }
        _ = freerdp_disconnect(inst)
        report(.ended(leftOnPurpose ? nil : "Lost the connection."))
    }

    /// PIXEL_FORMAT_BGRA32 (FreeRDP's codec/color.h macro, which Swift cannot import).
    static let bgra32: UInt32 = (32 << 24) | (4 << 16) | (8 << 12) | (8 << 8) | (8 << 4) | 8

    /// The certificate check (plan §4). 2 = accept for this connection only (FreeRDP stores nothing); 0 = refuse.
    private func verify(_ raw: String, isPEM: Bool) -> DWORD {
        let fp = RDPTrust.fingerprint(fromFreeRDP: raw, isPEM: isPEM)
        switch RDPTrust.decide(saved: target.savedCertificate, presented: fp) {
        case .known:
            return 2
        case .changed:
            lock.withLock { refusedChange = true }
            return 0
        case let .askFirstTime(fingerprint):
            guard askTrust(fingerprint) else { return 0 }
            DispatchQueue.main.async { self.trusted(fingerprint) }
            return 2
        }
    }

    /// Plain words for why the connect failed (the full list is milestone 3).
    private func failureWords(_ code: UInt32) -> String {
        if lock.withLock({ refusedChange }) {
            return "This PC's certificate is not the one you trusted before, so the app did not connect."
        }
        // FreeRDP's error.h: MAKE_FREERDP_ERROR(CONNECT, ERRCONNECT_*) = (2 << 16) | type (macros Swift cannot import).
        let connect = { (type: UInt32) in (UInt32(2) << 16) | type }
        switch code {
        case connect(0x09), connect(0x14), connect(0x15): // authentication failed, logon failure, wrong password
            return "Windows did not accept the user name or password."
        case connect(0x16), connect(0x0A): // access denied, insufficient privileges
            return "This account is not allowed to use Remote Desktop on this PC."
        case connect(0x08), connect(0x0B): // TLS connect failed, cancelled (a refused certificate)
            return "The PC's certificate was not trusted, so the app did not connect."
        default:
            return "Could not connect to the PC (\(String(cString: freerdp_get_last_error_string(code))))."
        }
    }

    /// One finished paint: copy the desktop into a pixel buffer for the screen (only when the last one was shown).
    private func painted(_ ctx: UnsafeMutablePointer<rdpContext>) {
        guard let gdi = ctx.pointee.gdi, let src = gdi.pointee.primary_buffer else { return }
        let ready = lock.withLock { () -> Bool in
            if framePending { return false }
            framePending = true
            return true
        }
        guard ready else { return }
        let w = Int(gdi.pointee.width), h = Int(gdi.pointee.height), srcStride = Int(gdi.pointee.stride)
        if pool == nil || poolSize != (w, h) {
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                                          kCVPixelBufferWidthKey: w, kCVPixelBufferHeightKey: h,
                                          kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &p)
            pool = p
            poolSize = (w, h)
        }
        var pb: CVPixelBuffer?
        guard let pool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else {
            lock.withLock { framePending = false }
            return
        }
        CVPixelBufferLockBaseAddress(pb, [])
        if let dst = CVPixelBufferGetBaseAddress(pb) {
            let dstStride = CVPixelBufferGetBytesPerRow(pb)
            for y in 0..<h {
                memcpy(dst + y * dstStride, src + y * srcStride, min(srcStride, dstStride, w * 4))
            }
        }
        CVPixelBufferUnlockBaseAddress(pb, [])
        DispatchQueue.main.async {
            self.onFrame(pb)
            self.lock.withLock { self.framePending = false }
        }
    }
}
#endif
