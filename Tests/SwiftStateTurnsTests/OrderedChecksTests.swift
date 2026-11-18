import SwiftStateTurns
import Testing

/// The core's rules one at a time, on `DemoMachine`. Every interleaving is ordered by a gate,
/// a core diagnostic or an awaited reply.
@Suite("Turn core: ordered checks", .timeLimit(.minutes(1)))
struct OrderedChecksTests {
    @Test("1: a completion after its key ended goes to handleStale")
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
        #expect(mid.stats.parked == 1)
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
        f.open("deadline 5")
        await a.waitForLog(3)
        f.open("d1")
        await a.waitForLog(4)
        f.open("d2")
        await a.waitForLog(5)
        let s = await a.snapshot()
        #expect(s.log == ["begin 1", "abandoned 1 deadline", "begin 2", "stale 1", "end 2"])
        #expect(s.stats.heldKeys == 0)
    }

    @Test("4: an untilWorkerRetires hold outlives the deadline and is released by the stale result")
    func retiringHoldOutlivesDeadline() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.transaction(1, "w1", deadline: .seconds(7), untilRetire: true))
        await a.send(.transaction(2, ""))
        f.open("deadline 7")
        await a.waitForLog(2)
        let mid = await a.snapshot()
        f.open("w1")
        await a.waitForLog(5)
        let s = await a.snapshot()
        #expect(mid.log == ["begin 1", "abandoned 1 deadline"])
        #expect(mid.stats.parked == 1)
        #expect(mid.stats.heldKeys == 1)
        #expect(mid.stats.openRequests == 0)
        #expect(s.log == ["begin 1", "abandoned 1 deadline", "stale 1", "begin 2", "end 2"])
        #expect(s.stats.heldKeys == 0)
    }

    @Test("5: close answers a parked call and refuses a later one; a stepped call still gets its answer")
    func closeAnswersParkedRefusesLater() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        let stepped = Task { try await a.call(.transaction(4, "c4"), cancellation: .ignored) }
        await f.wait("at c4")
        let parked = Task { try await a.call(.transaction(5, ""), cancellation: .ignored) }
        await f.wait("park #1")
        await a.send(.shutdown)
        let parkedResult = outcome(await parked.result)
        let late = outcome(await Task { try await a.call(.echo(1), cancellation: .ignored) }.result)
        f.open("c4")
        let steppedResult = outcome(await stepped.result)
        let s = await a.snapshot()
        #expect(parkedResult == "closed")
        #expect(late == "closed")
        #expect(steppedResult == "success 4")
        #expect(s.log == ["begin 4", "shutdown", "end 4"])
        #expect(s.stats.pendingWaiters == 0)
        #expect(s.stats.parked == 0)
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

    @Test("8: a collaborator called between steps may read, ask and send")
    func collaboratorBetweenSteps() async {
        let a = DemoActor()
        let saw = await a.collaboratorBetweenSteps()
        let s = await a.snapshot()
        // It read two steps and was answered the first ask; its send stepped after them.
        #expect(saw == [2, 1])
        #expect(s.steps == 3)
        #expect(s.asks == 1)
        #expect(s.flushed == [900])
    }

    @Test("9: call and reply round-trip; reply(after:) waits for the completion step, and for the abandonment")
    func callReplyAndReplyAfter() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        let value = try? await a.call(.echo(42), cancellation: .ignored)
        #expect(value == 42)

        // Published after the request's completion step.
        let afterCompletion = Task {
            try await a.call(.replyAfter(job: 9, gate: "r9", deadline: nil), cancellation: .ignored)
        }
        await f.wait("at r9")
        let waiting = await a.snapshot()
        f.open("r9")
        let completed = outcome(await afterCompletion.result)
        let afterStep = await a.snapshot()

        // Published when the request is abandoned (here by its deadline).
        let afterAbandon = Task {
            try await a.call(.replyAfter(job: 10, gate: "never", deadline: .seconds(5)), cancellation: .ignored)
        }
        await f.wait("at never")
        let waitingAgain = await a.snapshot()
        f.open("deadline 5")
        let abandoned = outcome(await afterAbandon.result)
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
        await f.wait("at c3")
        await a.send(.cancelJob(3))
        let mid = await a.snapshot()
        f.open("c3")
        await a.waitForLog(2)
        let s = await a.snapshot()
        #expect(mid.log == ["abandoned job 3 cancelled"])
        #expect(mid.stats.openRequests == 0)
        #expect(s.log == ["abandoned job 3 cancelled", "stale 3"])
    }

    @Test("11: a parked input is withdrawn when its scope ends; ending another key leaves it")
    func scopeEndWithdrawsParked() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.transaction(1, "s1"))
        let scoped = Task { try await a.call(.scoped(1, scope: 5), cancellation: .ignored) }
        await f.wait("park #1")
        await a.send(.endJob(6))
        let afterOther = await a.snapshot()
        await a.send(.endJob(5))
        let result = outcome(await scoped.result)
        f.open("s1")
        await a.waitForLog(2)
        let s = await a.snapshot()
        #expect(afterOther.stats.parked == 1)
        #expect(result == "withdrawn")
        #expect(s.log == ["begin 1", "end 1"])
        #expect(s.stats.parked == 0)
    }

    @Test("12: the parked limit refuses a call with overloaded; a send over it is dropped and counted")
    func parkedLimitRefuses() async {
        let f = Fixture()
        let a = DemoActor(fixture: f, parkedLimit: 2)
        await a.send(.transaction(1, "l1"))
        let second = Task { try await a.call(.transaction(2, ""), cancellation: .ignored) }
        let third = Task { try await a.call(.transaction(3, ""), cancellation: .ignored) }
        await f.wait("park #2")
        let fourth = outcome(await Task { try await a.call(.transaction(4, ""), cancellation: .ignored) }.result)
        await a.send(.transaction(5, ""))
        let full = await a.snapshot()
        f.open("l1")
        let results = [outcome(await second.result), outcome(await third.result)].sorted()
        let s = await a.snapshot()
        #expect(fourth == "overloaded")
        #expect(full.stats.droppedSends == 1)
        #expect(full.stats.parked == 2)
        #expect(results == ["success 2", "success 3"])
        #expect(!s.log.contains("begin 4"))
        #expect(!s.log.contains("begin 5"))
    }

    @Test("13: 40 released inputs step in order, at most segmentBudget per segment; a late arrival steps after them")
    func releasedInputsDrainInBudgetedSegments() async {
        let f = Fixture()
        let a = DemoActor(fixture: f, segmentBudget: 8)
        await a.drainWithLateArrival(count: 40)
        await a.waitForLog(44)
        await a.clearHooks()
        let s = await a.snapshot()
        let segments = f.segments
        #expect(Array(s.log.prefix(3)) == ["begin 1", "abort 1", "abandoned 1 keyEnded"])
        #expect(Array(s.log.dropFirst(3)) == (0..<40).map { "step \($0)" } + ["step 999"])
        #expect(s.flushed == Array(0..<40) + [999])
        #expect(s.stats.drainContinuations >= 4)
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
        await f.wait("foreign")
        let state = await a.state()
        #expect(state.log.isEmpty)
        #expect(state.steps == 0)
        #expect(state.foreign == 1)
    }

    @Test("15: a token marked before arrival withdraws; marked while parked withdraws on release; revoke withdraws in its step")
    func endTokens() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)

        // Marked before the input arrives: withdrawn before any step.
        let early = EndToken()
        early.markEnded()
        let first = outcome(await Task { try await a.call(.guarded(1, token: early), cancellation: .ignored) }.result)

        // Marked upstream while parked: it keeps its place, and is withdrawn when released.
        await a.send(.transaction(1, "g1"))
        let late = EndToken()
        let second = Task { try await a.call(.guarded(2, token: late), cancellation: .ignored) }
        await f.wait("park #1")
        late.markEnded()
        let stillParked = await a.snapshot().stats.parked
        f.open("g1")
        let secondResult = outcome(await second.result)

        // Revoked by a step: withdrawn in that step.
        await a.send(.transaction(3, "g3"))
        let revoked = EndToken()
        let third = Task { try await a.call(.guarded(3, token: revoked), cancellation: .ignored) }
        await f.wait("park #2")
        await a.send(.revoke(revoked))
        let afterRevoke = await a.snapshot()
        let thirdResult = outcome(await third.result)
        f.open("g3")
        await a.waitForLog(5)
        let s = await a.snapshot()

        #expect(first == "withdrawn")
        #expect(stillParked == 1)
        #expect(secondResult == "withdrawn")
        #expect(afterRevoke.stats.parked == 0)
        #expect(revoked.isEnded)
        #expect(thirdResult == "withdrawn")
        #expect(s.log == ["begin 1", "end 1", "begin 3", "revoke", "end 3"])
    }

    @Test("16: queue steps after the inputs already parked, survives close, the parked limit and a key's end; only endAll drops it")
    func queueKeepsItsPlace() async {
        let f = Fixture()
        let a = DemoActor(fixture: f, parkedLimit: 2)
        await a.send(.transaction(1, "q1"))
        let parked = Task { try await a.call(.transaction(2, ""), cancellation: .ignored) }
        await f.wait("park #1")
        await a.send(.enqueue("a"))
        // The queued input counts as parked, so the limit is reached...
        let overLimit = outcome(await Task { try await a.call(.transaction(3, ""), cancellation: .ignored) }.result)
        // ...and doesn't apply to `queue` itself.
        await a.send(.enqueue("b"))
        await a.send(.endKey(.membership))
        let beforeClose = await a.snapshot()
        await a.send(.shutdown)
        let parkedResult = outcome(await parked.result)
        let afterClose = await a.snapshot()
        f.open("q1")
        await a.waitForLog(8)
        let s = await a.snapshot()
        #expect(overLimit == "overloaded")
        #expect(beforeClose.stats.parked == 3)
        #expect(parkedResult == "closed")
        #expect(afterClose.stats.parked == 2)
        #expect(s.log == [
            "begin 1", "enqueue a true", "enqueue b true", "end key membership", "shutdown",
            "end 1", "queued a", "queued b",
        ])
        #expect(s.stats.parked == 0)

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
        #expect(afterEnd.stats.parked == 0)
        #expect(t.log == ["begin 1", "enqueue c true", "teardown", "abandoned 1 keyEnded", "enqueue d false", "stale 1"])
        #expect(t.stats.ignoredAfterEnd == 1)

        // The queued input steps after the inputs already parked behind the key, which survive
        // here and step first, in their order.
        let h = Fixture()
        let c = DemoActor(fixture: h)
        await c.send(.transaction(1, "y1"))
        await c.send(.step(5))
        await h.wait("park #1")
        await c.send(.step(6))
        await h.wait("park #2")
        await c.send(.enqueue("e"))
        await c.send(.step(7))
        h.open("y1")
        await c.waitForLog(7)
        let u = await c.snapshot()
        // `step 7` arrived after the queue and parks after it.
        #expect(u.log == ["begin 1", "enqueue e true", "end 1", "step 5", "step 6", "queued e", "step 7"])
        #expect(u.stats.parked == 0)
    }

    @Test("17: endAll abandons, ends, withdraws, drops and closes; then issue and queue are ignored, run and ask still step")
    func endAllIsTerminal() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.setup)
        await a.send(.start(job: 1, gate: "x1"))
        await a.send(.transaction(2, "x2"))
        let scoped = Task { try await a.call(.scoped(3, scope: 7), cancellation: .ignored) }
        await f.wait("park #1")
        let unscoped = Task { try await a.call(.transaction(4, ""), cancellation: .ignored) }
        await f.wait("park #2")
        await a.send(.enqueue("x"))
        await a.send(.teardown)
        let scopedResult = outcome(await scoped.result)
        let unscopedResult = outcome(await unscoped.result)
        let afterEnd = await a.snapshot()
        await a.send(.issueKey(9))
        await a.send(.enqueue("y"))
        await a.send(.runMark("after end"))
        let asked = await a.ask(.bump)
        let late = outcome(await Task { try await a.call(.echo(1), cancellation: .ignored) }.result)
        await a.waitForLog(8)
        let s = await a.snapshot()
        #expect(scopedResult == "withdrawn")
        #expect(unscopedResult == "closed")
        #expect(afterEnd.stats.liveKeys == 0)
        #expect(afterEnd.stats.openRequests == 0)
        #expect(afterEnd.stats.parked == 0)
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

    @Test("18: endAll with an untilWorkerRetires hold: the hold outlives it, and its deadline does nothing")
    func endAllWithRetiringHold() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.transaction(1, "w", deadline: .seconds(9), untilRetire: true))
        let parked = Task { try await a.call(.transaction(2, ""), cancellation: .ignored) }
        await f.wait("park #1")
        await a.send(.teardown)
        let parkedResult = outcome(await parked.result)
        let mid = await a.snapshot()
        // The closed request's deadline task was cancelled: its sleep ended early, and the core's
        // re-check found the request closed.
        await f.wait("cancelled deadline 9")
        await f.wait("stale deadline #1")
        f.open("deadline 9")
        f.open("w")
        await a.waitForLog(4)
        let s = await a.snapshot()
        #expect(parkedResult == "closed")
        #expect(mid.stats.openRequests == 0)
        #expect(mid.stats.heldKeys == 1)
        #expect(mid.stats.pendingWaiters == 0)
        #expect(s.log == ["begin 1", "teardown", "abandoned 1 keyEnded", "stale 1"])
        #expect(s.stats.heldKeys == 0)
        // The one stale wake is the cancelled one; opening the gate later wakes nothing.
        #expect(f.count(of: "stale deadline") == 1)
    }

    @Test("19: issue over a live generation closes requests made earlier in the same step")
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

    @Test("19b: a supersede withdraws the inputs parked under the old generation's scope; one parked before the key's first issue stays")
    func supersedeWithdrawsScopedParked() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        // Job 1 is bound (its key is live); job 2's key isn't issued yet.
        await a.send(.issueKey(1))
        // A transaction holds .membership; a call scoped to job 1 and a send scoped to job 2 park
        // behind it.
        await a.send(.transaction(1, "t1"))
        let scopedCall = Task { try await a.call(.scoped(9, scope: 1), cancellation: .ignored) }
        await f.wait("park #1")
        await a.send(.scoped(10, scope: 2))
        await f.wait("park #2")
        // The rebind: job 1's key is superseded, which withdraws the call parked under it. Job 2's
        // first issue isn't a supersede: its parked send stays.
        await a.send(.issueKey(1))
        await a.send(.issueKey(2))
        let callResult = outcome(await scopedCall.result)
        let mid = await a.snapshot()
        // The hold is released: only what stayed parked steps, under the new generation.
        f.open("t1")
        await a.waitForLog(6)
        let s = await a.snapshot()
        #expect(callResult == "\(TurnError.withdrawn)")
        #expect(mid.stats.parked == 1)
        #expect(s.log == ["issue 1 false", "begin 1", "issue 1 true", "issue 2 false", "end 1", "scoped 10"])
        #expect(!s.log.contains("scoped 9"))
        #expect(s.stats.parked == 0)
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
        await f.wait("performed 7")
        let s = await a.snapshot()
        // The two released steps ran in one segment, each flushed before the next stepped.
        #expect(s.log == ["begin 1", "end 1", "step 1", "step 2"])
        #expect(s.batches == [[1], [2], [7]])
        #expect(f.trace == ["flush [1]", "flush [2]", "flush [7]", "perform 7"])
    }

    @Test("28: hold handover: the closing step makes the next request on the same key, and a parked input waits for it")
    func holdHandover() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.relay(1, first: "h1", second: "h2"))
        let parked = Task { try await a.call(.transaction(7, ""), cancellation: .ignored) }
        await f.wait("park #1")
        f.open("h1")
        await a.waitForLog(2)
        let mid = await a.snapshot()
        f.open("h2")
        let result = outcome(await parked.result)
        let s = await a.snapshot()
        #expect(mid.log == ["relay 1", "relay 1 leg 1"])
        #expect(mid.stats.parked == 1)
        #expect(mid.stats.heldKeys == 1)
        #expect(mid.stats.openRequests == 1)
        #expect(result == "success 7")
        #expect(s.log == ["relay 1", "relay 1 leg 1", "relay 1 done", "begin 7", "end 7"])
        #expect(s.stats.heldKeys == 0)
    }
}
