#if DUO_TERMINAL
import DuoTerminalKit
import GlassActWire
import XCTest
@testable import DuoDesktop

/// Project notes items 5 and 6, at the app's level (the engine and live proofs are in KeyInstallTests,
/// tools/computers-m2-fixes-shots.sh and the result). Made-up names only.
@MainActor
final class ComputersM2FixesTests: XCTestCase {
    /// Item 5: a `none` sign-in answered by ordinary SSH is said as ordinary SSH (never "Tailscale refused"), and
    /// offers the password sign-in when the server takes passwords, the key to copy when it does not; Tailscale's own
    /// refusal keeps today's words.
    func testOrdinarySSHIsNotCalledATailscaleRefusal() {
        let p = TerminalComputerProblem.diagnose(SSHNotTailscale(offersPassword: true, offersKey: true),
                                                 user: "guest", host: "guests-mac", port: 22, tailscale: true)
        XCTAssertEqual(p, .ordinarySSH(user: "guest", offersPassword: true))
        XCTAssertTrue(p.text.hasPrefix("This computer does not use Tailscale SSH."), p.text)
        XCTAssertFalse(p.text.contains("Tailscale did not let"), p.text)
        let noPw = TerminalComputerProblem.diagnose(SSHNotTailscale(offersPassword: false, offersKey: true),
                                                    user: "guest", host: "h", port: 22, tailscale: true)
        XCTAssertTrue(noPw.text(.addSheet).contains("does not take passwords"), noPw.text(.addSheet))
        let ts = TerminalComputerProblem.diagnose(SSHSignInRefused(reason: "tailscale: tailnet policy does not permit you to SSH as user \"root\""),
                                                  user: "root", host: "h", port: 22, tailscale: true)
        XCTAssertTrue(ts.text.hasPrefix("Tailscale did not let this iPhone sign in as “root”"), ts.text)
    }

    /// Item 5: each outcome of the one-time password sign-in in plain words; the key to copy only when the server
    /// takes no password.
    func testPasswordSignInOutcomes() {
        let o = { (r: KeyInstallByPassword.Outcome) in TerminalKeyByPassword.outcome(r, user: "alex", name: "Alex’s Mac") }
        XCTAssertTrue(o(.added(alreadyThere: false)).ok)
        XCTAssertTrue(o(.wrongPassword).text.contains("did not accept that password"))
        XCTAssertFalse(o(.wrongPassword).keyByHandOnly)
        XCTAssertTrue(o(.passwordNotAllowed).keyByHandOnly)
        // Every case the app cannot finish shows the key to copy and says so.
        XCTAssertTrue(o(.cannotWrite(detail: "Permission denied")).text.contains("could not save the key"))
        XCTAssertTrue(o(.cannotWrite(detail: "x")).keyByHandOnly)
        XCTAssertTrue(o(.windows).text.contains("Windows PC"))
        XCTAssertTrue(o(.windows).keyByHandOnly)
    }

    /// Item 6: what the Host said, step by step, in place; nothing about Tailscale.
    func testHostSteps() {
        func r(_ s: WireTerminalKeyResult.Status, user: String = "robin", login: Bool = true, reason: String = "") -> WireTerminalKeyResult {
            WireTerminalKeyResult(requestID: 1, status: s, remoteLoginOn: login, tmuxPresent: true, userName: user, reason: reason)
        }
        XCTAssertEqual(AddComputerSheet.hostSteps(.answered(.answered(r(.installed))), typed: "robin"),
                       ["Glass Act Host added this iPhone’s key for “robin”."])
        let other = AddComputerSheet.hostSteps(.answered(.answered(r(.alreadyThere, user: "robinmac", login: false))), typed: "robin")
        XCTAssertTrue(other.contains { $0.contains("went to that account") })
        XCTAssertTrue(other.contains { $0.contains("Remote Login looks off") })
        XCTAssertEqual(AddComputerSheet.hostSteps(.answered(.olderHost), typed: "x"), ["This Mac’s Glass Act Host is older and can’t add the key."])
        XCTAssertEqual(AddComputerSheet.hostSteps(.noLink("Glass Act Host on Robin did not answer."), typed: "x"),
                       ["Glass Act Host on Robin did not answer."])
        for steps in [other, AddComputerSheet.hostSteps(.answered(.answered(r(.refused, reason: "no"))), typed: "x")] {
            XCTAssertFalse(steps.joined().contains("Tailscale"))
        }
    }
}
#endif
