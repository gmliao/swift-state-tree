// Tests/SwiftStateTreeTests/ReplayServerInputDecodeFailureTests.swift
//
// Pins how replay reports a recorded server input that doesn't decode, before server inputs are
// decoded at submit and at item building instead of at apply. That change keeps this test green
// unchanged. A failing server input fails alone, inside the tick: replay lists it as refused,
// logs it and applies the inputs after it. Three recorded server inputs, in sequence order:
// - a field of the wrong type (`n` holds a string);
// - a tree nested past the record codec's depth, under a key the type doesn't read;
// - a good one.
// The frame is built in memory. From 3.7 (#700 K1a) each payload is its canonical MessagePack
// bytes; the deep one is written by hand, since the encoder refuses a tree that deep.
//
// The record codec's reader refuses the deep tree on the way down, at level `maxDepth + 1`, so
// its stack doesn't grow with the input past the limit (#804). In a debug build the deepest point
// of this replay is about 250 KiB below the thread's top on Darwin (#874): its deepest sampled
// point, the reader's refusal. That fits a 524 KiB cooperative-pool thread. `onLargeStack` measures it on every run and fails above
// `stackBound`, so a regression in the codec or in the replay frames above it fails a test
// instead of overflowing a pool thread.
//
// The replay still prefers a task executor with an 8 MiB thread, as headroom, not as a
// precondition: a re-evaluation keeper's legacy tick can resume off a preferred executor (#872,
// #874; it goes with #612), and the tests are correct on either thread.

import Foundation
import Logging
import Testing
@testable import SwiftStateTree
#if canImport(WinSDK)
import WinSDK
#endif

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

#if DEBUG
/// The address of a local in the caller's frame: the stack's current depth.
@inline(never)
private func replaySIStackAddress() -> Int {
    var local = 0
    return withUnsafeMutablePointer(to: &local) { Int(bitPattern: $0) }
}

#if canImport(Glibc)
/// glibc's `pthread_getattr_np`, a GNU extension Swift's Glibc module doesn't expose, looked up
/// at run time and called with the C convention. Nil when the lookup fails: the stack can't be
/// measured there.
private typealias ReplaySIPthreadGetattrNP = @convention(c) (pthread_t, UnsafeMutablePointer<pthread_attr_t>) -> Int32
private let replaySIPthreadGetattrNP: ReplaySIPthreadGetattrNP? = {
    guard let symbol = dlsym(nil, "pthread_getattr_np") else { return nil }
    return unsafeBitCast(symbol, to: ReplaySIPthreadGetattrNP.self)
}()
#endif

/// Whether `replaySIThreadStackTop` can find the current thread's stack top here. Where it
/// can't, the replay runs and its assertions hold, but the stack isn't measured.
private let replaySICanMeasureStack: Bool = {
    #if canImport(Darwin) || canImport(WinSDK)
    return true
    #elseif canImport(Glibc)
    return replaySIPthreadGetattrNP != nil
    #else
    return false
    #endif
}()

/// The top (highest address) of the current thread's stack. A per-platform call: Darwin has
/// `pthread_get_stackaddr_np`, glibc has `pthread_getattr_np` (looked up above), Windows has
/// `GetCurrentThreadStackLimits`, and Foundation has none of them.
private func replaySIThreadStackTop() -> Int? {
    #if canImport(Darwin)
    return Int(bitPattern: pthread_get_stackaddr_np(pthread_self()))
    #elseif canImport(Glibc)
    var attributes = pthread_attr_t()
    guard let getattr = replaySIPthreadGetattrNP, getattr(pthread_self(), &attributes) == 0 else { return nil }
    defer { pthread_attr_destroy(&attributes) }
    var base: UnsafeMutableRawPointer?
    var size = 0
    guard pthread_attr_getstack(&attributes, &base, &size) == 0, let base else { return nil }
    return Int(bitPattern: base) + size
    #elseif canImport(WinSDK)
    var low: ULONG_PTR = 0
    var high: ULONG_PTR = 0
    GetCurrentThreadStackLimits(&low, &high)
    return Int(bitPattern: UInt(high))
    #else
    return nil
    #endif
}

/// The most stack the codec's probe points saw in use, measured from the top of the thread each
/// ran on, whichever thread that was; and how often the reader's depth refusal was sampled.
final class ReplaySIStackReach: @unchecked Sendable {
    private let lock = NSLock()
    private var deepest = 0
    private var notes = 0
    private var refusals = 0

    func note() { record(refusal: false) }

    /// The reader's refusal of the deep tree: the deepest sampled point.
    func noteRefusal() { record(refusal: true) }

    /// One sample, in one locked update: a refusal counts only when its depth was measured, so
    /// `refusalCount > 0` can't hold with nothing measured.
    private func record(refusal: Bool) {
        guard let top = replaySIThreadStackTop() else { return }
        let used = top - replaySIStackAddress()
        lock.withLock {
            deepest = max(deepest, used)
            notes += 1
            if refusal { refusals += 1 }
        }
    }

    var bytes: Int { lock.withLock { deepest } }
    var count: Int { lock.withLock { notes } }
    var refusalCount: Int { lock.withLock { refusals } }
}
#endif

@Suite("Replay reports a recorded server input that doesn't decode")
struct ReplayServerInputDecodeFailureTests {
    static let landType = "replay-si-decode"

    static func definition() -> LandDefinition<ReplaySIDecodeState> {
        Land(landType, using: ReplaySIDecodeState.self) {
            Rules {
                HandleServerInput(ReplaySIDecodeInput.self) { state, input, _ in
                    state.hits.append("server:\(input.tag):\(input.n)")
                }
            }
            Lifetime {
                Tick(every: .seconds(3600)) { _, _ in }
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

    /// The canonical MessagePack bytes of a map of `tag` and `n` with the given values, and under
    /// `extra` an array nested `depth` levels, written by hand (keys in byte order).
    static func tree(tag: Any, n: Any, depth: Int = 0) -> Data {
        func key(_ name: String) -> [UInt8] { [0xa0 | UInt8(name.utf8.count)] + Array(name.utf8) }
        var bytes: [UInt8] = [depth > 0 ? 0x83 : 0x82]
        if depth > 0 {
            bytes += key("extra") + [UInt8](repeating: 0x91, count: depth - 1) + [0x90]
        }
        bytes += key("n") + (try! CanonicalMessagePack.encode(AnyCodable(n)))
        bytes += key("tag") + (try! CanonicalMessagePack.encode(AnyCodable(tag)))
        return Data(bytes)
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
    static func replay(_ payloads: [Data], rejected: [Int64]) async throws -> Replayed {
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
            definition: definition(),
            initialState: ReplaySIDecodeState(),
            mode: .reevaluation,
            reevaluationSource: JSONReevaluationSource(metadata: metadata(), frames: [frame]),
            autoStartLoops: false,
            logger: Logger(label: "replay-si-decode") { _ in ResolverReplayLogHandler(records: logs) }
        )
        // Hygiene (#872): removes the keeper's start-up tasks, which don't inherit the caller's
        // task executor, as a source of pool-thread drains. It is not a guarantee: the tick can
        // still resume off the executor's thread (#874), which `stackBound` allows for.
        await keeper.awaitInitialization()
        _ = await keeper.currentState()
        // As for a record from 3.5 on, which lists every refused input.
        await keeper.setReplayRecordsRejected(true)
        await keeper.stepTickOnce()
        return Replayed(
            hits: await keeper.currentState().hits,
            mismatch: await keeper.takeRecordedPassMismatch(for: 0),
            refusals: logs.all.filter { $0.level == .error && $0.message.hasPrefix("Input refused") }
        )
    }

    /// The most stack the replay may use, from the thread's top, in a debug build (#874): three
    /// quarters of a Darwin cooperative-pool thread's 524 KiB (`pthread_get_stacksize_np`). The
    /// quarter held back covers what the samples miss (the refusal's boxing and unwinding, the
    /// logging after it) and frame growth between toolchains. A pool worker's job starts no
    /// deeper than the large-stack executor's run loop does (624 bytes against 1632), so nothing
    /// more is taken off.
    static let stackBound = 393 << 10

    /// Runs `body` preferring the large-stack executor (headroom, not a precondition; see the
    /// header). In a debug build, every codec probe point notes how much of its thread's stack
    /// is in use, and the deepest sampled point must stay under `stackBound`. The reader's
    /// refusal must be among the samples, so the bound can't pass on the shallow decodes alone.
    @available(macOS 15.0, *)
    static func onLargeStack(_ body: () async throws -> Void) async throws {
        let executor = LargeStackTaskExecutor()
        defer { executor.stop() }
        try await withTaskExecutorPreference(executor) {
            #if DEBUG
            let reach = ReplaySIStackReach()
            try await CanonicalMessagePack.$stackProbeForTesting.withValue({ reach.note() }) {
                try await CanonicalMessagePack.$depthRefusalProbeForTesting.withValue({ reach.noteRefusal() }) {
                    try await body()
                }
            }
            // A platform `replaySIThreadStackTop` doesn't know: the replay's own assertions ran,
            // and there is nothing measured to check.
            guard replaySICanMeasureStack else { return }
            print("replay-si-decode: deepest sampled stack \(reach.bytes) bytes (\(reach.bytes / 1024) KiB) of \(stackBound / 1024) KiB, \(reach.count) probe points, \(reach.refusalCount) depth refusals")
            #expect(reach.refusalCount > 0, "the reader's depth refusal wasn't sampled: the bound would check only the shallow decodes")
            #expect(reach.bytes < stackBound, "the replay used \(reach.bytes / 1024) KiB of its thread's stack, over \(stackBound / 1024) KiB")
            #else
            try await body()
            #endif
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
