import SwiftStateTurns
import Testing

/// `TurnMachine.handleCallerCancelled`: the machine hears of a `.cancelsCall` caller cancelled
/// after its input stepped, once, as a step of its own, on both mailbox modes. Not for a call
/// still queued (withdrawn, never stepped) or already answered (stale). Each order is forced by
/// an event (a log line, a flush, a stale-cancellation diagnostic), never by timing.
@Suite("Turn core: the cancelled-caller hook", .timeLimit(.minutes(1)))
struct CallerCancelledHookTests {
    @Test("A stepped caller's cancellation steps the hook once; its output is flushed and its reply finds no waiter (no mailbox)")
    func steppedCallerNoMailbox() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.setup)
        let task = Task { try await a.sendAndWait(.holdCaller(1), cancellation: .cancelsCall) }
        await a.waitForLog(1)
        let before = await a.snapshot()
        task.cancel()
        let result = outcome(await boundedResult(task))
        let s = await a.snapshot()
        #expect(result == "cancelled")
        #expect(before.cancelledCallers.isEmpty)
        #expect(s.cancelledCallers.count == 1)
        // The hook's step isn't a handled input, and its output left through the segment.
        #expect(s.steps == before.steps)
        #expect(s.flushed.last == -1)
        #expect(s.stats.pendingWaiters == 0)
        #expect(s.stats.cancelledCalls == 1)
        // The machine forgot the caller: a later answer replies to no one.
        await a.send(.answerHeld)
        #expect(await a.snapshot().stats.pendingWaiters == 0)
    }

    @Test("A queued caller's cancellation withdraws its input and steps no hook")
    func queuedCallerNoHook() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.transaction(1, "p1"))
        let parked = Task { try await a.sendAndWait(.transaction(2, ""), cancellation: .cancelsCall) }
        await f.reach("park #1")
        parked.cancel()
        let result = outcome(await boundedResult(parked))
        f.open("p1")
        await a.waitForLog(2)
        let s = await a.snapshot()
        #expect(result == "cancelled")
        #expect(s.cancelledCallers.isEmpty)
        #expect(s.log == ["begin 1", "end 1"])
    }

    @Test("A cancellation after the reply was sent is stale: the caller gets the reply, and no hook steps")
    func answeredCallerStale() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        let task = Task { try await a.sendAndWait(.holdCaller(1), cancellation: .cancelsCall) }
        await a.waitForLog(1)
        // The reply is sent and its waiter resumed in this entry, before the cancellation.
        await a.send(.answerHeld)
        task.cancel()
        let result = outcome(await boundedResult(task))
        // The cancellation's entry ran and found no waiter.
        await f.reach("stale cancellation #1")
        let s = await a.snapshot()
        #expect(result == "success 0")
        #expect(s.cancelledCallers.isEmpty)
        #expect(s.stats.cancelledCalls == 0)
    }

    @Test("A stepped caller's cancellation steps the hook once under the mailbox's order; the hook's reply finds no waiter")
    func steppedCallerMailbox() async {
        let f = Fixture()
        let a = await MailboxActor.started(f)
        let task = Task { try await a.sendAndWait(.script([.holdCaller, .note("held")]), cancellation: .cancelsCall) }
        await f.reach("flushed held")
        task.cancel()
        let result = outcome(await boundedResult(task))
        #expect(result == "cancelled")
        #expect(await a.cancelledCallers.count == 1)
        #expect(await a.stats.pendingWaiters == 0)
        #expect(await a.stats.cancelledCalls == 1)
    }

    @Test("A mail that answers the call before the cancellation's entry makes it stale: no hook, the caller gets the mail's reply")
    func mailAnswersFirst() async {
        let f = Fixture()
        let a = await MailboxActor.started(f)
        let task = Task { try await a.sendAndWait(.script([.holdCaller, .note("held")]), cancellation: .cancelsCall) }
        await f.reach("flushed held")
        // The mail is posted before the cancellation: whichever runs first (its wake, or the
        // cancellation's entry, whose take steps it), the mail answers the call first.
        _ = a.post(MailNote("answer", then: [.answerHeld]))
        task.cancel()
        let result = outcome(await boundedResult(task))
        await f.reach("stale cancellation #1")
        #expect(result == "success 1")
        #expect(await a.cancelledCallers.isEmpty)
        #expect(await a.stats.cancelledCalls == 0)
    }
}
