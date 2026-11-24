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

    @Test("A sleep cancelled while it sleeps returns")
    func cancelWhileSleeping() async {
        let clock = SystemTurnClock()
        let instant = clock.now + .seconds(3600)
        let started = AsyncStream<Void>.makeStream()
        let sleeper = Task {
            started.continuation.yield()
            await clock.sleep(until: instant)
        }
        // The sleeper has begun; cancelling it now, or just before its sleep starts, must end it.
        for await _ in started.stream { break }
        sleeper.cancel()
        await sleeper.value
        #expect(clock.now < instant)
    }
}
