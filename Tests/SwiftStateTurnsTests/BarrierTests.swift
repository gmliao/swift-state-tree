import SwiftStateTurns
import Testing

/// The barrier wait (#953): every way a wait ends hands its payload back once, the caller is
/// answered once, and nothing is left behind (no table entry, no live timer, no cancellation
/// flag). Interleavings are forced by gates, diagnostics and awaited replies, never by timing.
@Suite("Turn core: barrier waits (#953)", .timeLimit(.minutes(1)))
struct BarrierTests {
    /// Starts a `.wait` call and returns once it registered (its `n`th registration).
    private func waiting(
        _ a: BarrierActor, _ f: Fixture, _ key: String, payload: Int, timeout: Int64? = nil,
        _ cancellation: CallerCancellation = .cancelsCall, registration n: Int
    ) async -> Task<Int, any Error> {
        let task = Task { try await a.sendAndWait(.wait(key, payload: payload, timeoutSeconds: timeout), cancellation: cancellation) }
        await f.reach("barrier wait #\(n)")
        return task
    }

    @Test("A release answers its callers once, oldest first across the matching keys, and leaves the rest waiting")
    func releaseOrder() async {
        let f = Fixture()
        let a = BarrierActor(fixture: f)
        let first = await waiting(a, f, "a", payload: 1, registration: 1)
        let second = await waiting(a, f, "b", payload: 2, registration: 2)
        let third = await waiting(a, f, "a", payload: 3, registration: 3)
        let other = await waiting(a, f, "c", payload: 4, registration: 4)
        await a.send(.count("a"))
        await a.send(.releaseAll)
        // `releaseAll` took every key, c's too; the order is the calls' order, not the keys'.
        let results = [outcome(await boundedResult(first)), outcome(await boundedResult(second)),
                       outcome(await boundedResult(third)), outcome(await boundedResult(other))]
        let log = await a.log
        #expect(results == ["success 1", "success 2", "success 3", "success 4"])
        #expect(Array(log.suffix(5)) == [
            "count a=2",
            "released 1 from a cancelled=false", "released 2 from b cancelled=false",
            "released 3 from a cancelled=false", "released 4 from c cancelled=false",
        ])
        #expect(!log.contains { $0.hasPrefix("ended") })
        #expect(await a.table == [0, 0])
        #expect(await a.stats.barrierWaits == 4)
        #expect(await a.stats.pendingWaiters == 0)
    }

    @Test("A keyed release takes only its key")
    func keyedRelease() async {
        let f = Fixture()
        let a = BarrierActor(fixture: f)
        let onA = await waiting(a, f, "a", payload: 1, registration: 1)
        let onB = await waiting(a, f, "b", payload: 2, registration: 2)
        await a.send(.release("a"))
        #expect(outcome(await boundedResult(onA)) == "success 1")
        await a.send(.count("b"))
        await a.send(.release("b"))
        #expect(outcome(await boundedResult(onB)) == "success 2")
        #expect(await a.log.contains("count b=1"))
        #expect(await a.table == [0, 0])
    }

    @Test("A timeout steps the hook with the payload; the caller is answered timedOut once")
    func timeout() async {
        let f = Fixture()
        let a = BarrierActor(fixture: f)
        let task = await waiting(a, f, "a", payload: 7, timeout: 5, registration: 1)
        #expect(await a.liveDeadlines == 1)
        a.clock.release(through: 5)
        #expect(outcome(await boundedResult(task)) == "timedOut")
        await a.send(.release("a"))
        let log = await a.log
        #expect(log.filter { $0.hasPrefix("ended 7") } == ["ended 7 timedOut cancelled=false"])
        #expect(!log.contains { $0.hasPrefix("released") })
        #expect(await a.table == [0, 0])
        #expect(await a.liveDeadlines == 0)
    }

    @Test("An expired budget doesn't register: the payload comes back at the wait, and no timer is armed")
    func expiredBudget() async {
        let f = Fixture()
        let a = BarrierActor(fixture: f)
        let result = await boundedResult { try await a.sendAndWait(.wait("a", payload: 3, timeoutSeconds: 0), cancellation: .cancelsCall) }
        #expect(outcome(result) == "timedOut")
        #expect(await a.log == ["expired 3"])
        #expect(await a.stats.barrierWaits == 0)
        #expect(await a.liveDeadlines == 0)
        #expect(f.count(of: "barrier wait") == 0)
    }

    @Test("A budget past the clock's range saturates instead of wrapping: the wait stays until its release")
    func saturatingBudget() async {
        let f = Fixture()
        let a = BarrierActor(fixture: f)
        a.clock.release(through: 10)
        let task = await waiting(a, f, "a", payload: 5, timeout: .max, registration: 1)
        // The heap's head is the clamped instant, not a wrapped one in the past.
        #expect(await a.heap.target == TurnInstant(nanoseconds: .max))
        a.clock.release(through: 20)
        await a.send(.release("a"))
        #expect(outcome(await boundedResult(task)) == "success 5")
        #expect(!(await a.log).contains { $0.hasPrefix("ended") })
    }

    @Test("The withdraw: a waiting .cancelsCall caller's cancellation removes its entry and timer, steps the hook with the payload, then answers CancellationError")
    func withdraw() async {
        let f = Fixture()
        let a = BarrierActor(fixture: f)
        let task = await waiting(a, f, "a", payload: 9, timeout: 5, registration: 1)
        task.cancel()
        #expect(outcome(await boundedResult(task)) == "cancelled")
        #expect(await a.table == [0, 0])
        #expect(await a.liveDeadlines == 0)
        // The withdrawn wait's heap entry is stale: it fires nothing.
        a.clock.release(through: 5)
        await f.reach("stale timer #1")
        await a.send(.release("a"))
        let log = await a.log
        #expect(log == ["waiting 9 on a", "ended 9 withdrawn cancelled=true"])
        #expect(await a.stats.cancelledCalls == 1)
    }

    @Test("A caller with no waiter (a pre-cancelled control input) doesn't register: the payload comes back at the wait")
    func noWaiter() async {
        let f = Fixture()
        let a = BarrierActor(fixture: f)
        let task = Task { () async throws -> Int in
            await f.wait("go")
            return try await a.sendAndWait(.controlWait("a", payload: 4), cancellation: .cancelsCall)
        }
        task.cancel()
        f.open("go")
        #expect(outcome(await boundedResult(task)) == "cancelled")
        await a.send(.count("a"))
        #expect(await a.log == ["refused 4 noWaiter", "count a=0"])
        #expect(await a.table == [0, 0])
    }

    @Test(".ignoresCancel installs no handler: a cancelled caller keeps waiting, its release reads cancelled=false, and it gets the real result")
    func ignoresCancel() async {
        let f = Fixture()
        let a = BarrierActor(fixture: f)
        let task = await waiting(a, f, "a", payload: 2, .ignoresCancel, registration: 1)
        task.cancel()
        await a.send(.release("a"))
        #expect(outcome(await boundedResult(task)) == "success 2")
        #expect(await a.log.contains("released 2 from a cancelled=false"))
        #expect(await a.table == [0, 0])
        #expect(f.count(of: "stale cancellation") == 0)
    }

    @Test("A cancel that lands before the release steps sets the flag the release reads; a re-wait in the same step is refused, and the hop then removes the flag")
    func flagSticksAcrossReleaseAndRewait() async {
        let f = Fixture()
        let a = BarrierActor(fixture: f)
        let task = await waiting(a, f, "a", payload: 6, registration: 1)
        await a.send(.rewaitOnRelease(6, timeoutSeconds: nil))
        await a.cancel(onNextFlush: task)
        // The flush between the emit's step and the queued release cancels the caller: its
        // `onCancel` sets the flag synchronously, and its hop waits behind this segment.
        await a.send(.emitThenRelease("a"))
        #expect(outcome(await boundedResult(task)) == "cancelled")
        await f.reach("stale cancellation #1")
        let log = await a.log
        #expect(Array(log.suffix(2)) == ["released 6 from a cancelled=true", "refused 6 cancelled"])
        #expect(await a.table == [0, 0])
    }

    @Test("A cancel whose hop comes after the reply leaves no flag: the hop is stale and removes it")
    func cancelAfterReplyLeavesNoFlag() async {
        let f = Fixture()
        let a = BarrierActor(fixture: f)
        let task = await waiting(a, f, "a", payload: 8, registration: 1)
        await a.cancel(onNextFlush: task)
        // The release step read the flag unset; its flush cancels the caller before its reply is
        // published, in the same drain, so the reply wins and the hop arrives with the call answered.
        await a.send(.releaseAndEmit("a"))
        let result = outcome(await boundedResult(task))
        await f.reach("stale cancellation #1")
        #expect(result == "success 8")
        #expect(await a.table == [0, 0])
    }

    @Test("A published reply claims a waiting caller: its entry leaves, its payload comes back as .answered, and the caller has the reply")
    func replyClaimsCaller() async {
        let f = Fixture()
        let a = BarrierActor(fixture: f)
        let task = await waiting(a, f, "a", payload: 3, timeout: 5, registration: 1)
        await a.send(.replyTo(payload: 3, value: 30))
        #expect(outcome(await boundedResult(task)) == "success 30")
        #expect(await a.log.contains("ended 3 answered cancelled=false"))
        #expect(await a.table == [0, 0])
        #expect(await a.liveDeadlines == 0)
    }

    @Test("A reply(after:) claims the caller when its request completes, not when it is staged")
    func replyAfterClaimsCaller() async {
        let f = Fixture()
        let a = BarrierActor(fixture: f)
        let task = await waiting(a, f, "a", payload: 4, registration: 1)
        await a.send(.replyAfterWork(payload: 4, gate: "g"))
        await f.reach("at g")
        await a.send(.count("a"))
        f.open("g")
        #expect(outcome(await boundedResult(task)) == "success 40")
        let log = await a.log
        #expect(Array(log.suffix(3)) == ["count a=1", "finished", "ended 4 answered cancelled=false"])
        #expect(await a.table == [0, 0])
    }

    @Test("A wait whose reply is staged in the same step ends before its timer is armed")
    func replyInTheWaitingStep() async {
        let f = Fixture()
        let a = BarrierActor(fixture: f)
        let result = await boundedResult { try await a.sendAndWait(.waitThenReply("a", payload: 2, timeoutSeconds: 5), cancellation: .cancelsCall) }
        #expect(outcome(result) == "success 2")
        #expect(await a.log == ["waiting 2 on a", "ended 2 answered cancelled=false"])
        // Never pushed: no heap entry and no timer start, not just no live one.
        let heap = await a.heap
        #expect(heap.entries == 0)
        #expect(heap.sleeperStarts == 0)
        #expect(await a.table == [0, 0])
    }

    @Test("endAll ends every wait, oldest first, through the hook, each answered closed; its timers go with the deadlines")
    func endAllEndsWaits() async {
        let f = Fixture()
        let a = BarrierActor(fixture: f)
        let first = await waiting(a, f, "a", payload: 1, timeout: 5, registration: 1)
        let second = await waiting(a, f, "b", payload: 2, registration: 2)
        await a.send(.teardown)
        #expect(outcome(await boundedResult(first)) == "closed")
        #expect(outcome(await boundedResult(second)) == "closed")
        // After the end a wait doesn't register: its payload comes back at the wait.
        let late = await boundedResult { try await a.sendAndWait(.controlWait("a", payload: 3), cancellation: .cancelsCall) }
        #expect(outcome(late) == "closed")
        let log = await a.log
        #expect(Array(log.suffix(3)) == ["ended 1 ended cancelled=false", "ended 2 ended cancelled=false", "refused 3 ended"])
        #expect(await a.liveDeadlines == 0)
        #expect(await a.table == [0, 0])
    }

    @Test("endAll with a reply(after:) staged for a waiter: the reply claims it (.answered) and is its answer; the others end .ended")
    func endAllWithStagedReply() async {
        let f = Fixture()
        let a = BarrierActor(fixture: f)
        let staged = await waiting(a, f, "a", payload: 1, registration: 1)
        let other = await waiting(a, f, "b", payload: 2, registration: 2)
        await a.send(.replyAfterWorkThenTeardown(payload: 1, gate: "g"))
        #expect(outcome(await boundedResult(staged)) == "success 10")
        #expect(outcome(await boundedResult(other)) == "closed")
        let log = await a.log
        #expect(Array(log.suffix(2)) == ["ended 1 answered cancelled=false", "ended 2 ended cancelled=false"])
        #expect(await a.table == [0, 0])
        f.open("g")
    }

    @Test("The deadline is clamped as an instant, not the budget first")
    func saturatingDeadlineArithmetic() {
        let past = Duration.nanoseconds(Int64.max) + .nanoseconds(5)
        #expect(TurnCore<BarrierMachine>.saturatingDeadline(-10, past) == Int64.max - 5)
        #expect(TurnCore<BarrierMachine>.saturatingDeadline(10, past) == Int64.max)
        #expect(TurnCore<BarrierMachine>.saturatingDeadline(10, .nanoseconds(Int64.max)) == Int64.max)
        #expect(TurnCore<BarrierMachine>.saturatingDeadline(10, .seconds(1)) == 1_000_000_010)
    }

    @Test("A step that releases before its endAll answers those callers itself; endAll ends the rest")
    func releaseThenEndAll() async {
        let f = Fixture()
        let a = BarrierActor(fixture: f)
        let shutdown = await waiting(a, f, "shutdown", payload: 1, registration: 1)
        let other = await waiting(a, f, "a", payload: 2, registration: 2)
        await a.send(.releaseThenTeardown("shutdown"))
        #expect(outcome(await boundedResult(shutdown)) == "success 1")
        #expect(outcome(await boundedResult(other)) == "closed")
        #expect(await a.table == [0, 0])
    }

    @Test("close leaves waits alone: a waiting caller is still released, and a budget still times out")
    func closeLeavesWaits() async {
        let f = Fixture()
        let a = BarrierActor(fixture: f)
        let released = await waiting(a, f, "a", payload: 1, registration: 1)
        let timed = await waiting(a, f, "b", payload: 2, timeout: 5, registration: 2)
        await a.send(.close)
        await a.send(.count("a"))
        await a.send(.release("a"))
        #expect(outcome(await boundedResult(released)) == "success 1")
        a.clock.release(through: 5)
        #expect(outcome(await boundedResult(timed)) == "timedOut")
        let log = await a.log
        #expect(log.contains("count a=1"))
        #expect(log.contains("ended 2 timedOut cancelled=false"))
    }

    @Test("A release that steps before the cancel's hop wins: the hop, forced to come after the reply, is stale")
    func releaseBeforeCancel() async {
        let f = Fixture()
        let a = BarrierActor(fixture: f)
        let task = await waiting(a, f, "a", payload: 5, registration: 1)
        // The release's own flush cancels the caller: its hop is queued behind the release's
        // segment, which publishes the reply first.
        await a.cancel(onNextFlush: task)
        await a.send(.releaseAndEmit("a"))
        let result = outcome(await boundedResult(task))
        await f.reach("stale cancellation #1")
        #expect(result == "success 5")
        #expect(!(await a.log).contains { $0.hasPrefix("ended") })
        #expect(await a.table == [0, 0])
    }

    @Test("A cancel whose hop steps before the release wins: the release finds nothing")
    func cancelBeforeRelease() async {
        let f = Fixture()
        let a = BarrierActor(fixture: f)
        let task = await waiting(a, f, "a", payload: 5, registration: 1)
        task.cancel()
        #expect(outcome(await boundedResult(task)) == "cancelled")
        await a.send(.release("a"))
        let log = await a.log
        #expect(log == ["waiting 5 on a", "ended 5 withdrawn cancelled=true"])
        #expect(await a.table == [0, 0])
    }

    @Test("A timeout that steps before the cancel wins; a cancel that steps first makes the timeout stale")
    func timeoutAgainstCancel() async {
        // The timeout first: its hook's flush cancels the caller before the timeout's answer is
        // published, so the hop comes after the answer and is stale.
        do {
            let f = Fixture()
            let a = BarrierActor(fixture: f)
            let task = await waiting(a, f, "a", payload: 1, timeout: 5, registration: 1)
            await a.send(.emitOnEnd)
            await a.cancel(onNextFlush: task)
            a.clock.release(through: 5)
            #expect(outcome(await boundedResult(task)) == "timedOut")
            await f.reach("stale cancellation #1")
            #expect(await a.log == ["waiting 1 on a", "ended 1 timedOut cancelled=false"])
            #expect(await a.table == [0, 0])
        }
        // The cancel first: the timeout's entry is stale when it comes due.
        do {
            let f = Fixture()
            let a = BarrierActor(fixture: f)
            let task = await waiting(a, f, "a", payload: 1, timeout: 5, registration: 1)
            task.cancel()
            #expect(outcome(await boundedResult(task)) == "cancelled")
            a.clock.release(through: 5)
            await f.reach("stale timer #1")
            #expect(await a.log == ["waiting 1 on a", "ended 1 withdrawn cancelled=true"])
            #expect(await a.table == [0, 0])
        }
    }

    @Test("A re-wait gets a fresh timer generation: the first wait's due entry is stale, and only the second budget fires")
    func rewaitFreshGeneration() async {
        let f = Fixture()
        let a = BarrierActor(fixture: f)
        let task = await waiting(a, f, "a", payload: 1, timeout: 5, registration: 1)
        await a.send(.rewaitOnRelease(1, timeoutSeconds: 5))
        a.clock.release(through: 1)
        await a.send(.release("a"))
        await f.reach("barrier wait #2")
        a.clock.release(through: 5)
        await f.reach("stale timer #1")
        await a.send(.count("a"))
        a.clock.release(through: 6)
        #expect(outcome(await boundedResult(task)) == "timedOut")
        let log = await a.log
        #expect(log == [
            "waiting 1 on a", "released 1 from a cancelled=false", "waiting 1 on a",
            "count a=1", "ended 1 timedOut cancelled=false",
        ])
    }

    @Test("A due timeout whose waiter an earlier entry of the same wake released fails its liveness check: no second hook")
    func dueEntryReleasedInTheSameWake() async {
        let f = Fixture()
        let a = BarrierActor(fixture: f)
        let first = await waiting(a, f, "a", payload: 1, timeout: 5, registration: 1)
        let second = await waiting(a, f, "b", payload: 2, timeout: 5, registration: 2)
        await a.send(.releaseAllOnTimeout(1))
        a.clock.release(through: 5)
        #expect(outcome(await boundedResult(first)) == "timedOut")
        #expect(outcome(await boundedResult(second)) == "success 2")
        await f.reach("stale timer #1")
        let log = await a.log
        #expect(Array(log.suffix(2)) == ["ended 1 timedOut cancelled=false", "released 2 from b cancelled=false"])
        #expect(log.filter { $0.hasPrefix("ended 2") }.isEmpty)
        #expect(await a.table == [0, 0])
    }
}
