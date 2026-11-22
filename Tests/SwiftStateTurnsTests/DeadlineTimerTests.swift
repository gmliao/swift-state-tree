import SwiftStateTurns
import Testing

/// The core's one timer for every deadline (#621 item 2, Notes/plans/2026-11-21-turns-shared-
/// deadline-timer.md §4.3). Time is the test clock's release horizon; every wait is an event
/// ("timer wake #n", "superseded wake #n", "woke deadline N", a diagnostic) under the hang bound.
@Suite("Turn core: the shared deadline timer (#621 item 2)", .timeLimit(.minutes(1)))
struct DeadlineTimerTests {
    @Test("2: one sleeper for every deadline and timer; due entries step in instant then arm order, each in its own batch")
    func oneSleeper() async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f)
        await a.send(.request(1, seconds: 5))
        await a.send(.request(2, seconds: 9))
        await a.send(.request(3, seconds: 9))
        await a.send(.request(4, seconds: 12))
        await a.send(.arm(5, seconds: 7))
        await f.reach("sleeping deadline 5 #1")
        #expect(a.clock.sleeps == 1)
        #expect(await a.timer().starts == 1)
        let readsBefore = a.clock.reads
        a.clock.advance(to: 12)
        await f.reach("timer wake #4")
        #expect(await a.log == [
            "abandoned 1 deadline at 12", "tick 5 at 12", "abandoned 2 deadline at 12", "abandoned 3 deadline at 12",
            "abandoned 4 deadline at 12",
        ])
        // One clock read per fired batch: each reads `now` in its step.
        #expect(a.clock.reads - readsBefore == 5)
        #expect(await a.timer().starts == 1)
        #expect(await a.timer().entries == 0)
    }

    @Test("3: an earlier insert re-arms the sleeper; the superseded sleeper's wake fires nothing")
    func rearmOnEarlierInsert() async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f)
        await a.send(.request(1, seconds: 9))
        await a.send(.request(2, seconds: 5))
        await f.reach("cancelled deadline 9")
        await f.reach("superseded wake #1")
        await f.reach("sleeping deadline 5 #1")
        #expect(a.clock.sleepingUntil == [.seconds(5)])
        a.clock.release(through: 5)
        await f.reach("timer wake #1")
        #expect(await a.log == ["abandoned 2 deadline at 5"])
        a.clock.release(through: 9)
        await f.reach("timer wake #2")
        #expect(await a.log == ["abandoned 2 deadline at 5", "abandoned 1 deadline at 9"])
        let timer = await a.timer()
        #expect(timer.starts == 2)
        #expect(timer.superseded == 1)
    }

    @Test("4: a sleeper superseded after it woke on time fires nothing; the new sleeper fires both in order")
    func supersededAfterWaking() async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f)
        a.clock.holdAfterWake(9)
        await a.send(.request(1, seconds: 9))
        a.clock.release(through: 9)
        // Woken for 9, and held before its hop to the actor.
        await f.reach("woke deadline 9")
        // An earlier timer re-arms: the held sleeper is cancelled, and a new one starts for 5,
        // which returns at once (time is already 9).
        await a.send(.arm(2, seconds: 5))
        f.open("resume deadline 9")
        await f.reach("superseded wake #1")
        await f.reach("timer wake #2")
        #expect(await a.log == ["tick 2 at 9", "abandoned 1 deadline at 9"])
        let timer = await a.timer()
        #expect(timer.starts == 2)
        #expect(timer.superseded == 1)
        #expect(timer.wakes == 2)
    }

    enum Closer: String, CaseIterable, Sendable {
        case cancel, end, supersede, completion, endAll, inItsOwnStep
    }

    @Test("5: an abandoned request's deadline never fires, for each way it closes", arguments: Closer.allCases)
    func closedRequestNeverFires(closer: Closer) async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f)
        switch closer {
        case .cancel: await a.send(.request(1, seconds: 5)); await a.send(.cancel(1))
        case .end: await a.send(.request(1, seconds: 5)); await a.send(.end(1))
        case .supersede: await a.send(.request(1, seconds: 5)); await a.send(.supersede(1))
        case .completion:
            await a.send(.request(1, seconds: 5))
            f.open("work 1")
            await f.reach("out 1 #1")
        case .endAll: await a.send(.request(1, seconds: 5)); await a.send(.teardown)
        case .inItsOwnStep: await a.send(.requestAndCancel(1, seconds: 5))
        }
        a.clock.release(through: 5)
        switch closer {
        case .endAll:
            // `endAll` stopped the timer: its cancelled sleeper's wake is superseded.
            await f.reach("superseded wake #1")
            #expect(f.count(of: "stale deadline") == 0)
        case .inItsOwnStep:
            // Closed before the driver armed it: no entry, no sleeper.
            #expect(await a.timer().starts == 0)
            #expect(a.clock.sleeps == 0)
        default:
            await f.reach("stale deadline #1")
        }
        #expect(await a.log.allSatisfy { !$0.contains("deadline") })
        #expect(await a.timer().entries == 0)
    }

    @Test("5: a completion that lands while the woken timer is held before its hop wins; the wake finds the request closed")
    func completionBeforeHeldWake() async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f)
        a.clock.holdAfterWake(5)
        await a.send(.request(1, seconds: 5))
        a.clock.release(through: 5)
        await f.reach("woke deadline 5")
        f.open("work 1")
        await f.reach("out 1 #1")
        f.open("resume deadline 5")
        await f.reach("stale deadline #1")
        #expect(await a.log == ["completed 1"])
    }

    @Test("6: the ticket is re-checked per entry: an earlier due entry's step that cancels a later one makes it stale at its turn")
    func recheckPerEntry() async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f)
        await a.send(.onAbandonCancel(1, other: 2))
        await a.send(.requests([1, 2], seconds: 5))
        a.clock.release(through: 5)
        await f.reach("stale deadline #1")
        #expect(await a.log == ["abandoned 1 deadline at 5", "abandoned 2 cancelled at 5"])
        #expect(f.count(of: "stale deadline") == 1)
    }

    @Test("7: an entry armed during a wake isn't due in it, even at or before its target")
    func insertDuringWake() async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f)
        // Request 1's abandonment makes request 3 with a zero deadline: due at that batch's now.
        await a.send(.onAbandonRequest(1, other: 3, nanoseconds: 0))
        await a.send(.request(1, seconds: 5))
        a.clock.advance(to: 5)
        await f.reach("timer wake #2")
        #expect(await a.log == ["abandoned 1 deadline at 5", "abandoned 3 deadline at 5"])
        // The first sleep, and the one the first wake's return started for request 3's instant.
        #expect(a.clock.sleeps == 2)
        #expect(await a.timer().wakes == 2)
    }

    @Test("8: a wake steps at most 64 due entries; the rest steps on the next wake, and other work can run before it", arguments: [16, 1])
    func capPerWake(maxReleasesPerBatch: Int) async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f, maxReleasesPerBatch: maxReleasesPerBatch)
        await a.send(.requests(Array(1 ... 66), seconds: 5))
        // The first wake's return sleeps until 5 again: that second sleep is held after it wakes.
        a.clock.holdAfterWake(5, skipping: 1)
        a.clock.release(through: 5)
        await f.reach("timer wake #1")
        // 64 fired in the first wake: the cap doesn't follow `maxReleasesPerBatch`.
        #expect(await a.log.count == 64)
        await a.send(.note("between"))
        f.open("resume deadline 5")
        await f.reach("timer wake #2")
        let log = await a.log
        #expect(log.count == 67)
        #expect(log.firstIndex(of: "between") == 64)
        #expect(await a.timer().wakes == 2)
    }

    @Test("8: stale entries don't count toward the cap: a live entry behind 64 stale ones fires in the same wake")
    func staleEntriesDontFillTheCap() async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f)
        // 64 stale entries due at 5, armed before request 1; 200 live ones at 3600 keep the stale
        // ones under half the heap, so no compaction drops them first.
        _ = await a.sendEach([.requests(Array(100 ..< 164), seconds: 5), .request(1, seconds: 5),
                              .requests(Array(200 ..< 400), seconds: 3600), .cancelEach(Array(100 ..< 164))])
        a.clock.release(through: 5)
        await f.reach("stale deadline #64")
        await f.reach("out 1 #1")
        #expect(await a.log.filter { $0.contains("deadline") } == ["abandoned 1 deadline at 5"])
        #expect(await a.timer().wakes == 1)
    }

    @Test("8: a wake pops at most 256 stale entries; the rest, and a live entry behind them, come on the next wake")
    func stalePopsAreBounded() async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f)
        // 300 closed entries due at 5, then live request 1 at 5; 400 live ones at 3600 keep the
        // closed ones under half the heap, so no compaction drops them.
        _ = await a.sendEach([.requests(Array(100 ..< 400), seconds: 5), .request(1, seconds: 5),
                              .requests(Array(1000 ..< 1400), seconds: 3600), .cancelEach(Array(100 ..< 400))])
        a.clock.holdAfterWake(5, skipping: 1)
        a.clock.release(through: 5)
        await f.reach("timer wake #1")
        // The wake's job has ended once this hop runs.
        #expect(await a.timer().entries == 445)
        #expect(f.count(of: "stale deadline") == 256)
        #expect(await a.log.allSatisfy { !$0.contains("deadline") })
        f.open("resume deadline 5")
        await f.reach("out 1 #1")
        #expect(f.count(of: "stale deadline") == 300)
        #expect(await a.log.filter { $0.contains("deadline") } == ["abandoned 1 deadline at 5"])
        #expect(await a.timer().wakes == 2)
        #expect(await a.timer().entries == 400)
    }

    @Test("8: a wake that finds half the heap stale compacts first: the closed entries due then report nothing")
    func wakeStartCompaction() async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f)
        // 99 closed entries due at 5, with no arm after the cancels, and live request 1 at 5.
        _ = await a.sendEach([.request(1, seconds: 5), .requests(Array(100 ..< 199), seconds: 5), .cancelEach(Array(100 ..< 199))])
        #expect(await a.timer().entries == 100)
        a.clock.release(through: 5)
        await f.reach("out 1 #1")
        #expect(await a.log.filter { $0.contains("deadline") } == ["abandoned 1 deadline at 5"])
        #expect(f.count(of: "stale deadline") == 0)
        #expect(await a.timer().entries == 0)
    }

    @Test("8: a stale head at or before the wake's target is left for the next wake, which reports it")
    func staleHeadAtTargetIsReported() async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f)
        // Tick 1 arms timer 3 at 5; tick 2 replaces it with one at 3600, so its entry at 5 is stale.
        await a.send(.onTickArm(1, labels: [3], seconds: [5]))
        await a.send(.onTickArm(2, labels: [3], seconds: [3600]))
        await a.send(.arm(1, seconds: 5))
        await a.send(.arm(2, seconds: 5))
        a.clock.holdAfterWake(5, skipping: 1)
        a.clock.release(through: 5)
        await f.reach("timer wake #1")
        // Not dropped silently after the wake: still in the heap, beside its replacement.
        #expect(await a.timer().entries == 2)
        #expect(f.count(of: "stale timer") == 0)
        f.open("resume deadline 5")
        await f.reach("stale timer #1")
        #expect(await a.timer().entries == 1)
        #expect(await a.log == ["tick 1 at 5", "tick 2 at 5"])
    }

    @Test("9: stale entries are compacted: the heap stays bounded, the live entry still fires, and order holds after a rebuild")
    func compaction() async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f)
        var inputs: [DeadlineMachine.Input] = []
        for label in 100 ..< 200 { inputs += [.request(label, seconds: 3600), .cancel(label)] }
        inputs.append(.request(1, seconds: 10))
        for label in 200 ..< 300 { inputs += [.request(label, seconds: 3600), .cancel(label)] }
        let counts = await a.sendEach(inputs)
        // At most max(64, 2 × live) + 1 entries, live being 1.
        #expect(counts.max() ?? 0 <= 65)
        // Mixed instants after a rebuild still fire in order.
        await a.send(.request(4, seconds: 8))
        await a.send(.request(2, seconds: 6))
        await a.send(.request(3, seconds: 7))
        a.clock.release(through: 10)
        await f.reach("out 1 #1")
        // The cancels' own abandonments aside: the deadlines, in instant order.
        #expect(await a.log.filter { $0.contains("deadline") } == [
            "abandoned 2 deadline at 10", "abandoned 3 deadline at 10", "abandoned 4 deadline at 10", "abandoned 1 deadline at 10",
        ])
        #expect(f.count(of: "stale deadline") == 0)
    }

    @Test("9: a rebuild that removes the sleeper's target doesn't re-arm it: one wake that steps nothing, then the live entry")
    func compactionWastedHop() async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f)
        await a.send(.request(1, seconds: 5))
        await a.send(.request(2, seconds: 10))
        await a.send(.cancel(1))
        var inputs: [DeadlineMachine.Input] = []
        for label in 100 ..< 170 { inputs += [.request(label, seconds: 3600), .cancel(label)] }
        _ = await a.sendEach(inputs)
        // The rebuild dropped request 1's entry at 5; the sleeper still sleeps until 5.
        await f.reach("sleeping deadline 5 #1")
        #expect(await a.timer().starts == 1)
        #expect(a.clock.sleepingUntil == [.seconds(5)])
        a.clock.release(through: 5)
        await f.reach("timer wake #1")
        // It stepped nothing and reported nothing: the entry was gone. The next sleep is for 10.
        #expect(await a.log.allSatisfy { !$0.contains("deadline") })
        #expect(f.count(of: "stale deadline") == 0)
        #expect(!f.isOpen("cancelled deadline 5"))
        await f.reach("sleeping deadline 10 #1")
        a.clock.release(through: 10)
        await f.reach("timer wake #2")
        #expect(await a.log.filter { $0.contains("deadline") } == ["abandoned 2 deadline at 10"])
        #expect(await a.timer().starts == 1)
    }

    @Test("9: no compaction during a wake: entries closed while outside the heap never leave the count short, and the heap is compacted after it")
    func noCompactionDuringAWake() async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f)
        // Due at 5, in this arm order: 1, 12, then 2 to 11. Request 1's step closes 64 requests in
        // the heap and 2 to 11, which the wake already took, then arms request 3 at 65 (a
        // compaction point, were compactions allowed during a wake). Request 12's step closes 64
        // more in the heap. Request 3 then heads the heap, so the silent head drop can't clear
        // the closed ones behind it: only a compaction can.
        _ = await a.sendEach([
            .onAbandonCancelEach(1, others: Array(200 ..< 264) + Array(2 ..< 12)),
            .onAbandonRequest(1, other: 3, nanoseconds: 60_000_000_000),
            .onAbandonCancelEach(12, others: Array(300 ..< 364)),
            .requests([1, 12] + Array(2 ..< 12), seconds: 5),
            .requests(Array(200 ..< 264) + Array(300 ..< 364), seconds: 3600),
        ])
        a.clock.release(through: 5)
        await f.reach("timer wake #1")
        #expect(await a.log.filter { $0.contains("deadline") } == ["abandoned 1 deadline at 5", "abandoned 12 deadline at 5"])
        // 2 to 11 were reached as stale at their turns.
        #expect(f.count(of: "stale deadline") == 10)
        // Only request 3's entry is left.
        #expect(await a.timer().entries == 1)
        #expect(await a.timer().live == 1)
    }

    @Test("9: the silent drop after a wake shares the stale budget; the closed entries past it are reported at their instant")
    func headDropIsBounded() async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f)
        // Live request 1 at 5, then 200 closed entries at 5 (the wake's stale pops), 300 closed
        // ones at 10 (the silent drop's), and 600 live ones at 3600, which keep the closed ones
        // under half the heap, so no compaction drops them.
        _ = await a.sendEach([.request(1, seconds: 5), .requests(Array(100 ..< 300), seconds: 5),
                              .requests(Array(300 ..< 600), seconds: 10), .requests(Array(1000 ..< 1600), seconds: 3600),
                              .cancelEach(Array(100 ..< 600))])
        a.clock.release(through: 5)
        await f.reach("out 1 #1")
        // 200 reported in the wake; the drop had 56 of the budget left: 244 at 10 remain.
        #expect(f.count(of: "stale deadline") == 200)
        #expect(await a.timer().entries == 844)
        a.clock.release(through: 10)
        await f.reach("stale deadline #444")
        #expect(await a.timer().entries == 600)
    }

    @Test("10: endAll stops the timer: the heap empties, the sleeper is cancelled, and no release steps anything")
    func endAllStopsTheTimer() async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f)
        await a.send(.request(1, seconds: 5))
        await a.send(.request(2, seconds: 9))
        await a.send(.teardown)
        #expect(await a.timer().entries == 0)
        await f.reach("cancelled deadline 5")
        await f.reach("superseded wake #1")
        a.clock.release(through: 3600)
        #expect(await a.log == ["abandoned 1 keyEnded at 0", "abandoned 2 keyEnded at 0"])
        #expect(f.count(of: "stale deadline") == 0)
        #expect(await a.timer().wakes == 0)
    }

    @Test("10: endAll in a wake's first entry: the rest of the wake doesn't run or report, and the old sleeper exits")
    func endAllInsideAWake() async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f)
        // Request 1's abandonment ends everything; requests 2 and 3 are due in the same wake.
        await a.send(.onAbandonTeardown(1))
        await a.send(.requests([1, 2, 3], seconds: 5))
        a.clock.release(through: 5)
        await f.reach("timer wake #1")
        #expect(await a.log == ["abandoned 1 deadline at 5", "abandoned 2 keyEnded at 5", "abandoned 3 keyEnded at 5"])
        // 2 and 3 were taken as live, then closed by the endAll: their turns don't come.
        #expect(f.count(of: "stale deadline") == 0)
        #expect(await a.timer().entries == 0)
        a.clock.release(through: 3600)
        // The sleeper ended with its wake: no second sleep, no further wake.
        #expect(a.clock.sleeps == 1)
        let timer = await a.timer()
        #expect(timer.starts == 1)
        #expect(timer.wakes == 1)
        #expect(timer.superseded == 0)
    }

    @Test("11: a periodic timer reuses the one sleeper")
    func periodicReusesTheSleeper() async {
        let f = Fixture()
        let a = DemoActor(fixture: f)
        await a.send(.startPeriodic(job: 1, periodSeconds: 2))
        for fire in 1 ... 5 {
            a.clock.advance(to: Int64(2 * fire))
            await a.waitForLog(fire)
        }
        // The fifth fire armed the sixth: its sleep is the sixth, on the same task.
        await f.reach("sleeping deadline 12 #1")
        #expect(a.clock.sleeps == 6)
        #expect(await a.deadlineTimer().starts == 1)
    }

    @Test("12: a replaced, ended, superseded or endAll-dropped timer releases its input at once")
    func timerInputReleasedAtOnce() async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f)
        let closers: [(Int) -> DeadlineMachine.Input] = [{ .arm($0, seconds: 3600) }, { .end($0) }, { .supersede($0) }, { _ in .teardown }]
        for (label, closer) in closers.enumerated() {
            weak var probe: Probe?
            do {
                let held = Probe()
                probe = held
                await a.send(.armProbe(label, seconds: 3600, held))
            }
            #expect(probe != nil)
            await a.send(closer(label))
            #expect(probe == nil, "closer \(label)")
        }
    }

    @Test("12: replacing a timer with an earlier one re-arms the sleeper; the old entry is dropped silently")
    func earlierReplacementRearms() async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f)
        await a.send(.arm(1, seconds: 9))
        await f.reach("sleeping deadline 9 #1")
        await a.send(.arm(1, seconds: 5))
        await f.reach("cancelled deadline 9")
        await f.reach("sleeping deadline 5 #1")
        a.clock.release(through: 5)
        await f.reach("timer wake #1")
        #expect(await a.log == ["tick 1 at 5"])
        // The replaced entry at 9 was cleared after the wake: nothing is left to sleep for.
        #expect(await a.timer().entries == 0)
        #expect(await a.timer().starts == 2)
        #expect(f.count(of: "stale timer") == 0)
    }

    @Test("13: entries armed during a wake, earlier than or equal to one still to fire, fire on later wakes: 3@4 on the second, 4@5 on the third")
    func armedDuringAWakeWaitsForALaterOne() async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f)
        await a.send(.onTickArm(1, labels: [3, 4], seconds: [4, 5]))
        await a.send(.arm(1, seconds: 5))
        await a.send(.arm(2, seconds: 5))
        // The first wake returns 4, the second 5. Both sleeps are held after they wake: the one
        // until 4, and the second one until 5 (the first sleep until 5 is the first wake's).
        a.clock.holdAfterWake(4)
        a.clock.holdAfterWake(5, skipping: 1)
        a.clock.release(through: 5)
        await f.reach("timer wake #1")
        await f.reach("woke deadline 4")
        #expect(await a.log == ["tick 1 at 5", "tick 2 at 5"])
        f.open("resume deadline 4")
        await f.reach("timer wake #2")
        #expect(await a.log == ["tick 1 at 5", "tick 2 at 5", "tick 3 at 5"])
        f.open("resume deadline 5")
        await f.reach("timer wake #3")
        #expect(await a.log == ["tick 1 at 5", "tick 2 at 5", "tick 3 at 5", "tick 4 at 5"])
        #expect(await a.timer().wakes == 3)
    }

    @Test("13: one step's entries at one instant: its timer, then its gate deadline, then its request deadline, whatever the call order")
    func sameInstantArmOrder() async {
        let f = Fixture()
        let a = FollowUpActor(fixture: f)
        await a.send(.script([.start(1), .start(2), .start(3),
                              .holdLabelled("R", gate: "r", key: 2, deadlineSeconds: 5),
                              .arm("G", .work(gate: "g", deadlineSeconds: 5)),
                              .timerLabelled("T", key: 3, seconds: 5)]))
        a.clock.release(through: 5)
        #expect(await bounded { await a.waitForQuiescence([.followUps, .requests, .timers]) })
        #expect(await a.snapshot().log == ["armed G", "parked T", "abandoned G deadline", "abandoned R deadline"])
    }

    enum Ambient {
        @TaskLocal static var tag: Int?
    }

    @Test("14: the shared sleeper takes no task-local from the step that armed it")
    func sleeperIsDetached() async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f)
        await a.recordOnFlush { Ambient.tag }
        await Ambient.$tag.withValue(7) {
            await a.send(.request(1, seconds: 5))
        }
        a.clock.release(through: 5)
        await f.reach("out 1 #1")
        #expect(await a.flushReadings == [nil])
    }
}
