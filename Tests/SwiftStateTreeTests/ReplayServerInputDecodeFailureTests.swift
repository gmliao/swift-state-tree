// Tests/SwiftStateTreeTests/ReplayServerInputDecodeFailureTests.swift
//
// Pins how replay reports a recorded server input that doesn't decode, before server inputs are
// decoded at submit and at item building instead of at apply. That change keeps this test green
// unchanged. A failing server input fails alone, inside the tick: replay lists it as refused,
// logs it and applies the inputs after it. Three recorded server inputs, in sequence order:
// - a field of the wrong type (`n` holds a string);
// - a tree nested past the record codec's depth, under a key the type doesn't read;
// - a good one.
// The frame is built in memory: a record file can't hold the deep tree, since the loader refuses
// a tree that deep before replay builds its items.
//
// Decoding the deep tree boxes it recursively, about 4 KB of stack per level in a debug build,
// before the codec's depth check refuses it. Darwin's 544 KiB cooperative-pool thread has no room
// for 129 levels, so the replay runs on a task executor with an 8 MiB thread, which the keeper (a
// default actor) runs on as well (#802).

import Foundation
import Logging
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct ReplaySIDecodeState: StateNodeProtocol {
    @Sync(.broadcast)
    var hits: [String] = []

    public init() {}
}

@Payload
struct ReplaySIDecodeInput: ServerInputPayload {
    let tag: String
    let n: Int
}

/// A task executor that runs every job on one thread with a large stack. The thread carries
/// `marker` in its thread dictionary under `markerKey`, so a job can tell it runs there.
@available(macOS 15.0, *)
final class LargeStackTaskExecutor: TaskExecutor, @unchecked Sendable {
    static let stackSize = 8 << 20
    static let markerKey = "LargeStackTaskExecutor"

    let marker = UUID().uuidString
    private let condition = NSCondition()
    private var jobs: [UnownedJob] = []
    private var stopped = false

    init() {
        let thread = Thread { [self] in
            Thread.current.threadDictionary[Self.markerKey] = marker
            run()
        }
        thread.stackSize = Self.stackSize
        thread.start()
    }

    func enqueue(_ job: consuming ExecutorJob) {
        let job = UnownedJob(job)
        condition.lock()
        jobs.append(job)
        condition.signal()
        condition.unlock()
    }

    /// Ends the thread once its queued jobs have run.
    func stop() {
        condition.lock()
        stopped = true
        condition.signal()
        condition.unlock()
    }

    private func run() {
        while true {
            condition.lock()
            while jobs.isEmpty && !stopped { condition.wait() }
            if jobs.isEmpty { condition.unlock(); return }
            let job = jobs.removeFirst()
            condition.unlock()
            job.runSynchronously(on: asUnownedTaskExecutor())
        }
    }
}

/// The large-stack executor's marker on each thread the input handler ran on (nil off it).
final class ReplaySIStackProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var markers: [String?] = []

    func note() {
        let marker = Thread.current.threadDictionary["LargeStackTaskExecutor"] as? String
        lock.withLock { markers.append(marker) }
    }

    var all: [String?] { lock.withLock { markers } }
}

@Suite("Replay reports a recorded server input that doesn't decode")
struct ReplayServerInputDecodeFailureTests {
    static let landType = "replay-si-decode"

    static func definition(probe: ReplaySIStackProbe? = nil) -> LandDefinition<ReplaySIDecodeState> {
        Land(landType, using: ReplaySIDecodeState.self) {
            Rules {
                HandleServerInput(ReplaySIDecodeInput.self) { (state: inout ReplaySIDecodeState, input: ReplaySIDecodeInput, _: LandContext) in
                    probe?.note()
                    state.hits.append("server:\(input.tag):\(input.n)")
                }
            }
            Lifetime {
                Tick(every: .seconds(3600)) { (_: inout ReplaySIDecodeState, _: LandContext) in }
            }
        }
    }

    static func metadata() -> ReevaluationRecordMetadata {
        ReevaluationRecordMetadata(
            landID: "\(landType):pin",
            landType: landType,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: [:],
            landDefinitionID: landType,
            rngSeed: DeterministicSeed.fromLandID("\(landType):pin"),
            version: ReevaluationRecordVersion.current,
            schemaFingerprint: try? ReevaluationSchemaFingerprint.compute(for: definition())
        )
    }

    /// `tag` and `n` with the given values, and under `extra` an array nested `depth` levels.
    /// Plain `[String: Any]` and `[Any]`, the shape the record loader produces.
    static func tree(tag: Any, n: Any, depth: Int = 0) -> AnyCodable {
        var fields: [String: Any] = ["tag": tag, "n": n]
        if depth > 0 {
            var nested: Any = [Any]()
            for _ in 1..<depth { nested = [nested] as [Any] }
            fields["extra"] = nested
        }
        return AnyCodable(fields)
    }

    static let wrongType = tree(tag: "bad", n: "five")
    static let tooDeep = tree(tag: "deep", n: 1, depth: CanonicalMessagePack.maxDepth + 1)
    static let good = tree(tag: "ok", n: 2)

    struct Replayed {
        let hits: [String]
        let mismatch: String?
        let refusals: [(level: Logger.Level, message: String, metadata: Logger.Metadata)]
    }

    /// Replays tick 0 of a frame holding `payloads` as server inputs (sequence = index), comparing
    /// the inputs replay refuses with the frame's `rejected` list.
    static func replay(_ payloads: [AnyCodable], rejected: [Int64], probe: ReplaySIStackProbe? = nil) async throws -> Replayed {
        let inputs = payloads.enumerated().map { index, payload in
            ReevaluationRecordedServerInput(
                sequence: Int64(index),
                typeIdentifier: String(describing: ReplaySIDecodeInput.self),
                payload: payload,
                resolvedAtTick: 0
            )
        }
        let frame = ReevaluationTickFrame(
            tickId: 0, actions: [], clientEvents: [], lifecycleEvents: [],
            serverInputs: inputs, rejected: rejected
        )
        let logs = ResolverReplayLogRecords()
        let keeper = LandKeeper<ReplaySIDecodeState>(
            definition: definition(probe: probe),
            initialState: ReplaySIDecodeState(),
            mode: .reevaluation,
            reevaluationSource: JSONReevaluationSource(metadata: metadata(), frames: [frame]),
            autoStartLoops: false,
            logger: Logger(label: "replay-si-decode") { _ in ResolverReplayLogHandler(records: logs) }
        )
        // As for a record from 3.5 on, which lists every refused input.
        await keeper.setReplayRecordsRejected(true)
        await keeper.stepTickOnce()
        return Replayed(
            hits: await keeper.currentState().hits,
            mismatch: await keeper.takeRecordedPassMismatch(for: 0),
            refusals: logs.all.filter { $0.level == .error && $0.message.hasPrefix("Input refused") }
        )
    }

    /// Runs `body` on the large-stack executor, after a shallow replay proves the handler runs
    /// on that executor's thread: the deep tree is never decoded on a pool thread.
    @available(macOS 15.0, *)
    static func onLargeStack(_ body: () async throws -> Void) async throws {
        let executor = LargeStackTaskExecutor()
        defer { executor.stop() }
        try await withTaskExecutorPreference(executor) {
            let probe = ReplaySIStackProbe()
            let shallow = try await replay([good], rejected: [], probe: probe)
            #expect(shallow.hits == ["server:ok:2"])
            try #require(probe.all == [executor.marker])
            try await body()
        }
    }

    static let inputs = [wrongType, tooDeep, good]

    // Task executors need macOS 15: below it, the tests are skipped, not passed.
    @available(macOS 15.0, *)
    @Test("A wrong-type and a too-deep server input each fail alone, are listed as refused and logged with the codec's error text; the good one applies")
    func replayServerInputDecodeFailureIsReportedAsBefore() async throws {
        try await Self.onLargeStack {
            // Both bad inputs are recorded before their decode fails, so replay lists them as
            // refused: a frame that lists them both matches.
            let replayed = try await Self.replay(Self.inputs, rejected: [0, 1])
            #expect(replayed.hits == ["server:ok:2"])
            #expect(replayed.mismatch == nil, "\(replayed.mismatch ?? "")")
            #expect(replayed.refusals.map { $0.metadata["sequence"] } == [.stringConvertible(0), .stringConvertible(1)])
            // Today's errors: the record codec's, a type mismatch and its own depth refusal
            // (`CanonicalMessagePackError.nestingTooDeep`, not `PayloadNesting.TooDeep`). The deep
            // tree and the text follow `maxDepth` on purpose: the pin is "refused by the record
            // codec's own limit", whatever that limit is; a change to the limit is its own change.
            #expect(replayed.refusals.map { $0.metadata["error"] } == [
                .string("canonical MessagePack: expected Int at n"),
                .string("canonical MessagePack: nested deeper than \(CanonicalMessagePack.maxDepth)"),
            ])
        }
    }

    @available(macOS 15.0, *)
    @Test("Control: a frame that lists neither bad input as refused reports a divergence for tick 0")
    func frameListingNoRefusalDiverges() async throws {
        try await Self.onLargeStack {
            let replayed = try await Self.replay(Self.inputs, rejected: [])
            // The comparison runs on this land: the `mismatch == nil` above can fail.
            #expect(replayed.mismatch == "tick 0: input 0 was applied live and rejected in replay")
            #expect(replayed.hits == ["server:ok:2"])
        }
    }
}
