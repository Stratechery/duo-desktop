@testable import DuoTerminalKit
import NIOCore
import NIOEmbedded
import NIOSSH
import XCTest

/// project notes, terminal-only computers, M2: the Tailscale (`none`) sign-in.
final class TailscaleSignInTests: XCTestCase {
    /// The Tailscale sign-in offers SSH's `none` method with the user name, once; no key, no password.
    func testTailscaleSignInOffersNoneOnce() throws {
        let loop = EmbeddedEventLoop()
        let d = SignInDelegate(user: "lab", signIn: .tailscale)
        let first = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        d.nextAuthenticationType(availableMethods: .publicKey, nextChallengePromise: first)
        let offer = try XCTUnwrap(try first.futureResult.wait())
        XCTAssertEqual(offer.username, "lab")
        guard case .none = offer.offer else { return XCTFail("not the none offer: \(offer.offer)") }
        // A second call means Tailscale said no: refused, not a second try.
        let second = loop.makePromise(of: NIOSSHUserAuthenticationOffer?.self)
        d.nextAuthenticationType(availableMethods: .all, nextChallengePromise: second)
        XCTAssertThrowsError(try second.futureResult.wait()) { XCTAssertTrue($0 is SSHSignInRefused) }
    }

    /// Tailscale's refusal banner (its exact words, from the live probe of 2026-11-22) ends the sign-in at once
    /// with those words; another banner is passed on and the sign-in goes on.
    func testTailscaleRefusalBannerFailsTheSignInAtOnce() throws {
        let words = "tailscale: tailnet policy does not permit you to SSH as user \"root\"\n"
        XCTAssertTrue(TailscaleBanner.isRefusal(words))
        XCTAssertFalse(TailscaleBanner.isRefusal("Welcome to Lab Server\n"))

        let ch = EmbeddedChannel()
        let ready = ch.eventLoop.makePromise(of: Void.self)
        let seen = Box()
        try ch.pipeline.syncOperations.addHandler(ReadyWatcher(ready: ready, onBanner: { seen.add($0) },
                                                               refuses: TailscaleBanner.isRefusal))
        ch.pipeline.fireUserInboundEventTriggered(NIOUserAuthBannerEvent(message: "Welcome\n", languageTag: ""))
        ch.pipeline.fireUserInboundEventTriggered(NIOUserAuthBannerEvent(message: words, languageTag: ""))
        XCTAssertThrowsError(try ready.futureResult.wait()) { e in
            XCTAssertEqual((e as? SSHSignInRefused)?.reason, "tailscale: tailnet policy does not permit you to SSH as user \"root\"")
            XCTAssertEqual(SSHFailureKind.of(e), .signInRefused)
        }
        XCTAssertEqual(seen.items, ["Welcome\n", words])
    }

    /// A server that never finishes the sign-in is let go after the deadline (Tailscale holds a refused one open).
    func testSignInDeadlineFails() throws {
        let loop = EmbeddedEventLoop()
        let ch = EmbeddedChannel(loop: loop)
        let ready = loop.makePromise(of: Void.self)
        try ch.pipeline.syncOperations.addHandler(ReadyWatcher(ready: ready, deadline: .seconds(30)))
        let settled = Box()
        ready.futureResult.whenComplete { _ in settled.add("done") }
        loop.advanceTime(by: .seconds(29))
        XCTAssertTrue(settled.items.isEmpty, "settled before the deadline")
        loop.advanceTime(by: .seconds(2))
        XCTAssertEqual(settled.items, ["done"])
        XCTAssertThrowsError(try ready.futureResult.wait()) { XCTAssertTrue($0 is SSHSignInTimedOut) }
    }

    /// A terminal-only computer's start: tmux `duo` when there is tmux, else a login shell with a notice naming the
    /// computer (not "this Mac").
    func testComputerShellCommandNamesTheComputer() {
        let c = ShellCommand.tmuxOrShellComputer
        XCTAssertTrue(c.contains("tmux -u new -A -s duo"))
        XCTAssertTrue(c.contains("tmux is not on this computer"))
        XCTAssertFalse(c.contains("Mac"))
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock(); private var _items: [String] = []
        func add(_ s: String) { lock.withLock { _items.append(s) } }
        var items: [String] { lock.withLock { _items } }
    }
}
