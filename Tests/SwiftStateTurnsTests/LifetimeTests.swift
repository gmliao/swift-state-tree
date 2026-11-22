import SwiftStateTurns
import Testing

/// The core's timer task doesn't keep a released actor alive; an effect's task does, until its
/// result has been handled.
@Suite("Turn core: the actor's lifetime", .timeLimit(.minutes(1)))
struct LifetimeTests {
    @Test("A periodic timer doesn't keep a released actor alive; the core's end cancels its sleep")
    func timerDoesNotRetain() async {
        let f = Fixture()
        weak var released: DemoActor?
        var clock: TestClock?
        do {
            let a = DemoActor(fixture: f)
            released = a
            clock = a.clock
            await a.send(.startPeriodic(job: 1, periodSeconds: 2))
            await a.send(.armIn(job: 2, after: .seconds(30)))
            await f.reach("sleeping deadline 2 #1")
        }
        #expect(released == nil)
        // One sleep for both timers. The core's deinit cancelled it; the woken task found no actor.
        await f.reach("cancelled deadline 2")
        #expect(!f.isOpen("cancelled deadline 30"))
        #expect(clock?.sleeps == 1)
        #expect(f.count(of: "stale timer") == 0)
    }

    @Test("An effect in flight keeps the actor until its result is handled, then lets it go")
    func effectRetainsOnlyWhilePerforming() async {
        let f = Fixture()
        weak var released: DemoActor?
        do {
            let a = DemoActor(fixture: f)
            released = a
            // A request with a deadline: the effect waits at its gate, the deadline at its own.
            await a.send(.replyAfter(job: 3, gate: "c3", deadline: .seconds(9)))
        }
        // The effect is in flight: its task holds the actor.
        #expect(released != nil)
        f.open("c3")
        // Once the result is handled, nothing holds the actor (a condition, not a delay: each
        // yield lets the effect's task run its next step).
        for _ in 0 ..< 10_000 where released != nil {
            await Task.yield() // wall-clock: not time: yields until the effect's task lets the actor go and the weak reference clears
        }
        #expect(released == nil)
        await f.reach("cancelled deadline 9")
    }
}
