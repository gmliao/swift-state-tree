// The values a machine and its turn exchange with the core.

import Foundation

// MARK: - Identities

/// Names one `sendAndWait`'s waiter. A step reads it from `Turn.input` and answers it with `Turn.reply`.
public struct InputID: Hashable, Sendable {
    @usableFromInline let raw: UInt64
    @inlinable init(raw: UInt64) { self.raw = raw }
}

/// Names one request: asynchronous work owned by a key's generation.
public struct RequestID: Hashable, Sendable {
    @usableFromInline let raw: UInt64
    @inlinable init(raw: UInt64) { self.raw = raw }
}

/// One life of a key, from `Turn.start` to `Turn.end`. For comparisons and logs only: a handler
/// never needs one to know whether a result is still wanted, because the core decides that.
public struct Generation: Hashable, Sendable {
    @usableFromInline let raw: UInt64
    @inlinable init(raw: UInt64) { self.raw = raw }
}

// MARK: - Withdraw tokens

/// Evidence, owned upstream, that an input is no longer wanted (a router's join attempt that
/// ended). It travels with the input, so it covers an end that reaches the core before the input
/// does, which no key can: there is nothing to end yet. It lives as long as the input.
///
/// The core reads it when the input is about to step: on arrival, and on release from queuing.
/// Marking it upstream doesn't remove a queued input; that input keeps its place until it is
/// released (and is then withdrawn), or until a step calls `Turn.revoke`. An end after the read
/// belongs to the started input, and is the machine's to handle. A machine never stores a token.
public final class WithdrawToken: @unchecked Sendable {
    private let lock = NSLock()
    private var ended = false

    public init() {}

    public var isWithdrawn: Bool { lock.withLock { ended } }

    public func withdraw() { lock.withLock { ended = true } }
}

// MARK: - InputPolicy, holds, outcomes

/// How an input is admitted.
public enum InputPolicy<Key: Hashable & Sendable>: Sendable {
    /// From outside: refused `closed` after `close`, refused `withdrawn` if `withdrawnBy` is
    /// withdrawn, queued while `waitsFor` is held (refused `queueFull` over the queue limit).
    /// `belongsTo`: the key the input belongs to. Ending that key, or starting it again over a
    /// live generation, after the input arrives and before it steps withdraws it. An input that
    /// arrives after an `end` and before the next `start` steps under the new generation, so
    /// use a fresh key per binding (a connection or session id) when that matters.
    case normal(waitsFor: Key?, belongsTo: Key?, withdrawnBy: WithdrawToken? = nil)
    /// Never gated, queued or refused: a disconnect, a stop, a teardown, a `run`'s result.
    case control
}

/// A key that a request keeps busy: normal inputs that name it as their hold wait.
///
/// Every holding request has a deadline, and the deadline bounds the request: when it passes,
/// the request is abandoned, its caller can be answered and `handleAbandoned` runs. An
/// `.untilRequestCloses` hold ends with the request; an `.untilWorkerReturns` hold ends only when
/// its worker returns, so the adopter bounds that worker. An abandoned request's worker is
/// cancelled; a worker under this hold settles its outside change before it returns, since
/// returning ends the hold, and honours the cancellation only at safe points. A request with no bound would leave
/// every input queued behind its key waiting for as long as its work hangs.
public enum Hold<Key: Hashable & Sendable>: Sendable {
    /// Held until the request closes, for any reason.
    case untilRequestCloses(Key, deadline: Duration)
    /// Held until the worker's result arrives, also after the request closed without it: for
    /// work that changes another domain while it runs.
    case untilWorkerReturns(Key, deadline: Duration)

    @inlinable var key: Key {
        switch self {
        case .untilRequestCloses(let key, _), .untilWorkerReturns(let key, _): key
        }
    }

    @inlinable var deadline: Duration {
        switch self {
        case .untilRequestCloses(_, let deadline), .untilWorkerReturns(_, let deadline): deadline
        }
    }

    @inlinable var untilRetire: Bool {
        if case .untilWorkerReturns = self { return true }
        return false
    }
}

// MARK: - Follow-ups

/// When a pending follow-up (`Turn.followUp`) steps.
public enum FollowUpTrigger<Effect: Sendable>: Sendable {
    /// In a new batch, as the actor's own job after the current one: a follow-up that arms its
    /// successor makes a chain of jobs, never a loop inside one batch. That job is the core's one
    /// continuation, which also releases parked inputs left past the release cap.
    case afterBatch
    /// When `perform(effect)` returns (the gate). A `deadline` that passes first closes the
    /// follow-up with `.deadline`. The gate's own result, if any, steps first, as a `run`'s does.
    case afterWork(Effect, deadline: Duration?)
}

/// What `Turn.followUp` did.
public enum FollowUpArming: Sendable, Equatable {
    /// A new follow-up, under the key's current generation.
    case armed(RequestID)
    /// One was already pending for the key and slot: nothing changed, and the first arm's input
    /// and trigger stand.
    case joined(RequestID)
    /// The key isn't live, or the core has ended: nothing was armed.
    case refused
}

/// Kinds of pending work, for `TurnActor.pendingWork` and `waitForQuiescence`.
public struct TurnWork: OptionSet, Sendable {
    public let rawValue: UInt8
    @inlinable public init(rawValue: UInt8) { self.rawValue = rawValue }
    /// Follow-ups armed and not yet stepped, consumed or closed.
    public static let followUps = TurnWork(rawValue: 1)
    /// Open requests.
    public static let requests = TurnWork(rawValue: 2)
    /// Armed timers.
    public static let timers = TurnWork(rawValue: 4)
}

/// Why a request closed without its completion.
public enum Abandonment: Sendable, Equatable {
    case keyEnded, deadline, cancelled
}

/// Why a normal input never stepped.
public enum TurnError: Error, Sendable, Equatable {
    /// The core is closed to normal inputs. A call that stepped can get it too, as the default
    /// `handleWaitEnded`'s answer when `endAll` ends its barrier wait.
    case closed
    /// The queue is full.
    case queueFull
    /// Its scope ended or was superseded, or its token was withdrawn, before it stepped.
    case withdrawn
    /// Its barrier wait's timeout passed (`Turn.wait`): the default `handleWaitEnded`'s answer. A
    /// call that stepped can get it, unlike the cases above.
    case timedOut
}

/// What a `sendAndWait` does when its task is cancelled. There is no default: each call states it.
public enum CallerCancellation: Sendable {
    /// Nothing: the caller keeps waiting and gets the real result.
    case ignoresCancel
    /// A normal input not yet submitted isn't; one still queued when the cancellation is
    /// handled is withdrawn and never steps; one that stepped goes on, and only its caller stops
    /// waiting. A control input is always submitted and stepped. The caller gets
    /// `CancellationError`. A core replaying its mail stops the process on it: a replay can't
    /// place a cancellation, so a replayed core's calls use `ignoresCancel`.
    case cancelsCall
}

// MARK: - Time

/// An instant on the core's clocks: signed nanoseconds since the process's origin, so a
/// difference can be negative. Every production clock measures from one origin per process,
/// captured once, so an instant a machine stored stays meaningful under a replaced core or a
/// second clock. A test clock starts at zero and is never mixed with a production one.
///
/// The arithmetic saturates at `Int64`'s range instead of wrapping (#791): `now + .seconds(.max)`
/// is the latest instant (a timer that never fires, not one in the past), and the difference of
/// two instants never has the wrong sign.
public struct TurnInstant: Hashable, Comparable, Sendable {
    public let nanoseconds: Int64

    @inlinable public init(nanoseconds: Int64) { self.nanoseconds = nanoseconds }

    @inlinable public static func < (lhs: TurnInstant, rhs: TurnInstant) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    /// `lhs + rhs` in whole nanoseconds (the duration truncated toward zero), clamped at
    /// `Int64`'s range. The sum is taken in `Int128`, so a negative instant plus a duration just
    /// past the range lands exactly, below the end.
    @inlinable public static func + (lhs: TurnInstant, rhs: Duration) -> TurnInstant {
        TurnInstant(nanoseconds: clamped(Int128(lhs.nanoseconds) + rhs.attoseconds / 1_000_000_000))
    }

    /// `lhs - rhs`, clamped at `Int64` nanoseconds: its sign always agrees with the order.
    @inlinable public static func - (lhs: TurnInstant, rhs: TurnInstant) -> Duration {
        .nanoseconds(TurnInstant.clamped(Int128(lhs.nanoseconds) - Int128(rhs.nanoseconds)))
    }

    /// `wide` clamped at `Int64`'s range.
    @inlinable static func clamped(_ wide: Int128) -> Int64 {
        if wide > Int128(Int64.max) { return .max }
        if wide < Int128(Int64.min) { return .min }
        return Int64(wide)
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
    /// Whole nanoseconds (truncated toward zero), saturating at `Int64`'s range. Read from
    /// `attoseconds` (an `Int128`): `components` converts its seconds to `Int64`, which traps for
    /// a duration past `Int64.max` seconds.
    @inlinable var turnNanoseconds: Int64 {
        let nanoseconds = attoseconds / 1_000_000_000
        if nanoseconds > Int128(Int64.max) { return .max }
        if nanoseconds < Int128(Int64.min) { return .min }
        return Int64(nanoseconds)
    }
}

/// The clock a core reads and sleeps on. Injected, with no default: a production adopter passes
/// `SystemTurnClock`, which measures from `TurnInstant.processOrigin` and sleeps with a safe
/// sleep; a test passes one it drives by hand.
public protocol TurnClock: Sendable {
    var now: TurnInstant { get }
    /// Returns once `now` has reached `instant`, never earlier unless its task is cancelled: the
    /// core fires what is due at the instant it slept until without reading the clock again. A
    /// cancelled sleep may return at once. A core has one current sleep; sleeps it superseded may
    /// still be finishing, and their returns do nothing.
    func sleep(until instant: TurnInstant) async
}
