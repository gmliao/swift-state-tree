import Foundation
import SwiftStateTurns
import Testing

/// Test 13 of the mailbox's plan (§3.9): each case runs live, recording the mailbox's hand-outs,
/// then replays the same inputs from the record with nothing posted, and the two logs match.
@Suite("Mailbox replay")
struct MailReplayTests {
    /// Runs `inputs` live (with `posting` true) and returns the log and the record; then replays
    /// them from `record` (the live record unless given) and returns the replay's log and
    /// divergences. `inputs` posts only when `posting` is true.
    static func liveThenReplay(
        maxReleasesPerBatch: Int = 64,
        queueLimit: Int = 64,
        edit: ([MailRecordEntry<MailNote>]) -> [MailRecordEntry<MailNote>] = { $0 },
        _ inputs: @escaping (MailboxActor, Bool) async -> Void
    ) async -> (live: [String], replayed: [String], record: [MailRecordEntry<MailNote>], diverged: [TurnReplayDivergence]) {
        let live = await MailboxActor.started(maxReleasesPerBatch: maxReleasesPerBatch, queueLimit: queueLimit)
        await inputs(live, true)
        let record = live.records.entries
        let replay = await MailboxActor.started(maxReleasesPerBatch: maxReleasesPerBatch, queueLimit: queueLimit, replay: edit(record))
        await inputs(replay, false)
        await replay.finishReplay()
        return (await live.log, await replay.log, record, replay.records.diverged)
    }

    /// Runs `body` with the step hook posting `note` when `posting`, and with no hook otherwise.
    static func posting(_ a: MailboxActor, _ on: Bool, _ note: MailNote, _ body: () async -> Void) async {
        let hook: (@Sendable () -> Void)? = on ? { @Sendable in _ = a.post(note) } : nil
        await StepHooks.$duringStep.withValue(hook) {
            await body()
        }
    }

    @Test("13a: a mid-step take in an input's step replays")
    func takeInInput() async {
        let run = await Self.liveThenReplay { a, on in
            await Self.posting(a, on, MailNote("R")) { await a.send(.script([.hook, .take])) }
        }
        #expect(run.live == ["took R"])
        #expect(run.replayed == run.live)
        #expect(run.record.map(\.key) == [.inside(step: 3, take: 0)])
        #expect(run.diverged.isEmpty)
    }

    @Test("13b: a mid-step take in a follow-up's step replays")
    func takeInFollowUp() async {
        let run = await Self.liveThenReplay { a, on in
            // The gate's task inherits the hook, so the follow-up's step posts.
            await Self.posting(a, on, MailNote("R")) {
                await a.send(.script([.start(5), .arm("F", key: 5, gate: "g", then: [.hook, .take, .note("F done")])]))
            }
            await a.fixture.reach("at g")
            a.fixture.open("gate g")
            await a.fixture.reach("flushed F done")
        }
        #expect(run.live == ["armed F", "result g", "ran F", "took R"])
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13c: a mid-step take in a query's answer asked from flush replays")
    func takeInAnswer() async {
        let run = await Self.liveThenReplay { a, on in
            await Self.posting(a, on, MailNote("R")) { await a.send(.script([.hook, .askTake("Q")])) }
        }
        #expect(run.live == ["answer Q took R"])
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13d: a driver-stepped mail ahead of a direct input replays")
    func mailAheadOfInput() async {
        let run = await Self.liveThenReplay { a, on in
            if on { await MailboxTests.heldPost(a, MailNote("R")) }
            await a.send(.script([.log("X")]))
            a.fixture.open("wake R")
        }
        #expect(run.live == ["mail R", "X"])
        #expect(run.replayed == run.live)
        #expect(run.record.map(\.key) == [.before(step: 2, index: 0)])
        #expect(run.diverged.isEmpty)
    }

    @Test("13e: a mail stepped between two releases in one segment replays")
    func mailBetweenReleases() async {
        let run = await Self.liveThenReplay(maxReleasesPerBatch: 2) { a, on in
            await a.send(.script([.start(1), .hold(gate: "h")]))
            await a.send(.parked("P1", [.hook]))
            await a.send(.parked("P2"))
            // The hold's request stays parked at its gate: its late result would race the logs.
            await Self.posting(a, on, MailNote("R")) { await a.send(.control([.end(1)])) }
        }
        #expect(run.live == ["abandoned h keyEnded", "parked P1", "mail R", "parked P2"])
        #expect(run.replayed == run.live)
        // Keyed before P2's step, not before the entry's.
        #expect(run.record.map(\.key) == [.before(step: 10, index: 0)])
        #expect(run.diverged.isEmpty)
    }

    @Test("13f: trailing mail replay: one a wake stepped with no turn due, at the next dispatch with its own now; one after the last input, at finishReplay")
    func trailingMail() async {
        let run = await Self.liveThenReplay { a, on in
            a.clock.set(seconds: 10)
            if on {
                _ = a.post(MailNote("W", then: [.readNow]))
                await a.fixture.reach("wake #1")
                // The hook fires at the wake's start, before its check reads the clock; the
                // clock is nonisolated, so hop onto the actor (after the wake's job) first.
                _ = await a.log
            }
            a.clock.set(seconds: 20)
            await a.send(.script([.readNow]))
            // The last input leaves nothing dirty, so no check runs after its step: in replay,
            // only finishReplay steps E. (After a dirty step, the segment's next check would.)
            await a.send(.script([.log("Z")]))
            if on {
                _ = a.post(MailNote("E", then: [.log("E")]))
                await a.fixture.reach("wake #2")
                _ = await a.log
            }
        }
        #expect(run.live == ["mail W", "now 10", "now 20", "Z", "mail E", "E"])
        // W steps at the input's check with the wake's now; the input still reads its own.
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13g: a wake-stepped mail whose flush sends replays with its send before the next input")
    func wakeMailWithASend() async {
        let run = await Self.liveThenReplay { a, on in
            if on {
                _ = a.post(MailNote("A", then: [.send([.log("S")])]))
                await a.fixture.reach("wake #1")
                // After the wake's job: its segment stepped S.
                _ = await a.log
            }
            await a.send(.script([.log("X")]))
        }
        #expect(run.live == ["mail A", "S", "X"])
        // Replay steps A at X's mailbox take; products first steps S before X.
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13n: a wake-stepped mail's products read the wake's now in replay too; the next input reads its own")
    func wakeProductsReadTheWakesNow() async {
        let run = await Self.liveThenReplay { a, on in
            a.clock.set(seconds: 10)
            if on {
                _ = a.post(MailNote("A", then: [.readNow, .send([.readNow])]))
                await a.fixture.reach("wake #1")
                _ = await a.log
            }
            a.clock.set(seconds: 20)
            await a.send(.script([.readNow]))
        }
        #expect(run.live == ["mail A", "now 10", "now 10", "now 20"])
        // Replay steps A and its send S at X's take: S reads the recorded wake now, X its own.
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13o: known gap (#745): a continuation job a wake's segment schedules (here .afterBatch work its send arms) can replay after the next input")
    func afterBatchThroughProductsReorders() async {
        let run = await Self.liveThenReplay { a, on in
            if on {
                // A's flush sends S, which arms F after the batch: live, the wake's epilogue
                // schedules F's job, and it runs before X.
                _ = a.post(MailNote("A", then: [.send([.start(2), .armAfterBatch("F", key: 2)])]))
                await a.fixture.reach("wake #1")
                _ = await a.log
                _ = await a.waitForQuiescence(.followUps)
            }
            await a.send(.script([.log("X")]))
            if !on { _ = await a.waitForQuiescence(.followUps) }
        }
        #expect(run.live == ["mail A", "armed F", "ran F", "X"])
        // Replay steps S in X's products-first segment, and F's job runs after X: replay
        // doesn't place a continuation job relative to the next external input (#745). A capped
        // release the wake's segment schedules replays the same way.
        #expect(run.replayed == ["mail A", "armed F", "X", "ran F"])
        #expect(run.diverged.isEmpty)
    }

    @Test("13h: a mail stepped after a refused admission replays after it, so the refusal stands")
    func mailAfterARefusal() async {
        let run = await Self.liveThenReplay(queueLimit: 1) { a, on in
            // P1 parks behind h's hold; P2 is refused (the queue holds one).
            await a.send(.script([.start(1), .hold(gate: "h", key: 1)]))
            await a.send(.parked("P1"))
            await a.send(.parked("P2"))
            // R ends key 1, closing h's request, which frees the queue and the hold.
            if on { await MailboxTests.heldPost(a, MailNote("R", then: [.end(1)])) }
            await a.send(.script([.log("X")]))
            if on { a.fixture.open("wake R") }
        }
        #expect(run.live == ["mail R", "abandoned h keyEnded", "parked P1", "X"])
        // Keyed after P2's admission (admissions take an ordinal), R can't step ahead of it in
        // replay and turn the refusal into a park.
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    /// Live: posts `note` at the next entry's boundary (after its mailbox take, before its own work).
    static func postAtBoundary(_ a: MailboxActor, _ on: Bool, _ note: MailNote) {
        if on { a.atNextBoundary.set { _ = a.post(note) } }
    }

    @Test("13i: a mail posted at a deadline's boundary replays after the deadline's work: the abandonment keeps .deadline")
    func mailAtDeadlineBoundary() async {
        let run = await Self.liveThenReplay { a, on in
            await a.send(.script([.start(1), .request(gate: "d", key: 1, deadlineSeconds: 5)]))
            await a.fixture.reach("at d")
            Self.postAtBoundary(a, on, MailNote("R", then: [.end(1)]))
            a.fixture.open("deadline 5")
            _ = await a.waitForQuiescence(.requests)
        }
        // R ends key 1 after the deadline closed d: replayed before it, d would end keyEnded.
        #expect(run.live == ["mail R", "abandoned d deadline"])
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13j: a mail posted at a nil completion's boundary replays after the completion closed the request")
    func mailAtNilCompletionBoundary() async {
        let run = await Self.liveThenReplay { a, on in
            await a.send(.script([.start(1), .request(gate: "nilc", key: 1)]))
            await a.fixture.reach("at nilc")
            Self.postAtBoundary(a, on, MailNote("R", then: [.end(1)]))
            a.fixture.open("gate nilc")
            _ = await a.waitForQuiescence(.requests)
        }
        // The completion closed the request with no step, so R's end abandons nothing.
        #expect(run.live == ["mail R"])
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13k: a mail posted at a retire's boundary (a nil result after the request closed) replays after the hold is freed")
    func mailAtRetireBoundary() async {
        let run = await Self.liveThenReplay { a, on in
            await a.send(.script([.start(1), .holdUntilReturn(gate: "nilr", key: 1)]))
            await a.fixture.reach("at nilr")
            await a.send(.parked("P", [.note("P done")]))
            // The request closes; its hold on 99 stays until the worker returns.
            await a.send(.control([.end(1)]))
            // The closed request's deadline task wakes early and returns stale: no entry, no
            // boundary. Waited for, so the test doesn't lean on that.
            await a.fixture.reach("stale deadline #1")
            Self.postAtBoundary(a, on, MailNote("R", then: [.log("R")]))
            a.fixture.open("gate nilr")
            await a.fixture.reach("flushed P done")
        }
        #expect(run.live == ["abandoned nilr keyEnded", "mail R", "R", "parked P"])
        #expect(run.replayed == run.live)
        // R only logs, so the order alone can't tell the boundary: its key names it, after the
        // retire's own ordinal (the stale deadline took none).
        #expect(run.record.map(\.key) == [.before(step: 9, index: 0)])
        #expect(run.diverged.isEmpty)
    }

    @Test("13l: a mail posted at a timer's boundary replays after the timer's work")
    func mailAtTimerBoundary() async {
        let run = await Self.liveThenReplay { a, on in
            await a.send(.script([.start(1), .timer("T", key: 1, seconds: 5)]))
            Self.postAtBoundary(a, on, MailNote("R", then: [.end(1)]))
            a.fixture.open("deadline 5")
            _ = await a.waitForQuiescence(.timers)
        }
        // The timer fired before R ended its key.
        #expect(run.live == ["timer T", "mail R"])
        #expect(run.replayed == run.live)
        // The timer's work is a dispatched step, so R replays after it with or without the
        // boundary; the boundary keeps the timer entry's count alike on both sides, and the key
        // names it.
        #expect(run.record.map(\.key) == [.before(step: 6, index: 0)])
        #expect(run.diverged.isEmpty)
    }

    @Test("13m: a mail posted at a gate's boundary (a nil result) replays after the follow-up became due")
    func mailAtGateBoundary() async {
        let run = await Self.liveThenReplay { a, on in
            await a.send(.script([.start(5), .arm("F", key: 5, gate: "nilg")]))
            await a.fixture.reach("at nilg")
            Self.postAtBoundary(a, on, MailNote("R", then: [.consume(key: 5)]))
            a.fixture.open("gate nilg")
            _ = await a.waitForQuiescence(.followUps)
        }
        #expect(run.live == ["armed F", "mail R", "consumed F"])
        #expect(run.replayed == run.live)
        // `consume` takes F waiting or due, so neither the log nor the gate's outcome tells the
        // orders apart: R's key names the boundary, after the gate's own ordinal.
        #expect(run.record.map(\.key) == [.before(step: 5, index: 0)])
        #expect(run.diverged.isEmpty)
    }

    @Test("13p: a mail posted at a withdrawn release's refusal replays after it: the caller is still refused withdrawn")
    func mailAtAWithdrawnRelease() async {
        let outcomes = Released()
        let run = await Self.liveThenReplay { a, on in
            await a.send(.script([.start(1), .hold(gate: "h", key: 1)]))
            let token = WithdrawToken()
            let p = Task { try await a.sendAndWait(.tokened("P", token), cancellation: .ignoresCancel) }
            await a.fixture.reach("park #1")
            token.withdraw()
            // Ending key 1 frees the hold, and P's release is refused; M, posted at that
            // refusal's boundary, closes the core.
            Self.postAtBoundary(a, on, MailNote("M", then: [.close]))
            await a.send(.script([.end(1)]))
            outcomes.add(outcome(await boundedResult(p)))
        }
        #expect(run.live == ["abandoned h keyEnded", "mail M"])
        #expect(run.replayed == run.live)
        // Replayed ahead of the refusal, M's close would answer P closed.
        #expect(outcomes.names == ["withdrawn", "withdrawn"])
        #expect(run.diverged.isEmpty)
    }

    @Test("13q: a wake's served now lasts its whole replayed segment: a send after a later staged mail reads it too")
    func wakeNowAcrossALaterStagedMail() async {
        let run = await Self.liveThenReplay { a, on in
            a.clock.set(seconds: 10)
            if on {
                // A's flush sends S1 and S2; S1's step posts B, which the loop's check steps
                // between them, all in the wake's segment.
                _ = a.post(MailNote("A", then: [.send([.readNow, .post("B")]), .send([.readNow])]))
                await a.fixture.reach("wake #1")
                _ = await a.log
            }
            a.clock.set(seconds: 20)
            await a.send(.script([.readNow]))
            // S1's post runs in replay too, so a real B sits in the mailbox, which a replay never
            // reads: the B that stepped was the staged one. Live, the wake took it.
            #expect(a.mailbox?.isEmpty == on)
        }
        #expect(run.live == ["mail A", "now 10", "mail B", "now 10", "now 20"])
        // Replay steps A, S1, B and S2 in X's products-first segment: S2 reads the wake's 10,
        // and X its own 20.
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13r: a wake's mail that a previous segment's last check steps in replay serves the wake's now to its send")
    func wakeNowInAPreviousSegment() async {
        let afterY = Released()
        let run = await Self.liveThenReplay { a, on in
            a.clock.set(seconds: 5)
            // Y: dirty (its note), so its segment runs and ends with a check.
            await a.send(.script([.readNow, .note("y")]))
            a.clock.set(seconds: 10)
            if on {
                _ = a.post(MailNote("A", then: [.send([.readNow])]))
                await a.fixture.reach("wake #1")
                _ = await a.log
            } else {
                // Before X: A stepped at Y's last check, in Y's segment, reading the wake's 10.
                afterY.add((await a.log).joined(separator: ","))
            }
            a.clock.set(seconds: 20)
            await a.send(.script([.readNow]))
        }
        #expect(run.live == ["now 5", "mail A", "now 10", "now 20"])
        // Replay steps A at Y's last check, in Y's segment: A's send reads the wake's 10, not
        // Y's cached 5.
        #expect(afterY.names == [Array(run.live.prefix(while: { $0 != "now 20" })).joined(separator: ",")])
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13s: a cancellation takes the mailbox and then an ordinal: a mail posted at its boundary steps after the withdrawal (live only: a replay refuses .cancelsCall)")
    func mailAtACancellationBoundary() async {
        let a = await MailboxActor.started()
        await a.send(.script([.start(1), .hold(gate: "h", key: 1)]))
        let p = Task { try await a.sendAndWait(.parked("P"), cancellation: .cancelsCall) }
        await a.fixture.reach("park #1")
        // M ends key 1, which frees the hold P waits behind.
        Self.postAtBoundary(a, true, MailNote("M", then: [.end(1), .note("M done")]))
        p.cancel()
        #expect(outcome(await boundedResult(p)) == "cancelled")
        await a.fixture.reach("flushed M done")
        // Ahead of the withdrawal, M would release P, which would step and answer.
        #expect(await a.log == ["mail M", "abandoned h keyEnded"])
        // M's key names the boundary, after the cancellation's own ordinal.
        #expect(a.records.entries.map(\.key) == [.before(step: 6, index: 0)])
    }

    @Test("13t: a stale deadline takes no ordinal: one that lands before X live and after X in replay leaves the mail between them in place")
    func staleDeadlineAnyWhere() async {
        let run = await Self.liveThenReplay { a, on in
            a.fixture.open("hold cancelled deadline 60")
            await a.send(.script([.start(1), .request(gate: "g", key: 1, deadlineSeconds: 60)]))
            await a.fixture.reach("at g")
            a.fixture.open("gate g")
            // The completion closes the request and cancels its deadline task, held here.
            await a.fixture.reach("cancelled deadline 60")
            if on {
                a.fixture.open("release cancelled deadline 60")
                await a.fixture.reach("stale deadline #1")
                _ = a.post(MailNote("M", then: [.log("M")]))
                await a.fixture.reach("wake #1")
                _ = await a.log
            }
            await a.send(.script([.log("X")]))
            if !on {
                a.fixture.open("release cancelled deadline 60")
                await a.fixture.reach("stale deadline #1")
            }
        }
        #expect(run.live.suffix(3) == ["mail M", "M", "X"])
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13u: a normal .cancelsCall call cancelled before entry makes no cancellation entry: the next mail's key counts no ordinal for it")
    func preCancelledCallTakesNoOrdinal() async {
        let a = await MailboxActor.started()
        let before = await a.stats.cancelledCalls
        let p = Task { () async throws -> Int in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await a.sendAndWait(.script([.log("P")]), cancellation: .cancelsCall)
        }
        #expect(outcome(await boundedResult(p)) == "cancelled")
        _ = a.post(MailNote("M", then: [.log("M")]))
        await a.fixture.reach("wake #1")
        await a.send(.script([.log("X")]))
        #expect(await a.log == ["mail M", "M", "X"])
        #expect(await a.stats.cancelledCalls == before + 1)
        // The started actor's control input took ordinals 0 and 1; the call took none.
        #expect(a.records.entries.map(\.key) == [.before(step: 2, index: 0)])
    }

    @Test("13v: a refusal that wins over a cancellation: the call ends refused, and the late cancellation is stale, with no entry and no ordinal")
    func refusalBeatsCancellation() async {
        let a = await MailboxActor.started()
        await a.send(.script([.start(1), .hold(gate: "h", key: 1)]))
        let p = Task { try await a.sendAndWait(.parked("P"), cancellation: .cancelsCall) }
        await a.fixture.reach("park #1")
        let before = await a.stats.cancelledCalls
        // The cancellation's hop waits behind this step, whose close refuses P first.
        await StepHooks.$duringStep.withValue({ @Sendable in p.cancel() }) {
            await a.send(.control([.hook, .close]))
        }
        #expect(outcome(await boundedResult(p)) == "\(TurnError.closed)")
        _ = a.post(MailNote("M", then: [.log("M")]))
        await a.fixture.reach("wake #1")
        await a.send(.control([.log("X")]))
        #expect(await a.stats.cancelledCalls == before)
        #expect(await a.log.suffix(3) == ["mail M", "M", "X"])
        // Wherever the stale cancellation landed, it took no ordinal.
        #expect(a.records.entries.map(\.key) == [.before(step: 7, index: 0)])
    }

    @Test("13w: a core replaying its mail stops the process on a .cancelsCall call")
    func replayRefusesCancelsCall() async {
        await #expect(processExitsWith: .failure) {
            let a = await MailboxActor.started(replay: [])
            // Cancelled first, so the call ends at once if the refusal is ever dropped.
            let call = Task { () async throws -> Int in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await a.sendAndWait(.script([.log("P")]), cancellation: .cancelsCall)
            }
            _ = await call.result
        }
    }

    @Test("13x: a stale timer takes no ordinal: one that lands before X live and after X in replay leaves the mail between them in place")
    func staleTimerAnyWhere() async {
        let run = await Self.liveThenReplay { a, on in
            a.fixture.open("hold cancelled deadline 60")
            await a.send(.script([.start(1), .timer("T", key: 1, seconds: 60)]))
            // U replaces T, whose task is cancelled and held here.
            await a.send(.script([.timer("U", key: 1, seconds: 70)]))
            await a.fixture.reach("cancelled deadline 60")
            if on {
                a.fixture.open("release cancelled deadline 60")
                await a.fixture.reach("stale timer #1")
                _ = a.post(MailNote("M", then: [.log("M")]))
                await a.fixture.reach("wake #1")
                _ = await a.log
            }
            await a.send(.script([.log("X")]))
            if !on {
                a.fixture.open("release cancelled deadline 60")
                await a.fixture.reach("stale timer #1")
            }
        }
        #expect(run.live.suffix(3) == ["mail M", "M", "X"])
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13: a replay with an extra take staged fails as unconsumed; an extra mail staged past the last input, as leftover; a removed take changes the output")
    func divergences() async {
        let inputs: (MailboxActor, Bool) async -> Void = { a, on in
            await Self.posting(a, on, MailNote("R")) { await a.send(.script([.hook, .take])) }
            await a.send(.script([.log("next")]))
        }
        let extraTake = await Self.liveThenReplay(edit: { $0 + [MailRecordEntry(key: .inside(step: 1, take: 1), mail: [MailNote("X")], now: nil)] }, inputs)
        #expect(extraTake.diverged == [.unconsumed(.inside(step: 1, take: 1))])
        let extraMail = await Self.liveThenReplay(edit: { $0 + [MailRecordEntry(key: .before(step: 9, index: 0), mail: [MailNote("X")], now: nil)] }, inputs)
        #expect(extraMail.diverged == [.leftover(.before(step: 9, index: 0))])
        let removed = await Self.liveThenReplay(edit: { _ in [] }, inputs)
        #expect(removed.diverged.isEmpty)
        #expect(removed.live == ["took R", "next"])
        #expect(removed.replayed == ["took", "next"])
    }
}
