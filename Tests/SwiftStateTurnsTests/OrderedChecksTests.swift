import SwiftStateTurns
import Testing

/// The core's rules one at a time, on `DemoMachine`. Every interleaving is ordered by a gate,
/// a core diagnostic or an awaited reply.
@Suite("Turn core: ordered checks", .timeLimit(.minutes(1)))
struct OrderedChecksTests {
    @Test("1: a completion after its key ended goes to handleLateResult")
    func completionAfterKeyEndedIsStale() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.start(job: 1, gate: "j1"))
        await a.send(.endJob(1))
        await a.send(.start(job: 2, gate: "j2"))
        f.open("j1")
        f.open("j2")
        await a.waitForLog(3)
        let s = await a.snapshot()
        #expect(s.log.sorted() == ["abandoned job 1 keyEnded", "finished 2", "stale 1"])
        #expect(s.stats.openRequests == 0)
    }

    @Test("2: an aborted owner's late completion doesn't release the next owner's hold")
    func lateCompletionKeepsNextOwnersHold() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.transaction(1, "t1"))
        await a.send(.transaction(2, "t2"))
        await a.send(.transaction(3, "t3"))
        await a.send(.abort(1))
        f.open("t1")
        await a.waitForLog(5)
        let mid = await a.snapshot()
        let wantMid = ["begin 1", "abort 1", "abandoned 1 keyEnded", "begin 2", "stale 1"]
        f.open("t2")
        f.open("t3")
        await a.waitForLog(8)
        let s = await a.snapshot()
        #expect(mid.log == wantMid)
        #expect(mid.stats.queued == 1)
        #expect(mid.stats.heldKeys == 1)
        #expect(s.log == wantMid + ["end 2", "begin 3", "end 3"])
        #expect(s.stats.heldKeys == 0)
    }

    @Test("3: a deadline abandons the request and releases its hold; the late result is stale")
    func deadlineAbandonsAndReleases() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.transaction(1, "d1", deadline: .seconds(5)))
        await a.send(.transaction(2, "d2"))
        a.clock.release(through: 5)
        await a.waitForLog(3)
        f.open("d1")
        await a.waitForLog(4)
        f.open("d2")
        await a.waitForLog(5)
        let s = await a.snapshot()
        #expect(s.log == ["begin 1", "abandoned 1 deadline", "begin 2", "stale 1", "end 2"])
        #expect(s.stats.heldKeys == 0)
    }

    @Test("4: an untilWorkerReturns hold outlives the deadline and is released by the stale result")
    func retiringHoldOutlivesDeadline() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.transaction(1, "w1", deadline: .seconds(7), untilRetire: true))
        await a.send(.transaction(2, ""))
        a.clock.release(through: 7)
        await a.waitForLog(2)
        let mid = await a.snapshot()
        f.open("w1")
        await a.waitForLog(5)
        let s = await a.snapshot()
        #expect(mid.log == ["begin 1", "abandoned 1 deadline"])
        #expect(mid.stats.queued == 1)
        #expect(mid.stats.heldKeys == 1)
        #expect(mid.stats.openRequests == 0)
        #expect(s.log == ["begin 1", "abandoned 1 deadline", "stale 1", "begin 2", "end 2"])
        #expect(s.stats.heldKeys == 0)
    }

    @Test("5: close answers a queued call and refuses a later one; a stepped call still gets its answer")
    func closeAnswersParkedRefusesLater() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        let stepped = Task { try await a.sendAndWait(.transaction(4, "c4"), cancellation: .ignoresCancel) }
        await f.reach("at c4")
        let parked = Task { try await a.sendAndWait(.transaction(5, ""), cancellation: .ignoresCancel) }
        await f.reach("park #1")
        await a.send(.shutdown)
        let parkedResult = outcome(await boundedResult(parked))
        let late = outcome(await boundedResult(Task { try await a.sendAndWait(.echo(1), cancellation: .ignoresCancel) }))
        f.open("c4")
        let steppedResult = outcome(await boundedResult(stepped))
        let s = await a.snapshot()
        #expect(parkedResult == "closed")
        #expect(late == "closed")
        #expect(steppedResult == "success 4")
        #expect(s.log == ["begin 4", "shutdown", "end 4"])
        #expect(s.stats.pendingWaiters == 0)
        #expect(s.stats.queued == 0)
    }

    @Test("6: emit under an ended key is dropped and counted")
    func emitUnderEndedKeyIsDropped() async {
        let a = DemoActor()
        await a.send(.start(job: 7, gate: "never"))
        await a.send(.emit(7))
        await a.send(.endJob(7))
        await a.send(.emit(7))
        let s = await a.snapshot()
        #expect(s.flushed == [7])
        #expect(s.stats.droppedOutputs == 1)
    }

    @Test("7: a send from inside a step is queued and steps after it")
    func sendFromInsideStepIsQueued() async {
        let a = DemoActor()
        await a.sendFromInsideStep()
        let s = await a.snapshot()
        #expect(s.log == ["hook start", "hook end", "queued"])
        #expect(s.steps == 2)
    }

    @Test("8: a collaborator called between steps may read, query and send")
    func collaboratorBetweenSteps() async {
        let a = DemoActor()
        let saw = await a.collaboratorBetweenSteps()
        let s = await a.snapshot()
        // It read two steps and was answered the first query; its send stepped after them.
        #expect(saw == [2, 1])
        #expect(s.steps == 3)
        #expect(s.asks == 1)
        #expect(s.flushed == [900])
    }

    @Test("9: call and reply round-trip; reply(after:) waits for the completion step, and for the abandonment")
    func callReplyAndReplyAfter() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        let value = try? await boundedResult(Task { try await a.sendAndWait(.echo(42), cancellation: .ignoresCancel) }).get()
        #expect(value == 42)

        // Published after the request's completion step.
        let afterCompletion = Task {
            try await a.sendAndWait(.replyAfter(job: 9, gate: "r9", deadline: nil), cancellation: .ignoresCancel)
        }
        await f.reach("at r9")
        let waiting = await a.snapshot()
        f.open("r9")
        let completed = outcome(await boundedResult(afterCompletion))
        let afterStep = await a.snapshot()

        // Published when the request is abandoned (here by its deadline).
        let afterAbandon = Task {
            try await a.sendAndWait(.replyAfter(job: 10, gate: "never", deadline: .seconds(5)), cancellation: .ignoresCancel)
        }
        await f.reach("at never")
        let waitingAgain = await a.snapshot()
        a.clock.release(through: 5)
        let abandoned = outcome(await boundedResult(afterAbandon))
        let s = await a.snapshot()

        #expect(waiting.stats.pendingWaiters == 1)
        #expect(completed == "success 9")
        #expect(afterStep.log == ["finished 9"])
        #expect(waitingAgain.stats.pendingWaiters == 1)
        #expect(abandoned == "success 10")
        #expect(s.log == ["finished 9", "abandoned job 10 deadline"])
        #expect(s.stats.pendingWaiters == 0)
    }

    @Test("10: cancel(request) abandons with .cancelled; the late result is stale")
    func cancelRequestAbandons() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.start(job: 3, gate: "c3"))
        await f.reach("at c3")
        await a.send(.cancelJob(3))
        let mid = await a.snapshot()
        f.open("c3")
        await a.waitForLog(2)
        let s = await a.snapshot()
        #expect(mid.log == ["abandoned job 3 cancelled"])
        #expect(mid.stats.openRequests == 0)
        #expect(s.log == ["abandoned job 3 cancelled", "stale 3"])
    }

    @Test("11: a queued input is withdrawn when its scope ends; ending another key leaves it")
    func scopeEndWithdrawsParked() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.transaction(1, "s1"))
        let scoped = Task { try await a.sendAndWait(.scoped(1, scope: 5), cancellation: .ignoresCancel) }
        await f.reach("park #1")
        await a.send(.endJob(6))
        let afterOther = await a.snapshot()
        await a.send(.endJob(5))
        let result = outcome(await boundedResult(scoped))
        f.open("s1")
        await a.waitForLog(2)
        let s = await a.snapshot()
        #expect(afterOther.stats.queued == 1)
        #expect(result == "withdrawn")
        #expect(s.log == ["begin 1", "end 1"])
        #expect(s.stats.queued == 0)
    }

    @Test("12: the queue limit refuses a call with queueFull; a send over it is dropped and counted")
    func queueLimitRefuses() async {
        let f = Fixture()
        let a = DemoActor(fixture: f, queueLimit: 2)
        await a.send(.transaction(1, "l1"))
        let second = Task { try await a.sendAndWait(.transaction(2, ""), cancellation: .ignoresCancel) }
        let third = Task { try await a.sendAndWait(.transaction(3, ""), cancellation: .ignoresCancel) }
        await f.reach("park #2")
        let fourth = outcome(await boundedResult(Task { try await a.sendAndWait(.transaction(4, ""), cancellation: .ignoresCancel) }))
        await a.send(.transaction(5, ""))
        let full = await a.snapshot()
        f.open("l1")
        let results = [outcome(await boundedResult(second)), outcome(await boundedResult(third))].sorted()
        let s = await a.snapshot()
        #expect(fourth == "queueFull")
        #expect(full.stats.droppedSends == 1)
        #expect(full.stats.queued == 2)
        #expect(results == ["success 2", "success 3"])
        #expect(!s.log.contains("begin 4"))
        #expect(!s.log.contains("begin 5"))
    }

    @Test("13: 40 released inputs step in order, at most maxReleasesPerBatch per batch; a late arrival steps after them")
    func releasedInputsDrainInBudgetedSegments() async {
        let f = Fixture()
        let a = DemoActor(fixture: f, maxReleasesPerBatch: 8)
        await a.drainWithLateArrival(count: 40)
        await a.waitForLog(44)
        await a.clearHooks()
        let s = await a.snapshot()
        let segments = f.segments
        #expect(Array(s.log.prefix(3)) == ["begin 1", "abort 1", "abandoned 1 keyEnded"])
        #expect(Array(s.log.dropFirst(3)) == (0..<40).map { "step \($0)" } + ["step 999"])
        #expect(s.flushed == Array(0..<40) + [999])
        #expect(s.stats.continuationJobs >= 4)
        #expect(segments.allSatisfy { $0 <= 8 })
        #expect(segments.reduce(0, +) == 41)
    }

    @Test("14: a replaced core doesn't take the old core's completion")
    func replacedCoreDropsForeignCompletion() async {
        let f = Fixture()
        let a = ReplaceableCoreActor(fixture: f)
        await a.send(.start(job: 1, gate: "v1"))
        await a.replaceCore()
        f.open("v1")
        await f.reach("foreign")
        let state = await a.state()
        #expect(state.log.isEmpty)
        #expect(state.steps == 0)
        #expect(state.foreign == 1)
    }

    @Test("15: a token marked before arrival withdraws; marked while queued withdraws on release; revoke withdraws in its step")
    func endTokens() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)

        // Marked before the input arrives: withdrawn before any step.
        let early = WithdrawToken()
        early.withdraw()
        let first = outcome(await boundedResult(Task { try await a.sendAndWait(.guarded(1, token: early), cancellation: .ignoresCancel) }))

        // Marked upstream while queued: it keeps its place, and is withdrawn when released.
        await a.send(.transaction(1, "g1"))
        let late = WithdrawToken()
        let second = Task { try await a.sendAndWait(.guarded(2, token: late), cancellation: .ignoresCancel) }
        await f.reach("park #1")
        late.withdraw()
        let stillParked = await a.snapshot().stats.queued
        f.open("g1")
        let secondResult = outcome(await boundedResult(second))

        // Revoked by a step: withdrawn in that step.
        await a.send(.transaction(3, "g3"))
        let revoked = WithdrawToken()
        let third = Task { try await a.sendAndWait(.guarded(3, token: revoked), cancellation: .ignoresCancel) }
        await f.reach("park #2")
        await a.send(.revoke(revoked))
        let afterRevoke = await a.snapshot()
        let thirdResult = outcome(await boundedResult(third))
        f.open("g3")
        await a.waitForLog(5)
        let s = await a.snapshot()

        #expect(first == "withdrawn")
        #expect(stillParked == 1)
        #expect(secondResult == "withdrawn")
        #expect(afterRevoke.stats.queued == 0)
        #expect(revoked.isWithdrawn)
        #expect(thirdResult == "withdrawn")
        #expect(s.log == ["begin 1", "end 1", "begin 3", "revoke", "end 3"])
    }

    @Test("16: queue steps after the inputs already queued, survives close, the queue limit and a key's end; only endAll drops it")
    func queueKeepsItsPlace() async throws {
        let f = Fixture()
        let a = DemoActor(fixture: f, queueLimit: 2)
        await a.send(.transaction(1, "q1"))
        let parked = Task { try await a.sendAndWait(.transaction(2, ""), cancellation: .ignoresCancel) }
        await f.reach("park #1")
        await a.send(.enqueue("a"))
        // The queued input counts as queued, so the limit is reached...
        let overLimit = outcome(await boundedResult(Task { try await a.sendAndWait(.transaction(3, ""), cancellation: .ignoresCancel) }))
        // ...and doesn't apply to `queue` itself.
        await a.send(.enqueue("b"))
        await a.send(.endKey(.membership))
        let beforeClose = await a.snapshot()
        await a.send(.shutdown)
        let parkedResult = outcome(await boundedResult(parked))
        let afterClose = await a.snapshot()
        f.open("q1")
        await a.waitForLog(8)
        let s = await a.snapshot()
        #expect(overLimit == "queueFull")
        #expect(beforeClose.stats.queued == 3)
        #expect(parkedResult == "closed")
        #expect(afterClose.stats.queued == 2)
        #expect(s.log == [
            "begin 1", "enqueue a true", "enqueue b true", "end key membership", "shutdown",
            "end 1", "queued a", "queued b",
        ])
        #expect(s.stats.queued == 0)

        // endAll drops what is queued, and a later queue does nothing.
        let g = Fixture()
        let b = DemoActor(fixture: g)
        await b.send(.transaction(1, "x1"))
        await b.send(.enqueue("c"))
        await b.send(.teardown)
        let afterEnd = await b.snapshot()
        await b.send(.enqueue("d"))
        g.open("x1")
        await b.waitForLog(6)
        let t = await b.snapshot()
        #expect(afterEnd.stats.queued == 0)
        #expect(t.log == ["begin 1", "enqueue c true", "teardown", "abandoned 1 keyEnded", "enqueue d false", "stale 1"])
        #expect(t.stats.ignoredAfterEnd == 1)

        // The queued input steps after the inputs already queued behind the key, which survive
        // here and step first, in their order.
        let h = Fixture()
        let c = DemoActor(fixture: h)
        await c.send(.transaction(1, "y1"))
        // A failed reach below ends the test early; the held transaction's gate still opens.
        defer { h.open("y1") }
        await c.send(.step(5))
        try #require(await h.reach("park #1"))
        await c.send(.step(6))
        try #require(await h.reach("park #2"))
        await c.send(.enqueue("e"))
        await c.send(.step(7))
        h.open("y1")
        await c.waitForLog(7)
        let u = await c.snapshot()
        // `step 7` arrived after the queue and queues after it.
        #expect(u.log == ["begin 1", "enqueue e true", "end 1", "step 5", "step 6", "queued e", "step 7"])
        #expect(u.stats.queued == 0)
    }

    @Test("17: endAll abandons, ends, withdraws, drops and closes; then start and queue are ignored, run and query still step")
    func endAllIsTerminal() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.setup)
        await a.send(.start(job: 1, gate: "x1"))
        await a.send(.transaction(2, "x2"))
        let scoped = Task { try await a.sendAndWait(.scoped(3, scope: 7), cancellation: .ignoresCancel) }
        await f.reach("park #1")
        let unscoped = Task { try await a.sendAndWait(.transaction(4, ""), cancellation: .ignoresCancel) }
        await f.reach("park #2")
        await a.send(.enqueue("x"))
        await a.send(.teardown)
        let scopedResult = outcome(await boundedResult(scoped))
        let unscopedResult = outcome(await boundedResult(unscoped))
        let afterEnd = await a.snapshot()
        await a.send(.issueKey(9))
        await a.send(.enqueue("y"))
        await a.send(.runMark("after end"))
        let asked = await a.query(.bump)
        let late = outcome(await boundedResult(Task { try await a.sendAndWait(.echo(1), cancellation: .ignoresCancel) }))
        await a.waitForLog(8)
        let s = await a.snapshot()
        #expect(scopedResult == "withdrawn")
        #expect(unscopedResult == "closed")
        #expect(afterEnd.stats.liveKeys == 0)
        #expect(afterEnd.stats.openRequests == 0)
        #expect(afterEnd.stats.queued == 0)
        #expect(afterEnd.stats.pendingWaiters == 0)
        #expect(asked == 1)
        #expect(late == "closed")
        #expect(s.log == [
            "begin 2", "enqueue x true", "teardown", "abandoned job 1 keyEnded", "abandoned 2 keyEnded",
            "issue 9 false", "enqueue y false", "ran after end",
        ])
        #expect(s.stats.ignoredAfterEnd == 2)
        #expect(s.stats.liveKeys == 0)
    }

    @Test("18: endAll with an untilWorkerReturns hold: the hold outlives it, and its deadline does nothing")
    func endAllWithRetiringHold() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.transaction(1, "w", deadline: .seconds(9), untilRetire: true))
        let parked = Task { try await a.sendAndWait(.transaction(2, ""), cancellation: .ignoresCancel) }
        await f.reach("park #1")
        await a.send(.teardown)
        let parkedResult = outcome(await boundedResult(parked))
        let mid = await a.snapshot()
        // `endAll` stopped the core's timer in its step: the heap is empty and the sleep ended
        // early. Its wake is superseded and reports nothing, and releasing the clock through 9
        // later wakes nothing.
        await f.reach("cancelled deadline 9")
        #expect(await a.deadlineTimer().entries == 0)
        a.clock.release(through: 9)
        f.open("w")
        await a.waitForLog(4)
        let s = await a.snapshot()
        #expect(parkedResult == "closed")
        #expect(mid.stats.openRequests == 0)
        #expect(mid.stats.heldKeys == 1)
        #expect(mid.stats.pendingWaiters == 0)
        #expect(s.log == ["begin 1", "teardown", "abandoned 1 keyEnded", "stale 1"])
        #expect(s.stats.heldKeys == 0)
        #expect(f.count(of: "stale deadline") == 0)
        #expect(await a.deadlineTimer().starts == 1)
    }

    @Test("19: start over a live generation closes requests made earlier in the same step")
    func reissueClosesEarlierRequests() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.reissue(job: 5, first: "r1", second: "r2"))
        let mid = await a.snapshot()
        f.open("r1")
        await a.waitForLog(3)
        f.open("r2")
        await a.waitForLog(4)
        let s = await a.snapshot()
        #expect(mid.log == ["reissue 5 superseded true", "abandoned job 5 keyEnded"])
        #expect(mid.stats.openRequests == 1)
        #expect(s.log == ["reissue 5 superseded true", "abandoned job 5 keyEnded", "stale 5", "finished 5"])
        #expect(s.stats.openRequests == 0)
    }

    @Test("19b: a supersede withdraws the inputs queued under the old generation's scope; one queued before the key's first start stays")
    func supersedeWithdrawsScopedParked() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        // Job 1 is bound (its key is live); job 2's key isn't issued yet.
        await a.send(.issueKey(1))
        // A transaction holds .membership; a call scoped to job 1 and a send scoped to job 2 queue
        // behind it.
        await a.send(.transaction(1, "t1"))
        let scopedCall = Task { try await a.sendAndWait(.scoped(9, scope: 1), cancellation: .ignoresCancel) }
        await f.reach("park #1")
        await a.send(.scoped(10, scope: 2))
        await f.reach("park #2")
        // The rebind: job 1's key is superseded, which withdraws the call queued under it. Job 2's
        // first issue isn't a supersede: its queued send stays.
        await a.send(.issueKey(1))
        await a.send(.issueKey(2))
        let callResult = outcome(await boundedResult(scopedCall))
        let mid = await a.snapshot()
        // The hold is released: only what stayed queued steps, under the new generation.
        f.open("t1")
        await a.waitForLog(6)
        let s = await a.snapshot()
        #expect(callResult == "\(TurnError.withdrawn)")
        #expect(mid.stats.queued == 1)
        #expect(s.log == ["issue 1 false", "begin 1", "issue 1 true", "issue 2 false", "end 1", "scoped 10"])
        #expect(!s.log.contains("scoped 9"))
        #expect(s.stats.queued == 0)
    }

    @Test("19c: a send deferred during a batch is withdrawn when its scope is superseded before it is admitted")
    func supersedeWithdrawsDeferredSend() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.issueKey(1))
        // While the batch flushes output 1, a collaborator sends a supersede of job 1's key and
        // then a send scoped to job 1. Both are deferred; the supersede steps first, so the send
        // belongs to the old generation by the time it is admitted.
        await a.onOutput(1, send: [.issueKey(1), .scoped(9, scope: 1)])
        await a.send(.emit(1))
        let s = await a.snapshot()
        #expect(s.log == ["issue 1 false", "issue 1 true"])
        #expect(s.stats.droppedSends == 1)
    }

    @Test("19f: a send deferred before its scope's end is withdrawn; one deferred after the end steps under the new generation")
    func endWithdrawsDeferredSend() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.issueKey(1))
        await a.send(.issueKey(2))
        // Flushing output 1 defers an end of job 1's key, a send scoped to job 1 (it arrived
        // before the end steps), and an emit for job 2. Flushing that output 2 defers a start of
        // job 1's key and a second scoped send, which arrives after the end.
        await a.onOutputs([
            1: [.endKey(.job(1)), .scoped(9, scope: 1), .emit(2)],
            2: [.issueKey(1), .scoped(10, scope: 1)],
        ])
        await a.send(.emit(1))
        let s = await a.snapshot()
        #expect(s.log == ["issue 1 false", "issue 2 false", "end key job(1)", "issue 1 false", "scoped 10"])
        #expect(s.stats.droppedSends == 1)
    }

    @Test("19d: limit: an input queued after its key's end and before the next start steps under the new generation")
    func queuedBetweenEndAndStartSteps() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.issueKey(1))
        await a.send(.transaction(1, "t1"))
        await a.send(.endKey(.job(1)))
        // Sent while job 1's key isn't live: no generation to belong to.
        await a.send(.scoped(10, scope: 1))
        await f.reach("park #1")
        // Not a supersede (the key isn't live), so the queued input stays.
        await a.send(.issueKey(1))
        f.open("t1")
        await a.waitForLog(6)
        let s = await a.snapshot()
        #expect(s.log == ["issue 1 false", "begin 1", "end key job(1)", "issue 1 false", "end 1", "scoped 10"])
        #expect(s.stats.droppedSends == 0)
    }

    @Test("19e: a queued send withdrawn by its scope's end, or dropped by close, counts as a dropped send")
    func droppedQueuedSendsCount() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.issueKey(1))
        await a.send(.transaction(1, "never"))
        await a.send(.scoped(5, scope: 1))
        await a.send(.step(6))
        await f.reach("park #2")
        await a.send(.endKey(.job(1)))
        let afterEnd = await a.snapshot()
        await a.send(.shutdown)
        let afterClose = await a.snapshot()
        #expect(afterEnd.stats.droppedSends == 1)
        #expect(afterEnd.stats.queued == 1)
        #expect(afterClose.stats.droppedSends == 2)
        #expect(afterClose.stats.queued == 0)
    }

    @Test("20: outputs flush before the next step; a step's effects launch after its flush")
    func flushBeforeNextStepAndBeforeEffects() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.setup)
        await a.send(.transaction(1, "f1"))
        await a.send(.step(1))
        await a.send(.step(2))
        f.open("f1")
        await a.waitForLog(4)
        await a.send(.emitAndWork(7))
        await f.reach("performed 7")
        let s = await a.snapshot()
        // The two released steps ran in one batch, each flushed before the next stepped.
        #expect(s.log == ["begin 1", "end 1", "step 1", "step 2"])
        #expect(s.batches == [[1], [2], [7]])
        #expect(f.trace == ["flush [1]", "flush [2]", "flush [7]", "perform 7"])
    }

    @Test("28: hold handover: the closing step makes the next request on the same key, and a queued input waits for it")
    func holdHandover() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.relay(1, first: "h1", second: "h2"))
        let parked = Task { try await a.sendAndWait(.transaction(7, ""), cancellation: .ignoresCancel) }
        await f.reach("park #1")
        f.open("h1")
        await a.waitForLog(2)
        let mid = await a.snapshot()
        f.open("h2")
        let result = outcome(await boundedResult(parked))
        let s = await a.snapshot()
        #expect(mid.log == ["relay 1", "relay 1 leg 1"])
        #expect(mid.stats.queued == 1)
        #expect(mid.stats.heldKeys == 1)
        #expect(mid.stats.openRequests == 1)
        #expect(result == "success 7")
        #expect(s.log == ["relay 1", "relay 1 leg 1", "relay 1 done", "begin 7", "end 7"])
        #expect(s.stats.heldKeys == 0)
    }
}
