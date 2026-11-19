import SwiftStateTurns
import Testing

/// Caller cancellation, one check per row of the policy table: `.ignoresCancel`, and `.cancelsCall`
/// before entry, while queued, after the step, and for a control input.
@Suite("Turn core: caller cancellation", .timeLimit(.minutes(1)))
struct CancellationTests {
    @Test("21: .ignoresCancel: a cancelled caller keeps waiting and gets the real result")
    func ignoredKeepsWaiting() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)

        // Cancelled after its input stepped.
        let stepped = Task {
            try await a.sendAndWait(.replyAfter(job: 1, gate: "i1", deadline: nil), cancellation: .ignoresCancel)
        }
        await f.wait("at i1")
        stepped.cancel()
        f.open("i1")
        let steppedResult = outcome(await stepped.result)

        // Cancelled before it was submitted.
        let early = Task { () async throws -> Int in
            await f.wait("go")
            return try await a.sendAndWait(.echo(5), cancellation: .ignoresCancel)
        }
        early.cancel()
        f.open("go")
        let earlyResult = outcome(await early.result)

        let s = await a.snapshot()
        #expect(steppedResult == "success 1")
        #expect(earlyResult == "success 5")
        #expect(s.stats.cancelledCalls == 0)
        #expect(s.stats.pendingWaiters == 0)
    }

    @Test("22: .cancelsCall, normal, cancelled before entry: not submitted; CancellationError")
    func cancelsCallBeforeEntry() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        let task = Task { () async throws -> Int in
            await f.wait("go")
            return try await a.sendAndWait(.note("submitted"), cancellation: .cancelsCall)
        }
        task.cancel()
        f.open("go")
        let result = outcome(await task.result)
        let s = await a.snapshot()
        #expect(result == "cancelled")
        #expect(s.log.isEmpty)
        #expect(s.steps == 0)
        #expect(s.stats.cancelledCalls == 1)
        #expect(s.stats.pendingWaiters == 0)
    }

    @Test("23: .cancelsCall, normal, still queued when the cancellation is handled: withdrawn, never steps")
    func cancelsCallWhileParked() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.transaction(1, "p1"))
        let parked = Task { try await a.sendAndWait(.transaction(2, ""), cancellation: .cancelsCall) }
        await f.wait("park #1")
        parked.cancel()
        let result = outcome(await parked.result)
        let mid = await a.snapshot()
        f.open("p1")
        await a.waitForLog(2)
        let s = await a.snapshot()
        #expect(result == "cancelled")
        #expect(mid.stats.queued == 0)
        #expect(s.log == ["begin 1", "end 1"])
        #expect(s.stats.queued == 0)
        #expect(s.stats.pendingWaiters == 0)
        #expect(s.stats.cancelledCalls == 1)
    }

    @Test("24: .cancelsCall, already stepped: the caller stops waiting; the work goes on and its reply finds no waiter")
    func cancelsCallAfterStep() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        let task = Task {
            try await a.sendAndWait(.replyAfter(job: 2, gate: "s2", deadline: nil), cancellation: .cancelsCall)
        }
        await f.wait("at s2")
        task.cancel()
        let result = outcome(await task.result)
        let mid = await a.snapshot()
        f.open("s2")
        await a.waitForLog(1)
        let s = await a.snapshot()
        #expect(result == "cancelled")
        #expect(mid.stats.openRequests == 1)
        #expect(mid.stats.pendingWaiters == 0)
        #expect(s.log == ["finished 2"])
        #expect(s.stats.openRequests == 0)
        #expect(s.stats.pendingWaiters == 0)
        #expect(s.stats.cancelledCalls == 1)
    }

    @Test("25: .cancelsCall, control: always submitted and stepped; only the caller stops waiting")
    func cancelsCallControl() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        let task = Task { () async throws -> Int in
            await f.wait("go")
            return try await a.sendAndWait(.holdCaller(1), cancellation: .cancelsCall)
        }
        task.cancel()
        f.open("go")
        let result = outcome(await task.result)
        let mid = await a.snapshot()
        // The machine still answers the caller it kept; the reply finds no waiter.
        await a.send(.answerHeld)
        let s = await a.snapshot()
        #expect(result == "cancelled")
        #expect(mid.log == ["control 1"])
        #expect(mid.stats.pendingWaiters == 0)
        #expect(mid.stats.cancelledCalls == 1)
        #expect(s.steps == 2)
        #expect(s.stats.pendingWaiters == 0)
    }

    @Test("25b: .cancelsCall, control, cancelled before entry, replying in its own step: stepped, and the caller still gets CancellationError")
    func cancelsCallControlRepliesAtOnce() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        let task = Task { () async throws -> Int in
            await f.wait("go")
            return try await a.sendAndWait(.answerNow(7), cancellation: .cancelsCall)
        }
        task.cancel()
        f.open("go")
        let result = outcome(await task.result)
        let s = await a.snapshot()
        // On an idle core the input steps at once and replies; the cancelled caller doesn't wait
        // for that reply, which finds no waiter.
        #expect(result == "cancelled")
        #expect(s.log == ["answered 7"])
        #expect(s.stats.cancelledCalls == 1)
        #expect(s.stats.pendingWaiters == 0)
    }
}
