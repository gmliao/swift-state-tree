// The values a machine and its turn exchange with the core.

import Foundation

// MARK: - Identities

/// Names one `call`'s waiter. A step reads it from `Turn.input` and answers it with `Turn.reply`.
public struct InputID: Hashable, Sendable {
    @usableFromInline let raw: UInt64
    @inlinable init(raw: UInt64) { self.raw = raw }
}

/// Names one request: asynchronous work owned by a key's generation.
public struct RequestID: Hashable, Sendable {
    @usableFromInline let raw: UInt64
    @inlinable init(raw: UInt64) { self.raw = raw }
}

/// One life of a key, from `Turn.issue` to `Turn.end`. For comparisons and logs only: a handler
/// never needs one to know whether a result is still wanted, because the core decides that.
public struct Generation: Hashable, Sendable {
    @usableFromInline let raw: UInt64
    @inlinable init(raw: UInt64) { self.raw = raw }
}

// MARK: - End tokens

/// Evidence, owned upstream, that an input is no longer wanted (a router's join attempt that
/// ended). It travels with the input, so it covers an end that reaches the core before the input
/// does, which no key can: there is nothing to end yet. It lives as long as the input.
///
/// The core reads it when the input is about to step: on arrival, and on release from parking.
/// Marking it upstream doesn't remove a parked input; that input keeps its place until it is
/// released (and is then withdrawn), or until a step calls `Turn.revoke`. An end after the read
/// belongs to the started input, and is the machine's to handle. A machine never stores a token.
public final class EndToken: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false

    public init() {}

    public var isEnded: Bool { lock.withLock { ended } }

    public func markEnded() { lock.withLock { ended = true } }
}

// MARK: - Admission, holds, outcomes

/// How an input is admitted.
public enum Admission<Key: Hashable & Sendable>: Sendable {
    /// From outside: refused `closed` after `close`, refused `withdrawn` if `unless` has ended,
    /// parked while `hold` is blocked (refused `overloaded` over the parked limit). `scope`: the
    /// key the input belongs to; ending it withdraws the input while it is parked.
    case external(hold: Key?, scope: Key?, unless: EndToken? = nil)
    /// Never gated, parked or refused: a disconnect, a stop, a teardown, a `run`'s result.
    case control
}

/// A key that a request keeps busy: external inputs that name it as their hold wait.
///
/// Every holding request has a deadline, and the deadline bounds the request: when it passes,
/// the request is abandoned, its caller can be answered and `handleAbandoned` runs. An
/// `.untilRequestCloses` hold ends with the request; an `.untilWorkerRetires` hold ends only when
/// its worker returns, so the adopter bounds that worker. A request with no bound would leave
/// every input parked behind its key waiting for as long as its work hangs.
public enum Hold<Key: Hashable & Sendable>: Sendable {
    /// Held until the request closes, for any reason.
    case untilRequestCloses(Key, deadline: Duration)
    /// Held until the worker's result arrives, also after the request closed without it: for
    /// work that changes another domain while it runs.
    case untilWorkerRetires(Key, deadline: Duration)

    @inlinable var key: Key {
        switch self {
        case .untilRequestCloses(let key, _), .untilWorkerRetires(let key, _): key
        }
    }

    @inlinable var deadline: Duration {
        switch self {
        case .untilRequestCloses(_, let deadline), .untilWorkerRetires(_, let deadline): deadline
        }
    }

    @inlinable var untilRetire: Bool {
        if case .untilWorkerRetires = self { return true }
        return false
    }
}

/// Why a request closed without its completion.
public enum Abandonment: Sendable, Equatable {
    case keyEnded, deadline, cancelled
}

/// Why an external input never stepped.
public enum TurnError: Error, Sendable, Equatable {
    /// The core is closed to external inputs.
    case closed
    /// The parked queue is full.
    case overloaded
    /// Its scope ended or was superseded, or its token ended, before it stepped.
    case withdrawn
}

/// What a `call` does when its task is cancelled. There is no default: each call states it.
public enum CallerCancellation: Sendable {
    /// Nothing: the caller keeps waiting and gets the real result.
    case ignored
    /// An external input not yet submitted isn't; one still parked when the cancellation is
    /// handled is withdrawn and never steps; one that stepped goes on, and only its caller stops
    /// waiting. A control input is always submitted and stepped. The caller gets
    /// `CancellationError`.
    case honoured
}

// MARK: - Time

/// An instant on the core's clocks: signed nanoseconds since the process's origin, so a
/// difference can be negative. Every production clock measures from one origin per process,
/// captured once, so an instant a machine stored stays meaningful under a replaced core or a
/// second clock. A test clock starts at zero and is never mixed with a production one.
public struct TurnInstant: Hashable, Comparable, Sendable {
    public let nanoseconds: Int64

    @inlinable public init(nanoseconds: Int64) { self.nanoseconds = nanoseconds }

    @inlinable public static func < (lhs: TurnInstant, rhs: TurnInstant) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    @inlinable public static func + (lhs: TurnInstant, rhs: Duration) -> TurnInstant {
        TurnInstant(nanoseconds: lhs.nanoseconds &+ rhs.turnNanoseconds)
    }

    @inlinable public static func - (lhs: TurnInstant, rhs: TurnInstant) -> Duration {
        .nanoseconds(lhs.nanoseconds &- rhs.nanoseconds)
    }

    /// The process's origin for production clocks, captured on first use.
    public static let processOrigin = ContinuousClock.now

    /// The continuous clock's instant, measured from the process's origin.
    public init(_ instant: ContinuousClock.Instant) {
        self.init(nanoseconds: (instant - Self.processOrigin).turnNanoseconds)
    }

    /// This instant on the continuous clock.
    public var continuous: ContinuousClock.Instant {
        Self.processOrigin + .nanoseconds(nanoseconds)
    }
}

extension Duration {
    /// Whole nanoseconds, saturating at `Int64`'s range.
    @inlinable var turnNanoseconds: Int64 {
        let (seconds, attoseconds) = components
        let (scaled, overflow) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if overflow { return seconds < 0 ? .min : .max }
        let (sum, overflow2) = scaled.addingReportingOverflow(attoseconds / 1_000_000_000)
        if overflow2 { return seconds < 0 ? .min : .max }
        return sum
    }
}

/// The clock a core reads and sleeps on. Injected, with no default: a production adopter passes
/// one that measures from `TurnInstant.processOrigin` and sleeps with its own safe sleep; a test
/// passes one it drives by hand.
public protocol TurnClock: Sendable {
    var now: TurnInstant { get }
    /// Returns at `instant`, or earlier when its task is cancelled. A caller that wakes re-checks
    /// whatever it slept for: the core does, before it abandons a request or fires a timer.
    func sleep(until instant: TurnInstant) async
}
