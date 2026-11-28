// The production `TurnClock`.

/// The production clock: `now` is monotonic and measured from `TurnInstant.processOrigin`, and
/// `sleep(until:)` honours `TurnClock`'s contract. It is a value with no state, so every copy
/// reads and sleeps on the same continuous clock.
///
/// Its sleep returns once `now` has reached the instant, never earlier unless its task is
/// cancelled. A timed sleep can wake slightly early on some platforms, so the sleep reads the clock
/// again after each wake and sleeps on for what is left. It sleeps with `Task.sleep(nanoseconds:)`,
/// never `Task.sleep(for:)`, which can crash in macOS release builds under load.
///
/// It compares instants by their order, never by the sign of their difference: a caller can pass
/// any instant, near either end of the range, and a difference clamped there no longer measures
/// the gap (`TurnInstant`'s `+` and `-` clamp, #791). Only an ordered pair is subtracted, with
/// overflow reported, and no single sleep is longer than an hour.
public struct SystemTurnClock: TurnClock {
    public init() {}

    public var now: TurnInstant { TurnInstant(ContinuousClock.now) }

    /// The longest single sleep: one hour. A longer wait sleeps in chunks and reads the clock
    /// between them, so no sleep is given a length near the range's end.
    private static let longestSleepNanoseconds: UInt64 = 3_600_000_000_000

    public func sleep(until instant: TurnInstant) async {
        while !Task.isCancelled {
            let current = now
            if current >= instant { return }
            // `current < instant`, so the true difference is positive. It overflows `Int64` only
            // when `current` is negative and `instant` is far above zero: sleep a full chunk then.
            let (difference, overflow) = instant.nanoseconds.subtractingReportingOverflow(current.nanoseconds)
            let chunk = overflow || difference <= 0
                ? Self.longestSleepNanoseconds
                : min(UInt64(difference), Self.longestSleepNanoseconds)
            do {
                try await turnsSafeSleep(nanoseconds: chunk)
            } catch {
                // The protocol's sleep doesn't throw: a cancelled sleep returns at once.
                return
            }
        }
    }
}
