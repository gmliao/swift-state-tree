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
        mailboxCapacity: Int = 8,
        queueLimit: Int = 64,
        edit: ([MailRecordEntry<MailNote>]) -> [MailRecordEntry<MailNote>] = { $0 },
        _ inputs: @escaping (MailboxActor, Bool) async -> Void
    ) async -> (live: [String], replayed: [String], record: [MailRecordEntry<MailNote>], diverged: [TurnReplayDivergence]) {
        let live = await MailboxActor.started(maxReleasesPerBatch: maxReleasesPerBatch, mailboxCapacity: mailboxCapacity, queueLimit: queueLimit)
        await inputs(live, true)
        // A hop onto the live actor first lets the jobs already on it end, so a wake that ran
        // before it has recorded its take. A post whose wake task isn't enqueued yet can still
        // land after the hop: tests that post reach the wake (`wake #n`) through the actor.
        _ = await live.log
        let record = live.records.entries
        let replay = await MailboxActor.started(maxReleasesPerBatch: maxReleasesPerBatch, mailboxCapacity: mailboxCapacity, queueLimit: queueLimit, replay: edit(record))
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

    /// Lets `gate` in: "deadline N" moves the test clock through N (the core's one timer wakes
    /// for every deadline and timer at or before it); any other gate opens.
    static func letIn(_ a: MailboxActor, _ gate: String) {
        if gate.hasPrefix("deadline "), let seconds = Int64(gate.dropFirst("deadline ".count)) {
            a.clock.release(through: seconds)
        } else {
            a.fixture.open(gate)
        }
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
            a.clock.release(through: 5)
            _ = await a.waitForQuiescence(.requests)
        }
        // R ends key 1 after the deadline closed d: replayed before it, d would end keyEnded.
        #expect(run.live == ["mail R", "abandoned d deadline"])
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13i2: a mail posted at a gate deadline's boundary replays after the deadline's work: the follow-up closes with .deadline")
    func mailAtGateDeadlineBoundary() async {
        let run = await Self.liveThenReplay { a, on in
            await a.send(.script([.start(5), .armWithDeadline("F", key: 5, gate: "nilg", deadlineSeconds: 5)]))
            await a.fixture.reach("at nilg")
            Self.postAtBoundary(a, on, MailNote("R", then: [.end(5)]))
            a.clock.release(through: 5)
            _ = await a.waitForQuiescence(.followUps)
            // The gate's worker returns after its follow-up closed.
            a.fixture.open("gate nilg")
            await a.fixture.reach("stale follow-up #1")
        }
        // R ends key 5 after the deadline closed F: replayed before it, F would end keyEnded.
        #expect(run.live == ["armed F", "mail R", "abandoned F deadline"])
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
            // The closed request's deadline entry stays in the core's one timer until its
            // instant: a close wakes nothing, so no stale arrival lands here.
            Self.postAtBoundary(a, on, MailNote("R", then: [.log("R")]))
            a.fixture.open("gate nilr")
            await a.fixture.reach("flushed P done")
        }
        #expect(run.live == ["abandoned nilr keyEnded", "mail R", "R", "parked P"])
        #expect(run.replayed == run.live)
        // R only logs, so the order alone can't tell the boundary: its key names it, after the
        // retire's own ordinal (the closed request's deadline isn't due, so nothing else took one).
        #expect(run.record.map(\.key) == [.before(step: 9, index: 0)])
        #expect(run.diverged.isEmpty)
    }

    @Test("13l: a mail posted at a timer's boundary replays after the timer's work")
    func mailAtTimerBoundary() async {
        let run = await Self.liveThenReplay { a, on in
            await a.send(.script([.start(1), .timer("T", key: 1, seconds: 5)]))
            Self.postAtBoundary(a, on, MailNote("R", then: [.end(1)]))
            a.clock.release(through: 5)
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

    @Test("13t: a stale deadline takes no ordinal and no mail: one reached before X live and after X in replay leaves the mail between them in place")
    func staleDeadlineAnyWhere() async {
        let run = await Self.liveThenReplay { a, on in
            await a.send(.script([.start(1), .request(gate: "g", key: 1, deadlineSeconds: 60)]))
            await a.fixture.reach("at g")
            a.fixture.open("gate g")
            // The completion closes the request; its entry stays in the core's timer until 60.
            _ = await a.waitForQuiescence(.requests)
            if on {
                // M is pending, its wake held, when the stale entry is reached: no take steps it.
                let post = await MailboxTests.heldPost(a, MailNote("M", then: [.log("M")]))
                a.clock.release(through: 60)
                await a.fixture.reach("stale deadline #1")
                #expect(!(await a.log).contains("mail M"))
                a.fixture.open("wake M")
                _ = await post.value
                await a.fixture.reach("wake #1")
                _ = await a.log
            }
            await a.send(.script([.log("X")]))
            if !on {
                a.clock.release(through: 60)
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
        await a.fixture.reach("stale cancellation #1")
        _ = a.post(MailNote("M", then: [.log("M")]))
        await a.fixture.reach("wake #1")
        await a.send(.control([.log("X")]))
        #expect(await a.stats.cancelledCalls == before)
        #expect(await a.log.suffix(3) == ["mail M", "M", "X"])
        // The stale cancellation, reached before M's post, took no ordinal.
        #expect(a.records.entries.map(\.key) == [.before(step: 7, index: 0)])
    }

    @Test("13w: a core replaying its mail stops the process on a .cancelsCall call")
    func replayRefusesCancelsCall() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let a = await MailboxActor.started(replay: [])
            // Cancelled first, so the call ends at once if the refusal is ever dropped.
            let call = Task { () async throws -> Int in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await a.sendAndWait(.script([.log("P")]), cancellation: .cancelsCall)
            }
            _ = await call.result
        }
        RuntimeStopTests.expectCoreStop(result, "TurnActor: a mail replay doesn't take .cancelsCall calls")
    }

    @Test("13x: a stale timer takes no ordinal and no mail: one reached before X live and after X in replay leaves the mail between them in place")
    func staleTimerAnyWhere() async {
        let run = await Self.liveThenReplay { a, on in
            await a.send(.script([.start(1), .timer("T", key: 1, seconds: 60)]))
            // U replaces T, whose entry stays in the core's timer until 60.
            await a.send(.script([.timer("U", key: 1, seconds: 70)]))
            if on {
                let post = await MailboxTests.heldPost(a, MailNote("M", then: [.log("M")]))
                a.clock.release(through: 60)
                await a.fixture.reach("stale timer #1")
                #expect(!(await a.log).contains("mail M"))
                a.fixture.open("wake M")
                _ = await post.value
                await a.fixture.reach("wake #1")
                _ = await a.log
            }
            await a.send(.script([.log("X")]))
            if !on {
                a.clock.release(through: 60)
                await a.fixture.reach("stale timer #1")
            }
        }
        #expect(run.live.suffix(3) == ["mail M", "M", "X"])
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    /// Live: `pending` is left in the mailbox behind a held remainder wake. Capacity 2: the
    /// step's check steps N and N2, which spend the budget; N posts `pending` while N2 is
    /// still stored, so that post schedules no wake of its own. Then `gate` opens,
    /// and the entry it lets in takes `pending` and reaches `event`, stale after its take.
    /// Replay: the next input X (whose step takes a mail Z mid-step) comes first and steps
    /// `pending`; then the entry arrives, stale before its take. Z's `inside` key pins X's step
    /// number, so an ordinal the stale entry took live would show as a divergence.
    static func staleAfterTake(_ prepare: [MailOp], at reach: String, pending: MailNote, open gate: String, event: String,
                               then cleanup: @escaping (MailboxActor) async -> Void = { _ in }) async -> (live: [String], replayed: [String], record: [MailRecordEntry<MailNote>], diverged: [TurnReplayDivergence]) {
        await liveThenReplay(mailboxCapacity: 2) { a, on in
            await a.holdRemainderWakes()
            await a.send(.script(prepare))
            if !reach.isEmpty { await a.fixture.reach(reach) }
            let hook: (@Sendable () -> Void)? = on ? { @Sendable in
                _ = a.post(MailNote("N", then: [.post(pending.label, then: pending.then)]))
                _ = a.post(MailNote("N2"))
            } : nil
            await StepHooks.$duringStep.withValue(hook) { await a.send(.script([.hook])) }
            if on {
                await a.fixture.reach("remainder #1")
                letIn(a, gate)
                await a.fixture.reach(event)
            }
            await posting(a, on, MailNote("Z")) { await a.send(.script([.hook, .take])) }
            if !on {
                letIn(a, gate)
                await a.fixture.reach(event)
            }
            a.fixture.open("remainder go")
            await cleanup(a)
        }
    }

    /// Two entries due together: A, a timer whose flush posts `pending`, then the one `second`
    /// arms. Capacity 2: P1 and P2, pending when the wake starts, spend A's budget, so `pending`
    /// is left for the second entry's take, which makes that entry stale: it reaches `event`
    /// after its take. Replay steps `pending` at the trailing check of A's segment, so there the
    /// second entry is stale before its take. X's step takes a mail Z mid-step, whose `inside`
    /// key pins X's step number, so an ordinal the stale entry took live shows as a divergence.
    static func laterStaleAfterTake(_ second: [MailOp], pending: MailNote, event: String,
                                    then cleanup: @escaping (MailboxActor) async -> Void = { _ in }) async -> (live: [String], replayed: [String], record: [MailRecordEntry<MailNote>], diverged: [TurnReplayDivergence]) {
        await liveThenReplay(mailboxCapacity: 2) { a, on in
            await a.holdRemainderWakes()
            await a.send(.script([.start(1), .start(2),
                                  .timerRunning("A", key: 1, seconds: 5, then: [.post(pending.label, then: pending.then)])] + second))
            var post: Task<Bool, Never>?
            if on {
                post = await MailboxTests.heldPost(a, MailNote("P1"))
                _ = a.post(MailNote("P2"))
            }
            a.clock.release(through: 5)
            await a.fixture.reach(event)
            // Live, A's segment left `pending` with its budget spent: a remainder wake follows.
            // Had A taken again with a fresh budget, its segment would have stepped `pending`.
            if on { await a.fixture.reach("remainder #1") }
            _ = await a.log
            await posting(a, on, MailNote("Z")) { await a.send(.script([.hook, .take])) }
            a.fixture.open("remainder go")
            if let post {
                a.fixture.open("wake P1")
                _ = await post.value
            }
            await cleanup(a)
        }
    }

    /// The 13t shape for an entry `open` lets in, stale before it enters: live it lands before
    /// X with a wake-stepped mail M between them; in replay it lands after X. X's step takes a
    /// mail Z mid-step, whose `inside` key pins X's step number.
    static func staleBeforeX(_ prepare: [[MailOp]], at reach: String, open gate: String, event: String) async -> (live: [String], replayed: [String], record: [MailRecordEntry<MailNote>], diverged: [TurnReplayDivergence]) {
        await liveThenReplay { a, on in
            for (index, ops) in prepare.enumerated() {
                await a.send(index == 0 ? .script(ops) : .control(ops))
                if index == 0 { await a.fixture.reach(reach) }
            }
            if on {
                a.fixture.open(gate)
                await a.fixture.reach(event)
                _ = a.post(MailNote("M", then: [.log("M")]))
                await a.fixture.reach("wake #1")
                _ = await a.log
            }
            await posting(a, on, MailNote("Z")) { await a.send(.script([.hook, .take])) }
            if !on {
                a.fixture.open(gate)
                await a.fixture.reach(event)
            }
        }
    }

    @Test("13y: a nil run completion takes no ordinal: one that lands before X live and after X in replay leaves the mail between them in place")
    func idleRunCompletionAnyWhere() async {
        let run = await Self.staleBeforeX([[.run(gate: "nilq")]], at: "at nilq", open: "gate nilq", event: "idle completion #1")
        #expect(run.live.suffix(3) == ["mail M", "M", "took Z"])
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13z: a late nil result of a request end closed (no hold) takes no ordinal, wherever it lands")
    func idleLateNilAnyWhere() async {
        let run = await Self.staleBeforeX([[.start(1), .request(gate: "nilz", key: 1)], [.end(1)]], at: "at nilz", open: "gate nilz", event: "idle completion #1")
        #expect(run.live.suffix(3) == ["mail M", "M", "took Z"])
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13za: a stale nil gate return (its follow-up consumed) takes no ordinal, wherever it lands")
    func staleGateReturnAnyWhere() async {
        let run = await Self.staleBeforeX([[.start(5), .arm("F", key: 5, gate: "nilg")], [.consume(key: 5)]], at: "at nilg", open: "gate nilg", event: "stale follow-up #1")
        #expect(run.live.suffix(3) == ["mail M", "M", "took Z"])
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13zb: a deadline its take's mail makes stale takes no ordinal: live it lands before X, in replay after")
    func deadlineStaleAfterTake() async {
        let run = await Self.staleAfterTake([.start(1), .request(gate: "d", key: 1, deadlineSeconds: 5)], at: "at d",
                                            pending: MailNote("C", then: [.end(1)]), open: "deadline 5", event: "stale deadline #1")
        #expect(run.live.contains("took Z"))
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13zc: a timer whose key its take's mail ends takes no ordinal: live it lands before X, in replay after")
    func timerStaleAfterTake() async {
        let run = await Self.staleAfterTake([.start(1), .timer("T", key: 1, seconds: 5)], at: "",
                                            pending: MailNote("C", then: [.end(1)]), open: "deadline 5", event: "stale timer #1")
        #expect(run.live.contains("took Z"))
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13zc2: a gate deadline whose follow-up its take's mail consumes takes no ordinal: live it lands before X, in replay after")
    func gateDeadlineStaleAfterTake() async {
        let run = await Self.staleAfterTake([.start(5), .armWithDeadline("F", key: 5, gate: "nilg", deadlineSeconds: 5)], at: "at nilg",
                                            pending: MailNote("C", then: [.consume(key: 5)]), open: "deadline 5", event: "stale deadline #1") { a in
            a.fixture.open("gate nilg")
            await a.fixture.reach("stale follow-up #1")
        }
        #expect(run.live.contains("took Z"))
        #expect(run.live.contains("consumed F"))
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13zc3: a later due timer whose key its take's mail ends takes no ordinal: stale after its take live, before it in replay")
    func laterTimerStaleAfterTake() async {
        let run = await Self.laterStaleAfterTake([.timer("B", key: 2, seconds: 5)], pending: MailNote("C", then: [.end(2)]), event: "stale timer #1")
        #expect(run.live == ["mail P1", "mail P2", "ran A", "mail C", "took Z"])
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13zc4: a later due deadline whose request its take's mail closes takes no ordinal: stale after its take live, before it in replay")
    func laterDeadlineStaleAfterTake() async {
        let run = await Self.laterStaleAfterTake([.request(gate: "nild", key: 2, deadlineSeconds: 5)], pending: MailNote("C", then: [.end(2)]),
                                                 event: "stale deadline #1") { a in
            a.fixture.open("gate nild")
            await a.fixture.reach("idle completion #1")
        }
        #expect(run.live == ["mail P1", "mail P2", "ran A", "mail C", "abandoned nild keyEnded", "took Z"])
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13zc5: a later due gate deadline whose follow-up its take's mail consumes takes no ordinal: stale after its take live, before it in replay")
    func laterGateDeadlineStaleAfterTake() async {
        let run = await Self.laterStaleAfterTake([.armWithDeadline("F", key: 2, gate: "nilg", deadlineSeconds: 5)], pending: MailNote("C", then: [.consume(key: 2)]),
                                                 event: "stale deadline #1") { a in
            a.fixture.open("gate nilg")
            await a.fixture.reach("stale follow-up #1")
        }
        #expect(run.live == ["armed F", "mail P1", "mail P2", "ran A", "mail C", "consumed F", "took Z"])
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13zd: a nil result whose request its take's mail closes takes no ordinal: live it lands before X, in replay after")
    func completionStaleAfterTake() async {
        let run = await Self.staleAfterTake([.start(1), .request(gate: "nilc", key: 1)], at: "at nilc",
                                            pending: MailNote("C", then: [.end(1)]), open: "gate nilc", event: "idle completion #1")
        #expect(run.live.contains("took Z"))
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13ze: a nil gate return whose follow-up its take's mail consumes takes no ordinal: live it lands before X, in replay after")
    func gateStaleAfterTake() async {
        let run = await Self.staleAfterTake([.start(5), .arm("F", key: 5, gate: "nilh")], at: "at nilh",
                                            pending: MailNote("C", then: [.consume(key: 5)]), open: "gate nilh", event: "stale follow-up #1")
        #expect(run.live.contains("took Z"))
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13zf: a cancellation its take's mail makes stale (a pending close refuses the call) takes no ordinal; the call ends closed (live only)")
    func cancellationStaleAfterTake() async {
        let a = await MailboxActor.started(mailboxCapacity: 2)
        await a.holdRemainderWakes()
        await a.send(.script([.start(1), .hold(gate: "h", key: 1)]))
        let p = Task { try await a.sendAndWait(.parked("P"), cancellation: .cancelsCall) }
        await a.fixture.reach("park #1")
        let before = await a.stats.cancelledCalls
        await StepHooks.$duringStep.withValue({ @Sendable in
            _ = a.post(MailNote("N", then: [.post("C", then: [.close])]))
            _ = a.post(MailNote("N2"))
        }) {
            await a.send(.control([.hook]))
        }
        await a.fixture.reach("remainder #1")
        // C waits behind the held remainder wake: the cancellation's take steps it, and its close
        // refuses P before the cancellation's own check.
        p.cancel()
        await a.fixture.reach("stale cancellation #1")
        #expect(outcome(await boundedResult(p)) == "\(TurnError.closed)")
        #expect(await a.stats.cancelledCalls == before)
        await Self.posting(a, true, MailNote("Z")) { await a.send(.control([.hook, .take])) }
        a.fixture.open("remainder go")
        #expect(await a.log.suffix(2) == ["mail C", "took Z"])
        // Z's key pins its step's number: the cancellation took no ordinal.
        #expect(a.records.entries.map(\.key).last == .inside(step: 8, take: 0))
    }

    @Test("13zg: replayMail installed after the first entry stops the process")
    func replayInstalledLateStops() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let a = await MailboxActor.started()
            await a.installReplayForTesting([])
        }
        RuntimeStopTests.expectCoreStop(result, "TurnCore: replayMail after the first entry")
    }

    @Test("13zh: replayMail after a woken post stops the process: a mail was taken, though no ordinal was")
    func replayInstalledAfterAWokenPostStops() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let fixture = Fixture()
            let a = MailboxActor(fixture: fixture, maxReleasesPerBatch: 64, mailboxCapacity: 8)
            _ = a.post(MailNote("M"))
            await fixture.reach("wake #1")
            await a.installReplayForTesting([])
        }
        RuntimeStopTests.expectCoreStop(result, "TurnCore: replayMail after the first entry")
    }

    @Test("13zn: replayMail after a post whose wake hasn't run stops the process: no mail taken yet, but the mailbox took a post")
    func replayInstalledAfterAnUnwokenPostStops() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let a = MailboxActor(fixture: Fixture(), maxReleasesPerBatch: 64, mailboxCapacity: 8)
            await a.postThenInstallReplayForTesting()
        }
        RuntimeStopTests.expectCoreStop(result, "TurnCore: replayMail after the first entry")
    }

    @Test("13zo: replayMail after a call cancelled before entry stops the process: no ordinal, no waiter, but a call was made")
    func replayInstalledAfterAPreCancelledCallStops() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let a = MailboxActor(fixture: Fixture(), maxReleasesPerBatch: 64, mailboxCapacity: 8)
            let call = Task { () async throws -> Int in
                withUnsafeCurrentTask { $0?.cancel() }
                return try await a.sendAndWait(.script([.log("P")]), cancellation: .cancelsCall)
            }
            _ = await call.result
            await a.installReplayForTesting([])
        }
        RuntimeStopTests.expectCoreStop(result, "TurnCore: replayMail after the first entry")
    }

    @Test("13zp: replayMail on a core without a mailbox stops the process")
    func replayOnACoreWithoutAMailboxStops() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            let demo = DemoActor()
            await demo.installReplayForTesting()
        }
        RuntimeStopTests.expectCoreStop(result, "TurnCore: replayMail after the first entry")
    }

    @Test("13zq: in replay, a query from inside a read stops on the open read before it takes an ordinal, not as a divergence")
    func queryInsideReadStopsBeforeItsOrdinal() async {
        let result = await #expect(processExitsWith: .failure, observing: [\.standardErrorContent]) {
            // A staged sentinel no take can match (index 1 while the take is at 0) and no
            // divergence hook: a query that took its ordinal first would stop as a divergence
            // (`unconsumed`) instead, whatever the take did.
            let staged = [MailRecordEntry(key: .before(step: 0, index: 1), mail: [MailNote("S")], now: nil)]
            let a = MailboxActor(fixture: Fixture(), maxReleasesPerBatch: 64, mailboxCapacity: 8, replay: staged, divergenceHook: false)
            await a.queryInsideReadForTesting()
        }
        RuntimeStopTests.expectCoreStop(result, "TurnCore: a step was entered while a read is open")
    }

    @Test("13zi: in replay, a physical post wakes nothing: a staged trailing mail steps at finishReplay, not at the wake")
    func replayWakeTakesNothing() async {
        let beforeFinish = Released()
        let run = await Self.liveThenReplay { a, on in
            // X is clean: no segment, so no check after its ordinals.
            await a.send(.script([.log("X")]))
            // Live, M's wake steps it, keyed after X. In replay, Q only reaches the physical
            // mailbox, which a replay never reads; its wake must not step the staged M.
            _ = a.post(on ? MailNote("M", then: [.log("M")]) : MailNote("Q"))
            await a.fixture.reach("wake #1")
            // Through the actor, so the wake's job (its take, live) has ended.
            let log = await a.log
            if !on { beforeFinish.add(log.joined(separator: ",")) }
        }
        #expect(run.live == ["X", "mail M", "M"])
        #expect(beforeFinish.names == ["X"])
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    /// Live only: `setup` leaves an entry that will arrive stale, held; pending mail C then waits
    /// behind a held remainder wake (the `staleAfterTake` setup). `release` lets the stale entry
    /// in: it returns before its take, so C is still pending when `event` opens.
    static func pendingStaysAtAStaleArrival(_ setup: (MailboxActor) async -> Void, release: (MailboxActor) -> Void, event: String) async -> [String] {
        let a = await MailboxActor.started(mailboxCapacity: 2)
        await a.holdRemainderWakes()
        await setup(a)
        await StepHooks.$duringStep.withValue({ @Sendable in
            _ = a.post(MailNote("N", then: [.post("C")]))
            _ = a.post(MailNote("N2"))
        }) {
            await a.send(.script([.hook]))
        }
        await a.fixture.reach("remainder #1")
        release(a)
        await a.fixture.reach(event)
        let log = await a.log
        a.fixture.open("remainder go")
        return log
    }

    @Test("13zj: a stale deadline returns before its take: mail pending when it is reached stays pending")
    func staleDeadlineLeavesPendingMail() async {
        let log = await Self.pendingStaysAtAStaleArrival({ a in
            await a.send(.script([.start(1), .request(gate: "g", key: 1, deadlineSeconds: 60)]))
            await a.fixture.reach("at g")
            a.fixture.open("gate g")
            _ = await a.waitForQuiescence(.requests)
        }, release: { $0.clock.release(through: 60) }, event: "stale deadline #1")
        #expect(log.contains("mail N2"))
        #expect(!log.contains("mail C"))
    }

    @Test("13zk: a timer made stale after the wake took it returns before its take: mail posted then is left for its own wake")
    func staleTimerLeavesPendingMail() async {
        let a = await MailboxActor.started(mailboxCapacity: 2)
        await a.holdRemainderWakes()
        // A and T are due together, A first. A's step replaces T after the wake took both.
        await a.send(.script([.start(1), .start(2),
                              .timerRunning("A", key: 2, seconds: 60, then: [.timer("U", key: 1, seconds: 70), .post("D")]),
                              .timer("T", key: 1, seconds: 60)]))
        // P1 and P2 are pending (P1's wake held): A's take steps both and spends the budget, so
        // D, which A's flush posts into the emptied mailbox, waits for its own wake.
        let post = await MailboxTests.heldPost(a, MailNote("P1"))
        _ = a.post(MailNote("P2"))
        a.clock.release(through: 60)
        await a.fixture.reach("stale timer #1")
        await a.fixture.reach("wake #1")
        // D's wake stepped it: had T's turn taken the mailbox, that wake would have found it empty.
        #expect(await a.stats.emptyMailboxWakes == 0)
        #expect(await a.log == ["mail P1", "mail P2", "ran A", "mail D"])
        // P1 and P2 are keyed before A's boundary; A's boundary and its step take one ordinal
        // each, so D is keyed two later: T took none.
        let keys = a.records.entries.map(\.key)
        #expect(keys.count == 3)
        if keys.count == 3, case .before(let first, 0) = keys[0], case .before(let d, 0) = keys[2] {
            #expect(keys[1] == .before(step: first, index: 1))
            #expect(d == first + 2)
        } else {
            Issue.record("unexpected keys \(keys)")
        }
        a.fixture.open("remainder go")
        a.fixture.open("wake P1")
        _ = await post.value
    }

    @Test("13zk2: a mixed wake: the mail its first live entry takes closes that entry and a later one, replaces a third and leaves a fourth live, the same in replay")
    func mixedWake() async {
        let run = await Self.liveThenReplay { a, on in
            await a.send(.script([.start(1), .start(2), .start(3), .start(4),
                                  .timer("T1", key: 1, seconds: 5), .timer("T3", key: 3, seconds: 5),
                                  .request(gate: "nild2", key: 2, deadlineSeconds: 5), .request(gate: "nild4", key: 4, deadlineSeconds: 5)]))
            // Live, C is pending when the wake starts, its own wake held: T1's take steps it.
            // The fixture's mail arms no timer: its flush sends the input that replaces T3.
            var post: Task<Bool, Never>?
            if on {
                post = await MailboxTests.heldPost(a, MailNote("C", then: [.end(1), .end(2), .send([.timer("T3b", key: 3, seconds: 9)])]))
            }
            a.clock.release(through: 5)
            // Due in arm order: T1, T3, nild2, nild4 (timers first). After C, the first three
            // pop as stale and nild4 fires.
            await a.fixture.reach("stale deadline #1")
            _ = await a.log
            #expect(a.fixture.count(of: "stale timer") == 2)
            #expect(a.fixture.count(of: "stale deadline") == 1)
            #expect(await a.deadlineEntries == 1)
            a.clock.release(through: 9)
            _ = await a.waitForQuiescence(.timers)
            #expect(await a.deadlineEntries == 0)
            a.fixture.open("gate nild2")
            a.fixture.open("gate nild4")
            await a.fixture.reach("idle completion #2")
            if let post {
                a.fixture.open("wake C")
                _ = await post.value
            }
        }
        #expect(run.live == ["mail C", "abandoned nild2 keyEnded", "abandoned nild4 deadline", "timer T3b"])
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13zk4: when the wake's take closes the head it was taken for, the next due entry takes its own, with a fresh budget")
    func takeClosesItsOwnHead() async {
        let a = await MailboxActor.started(mailboxCapacity: 2)
        await a.holdRemainderWakes()
        await a.send(.script([.start(1), .start(2),
                              .timer("A", key: 1, seconds: 5),
                              .timerRunning("B", key: 2, seconds: 5, then: [.post("D")])]))
        // P1 and P2 spend the take made for A; P1 ends A's key, so B is the list's first entry.
        let post = await MailboxTests.heldPost(a, MailNote("P1", then: [.end(1)]))
        _ = a.post(MailNote("P2"))
        a.clock.release(through: 5)
        await a.fixture.reach("stale timer #1")
        // B's own take reset the budget, so B's segment stepped D, which its flush posted;
        // D's wake then found the mailbox empty. Without that take, D would wait for its wake.
        await a.fixture.reach("wake #1")
        #expect(await a.log == ["mail P1", "mail P2", "ran B", "mail D"])
        #expect(await a.stats.emptyMailboxWakes == 1)
        a.fixture.open("remainder go")
        a.fixture.open("wake P1")
        _ = await post.value
    }

    @Test("13zk3: mail pending at a wake arms a timer at or before the wake's instant: it steps before the wake takes its entries, live and in replay")
    func mailArmsAnEarlierEntryBeforeTheDueList() async {
        let run = await Self.liveThenReplay { a, on in
            await a.send(.script([.start(1), .start(2), .start(3), .timer("A", key: 1, seconds: 5), .timer("B", key: 2, seconds: 5)]))
            // Live, M waits behind its held wake; its flush's send arms C at 4. Replay steps M
            // at the trailing check of this input's segment, before the wake.
            var post: Task<Bool, Never>?
            if on {
                post = await MailboxTests.heldPost(a, MailNote("M", then: [.send([.timer("C", key: 3, seconds: 4)])]))
            }
            a.clock.release(through: 5)
            _ = await a.waitForQuiescence(.timers)
            if let post {
                a.fixture.open("wake M")
                _ = await post.value
            }
        }
        // Both runs: C, armed by M, fires first.
        #expect(run.live == ["mail M", "timer C", "timer A", "timer B"])
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13zl: a nil run completion returns before its take: mail pending when it lands stays pending")
    func idleCompletionLeavesPendingMail() async {
        let log = await Self.pendingStaysAtAStaleArrival({ a in
            await a.send(.script([.run(gate: "nilq")]))
            await a.fixture.reach("at nilq")
        }, release: { $0.fixture.open("gate nilq") }, event: "idle completion #1")
        #expect(log.contains("mail N2"))
        #expect(!log.contains("mail C"))
    }

    @Test("13zm: a stale nil gate return returns before its take: mail pending when it lands stays pending")
    func staleGateReturnLeavesPendingMail() async {
        let log = await Self.pendingStaysAtAStaleArrival({ a in
            await a.send(.script([.start(5), .arm("F", key: 5, gate: "nilg")]))
            await a.fixture.reach("at nilg")
            await a.send(.script([.consume(key: 5)]))
        }, release: { $0.fixture.open("gate nilg") }, event: "stale follow-up #1")
        #expect(log.contains("mail N2"))
        #expect(!log.contains("mail C"))
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
