import Foundation
import CoreGraphics
import CoreVideo
import WebRTC
import JetKVMProtocol

/// What the session is doing. The app shows a message for each non-live state.
public enum JetKVMState: Equatable, Sendable {
    case idle
    case connecting(step: String)
    /// Picture and input both up. `deviceVersion` is the JetKVM's app version from the signaling hello.
    case live(deviceVersion: String?)
    /// Another viewer (browser, another phone, the agents' tools) opened this JetKVM; the device closed us.
    case takenOver
    case failed(JetKVMError)
    case disconnected
}

public enum JetKVMError: Error, Equatable, Sendable, CustomStringConvertible {
    case wrongPassword
    case loginFailed(status: Int)
    case unreachable(String)
    case signaling(String)
    case webRTC(String)
    /// The device answered the hidrpc handshake with a version we do not speak (or did not answer at all).
    case unsupportedFirmware(hidrpcVersion: UInt8?)
    case timeout(String)

    public var description: String {
        switch self {
        case .wrongPassword: return "The JetKVM refused the password."
        case .loginFailed(let s): return "JetKVM login failed (HTTP \(s))."
        case .unreachable(let m): return "Cannot reach the JetKVM: \(m)"
        case .signaling(let m): return "JetKVM signaling error: \(m)"
        case .webRTC(let m): return "Video connection error: \(m)"
        case .unsupportedFirmware(let v):
            return "Unsupported JetKVM firmware: keyboard/mouse protocol version \(v.map { String($0) } ?? "none"), this app speaks \(HIDRPC.supportedVersion)."
        case .timeout(let m): return "Timed out \(m)."
        }
    }
}

/// One decoded video frame. `pixelBuffer` is set when the decoder produced a CVPixelBuffer (VideoToolbox H.264).
public struct JetKVMFrame: @unchecked Sendable {
    public let width: Int
    public let height: Int
    public let timestampNs: Int64
    public let pixelBuffer: CVPixelBuffer?
    let rtcFrame: RTCVideoFrame

    /// RGB image of the frame (converted from I420; fine for snapshots, not for every frame).
    public func cgImage() -> CGImage? { I420.cgImage(from: rtcFrame.buffer.toI420()) }
}

/// A JetKVM viewer session: login → signaling → WebRTC (H.264 video in, hidrpc input out).
///
/// Usage: `let s = JetKVMSession(host:password:)`; read `states` and `frames`; `try await s.connect()`;
/// `s.sendPointer(...)`, `s.sendKey(...)`; `s.disconnect()`. For on-screen display the app can add
/// `RTCMTLVideoView` as a renderer of `videoTrack` instead of consuming `frames`.
public final class JetKVMSession: NSObject, @unchecked Sendable {
    public let host: String
    private let password: String?
    private let queue = DispatchQueue(label: "jetkvm.session")

    public let states: AsyncStream<JetKVMState>
    public let frames: AsyncStream<JetKVMFrame>
    private let stateCont: AsyncStream<JetKVMState>.Continuation
    private let frameCont: AsyncStream<JetKVMFrame>.Continuation

    public private(set) var state: JetKVMState = .idle
    /// Optional trace of protocol events (never includes the password). Called on the session's queue.
    public var trace: ((String) -> Void)?
    /// Send plain pointer moves on the lossy channel (default) or the reliable one.
    public var pointerMovesOnLossyChannel = true
    public private(set) var deviceVersion: String?
    public private(set) var hidrpcVersion: UInt8?
    /// The remote video track once it arrives; attach an `RTCVideoRenderer` (e.g. `RTCMTLVideoView`) to show it.
    public private(set) var videoTrack: RTCVideoTrack?

    private var urlSession: URLSession?
    private var ws: URLSessionWebSocketTask?
    private var pc: RTCPeerConnection?
    private var rpc: RTCDataChannel?
    private var hid: RTCDataChannel?
    private var hidFast: RTCDataChannel?
    private var pendingRemote: [RTCIceCandidate] = []
    private var haveAnswer = false
    /// Our own candidates found before the offer went out. The JetKVM (0.5.10, web.go) drops a candidate that
    /// arrives before the offer made its session ("no current session, skipping"), or hands it to an older
    /// session; the new session then has no candidate of ours and ICE can fail ("Failed to ping without
    /// candidate pairs" in the device's log). So candidates are sent only after the offer, in order.
    private var pendingLocal: [String] = []
    private var offerSent = false
    private var hidReady: CheckedContinuation<Void, Error>?
    private var firstFrame: CheckedContinuation<Void, Error>?
    /// Review fixes (review finding 4): set when the deadline (or a cancel) ended the connect; every wait that is
    /// pending or starts later throws it, so `connect` returns at the deadline.
    private var aborted: JetKVMError?
    /// Tests only: replaces the network steps of `connect` (the deadline and the waits are the real ones).
    var connectStepsForTest: (() async throws -> Void)?
    private var sawFrame = false
    private var buttons: HIDRPC.Buttons = []
    private var rpcID = 1000

    static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(),
                                        decoderFactory: RTCDefaultVideoDecoderFactory())
    }()

    /// `host` is a name or address (e.g. `jetkvm.example.ts.net`), plain HTTP on port 80.
    /// `password` nil = the device is in no-password mode.
    public init(host: String, password: String?) {
        self.host = host
        self.password = password
        (states, stateCont) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (frames, frameCont) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        super.init()
        queue.setSpecific(key: Self.queueKey, value: true)
    }

    // MARK: Connect / disconnect

    /// Logs in, signals, waits for the hidrpc handshake and the first video frame. Throws `JetKVMError`.
    ///
    /// Review fixes (review finding 4): at the deadline the connect is ended from outside: the session is torn
    /// down (the JetKVM released) and every pending wait (hidrpc handshake, first frame) is resumed with the
    /// timeout, so this returns at the deadline. A task group could not: cancelling it does not resume a checked
    /// continuation, and the group waits for its children.
    public func connect(timeout: TimeInterval = 20) async throws {
        let steps = connectStepsForTest ?? { try await self.runConnect() }
        let work = Task { try await steps() }
        let deadline = Task { [weak self, host] in
            try await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
            self?.abort(.timeout("connecting to \(host)"))
            work.cancel() // the login request honours cancellation
        }
        defer { deadline.cancel() }
        do {
            try await withTaskCancellationHandler {
                try await work.value
            } onCancel: { [weak self] in
                self?.abort(.unreachable("cancelled")); work.cancel()
            }
        } catch {
            // Re-review fix (review finding 4): the first failure is the error (an ICE failure, not the "closed" of
            // the teardown it caused), and whatever a step made after it is released here, so `connect` returns
            // with the session freed and its caller never has to call `disconnect`.
            let e = queue.sync { () -> JetKVMError in
                let e = aborted ?? (error as? JetKVMError) ?? .unreachable(String(describing: error))
                if aborted == nil { aborted = e }
                if case .connecting = state { state = .failed(e); stateCont.yield(.failed(e)) }
                teardown(e)
                return e
            }
            throw e
        }
    }

    /// Ends a connect in progress: the waits throw `e`, the peer connection and signaling close.
    private func abort(_ e: JetKVMError) {
        queue.async {
            guard self.aborted == nil else { return }
            switch self.state { case .live, .takenOver, .failed, .disconnected: return; default: break }
            self.aborted = e
            self.state = .failed(e); self.stateCont.yield(.failed(e))
            self.teardown(e)
        }
    }

    /// Re-review fix (review finding 4): a failure already reported (ICE, signaling error, take-over) ends the
    /// connect before its next step makes anything new.
    private func checkStillConnecting() throws {
        try queue.sync {
            if let e = aborted { throw e }
            switch state {
            case .failed(let e): throw e
            case .takenOver, .disconnected: throw JetKVMError.signaling("closed")
            default: break
            }
        }
    }

    private func runConnect() async throws {
        setState(.connecting(step: "login"))
        let cookie = try await login()
        try checkStillConnecting()

        setState(.connecting(step: "signaling"))
        guard let url = URL(string: "ws://\(host)\(JetKVMSignaling.signalingPath)") else {
            throw JetKVMError.unreachable("bad host \(host)")
        }
        var req = URLRequest(url: url)
        if let cookie { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
        let us = URLSession(configuration: .ephemeral)
        let task = us.webSocketTask(with: req)
        queue.sync { urlSession = us; ws = task }
        task.resume()
        receiveLoop(task)

        setState(.connecting(step: "video"))
        try checkStillConnecting()
        try await startPeer()
        try checkStillConnecting()
        try await waitHandshake()
        setState(.connecting(step: "picture"))
        try await waitFirstFrame()
        setState(.live(deviceVersion: deviceVersion))
    }

    /// Ends the session and releases the JetKVM for other viewers.
    public func disconnect() {
        queue.sync {
            // Report our own close first, so the peer connection closing is not read as a failure.
            switch state {
            case .takenOver, .failed, .disconnected: break
            default: state = .disconnected; stateCont.yield(.disconnected)
            }
            teardown()
        }
        stateCont.finish(); frameCont.finish()
    }

    private func teardown(_ why: JetKVMError = .signaling("closed")) {
        hidReady?.resume(throwing: why); hidReady = nil
        // Review fixes (review finding 4): a teardown is not a first frame; the wait ends with an error.
        firstFrame?.resume(throwing: why); firstFrame = nil
        videoTrack?.remove(self)
        rpc?.close(); hid?.close(); hidFast?.close()
        pc?.close(); pc = nil
        ws?.cancel(with: .normalClosure, reason: nil); ws = nil
        urlSession?.invalidateAndCancel(); urlSession = nil
    }

    // MARK: Input

    /// One key down/up by USB HID usage (page 7), e.g. 0xE1 = left shift, 0x04 = A.
    public func sendKey(usage: UInt8, down: Bool) { sendHID(HIDRPC.keypress(usage: usage, down: down)) }

    /// Press and release a key.
    public func tapKey(usage: UInt8) { sendKey(usage: usage, down: true); sendKey(usage: usage, down: false) }

    /// Whole keyboard state (modifiers + up to six keys); send an empty report to release everything.
    public func sendKeyboard(modifiers: HIDRPC.Modifiers, keys: [UInt8]) {
        sendHID(HIDRPC.keyboardReport(modifiers: modifiers, keys: keys))
    }

    /// Absolute pointer at a normalised position (0...1, top-left origin) of the Mac's screen, with buttons held.
    public func sendPointer(x: Double, y: Double, buttons: HIDRPC.Buttons? = nil) {
        let b = queue.sync { () -> HIDRPC.Buttons in if let buttons { self.buttons = buttons }; return self.buttons }
        let msg = HIDRPC.pointer(normalizedX: x, normalizedY: y, buttons: b)
        // Plain moves may drop (newer one follows); button changes go on the reliable channel.
        if buttons == nil && pointerMovesOnLossyChannel { sendHID(msg, fast: true) } else { sendHID(msg) }
    }

    /// Relative pointer move (each axis clamped to -127...127 per message; larger moves are split).
    /// Use this when the Mac maps the JetKVM's absolute pointer to a different display than the one captured.
    public func sendPointerDelta(dx: Int, dy: Int, buttons: HIDRPC.Buttons? = nil) {
        let b = queue.sync { () -> HIDRPC.Buttons in if let buttons { self.buttons = buttons }; return self.buttons }
        var rx = dx, ry = dy
        repeat {
            let sx = max(-127, min(127, rx)), sy = max(-127, min(127, ry))
            sendHID(HIDRPC.mouse(dx: sx, dy: sy, buttons: b))
            rx -= sx; ry -= sy
        } while rx != 0 || ry != 0
    }

    /// Click at a point: press then release.
    public func click(x: Double, y: Double, button: HIDRPC.Buttons = .primary) {
        sendPointer(x: x, y: y, buttons: button)
        sendPointer(x: x, y: y, buttons: [])
    }

    /// Scroll wheel steps (-127...127); positive dy scrolls up.
    /// Firmware up to 0.5.10 takes wheel steps only as a JSON-RPC call (`HIDRPC.wheelOverJSONRPC`).
    public func sendScroll(dy: Int, dx: Int = 0) {
        guard HIDRPC.wheelOverJSONRPC(deviceVersion: deviceVersion) else { sendHID(HIDRPC.wheel(dy: dy, dx: dx)); return }
        queue.async {
            guard let ch = self.rpc, ch.readyState == .open else { self.trace?("rpc send dropped (channel not ready)"); return }
            self.rpcID += 1
            let text = HIDRPC.wheelJSONRPC(dy: dy, dx: dx, id: self.rpcID)
            let ok = ch.sendData(RTCDataBuffer(data: Data(text.utf8), isBinary: false))
            self.trace?("rpc → \(text) ok=\(ok)")
        }
    }

    private func sendHID(_ data: Data, fast: Bool = false) {
        queue.async {
            let ch = (fast && self.hidFast?.readyState == .open) ? self.hidFast : self.hid
            guard let ch, ch.readyState == .open, self.hidrpcVersion == HIDRPC.supportedVersion else {
                self.trace?("hid send dropped (channel not ready)"); return
            }
            let ok = ch.sendData(RTCDataBuffer(data: data, isBinary: true))
            self.trace?("hid → \(ch.label) \(data.map { String(format: "%02x", $0) }.joined()) ok=\(ok)")
        }
    }

    // MARK: Login

    private func login() async throws -> String? {
        guard let password else { return nil }
        guard let url = URL(string: "http://\(host)\(JetKVMSignaling.loginPath)") else {
            throw JetKVMError.unreachable("bad host \(host)")
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JetKVMSignaling.loginBody(password: password)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpShouldSetCookies = false
        let (_, resp): (Data, URLResponse)
        do { (_, resp) = try await URLSession(configuration: cfg).data(for: req) }
        catch { throw JetKVMError.unreachable(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw JetKVMError.loginFailed(status: 0) }
        if http.statusCode == 401 || http.statusCode == 403 { throw JetKVMError.wrongPassword }
        guard (200..<300).contains(http.statusCode) else { throw JetKVMError.loginFailed(status: http.statusCode) }
        guard let c = JetKVMSignaling.authCookie(fromSetCookie: http.value(forHTTPHeaderField: "Set-Cookie")) else {
            throw JetKVMError.loginFailed(status: http.statusCode)
        }
        return c
    }

    // MARK: Signaling

    private func receiveLoop(_ task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let e):
                self.queue.async {
                    guard self.ws === task else { return }
                    // Once live, the WebSocket closing is normal for the device; only fail during setup.
                    if case .connecting = self.state { self.fail(.signaling(e.localizedDescription)) }
                }
            case .success(let msg):
                let text: String
                switch msg {
                case .string(let s): text = s
                case .data(let d): text = String(decoding: d, as: UTF8.self)
                @unknown default: text = ""
                }
                self.queue.async { self.handleSignal(JetKVMSignaling.decode(text)) }
                self.receiveLoop(task)
            }
        }
    }

    private func handleSignal(_ m: JetKVMSignaling.Incoming) {
        switch m {
        case .deviceMetadata(let v): deviceVersion = v
        case .answer(let sdp):
            pc?.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { [weak self] err in
                guard let self else { return }
                self.queue.async {
                    if let err { self.fail(.webRTC("answer: \(err.localizedDescription)")); return }
                    self.trace?("answer received; \(Self.describeCandidates(sdp))")
                    self.haveAnswer = true
                    for c in self.pendingRemote { self.pc?.add(c) { _ in } }
                    self.pendingRemote = []
                }
            }
        case .candidate(let c):
            trace?("device candidate \(Self.describe(candidate: c.candidate))")
            let ice = RTCIceCandidate(sdp: c.candidate, sdpMLineIndex: c.sdpMLineIndex, sdpMid: c.sdpMid)
            if haveAnswer { pc?.add(ice) { _ in } } else { pendingRemote.append(ice) }
        case .error(let e): fail(.signaling(e))
        case .ping, .other: break
        }
    }

    private func sendSignal(_ text: String) {
        queue.async { self.ws?.send(.string(text)) { _ in } }
    }

    // MARK: WebRTC

    private func startPeer() async throws {
        let cfg = RTCConfiguration()
        cfg.sdpSemantics = .unifiedPlan
        cfg.iceServers = []          // Tailscale/LAN: host candidates are enough.
        cfg.continualGatheringPolicy = .gatherContinually
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let pc = Self.factory.peerConnection(with: cfg, constraints: constraints, delegate: self) else {
            throw JetKVMError.webRTC("could not create peer connection")
        }
        let vinit = RTCRtpTransceiverInit(); vinit.direction = .recvOnly
        let transceiver = pc.addTransceiver(of: .video, init: vinit)
        // H.264 only: this WebRTC build has no HEVC decoder, and the device picks from what we offer.
        if let t = transceiver {
            let h264 = Self.factory.rtpReceiverCapabilities(forKind: kRTCMediaStreamTrackKindVideo).codecs
                .filter { $0.name.uppercased() == "H264" }
            if !h264.isEmpty { try? t.setCodecPreferences(h264, error: ()) }
        }

        let reliable = RTCDataChannelConfiguration()
        let fast = RTCDataChannelConfiguration(); fast.maxRetransmits = 0; fast.isOrdered = true
        let rpc = pc.dataChannel(forLabel: "rpc", configuration: RTCDataChannelConfiguration())
        let hid = pc.dataChannel(forLabel: "hidrpc", configuration: reliable)
        let hidFast = pc.dataChannel(forLabel: "hidrpc-unreliable-ordered", configuration: fast)
        rpc?.delegate = self; hid?.delegate = self; hidFast?.delegate = self
        queue.sync { self.pc = pc; self.rpc = rpc; self.hid = hid; self.hidFast = hidFast }

        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { cont in
            pc.offer(for: constraints) { sdp, err in
                if let sdp { cont.resume(returning: sdp) } else {
                    cont.resume(throwing: JetKVMError.webRTC("offer: \(err?.localizedDescription ?? "?")"))
                }
            }
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pc.setLocalDescription(offer) { err in
                if let err { cont.resume(throwing: JetKVMError.webRTC("local: \(err.localizedDescription)")) }
                else { cont.resume() }
            }
        }
        let offerText = try JetKVMSignaling.offerMessage(sdp: offer.sdp)
        queue.async {
            // The offer first, then every candidate found meanwhile, on the one WebSocket in this order.
            self.ws?.send(.string(offerText)) { _ in }
            self.offerSent = true
            self.trace?("offer sent; then \(self.pendingLocal.count) own candidates")
            for m in self.pendingLocal { self.ws?.send(.string(m)) { _ in } }
            self.pendingLocal = []
        }
    }

    // MARK: Log lines (no addresses: each candidate by its kind and network only)

    /// "host udp tailnet", "srflx udp internet", "host udp mdns" … from one `candidate:` line.
    static func describe(candidate line: String) -> String {
        let f = line.split(separator: " ").map(String.init)
        guard f.count >= 8 else { return "unreadable" }
        let proto = f[2].lowercased(), addr = f[4]
        let type = f.firstIndex(of: "typ").flatMap { $0 + 1 < f.count ? f[$0 + 1] : nil } ?? "?"
        return "\(type) \(proto) \(network(of: addr))"
    }

    static func describeCandidates(_ sdp: String) -> String {
        let lines = sdp.split(whereSeparator: \.isNewline).filter { $0.hasPrefix("a=candidate:") }
        if lines.isEmpty { return "no candidates in it" }
        return "candidates in it: " + lines.map { describe(candidate: String($0.dropFirst(2))) }.joined(separator: ", ")
    }

    /// Which network an address belongs to, without the address.
    static func network(of a: String) -> String {
        if a.hasSuffix(".local") { return "mdns" }
        let p = a.split(separator: ".").compactMap { Int($0) }
        if p.count == 4 {
            if p[0] == 100, (64...127).contains(p[1]) { return "tailnet" }
            if p[0] == 10 || (p[0] == 172 && (16...31).contains(p[1])) || (p[0] == 192 && p[1] == 168) { return "lan" }
            if p[0] == 169 && p[1] == 254 { return "link-local" }
            if p[0] == 127 { return "loopback" }
            return "internet"
        }
        let l = a.lowercased()
        if l.hasPrefix("fd7a:115c:a1e0") { return "tailnet-v6" }
        if l.hasPrefix("fe80") { return "link-local-v6" }
        if l.hasPrefix("fd") || l.hasPrefix("fc") { return "lan-v6" }
        return l.contains(":") ? "internet-v6" : "name"
    }

    func waitHandshake() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                if let e = self.aborted { cont.resume(throwing: e); return }
                if let v = self.hidrpcVersion {
                    if v == HIDRPC.supportedVersion { cont.resume() }
                    else { cont.resume(throwing: JetKVMError.unsupportedFirmware(hidrpcVersion: v)) }
                } else { self.hidReady = cont }
            }
        }
    }

    func waitFirstFrame() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async {
                if let e = self.aborted { cont.resume(throwing: e) }
                else if self.sawFrame { cont.resume() }
                else if self.ws == nil && self.pc == nil && self.connectStepsForTest == nil {
                    cont.resume(throwing: JetKVMError.signaling("closed")) // already torn down
                } else { self.firstFrame = cont }
            }
        }
    }

    // MARK: State

    func setState(_ s: JetKVMState) {
        let apply = {
            guard self.state != s else { return }
            // Terminal states stick.
            switch self.state { case .takenOver, .failed, .disconnected: return; default: break }
            self.state = s
            self.stateCont.yield(s)
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { apply() } else { queue.sync(execute: apply) }
    }

    private static let queueKey = DispatchSpecificKey<Bool>()

    private func fail(_ e: JetKVMError) {
        let run = {
            if case .connecting = self.state {} else if case .live = self.state {} else { return }
            self.trace?("failed: \(e)")
            self.state = .failed(e); self.stateCont.yield(.failed(e))
            // Every wait ends with the error, and the attempt is torn down at once (no half-open session holding
            // the JetKVM): an ICE failure during the connect used to leave the first-frame wait to the deadline.
            if self.aborted == nil { self.aborted = e }
            self.teardown(e)
        }
        if DispatchQueue.getSpecific(key: Self.queueKey) != nil { run() } else { queue.async(execute: run) }
    }

    private func takenOver() {
        if case .live = state {} else if case .connecting = state {} else { return }
        state = .takenOver; stateCont.yield(.takenOver)
        teardown()
    }

    /// Tests only: nothing of the attempt is held (no peer connection, data channels, WebSocket or URL session).
    var isReleasedForTest: Bool {
        queue.sync { pc == nil && ws == nil && urlSession == nil && hidReady == nil && firstFrame == nil }
    }

    public override var description: String { "JetKVMSession(\(host), \(state))" }
}

// MARK: - WebRTC delegates

extension JetKVMSession: RTCPeerConnectionDelegate {
    public func peerConnection(_ pc: RTCPeerConnection, didChange s: RTCSignalingState) {}
    public func peerConnection(_ pc: RTCPeerConnection, didAdd stream: RTCMediaStream) {}
    public func peerConnection(_ pc: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    public func peerConnectionShouldNegotiate(_ pc: RTCPeerConnection) {}
    public func peerConnection(_ pc: RTCPeerConnection, didChange s: RTCIceGatheringState) {
        let name = ["new", "gathering", "complete"][min(Int(s.rawValue), 2)]
        queue.async { self.trace?("gathering \(name)") }
    }
    public func peerConnection(_ pc: RTCPeerConnection, didRemove c: [RTCIceCandidate]) {}
    public func peerConnection(_ pc: RTCPeerConnection, didOpen dc: RTCDataChannel) {}

    public func peerConnection(_ pc: RTCPeerConnection, didChange s: RTCIceConnectionState) {
        queue.async {
            let names = ["new", "checking", "connected", "completed", "failed", "disconnected", "closed", "count"]
            self.trace?("ICE \(names[min(Int(s.rawValue), names.count - 1)])")
            switch s {
            case .failed: self.fail(.webRTC("ICE failed"))
            case .closed, .disconnected:
                if case .live = self.state { self.fail(.webRTC("connection lost")) }
            default: break
            }
        }
    }

    public func peerConnection(_ pc: RTCPeerConnection, didGenerate c: RTCIceCandidate) {
        let cand = JetKVMSignaling.Candidate(candidate: c.sdp, sdpMid: c.sdpMid, sdpMLineIndex: c.sdpMLineIndex)
        guard let msg = try? JetKVMSignaling.candidateMessage(cand) else { return }
        queue.async {
            self.trace?("own candidate \(Self.describe(candidate: c.sdp))\(self.offerSent ? "" : " (held until the offer)")")
            if self.offerSent { self.ws?.send(.string(msg)) { _ in } } else { self.pendingLocal.append(msg) }
        }
    }

    public func peerConnection(_ pc: RTCPeerConnection, didStartReceivingOn t: RTCRtpTransceiver) {
        guard let track = t.receiver.track as? RTCVideoTrack else { return }
        queue.async { self.videoTrack = track; track.add(self) }
    }
}

extension JetKVMSession: RTCDataChannelDelegate {
    public func dataChannelDidChangeState(_ dc: RTCDataChannel) {
        guard dc.label == "hidrpc", dc.readyState == .open else { return }
        dc.sendData(RTCDataBuffer(data: HIDRPC.handshake(), isBinary: true))
    }

    public func dataChannel(_ dc: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let data = buffer.data
        queue.async {
            switch dc.label {
            case "rpc":
                let ev = JetKVMRPCEvent.decode(data)
                self.trace?("rpc ← \(ev.map { String(describing: $0) } ?? "?")")
                if ev == .otherSessionConnected { self.takenOver() }
            case "hidrpc":
                self.trace?("hid ← \(HIDRPC.decode(data).map { String(describing: $0) } ?? "?")")
                if case .handshake(let v) = HIDRPC.decode(data) {
                    self.hidrpcVersion = v
                    if let c = self.hidReady {
                        self.hidReady = nil
                        if v == HIDRPC.supportedVersion { c.resume() }
                        else { c.resume(throwing: JetKVMError.unsupportedFirmware(hidrpcVersion: v)) }
                    }
                }
            default: break
            }
        }
    }
}

extension JetKVMSession: RTCVideoRenderer {
    public func setSize(_ size: CGSize) {}
    public func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        let pb = (frame.buffer as? RTCCVPixelBuffer)?.pixelBuffer
        frameCont.yield(JetKVMFrame(width: Int(frame.width), height: Int(frame.height),
                                    timestampNs: frame.timeStampNs, pixelBuffer: pb, rtcFrame: frame))
        queue.async {
            guard !self.sawFrame else { return }
            self.sawFrame = true
            self.firstFrame?.resume(); self.firstFrame = nil
        }
    }
}
