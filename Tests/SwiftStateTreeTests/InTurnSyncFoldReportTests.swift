// Tests/SwiftStateTreeTests/InTurnSyncFoldReportTests.swift
//
// The keeper reports each in-turn sync fold to its transport (`noteInTurnSyncFold`) when the tick
// turn that carries it starts, once per turn (#232): overdue when the tick's deadline had passed
// at the fold, and with the turn's lateness against that deadline. Only when the transport
// records folds (`recordsInTurnSyncFolds`, read when the transport is attached).

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct FoldReportState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0

    public init() {}
}

/// Ticks and syncs hourly: the loops exist (the fold needs a tick task) but never fire.
private func foldReportLand() -> LandDefinition<FoldReportState> {
    Land("fold-report-test", using: FoldReportState.self) {
        Lifetime {
            Tick(every: .seconds(3600)) { state, _ in
                state.ticks += 1
            }
            StateSync(every: .seconds(3600)) { _, _ in }
        }
    }
}

@Payload
struct FoldTickEvent: ServerEventPayload {
    let ticks: Int
}

/// `foldReportLand` whose tick handler emits an event: a replay that runs a tick the live
/// keeper skipped shows it as a server-event mismatch.
func foldReportLandEmitting() -> LandDefinition<FoldReportState> {
    Land("fold-report-test", using: FoldReportState.self) {
        ServerEvents { Register(FoldTickEvent.self) }
        Lifetime {
            Tick(every: .seconds(3600)) { state, ctx in
                state.ticks += 1
                ctx.emitEvent(FoldTickEvent(ticks: state.ticks), to: .all)
            }
            StateSync(every: .seconds(3600)) { _, _ in }
        }
    }
}

/// `foldReportLand` with an OnJoin: a join queues its OnJoin input, which the next tick turn
/// applies.
private func foldReportLandWithOnJoin() -> LandDefinition<FoldReportState> {
    Land("fold-report-test", using: FoldReportState.self) {
        Rules {
            OnJoin { _, _ in }
        }
        Lifetime {
            Tick(every: .seconds(3600)) { state, _ in
                state.ticks += 1
            }
            StateSync(every: .seconds(3600)) { _, _ in }
        }
    }
}

/// In-turn transport that records the folds it is told about.
final class FoldRecordingTransport: LandKeeperTransport, @unchecked Sendable {
    /// The port call of a tick turn that calls back into the keeper, once armed (#700 K1b-5a
    /// step 2).
    enum Reentry {
        case none
        /// `noteInTurnSyncFold`, at the tick turn's start.
        case foldNote
        /// `hasJoinsAwaitingSync`, the tick's join-sync read.
        case joinsRead
        /// `noteInTurnJoinSyncTick`, once the tick counted a join sync.
        case joinSyncTickNote
        /// The nth port call made during a turn body, whichever it is (`armNthCallInBody`).
        case nthCallInBody
        /// `refusesResolvedJoin`, a reporting join's stale-join refusal (#700 K1b-5b J2).
        case staleRefusal
    }

    private let lock = NSLock()
    private var notes: [InTurnSyncFold] = []
    private var eventSequences: [Int64?] = []
    private var deferNextSyncs = 0
    private var syncPhases: [InTurnSyncResult] = []
    private var phasesRun = 0
    private var reentry = Reentry.none
    private var joinsWait = false
    private var nthTarget = 0
    private var callsInBody = 0
    private var reenteredNth = false
    private weak var keeper: LandKeeper<FoldReportState>?
    private var reentersAtFirstPhaseQuery = false
    private var phaseQueriesToSkip = 0
    let records: Bool

    /// `reentersAtFirstPhaseQuery`: the first `runsSyncPhaseInTurn(of:)` asked during a turn body
    /// re-enters the keeper that asked, so a body that runs before the test holds the keeper
    /// (initialization, which the keeper starts from its `init`) can be refused (#901). The
    /// keeper's `init` asks once, off its actor, before it starts the initialization
    /// (`refuseTransportWithoutInTurnPhase`, LandKeeper.swift:636 at #896's head 1ea3b13b): that
    /// query is skipped, and every later one comes from the keeper's actor.
    init(records: Bool, reentersAtFirstPhaseQuery: Bool = false) {
        self.records = records
        self.reentersAtFirstPhaseQuery = reentersAtFirstPhaseQuery
        self.phaseQueriesToSkip = reentersAtFirstPhaseQuery ? 1 : 0
    }

    var folds: [InTurnSyncFold] { lock.withLock { notes } }
    /// The output sequence of every event a sync phase was given, in order.
    var receivedEventSequences: [Int64?] { lock.withLock { eventSequences } }
    /// How many sync phases the keeper ran, requested or not.
    var phaseCount: Int { lock.withLock { phasesRun } }

    /// From now on `reentry`'s call re-enters once, and joins wait when `joinsWait`.
    func arm(_ reentry: Reentry, keeper: LandKeeper<FoldReportState>, joinsWait: Bool) {
        lock.withLock {
            self.reentry = reentry
            self.keeper = keeper
            self.joinsWait = joinsWait
        }
    }

    /// From now on the `n`th port call made during a turn body re-enters, and joins wait when
    /// `joinsWait`.
    func armNthCallInBody(_ n: Int, keeper: LandKeeper<FoldReportState>, joinsWait: Bool) {
        lock.withLock {
            reentry = .nthCallInBody
            self.keeper = keeper
            self.joinsWait = joinsWait
            nthTarget = n
            callsInBody = 0
        }
    }
    /// Whether the armed nth call was made, and re-entered.
    var reenteredAtNth: Bool { lock.withLock { reenteredNth } }

    /// Counts a port call made during a turn body, and re-enters at the armed one.
    /// The port method of the call that re-entered, for the loop's pin.
    var reenteredCall: String? { lock.withLock { reenteredName } }
    private var reenteredName: String?

    private func noteCall(_ name: String = #function) {
        guard let keeper = lock.withLock({ reentry == .nthCallInBody ? self.keeper : nil }) else { return }
        guard keeper.assumeIsolated({ $0.bodyDepthForTesting > 0 }) else { return } // lint-allow: turns-isolated: the fake counts only the calls a body makes
        let due = lock.withLock {
            callsInBody += 1
            if callsInBody == nthTarget { reenteredNth = true; reenteredName = name }
            return callsInBody == nthTarget
        }
        if due { keeper.assumeIsolated { $0.submitSyncStream([]) } } // lint-allow: turns-isolated: the synchronous callback the sentinel refuses
    }

    /// The synchronous callback the sentinel refuses, if `call` is the armed one (one-shot).
    private func reenter(at call: Reentry) {
        let keeper: LandKeeper<FoldReportState>? = lock.withLock {
            guard reentry == call else { return nil }
            reentry = .none
            return self.keeper
        }
        keeper?.assumeIsolated { $0.submitSyncStream([]) } // lint-allow: turns-isolated: the synchronous callback the sentinel refuses
    }

    var hasJoinsAwaitingSync: Bool {
        noteCall()
        reenter(at: .joinsRead)
        return lock.withLock { joinsWait }
    }
    func noteInTurnJoinSyncTick() {
        noteCall()
        reenter(at: .joinSyncTickNote)
    }
    func noteJoinInputsConsumed(_ results: [JoinInputResult]) { noteCall() }
    func refusesResolvedJoin(playerID: PlayerID, sessionID: SessionID) -> Bool {
        noteCall()
        reenter(at: .staleRefusal)
        return false
    }
    /// What each sync phase the keeper ran returned.
    var syncResults: [InTurnSyncResult] { lock.withLock { syncPhases } }

    /// The next `count` sync phases defer on writer back-pressure.
    func deferNext(_ count: Int) { lock.withLock { deferNextSyncs = count } }

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool {
        noteCall()
        // The flag first: only an armed fake past the `init`'s query assumes the keeper's actor.
        let armed = lock.withLock { () -> Bool in
            guard reentersAtFirstPhaseQuery else { return false }
            if phaseQueriesToSkip > 0 {
                phaseQueriesToSkip -= 1
                return false
            }
            return true
        }
        guard armed, let asking = keeper as? LandKeeper<FoldReportState>,
              asking.assumeIsolated({ $0.bodyDepthForTesting > 0 }) // lint-allow: turns-isolated: the fake re-enters only from a body
        else { return true }
        lock.withLock { reentersAtFirstPhaseQuery = false }
        asking.assumeIsolated { $0.submitSyncStream([]) } // lint-allow: turns-isolated: the synchronous callback the sentinel refuses
        return true
    }
    var recordsInTurnSyncFolds: Bool { records }
    func noteInTurnSyncFold(_ fold: InTurnSyncFold) {
        noteCall()
        lock.withLock { notes.append(fold) }
        reenter(at: .foldNote)
    }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool,
        recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        noteCall()
        lock.withLock {
            phasesRun += 1
            eventSequences.append(contentsOf: events.map(\.sequence))
        }
        return InTurnSyncOutput(syncPhaseResult(state: state, events: events, includeSync: includeSync))
    }

    private func syncPhaseResult<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool
    ) -> InTurnSyncResult {
        guard includeSync else { return .notRequested }
        return lock.withLock {
            let result: InTurnSyncResult
            if deferNextSyncs > 0 {
                deferNextSyncs -= 1
                result = .deferredBackPressure
            } else {
                result = .committed(clearDirtyFlags: true)
            }
            syncPhases.append(result)
            return result
        }
    }
    /// At once: it defers only the counted phases (`deferNext`), so a retry commits.
    func waitForWriterDrainForInTurnSync() async {}
}

/// A tick-loop clock on real time that reports the loop's first `sleepUntil`. The loop
/// publishes its first tick deadline (`noteNextTickDeadline`) in its own task, just before that
/// sleep; a test that set the deadline before then could have it overwritten by the loop's
/// (now + 1 h), and the next sync would then not fold. Once the sleep is reported, the loop
/// writes no deadline until the hour has passed. The sleep is real and ends on shutdown.
/// Shared with `KeeperCoreDifferentialTests`, whose fold case drives a keeper the same way.
final class FirstTickSleepSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var reached = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var tickLoopClock: TickLoopClock {
        TickLoopClock(
            now: { ContinuousClock.now },
            sleepFor: { try? await safeTaskSleep(for: $0) },
            sleepUntil: { deadline in
                self.markReached()
                try? await Task.sleep(until: deadline, clock: .continuous)
            }
        )
    }

    private func markReached() {
        lock.lock()
        reached = true
        let resumed = waiters
        waiters.removeAll()
        lock.unlock()
        for waiter in resumed { waiter.resume() }
    }

    /// Returns once the tick loop has started its first sleep (at once if it has).
    func waitUntilReached() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if reached {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// The land's coincident-sync window: min(5 ms, tick / 4, sync / 4) with hourly loops.
private let window = Duration.milliseconds(5)

@Suite("In-turn sync: folds reported to the transport", .timeLimit(.minutes(1)))
struct InTurnSyncFoldReportTests {
    func makeKeeper(
        _ transport: FoldRecordingTransport,
        onJoin: Bool = false,
        definition: LandDefinition<FoldReportState>? = nil,
        recording: Bool = false
    ) async throws -> LandKeeper<FoldReportState> {
        let signal = FirstTickSleepSignal()
        let definition = definition ?? (onJoin ? foldReportLandWithOnJoin() : foldReportLand())
        // One land ID per recording keeper: parallel tests must not share a recorder spool.
        let landID = recording ? "\(definition.id):\(UUID().uuidString)" : nil
        let keeper = TickLoopClock.$forNewKeepers.withValue(signal.tickLoopClock) {
            LandKeeper<FoldReportState>(
                definition: definition,
                initialState: FoldReportState(),
                enableLiveStateHashRecording: recording,
                enableLoopPhaseOffset: false,
                landID: landID,
                transport: transport
            )
        }
        if recording, let landID {
            let recorder = try #require(await keeper.getReevaluationRecorder())
            await recorder.setMetadata(ReevaluationRecordMetadata(
                landID: landID,
                landType: definition.id,
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                metadata: [:],
                landDefinitionID: definition.id,
                rngSeed: DeterministicSeed.fromLandID(landID),
                version: ReevaluationRecordVersion.current
            ))
        }
        #expect(await keeper.isUsingInTurnSync())
        try await Self.waitForLoops(keeper, signal)
        return keeper
    }

    /// The keeper initializes, and starts its loops, on the first join; the fold needs the tick
    /// task. Waits for the initialization, then for the tick loop's first sleep, after which the
    /// loop no longer writes the tick deadline the tests set (`FirstTickSleepSignal`).
    private static func waitForLoops(
        _ keeper: LandKeeper<FoldReportState>,
        _ signal: FirstTickSleepSignal
    ) async throws {
        try await keeper.join(
            playerID: PlayerID("fold-player"),
            clientID: ClientID("fold-client"),
            sessionID: SessionID("fold-session")
        )
        await keeper.awaitInitialization()
        try #require(await keeper.appliedTickPhaseOffset != nil, "the keeper's tick loop did not start")
        try #require(await keeper.appliedSyncPhaseOffset != nil, "the keeper's sync loop did not start")
        await signal.waitUntilReached()
    }

    /// One sync loop iteration at `deadline + syncAt`, then the tick turn at `deadline + tickAt`.
    /// Fixed clock readings make the fold, overdue and lateness decisions independent of
    /// scheduling.
    private func syncThenTick(
        _ keeper: LandKeeper<FoldReportState>,
        syncAt: Duration,
        tickAt: Duration
    ) async {
        let deadline = ContinuousClock.now
        await keeper.setNextTickDeadlineForTesting(deadline)
        await keeper.runSyncLoopIterationForTesting(at: deadline + syncAt)
        await keeper.stepTickOnceForTesting(at: deadline + tickAt)
    }

    @Test("each folded tick turn is reported once, with overdue at the fold and lateness at the turn's start")
    func foldsAreReported() async throws {
        let transport = FoldRecordingTransport(records: true)
        let keeper = try await makeKeeper(transport)
        // (sync at, tick at) relative to the tick deadline; expected overdue, late, lateness.
        let cases: [(Duration, Duration, Bool, Bool, Duration)] = [
            (.milliseconds(-1), .zero, false, false, .zero),                         // coincident, on time
            (.zero, .zero, false, false, .zero),                                       // exactly at the deadline
            (.milliseconds(1), .milliseconds(1), true, false, .milliseconds(1)),       // overdue by the race only
            (window, window, true, false, window),                                     // at the window: not late
            (.milliseconds(-1), .milliseconds(20), false, true, .milliseconds(20)),    // late, not overdue
            (.milliseconds(20), .milliseconds(20), true, true, .milliseconds(20)),     // overdue and late
        ]
        for (syncAt, tickAt, _, _, _) in cases {
            await syncThenTick(keeper, syncAt: syncAt, tickAt: tickAt)
        }
        let expected = cases.map {
            InTurnSyncFold(overdueAtFold: $0.2, tickLateness: $0.4, coincidentWindow: window)
        }
        #expect(transport.folds == expected)
        #expect(transport.folds.map { $0.isLate } == cases.map { $0.3 })
        let counters = await keeper.cadenceCountersForTesting()
        #expect(counters.foldedSyncs == 6)
        #expect(counters.overdueFoldedSyncs == 3)
        #expect(counters.lateFoldedSyncs == 2)
        await keeper.forceShutdown()
    }

    /// The tick turn is a turn body (#700 K1b-5a step 2): its port calls go through `callOut`,
    /// so a synchronous callback from one ends the land in that tick, with no output step.
    @Test("a callback from a tick turn's port call ends the land in that tick", arguments: [
        FoldRecordingTransport.Reentry.foldNote, .joinsRead, .joinSyncTickNote,
    ])
    func tickTurnReentryEndsTheLand(_ reentry: FoldRecordingTransport.Reentry) async throws {
        let transport = FoldRecordingTransport(records: true)
        let keeper = try await makeKeeper(transport)
        transport.arm(reentry, keeper: keeper, joinsWait: reentry != .foldNote)
        let deadline = ContinuousClock.now
        if reentry == .foldNote {
            await keeper.setNextTickDeadlineForTesting(deadline)
            await keeper.runSyncLoopIterationForTesting(at: deadline - .milliseconds(1))
        }
        let ticksBefore = await keeper.currentState().ticks
        let phasesBefore = transport.phaseCount
        await keeper.stepTickOnceForTesting(at: deadline + .milliseconds(1))

        #expect(keeper.failure?.kind == .keeperReentry)
        #expect(await keeper.reentryViolationsForTesting == 1)
        #expect(await keeper.bodyDepthForTesting == 0)
        #expect(transport.phaseCount == phasesBefore, "an output step ran after the refusal")
        // The fold is reported before the inputs: the land ends there, and the tick handler
        // doesn't run. The join-sync calls come after the handler.
        #expect(await keeper.currentState().ticks == ticksBefore + (reentry == .foldNote ? 0 : 1))
        // So the fold's refusal ended the tick's inputs (replay skips its handler too); the
        // join-sync ones came after the handler.
        #expect((keeper.failure?.position.endsInputs == true) == (reentry == .foldNote))
        #expect(keeper.failure?.position.pass == nil)
        await keeper.forceShutdown()
    }

    /// A recorded tick that a port call's re-entry ends (#891 review): the record holds the
    /// terminal entry, then the tick's own record, and the failure's position says whether the
    /// tick's inputs ended (the fold report, before the handler) or not (the joins read, after
    /// it). Replay then runs the handler only where live did: no server-event mismatch.
    @Test("a recorded tick ended by a port call's re-entry replays as it ran", arguments: [
        FoldRecordingTransport.Reentry.foldNote, .joinsRead,
    ])
    func recordedTickRefusalReplays(_ reentry: FoldRecordingTransport.Reentry) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("fold-refusal-\(UUID().uuidString).sstr").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let transport = FoldRecordingTransport(records: true)
        let keeper = try await makeKeeper(transport, definition: foldReportLandEmitting(), recording: true)
        let deadline = ContinuousClock.now
        // One ordinary tick first, so the record has a handler's event to compare.
        await keeper.stepTickOnceForTesting(at: deadline)
        transport.arm(reentry, keeper: keeper, joinsWait: reentry != .foldNote)
        if reentry == .foldNote {
            await keeper.setNextTickDeadlineForTesting(deadline + .seconds(1))
            await keeper.runSyncLoopIterationForTesting(at: deadline + .seconds(1) - .milliseconds(1))
        }
        let tracker = await keeper.recorderSubmissionsForTesting
        tracker.startTraceForTesting()
        await keeper.stepTickOnceForTesting(at: deadline + .seconds(1) + .milliseconds(1))

        #expect(keeper.failure?.kind == .keeperReentry)
        #expect((keeper.failure?.position.endsInputs == true) == (reentry == .foldNote))
        #expect(await keeper.currentState().ticks == (reentry == .foldNote ? 1 : 2))
        await keeper.waitForRecorderSubmissionsForTesting()
        // The terminal entry, then the tick's own record (no sync phase ran, so no sync-stream
        // entry precedes them).
        #expect(tracker.traceForTesting == ["terminal", "turn-record"], "\(tracker.traceForTesting)")

        let recorder = try #require(await keeper.getReevaluationRecorder())
        try await recorder.save(to: path)
        await keeper.forceShutdown()
        let result = try await ReevaluationEngine.run(
            definition: foldReportLandEmitting(),
            initialState: FoldReportState(),
            recordFilePath: path
        )
        #expect(result.serverEventMismatches.isEmpty, "\(result.serverEventMismatches.map(\.tickId))")
        #expect(result.serverEventVerification == .passed)
    }

    /// A reporting join's stale-join refusal (J2) that re-enters ends the land outside any tick.
    /// Before the first tick, its terminal entry goes into frame 0, whose handler never ran, so
    /// the failure must end that tick's inputs; after a committed tick, the frame's handler ran.
    /// Either way the record replays with the server events verified (#896 round 1).
    @Test("a recorded stale-join refusal that re-enters replays as it ran, before and after the first tick", arguments: [false, true])
    func recordedStaleRefusalReplays(afterFirstTick: Bool) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("stale-refusal-\(UUID().uuidString).sstr").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let transport = FoldRecordingTransport(records: true)
        let keeper = try await makeKeeper(transport, definition: foldReportLandEmitting(), recording: true)
        if afterFirstTick {
            await keeper.stepTickOnceForTesting(at: ContinuousClock.now)
        }
        transport.arm(.staleRefusal, keeper: keeper, joinsWait: false)

        var refusal: JoinError?
        do {
            _ = try await keeper.joinReportingAdmission(
                session: PlayerSession(playerID: "p2"),
                clientID: ClientID("c2"),
                sessionID: SessionID("s2"),
                services: LandServices(),
                admitThroughTransport: true
            )
        } catch let error as JoinError {
            refusal = error
        }
        guard case .landShuttingDown = refusal else {
            Issue.record("the join's outcome: \(String(describing: refusal))")
            return
        }
        #expect(keeper.failure?.kind == .keeperReentry)
        #expect(keeper.failure?.position.endsInputs == (afterFirstTick ? nil : true))
        #expect(await keeper.currentState().ticks == (afterFirstTick ? 1 : 0))

        await keeper.waitForRecorderSubmissionsForTesting()
        let recorder = try #require(await keeper.getReevaluationRecorder())
        try await recorder.save(to: path)
        await keeper.forceShutdown()
        let result = try await ReevaluationEngine.run(
            definition: foldReportLandEmitting(),
            initialState: FoldReportState(),
            recordFilePath: path
        )
        #expect(result.serverEventMismatches.isEmpty, "\(result.serverEventMismatches.map(\.tickId))")
        #expect(result.serverEventVerification == .passed)
    }

    /// Every port call a tick turn's body makes goes through `callOut`: the fake re-enters at the
    /// nth call it gets during a body, for each n until the body makes no more, and each re-entry
    /// ends the land in that call; the late backstop applies none. Run on a folded tick (the
    /// fold report and a cadence sync), on a join-sync tick (the joins read, its count note, and
    /// the joins' sync), and on a tick that applies a join's OnJoin (the join report).
    enum TickKind: CaseIterable { case folded, joinSync, appliesJoin }

    @Test("a re-entry at any port call of a tick turn ends the land in that call", arguments: TickKind.allCases)
    func tickTurnReentryAtEveryPortCall(kind: TickKind) async throws {
        let folded = kind == .folded
        var reentered: [Int] = []
        var calls: [String] = []
        var endedInputs: [Bool] = []
        for n in 1...30 {
            let transport = FoldRecordingTransport(records: true)
            // With OnJoin, the setup's join queues its input for the tick below.
            let keeper = try await makeKeeper(transport, onJoin: kind == .appliesJoin)
            transport.armNthCallInBody(n, keeper: keeper, joinsWait: kind == .joinSync)
            let deadline = ContinuousClock.now
            if folded {
                await keeper.setNextTickDeadlineForTesting(deadline)
                await keeper.runSyncLoopIterationForTesting(at: deadline - .milliseconds(1))
            }
            await keeper.stepTickOnceForTesting(at: deadline + .milliseconds(1))
            defer { Task { await keeper.forceShutdown() } }
            guard transport.reenteredAtNth else {
                #expect(keeper.failure == nil, "past the last call (\(n))")
                break
            }
            reentered.append(n)
            calls.append(transport.reenteredCall ?? "?")
            endedInputs.append(keeper.failure?.position.endsInputs == true)
            #expect(keeper.failure?.kind == .keeperReentry, "call \(n)")
            #expect(await keeper.reentryViolationsForTesting == 1, "call \(n)")
            #expect(await keeper.lateReentriesAppliedForTesting == 0, "call \(n): applied by the backstop, not in the call")
            #expect(await keeper.reentriesAppliedInCallForTesting == 1, "call \(n): not applied by its call's callOut")
            #expect(await keeper.bodyDepthForTesting == 0, "call \(n)")
        }
        // Folded: the fold report and the phase. Join sync: the in-turn check and the joins read,
        // the join-sync count note, and the phase. Applies a join: the join report (its witness,
        // then the report), the joins read (its witness, then the read), and the phase, which
        // syncs the join. With no recorder, the recording reads no port.
        let expected: [TickKind: Int] = [.folded: 2, .joinSync: 4, .appliesJoin: 5]
        #expect(reentered == Array(1...expected[kind]!), "calls that re-entered: \(reentered) \(calls)")
        if kind == .appliesJoin {
            #expect(calls.count > 1 && calls[1] == "noteJoinInputsConsumed(_:)", "the tick's join report: \(calls)")
        }
        // A refusal before the handler (the fold report, the join report) ended the tick's
        // inputs, so replay skips the handler as live did; the ones after the handler didn't.
        let ended: [TickKind: [Bool]] = [
            .folded: [true, false],
            .joinSync: [false, false, false, false],
            .appliesJoin: [true, true, false, false, false],
        ]
        #expect(endedInputs == ended[kind]!, "\(calls)")
    }

    @Test("a sync-only turn when the tick is far away is not a fold")
    func noFoldWhenTickFarAway() async throws {
        let transport = FoldRecordingTransport(records: true)
        let keeper = try await makeKeeper(transport)
        await syncThenTick(keeper, syncAt: .seconds(-10), tickAt: .zero)
        #expect(transport.folds.isEmpty)
        #expect(await keeper.foldedSyncs == 0)
        await keeper.forceShutdown()
    }

    @Test("two sync iterations before one tick turn give one report, on the first fold's deadline")
    func lateTickCountsOneFold() async throws {
        let transport = FoldRecordingTransport(records: true)
        let keeper = try await makeKeeper(transport)
        let deadline = ContinuousClock.now
        await keeper.setNextTickDeadlineForTesting(deadline)
        // Two sync iterations, 100 ms apart, before the late tick runs: one tick turn, one cycle.
        await keeper.runSyncLoopIterationForTesting(at: deadline + .milliseconds(1))
        await keeper.setNextTickDeadlineForTesting(deadline + .milliseconds(50))
        await keeper.runSyncLoopIterationForTesting(at: deadline + .milliseconds(101))
        await keeper.stepTickOnceForTesting(at: deadline + .milliseconds(120))
        #expect(transport.folds == [
            InTurnSyncFold(overdueAtFold: true, tickLateness: .milliseconds(120), coincidentWindow: window)
        ])
        #expect(await keeper.foldedSyncs == 1)
        #expect(await keeper.overdueFoldedSyncs == 1)
        #expect(await keeper.lateFoldedSyncs == 1)
        // The next tick turn carries no fold.
        await keeper.stepTickOnceForTesting(at: deadline + .milliseconds(170))
        #expect(transport.folds.count == 1)
        await keeper.forceShutdown()
    }

    @Test("a fold whose tick turn runs without a port ends with it: a later attach doesn't report it")
    func foldEndsWithAPortlessTickTurn() async throws {
        let transport = FoldRecordingTransport(records: true)
        let keeper = try await makeKeeper(transport)
        let deadline = ContinuousClock.now
        await keeper.setNextTickDeadlineForTesting(deadline)
        await keeper.runSyncLoopIterationForTesting(at: deadline - .milliseconds(1))
        #expect(await keeper.foldedSyncs == 1)
        await keeper.setTransport(nil)
        await keeper.stepTickOnceForTesting(at: deadline + .milliseconds(1))  // the folded tick, no port
        #expect(await !keeper.inTurnSyncDueForTesting, "the due sync ended with its tick turn")
        await keeper.setTransport(transport)
        await keeper.stepTickOnceForTesting(at: deadline + .milliseconds(51))
        #expect(transport.folds.isEmpty, "the stale fold was reported by the next turn: \(transport.folds)")
        #expect(await keeper.lateFoldedSyncs == 0)
        await keeper.forceShutdown()
    }

    @Test("a fold is reported at the first tick turn after it, also when that turn's sync phase defers")
    func reportedAtFirstTurnWhenItsSyncDefers() async throws {
        let transport = FoldRecordingTransport(records: true)
        let keeper = try await makeKeeper(transport)
        let deadline = ContinuousClock.now
        await keeper.setNextTickDeadlineForTesting(deadline)
        await keeper.runSyncLoopIterationForTesting(at: deadline - .milliseconds(1))
        transport.deferNext(1)
        await keeper.stepTickOnceForTesting(at: deadline + .milliseconds(1))   // on time; sync defers
        await keeper.stepTickOnceForTesting(at: deadline + .milliseconds(51))  // the next tick turn
        #expect(transport.folds == [
            InTurnSyncFold(overdueAtFold: false, tickLateness: .milliseconds(1), coincidentWindow: window)
        ], "back-pressure is not tick lateness: one report, from the first turn, not late")
        #expect(await keeper.lateFoldedSyncs == 0)
        #expect(transport.syncResults.first == .deferredBackPressure, "the first turn's sync phase deferred")
        await keeper.forceShutdown()
    }

    @Test("a fold pending when the land freezes isn't reported; a fold after the resume is")
    func freezeDropsPendingFold() async throws {
        let transport = FoldRecordingTransport(records: true)
        let keeper = try await makeKeeper(transport)
        let deadline = ContinuousClock.now
        await keeper.setNextTickDeadlineForTesting(deadline)
        await keeper.runSyncLoopIterationForTesting(at: deadline - .milliseconds(1))
        #expect(await keeper.debugFreeze(generation: 1, timeout: .seconds(1)))
        await keeper.stepTickOnceForTesting(at: deadline + .milliseconds(1))   // frozen: no turn
        await keeper.debugResume(generation: 1)
        // After the resume: a new fold, and the tick turn that carries it starts on time.
        let next = deadline + .milliseconds(500)
        await keeper.setNextTickDeadlineForTesting(next)
        await keeper.runSyncLoopIterationForTesting(at: next - .milliseconds(1))
        await keeper.stepTickOnceForTesting(at: next + .milliseconds(1))
        #expect(transport.folds == [
            InTurnSyncFold(overdueAtFold: false, tickLateness: .milliseconds(1), coincidentWindow: window)
        ], "the freeze is not tick lateness")
        #expect(await keeper.lateFoldedSyncs == 0)
        await keeper.forceShutdown()
    }

    @Test("a transport that doesn't record folds is not called")
    func notCalledWhenNotRecording() async throws {
        let transport = FoldRecordingTransport(records: false)
        let keeper = try await makeKeeper(transport)
        await syncThenTick(keeper, syncAt: .milliseconds(-1), tickAt: .zero)
        await syncThenTick(keeper, syncAt: .milliseconds(20), tickAt: .milliseconds(20))
        #expect(transport.folds.isEmpty)
        let counters = await keeper.cadenceCountersForTesting()
        #expect(counters.foldedSyncs == 2, "the keeper's own counters still count")
        #expect(counters.lateFoldedSyncs == 1)
        await keeper.forceShutdown()
    }

    @Test("the recording flag is read when the transport is attached with setTransport")
    func flagReadOnSetTransport() async throws {
        let signal = FirstTickSleepSignal()
        let keeper = TickLoopClock.$forNewKeepers.withValue(signal.tickLoopClock) {
            LandKeeper<FoldReportState>(
                definition: foldReportLand(),
                initialState: FoldReportState(),
                enableLoopPhaseOffset: false
            )
        }
        let transport = FoldRecordingTransport(records: true)
        await keeper.setTransport(transport)
        #expect(await keeper.isUsingInTurnSync())
        try await Self.waitForLoops(keeper, signal)
        await syncThenTick(keeper, syncAt: .milliseconds(20), tickAt: .milliseconds(20))
        #expect(transport.folds.map { $0.overdueAtFold } == [true])
        await keeper.forceShutdown()
    }
}

/// A tick-loop clock whose phase-offset sleep (`sleepFor`) waits until `release()`: the test
/// decides when the loop's task goes on to write its first tick deadline. Like
/// `FirstTickSleepSignal`, it reports the loop's first `sleepUntil`.
private final class HeldLoopStartClock: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false
    private var startWaiter: CheckedContinuation<Void, Never>?
    let firstSleep = FirstTickSleepSignal()

    var tickLoopClock: TickLoopClock {
        let sleeping = firstSleep.tickLoopClock
        return TickLoopClock(
            now: sleeping.now,
            sleepFor: { _ in await self.waitForRelease() },
            sleepUntil: sleeping.sleepUntil
        )
    }

    private func waitForRelease() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                startWaiter = continuation
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let waiter = startWaiter
        startWaiter = nil
        lock.unlock()
        waiter?.resume()
    }
}

extension InTurnSyncFoldReportTests {
    /// The order `waitForLoops` relies on. A deadline the test sets before the loop's task has
    /// written its first one is overwritten (now + 1 h), so the sync doesn't fold; one set after
    /// the loop's first sleep is kept, and the sync folds. If the keeper comes to write the first
    /// deadline synchronously when it configures the loop, the first expectation fails: the race
    /// is gone, and `waitForLoops` no longer needs to wait for the first sleep.
    @Test("a tick deadline set before the loop's first write is overwritten; one set after its first sleep is kept")
    func loopStartDeadlineOrder() async throws {
        let transport = FoldRecordingTransport(records: false)
        let clock = HeldLoopStartClock()
        // A phase offset, so the loop's task sleeps (held) before it writes the deadline.
        let keeper = TickLoopClock.$forNewKeepers.withValue(clock.tickLoopClock) {
            LandKeeper<FoldReportState>(
                definition: foldReportLand(),
                initialState: FoldReportState(),
                enableLoopPhaseOffset: true,
                landID: "fold-report-test:550e8400-e29b-41d4-a716-446655440000",
                transport: transport
            )
        }
        try await keeper.join(playerID: PlayerID("p"), clientID: ClientID("c"), sessionID: SessionID("s"))
        await keeper.awaitInitialization()
        try #require(await keeper.appliedTickPhaseOffset ?? .zero > .zero, "the loop must have an offset to hold")

        // Set before the loop's write: overwritten, no fold.
        let early = ContinuousClock.now
        await keeper.setNextTickDeadlineForTesting(early)
        clock.release()
        await clock.firstSleep.waitUntilReached()
        await keeper.runSyncLoopIterationForTesting(at: early - .milliseconds(1))
        await keeper.stepTickOnceForTesting(at: early)
        #expect(await keeper.foldedSyncs == 0, "the loop's own deadline replaced the test's")

        // Set after the loop's first sleep: kept, one fold.
        let late = ContinuousClock.now
        await keeper.setNextTickDeadlineForTesting(late)
        await keeper.runSyncLoopIterationForTesting(at: late - .milliseconds(1))
        await keeper.stepTickOnceForTesting(at: late)
        #expect(await keeper.foldedSyncs == 1)
        await keeper.forceShutdown()
    }
}
