import Foundation
import SwiftStateTurns

/// The lane machine's actor. Outputs go under key 0, which `started` starts. A flush records each
/// note in the fixture's trace and opens "flushed `text`"; it sends, asks and posts as its outputs
/// say, as a collaborator between steps would.
actor LaneActor: TurnActor {
    let core: TurnCore<LaneMachine>
    nonisolated let lane: TurnLane<LaneNote>?
    nonisolated let fixture: Fixture
    nonisolated let clock: TestClock
    /// Where each lane wake started, as a count of the machine's log lines.
    nonisolated let wakes = JobLog()
    /// Where each continuation job started, as a count of the machine's log lines.
    nonisolated let jobs = JobLog()
    /// Live: every lane hand-out the core recorded, in order. Replay: the divergences.
    nonisolated let records = LaneRecords()
    /// How deep flushes nest now, and the deepest seen.
    private var flushDepth = 0
    private(set) var deepestFlush = 0

    init(fixture: Fixture, maxReleasesPerBatch: Int, laneCapacity: Int, replay: [LaneRecordEntry<LaneNote>]? = nil) {
        let clock = TestClock(fixture: fixture)
        self.fixture = fixture
        self.clock = clock
        let core = TurnCore(LaneMachine(), queueLimit: 64, maxReleasesPerBatch: maxReleasesPerBatch, clock: clock, laneCapacity: laneCapacity)
        core.onDiagnostic = { event in fixture.observe(event) }
        let wakes = self.wakes
        let jobs = self.jobs
        // Between steps, so the reads are allowed.
        core.onLaneWakeForTesting = { [unowned core] in
            wakes.mark(core.read { $0.log.count })
            fixture.openCounted("wake")
        }
        core.onContinuationJobForTesting = { [unowned core] in
            jobs.mark(core.read { $0.log.count })
            fixture.openCounted("job")
        }
        let records = self.records
        if let replay {
            core.replayReports(replay)
            core.onReplayDivergence = { records.diverged($0) }
        } else {
            core.onReportsTaken = { key, reports, now in records.append(LaneRecordEntry(key: key, reports: reports, now: now)) }
        }
        self.core = core
        self.lane = core.lane
    }

    /// An actor with key 0 started, so its outputs aren't dropped.
    static func started(
        _ fixture: Fixture = Fixture(),
        maxReleasesPerBatch: Int = 64,
        laneCapacity: Int = 8,
        replay: [LaneRecordEntry<LaneNote>]? = nil
    ) async -> LaneActor {
        let actor = LaneActor(fixture: fixture, maxReleasesPerBatch: maxReleasesPerBatch, laneCapacity: laneCapacity, replay: replay)
        await actor.send(.control([.start(0)]))
        return actor
    }

    @concurrent nonisolated func perform(_ effect: LaneMachine.Effect) async -> LaneMachine.Input? {
        switch effect {
        case .work(let label):
            fixture.open("at \(label)")
            await fixture.wait("gate \(label)")
            return .result(label)
        }
    }

    func flush(_ outputs: consuming [LaneMachine.Output]) {
        flushDepth += 1
        deepestFlush = max(deepestFlush, flushDepth)
        defer { flushDepth -= 1 }
        for output in outputs {
            switch output {
            case .note(let text):
                fixture.record(text)
                fixture.open("flushed \(text)")
            case .send(let ops):
                send(.script(ops))
            case .ask(let label):
                _ = query(.ask(label))
            case .askTake(let label):
                _ = query(.take(label))
            case .post(let note):
                _ = post(note)
            }
        }
    }

    /// Sets the lane check's hook: `body` runs at each check, after its watermark is read.
    func onLaneCheck(_ body: (@Sendable () -> Void)?) {
        core.onLaneCheckForTesting = body
    }

    var log: [String] { core.read { $0.log } }
    var stats: TurnStats { core.stats }

    /// The machine's log, cut where each mark in `marks` was made: element 0 is what came before
    /// the first mark, element n what followed mark n.
    func log(cutBy marks: JobLog) -> [[String]] {
        let log = core.read { $0.log }
        var cuts = marks.marks
        cuts.append(log.count)
        var parts = [Array(log[0 ..< cuts[0]])]
        for index in 0 ..< cuts.count - 1 { parts.append(Array(log[cuts[index] ..< cuts[index + 1]])) }
        return parts
    }
}

/// A live lane actor's record, or a replay's divergences.
final class LaneRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [LaneRecordEntry<LaneNote>] = []
    private var divergences: [TurnReplayDivergence] = []

    func append(_ entry: LaneRecordEntry<LaneNote>) {
        lock.withLock { recorded.append(entry) }
    }

    func diverged(_ divergence: TurnReplayDivergence) {
        lock.withLock { divergences.append(divergence) }
    }

    var entries: [LaneRecordEntry<LaneNote>] { lock.withLock { recorded } }
    var diverged: [TurnReplayDivergence] { lock.withLock { divergences } }
}
