import Foundation
import SwiftStateTurns
import Testing

/// `SystemTurnClock`, the production clock. The checks are about its contract, not about how long
/// a sleep takes: a sleep that returned has reached its instant, and a cancelled sleep returns.
@Suite("Turn core: the production clock (#759)", .timeLimit(.minutes(1)))
struct SystemTurnClockTests {
    @Test("`now` never decreases across consecutive reads")
    func nowIsMonotonic() {
        let clock = SystemTurnClock()
        var previous = clock.now
        for _ in 0..<1000 {
            let current = clock.now
            #expect(current >= previous)
            previous = current
        }
    }

    @Test("A sleep until an instant that has passed, or until now, returns")
    func pastInstantReturns() async {
        let clock = SystemTurnClock()
        let past = clock.now + .seconds(-1)
        await clock.sleep(until: past)
        #expect(clock.now >= past)

        let present = clock.now
        await clock.sleep(until: present)
        #expect(clock.now >= present)
    }

    @Test("When a sleep returns, now has reached its instant: 50 sleeps of 1 ms")
    func sleepReachesItsInstant() async {
        let clock = SystemTurnClock()
        for _ in 0..<50 {
            let instant = clock.now + .milliseconds(1)
            await clock.sleep(until: instant)
            #expect(clock.now >= instant)
        }
    }

    @Test("A cancelled sleep far from its instant returns")
    func cancelledSleepReturns() async {
        let clock = SystemTurnClock()
        let instant = clock.now + .seconds(3600)
        let sleeper = Task { await clock.sleep(until: instant) }
        sleeper.cancel()
        await sleeper.value
        // Returned early, because it was cancelled: the instant is still an hour away.
        #expect(clock.now < instant)
    }

    @Test("A sleep cancelled after it was entered returns; the sleeper has signalled right before the call")
    func cancelAroundTheSleep() async {
        let clock = SystemTurnClock()
        let instant = clock.now + .seconds(3600)
        let started = AsyncStream<Void>.makeStream()
        let sleeper = Task {
            started.continuation.yield()
            await clock.sleep(until: instant)
        }
        for await _ in started.stream { break }
        // The signal comes right before `sleep` is entered, and nothing in the clock lets a test
        // see that it is inside the sleep, so a few yields make it likely that the cancellation
        // lands during the sleep, not before it. Either way the sleeper must return; the path
        // where the sleep is already running relies on `Task.sleep(nanoseconds:)` throwing
        // `CancellationError`, which `sleep(until:)` turns into a return.
        for _ in 0..<16 { await Task.yield() } // wall-clock: not time: the clock has no hook to see its sleep begin; yields let the sleeper reach it, and the test passes whichever side of it the cancel lands on
        sleeper.cancel()
        await sleeper.value
        #expect(clock.now < instant)
    }

    // The clock compares by order first, as the core does: an instant at either end of the range
    // works (`TurnInstant`'s arithmetic saturates there, #791).

    @Test("A sleep until the earliest possible instant returns")
    func minimumInstantReturns() async {
        let clock = SystemTurnClock()
        let instant = TurnInstant(nanoseconds: .min)
        await clock.sleep(until: instant)
        #expect(clock.now >= instant)
    }

    @Test("A deadline past the range saturates at the latest instant instead of wrapping into the past (#791)")
    func farDeadlineSaturates() {
        let clock = SystemTurnClock()
        // Make sure the process origin exists, so that `now` is not negative: before #791,
        // `now + .seconds(.max)` wrapped below `now`. Sleeping until `.max` is
        // `farFutureStaysAsleep`'s case.
        _ = TurnInstant.processOrigin
        let now = clock.now
        #expect(now + .seconds(Int64.max) == TurnInstant(nanoseconds: .max))
        #expect(now + .seconds(Int64.max) > now)
    }

    @Test("A sleep until a far future instant stays asleep until it is cancelled, and then returns")
    func farFutureStaysAsleep() async {
        let clock = SystemTurnClock()
        let instant = TurnInstant(nanoseconds: .max)
        let returned = Flag()
        let started = AsyncStream<Void>.makeStream()
        let sleeper = Task {
            started.continuation.yield()
            await clock.sleep(until: instant)
            returned.set()
        }
        for await _ in started.stream { break }
        for _ in 0..<16 { await Task.yield() } // wall-clock: not time: yields let the sleeper enter its sleep; a premature return is then caught by the flag, and a sleeper that hasn't run yet can't fail the test
        // Not cancelled yet: a return now would be an early one.
        #expect(!returned.isSet)
        #expect(clock.now < instant)
        sleeper.cancel()
        await sleeper.value
        #expect(returned.isSet)
    }
}

/// A flag one task sets and another reads.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}
