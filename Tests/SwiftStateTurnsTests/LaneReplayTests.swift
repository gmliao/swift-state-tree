import Foundation
import SwiftStateTurns
import Testing

/// Test 13 of the post lane's plan (§3.9): each case runs live, recording the lane's hand-outs,
/// then replays the same inputs from the record with nothing posted, and the two logs match.
@Suite("Lane replay")
struct LaneReplayTests {
    /// Runs `inputs` live (with `posting` true) and returns the log and the record; then replays
    /// them from `record` (the live record unless given) and returns the replay's log and
    /// divergences. `inputs` posts only when `posting` is true.
    static func liveThenReplay(
        maxReleasesPerBatch: Int = 64,
        edit: ([LaneRecordEntry<LaneNote>]) -> [LaneRecordEntry<LaneNote>] = { $0 },
        _ inputs: @escaping (LaneActor, Bool) async -> Void
    ) async -> (live: [String], replayed: [String], record: [LaneRecordEntry<LaneNote>], diverged: [TurnReplayDivergence]) {
        let live = await LaneActor.started(maxReleasesPerBatch: maxReleasesPerBatch)
        await inputs(live, true)
        let record = live.records.entries
        let replay = await LaneActor.started(maxReleasesPerBatch: maxReleasesPerBatch, replay: edit(record))
        await inputs(replay, false)
        await replay.finishReplay()
        return (await live.log, await replay.log, record, replay.records.diverged)
    }

    /// Runs `body` with the step hook posting `note` when `posting`, and with no hook otherwise.
    static func posting(_ a: LaneActor, _ on: Bool, _ note: LaneNote, _ body: () async -> Void) async {
        let hook: (@Sendable () -> Void)? = on ? { @Sendable in _ = a.post(note) } : nil
        await StepHooks.$duringStep.withValue(hook) {
            await body()
        }
    }

    @Test("13a: a mid-step take in an input's step replays")
    func takeInInput() async {
        let run = await Self.liveThenReplay { a, on in
            await Self.posting(a, on, LaneNote("R")) { await a.send(.script([.hook, .take])) }
        }
        #expect(run.live == ["took R"])
        #expect(run.replayed == run.live)
        #expect(run.record.map(\.key) == [.inside(step: 1, take: 0)])
        #expect(run.diverged.isEmpty)
    }

    @Test("13b: a mid-step take in a follow-up's step replays")
    func takeInFollowUp() async {
        let run = await Self.liveThenReplay { a, on in
            // The gate's task inherits the hook, so the follow-up's step posts.
            await Self.posting(a, on, LaneNote("R")) {
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
            await Self.posting(a, on, LaneNote("R")) { await a.send(.script([.hook, .askTake("Q")])) }
        }
        #expect(run.live == ["answer Q took R"])
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13d: a driver-stepped report ahead of a direct input replays")
    func reportAheadOfInput() async {
        let run = await Self.liveThenReplay { a, on in
            if on { await LaneTests.heldPost(a, LaneNote("R")) }
            await a.send(.script([.log("X")]))
            a.fixture.open("wake R")
        }
        #expect(run.live == ["report R", "X"])
        #expect(run.replayed == run.live)
        #expect(run.record.map(\.key) == [.before(step: 1, index: 0)])
        #expect(run.diverged.isEmpty)
    }

    @Test("13e: a report stepped between two releases in one segment replays")
    func reportBetweenReleases() async {
        let run = await Self.liveThenReplay(maxReleasesPerBatch: 2) { a, on in
            await a.send(.script([.start(1), .hold(gate: "h")]))
            await a.send(.parked("P1", [.hook]))
            await a.send(.parked("P2"))
            // The hold's request stays parked at its gate: its late result would race the logs.
            await Self.posting(a, on, LaneNote("R")) { await a.send(.control([.end(1)])) }
        }
        #expect(run.live == ["abandoned h keyEnded", "parked P1", "report R", "parked P2"])
        #expect(run.replayed == run.live)
        // Keyed before P2's step, not before the entry's.
        #expect(run.record.map(\.key) == [.before(step: 5, index: 0)])
        #expect(run.diverged.isEmpty)
    }

    @Test("13f: trailing reports replay: one a wake stepped with no turn due, at the next dispatch with its own now; one after the last input, at finishReplay")
    func trailingReports() async {
        let run = await Self.liveThenReplay { a, on in
            a.clock.set(seconds: 10)
            if on {
                _ = a.post(LaneNote("W", then: [.readNow]))
                await a.fixture.reach("wake #1")
            }
            a.clock.set(seconds: 20)
            await a.send(.script([.readNow]))
            // The last input leaves nothing dirty, so no check runs after its step: in replay,
            // only finishReplay steps E. (After a dirty step, the segment's next check would.)
            await a.send(.script([.log("Z")]))
            if on {
                _ = a.post(LaneNote("E", then: [.log("E")]))
                await a.fixture.reach("wake #2")
            }
        }
        #expect(run.live == ["report W", "now 10", "now 20", "Z", "report E", "E"])
        // W steps at the input's check with the wake's now; the input still reads its own.
        #expect(run.replayed == run.live)
        #expect(run.diverged.isEmpty)
    }

    @Test("13: a replay with an extra take staged fails as unconsumed; an extra report staged past the last input, as leftover; a removed take changes the output")
    func divergences() async {
        let inputs: (LaneActor, Bool) async -> Void = { a, on in
            await Self.posting(a, on, LaneNote("R")) { await a.send(.script([.hook, .take])) }
            await a.send(.script([.log("next")]))
        }
        let extraTake = await Self.liveThenReplay(edit: { $0 + [LaneRecordEntry(key: .inside(step: 1, take: 1), reports: [LaneNote("X")], now: nil)] }, inputs)
        #expect(extraTake.diverged == [.unconsumed(.inside(step: 1, take: 1))])
        let extraReport = await Self.liveThenReplay(edit: { $0 + [LaneRecordEntry(key: .before(step: 9, index: 0), reports: [LaneNote("X")], now: nil)] }, inputs)
        #expect(extraReport.diverged == [.leftover(.before(step: 9, index: 0))])
        let removed = await Self.liveThenReplay(edit: { _ in [] }, inputs)
        #expect(removed.diverged.isEmpty)
        #expect(removed.live == ["took R", "next"])
        #expect(removed.replayed == ["took", "next"])
    }
}
