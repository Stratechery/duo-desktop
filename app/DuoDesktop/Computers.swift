import Foundation
import Network
import SwiftUI

// One list of computers (project notes, one computer with any connection, milestone 1). A computer with Screen Sharing
// keeps its Glass Act row and check (`MacRow`, `MacList`); a computer without it gets this row and a plain TCP check
// of its first way in. In every build: the check needs neither the Terminal nor the JetKVM code.

// MARK: - Reach: is the first way in there? A plain TCP connect, every time the list appears

/// Each computer-without-Screen-Sharing's dot. "Reachable" only, never "signed in" (review finding 3): the check
/// opens a TCP connection to the SSH port or the JetKVM's web port and closes it. No SSH, no password read, no
/// JetKVM viewer (that would take over whoever is watching it).
@MainActor @Observable
final class ComputerReach {
    enum State: Equatable {
        case checking, ready, notReachable
        var label: String {
            switch self {
            case .checking: "Checking…"
            case .ready: "Ready"
            case .notReachable: "Not reachable"
            }
        }
        var reachable: Bool { self == .ready }
        var color: Color { self == .ready ? .green : .gray }
    }

    static let shared = ComputerReach()
    private(set) var states: [String: State] = [:]
    private var generation = 0
    /// Tests swap the connect.
    @ObservationIgnored var check: (String, UInt16, TimeInterval, @escaping @Sendable (Bool) -> Void) -> Void = TCPCheck.check

    func state(_ id: String) -> State { states[id] ?? .checking }

    /// Where the check connects: the first way in this build has after Screen Sharing (which has its own check).
    nonisolated static func target(_ e: MacEntry) -> (host: String, port: UInt16)? {
        switch e.waysInThisBuild.first(where: { $0 != .screenSharing }) {
        case .terminal?:
            guard let host = e.address(.tailscale) ?? e.address(.home) else { return nil }
            return (host, e.sshPortValue)
        case .jetkvm?:
            guard let host = e.jetkvmHost else { return nil }
            let https = e.jetkvmAddress?.lowercased().hasPrefix("https://") == true
            return (host, https ? 443 : 80)
        default:
            return nil
        }
    }

    func probeAll(_ entries: [MacEntry]) {
        generation += 1
        let g = generation
        for e in entries {
            // The simulator checks these too, as build 59 did (the live Linux-server proof needs it).
            guard let t = Self.target(e) else { states[e.id] = .notReachable; continue }
            // Keep the last answer while rechecking (as the Mac rows do), so a tap right after a session works.
            if states[e.id] == nil { states[e.id] = .checking }
            let id = e.id
            check(t.host, t.port, 2) { [weak self] ok in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self, self.generation == g else { return }
                        self.states[id] = ok ? .ready : .notReachable
                    }
                }
            }
        }
    }
}

/// One TCP connect, answered once: true when the port took the connection within `timeout`.
enum TCPCheck {
    static func check(host: String, port: UInt16, timeout: TimeInterval, done: @escaping @Sendable (Bool) -> Void) {
        guard let p = NWEndpoint.Port(rawValue: port) else { done(false); return }
        let c = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
        let once = Once(done)
        c.stateUpdateHandler = { st in
            switch st {
            case .ready: once.fire(true); c.cancel()
            case .failed, .waiting: once.fire(false); c.cancel()
            default: break
            }
        }
        let q = DispatchQueue(label: "tcp-check")
        c.start(queue: q)
        q.asyncAfter(deadline: .now() + timeout) { once.fire(false); c.cancel() }
    }

    final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var f: (@Sendable (Bool) -> Void)?
        init(_ f: @escaping @Sendable (Bool) -> Void) { self.f = f }
        func fire(_ v: Bool) { lock.withLock { () -> (@Sendable (Bool) -> Void)? in defer { f = nil }; return f }?(v) }
    }
}

// MARK: - The row of a computer without Screen Sharing

/// Name, what it has ("Terminal · JetKVM"), the dot of its first way in, and ⓘ. Same layout as `MacRow`.
struct ComputerRow: View {
    let entry: MacEntry
    let reach: ComputerReach.State
    /// Whether tapping it opens something in this build (milestone 1: a computer with a Terminal).
    let opens: Bool
    let enabled: Bool
    let connect: () -> Void
    let settings: () -> Void
    /// Project notes 1: every row's icon sits in one fixed-width, centred column (the HIG Lists pattern of
    /// Settings: a leading icon column of one width, the text after it), so every name starts at the same place
    /// whatever the symbol's own width. It grows with Dynamic Type with the icon's own text style.
    @ScaledMetric(relativeTo: .title2) private var iconColumn: CGFloat = 34

    static func symbol(_ e: MacEntry) -> String {
        e.hasScreenSharing ? "desktopcomputer" : (e.waysInThisBuild.first == .terminal ? "terminal" : "cable.connector")
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: connect) {
                HStack(spacing: 12) {
                    Image(systemName: Self.symbol(entry))
                        .font(.title2)
                        .foregroundStyle(reach.reachable ? Color.accentColor : .secondary)
                        .frame(width: iconColumn, alignment: .center)
                        .accessibilityIdentifier("computerIcon.\(entry.name)")
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name).font(.headline)
                        Text(entry.waysLine).font(.caption).foregroundStyle(.secondary)
                            .accessibilityIdentifier("computerWays.\(entry.name)")
                    }
                    // The divider starts where the name starts, on every row.
                    .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                    Spacer()
                    HStack(spacing: 6) {
                        Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(reach.color)
                        Text(reach.label)
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .combine)
                }
                .padding(.vertical, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!opens || !reach.reachable || !enabled)
            .accessibilityIdentifier("terminalComputer.\(entry.name)")
            Button("Settings for \(entry.name)", systemImage: "info.circle", action: settings)
                .labelStyle(.iconOnly)
                .font(.title3)
                .buttonStyle(.borderless)
                .accessibilityIdentifier("macSettings.\(entry.name)")
        }
    }
}

// MARK: - Which computer is open on its own screen (no Glass Act session)

/// The computer open on its own screen, and in which way in (milestone 2: a Terminal-only computer in its terminal,
/// a JetKVM-only computer in its JetKVM view). Outside the build switches, so every build reads it; a way in the
/// build cannot show is never set here.
@MainActor @Observable final class ComputerNav {
    static let shared = ComputerNav()
    /// The open computer's id (nil: the list).
    private(set) var openID: String?
    private(set) var way: WayIn?

    /// Opens the computer in its own way in (`MacEntry.opensOnItsOwn`); nothing when it has none in this build.
    func open(_ e: MacEntry) {
        guard let w = e.opensOnItsOwn else { return }
        way = w
        openID = e.id
    }

    func close() {
        openID = nil
        way = nil
    }
}
