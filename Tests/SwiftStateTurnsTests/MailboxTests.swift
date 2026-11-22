import Foundation
import SwiftStateTurns
import Testing

/// The core's mailbox (#725): mail posted from any thread, taken before the next step.
/// Numbers follow the plan's §5 (`Notes/plans/2026-11-21-turn-core-mailbox.md`). Every
/// interleaving is ordered by a gate or a hook, never by timing.
@Suite("Mailbox")
struct MailboxTests {
    /// Posts `note` from a task of its own, held between the append and the wake: "appended
    /// `label`" opens after the append, and the wake waits for "wake `label`".
    @discardableResult
    static func heldPost(_ a: MailboxActor, _ note: MailNote) async -> Task<Bool, Never> {
        let f = a.fixture
        let label = note.label
        let task = Task {
            await a.postForTesting(note, afterAppend: {
                f.open("appended \(label)")
                await f.wait("wake \(label)")
            })
        }
        await f.reach("appended \(label)")
        return task
    }

    @Test("1: a mail posted after a step, with an input still queued, steps before that input")
    func mailBeforeQueuedInput() async {
        let a = await MailboxActor.started()
        // A's flush sends B (queued behind the segment), then posts the mail.
        await a.send(.script([.log("A"), .send([.log("B"), .note("B done")]), .post("R")]))
        await a.fixture.reach("flushed B done")
        #expect(await a.log == ["A", "mail R", "B"])
    }

    @Test("2: a post during a step is taken after that step's products drain, before the segment's next step")
    func postDuringStep() async {
        let a = await MailboxActor.started()
        let ops: [MailOp] = [.log("A"), .note("A's output"), .hook, .send([.log("B"), .note("B done")])]
        await StepHooks.$duringStep.withValue({ _ = a.post(MailNote("R", then: [.note("R's output")])) }) {
            await a.send(.script(ops))
        }
        await a.fixture.reach("flushed B done")
        #expect(await a.log == ["A", "mail R", "B"])
        #expect(a.fixture.trace == ["A's output", "R's output", "B done"])
    }

    @Test("3: a post held after its append is taken by the next entry; its wake then finds the mailbox empty")
    func entryTakesHeldPost() async {
        let a = await MailboxActor.started()
        let post = await Self.heldPost(a, MailNote("R"))
        await a.send(.script([.log("X")]))
        #expect(await a.log == ["mail R", "X"])
        a.fixture.open("wake R")
        #expect(await post.value)
        await a.fixture.reach("wake #1")
        // The wake is an entry of its own; the next call into the actor runs after it.
        #expect(await a.stats.emptyMailboxWakes == 1)
    }

    @Test("4: no lost wakeup: a post whose append lands after an entry emptied the mailbox still wakes the core")
    func noLostWakeup() async {
        let a = await MailboxActor.started()
        let f = a.fixture
        // R0's own wake is held for the whole case, so it can't rescue R1.
        await Self.heldPost(a, MailNote("R0"))
        // R1's post is held before its critical section: before it reads whether the mailbox is empty.
        let late = Task {
            await a.postForTesting(MailNote("R1", then: [.note("R1 stepped")]), beforeAppend: {
                f.open("before append R1")
                await f.wait("go R1")
            })
        }
        await f.reach("before append R1")
        // An entry takes R0: the mailbox is empty, and no segment leaves mail behind.
        await a.send(.script([.log("X")]))
        f.open("go R1")
        #expect(await late.value)
        // R1's post found the mailbox empty, so it owns the wake.
        await f.reach("flushed R1 stepped")
        // A post at the check's hold point (after its watermark, before its first removal) is
        // past the watermark: it steps at the segment's next check, in the same entry.
        let once = Once()
        await a.onMailboxCheck { [weak a] in
            once.run { _ = a?.post(MailNote("R3", then: [.note("R3 stepped")])) }
        }
        _ = a.post(MailNote("R2"))
        await f.reach("flushed R3 stepped")
        #expect(await a.log == ["mail R0", "X", "mail R1", "mail R2", "mail R3"])
        f.open("wake R0")
    }

    @Test("5: a capped segment still checks the mailbox before each step it makes")
    func cappedSegmentChecks() async {
        let a = await MailboxActor.started(maxReleasesPerBatch: 1)
        await a.send(.script([.start(1), .hold(gate: "h")]))
        await a.send(.parked("P1", [.hook]))
        await a.send(.parked("P2"))
        // Ending key 1 releases the hold: the segment releases P1, whose step posts R, and leaves
        // P2 at the cap for the continuation job.
        await StepHooks.$duringStep.withValue({ _ = a.post(MailNote("R")) }) {
            await a.send(.control([.end(1)]))
        }
        await a.fixture.reach("job #1")
        await a.send(.script([.log("after")]))
        let parts = await a.log(cutBy: a.jobs)
        // R stepped in the capped segment, before its job.
        #expect(parts.first?.suffix(2) == ["parked P1", "mail R"])
        #expect(parts.last?.first == "parked P2")
        // The segment's check took R, not R's own wake: that wake found the mailbox empty.
        await a.fixture.reach("wake #1")
        #expect(await a.stats.emptyMailboxWakes == 1)
        a.fixture.open("gate h")
    }

    @Test("5b: a mail posted after the segment is capped is still checked before its next step")
    func mailAfterTheCap() async {
        let a = await MailboxActor.started(maxReleasesPerBatch: 1)
        await a.send(.script([.start(1), .hold(gate: "h")]))
        // P1's flush sends Q, which steps after the release left P2 at the cap, and posts R.
        await a.send(.parked("P1", [.send([.hook, .log("Q")])]))
        await a.send(.parked("P2"))
        await StepHooks.$duringStep.withValue({ _ = a.post(MailNote("R")) }) {
            await a.send(.control([.end(1)]))
        }
        await a.fixture.reach("job #1")
        let parts = await a.log(cutBy: a.jobs)
        #expect(parts.first?.suffix(3) == ["parked P1", "Q", "mail R"])
        #expect(parts.last?.first == "parked P2")
        await a.fixture.reach("wake #1")
        #expect(await a.stats.emptyMailboxWakes == 1)
        a.fixture.open("gate h")
    }

    @Test("6: at capacity 1 the first pending mail wins; a second post is refused and counted")
    func capacityOneFirstWins() async {
        let a = await MailboxActor.started(mailboxCapacity: 1)
        await Self.heldPost(a, MailNote("first"))
        #expect(a.post(MailNote("second")) == false)
        await a.send(.script([.log("X")]))
        #expect(await a.log == ["mail first", "X"])
        #expect(await a.stats.refusedMail == 1)
        a.fixture.open("wake first")
    }

    @Test("7: a step's takeMail returns a mail posted during that step, which then doesn't step again")
    func takeMailInStep() async {
        let a = await MailboxActor.started()
        await StepHooks.$duringStep.withValue({ _ = a.post(MailNote("R")) }) {
            await a.send(.script([.hook, .take, .note("taken")]))
        }
        #expect(await a.log == ["took R"])
        // A later post is stepped by the driver.
        _ = a.post(MailNote("S", then: [.note("S stepped")]))
        await a.fixture.reach("flushed S stepped")
        #expect(await a.log == ["took R", "mail S"])
    }

    @Test("8: a mail steps through close and after endAll")
    func mailAfterCloseAndEndAll() async {
        let a = await MailboxActor.started()
        await a.send(.control([.close]))
        _ = a.post(MailNote("closed", then: [.log("ok")]))
        await a.fixture.reach("wake #1")
        await a.send(.control([.endAll]))
        _ = a.post(MailNote("ended"))
        await a.fixture.reach("wake #2")
        #expect(await a.log == ["mail closed", "ok", "mail ended"])
    }

    @Test("9a: complete of a request the mail closes takes the stale path")
    func completeAfterMail() async {
        let a = await MailboxActor.started()
        await a.send(.script([.start(2), .request(gate: "w", key: 2)]))
        await a.fixture.reach("at w")
        await Self.heldPost(a, MailNote("R", then: [.end(2), .note("R stepped")]))
        a.fixture.open("gate w")
        await a.fixture.reach("flushed R stepped")
        await a.send(.script([.log("after")]))
        // Products first: the abandonment the mail queued steps in the entry's first segment,
        // before the entry's own (stale) completion.
        #expect(await a.log == ["mail R", "abandoned w keyEnded", "late w", "after"])
        a.fixture.open("wake R")
    }

    @Test("9b: a due timer whose key its take's mail ends is stale after the take")
    func timerAfterMail() async {
        let a = await MailboxActor.started()
        await a.send(.script([.start(3), .timer("T", key: 3, seconds: 5)]))
        await Self.heldPost(a, MailNote("R", then: [.end(3), .note("R stepped")]))
        a.clock.release(through: 5)
        await a.fixture.reach("flushed R stepped")
        await a.send(.script([.log("after")]))
        #expect(await a.log == ["mail R", "after"])
        #expect(a.fixture.count(of: "stale timer") == 1)
        a.fixture.open("wake R")
    }

    @Test("9e: a due timer whose take's mail ends everything: it and the rest of the wake end silently")
    func endAllByMailDuringAWake() async {
        let a = await MailboxActor.started()
        await a.send(.script([.start(1), .start(2), .timer("T1", key: 1, seconds: 5), .timer("T2", key: 2, seconds: 5)]))
        // A mail can't end everything itself: its flush sends the input that does, stepped in the
        // take's segment, before T1's own check.
        let post = await Self.heldPost(a, MailNote("R", then: [.note("R stepped"), .send([.endAll])]))
        a.clock.release(through: 5)
        // R's own note, flushed before its send ends everything (after endAll no keyed output is kept).
        await a.fixture.reach("flushed R stepped")
        // Neither timer fired, and endAll emptied the timer: neither reports either.
        #expect(await a.log == ["mail R"])
        #expect(a.fixture.count(of: "stale timer") == 0)
        a.fixture.open("wake R")
        _ = await post.value
    }

    @Test("9c: a due deadline whose request its take's mail closes is stale after the take")
    func deadlineAfterMail() async {
        let a = await MailboxActor.started()
        await a.send(.script([.start(4), .request(gate: "d", key: 4, deadlineSeconds: 7)]))
        await Self.heldPost(a, MailNote("R", then: [.end(4), .note("R stepped")]))
        a.clock.release(through: 7)
        await a.fixture.reach("flushed R stepped")
        await a.send(.script([.log("after")]))
        #expect(await a.log == ["mail R", "abandoned d keyEnded", "after"])
        #expect(a.fixture.count(of: "stale deadline") == 1)
        a.fixture.open("wake R")
        a.fixture.open("gate d")
    }

    @Test("9d: gateReturned of a follow-up the mail consumes is stale")
    func gateAfterMail() async {
        let a = await MailboxActor.started()
        await a.send(.script([.start(5), .arm("F", key: 5, gate: "g")]))
        await a.fixture.reach("at g")
        await Self.heldPost(a, MailNote("R", then: [.consume(key: 5), .note("R stepped")]))
        a.fixture.open("gate g")
        await a.fixture.reach("flushed R stepped")
        await a.send(.script([.log("after")]))
        #expect(await a.log == ["armed F", "mail R", "consumed F", "result g", "after"])
        #expect(a.fixture.count(of: "stale follow-up") == 1)
        a.fixture.open("wake R")
    }

    @Test("9e: submit's input is refused when the mail closes the core")
    func submitAfterMail() async {
        let a = await MailboxActor.started()
        await Self.heldPost(a, MailNote("R", then: [.close]))
        let result = await boundedResult { try await a.sendAndWait(.script([.log("X")]), cancellation: .ignoresCancel) }
        #expect(outcome(result) == "closed")
        #expect(await a.log == ["mail R"])
        a.fixture.open("wake R")
    }

    @Test("10: a mail's flush sends and asks; the send queues, the query answers in place, and a mail posted before it waits for the next check")
    func reentrancyAndExceptionOne() async {
        let a = await MailboxActor.started()
        _ = a.post(MailNote("R1", then: [.send([.log("S"), .note("S done")]), .post("R2"), .ask("Q")]))
        await a.fixture.reach("flushed S done")
        #expect(await a.log == ["mail R1", "answer Q", "mail R2", "S"])
        // No flush ran inside another: the send from R1's flush queued.
        #expect(await a.deepestFlush == 1)
    }

    @Test("11: a self-reposting mail splits at the budget: batches of 2, 2 and 1 at capacity 2")
    func budgetSplitsSelfReposting() async {
        let a = await MailboxActor.started(mailboxCapacity: 2)
        // Each mail's flush posts the next, five in all; R5 notes the end.
        _ = a.post(MailNote("R1", then: [.post("R2", then: [.post("R3", then: [.post("R4", then: [.post("R5", then: [.note("chain done")])])])])]))
        await a.fixture.reach("flushed chain done")
        await a.send(.script([.log("after")]))
        let batches = await a.log(cutBy: a.wakes).dropFirst().map { $0.filter { $0.hasPrefix("mail") } }.filter { !$0.isEmpty }
        #expect(batches == [["mail R1", "mail R2"], ["mail R3", "mail R4"], ["mail R5"]])
    }

    @Test("11c: after a loop check that stepped, the loop checks again: a mail posted between its watermark and its removal steps in the same segment")
    func loopComesRoundAfterAStep() async {
        let a = await MailboxActor.started()
        // R1 is posted during X's step, so the loop's check (not the entry's take) steps it;
        // R1's own wake runs after this job.
        let once = Once()
        await a.onMailboxCheck { [weak a] in
            // At the check's hold point, past its watermark: the mailbox holds R1, so no wake.
            once.run { _ = a?.post(MailNote("R3")) }
        }
        await StepHooks.$duringStep.withValue({ _ = a.post(MailNote("R1")) }) {
            // `.note` makes X's step dirty, so its segment runs the loop.
            await a.send(.script([.hook, .log("X"), .note("x")]))
        }
        await a.fixture.reach("wake #1")
        let batches = await a.log(cutBy: a.wakes)
        // R3 stepped before R1's wake, in X's segment, because the loop came round.
        #expect(batches.first?.suffix(3) == ["X", "mail R1", "mail R3"])
        #expect(await a.stats.emptyMailboxWakes == 1)
    }

    @Test("11b: a mail the budget leaves, posted while the mailbox wasn't empty, is stepped by the epilogue's wake")
    func epilogueOwnsTheRemainderWake() async {
        let a = await MailboxActor.started(mailboxCapacity: 2)
        // R1 wakes the core. R1's flush posts R3 while R2 is still in the mailbox, so R3's post
        // finds the mailbox non-empty and schedules no wake.
        await Self.heldPost(a, MailNote("R1", then: [.post("R3", then: [.note("R3 stepped")])]))
        _ = a.post(MailNote("R2"))
        a.fixture.open("wake R1")
        // The wake steps R1 and R2, which spends the budget; only its epilogue's wake steps R3.
        await a.fixture.reach("flushed R3 stepped")
        let batches = await a.log(cutBy: a.wakes).dropFirst().filter { !$0.isEmpty }
        #expect(batches == [["mail R1", "mail R2"], ["mail R3"]])
    }

    @Test("11d: a pending remainder wake coalesces: an entry that spends its budget while it is held schedules no second one")
    func remainderWakeCoalesces() async {
        let a = await MailboxActor.started(mailboxCapacity: 2)
        await a.holdRemainderWakes()
        // Each flush posts while another mail is pending, so no post schedules a wake. The wake
        // steps R1 and R2 and leaves R3 and R4: its epilogue schedules the remainder wake, held.
        await Self.heldPost(a, MailNote("R1", then: [.post("R3", then: [.post("R5", then: [.note("R5 done")])])]))
        _ = a.post(MailNote("R2", then: [.post("R4")]))
        a.fixture.open("wake R1")
        await a.fixture.reach("remainder #1")
        // X's take steps R3 and R4 and leaves R5, spending the budget again, while the wake is held.
        await a.send(.script([.log("X")]))
        _ = await a.log
        #expect(a.fixture.count(of: "remainder") == 1)
        a.fixture.open("remainder go")
        await a.fixture.reach("flushed R5 done")
        let batches = await a.log(cutBy: a.wakes).dropFirst().filter { !$0.isEmpty }
        #expect(batches == [["mail R1", "mail R2", "mail R3", "mail R4", "X"], ["mail R5"]])
        #expect(a.fixture.count(of: "remainder") == 1)
        #expect(await a.stats.emptyMailboxWakes == 0)
    }

    @Test("11e: a post's wake leaves a pending remainder wake's flag alone: its own spent budget schedules no second one")
    func postWakeLeavesTheRemainderFlag() async {
        let a = await MailboxActor.started(mailboxCapacity: 2)
        await a.holdRemainderWakes()
        // The first wake steps R1 and R2 and leaves R3: the remainder wake is scheduled, held.
        await Self.heldPost(a, MailNote("R1", then: [.post("R3")]))
        _ = a.post(MailNote("R2"))
        a.fixture.open("wake R1")
        await a.fixture.reach("remainder #1")
        // Y's take steps R3 and empties the mailbox, so R6's post schedules a wake of its own.
        await a.send(.script([.log("Y")]))
        // R6's wake steps R6 and R7 and leaves R8, spending its budget with the remainder wake
        // still held.
        await Self.heldPost(a, MailNote("R6", then: [.post("R8", then: [.note("R8 done")])]))
        _ = a.post(MailNote("R7", then: [.note("R7 done")]))
        a.fixture.open("wake R6")
        await a.fixture.reach("flushed R7 done")
        _ = await a.log
        #expect(a.fixture.count(of: "remainder") == 1)
        a.fixture.open("remainder go")
        await a.fixture.reach("flushed R8 done")
        _ = await a.log
        #expect(a.fixture.count(of: "remainder") == 1)
        #expect(await a.stats.emptyMailboxWakes == 0)
    }

    @Test("14: FIFO across the two takes: a take during a check returns the mail it hasn't reached yet, in order")
    func fifoAcrossTakes() async {
        let a = await MailboxActor.started()
        // A's step posts C, then its flush asks a query, answered in place inside the check: the
        // answer's take sees B, which the check hasn't removed, then C.
        await Self.heldPost(a, MailNote("A", then: [.hook, .askTake("Q")]))
        _ = a.post(MailNote("B"))
        await StepHooks.$duringStep.withValue({ _ = a.post(MailNote("C")) }) {
            await a.send(.script([.log("X")]))
        }
        #expect(await a.log == ["mail A", "answer Q took B C", "X"])
        a.fixture.open("wake A")
    }

    @Test("15: a mail that makes a deadline stale: its abandonment and its flush's send step with no later entry")
    func staleDeadlineRunsEpilogue() async {
        let a = await MailboxActor.started()
        await a.send(.script([.start(6), .request(gate: "r", key: 6, deadlineSeconds: 9)]))
        await Self.heldPost(a, MailNote("R", then: [.end(6), .send([.log("S"), .note("S done")])]))
        a.clock.release(through: 9)
        await a.fixture.reach("flushed S done")
        #expect(await a.log == ["mail R", "abandoned r keyEnded", "S"])
        a.fixture.open("wake R")
        a.fixture.open("gate r")
    }

    @Test("18: an input a mail sends from a continuation job's mailbox take arms an afterBatch follow-up, which steps in the next job")
    func continuationCapturesBeforeTheMailbox() async {
        let a = await MailboxActor.started()
        let jobsBefore = await a.stats.continuationJobs
        // R is posted at the job's start, before it captures F1; its wake runs after the job.
        // A mail can't arm `.afterBatch` work itself (MailTurn); the input its flush sends can.
        a.atNextJob.set { _ = a.post(MailNote("R", then: [.send([.armAfterBatch("F2", key: 2)])])) }
        await a.send(.script([.start(1), .start(2), .armAfterBatch("F1", key: 1)]))
        await a.fixture.reach("job #2")
        _ = await a.log
        let batches = await a.log(cutBy: a.jobs).dropFirst().map(Array.init)
        // F1 was due at the first job's start; F2, armed by R's send in that job, waits for the next.
        #expect(batches == [["mail R", "armed F2", "ran F1"], ["ran F2"]])
        #expect(await a.stats.continuationJobs == jobsBefore + 2)
    }

    @Test("16: products first: what the entry's mailbox take caused (a mail it posts, a release) steps before the entry's input")
    func productsFirst() async {
        let a = await MailboxActor.started()
        // P waits behind the hold on key 99, which h's request under key 1 owns.
        await a.send(.script([.start(1), .hold(gate: "h", key: 1)]))
        await a.send(.parked("P"))
        // A ends key 1 (closing h's request, which frees P) and posts B from its flush.
        await Self.heldPost(a, MailNote("A", then: [.end(1), .post("B")]))
        await a.send(.script([.log("X")]))
        // The entry's first segment steps B and releases P before X, as a wake's segment would
        // have before any later entry (plan §3.4).
        #expect(await a.log == ["mail A", "mail B", "abandoned h keyEnded", "parked P", "X"])
        a.fixture.open("wake A")
    }
}

/// Runs a body once, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        let first = lock.withLock { () -> Bool in
            defer { done = true }
            return !done
        }
        if first { body() }
    }
}
