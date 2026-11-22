import Foundation
import XCTest
import WebRTC
@testable import JetKVMClient

/// Review fixes (review finding 4): the connect deadline fires at its deadline and releases the session, even when
/// the first video frame never comes; a teardown is not a successful first frame.
final class ConnectDeadlineTests: XCTestCase {
    /// The focused check: the first-frame wait is held forever; a 0.2 s deadline must end `connect` with a timeout
    /// at about 0.2 s (before the fix it waited for the frame) and leave the session failed and torn down.
    func testTimeoutFiresAtTheDeadlineWhileTheFirstFrameNeverComes() async {
        let s = JetKVMSession(host: "jetkvm.invalid", password: nil)
        s.connectStepsForTest = { [unowned s] in try await s.waitFirstFrame() }
        let start = Date()
        do {
            try await s.connect(timeout: 0.2)
            XCTFail("connected without a frame")
        } catch let e as JetKVMError {
            guard case .timeout = e else { return XCTFail("not a timeout: \(e)") }
        } catch { XCTFail("\(error)") }
        let took = Date().timeIntervalSince(start)
        XCTAssertLessThan(took, 0.6, "connect returned \(took) s after a 0.2 s deadline")
        guard case .failed(.timeout) = s.state else { return XCTFail("state \(s.state)") }
        XCTAssertNil(s.videoTrack)
    }

    /// Leaving while it waits for the first frame: `connect` throws instead of reporting a live session.
    func testDisconnectDuringTheFirstFrameWaitIsNotAFrame() async {
        let s = JetKVMSession(host: "jetkvm.invalid", password: nil)
        s.connectStepsForTest = { [unowned s] in try await s.waitFirstFrame() }
        Task { try? await Task.sleep(nanoseconds: 100_000_000); s.disconnect() }
        do {
            try await s.connect(timeout: 5)
            XCTFail("a teardown was taken as the first frame")
        } catch {}
        if case .live = s.state { XCTFail("live after a teardown") }
    }

    /// Re-review (review finding 4), the reviewer's focused check as a test: the session is in the real first-frame wait at
    /// `.connecting(step: "video")`; ICE fails through the session's own delegate callback. `connect` must end at
    /// once with the ICE error (not "closed", not the deadline), the state failed, everything released, and no
    /// `disconnect` from the caller. Before the fix it stayed suspended past the deadline.
    func testICEFailureBeforeTheFirstFrameEndsConnectAtOnceWithItsError() async {
        let s = JetKVMSession(host: "jetkvm.invalid", password: nil)
        let pc = Self.peerConnection()
        s.connectStepsForTest = { [unowned s] in
            s.setState(.connecting(step: "video"))
            Task { try? await Task.sleep(nanoseconds: 100_000_000); s.peerConnection(pc, didChange: .failed) }
            try await s.waitFirstFrame()
        }
        let start = Date()
        do {
            try await s.connect(timeout: 5)
            XCTFail("connected without a frame")
        } catch let e as JetKVMError {
            XCTAssertEqual(e, .webRTC("ICE failed"))
        } catch { XCTFail("\(error)") }
        let took = Date().timeIntervalSince(start)
        XCTAssertLessThan(took, 1, "connect returned \(took) s after the ICE failure (deadline 5 s)")
        XCTAssertEqual(s.state, .failed(.webRTC("ICE failed")))
        XCTAssertTrue(s.isReleasedForTest, "the session still holds the attempt")
        pc.close()
    }

    /// A failure while no wait is pending (between steps): the next wait throws it at once, `connect` ends with
    /// the original error and releases the session.
    func testFailureBetweenStepsEndsTheNextWaitWithTheOriginalError() async {
        let s = JetKVMSession(host: "jetkvm.invalid", password: nil)
        let pc = Self.peerConnection()
        s.connectStepsForTest = { [unowned s] in
            s.setState(.connecting(step: "video"))
            s.peerConnection(pc, didChange: .failed)
            try? await Task.sleep(nanoseconds: 100_000_000)
            try await s.waitHandshake()
            try await s.waitFirstFrame()
        }
        let start = Date()
        do {
            try await s.connect(timeout: 5)
            XCTFail("connected after a failure")
        } catch let e as JetKVMError {
            XCTAssertEqual(e, .webRTC("ICE failed"))
        } catch { XCTFail("\(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        XCTAssertEqual(s.state, .failed(.webRTC("ICE failed")))
        XCTAssertTrue(s.isReleasedForTest)
        pc.close()
    }

    private static func peerConnection() -> RTCPeerConnection {
        let cfg = RTCConfiguration(); cfg.sdpSemantics = .unifiedPlan
        return JetKVMSession.factory.peerConnection(
            with: cfg, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil),
            delegate: nil)!
    }
}
