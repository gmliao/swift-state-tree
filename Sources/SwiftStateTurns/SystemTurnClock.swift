// The production `TurnClock`.

/// The production clock: `now` is monotonic and measured from `TurnInstant.processOrigin`, and
/// `sleep(until:)` honours `TurnClock`'s contract. It is a value with no state, so every copy
/// reads and sleeps on the same continuous clock.
///
/// Its sleep returns once `now` has reached the instant, never earlier unless its task is
/// cancelled. A timed sleep can wake slightly early on some platforms, so the sleep reads the clock
/// again after each wake and sleeps on for what is left. It sleeps with `Task.sleep(nanoseconds:)`,
/// never `Task.sleep(for:)`, which can crash in macOS release builds under load.
public struct SystemTurnClock: TurnClock {
    public init() {}

    public var now: TurnInstant { TurnInstant(ContinuousClock.now) }

    public func sleep(until instant: TurnInstant) async {
        while !Task.isCancelled {
            let remaining = (instant - now).turnNanoseconds
            if remaining <= 0 { return }
            do {
                try await turnsSafeSleep(nanoseconds: UInt64(remaining))
            } catch {
                // The protocol's sleep doesn't throw: a cancelled sleep returns at once.
                return
            }
        }
    }
}
