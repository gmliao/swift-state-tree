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

    @Test("13o: known gap (#745): an .afterBatch job a wake's products schedule can replay after the next input")
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
        // doesn't place a continuation job relative to the next external input (#745).
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
            Self.postAtBoundary(a, on, MailNote("R", then: [.log("R")]))
            a.fixture.open("gate nilr")
            await a.fixture.reach("flushed P done")
        }
        #expect(run.live == ["abandoned nilr keyEnded", "mail R", "R", "parked P"])
        #expect(run.replayed == run.live)
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
