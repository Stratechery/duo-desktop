#if DUO_TERMINAL
import DuoTerminalKit
import XCTest
@testable import DuoDesktop

/// Every check message says what is wrong first, then what to do, naming the control by its name on screen. Made-up
/// names only.
@MainActor
final class AddTerminalWordsTests: XCTestCase {
    private let all: [TerminalComputerProblem] = [
        .tailscaleRefused(user: "pat", said: nil), .keyRefused(user: "pat", offersPassword: false),
        .keyRefused(user: "pat", offersPassword: true), .ordinarySSH(user: "pat", offersPassword: false),
        .ordinarySSH(user: "pat", offersPassword: true), .nothingOnPort(22), .notReachable(host: "lab-server"),
        .signInTimedOut,
    ]

    /// The owner's case: Tailscale chosen, ordinary SSH, no passwords. Says it is not Tailscale SSH, then "Set Sign In With to
    /// This iPhone's Key", then how the key gets there (Copy This iPhone's Key, the list of allowed keys).
    func testOrdinarySSHWithoutPasswordNamesSignInWithAndCopy() {
        let t = TerminalComputerProblem.ordinarySSH(user: "pat", offersPassword: false).text(.addSheet)
        XCTAssertTrue(t.hasPrefix("This computer does not use Tailscale SSH."), t)
        let set = try! XCTUnwrap(t.range(of: "Set Sign In With to This iPhone’s Key."))
        let copy = try! XCTUnwrap(t.range(of: "Copy This iPhone’s Key"))
        XCTAssertLessThan(set.lowerBound, copy.lowerBound)
        XCTAssertTrue(t.contains("list of allowed keys for “pat”"), t)
        XCTAssertTrue(t.contains("does not take passwords"), t)
    }

    /// Ordinary SSH that takes a password: the sheet names its own Sign In and Add Key; elsewhere (no password field)
    /// it names Sign In With and the copy button.
    func testOrdinarySSHWithPassword() {
        let p = TerminalComputerProblem.ordinarySSH(user: "pat", offersPassword: true)
        XCTAssertTrue(p.text(.addSheet).contains("tap Sign In and Add Key"), p.text(.addSheet))
        XCTAssertTrue(p.text(.elsewhere).contains("Set Sign In With to This iPhone’s Key."), p.text(.elsewhere))
        XCTAssertTrue(p.text(.elsewhere).contains("Copy This iPhone’s Key"))
    }

    func testKeyRefusedNamesCopyOrPassword() {
        XCTAssertTrue(TerminalComputerProblem.keyRefused(user: "pat", offersPassword: false).text(.addSheet)
            .contains("Tap Copy This iPhone’s Key"))
        XCTAssertTrue(TerminalComputerProblem.keyRefused(user: "pat", offersPassword: true).text(.addSheet)
            .contains("Sign In and Add Key"))
    }

    func testTailscaleRefusedNamesUserName() {
        XCTAssertTrue(TerminalComputerProblem.tailscaleRefused(user: "pat", said: nil).text.contains("Check User Name."))
    }

    func testNothingOnPortNamesPort() {
        XCTAssertTrue(TerminalComputerProblem.nothingOnPort(2222).text.contains("Check Port"))
    }

    func testNotReachableAndTimeoutNameTheAddress() {
        XCTAssertTrue(TerminalComputerProblem.notReachable(host: "lab-server").text.contains("Check the address"))
        XCTAssertTrue(TerminalComputerCheck.timedOutText("lab-server").contains("Check the address"))
    }

    /// No "by hand", no "what is wrong above", no file paths (a Windows administrator's list is elsewhere), in every
    /// check message, password outcome and footer.
    func testNoVagueWordsOrPaths() {
        let o = { (r: KeyInstallByPassword.Outcome) in TerminalKeyByPassword.outcome(r, user: "pat", name: "Lab PC").text }
        var texts = all.flatMap { [$0.text(.addSheet), $0.text(.elsewhere)] }
        texts += [o(.wrongPassword), o(.passwordNotAllowed), o(.cannotWrite(detail: "x")), o(.windows), o(.failed("x"))]
        texts += [AddComputerSheet.savedAnyway, AddComputerSheet.terminalSignInFooter, PhoneKeySection.footer]
        for t in texts {
            for bad in ["by hand", "what is wrong above", "~/", "/.ssh", "\\", "ProgramData"] {
                XCTAssertFalse(t.contains(bad), "“\(bad)” in: \(t)")
            }
        }
    }

    /// A Windows PC (the password sign-in found it): the key to copy, and no Opens advice any more.
    func testWindowsOutcomeMarksAPCAndNamesNoShellChoice() {
        let w = TerminalKeyByPassword.outcome(.windows, user: "pat", name: "Lab PC")
        XCTAssertFalse(w.text.contains("Login Shell") || w.text.contains("tmux"), w.text)
        XCTAssertTrue(w.keyByHandOnly)
        XCTAssertTrue(w.windows)
    }

    /// The footer under Sign In: one line per choice, each saying when to pick it.
    func testSignInFooterHasFourLines() {
        let lines = AddComputerSheet.terminalSignInFooter.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.map { $0.components(separatedBy: ":")[0] }, ["Tailscale", "This iPhone’s Key", "tmux", "Login Shell"])
        XCTAssertTrue(lines.allSatisfy { $0.contains("pick this") })
    }

    /// Part 2: the notice's button names a way in the computer has. A PC's Screen Sharing slot is Remote Desktop, so it
    /// reads "Open in Remote Desktop Instead", never Screen Sharing.
    func testInsteadButtonNamesTheWayTheComputerHas() {
        var pc = MacEntry.terminalComputer(name: "Lab PC", address: "lab-pc", port: 22, user: "pat",
                                           signIn: .tailscale, opens: .tmux)
        pc.remoteDesktop = true
        XCTAssertTrue(pc.hasRemoteDesktop)
        let titles = ComputerNav.others(pc, than: .terminal).map(pc.insteadTitle)
        XCTAssertTrue(titles.contains("Open in Remote Desktop Instead"), "\(titles)")
        XCTAssertFalse(titles.contains("Open in Screen Sharing Instead"), "\(titles)")
        // A terminal-only computer with nothing else offers no other way at all.
        let lone = MacEntry.terminalComputer(name: "Lab Server", address: "lab", port: 22, user: "pat",
                                             signIn: .tailscale, opens: .tmux)
        XCTAssertEqual(ComputerNav.others(lone, than: .terminal), [])
    }

    /// The notice offers Open Settings exactly for the failures fixed there (not for ones that retry by themselves).
    func testSettingsOfferedForSettingsFixes() {
        XCTAssertTrue(TerminalComputerProblem.ordinarySSH(user: "pat", offersPassword: false).opensSettings)
        XCTAssertTrue(TerminalComputerProblem.keyRefused(user: "pat", offersPassword: false).opensSettings)
        XCTAssertFalse(TerminalComputerProblem.notReachable(host: "h").opensSettings)
    }
}
#endif
