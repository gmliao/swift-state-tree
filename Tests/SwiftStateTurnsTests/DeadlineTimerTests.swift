import SwiftStateTurns
import Testing

/// The core's one timer for every deadline (#621 item 2, Notes/plans/2026-11-21-turns-shared-
/// deadline-timer.md §4.3). Time is the test clock's release horizon; every wait is an event
/// ("timer wake #n", "superseded wake #n", "woke deadline N", a diagnostic) under the hang bound.
@Suite("Turn core: the shared deadline timer (#621 item 2)", .timeLimit(.minutes(1)))
struct DeadlineTimerTests {
    @Test("2: one sleeper for every deadline; due entries step in instant then arm order, each in its own batch")
    func oneSleeper() async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f)
        await a.send(.request(1, seconds: 5))
        await a.send(.request(2, seconds: 9))
        await a.send(.request(3, seconds: 9))
        await a.send(.request(4, seconds: 12))
        await f.reach("sleeping deadline 5 #1")
        #expect(a.clock.sleeps == 1)
        #expect(await a.timer().starts == 1)
        let readsBefore = a.clock.reads
        a.clock.advance(to: 12)
        await f.reach("timer wake #3")
        #expect(await a.log == [
            "abandoned 1 deadline at 12", "abandoned 2 deadline at 12", "abandoned 3 deadline at 12", "abandoned 4 deadline at 12",
        ])
        // One clock read per fired batch: each reads `now` in its abandonment step.
        #expect(a.clock.reads - readsBefore == 4)
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
        #expect(await a.log == ["abandoned 2 deadline at 0"])
        a.clock.release(through: 9)
        await f.reach("timer wake #2")
        #expect(await a.log == ["abandoned 2 deadline at 0", "abandoned 1 deadline at 0"])
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
        // An earlier deadline re-arms: the held sleeper is cancelled, and a new one starts for 5.
        await a.send(.request(2, seconds: 5))
        f.open("resume deadline 9")
        await f.reach("superseded wake #1")
        await f.reach("timer wake #2")
        #expect(await a.log == ["abandoned 2 deadline at 0", "abandoned 1 deadline at 0"])
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
        #expect(await a.log == ["abandoned 1 deadline at 0", "abandoned 2 cancelled at 0"])
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

    @Test("8: a wake steps at most 64 due entries; the rest steps on the next wake, after other entries", arguments: [16, 1])
    func capPerWake(maxReleasesPerBatch: Int) async {
        let f = Fixture()
        let a = DeadlineActor(fixture: f, maxReleasesPerBatch: maxReleasesPerBatch)
        await a.send(.requests(Array(1 ... 66), seconds: 5))
        await a.onOutputSendLater(1, "between")
        a.clock.release(through: 5)
        await f.reach("timer wake #2")
        let log = await a.log
        #expect(log.count == 67)
        // The note, queued by the first fire's flush as a new actor job, steps after 64 fires and
        // before the 65th: the cap doesn't follow `maxReleasesPerBatch`.
        #expect(log.firstIndex(of: "between") == 64)
        #expect(await a.timer().wakes == 2)
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
            "abandoned 2 deadline at 0", "abandoned 3 deadline at 0", "abandoned 4 deadline at 0", "abandoned 1 deadline at 0",
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
        #expect(await a.log.filter { $0.contains("deadline") } == ["abandoned 2 deadline at 0"])
        #expect(await a.timer().starts == 1)
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
}
