import Foundation

/// Local login and the signaling WebSocket's JSON messages.
public enum JetKVMSignaling {
    public static let loginPath = "/auth/login-local"
    public static let signalingPath = "/webrtc/signaling/client"
    public static let authCookieName = "authToken"

    /// Body of `POST /auth/login-local`.
    public static func loginBody(password: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["password": password])
    }

    /// The `authToken=...` pair from a login response's Set-Cookie header, or nil.
    public static func authCookie(fromSetCookie header: String?) -> String? {
        guard let header else { return nil }
        for part in header.split(separator: ",").flatMap({ $0.split(separator: ";") }) {
            let t = part.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(authCookieName + "=") { return t }
        }
        return nil
    }

    /// An ICE candidate in the browser's JSON shape.
    public struct Candidate: Equatable, Sendable {
        public var candidate: String
        public var sdpMid: String?
        public var sdpMLineIndex: Int32
        public init(candidate: String, sdpMid: String?, sdpMLineIndex: Int32) {
            self.candidate = candidate; self.sdpMid = sdpMid; self.sdpMLineIndex = sdpMLineIndex
        }
    }

    /// `{"type":"offer","data":{"sd": base64(JSON {"type":"offer","sdp":...})}}`
    public static func offerMessage(sdp: String) throws -> String {
        let desc = try JSONSerialization.data(withJSONObject: ["type": "offer", "sdp": sdp])
        let msg: [String: Any] = ["type": "offer", "data": ["sd": desc.base64EncodedString()]]
        return String(decoding: try JSONSerialization.data(withJSONObject: msg), as: UTF8.self)
    }

    public static func candidateMessage(_ c: Candidate) throws -> String {
        var data: [String: Any] = ["candidate": c.candidate, "sdpMLineIndex": c.sdpMLineIndex]
        if let mid = c.sdpMid { data["sdpMid"] = mid }
        let msg: [String: Any] = ["type": "new-ice-candidate", "data": data]
        return String(decoding: try JSONSerialization.data(withJSONObject: msg), as: UTF8.self)
    }

    public enum Incoming: Equatable, Sendable {
        case deviceMetadata(version: String?)
        case answer(sdp: String)
        case candidate(Candidate)
        case error(String)
        case ping
        case other(String)
    }

    public static func decode(_ text: String) -> Incoming {
        if text == "pong" || text == "ping" { return .ping }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] else {
            return .other(text)
        }
        if let err = obj["error"] { return .error(String(describing: err)) }
        let type = obj["type"] as? String
        switch type {
        case "device-metadata":
            let d = obj["data"] as? [String: Any]
            return .deviceMetadata(version: d?["deviceVersion"] as? String)
        case "answer":
            guard let b64 = obj["data"] as? String, let raw = Data(base64Encoded: b64),
                  let desc = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any],
                  let sdp = desc["sdp"] as? String else { return .error("malformed answer") }
            return .answer(sdp: sdp)
        case "new-ice-candidate":
            guard let d = obj["data"] as? [String: Any], let c = d["candidate"] as? String else { return .other(text) }
            let idx = (d["sdpMLineIndex"] as? NSNumber)?.int32Value ?? 0
            return .candidate(Candidate(candidate: c, sdpMid: d["sdpMid"] as? String, sdpMLineIndex: idx))
        default:
            return .other(text)
        }
    }
}

/// JSON-RPC events the device pushes on the "rpc" data channel.
public enum JetKVMRPCEvent: Equatable, Sendable {
    case otherSessionConnected
    case videoInputState(String)
    case other(method: String)

    public static func decode(_ data: Data) -> JetKVMRPCEvent? {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let method = obj["method"] as? String else { return nil }
        switch method {
        case "otherSessionConnected": return .otherSessionConnected
        case "videoInputState": return .videoInputState(String(describing: obj["params"] ?? ""))
        default: return .other(method: method)
        }
    }
}
