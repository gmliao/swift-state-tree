import Foundation
import SwiftStateTurns
import Testing

/// The core's post lane (#725): reports posted from any thread, taken before the next step.
/// Numbers follow the plan's §5 (`Notes/plans/2026-11-21-turn-core-post-lane.md`). Every
/// interleaving is ordered by a gate or a hook, never by timing.
@Suite("Lane")
struct LaneTests {
    /// Posts `note` from a task of its own, held between the append and the wake: "appended
    /// `label`" opens after the append, and the wake waits for "wake `label`".
    @discardableResult
    static func heldPost(_ a: LaneActor, _ note: LaneNote) async -> Task<Bool, Never> {
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

    @Test("1: a report posted after a step, with an input still queued, steps before that input")
    func reportBeforeQueuedInput() async {
        let a = await LaneActor.started()
        // A's flush sends B (queued behind the segment), then posts the report.
        await a.send(.script([.log("A"), .send([.log("B"), .note("B done")]), .post("R")]))
        await a.fixture.reach("flushed B done")
        #expect(await a.log == ["A", "report R", "B"])
    }

    @Test("2: a post during a step is taken after that step's products drain, before the segment's next step")
    func postDuringStep() async {
        let a = await LaneActor.started()
        let ops: [LaneOp] = [.log("A"), .note("A's output"), .hook, .send([.log("B"), .note("B done")])]
        await StepHooks.$duringStep.withValue({ _ = a.post(LaneNote("R", then: [.note("R's output")])) }) {
            await a.send(.script(ops))
        }
        await a.fixture.reach("flushed B done")
        #expect(await a.log == ["A", "report R", "B"])
        #expect(a.fixture.trace == ["A's output", "R's output", "B done"])
    }

    @Test("3: a post held after its append is taken by the next entry; its wake then finds the lane empty")
    func entryTakesHeldPost() async {
        let a = await LaneActor.started()
        let post = await Self.heldPost(a, LaneNote("R"))
        await a.send(.script([.log("X")]))
        #expect(await a.log == ["report R", "X"])
        a.fixture.open("wake R")
        #expect(await post.value)
        await a.fixture.reach("wake #1")
        // The wake is an entry of its own; the next call into the actor runs after it.
        #expect(await a.stats.emptyLaneWakes == 1)
    }

    @Test("4: no lost wakeup: a post whose append lands after an entry emptied the lane still wakes the core")
    func noLostWakeup() async {
        let a = await LaneActor.started()
        let f = a.fixture
        // R0's own wake is held for the whole case, so it can't rescue R1.
        await Self.heldPost(a, LaneNote("R0"))
        // R1's post is held before its critical section: before it reads whether the lane is empty.
        let late = Task {
            await a.postForTesting(LaneNote("R1", then: [.note("R1 stepped")]), beforeAppend: {
                f.open("before append R1")
                await f.wait("go R1")
            })
        }
        await f.reach("before append R1")
        // An entry takes R0: the lane is empty, and no segment leaves reports behind.
        await a.send(.script([.log("X")]))
        f.open("go R1")
        #expect(await late.value)
        // R1's post found the lane empty, so it owns the wake.
        await f.reach("flushed R1 stepped")
        // A post at the check's hold point (after its watermark, before its first removal) is
        // past the watermark: it steps at the segment's next check, in the same entry.
        let once = Once()
        await a.onLaneCheck { [weak a] in
            once.run { _ = a?.post(LaneNote("R3", then: [.note("R3 stepped")])) }
        }
        _ = a.post(LaneNote("R2"))
        await f.reach("flushed R3 stepped")
        #expect(await a.log == ["report R0", "X", "report R1", "report R2", "report R3"])
        f.open("wake R0")
    }

    @Test("5: a capped segment still checks the lane before each step it makes")
    func cappedSegmentChecks() async {
        let a = await LaneActor.started(maxReleasesPerBatch: 1)
        await a.send(.script([.start(1), .hold(gate: "h")]))
        await a.send(.parked("P1", [.hook]))
        await a.send(.parked("P2"))
        // Ending key 1 releases the hold: the segment releases P1, whose step posts R, and leaves
        // P2 at the cap for the continuation job.
        await StepHooks.$duringStep.withValue({ _ = a.post(LaneNote("R")) }) {
            await a.send(.control([.end(1)]))
        }
        await a.fixture.reach("job #1")
        await a.send(.script([.log("after")]))
        let parts = await a.log(cutBy: a.jobs)
        // R stepped in the capped segment, before its job.
        #expect(parts.first?.suffix(2) == ["parked P1", "report R"])
        #expect(parts.last?.first == "parked P2")
        a.fixture.open("gate h")
    }

    @Test("6: at capacity 1 the first pending report wins; a second post is refused and counted")
    func capacityOneFirstWins() async {
        let a = await LaneActor.started(laneCapacity: 1)
        await Self.heldPost(a, LaneNote("first"))
        #expect(a.post(LaneNote("second")) == false)
        await a.send(.script([.log("X")]))
        #expect(await a.log == ["report first", "X"])
        #expect(await a.stats.refusedReports == 1)
        a.fixture.open("wake first")
    }

    @Test("7: a step's takeReports returns a report posted during that step, which then doesn't step again")
    func takeReportsInStep() async {
        let a = await LaneActor.started()
        await StepHooks.$duringStep.withValue({ _ = a.post(LaneNote("R")) }) {
            await a.send(.script([.hook, .take, .note("taken")]))
        }
        #expect(await a.log == ["took R"])
        // A later post is stepped by the driver.
        _ = a.post(LaneNote("S", then: [.note("S stepped")]))
        await a.fixture.reach("flushed S stepped")
        #expect(await a.log == ["took R", "report S"])
    }

    @Test("8: a report steps through close and after endAll")
    func reportAfterCloseAndEndAll() async {
        let a = await LaneActor.started()
        await a.send(.control([.close]))
        _ = a.post(LaneNote("closed", then: [.log("ok")]))
        await a.fixture.reach("wake #1")
        await a.send(.control([.endAll]))
        _ = a.post(LaneNote("ended"))
        await a.fixture.reach("wake #2")
        #expect(await a.log == ["report closed", "ok", "report ended"])
    }

    @Test("9a: complete of a request the report closes takes the stale path")
    func completeAfterReport() async {
        let a = await LaneActor.started()
        await a.send(.script([.start(2), .request(gate: "w", key: 2)]))
        await a.fixture.reach("at w")
        await Self.heldPost(a, LaneNote("R", then: [.end(2), .note("R stepped")]))
        a.fixture.open("gate w")
        await a.fixture.reach("flushed R stepped")
        await a.send(.script([.log("after")]))
        // The stale completion steps in the entry; the abandonment the report queued, in its segment.
        #expect(await a.log == ["report R", "late w", "abandoned w keyEnded", "after"])
        a.fixture.open("wake R")
    }

    @Test("9b: timerFired of a timer the report drops is stale")
    func timerAfterReport() async {
        let a = await LaneActor.started()
        await a.send(.script([.start(3), .timer("T", key: 3, seconds: 5)]))
        await Self.heldPost(a, LaneNote("R", then: [.end(3), .note("R stepped")]))
        a.fixture.open("deadline 5")
        await a.fixture.reach("flushed R stepped")
        await a.send(.script([.log("after")]))
        #expect(await a.log == ["report R", "after"])
        #expect(a.fixture.count(of: "stale timer") == 1)
        a.fixture.open("wake R")
    }

    @Test("9c: deadlineFired of a request the report closes is stale")
    func deadlineAfterReport() async {
        let a = await LaneActor.started()
        await a.send(.script([.start(4), .request(gate: "d", key: 4, deadlineSeconds: 7)]))
        await Self.heldPost(a, LaneNote("R", then: [.end(4), .note("R stepped")]))
        a.fixture.open("deadline 7")
        await a.fixture.reach("flushed R stepped")
        await a.send(.script([.log("after")]))
        #expect(await a.log == ["report R", "abandoned d keyEnded", "after"])
        #expect(a.fixture.count(of: "stale deadline") == 1)
        a.fixture.open("wake R")
        a.fixture.open("gate d")
    }

    @Test("9d: gateReturned of a follow-up the report consumes is stale")
    func gateAfterReport() async {
        let a = await LaneActor.started()
        await a.send(.script([.start(5), .arm("F", key: 5, gate: "g")]))
        await a.fixture.reach("at g")
        await Self.heldPost(a, LaneNote("R", then: [.consume(key: 5), .note("R stepped")]))
        a.fixture.open("gate g")
        await a.fixture.reach("flushed R stepped")
        await a.send(.script([.log("after")]))
        #expect(await a.log == ["armed F", "report R", "consumed F", "result g", "after"])
        #expect(a.fixture.count(of: "stale follow-up") == 1)
        a.fixture.open("wake R")
    }

    @Test("9e: submit's input is refused when the report closes the core")
    func submitAfterReport() async {
        let a = await LaneActor.started()
        await Self.heldPost(a, LaneNote("R", then: [.close]))
        let result = await boundedResult { try await a.sendAndWait(.script([.log("X")]), cancellation: .ignoresCancel) }
        #expect(outcome(result) == "closed")
        #expect(await a.log == ["report R"])
        a.fixture.open("wake R")
    }

    @Test("10: a report's flush sends and asks; the send queues, the query answers in place, and a report posted before it waits for the next check")
    func reentrancyAndExceptionOne() async {
        let a = await LaneActor.started()
        _ = a.post(LaneNote("R1", then: [.send([.log("S"), .note("S done")]), .post("R2"), .ask("Q")]))
        await a.fixture.reach("flushed S done")
        #expect(await a.log == ["report R1", "answer Q", "report R2", "S"])
        // No flush ran inside another: the send from R1's flush queued.
        #expect(await a.deepestFlush == 1)
    }

    @Test("11: a self-reposting report splits at the budget: batches of 2, 2 and 1 at capacity 2")
    func budgetSplitsSelfReposting() async {
        let a = await LaneActor.started(laneCapacity: 2)
        // Each report's flush posts the next, five in all; R5 notes the end.
        _ = a.post(LaneNote("R1", then: [.post("R2", then: [.post("R3", then: [.post("R4", then: [.post("R5", then: [.note("chain done")])])])])]))
        await a.fixture.reach("flushed chain done")
        await a.send(.script([.log("after")]))
        let batches = await a.log(cutBy: a.wakes).dropFirst().map { $0.filter { $0.hasPrefix("report") } }.filter { !$0.isEmpty }
        #expect(batches == [["report R1", "report R2"], ["report R3", "report R4"], ["report R5"]])
    }

    @Test("11b: a report the budget leaves, posted while the lane wasn't empty, is stepped by the epilogue's wake")
    func epilogueOwnsTheRemainderWake() async {
        let a = await LaneActor.started(laneCapacity: 2)
        // R1 wakes the core. R1's flush posts R3 while R2 is still in the lane, so R3's post
        // finds the lane non-empty and schedules no wake.
        await Self.heldPost(a, LaneNote("R1", then: [.post("R3", then: [.note("R3 stepped")])]))
        _ = a.post(LaneNote("R2"))
        a.fixture.open("wake R1")
        // The wake steps R1 and R2, which spends the budget; only its epilogue's wake steps R3.
        await a.fixture.reach("flushed R3 stepped")
        let batches = await a.log(cutBy: a.wakes).dropFirst().filter { !$0.isEmpty }
        #expect(batches == [["report R1", "report R2"], ["report R3"]])
    }

    @Test("14: FIFO across the two takes: a take during a check returns the reports it hasn't reached yet, in order")
    func fifoAcrossTakes() async {
        let a = await LaneActor.started()
        // A's step posts C, then its flush asks a query, answered in place inside the check: the
        // answer's take sees B, which the check hasn't removed, then C. A report's own take
        // returns nothing (§3.9), so the second take is the answer's.
        await Self.heldPost(a, LaneNote("A", then: [.hook, .take, .askTake("Q")]))
        _ = a.post(LaneNote("B"))
        await StepHooks.$duringStep.withValue({ _ = a.post(LaneNote("C")) }) {
            await a.send(.script([.log("X")]))
        }
        #expect(await a.log == ["report A", "took", "answer Q took B C", "X"])
        a.fixture.open("wake A")
    }

    @Test("15: a report that makes a deadline stale: its abandonment and its flush's send step with no later entry")
    func staleDeadlineRunsEpilogue() async {
        let a = await LaneActor.started()
        await a.send(.script([.start(6), .request(gate: "r", key: 6, deadlineSeconds: 9)]))
        await Self.heldPost(a, LaneNote("R", then: [.end(6), .send([.log("S"), .note("S done")])]))
        a.fixture.open("deadline 9")
        await a.fixture.reach("flushed S done")
        #expect(await a.log == ["report R", "abandoned r keyEnded", "S"])
        a.fixture.open("wake R")
        a.fixture.open("gate r")
    }

    @Test("16: exception 2: a report the entry's lane take steps posts another, which steps after the entry's input")
    func exceptionTwo() async {
        let a = await LaneActor.started()
        await Self.heldPost(a, LaneNote("A", then: [.post("B")]))
        await a.send(.script([.log("X")]))
        #expect(await a.log == ["report A", "X", "report B"])
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
