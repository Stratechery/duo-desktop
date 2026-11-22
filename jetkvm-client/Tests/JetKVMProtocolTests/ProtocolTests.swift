import XCTest
@testable import JetKVMProtocol

final class HIDRPCTests: XCTestCase {
    func testHandshakeAndKeys() {
        XCTAssertEqual([UInt8](HIDRPC.handshake()), [0x01, 0x01])
        XCTAssertEqual([UInt8](HIDRPC.keypress(usage: 0xE1, down: true)), [0x05, 0xE1, 0x01])
        XCTAssertEqual([UInt8](HIDRPC.keypress(usage: 0x04, down: false)), [0x05, 0x04, 0x00])
        XCTAssertEqual([UInt8](HIDRPC.keyboardReport(modifiers: [.leftCommand, .leftShift], keys: [4, 5])), [0x02, 0x0A, 4, 5])
        XCTAssertEqual(HIDRPC.keyboardReport(modifiers: [], keys: Array(1...9)).count, 8) // type + mod + 6 keys
    }

    func testPointerIsBigEndianAndClamped() {
        XCTAssertEqual([UInt8](HIDRPC.pointer(x: 0x1234, y: 32767, buttons: .primary)),
                       [0x03, 0, 0, 0x12, 0x34, 0, 0, 0x7F, 0xFF, 0x01])
        XCTAssertEqual([UInt8](HIDRPC.pointer(x: -5, y: 99999, buttons: [])), [0x03, 0, 0, 0, 0, 0, 0, 0x7F, 0xFF, 0])
        let mid = [UInt8](HIDRPC.pointer(normalizedX: 0.5, normalizedY: 1.0, buttons: []))
        XCTAssertEqual(mid.count, 10)
        XCTAssertEqual(Int(mid[3]) << 8 | Int(mid[4]), 16384)
        XCTAssertEqual([UInt8](HIDRPC.pointer(normalizedX: .nan, normalizedY: -1, buttons: [])).dropFirst().prefix(8).reduce(0, +), 0)
    }

    func testWheelAndMouse() {
        XCTAssertEqual([UInt8](HIDRPC.wheel(dy: -3, dx: 200)), [0x04, 0xFD, 0x7F])
        XCTAssertEqual([UInt8](HIDRPC.mouse(dx: -1, dy: 2, buttons: .secondary)), [0x06, 0xFF, 0x02, 0x02])
    }

    func testDecode() {
        XCTAssertEqual(HIDRPC.decode(Data([0x01, 0x01])), .handshake(version: 1))
        XCTAssertEqual(HIDRPC.decode(Data([0x01, 0x02])), .handshake(version: 2))
        XCTAssertEqual(HIDRPC.decode(Data([0x32, 0x02])), .keyboardLEDs(2))
        XCTAssertEqual(HIDRPC.decode(Data([0x33, 0x02, 4])), .keysDown(modifiers: 2, keys: [4]))
        XCTAssertNil(HIDRPC.decode(Data()))
    }
}

final class SignalingTests: XCTestCase {
    func testOfferRoundTrip() throws {
        let text = try JetKVMSignaling.offerMessage(sdp: "v=0\r\n")
        let obj = try JSONSerialization.jsonObject(with: Data(text.utf8)) as! [String: Any]
        XCTAssertEqual(obj["type"] as? String, "offer")
        let sd = (obj["data"] as! [String: Any])["sd"] as! String
        let desc = try JSONSerialization.jsonObject(with: Data(base64Encoded: sd)!) as! [String: String]
        XCTAssertEqual(desc, ["type": "offer", "sdp": "v=0\r\n"])
    }

    func testDecodeAnswerCandidateMetadata() throws {
        let desc = try JSONSerialization.data(withJSONObject: ["type": "answer", "sdp": "v=0"])
        XCTAssertEqual(JetKVMSignaling.decode(#"{"type":"answer","data":"\#(desc.base64EncodedString())"}"#), .answer(sdp: "v=0"))
        XCTAssertEqual(JetKVMSignaling.decode(#"{"type":"device-metadata","data":{"deviceVersion":"0.4.8"}}"#),
                       .deviceMetadata(version: "0.4.8"))
        XCTAssertEqual(JetKVMSignaling.decode(#"{"type":"new-ice-candidate","data":{"candidate":"candidate:1","sdpMid":"0","sdpMLineIndex":0}}"#),
                       .candidate(.init(candidate: "candidate:1", sdpMid: "0", sdpMLineIndex: 0)))
        if case .error = JetKVMSignaling.decode(#"{"error":"boom"}"#) {} else { XCTFail() }
    }

    func testCookieAndRPCEvent() {
        XCTAssertEqual(JetKVMSignaling.authCookie(fromSetCookie: "authToken=abc; Path=/; HttpOnly"), "authToken=abc")
        XCTAssertNil(JetKVMSignaling.authCookie(fromSetCookie: "other=1"))
        XCTAssertEqual(JetKVMRPCEvent.decode(Data(#"{"jsonrpc":"2.0","method":"otherSessionConnected"}"#.utf8)), .otherSessionConnected)
    }

    /// Firmware up to 0.5.10 gets wheel steps as the JSON-RPC call; later (and unknown) firmware the binary message.
    func testWheelPathByFirmware() {
        XCTAssertTrue(HIDRPC.wheelOverJSONRPC(deviceVersion: "0.5.10"))
        XCTAssertTrue(HIDRPC.wheelOverJSONRPC(deviceVersion: "0.4.9"))
        XCTAssertFalse(HIDRPC.wheelOverJSONRPC(deviceVersion: "0.5.11-dev202611191401"))
        XCTAssertFalse(HIDRPC.wheelOverJSONRPC(deviceVersion: "0.6.0"))
        XCTAssertFalse(HIDRPC.wheelOverJSONRPC(deviceVersion: nil))
        XCTAssertEqual(HIDRPC.wheelJSONRPC(dy: -300, dx: 2, id: 7),
                       #"{"jsonrpc":"2.0","id":7,"method":"wheelReport","params":{"wheelY":-127,"wheelX":2}}"#)
    }
}
