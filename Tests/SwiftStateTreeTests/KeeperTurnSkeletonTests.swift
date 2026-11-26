// Tests/SwiftStateTreeTests/KeeperTurnSkeletonTests.swift
//
// The turn skeleton (#700 K1b-5a): a turn body borrows the turn side and its outputs, the
// outputs flush once before the caller goes on (a throw included), and a transport that calls
// back into the keeper during a body is refused and ends the land in that same turn, before
// the body reads the call's answer. The callbacks here are synchronous, through
// `assumeIsolated` on the keeper's executor, as the adapter's are; none of them traps.

import Foundation
import Testing
@testable import SwiftStateTree
import SwiftStateTreeTestSupport

@StateNodeBuilder
struct TurnSkeletonState: StateNodeProtocol {
    @Sync(.broadcast)
    var value: Int = 0

    public init() {}
}

/// Tickless, no periodic sync.
private func turnSkeletonLand() -> LandDefinition<TurnSkeletonState> {
    Land("turn-skeleton", using: TurnSkeletonState.self) {
        Rules {}
    }
}

private func makeKeeper(recording: Bool) -> LandKeeper<TurnSkeletonState> {
    LandKeeper<TurnSkeletonState>(
        definition: turnSkeletonLand(),
        initialState: TurnSkeletonState(),
        enableLiveStateHashRecording: recording,
        autoStartLoops: false,
        landID: "turn-skeleton:1"
    )
}

/// A sync-stream output draft, distinguishable by `tag`.
private func outputDraft(_ tag: UInt64) -> SyncStreamDraft {
    SyncStreamDraft(.output(observedTickId: 0, make: { streamIndex, index in
        ReevaluationRecordedSyncOutput(
            index: index, turnKind: .syncOnly, observedTickId: 0,
            streamIndex: streamIndex, sequence: Int64(streamIndex), broadcastHash: 0xbeef_0000 + tag
        )
    }))
}

/// A clear marker draft.
private func clearDraft() -> SyncStreamDraft {
    SyncStreamDraft(.marker(make: { streamIndex, position in
        ReevaluationRecordedSyncMarker(kind: .clear, playerID: "p1", streamIndex: streamIndex, sequence: position.sequence)
    }))
}

/// An in-turn transport that calls back into its keeper synchronously from inside one of the
/// keeper's synchronous calls, and reads its own gate and the keeper's mailbox right after the
/// refused call returns.
final class TurnSkeletonReenteringTransport: LandKeeperTransport, @unchecked Sendable {
    enum Where {
        case nowhere
        /// `submitSyncStream` from the sync phase.
        case phase
        /// `submitSyncStream` from the joins-awaiting-sync read after a committed phase.
        case joinsAwaitingSync
        /// `syncTurnNow` from the sync phase.
        case phaseRequestingSyncTurn
        /// The land starts draining in the sync phase, then `submitSyncStream`.
        case phaseOnDrainingLand
        /// `submitSyncStream` from a draft factory the phase returned, which the keeper runs
        /// after the phase, outside any call out.
        case draftFactory
        /// `submitSyncStream` from `runsSyncPhaseInTurn`, armed once the phase returned: the
        /// first of the joins-awaiting-sync read's two witnesses.
        case runsSyncPhaseWitness
    }

    private let lock = NSLock()
    private let reenter: Where
    /// Joins wait on a committed phase without a re-entry (`.nowhere` only).
    private let joinsWait: Bool
    private weak var keeper: LandKeeper<TurnSkeletonState>?
    private var closes = 0
    private var closedAtReentry: Bool?
    private var mailboxAtReentry: LandFailure?
    private var phaseReturned = false
    private var joinsAsked = 0

    init(reenter: Where, joinsWait: Bool = false) {
        self.reenter = reenter
        self.joinsWait = joinsWait
    }

    func attach(_ keeper: LandKeeper<TurnSkeletonState>) { lock.withLock { self.keeper = keeper } }

    /// Whether the gate was closed right after the refused call returned (nil: no re-entry).
    var gateClosedAtReentry: Bool? { lock.withLock { closedAtReentry } }
    /// The keeper's mailbox right after the refused call returned.
    var mailboxFailureAtReentry: LandFailure? { lock.withLock { mailboxAtReentry } }
    var closeCount: Int { lock.withLock { closes } }
    /// How many times `hasJoinsAwaitingSync` was read.
    var joinsAskedCount: Int { lock.withLock { joinsAsked } }

    private func reenterNow() {
        guard let keeper = lock.withLock({ self.keeper }) else { return }
        let entry = reenter
        keeper.assumeIsolated { keeper in // lint-allow: turns-isolated: the synchronous callback the sentinel refuses
            switch entry {
            case .phaseRequestingSyncTurn:
                _ = keeper.syncTurnNow(via: self, reason: .syncNow)
            case .phaseOnDrainingLand:
                keeper.markDrainingForTesting(cause: .forceShutdown)
                keeper.submitSyncStream([outputDraft(99)])
            case .phase, .joinsAwaitingSync, .draftFactory, .runsSyncPhaseWitness, .nowhere:
                keeper.submitSyncStream([outputDraft(99)])
            }
        }
        lock.withLock {
            closedAtReentry = closes > 0
            mailboxAtReentry = keeper.pendingFailureForTesting
        }
    }

    nonisolated func closeOutputs(for failure: LandFailure) {
        lock.withLock { closes += 1 }
    }

    /// Answers true when it re-enters, so a follow-up would be scheduled if the refused answer
    /// were read.
    var hasJoinsAwaitingSync: Bool {
        lock.withLock { joinsAsked += 1 }
        guard reenter == .joinsAwaitingSync else { return joinsWait }
        reenterNow()
        return true
    }

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}
    /// Read before the phase too (`inTurnSyncRecording`); re-enters only once the phase returned.
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool {
        if reenter == .runsSyncPhaseWitness, lock.withLock({ phaseReturned }) { reenterNow() }
        return true
    }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool,
        recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        switch reenter {
        case .phase, .phaseRequestingSyncTurn, .phaseOnDrainingLand: reenterNow()
        case .joinsAwaitingSync, .draftFactory, .runsSyncPhaseWitness, .nowhere: break
        }
        defer { lock.withLock { phaseReturned = true } }
        // Otherwise a success, so only the re-entry can fail the turn. Kept events would ask
        // for a follow-up turn if the answer were read, and an applied commit leaves its probe.
        return InTurnSyncOutput(
            .committed(clearDirtyFlags: false),
            syncStream: reenter == .draftFactory ? [reenteringDraft(), outputDraft(2)] : [outputDraft(1)],
            keepsEvents: reenter != .nowhere
        )
    }

    /// A draft whose factory re-enters when the keeper makes its entry.
    private func reenteringDraft() -> SyncStreamDraft {
        SyncStreamDraft(.output(observedTickId: 0, make: { [self] streamIndex, index in
            reenterNow()
            return ReevaluationRecordedSyncOutput(
                index: index, turnKind: .syncOnly, observedTickId: 0,
                streamIndex: streamIndex, sequence: Int64(streamIndex), broadcastHash: 0xbeef_0000 + 1
            )
        }))
    }
    func waitForWriterDrainForInTurnSync() async {}
}

/// An in-turn transport whose sync phase returns two distinguishable drafts together with a
/// failure, as no production adapter does (its failing plan returns before it records), so the
/// record order of a failing phase can be pinned.
final class TurnSkeletonFailingPhaseTransport: LandKeeperTransport, @unchecked Sendable {
    static let failure = LandFailure(kind: .syncPlan, detail: "the stub's failing plan", position: LandFailurePosition(stage: .syncPhase))

    var hasJoinsAwaitingSync: Bool { false }
    func closeOutputs(for failure: LandFailure) {}
    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { true }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool,
        recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        InTurnSyncOutput(.landFailed(Self.failure), syncStream: [outputDraft(1), outputDraft(2)], keepsEvents: false)
    }
    func waitForWriterDrainForInTurnSync() async {}
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    func add(_ s: String) { lock.withLock { log.append(s) } }
    var entries: [String] { lock.withLock { log } }
}

private struct BodyError: Error {}

private func attachedKeeper(
    _ reenter: TurnSkeletonReenteringTransport.Where,
    joinsWait: Bool = false
) async -> (LandKeeper<TurnSkeletonState>, TurnSkeletonReenteringTransport, ReevaluationSubmissionTracker) {
    let keeper = makeKeeper(recording: true)
    let transport = TurnSkeletonReenteringTransport(reenter: reenter, joinsWait: joinsWait)
    transport.attach(keeper)
    await keeper.setTransport(transport)
    let tracker = await keeper.recorderSubmissionsForTesting
    tracker.startTraceForTesting()
    return (keeper, transport, tracker)
}

@Suite("The turn skeleton: outputs, the depth and the re-entry sentinel (#700 K1b-5a)", .timeLimit(.minutes(1)))
struct KeeperTurnSkeletonTests {
    @Test("A re-entry during a requested sync-only turn ends the land in that turn", arguments: [
        TurnSkeletonReenteringTransport.Where.phase, .joinsAwaitingSync, .phaseRequestingSyncTurn,
        .draftFactory, .runsSyncPhaseWitness,
    ])
    func reentryEndsTheLandInTheTurn(at reenter: TurnSkeletonReenteringTransport.Where) async throws {
        let (keeper, transport, tracker) = await attachedKeeper(reenter)
        let probes = OrderLog()
        await keeper.setInTurnProbeForTesting { probes.add($0) }

        // An otherwise idle land: this turn is the only step it takes.
        let result = await keeper.syncTurnNow(via: transport, reason: .syncNow)

        guard case let .landFailed(reported) = result else {
            Issue.record("the turn returned \(result), not .landFailed")
            return
        }
        #expect(reported.kind == .keeperReentry)
        #expect(keeper.failure?.kind == .keeperReentry)
        // Closed and noted by the sentinel, inside the transport's call, before the turn went on.
        #expect(transport.gateClosedAtReentry == true)
        #expect(transport.mailboxFailureAtReentry?.kind == .keeperReentry)
        // Closed once: `failLand` doesn't close the gate the sentinel already closed.
        #expect(transport.closeCount == 1)
        #expect(await keeper.reentryViolationsForTesting == 1)
        #expect(await keeper.bodyDepthForTesting == 0)
        // The refused call is never numbered, and the refused phase's answer is never read.
        // Recorded: the committed phase's own draft when the re-entry came after it, the
        // terminal entry, then the turn's end.
        // A factory's re-entry keeps the whole batch, the draft after the trip included, and
        // applies nothing.
        let trace = tracker.traceForTesting
        switch reenter {
        case .draftFactory:
            #expect(trace == ["sync-output", "sync-output", "terminal", "endTurn"])
        case .joinsAwaitingSync, .runsSyncPhaseWitness:
            #expect(trace == ["sync-output", "terminal", "endTurn"])
        default:
            #expect(trace == ["terminal", "endTurn"])
        }
        // Nothing was asked for from the refused answers: no kept-events turn, and no join sync
        // turn, counted where one is scheduled (a scheduled one could retire before a later read).
        #expect(await keeper.joinSyncTurnsScheduledForTesting == 0)
        #expect(await keeper.hasRequestedSyncWorkForTesting == false)
        #expect(await keeper.requestedSyncTurnsForTesting[.keptEvents] == nil)
        // A refused phase's answer is never applied; the witnesses' phase was answered first.
        let applied: Set<TurnSkeletonReenteringTransport.Where> = [.joinsAwaitingSync, .runsSyncPhaseWitness]
        #expect(probes.entries.contains("sync-committed") == applied.contains(reenter))
        // A trip in the first witness stops the read before the second one.
        if reenter == .runsSyncPhaseWitness {
            #expect(transport.joinsAskedCount == 0)
        }
        // The refused `syncTurnNow` changed nothing: only the outer request was counted.
        #expect(await keeper.requestedSyncTurnsForTesting[.syncNow] == 1)
        // The backstop had nothing left to apply.
        #expect(await keeper.lateReentriesAppliedForTesting == 0)
    }

    @Test("A re-entry on a land that is already draining: the gate closes and nothing of the phase is recorded")
    func reentryOnDrainingLand() async throws {
        let (keeper, transport, tracker) = await attachedKeeper(.phaseOnDrainingLand)
        let counterBefore = await keeper.syncStreamCounterForTesting()

        let result = await keeper.syncTurnNow(via: transport, reason: .syncNow)

        guard case let .landFailed(reported) = result else {
            Issue.record("the turn returned \(result), not .landFailed")
            return
        }
        #expect(reported.kind == .keeperReentry)
        // The drain cause stays the land's; the failure isn't set over it.
        #expect(keeper.isDraining)
        #expect(keeper.failure == nil)
        #expect(transport.gateClosedAtReentry == true)
        // Nothing of the refused phase was numbered or submitted, and no terminal entry or
        // turn end either.
        #expect(await keeper.syncStreamCounterForTesting() == counterBefore)
        #expect(tracker.traceForTesting.isEmpty)
        #expect(await keeper.bodyDepthForTesting == 0)
        // Applied in the turn: the backstop, whose guard skips a draining land, had nothing.
        #expect(await keeper.lateReentriesAppliedForTesting == 0)
    }

    @Test("A failing sync phase's drafts are recorded in order, then the terminal entry, then the turn's end; teardown adds nothing")
    func failingPhaseRecordOrder() async throws {
        let keeper = makeKeeper(recording: true)
        let transport = TurnSkeletonFailingPhaseTransport()
        await keeper.setTransport(transport)
        let tracker = await keeper.recorderSubmissionsForTesting
        tracker.startTraceForTesting()
        let counterBefore = await keeper.syncStreamCounterForTesting()

        let result = await keeper.syncTurnNow(via: transport, reason: .syncNow)

        #expect(result == .landFailed(TurnSkeletonFailingPhaseTransport.failure))
        let expected = ["sync-output", "sync-output", "terminal", "endTurn"]
        #expect(tracker.traceForTesting == expected)
        #expect(await keeper.syncStreamCounterForTesting() == counterBefore + 2)

        // The teardown the failure starts submits nothing and numbers nothing.
        #expect(await withinHangBound { await keeper.waitUntilDrainStartedForTesting() })
        await keeper.waitUntilDrained()
        await tracker.waitForAll()
        #expect(tracker.traceForTesting == expected)
        #expect(await keeper.syncStreamCounterForTesting() == counterBefore + 2)

        // The two drafts reached the recorder in the phase's order (the trace's labels can't
        // tell them apart; their tags can).
        let recorder = try #require(await keeper.getReevaluationRecorder())
        let outputs = await recorder.getAllFrames().flatMap(\.syncOutputs)
        #expect(outputs.map(\.broadcastHash) == [0xbeef_0001, 0xbeef_0002])
        #expect(outputs.map(\.streamIndex) == [counterBefore, counterBefore + 1])
    }

    @Test("A tickless input batch that holds only a failure ends its trace with the turn's end")
    func failureOnlyBatchEndsWithItsTurnEnd() async throws {
        let keeper = makeKeeper(recording: true)
        let tracker = await keeper.recorderSubmissionsForTesting
        tracker.startTraceForTesting()

        await keeper.submitLandFailure(TurnSkeletonFailingPhaseTransport.failure)

        try #require(await keeper.waitForFailureForTesting())
        await keeper.waitForInputDrainIdleForTesting()
        await tracker.waitForAll()
        #expect(tracker.traceForTesting == ["terminal", "endTurn"])
    }

    @Test("Without a re-entry the same turn commits, and nothing is refused")
    func noReentryCommits() async throws {
        let (keeper, transport, tracker) = await attachedKeeper(.nowhere)

        #expect(await keeper.syncTurnNow(via: transport, reason: .syncNow) == .committed(clearDirtyFlags: false))
        #expect(keeper.failure == nil)
        #expect(transport.closeCount == 0)
        #expect(await keeper.reentryViolationsForTesting == 0)
        #expect(tracker.traceForTesting == ["sync-output", "endTurn"])
    }

    @Test("A committed phase with joins still waiting schedules one join sync turn")
    func committedPhaseSchedulesAJoinSyncTurn() async throws {
        // The positive case of the re-entry test's `joinSyncTurnsScheduledForTesting == 0`.
        let (keeper, transport, _) = await attachedKeeper(.nowhere, joinsWait: true)

        #expect(await keeper.syncTurnNow(via: transport, reason: .syncNow) == .committed(clearDirtyFlags: false))
        #expect(transport.joinsAskedCount == 1)
        #expect(await keeper.joinSyncTurnsScheduledForTesting == 1)
        #expect(keeper.failure == nil)
    }

    @Test("The adapter's entries outside a body record, at depth zero", arguments: [false, true])
    func entriesAtDepthZeroRecord(outsideTurn: Bool) async throws {
        let keeper = makeKeeper(recording: true)
        let tracker = await keeper.recorderSubmissionsForTesting
        tracker.startTraceForTesting()

        // A standalone commit's output, then a clear (a disconnect's, outside a turn, or a
        // superseded session's, in turn).
        await keeper.submitSyncStream([outputDraft(1)])
        await keeper.submitSyncStream([clearDraft()], outsideTurn: outsideTurn)

        #expect(await keeper.reentryViolationsForTesting == 0)
        #expect(keeper.failure == nil)
        #expect(tracker.traceForTesting == ["sync-output", "sync-marker"])
    }

    @Test("A throwing body flushes once and leaves the depth at zero")
    func throwingBodyFlushes() async throws {
        let keeper = makeKeeper(recording: true)
        let applied = Counter()
        let depthInside = Counter()

        await #expect(throws: BodyError.self) {
            try await keeper.runTestBodyForTesting(
                staging: 1,
                effect: { _ in applied.bump() },
                observe: { depth in if depth == 1 { depthInside.bump() } },
                throwing: BodyError()
            )
        }
        #expect(applied.value == 1, "the staged effect ran once")
        #expect(depthInside.value == 1, "the body ran at depth 1")
        #expect(await keeper.bodyDepthForTesting == 0)

        // The adapter's entry still records afterwards.
        let tracker = await keeper.recorderSubmissionsForTesting
        tracker.startTraceForTesting()
        await keeper.submitSyncStream([outputDraft(2)])
        #expect(await keeper.reentryViolationsForTesting == 0)
        #expect(tracker.traceForTesting == ["sync-output"])
    }

    @Test("A body's staged effects wait for the flush and run in staging order")
    func stagedEffectsRunInOrderAtTheFlush() async throws {
        let keeper = makeKeeper(recording: false)
        let order = OrderLog()
        try await keeper.runTestBodyForTesting(
            staging: 3,
            effect: { index in order.add("effect-\(index)") },
            observe: { _ in order.add("body end") }
        )
        #expect(order.entries == ["body end", "effect-0", "effect-1", "effect-2"])
    }

    @Test("A call out sees every effect staged before it (Rule 2)")
    func callOutFlushesFirst() async throws {
        let keeper = makeKeeper(recording: false)
        let order = OrderLog()
        let refused = try await keeper.runTestBodyForTesting(
            staging: 2,
            effect: { index in order.add("effect-\(index)") },
            callingOut: { order.add("call") },
            observe: { _ in order.add("body end") }
        )
        #expect(!refused)
        #expect(order.entries == ["effect-0", "effect-1", "call", "body end"])
    }

    @Test("A staged effect that re-enters during a call out's flush: the call isn't made, and it is refused")
    func reentryInTheFlushSkipsTheCall() async throws {
        let keeper = makeKeeper(recording: false)
        let order = OrderLog()
        let refused = try await keeper.runTestBodyForTesting(
            staging: 1,
            effect: { _ in
                order.add("effect")
                keeper.assumeIsolated { $0.submitSyncStream([outputDraft(5)]) } // lint-allow: turns-isolated: a staged effect that re-enters during a call out's flush
            },
            callingOut: { order.add("call") },
            observe: { _ in order.add("body end") }
        )
        #expect(refused)
        #expect(order.entries == ["effect", "body end"], "the call wasn't made")
        #expect(keeper.failure?.kind == .keeperReentry)
        #expect(await keeper.reentryViolationsForTesting == 1)
        #expect(await keeper.lateReentriesAppliedForTesting == 0, "applied by the call out, not the backstop")
    }

    @Test("The backstop applies a re-entry a body didn't apply, once, and only while the land runs")
    func backstopAppliesLateReentry() async throws {
        let keeper = makeKeeper(recording: false)
        // A body that is re-entered outside `callOut`: the backstop ends the land after it.
        try await keeper.runTestBodyForTesting(staging: 0, effect: { _ in }, observe: { _ in
            keeper.assumeIsolated { $0.submitSyncStream([outputDraft(3)]) } // lint-allow: turns-isolated: a re-entry no call out sees, for the backstop
        })
        #expect(keeper.failure?.kind == .keeperReentry)
        #expect(await keeper.lateReentriesAppliedForTesting == 1)
        #expect(await keeper.bodyDepthForTesting == 0)
        // On a land that has failed, a second one is refused and counted, and the backstop
        // leaves the first failure.
        let first = keeper.failure
        try await keeper.runTestBodyForTesting(staging: 0, effect: { _ in }, observe: { _ in
            keeper.assumeIsolated { $0.submitSyncStream([outputDraft(4)]) } // lint-allow: turns-isolated: a re-entry no call out sees, for the backstop
        })
        #expect(await keeper.reentryViolationsForTesting == 2)
        #expect(await keeper.lateReentriesAppliedForTesting == 1)
        #expect(keeper.failure == first)
    }

    @Test("submitTurnRecord awaits its own submission, not a later one queued during its hold")
    func turnRecordAwaitsItsOwnSubmission() async throws {
        let keeper = makeKeeper(recording: true)
        let hold = TestGate()
        await keeper.installHolds(HoldRegistry<LandKeeperHoldPoint>.at(.turnRecord) { await hold.arrive() })
        let tracker = await keeper.recorderSubmissionsForTesting
        let blocker = TestGate()

        // Open from the start: the record's task arrives when the call returns, and the test
        // waits for that arrival, which ends on its bound instead of hanging.
        let returned = TestGate()
        returned.open()
        let record = Task {
            await keeper.submitTurnRecordForTesting(tickId: 0)
            await returned.arrive()
        }
        defer {
            hold.open()
            blocker.open()
        }
        try #require(await hold.waitForArrivals(1))
        // A later submission that can't finish until the blocker opens.
        tracker.submit(label: "later") { await blocker.arrive() }
        hold.open()
        // Returns while the later submission is still blocked: awaiting the tracker's tail
        // instead would wait for the blocker, which opens only after this returns.
        try #require(await returned.waitForArrivals(1), "submitTurnRecord returned")
        // Its own submission is applied, and only the later one is pending.
        #expect(tracker.pendingCount == 1)
        blocker.open()
        await record.value
        await tracker.waitForAll()
    }
}
