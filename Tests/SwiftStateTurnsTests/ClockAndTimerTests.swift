import SwiftStateTurns
import Testing

/// Timers, deadlines and the clock, on a test clock the checks drive by hand. A sleep until N
/// seconds waits at the gate "deadline N" and, when it returns, opens "woke deadline N" or
/// "cancelled deadline N".
@Suite("Turn core: clock and timers", .timeLimit(.minutes(1)))
struct ClockAndTimerTests {
    @Test("26: a timer fires once at its instant with that instant in its input; a new one replaces it; ending the key drops a fire on its way; one clock read per segment")
    func timerFiresReplacesAndDrops() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)

        // Fires once, at its instant, carrying it. The arming step reads `now` twice: one read.
        await a.send(.armIn(job: 1, after: .seconds(5)))
        let readsAfterArm = a.clock.reads
        a.clock.set(seconds: 5)
        f.open("deadline 5")
        await a.waitForLog(2)
        await f.wait("woke deadline 5")

        // A new timer for the key replaces the armed one, whose sleep is cancelled.
        await a.send(.arm(job: 2, at: .seconds(6)))
        await a.send(.arm(job: 2, at: .seconds(7)))
        await f.wait("cancelled deadline 6")
        f.open("deadline 6")
        f.open("deadline 7")
        await a.waitForLog(3)

        // Ending the key drops a fire that has already woken: the wake and the end happen in
        // one segment (the flush of `.emit(3)` opens the gate, then sends the end), so the
        // timer's task re-enters the actor only after the end.
        await a.send(.arm(job: 3, at: .seconds(8)))
        await a.onOutput(3, open: "deadline 8", thenSend: .endJob(3))
        await a.send(.emit(3))
        await f.wait("woke deadline 8")
        // The woken task's trip back into the actor is ordered before the next arm: the drop is
        // the second stale timer (the replaced timer 6 was the first).
        await f.wait("stale timer #2")

        // A later timer still fires.
        await a.send(.arm(job: 4, at: .seconds(9)))
        f.open("deadline 9")
        await a.waitForLog(4)
        let s = await a.snapshot()

        #expect(readsAfterArm == 1)
        #expect(s.log == ["arm 1 now 0 0", "tick 1 at 5", "tick 2 at 7", "tick 4 at 9"])
        // Only the arming step read the clock: a fire and a step that doesn't ask read nothing.
        #expect(a.clock.reads == 1)
        #expect(f.count(of: "clock read") == 1)
        #expect(f.count(of: "stale timer") == 2)
    }

    @Test("27: timer skip-ahead: a fire that overran two periods schedules the next one after now, not a backlog")
    func timerSkipsAhead() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.startPeriodic(job: 1, periodSeconds: 2))
        // The fire due at 2 runs at 7: the fires due at 4 and 6 were missed.
        a.clock.set(seconds: 7)
        f.open("deadline 2")
        await a.waitForLog(1)
        // Nothing sleeps until the missed instants: opening them fires nothing.
        f.open("deadline 4")
        f.open("deadline 6")
        a.clock.set(seconds: 8)
        f.open("deadline 8")
        await a.waitForLog(2)
        await a.send(.endJob(1))
        await f.wait("cancelled deadline 10")
        let s = await a.snapshot()
        #expect(s.log == ["periodic 1 at 2 next 8", "periodic 1 at 8 next 10"])
        #expect(!f.isOpen("woke deadline 4"))
        #expect(!f.isOpen("woke deadline 6"))
    }

    @Test("29: wake re-check: a deadline woken after its request completed abandons nothing; a replaced timer fires nothing; a cancelled sleep submits nothing")
    func wakeRecheck() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)

        // The completion's step emits 5; its flush opens the deadline's gate. The deadline's
        // task wakes, but re-enters the actor only after the request has closed.
        await a.send(.replyAfter(job: 5, gate: "c5", deadline: .seconds(5)))
        await a.onOutput(5, open: "deadline 5", thenSend: nil)
        f.open("c5")
        await f.wait("woke deadline 5")
        await f.wait("stale deadline #1")
        await a.waitForLog(1)

        // The step that replaces the timer also opens the old timer's gate.
        await a.send(.arm(job: 6, at: .seconds(6)))
        await a.onOutput(6, open: "deadline 6", thenSend: .arm(job: 6, at: .seconds(7)))
        await a.send(.emit(6))
        await f.wait("woke deadline 6")
        await f.wait("stale timer #1")
        f.open("deadline 7")
        await a.waitForLog(2)

        // A request cancelled before its deadline: the deadline's sleep is cancelled, and
        // opening its gate afterwards does nothing.
        await a.send(.replyAfter(job: 8, gate: "c8", deadline: .seconds(9)))
        await a.send(.cancelJob(8))
        await f.wait("cancelled deadline 9")
        await f.wait("stale deadline #2")
        f.open("deadline 9")
        f.open("c8")
        await a.waitForLog(4)
        let s = await a.snapshot()

        #expect(s.log == ["finished 5", "tick 6 at 7", "abandoned job 8 cancelled", "stale 8"])
        #expect(s.stats.openRequests == 0)
        // Each woken task re-checked in the core and did nothing: two deadlines, one timer.
        #expect(f.count(of: "stale deadline") == 2)
        #expect(f.count(of: "stale timer") == 1)
    }

    @Test("30: a Duration deadline and turn.now in one segment take one clock read")
    func oneClockReadPerSegment() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        a.clock.set(seconds: 2)
        // Reads `now` twice and makes a request with a 5 s deadline, in one step.
        await a.send(.nowAndDeadline(job: 1, deadline: .seconds(5)))
        let readsAfterFirst = a.clock.reads
        // The deadline came from that one read: 2 + 5.
        f.open("deadline 7")
        await a.waitForLog(2)
        // The next entry reads the clock again, once.
        a.clock.set(seconds: 3)
        await a.send(.nowAndDeadline(job: 2, deadline: .seconds(1)))
        let readsAfterSecond = a.clock.reads
        f.open("deadline 4")
        await a.waitForLog(4)
        let s = await a.snapshot()
        #expect(readsAfterFirst == 1)
        #expect(readsAfterSecond == 2)
        #expect(f.count(of: "clock read") == 2)
        #expect(s.log == ["now 2", "abandoned job 1 deadline", "now 3", "abandoned job 2 deadline"])
    }
}
