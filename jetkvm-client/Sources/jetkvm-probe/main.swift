import Foundation
import ImageIO
import UniformTypeIdentifiers
import JetKVMClient

// jetkvm-probe <host> <password-file> <out.png>
// Connects, saves one decoded frame, moves the pointer a little and back, taps shift, reports state, disconnects.
// Never prints the password.
let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data("usage: jetkvm-probe <host> <password-file> <out.png>\n".utf8)); exit(2)
}
let host = args[1], pwFile = args[2], out = args[3]
guard let pw = try? String(contentsOfFile: pwFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) else {
    print("cannot read password file"); exit(2)
}
func log(_ s: String) { print("[\(String(format: "%.1f", Date().timeIntervalSince(t0)))s] \(s)"); fflush(stdout) }
let t0 = Date()

let session = JetKVMSession(host: host, password: pw)
if ProcessInfo.processInfo.environment["JETKVM_TRACE"] != nil { session.trace = { log("trace: \($0)") } }
if ProcessInfo.processInfo.environment["JETKVM_RELIABLE_POINTER"] != nil { session.pointerMovesOnLossyChannel = false }
Task { for await s in session.states { log("state: \(s)") } }

let deadline = DispatchTime.now() + 55
DispatchQueue.global().asyncAfter(deadline: deadline) { log("hard deadline: disconnecting"); session.disconnect(); exit(1) }

Task {
    do {
        try await session.connect(timeout: 25)
        log("live; device \(session.deviceVersion ?? "?"), hidrpc v\(session.hidrpcVersion.map { String($0) } ?? "?")")
        var it = session.frames.makeAsyncIterator()
        // Skip a few frames so the decoder has a clean picture.
        var frame = await it.next()
        for _ in 0..<10 { if let f = await it.next() { frame = f } }
        guard let f = frame, let img = f.cgImage() else { log("no frame"); session.disconnect(); exit(1) }
        log("frame \(f.width)x\(f.height) pixelBuffer=\(f.pixelBuffer != nil)")
        let url = URL(fileURLWithPath: out) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
        CGImageDestinationAddImage(dest, img, nil)
        log(CGImageDestinationFinalize(dest) ? "saved \(out)" : "save failed")

        // Pointer: a small move and back, near the centre (no clicks).
        session.sendPointer(x: 0.50, y: 0.50); try await Task.sleep(nanoseconds: 300_000_000)
        session.sendPointer(x: 0.53, y: 0.52); try await Task.sleep(nanoseconds: 1_000_000_000)
        // Second picture with the pointer at the moved spot, to show the move landed on the Mac.
        var moved: JetKVMFrame? = nil
        for _ in 0..<5 { if let f = await it.next() { moved = f } }
        if let m = moved, let mi = m.cgImage() {
            let p = out.replacingOccurrences(of: ".png", with: "-pointer-moved.png")
            if let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: p) as CFURL, UTType.png.identifier as CFString, 1, nil) {
                CGImageDestinationAddImage(d, mi, nil); if CGImageDestinationFinalize(d) { log("saved \(p)") }
            }
        }
        session.sendPointer(x: 0.50, y: 0.50); try await Task.sleep(nanoseconds: 300_000_000)
        log("pointer moved and back")
        if ProcessInfo.processInfo.environment["JETKVM_RELATIVE"] != nil {
            session.sendPointerDelta(dx: 40, dy: 20); try await Task.sleep(nanoseconds: 800_000_000)
            session.sendPointerDelta(dx: -40, dy: -20); try await Task.sleep(nanoseconds: 300_000_000)
            log("relative move +40,+20 and back")
        }
        session.tapKey(usage: 0xE1)   // left shift, harmless
        try await Task.sleep(nanoseconds: 300_000_000)
        log("shift tapped; state \(session.state)")
        // JETKVM_HOLD=<seconds>: stay connected that long (used to test take-over from a second session).
        if let h = ProcessInfo.processInfo.environment["JETKVM_HOLD"].flatMap(Double.init) {
            let end = Date().addingTimeInterval(min(h, 30))
            while Date() < end, case .live = session.state { try await Task.sleep(nanoseconds: 200_000_000) }
            log("after hold: state \(session.state)")
            if session.state == .takenOver { exit(0) }
        }
        session.disconnect()
        try await Task.sleep(nanoseconds: 300_000_000)
        log("disconnected")
        exit(0)
    } catch {
        log("failed: \(error)")
        session.disconnect()
        exit(1)
    }
}
dispatchMain()
