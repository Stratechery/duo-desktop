import XCTest

///  Fails if any of your own Mac names, tailnet, account names or a home/Tailscale address appears in the app's sources
/// (code, help text, comments), its tests or the project file.
final class NoBuiltInMacsTests: XCTestCase {
    /// Your own Mac names, user names and tailnet name, one per line, in `app/private-names.local.txt`. That file is
    /// ignored by git, so the names never enter the repository; without it only the address check runs.
    static let forbidden: [String] = {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("private-names.local.txt")
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }()
    /// 192.168.x.x and 100.x.x.x addresses.
    static let addresses = try! NSRegularExpression(pattern: #"\b(192\.168|100)\.\d{1,3}\.\d{1,3}(\.\d{1,3})?\b"#)

    /// The whole Tailscale address range (100.64.0.0/10), not anyone's address: the JetKVM build's App Transport
    /// Security exception lists it so a JetKVM typed as its tailnet IP address loads over plain HTTP (iOS 17 and
    /// later restrict IP addresses).
    static let tailnetRange = "100" + ".64.0.0"

    func testNoOwnersMacsInTheSources() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        var checked = 0
        var hits: [String] = []
        // The terminal's SSH engine and the JetKVM client are part of the app too.
        for folder in ["DuoDesktop", "DuoDesktopTests", "DuoDesktopUITests", "scripts", "Notices", "DuoTerminalKit",
                       "../jetkvm-client"] {
            let root = app.appendingPathComponent(folder)
            guard let walk = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in walk where ["swift", "plist", "strings", "sh", "yml", "json", "md", "txt"].contains(url.pathExtension)
                && !url.path.contains("/.build/") {
                guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
                checked += 1
                for name in Self.forbidden where text.localizedCaseInsensitiveContains(name) {
                    hits.append("\(folder)/\(url.lastPathComponent): \(name)")
                }
                let range = NSRange(text.startIndex..., in: text)
                for m in Self.addresses.matches(in: text, range: range)
                    where (text as NSString).substring(with: m.range) != Self.tailnetRange {
                    hits.append("\(folder)/\(url.lastPathComponent): \((text as NSString).substring(with: m.range))")
                }
            }
        }
        // The project files, and the Host patches this app's builds add (the terminal key install among them).
        let patches = app.deletingLastPathComponent().appendingPathComponent("patches")
        let patchList = (try? String(contentsOf: app.appendingPathComponent("GLASSACT_PATCHES"), encoding: .utf8)) ?? ""
        let extra = ["project.yml", "project-terminal.yml", "project-jetkvm.yml"].map { app.appendingPathComponent($0) }
            + patchList.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }
                .map { patches.appendingPathComponent(String($0)) }
        XCTAssertTrue(patchList.contains("duo-terminal-key-install-on-main.patch"), "the key-install patch is listed")
        for url in extra {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { hits.append("missing: \(url.lastPathComponent)"); continue }
            for name in Self.forbidden where text.localizedCaseInsensitiveContains(name) { hits.append("\(url.lastPathComponent): \(name)") }
        }
        XCTAssertGreaterThan(checked, 20, "the app's sources were not found from \(app.path)")
        XCTAssertEqual(hits, [], hits.joined(separator: "\n"))
    }
}
