import Foundation

/// Leaving Duo Desktop for another app and coming back (the owner 2026-11-20: "Is there any way to persist the connection
/// in the background so it doesn't have to reconnect every time I switch to it?"). The decisions only, as a value
/// type the tests drive; `SessionModel` carries out the actions.
///
/// iOS gives a backgrounded app a short, unguaranteed time (Apple DTS: "On current systems you can expect about 30
/// seconds"), then suspends it. So: keep the session while iOS lets the app run; once it has ended, keep the last
/// picture on screen, marked as not live, with the keys and trackpad in place, and rejoin at once on return. Nothing
/// is sent to the Mac until the picture is live again. The Touch ID lock (after 5 minutes away) comes first.
struct ReturnFlow: Equatable {
    enum Stage: Equatable {
        /// No session on screen (the list of Macs).
        case none
        /// The picture is live and input goes to the Mac.
        case live
        /// Left for another app; the session is still running (the picture paused by the Mac).
        case awayKept
        /// Back with a session it believes is running: proving it is alive before input goes to the Mac. The
        /// picture shows as normal (no dimming for this short moment); input is held back.
        case checking
        /// Left for another app; the session has ended. The last picture is kept for the return.
        case awayEnded
        /// Back, ended session, waiting for Touch ID before rejoining.
        case waitingForUnlock
        /// Rejoining behind the last picture.
        case rejoining
        /// The rejoin did not work; the last picture stays with a plain message and Try Again.
        case failed
    }

    enum Action: Equatable {
        case nothing
        /// Let go of held input, ask the Mac to pause the picture, and ask iOS for background time.
        case pause
        /// End the connection, keeping the last picture and the Mac.
        case endKeepingPicture
        /// Back with a kept session: ask the Mac for the picture again and start proving the session is alive
        /// (`ReturnCheck`), input still held back.
        case check
        /// The session is proven alive: input goes to the Mac again.
        case resume
        /// Dial the Mac again, behind the last picture.
        case dial
        /// Show the plain failure with Try Again.
        case showFailure
    }

    private(set) var stage: Stage = .none

    /// Most redials a rejoin makes before it says so plainly (each is up to a 5 s connect timeout plus 1 s): about
    /// 20 seconds, not the library's 2 minutes, so a Mac that is really gone is reported soon.
    static let rejoinAttempts = 3

    /// The last picture is on screen, dimmed and marked as not live.
    var showsHeldPicture: Bool { [.awayEnded, .waitingForUnlock, .rejoining, .failed].contains(stage) }
    /// The session screen is shown (live or held).
    var showsSession: Bool { stage != .none }
    /// Taps, keys and trackpad reach the Mac only while live.
    var acceptsInput: Bool { stage == .live }
    /// The picture draws from the session's own connection (live, kept in the background, or being checked).
    var drawsFromSession: Bool { [.live, .awayKept, .checking].contains(stage) }

    /// The picture arrived (a first connect, a rejoin, or a redial after a drop in the foreground).
    mutating func wentLive() -> Action {
        stage = .live
        return .nothing
    }

    /// The app went to the background.
    mutating func left() -> Action {
        switch stage {
        case .live, .checking:
            stage = .awayKept
            return .pause
        case .rejoining, .failed, .waitingForUnlock:
            // Leaving mid-rejoin: stop dialling; rejoin again on return.
            stage = .awayEnded
            return .endKeepingPicture
        default:
            return .nothing
        }
    }

    /// iOS's background time ran out while the session was kept.
    mutating func backgroundTimeUp() -> Action {
        guard stage == .awayKept else { return .nothing }
        stage = .awayEnded
        return .endKeepingPicture
    }

    /// The connection failed. In the foreground a live session rejoins behind its picture; away, it is simply over
    /// until the return.
    mutating func connectionDropped(inForeground: Bool) -> Action {
        switch stage {
        case .live where inForeground:
            stage = .rejoining
            return .dial
        case .checking where inForeground:
            stage = .rejoining
            return .dial
        case .live, .awayKept, .checking:
            stage = .awayEnded
            return .endKeepingPicture
        default:
            return .nothing
        }
    }

    /// Back in the foreground. `locked`: the Touch ID lock is up (5 minutes or more away).
    mutating func returned(locked: Bool) -> Action {
        switch stage {
        case .awayKept:
            stage = .checking
            return .check
        case .awayEnded:
            if locked {
                stage = .waitingForUnlock
                return .nothing
            }
            stage = .rejoining
            return .dial
        default:
            return .nothing
        }
    }

    /// The session answered after the return (`ReturnCheck` says alive).
    mutating func checkPassed() -> Action {
        guard stage == .checking else { return .nothing }
        stage = .live
        return .resume
    }

    /// Nothing heard from the Mac within `ReturnCheck.boundSeconds` of the return: treat the session as dead and
    /// rejoin behind the last picture.
    mutating func checkTimedOut() -> Action {
        guard stage == .checking else { return .nothing }
        stage = .rejoining
        return .dial
    }

    /// Touch ID passed.
    mutating func unlocked() -> Action {
        guard stage == .waitingForUnlock else { return .nothing }
        stage = .rejoining
        return .dial
    }

    /// The rejoin's redials are spent.
    mutating func rejoinFailed() -> Action {
        guard stage == .rejoining else { return .nothing }
        stage = .failed
        return .showFailure
    }

    /// Try Again.
    mutating func retry() -> Action {
        guard stage == .failed else { return .nothing }
        stage = .rejoining
        return .dial
    }

    /// The session is over for good: Leave, the Mac ended it, a key or version problem, or a fresh connect.
    mutating func ended() {
        stage = .none
    }
}

/// Is the kept session still alive on return? The quickest honest signal Glass Act's viewer offers without changing
/// it: the Host PINGs once a second, even while the picture is paused (`HostEngine`, "ping at 1 Hz"), and the viewer
/// engine stamps every control byte it receives (`ViewerEngine.lastControlRxUS`, the same stamp the library's own
/// 10 s liveness watchdog reads). The viewer has no ping of its own to send. So: alive once control bytes arrive
/// after the return; dead if none arrive within the bound.
///
/// - Bound: from the session's own measured spacing of control bytes (`LinkPace`): the longest gap seen while
///   live, plus half a second, never under 1.5 s (the next 1 Hz ping plus half a second for the network, a fast
///   link) and never over 4 s (a dead session is still caught quickly). A slow link whose pings arrive 1.8 s apart
///   gets 2.3 s instead of being called dead at 1.5 s and rejoined (the owner 2026-11-20: "This needs to work on all
///   connections").
/// - Grace 0.1 s: bytes read in the first moment after the return may be old ones iOS buffered while the app was
///   suspended, sent before the Host gave up; they do not count. A ping that lands in that moment costs one more
///   ping (about 1 s), still inside the bound.
struct ReturnCheck: Equatable {
    enum Verdict: Equatable { case waiting, alive, dead }

    static let floorUS: UInt64 = 1_500_000
    static let ceilingUS: UInt64 = 4_000_000
    static let marginUS: UInt64 = 500_000
    static let graceUS: UInt64 = 100_000

    /// When the app came back (monotonic microseconds, the engine's clock).
    let returnedUS: UInt64
    /// How long to wait for the Mac before calling the session dead.
    let boundUS: UInt64

    init(returnedUS: UInt64, boundUS: UInt64 = ReturnCheck.floorUS) {
        self.returnedUS = returnedUS
        self.boundUS = min(Self.ceilingUS, max(Self.floorUS, boundUS))
    }

    var boundSeconds: Double { Double(boundUS) / 1_000_000 }

    func verdict(lastControlRxUS: UInt64, nowUS: UInt64) -> Verdict {
        if lastControlRxUS >= returnedUS &+ Self.graceUS { return .alive }
        if nowUS >= returnedUS &+ boundUS { return .dead }
        return .waiting
    }
}

/// The session's measured pace: how long control bytes from the Mac go missing while the picture is live (the
/// Host's 1 Hz pings, plus everything else it sends). Sampled four times a second; the last 30 seconds are kept.
struct LinkPace: Equatable {
    static let keep = 120
    private(set) var stalenessUS: [UInt64] = []

    /// One sample: now minus the last control byte's arrival.
    mutating func record(stalenessUS us: UInt64) {
        stalenessUS.append(us)
        if stalenessUS.count > Self.keep { stalenessUS.removeFirst(stalenessUS.count - Self.keep) }
    }

    mutating func reset() { stalenessUS.removeAll() }

    /// The return check's bound: the longest gap seen plus the margin, held between the floor and the ceiling.
    var returnBoundUS: UInt64 {
        let longest = stalenessUS.max() ?? 0
        return min(ReturnCheck.ceilingUS, max(ReturnCheck.floorUS, longest &+ ReturnCheck.marginUS))
    }
}
