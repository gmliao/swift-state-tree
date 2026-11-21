import SwiftStateTurns
import Testing

/// Coalesced follow-ups and the quiescence wait (#702, plan `2026-11-20-turn-core-follow-ups.md`
/// §4). A step runs a script of operations, so arms, consumes, starts and ends share one step
/// where a case needs them to. A gate effect waits at the fixture gate "gate <label>" and opens
/// "at gate <label>" when its worker starts. Every order is set by a gate, a diagnostic or an
/// awaited wait, never by a sleep.
@Suite("Turn core: follow-ups and quiescence", .timeLimit(.minutes(1)))
struct FollowUpTests {
    @Test("1: arm, arm (joined, the same id), run: one step, with the first input")
    func armJoinRun() async {
        let a = FollowUpActor()
        await a.send(.script([.start(1), .arm("A"), .arm("B")]))
        #expect(await bounded { await a.waitForQuiescence() })
        let s = await a.snapshot()
        #expect(s.log == ["armed A", "joined A", "ran A"])
        #expect(s.stats.pendingFollowUps == 0)
    }

    @Test("2: arm, consume (its input returned, no step), arm again: a new id, which runs")
    func armConsumeArm() async {
        let a = FollowUpActor()
        await a.send(.script([.start(1), .arm("A"), .consume(), .arm("B")]))
        #expect(await bounded { await a.waitForQuiescence() })
        let s = await a.snapshot()
        #expect(s.log == ["armed A", "consumed A", "armed B", "ran B"])
        #expect(s.abandoned == 0)
        #expect(s.armedIDs.count == 2 && Set(s.armedIDs).count == 2)
    }

    @Test("3: arm, then end the key: closed unrun with keyEnded, and the wait wakes")
    func armThenEnd() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f)
        // In one step: closed before its job.
        await a.send(.script([.start(1), .arm("A"), .end(1)]))
        // A gate still waiting: the wait, started first, wakes at the end, not at the return.
        await a.send(.script([.start(2), .arm("B", key: 2, .work(gate: "b"))]))
        await f.reach("at gate b")
        let waiter = Task { await a.waitForQuiescence() }
        await f.reach("registered #1")
        await a.send(.script([.end(2)]))
        #expect(await settled(waiter))
        f.open("gate b")
        await f.reach("stale follow-up #1")
        let s = await a.snapshot()
        #expect(s.log == ["armed A", "abandoned A keyEnded", "armed B", "abandoned B keyEnded"])
    }

    @Test("4: arm under A, then start makes B current: A's is closed, B's arms (not joined) and runs; in the step, an arm before the start is closed and one after it stands")
    func supersede() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f)
        await a.send(.script([.start(1), .arm("A", .work(gate: "a"))]))
        await f.reach("at gate a")
        await a.send(.script([.arm("X", .slot(.b)), .start(1), .arm("B", .work(gate: "b"))]))
        // A's gate returns after the supersede: it steps nothing.
        f.open("gate a")
        await f.reach("stale follow-up #1")
        f.open("gate b")
        #expect(await bounded { await a.waitForQuiescence() })
        let s = await a.snapshot()
        // Closures step as `handleAbandoned` after the step that closed them, in arm order.
        #expect(s.log == ["armed A", "armed X", "armed B", "abandoned A keyEnded", "abandoned X keyEnded", "ran B"])
    }

    @Test("5: an arm during and after endAll is refused and counted; one before it is closed")
    func armAroundEndAll() async {
        let a = FollowUpActor()
        await a.send(.script([.start(1), .arm("A"), .endAll, .arm("B")]))
        // After endAll intake is closed: a control script.
        await a.send(.controlScript([.arm("C")]))
        #expect(await bounded { await a.waitForQuiescence() })
        let s = await a.snapshot()
        #expect(s.log == ["armed A", "refused B", "abandoned A keyEnded", "refused C"])
        #expect(s.stats.ignoredAfterEnd == 2)
    }

    @Test("6: the wait with nothing armed returns at once")
    func waitWithNothingArmed() async {
        let a = FollowUpActor()
        #expect(await a.pendingWork() == 0)
        #expect(await bounded { await a.waitForQuiescence() })
        #expect(await bounded { await a.waitForQuiescence([.followUps, .requests, .timers]) })
    }

    @Test("7: the wait across a chain: busy until the chain ends; each link steps in a new batch")
    func waitAcrossChain() async {
        let a = FollowUpActor()
        let third: [Op] = [.readNow]
        let second: [Op] = [.readNow, .arm("C", then: third)]
        let first: [Op] = [.readNow, .arm("B", then: second)]
        await a.send(.script([.start(1), .arm("A", then: first)]))
        #expect(await bounded { await a.waitForQuiescence() })
        let s = await a.snapshot()
        #expect(s.log == ["armed A", "ran A", "now", "armed B", "ran B", "now", "armed C", "ran C", "now"])
        // One clock read per link: each ran in a batch of its own.
        #expect(a.clock.reads == 3)
    }

    @Test("8: afterWork steps after its gate returns; the gate's own result steps first; a deadline closes it")
    func afterWork() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f)
        await a.send(.script([.start(1), .arm("A", .work(gate: "a", result: true))]))
        await f.reach("at gate a")
        #expect(await a.pendingWork() == 1)
        #expect(await a.snapshot().log == ["armed A"])
        f.open("gate a")
        #expect(await bounded { await a.waitForQuiescence() })
        #expect(await a.snapshot().log == ["armed A", "gate result a", "ran A"])

        await a.send(.script([.arm("B", .work(gate: "never", deadlineSeconds: 5))]))
        a.clock.set(seconds: 5)
        f.open("deadline 5")
        #expect(await bounded { await a.waitForQuiescence() })
        #expect(await a.snapshot().log.suffix(2) == ["armed B", "abandoned B deadline"])
    }

    @Test("9: afterWork closed while its gate runs (consume, end): the return steps nothing, and the wait woke at the close")
    func afterWorkClosedWhileGateRuns() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f)
        await a.send(.script([.start(1), .arm("A", .work(gate: "a"))]))
        await f.reach("at gate a")
        let first = Task { await a.waitForQuiescence() }
        await f.reach("registered #1")
        await a.send(.script([.consume()]))
        #expect(await settled(first))
        f.open("gate a")
        await f.reach("stale follow-up #1")

        await a.send(.script([.arm("B", .work(gate: "b"))]))
        await f.reach("at gate b")
        let second = Task { await a.waitForQuiescence() }
        await f.reach("registered #2")
        await a.send(.script([.end(1)]))
        #expect(await settled(second))
        f.open("gate b")
        await f.reach("stale follow-up #2")
        let s = await a.snapshot()
        #expect(s.log == ["armed A", "consumed A", "armed B", "abandoned B keyEnded"])
    }

    @Test("10: afterBatch doesn't step inside the arming batch; it steps in the next job, with a fresh now")
    func afterBatchStepsInNextJob() async {
        let a = FollowUpActor()
        await a.send(.script([.start(1), .readNow, .arm("A", then: [.readNow]), .pending(), .readNow]))
        #expect(await bounded { await a.waitForQuiescence() })
        let s = await a.snapshot()
        #expect(s.log == ["now", "armed A", "pending A", "now", "ran A", "now"])
        #expect(a.clock.reads == 2)
    }

    @Test("11: a follow-up's input steps with its hold key held and after close: a control input")
    func stepsAsControlInput() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f)
        // `.ran` asks to wait behind key 99, which the request holds; the core closes intake.
        await a.send(.script([.start(1), .hold(gate: "h"), .close, .arm("A")]))
        #expect(await bounded { await a.waitForQuiescence() })
        #expect(await a.snapshot().log == ["armed A", "ran A"])
        f.open("gate h")
        #expect(await bounded { await a.waitForQuiescence(.requests) })
    }

    @Test("12: two slots under one key are independent; follow-ups due together step in arm order")
    func slotsAndOrder() async {
        let a = FollowUpActor()
        await a.send(.script([.start(1), .start(2), .arm("A", .slot(.b)), .arm("B"), .arm("C", key: 2), .consume(.b)]))
        #expect(await bounded { await a.waitForQuiescence() })
        let s = await a.snapshot()
        #expect(s.log == ["armed A", "armed B", "armed C", "consumed A", "ran B", "ran C"])
    }

    @Test("13: the wait per key, with atMost and kinds, and a cancelled waiter returns false")
    func waitOptions() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f)
        await a.send(.script([.start(1), .start(2), .arm("A", .work(gate: "a")), .arm("B", key: 2, .work(gate: "b"))]))
        await f.reach("at gate a")
        await f.reach("at gate b")
        #expect(await a.pendingWork(of: 1) == 1)
        let keyTwo = Task { await a.waitForQuiescence(of: 2) }
        let atMostOne = Task { await a.waitForQuiescence(atMost: 1) }
        await f.reach("registered #2")
        f.open("gate b")
        #expect(await settled(keyTwo))
        #expect(await settled(atMostOne))
        #expect(await a.pendingWork() == 1)

        // Requests and timers count only when asked for.
        await a.send(.script([.hold(gate: "h"), .timer(seconds: 9)]))
        #expect(await a.pendingWork(.requests) == 1)
        #expect(await a.pendingWork(.timers) == 1)
        #expect(await a.pendingWork([.followUps, .requests, .timers]) == 3)

        let cancelled = Task { await a.waitForQuiescence() }
        await f.reach("registered #3")
        cancelled.cancel()
        #expect(await settled(cancelled) == false)
        #expect(await a.waiterCount() == 0)

        f.open("gate a")
        f.open("gate h")
        #expect(await bounded { await a.waitForQuiescence(.requests) })
    }

    @Test("15: a re-arm from the follow-up's own step is a new arm, not a join, and the wait stays busy across the hand-over")
    func rearmFromOwnStep() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f)
        await a.send(.script([.start(1), .arm("A", .work(gate: "a"), then: [.arm("B", .work(gate: "b"))])]))
        await f.reach("at gate a")
        let waiter = Task { await a.waitForQuiescence() }
        await f.reach("registered #1")
        f.open("gate a")
        await f.reach("at gate b")
        // A stepped and armed B: the waiter is still waiting.
        #expect(await a.waiterCount() == 1)
        f.open("gate b")
        #expect(await settled(waiter))
        let s = await a.snapshot()
        #expect(s.log == ["armed A", "ran A", "armed B", "ran B"])
        #expect(s.armedIDs.count == 2 && Set(s.armedIDs).count == 2)
    }

    @Test("17: a superseded binding's gate still waiting at endAll: the supersede closes A at once and uncounted; endAll closes B; A's late nil return steps nothing")
    func supersededGateAtEndAll() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f)
        await a.send(.script([.start(1), .arm("A", .work(gate: "a"))]))
        await f.reach("at gate a")
        // The supersede alone: A is closed and uncounted before any endAll.
        await a.send(.script([.start(1)]))
        #expect(await a.snapshot().log == ["armed A", "abandoned A keyEnded"])
        #expect(await a.pendingWork() == 0)
        // A live B, then the teardown: one abandonment for B, and the wait returns while A's
        // gate is still held.
        await a.send(.script([.arm("B", .work(gate: "b"))]))
        await f.reach("at gate b")
        await a.send(.script([.endAll]))
        #expect(await bounded { await a.waitForQuiescence() })
        #expect(!f.isOpen("stale follow-up #1"))
        // A returns (nil): stale, no step and no second abandonment.
        f.open("gate a")
        await f.reach("stale follow-up #1")
        f.open("gate b")
        await f.reach("stale follow-up #2")
        let s = await a.snapshot()
        #expect(s.log == ["armed A", "abandoned A keyEnded", "armed B", "abandoned B keyEnded"])
        #expect(s.ran == 0)
        #expect(s.abandoned == 2)
    }

    @Test("18: armed and closed in one step, before launch: its gate never starts")
    func closedBeforeLaunch() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f)
        await a.send(.script([.start(1), .arm("A", .work(gate: "a")), .end(1)]))
        await a.send(.script([.start(2), .arm("B", key: 2, .work(gate: "b")), .consume(key: 2)]))
        await a.send(.script([.start(3), .arm("D", key: 3, .work(gate: "d")), .start(3)]))
        // A later gate starts: the earlier ones would have started before it.
        await a.send(.script([.arm("C", key: 2, .work(gate: "c"))]))
        await f.reach("at gate c")
        // Only C's gate was launched: the launch filter, counted where it launches (in debug
        // builds; release builds keep only the gate checks below).
        #if DEBUG
        #expect(await a.gateLaunches() == 1)
        #endif
        #expect(!f.isOpen("at gate a"))
        #expect(!f.isOpen("at gate b"))
        #expect(!f.isOpen("at gate d"))
        f.open("gate c")
        #expect(await bounded { await a.waitForQuiescence() })
        #expect(await a.snapshot().log == ["armed A", "abandoned A keyEnded", "armed B", "consumed B", "armed D", "abandoned D keyEnded", "armed C", "ran C"])
    }

    @Test("19: consume and the gate deadline, both orders: whichever lands first wins, the other finds nothing")
    func consumeVersusDeadline() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f)
        // Consume first: the deadline then finds no follow-up.
        await a.send(.script([.start(1), .arm("A", .work(gate: "a", deadlineSeconds: 5))]))
        await f.reach("at gate a")
        await a.send(.script([.consume()]))
        a.clock.set(seconds: 5)
        f.open("deadline 5")
        await f.reach("stale deadline #1")
        // Deadline first: the consume then finds nothing. The clock is at 5 s, so this deadline is at 10 s.
        await a.send(.script([.arm("B", .work(gate: "b", deadlineSeconds: 5))]))
        await f.reach("at gate b")
        a.clock.set(seconds: 10)
        f.open("deadline 10")
        #expect(await bounded { await a.waitForQuiescence() })
        await a.send(.script([.consume()]))
        f.open("gate a")
        f.open("gate b")
        await f.reach("stale follow-up #2")
        let s = await a.snapshot()
        #expect(s.log == ["armed A", "consumed A", "armed B", "abandoned B deadline", "consumed nothing"])
    }

    @Test("20: A's stale gate returning while B is pending in the same slot neither steps nor closes B")
    func staleGateWithSuccessorPending() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f)
        await a.send(.script([.start(1), .arm("A", .work(gate: "a")), ]))
        await f.reach("at gate a")
        await a.send(.script([.consume(), .arm("B", .work(gate: "b"))]))
        await f.reach("at gate b")
        f.open("gate a")
        await f.reach("stale follow-up #1")
        #expect(await a.pendingWork() == 1)
        f.open("gate b")
        #expect(await bounded { await a.waitForQuiescence() })
        #expect(await a.snapshot().log == ["armed A", "consumed A", "armed B", "ran B"])
    }

    @Test("21: handleAbandoned arming the same key: refused after end, armed under the new generation after a supersede, refused after endAll")
    func armFromHandleAbandoned() async {
        let a = FollowUpActor()
        await a.send(.script([.start(1), .arm("A"), .onAbandoned([.arm("A2")]), .end(1)]))
        await a.send(.script([.start(2), .arm("B", key: 2), .onAbandoned([.arm("B2", key: 2)]), .start(2)]))
        #expect(await bounded { await a.waitForQuiescence() })
        await a.send(.script([.start(3), .arm("C", key: 3), .onAbandoned([.arm("C2", key: 3)]), .endAll]))
        #expect(await bounded { await a.waitForQuiescence() })
        let s = await a.snapshot()
        #expect(s.log == [
            "armed A", "abandoned A keyEnded", "refused A2",
            "armed B", "abandoned B keyEnded", "armed B2", "ran B2",
            "armed C", "abandoned C keyEnded", "refused C2",
        ])
        #expect(s.stats.ignoredAfterEnd == 1)
    }

    @Test("22: a follow-up whose step supersedes its key and then arms: the arm is new, under the new generation, and runs")
    func stepSupersedesThenArms() async {
        let a = FollowUpActor()
        await a.send(.script([.start(1), .arm("A", then: [.start(1), .arm("B")])]))
        #expect(await bounded { await a.waitForQuiescence() })
        #expect(await a.snapshot().log == ["armed A", "ran A", "armed B", "ran B"])
    }

    @Test("23: two follow-ups due together, the first's step calls endAll: the second is closed, not stepped")
    func revalidatedBetweenDueSteps() async {
        let a = FollowUpActor()
        await a.send(.script([.start(1), .start(2), .arm("A", then: [.endAll]), .arm("B", key: 2)]))
        #expect(await bounded { await a.waitForQuiescence() })
        let s = await a.snapshot()
        #expect(s.log == ["armed A", "armed B", "ran A", "abandoned B keyEnded"])
        #expect(s.ran == 1)
    }

    @Test("24: a gate result that ends the key: the follow-up is closed, not stepped")
    func gateResultEndsKey() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f)
        await a.send(.script([.start(1), .onGateResult([.end(1)]), .arm("A", .work(gate: "a", result: true))]))
        await f.reach("at gate a")
        f.open("gate a")
        #expect(await bounded { await a.waitForQuiescence() })
        let s = await a.snapshot()
        #expect(s.log == ["armed A", "gate result a", "abandoned A keyEnded"])
        #expect(s.ran == 0)
    }

    @Test("25: a stale gate's non-nil result still steps, and may arm work after the wait returned")
    func staleGateResultArms() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f)
        await a.send(.script([.start(1), .arm("A", .work(gate: "a", result: true))]))
        await f.reach("at gate a")
        await a.send(.script([.start(1), .onGateResult([.arm("B")])]))
        #expect(await bounded { await a.waitForQuiescence() })
        f.open("gate a")
        await f.reach("stale follow-up #1")
        #expect(await bounded { await a.waitForQuiescence() })
        #expect(await a.snapshot().log == ["armed A", "abandoned A keyEnded", "gate result a", "armed B", "ran B"])
    }

    @Test("26: endAll wakes an already-registered waiter")
    func endAllWakesWaiter() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f)
        await a.send(.script([.start(1), .arm("A", .work(gate: "a"))]))
        await f.reach("at gate a")
        let waiter = Task { await a.waitForQuiescence() }
        await f.reach("registered #1")
        await a.send(.script([.endAll]))
        #expect(await settled(waiter))
        f.open("gate a")
        await f.reach("stale follow-up #1")
    }

    @Test("27: the release budget exhausted with follow-ups due: they still step in their job; parked inputs past the cap step in later batches, at most the cap each; a successor runs in the next job")
    func capWithFollowUpsDue() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f, maxReleasesPerBatch: 1)
        // Key 1's request holds key 99; three inputs park behind it.
        await a.send(.script([.start(1), .start(2), .start(3), .hold(gate: "h")]))
        for label in ["P1", "P2", "P3"] { await a.send(.parked(label)) }
        // A's step ends key 1, which releases the hold: its segment hits the cap after P1.
        await a.send(.script([.arm("A", .slot(.a), key: 2, .batch, then: [.end(1), .arm("C", key: 2)]), .arm("B", key: 3)]))
        #expect(await bounded { await a.waitForQuiescence() })
        // The quiescence wait counts follow-ups only: wait for the last parked step itself.
        await f.reach("released #3")
        f.open("gate h")
        let log = await a.snapshot().log
        let parked = log.filter { $0.hasPrefix("parked") }
        #expect(parked == ["parked P1", "parked P2", "parked P3"])
        let at = { (line: String) -> Int in
            guard let index = log.firstIndex(of: line) else {
                Issue.record("no \"\(line)\" in the log")
                return Int.max
            }
            return index
        }
        #expect(at("ran A") < at("parked P1"))
        #expect(at("parked P1") < at("ran B"))
        // B steps in A's job, before the job ends; P2 and P3 step in later batches, at most the
        // cap each (whichever entry runs a segment first releases them: the drain, or C's
        // follow-ups job), and C in a later follow-ups job. No order is asserted between those
        // later jobs (plan §3.3).
        #expect(at("ran B") < at("parked P2"))
        #expect(at("ran B") < at("ran C"))
        #expect(f.segments.allSatisfy { $0 <= 1 })
    }

    @Test("27b: a gate's result step that releases past the cap: its follow-up still steps in that segment")
    func capOnGateReturn() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f, maxReleasesPerBatch: 1)
        await a.send(.script([.start(1), .start(2), .hold(gate: "h")]))
        for label in ["P1", "P2"] { await a.send(.parked(label)) }
        await a.send(.script([.onGateResult([.end(1)]), .arm("A", .slot(.a), key: 2, .work(gate: "a", result: true))]))
        await f.reach("at gate a")
        f.open("gate a")
        #expect(await bounded { await a.waitForQuiescence() })
        await f.reach("released #2")
        f.open("gate h")
        let log = await a.snapshot().log
        let at = { (line: String) -> Int in
            guard let index = log.firstIndex(of: line) else {
                Issue.record("no \"\(line)\" in the log")
                return Int.max
            }
            return index
        }
        #expect(at("gate result a") < at("parked P1"))
        #expect(at("parked P1") < at("ran A"))
        #expect(at("ran A") < at("parked P2"))
        #expect(f.segments.allSatisfy { $0 <= 1 })
    }

    @Test("28: a gate's return cancels its deadline and keeps a live request's deadline, which still fires")
    func gateReturnCancelsItsDeadline() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f)
        await a.send(.script([.start(1), .hold(gate: "h", deadlineSeconds: 7), .arm("A", .work(gate: "a", deadlineSeconds: 5))]))
        await f.reach("at gate a")
        f.open("gate a")
        await f.reach("cancelled deadline 5")
        #expect(await bounded { await a.waitForQuiescence() })
        #expect(!f.isOpen("cancelled deadline 7"))
        a.clock.set(seconds: 7)
        f.open("deadline 7")
        await f.reach("woke deadline 7")
        #expect(await bounded { await a.waitForQuiescence(.requests) })
        f.open("gate h")
        #expect(await a.snapshot().log == ["armed A", "ran A"])
    }

    @Test("29: A's obsolete deadline leaves B pending in the same slot; a later sweep keeps B's live gate deadline")
    func obsoleteDeadlineLeavesSuccessor() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f)
        await a.send(.script([.start(1), .arm("A", .work(gate: "a", deadlineSeconds: 5))]))
        await f.reach("at gate a")
        await a.send(.script([.consume(), .arm("B", .work(gate: "b", deadlineSeconds: 9))]))
        await f.reach("cancelled deadline 5")
        await f.reach("stale deadline #1")
        #expect(await a.pendingWork() == 1)
        await f.reach("at gate b")
        // B's deadline task now exists. C, in the other slot, is consumed in a step of its own,
        // so that step's sweep runs with B's gate deadline live: it cancels C's and keeps B's.
        await a.send(.script([.arm("C", .slot(.b), .work(gate: "c", deadlineSeconds: 11))]))
        await f.reach("at gate c")
        #expect(await a.deadlineTaskCount() == 2)
        await a.send(.script([.consume(.b)]))
        #expect(await a.deadlineTaskCount() == 1)
        await f.reach("cancelled deadline 11")
        await f.reach("stale deadline #2")
        f.open("gate b")
        #expect(await bounded { await a.waitForQuiescence() })
        f.open("gate a")
        f.open("gate c")
        await f.reach("stale follow-up #2")
        #expect(await a.snapshot().log == ["armed A", "consumed A", "armed B", "armed C", "consumed C", "ran B"])
    }

    @Test("34: a foreign gate return and a foreign gate deadline are rejected after the core is replaced")
    func foreignGateReturnAndDeadline() async {
        let f = Fixture()
        let a = ReplaceableCoreActor(fixture: f)
        await a.send(.gatedFollowUp(job: 1, gate: "g", deadline: .seconds(5)))
        await a.replaceCore()
        // The old core's deadline wakes first, then its gate returns (with a non-nil result).
        f.open("deadline 5")
        await f.reach("foreign")
        f.open("g")
        await f.reach("foreign #2")
        let state = await a.state()
        #expect(state.log.isEmpty)
        #expect(state.steps == 0)
        #expect(state.foreign == 2)
    }
    @Test("30: the registration tie: the count at the call wins over a cancellation; a registered waiter goes to whichever is serviced first")
    func registrationTie() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f)
        // A task already cancelled when it calls (it cancels itself first): true with nothing
        // pending, false otherwise.
        let quiet = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return await a.waitForQuiescence()
        }
        #expect(await settled(quiet) == true)
        await a.send(.script([.start(1), .arm("A", .work(gate: "a"))]))
        await f.reach("at gate a")
        let busy = Task { () -> Bool in
            withUnsafeCurrentTask { $0?.cancel() }
            return await a.waitForQuiescence()
        }
        #expect(await settled(busy) == false)
        #expect(await a.waiterCount() == 0)

        // Registered, then cancelled, then satisfied: false.
        let cancelledFirst = Task { await a.waitForQuiescence() }
        await f.reach("registered #1")
        cancelledFirst.cancel()
        #expect(await settled(cancelledFirst) == false)
        #expect(await a.waiterCount() == 0)

        // Registered, then cancelled and satisfied in one segment: true. The cancellation's hop
        // to the actor waits behind that segment, whose settle answers the waiter first.
        let satisfiedFirst = Task { await a.waitForQuiescence() }
        await f.reach("registered #2")
        await a.cancelThenConsume(satisfiedFirst)
        #expect(await settled(satisfiedFirst) == true)
        #expect(await a.waiterCount() == 0)
        f.open("gate a")
        await f.reach("stale follow-up #1")
    }

    @Test("31: a query whose answer step consumes the last follow-up wakes a registered waiter")
    func queryConsumeWakesWaiter() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f)
        await a.send(.script([.start(1), .arm("A", .work(gate: "a"))]))
        await f.reach("at gate a")
        let waiter = Task { await a.waitForQuiescence() }
        await f.reach("registered #1")
        #expect(await a.query(.consume(.a, key: 1)))
        #expect(await settled(waiter))
        f.open("gate a")
        await f.reach("stale follow-up #1")
        #expect(await a.snapshot().log == ["armed A", "consumed A"])
    }

    @Test("32: a gate's deadline shares the arming batch's clock read: one read, and the deadline is that now plus the duration")
    func deadlineSharesClockRead() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f)
        a.clock.set(seconds: 3)
        await a.send(.script([.start(1), .readNow, .arm("A", .work(gate: "a", deadlineSeconds: 5))]))
        #expect(a.clock.reads == 1)
        a.clock.set(seconds: 8)
        f.open("deadline 8")
        #expect(await bounded { await a.waitForQuiescence() })
        #expect(await a.snapshot().log == ["now", "armed A", "abandoned A deadline"])
        f.open("gate a")
        await f.reach("stale follow-up #1")
    }

    #if DEBUG
    @Test("33: a gate filtered at launch still counts against its originating input in the debug effect counts")
    func filteredGateCounts() async {
        let a = FollowUpActor()
        await a.send(.script([.start(1), .arm("A", .work(gate: "a")), .end(1)]))
        #expect(await a.effectsByInput()["script"] == 1)
    }
    #endif

    @Test("40: an afterBatch arm joins a pending afterWork arm in its slot: the same id, the first input and trigger stand")
    func joinAcrossTriggers() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f)
        await a.send(.script([.start(1), .arm("A", .work(gate: "a"))]))
        await f.reach("at gate a")
        // C, an afterBatch arm in the other slot, is the fence: its job steps every due
        // follow-up, so a join that made A due would step A there.
        await a.send(.script([.arm("B"), .arm("C", .slot(.b))]))
        #expect(await bounded { await a.waitForQuiescence(atMost: 1) })
        #expect(await a.snapshot().log == ["armed A", "joined A", "armed C", "ran C"])
        #expect(await a.pendingWork() == 1)
        f.open("gate a")
        #expect(await bounded { await a.waitForQuiescence() })
        let s = await a.snapshot()
        #expect(s.log == ["armed A", "joined A", "armed C", "ran C", "ran A"])
        #expect(s.ran == 2)
    }

    @Test("35: a follow-up id is a notification id: cancel does nothing, and reply(after:) publishes at once")
    func followUpIDIsNotARequest() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f)
        await a.send(.script([.start(1), .arm("A", .work(gate: "a"))]))
        await f.reach("at gate a")
        await a.send(.script([.cancelPending()]))
        #expect(await a.pendingWork() == 1)
        // Answered while A is still pending: the reply didn't wait for it.
        // Under the bound, cancellable: a reply that waited for A would park the test.
        let reply = await withinTurnHangBound {
            try? await a.sendAndWait(.script([.replyAfterPending()]), cancellation: .cancelsCall)
        } ?? nil
        #expect(reply == 1)
        #expect(await a.pendingWork() == 1)
        f.open("gate a")
        #expect(await bounded { await a.waitForQuiescence() })
        #expect(await a.snapshot().log == ["armed A", "cancel sent", "ran A"])
    }

    @Test("36: arm then wait, repeated, from outside the actor: every wait returns after its run")
    func armWaitRepeatedFromOutside() async {
        let a = FollowUpActor()
        await a.send(.script([.start(1)]))
        for i in 0 ..< 50 {
            await a.send(.script([.arm("A\(i)")]))
            #expect(await bounded { await a.waitForQuiescence() })
            #expect(await a.snapshot().ran == i + 1)
        }
    }

    @Test("37: arm then wait, repeated, inside one actor method (the follow-up bench's shape)")
    func armWaitRepeatedInside() async {
        let a = FollowUpActor()
        await a.send(.script([.start(1)]))
        #expect(await bounded { await a.armAndWait(50) })
    }

    #if !DEBUG
    @Test("38: release: eight actors arm and wait 3000 times each, in parallel; every wait wakes")
    func armWaitInParallel() async {
        // An extra check, not the gate (case 39 is): a waiter registered off its actor loses its
        // wake to the settle it races, and this load hit that within the first thousand rounds.
        let all = await withTaskGroup(of: Bool.self) { group in
            for _ in 0 ..< 8 {
                group.addTask {
                    let a = FollowUpActor()
                    await a.send(.script([.start(1)]))
                    return await bounded { await a.armAndWait(3000) }
                }
            }
            var all = true
            for await ok in group { all = all && ok }
            return all
        }
        #expect(all)
    }
    #endif

    @Test("39: a wait's re-check and registration run on the actor, in the segment that settles waiters")
    func registrationRunsOnTheActor() async {
        let f = Fixture()
        let a = QueueFollowUpActor(fixture: f)
        let log = RegistrationLog()
        await a.watchRegistrations(log)
        await a.send(.script([.start(1), .arm("A", .work(gate: "a"))]))
        #expect(await f.reach("at gate a"))
        let waiter = Task { await a.waitForQuiescence() }
        #expect(await f.reach("registering"))
        #expect(log.all == [true])
        f.open("gate a")
        #expect(await settled(waiter))
    }
}
