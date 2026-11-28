import Foundation
import SwiftStateTurns

/// The mailbox machine's actor. Outputs go under key 0, which `started` starts. A flush records each
/// note in the fixture's trace and opens "flushed `text`"; it sends, asks and posts as its outputs
/// say, as a collaborator between steps would.
actor MailboxActor: TurnActor {
    let core: TurnCore<MailboxMachine>
    nonisolated let mailbox: TurnMailbox<MailNote>?
    nonisolated let fixture: Fixture
    nonisolated let clock: TestClock
    /// Where each mailbox wake started, as a count of the machine's log lines.
    nonisolated let wakes = JobLog()
    /// Where each continuation job started, as a count of the machine's log lines.
    nonisolated let jobs = JobLog()
    /// Live: every mailbox hand-out the core recorded, in order. Replay: the divergences.
    nonisolated let records = MailRecords()
    /// How deep flushes nest now, and the deepest seen.
    private var flushDepth = 0
    private(set) var deepestFlush = 0
    /// Runs once at the start of the next continuation job, before it captures its due
    /// follow-ups.
    nonisolated let atNextJob = OneShot()
    /// Runs once at the next entry's boundary (after its mailbox take, before its own work).
    nonisolated let atNextBoundary = OneShot()

    init(fixture: Fixture, maxReleasesPerBatch: Int, mailboxCapacity: Int, queueLimit: Int = 64, replay: [MailRecordEntry<MailNote>]? = nil, divergenceHook: Bool = true) {
        let clock = TestClock(fixture: fixture)
        self.fixture = fixture
        self.clock = clock
        let core = TurnCore(MailboxMachine(), queueLimit: queueLimit, maxReleasesPerBatch: maxReleasesPerBatch, clock: clock, mailboxCapacity: mailboxCapacity)
        core.onDiagnostic = { event in fixture.observe(event) }
        let wakes = self.wakes
        let jobs = self.jobs
        // Between steps, so the reads are allowed.
        core.onMailboxWakeForTesting = { [unowned core] in
            wakes.mark(core.read { $0.log.count })
            fixture.openCounted("wake")
        }
        let atNextJob = self.atNextJob
        core.onContinuationJobForTesting = { [unowned core] in
            jobs.mark(core.read { $0.log.count })
            fixture.openCounted("job")
            atNextJob.take()?()
        }
        let atNextBoundary = self.atNextBoundary
        core.onEntryBoundaryForTesting = { atNextBoundary.take()?() }
        let records = self.records
        if let replay {
            core.replayMail(replay)
            // Without the hook, a divergence stops the process.
            if divergenceHook { core.onReplayDivergence = { records.diverged($0) } }
        } else {
            core.onMailTaken = { key, mail, now in records.append(MailRecordEntry(key: key, mail: mail, now: now)) }
        }
        self.core = core
        self.mailbox = core.mailbox
    }

    /// An actor with key 0 started, so its outputs aren't dropped.
    static func started(
        _ fixture: Fixture = Fixture(),
        maxReleasesPerBatch: Int = 64,
        mailboxCapacity: Int = 8,
        queueLimit: Int = 64,
        replay: [MailRecordEntry<MailNote>]? = nil
    ) async -> MailboxActor {
        let actor = MailboxActor(fixture: fixture, maxReleasesPerBatch: maxReleasesPerBatch, mailboxCapacity: mailboxCapacity, queueLimit: queueLimit, replay: replay)
        await actor.send(.control([.start(0)]))
        return actor
    }

    @concurrent nonisolated func perform(_ effect: MailboxMachine.Effect) async -> MailboxMachine.Input? {
        switch effect {
        case .work(let label):
            fixture.open("at \(label)")
            // A gate whose label starts with "cancel" honours a cancellation and returns nil
            // then (the contract's mailbox rule: a replay sees the same completion).
            if label.hasPrefix("cancel") {
                return await fixture.waitUnlessCancelled("gate \(label)") ? .result(label) : nil
            }
            await fixture.wait("gate \(label)")
            // A gate whose label starts with "nil" returns no input.
            return label.hasPrefix("nil") ? nil : .result(label)
        }
    }

    func flush(_ outputs: consuming [MailboxMachine.Output]) {
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

    /// Holds every remainder wake (the epilogue's, for mail a spent budget left) before it reaches
    /// the actor. Each opens "remainder #n" as the epilogue schedules it, then waits for
    /// "remainder go".
    func holdRemainderWakes() {
        let fixture = self.fixture
        core.onRemainderWakeForTesting = {
            fixture.openCounted("remainder")
            return { await fixture.wait("remainder go") }
        }
    }

    /// Installs a replay on a core that already took entries: it must stop the process.
    func installReplayForTesting(_ entries: [MailRecordEntry<MailNote>]) {
        core.replayMail(entries)
    }

    /// Posts, then installs a replay in the same actor job, before the post's wake can run: it
    /// must stop the process.
    func postThenInstallReplayForTesting() {
        _ = post(MailNote("M"))
        core.replayMail([])
    }

    /// Asks a query from inside a read: it must stop the process on the open read.
    func queryInsideReadForTesting() {
        _ = core.read { _ in self.query(.ask("Q")) }
    }

    /// Sets the mailbox check's hook: `body` runs at each check, after its watermark is read.
    func onMailboxCheck(_ body: (@Sendable () -> Void)?) {
        core.onMailboxCheckForTesting = body
    }

    var log: [String] { core.read { $0.log } }
    var stats: TurnStats { core.stats }
    /// Tracked workers with a handle now.
    var workers: Int { core.workersForTesting }
    /// Entries in the core's timer, live or stale.
    var deadlineEntries: Int { core.deadlineEntriesForTesting }

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

/// A live mailbox actor's record, or a replay's divergences.
final class MailRecords: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [MailRecordEntry<MailNote>] = []
    private var divergences: [TurnReplayDivergence] = []

    func append(_ entry: MailRecordEntry<MailNote>) {
        lock.withLock { recorded.append(entry) }
    }

    func diverged(_ divergence: TurnReplayDivergence) {
        lock.withLock { divergences.append(divergence) }
    }

    var entries: [MailRecordEntry<MailNote>] { lock.withLock { recorded } }
    var diverged: [TurnReplayDivergence] { lock.withLock { divergences } }
}

/// A closure set from a test and taken once, from any thread.
final class OneShot: @unchecked Sendable {
    private let lock = NSLock()
    private var body: (@Sendable () -> Void)?

    func set(_ body: @escaping @Sendable () -> Void) { lock.withLock { self.body = body } }

    func take() -> (@Sendable () -> Void)? {
        lock.withLock {
            defer { body = nil }
            return body
        }
    }
}
