import GlassActWire
import UIKit
import XCTest
@testable import DuoDesktop

/// Project notes: the two new messages, and an older Host that does not know them.
@MainActor
final class OverviewSnapshotTests: XCTestCase {
    private func jpeg(_ w: Int, _ h: Int) -> [UInt8] {
        let image = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: {
            let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }()).image { ctx in
            UIColor.orange.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        return [UInt8](image.jpegData(compressionQuality: 0.5)!)
    }

    private func roundTrip(_ m: ControlMessage) throws -> ControlMessage {
        var d = ControlDeframer()
        d.append(try XCTUnwrap(m.encodedForSend()))
        guard case let .message(back)? = d.next() else { XCTFail("no message"); throw XCTSkip() }
        XCTAssertNil(d.next())
        return back
    }

    /// Claim: DISPLAY_SNAPSHOT_REQUEST (0x65) and DISPLAY_SNAPSHOT (0x66) encode and decode exactly, and the still
    /// decodes to its size on the phone.
    func testMessagesRoundTrip() throws {
        XCTAssertEqual(try roundTrip(.displaySnapshotRequest(maxSide: 480)), .displaySnapshotRequest(maxSide: 480))
        let bytes = jpeg(480, 270)
        let snap = WireDisplaySnapshot(displayID: 2, format: WireDisplaySnapshot.jpeg, width: 480, height: 270, bytes: bytes)
        XCTAssertEqual(ControlMessage.displaySnapshot(snap).tlvType, 0x66)
        XCTAssertEqual(try roundTrip(.displaySnapshot(snap)), .displaySnapshot(snap))
        let image = try XCTUnwrap(MacScreen.decodeStill(bytes))
        XCTAssertEqual(image.size, CGSize(width: 480, height: 270))
        XCTAssertNil(MacScreen.decodeStill([1, 2, 3]), "not a picture: ignored, the tile stays as it was")
    }

    /// Claim (old Host: no snapshots, no error): a Host built before these messages knows types up to 0x64 only; it
    /// skips the request by its declared length and reads the next message normally, so the stream is not broken
    /// and simply no snapshot comes back.
    func testOldHostSkipsTheRequest() throws {
        var d = TLVDeframer<OldHostControl>()
        d.append(try XCTUnwrap(ControlMessage.displaySnapshotRequest(maxSide: 480).encodedForSend()))
        d.append(try XCTUnwrap(ControlMessage.displaySelect(displayID: 0, placePointer: false, pointerX: 0, pointerY: 0).encodedForSend()))
        XCTAssertEqual(d.next(), .skippedUnknown(type: 0x65))
        guard case let .message(m)? = d.next() else { return XCTFail("the next message was not read") }
        XCTAssertEqual(m.message, .displaySelect(displayID: 0, placePointer: false, pointerX: 0, pointerY: 0))
        XCTAssertFalse(d.isMalformed)
    }

    /// Claim: with no snapshot (older Host) the model holds none, so each tile draws as before; a still that arrives
    /// after the overview closed is dropped.
    func testNoSnapshotsLeavesTilesAsBefore() {
        let model = SessionModel(store: MacStore(url: FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".json"), defaults: .standard,
            knownHosts: .init(url: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))))
        XCTAssertTrue(model.screenSnapshots.isEmpty)
        model.snapshotArrived(WireDisplaySnapshot(displayID: 1, format: 3, width: 48, height: 27, bytes: jpeg(48, 27)))
        XCTAssertTrue(model.screenSnapshots.isEmpty, "overview not showing: dropped")
    }
}

/// The control family as an older Host parses it: the same bodies, known types 0x01...0x1E and 0x60...0x64.
private struct OldHostControl: TLVMessage {
    let message: ControlMessage
    static func parseBody(type: UInt8, _ buf: UnsafeRawBufferPointer) -> OldHostControl? {
        guard isKnownType(type), let m = ControlMessage.parseBody(type: type, buf) else { return nil }
        return OldHostControl(message: m)
    }
    static func isKnownType(_ t: UInt8) -> Bool { (0x01...0x1E).contains(t) || (0x60...0x64).contains(t) }
    static var maxBodyLength: UInt32 { ControlMessage.maxBodyLength }
}
