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

@Payload
struct TurnSkeletonAck: ResponsePayload {
    let ok: Bool
}

@Payload
struct TurnSkeletonAction: ActionPayload {
    typealias Response = TurnSkeletonAck
    let value: Int
}

@Payload
struct TurnSkeletonEvent: ClientEventPayload {
    let value: Int
}

/// Tickless, with an action and a client event.
private func turnSkeletonLandWithIntakes() -> LandDefinition<TurnSkeletonState> {
    Land("turn-skeleton", using: TurnSkeletonState.self) {
        ClientEvents { Register(TurnSkeletonEvent.self) }
        Rules {
            HandleAction(TurnSkeletonAction.self) { state, action, _ in
                state.value = action.value
                return TurnSkeletonAck(ok: true)
            }
            HandleEvent(TurnSkeletonEvent.self) { state, event, _ in state.value = event.value }
        }
    }
}

/// Tickless, with an OnJoin: a join queues its OnJoin as an input, which an input turn applies.
private func turnSkeletonLandWithOnJoin() -> LandDefinition<TurnSkeletonState> {
    Land("turn-skeleton", using: TurnSkeletonState.self) {
        Rules {
            OnJoin { state, _ in state.value += 1 }
        }
    }
}

/// With a Tick and an OnInitialize: the loops start after the initialization's turn.
private func turnSkeletonTickLandWithOnInitialize() -> LandDefinition<TurnSkeletonState> {
    Land("turn-skeleton", using: TurnSkeletonState.self) {
        Lifetime {
            OnInitialize { state, _ in state.value += 1 }
            Tick(every: .seconds(3600)) { _, _ in }
            StateSync(every: .seconds(3600)) { _, _ in }
        }
    }
}

/// Tickless, with an OnInitialize: the keeper's initialization is a turn body.
private func turnSkeletonLandWithOnInitialize() -> LandDefinition<TurnSkeletonState> {
    Land("turn-skeleton", using: TurnSkeletonState.self) {
        Lifetime { OnInitialize { state, _ in state.value += 1 } }
    }
}

private func makeKeeper(recording: Bool, onJoin: Bool = false, onInitialize: Bool = false) -> LandKeeper<TurnSkeletonState> {
    LandKeeper<TurnSkeletonState>(
        definition: onInitialize ? turnSkeletonLandWithOnInitialize() : onJoin ? turnSkeletonLandWithOnJoin() : turnSkeletonLand(),
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
/// The settle fence the settle cases use: generation 1, a deadline far off.
let turnSkeletonSettleFence = LandKeeper<TurnSkeletonState>.SettleFence(
    generation: 1, deadline: ContinuousClock.now + .seconds(3600)
)

final class TurnSkeletonReenteringTransport: LandKeeperSettlePort, @unchecked Sendable {
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
        /// `submitSyncStream` from the settle's in-turn check (`runsSyncPhaseInTurn`), armed by
        /// `armSettleCheck()` once the keeper is attached and frozen.
        case settleCheck
        /// `submitSyncStream` from the settle phase.
        case settlePhase
        /// `settleTurn` from the settle phase: a second settle nested in the first.
        case nestedSettle
        /// `submitSyncStream` from a draft factory the settle phase returned.
        case settleDraftFactory
        /// `submitSyncStream` from the nth port call made during a turn body, armed by
        /// `armNthCallInBody(_:)`: any call of this port, wherever the body makes it.
        case nthCallInBody
        /// `submitSyncStream` from the first `closeOutputs(for:)`: the gate close a land
        /// failure performs.
        case closeOutputs
    }

    private let lock = NSLock()
    private let reenter: Where
    /// Joins wait on the first committed phase without a re-entry (`.nowhere` only), then no
    /// longer: one-shot, so the scheduled follow-up finds none and retires at its guard.
    private var joinsWait: Bool
    private weak var keeper: LandKeeper<TurnSkeletonState>?
    private var closes = 0
    private var closedAtReentry: Bool?
    private var mailboxAtReentry: LandFailure?
    private var phaseReturned = false
    private var joinsAsked = 0
    private var settleCheckArmed = false
    private var settlePhases = 0
    private var nthTarget = 0
    private var callsInBody = 0
    private var reenteredNth = false
    private var portOrder: [String] = []
    private var reportWaits = false
    private let teardownStarted = DispatchSemaphore(value: 0)
    /// Yields once `landDidFail` has been recorded.
    let teardownReached = AsyncStream<Void>.makeStream()

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
    /// How many settle phases ran.
    var settlePhaseCount: Int { lock.withLock { settlePhases } }
    /// From now on, `.settleCheck` re-enters from `runsSyncPhaseInTurn`.
    func armSettleCheck() { lock.withLock { settleCheckArmed = true } }
    /// From now on, `.nthCallInBody` counts the port calls made during a turn body and re-enters
    /// at the `n`th.
    func armNthCallInBody(_ n: Int) {
        lock.withLock {
            nthTarget = n
            callsInBody = 0
        }
    }
    /// Whether the armed nth call was made, and re-entered.
    var reenteredAtNth: Bool { lock.withLock { reenteredNth } }
    /// The join report and the teardown's `landDidFail`, in the order they reached the port.
    var reportAndTeardownOrder: [String] { lock.withLock { portOrder } }
    /// From now on, the join report waits up to half a second for `landDidFail` to start, so a
    /// teardown that can run during the failing turn does so before the report returns.
    func armReportWaitsForTeardown() { lock.withLock { reportWaits = true } }

    func landDidFail(_ failure: LandFailure) async {
        lock.withLock { portOrder.append("landDidFail") }
        teardownStarted.signal()
        teardownReached.continuation.yield()
    }

    /// `.nthCallInBody`: counts a port call made during a turn body; re-enters at the armed one.
    private func noteCall() {
        guard reenter == .nthCallInBody, let keeper = lock.withLock({ self.keeper }) else { return }
        guard keeper.assumeIsolated({ $0.bodyDepthForTesting > 0 }) else { return } // lint-allow: turns-isolated: the fake counts only the calls a body makes
        let due = lock.withLock {
            guard nthTarget > 0 else { return false }
            callsInBody += 1
            return callsInBody == nthTarget
        }
        guard due else { return }
        lock.withLock { reenteredNth = true }
        reenterNow()
    }

    private func reenterNow() {
        guard let keeper = lock.withLock({ self.keeper }) else { return }
        let entry = reenter
        keeper.assumeIsolated { keeper in // lint-allow: turns-isolated: the synchronous callback the sentinel refuses
            switch entry {
            case .phaseRequestingSyncTurn:
                _ = keeper.syncTurnNow(via: self, reason: .syncNow)
            case .nestedSettle:
                _ = keeper.settleTurn(via: self, fence: turnSkeletonSettleFence)
            case .phaseOnDrainingLand:
                keeper.setDrainFlagInBodyForTesting(cause: .forceShutdown)
                keeper.submitSyncStream([outputDraft(99)])
            case .phase, .joinsAwaitingSync, .draftFactory, .runsSyncPhaseWitness, .settleCheck, .settlePhase,
                 .settleDraftFactory, .nthCallInBody, .closeOutputs, .nowhere:
                keeper.submitSyncStream([outputDraft(99)])
            }
        }
        lock.withLock {
            closedAtReentry = closes > 0
            mailboxAtReentry = keeper.pendingFailureForTesting
        }
    }

    nonisolated func closeOutputs(for failure: LandFailure) {
        let first = lock.withLock { () -> Bool in
            closes += 1
            return closes == 1
        }
        if reenter == .closeOutputs, first { reenterNow() }
    }

    /// Answers true when it re-enters, so a follow-up would be scheduled if the refused answer
    /// were read.
    var hasJoinsAwaitingSync: Bool {
        noteCall()
        lock.withLock { joinsAsked += 1 }
        guard reenter == .joinsAwaitingSync else {
            return lock.withLock {
                defer { joinsWait = false }
                return joinsWait
            }
        }
        reenterNow()
        return true
    }

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}
    /// Read before the phase too (`inTurnSyncRecording`); re-enters only once the phase returned.
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool {
        noteCall()
        if reenter == .runsSyncPhaseWitness, lock.withLock({ phaseReturned }) { reenterNow() }
        if reenter == .settleCheck, lock.withLock({ settleCheckArmed }) { reenterNow() }
        return true
    }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool,
        recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        noteCall()
        switch reenter {
        case .phase, .phaseRequestingSyncTurn, .phaseOnDrainingLand: reenterNow()
        case .joinsAwaitingSync, .draftFactory, .runsSyncPhaseWitness, .settleCheck, .settlePhase, .nestedSettle,
             .settleDraftFactory, .nthCallInBody, .closeOutputs, .nowhere: break
        }
        defer { lock.withLock { phaseReturned = true } }
        // Otherwise a success, so only the re-entry can fail the turn. Kept events would ask
        // for a follow-up turn if the answer were read, and an applied commit leaves its probe.
        return InTurnSyncOutput(
            .committed(clearDirtyFlags: false),
            syncStream: reenter == .draftFactory ? [reenteringDraft(), outputDraft(2)] : [outputDraft(1)],
            // `.nthCallInBody` keeps none: a follow-up turn would make further calls in a body
            // after the input turn ended.
            keepsEvents: reenter != .nowhere && reenter != .nthCallInBody
        )
    }

    func runSettlePhaseInTurn<S: StateNodeProtocol>(
        state: S,
        settle: InTurnSettle,
        recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        noteCall()
        lock.withLock { settlePhases += 1 }
        if reenter == .settlePhase || reenter == .nestedSettle { reenterNow() }
        let drafts = reenter == .settleDraftFactory ? [reenteringDraft()] : [outputDraft(3)]
        return InTurnSyncOutput(.notRequested, syncStream: drafts, settle: .empty(membershipEpoch: 0))
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
    func noteJoinInputsConsumed(_ results: [JoinInputResult]) {
        noteCall()
        // wall-clock: the bound on a teardown that can't start during the turn; the fixed keeper
        // waits it out, the broken one returns as soon as the teardown runs.
        if lock.withLock({ reportWaits }) { _ = teardownStarted.wait(timeout: .now() + .milliseconds(500)) }
        lock.withLock { portOrder.append("joinReport") }
    }
    func refusesResolvedJoin(playerID: PlayerID, sessionID: SessionID) -> Bool {
        noteCall()
        return false
    }
    func waitForWriterDrainForInTurnSync() async {}
}

/// An in-turn transport whose sync phase returns two distinguishable drafts together with a
/// failure, as no production adapter does (its failing plan returns before it records), so the
/// record order of a failing phase can be pinned.
final class TurnSkeletonFailingPhaseTransport: LandKeeperTransport, @unchecked Sendable {
    static let failure = LandFailure(kind: .syncPlan, detail: "the stub's failing plan", position: LandFailurePosition(stage: .syncPhase))
    /// `.landFailed(failure)` by default; `.failed` reports a thrown plan without its failure.
    let result: InTurnSyncResult
    let drafts: [SyncStreamDraft]

    init(result: InTurnSyncResult = .landFailed(TurnSkeletonFailingPhaseTransport.failure), drafts: [SyncStreamDraft]? = nil) {
        self.result = result
        self.drafts = drafts ?? [outputDraft(1), outputDraft(2)]
    }

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
        InTurnSyncOutput(result, syncStream: drafts, keepsEvents: false)
    }
    func waitForWriterDrainForInTurnSync() async {}
}

/// A port the keeper is bound to (never attached) whose sync phase trips the sentinel and then
/// tries to attach another transport synchronously, as a misbehaving callback could. The attach
/// is refused too, as the other adapter-facing entries are during a body.
final class TurnSkeletonAttachingTransport: LandKeeperTransport, @unchecked Sendable {
    private let lock = NSLock()
    private weak var keeper: LandKeeper<TurnSkeletonState>?
    private var closes = 0
    let replacement = TurnSkeletonReenteringTransport(reenter: .nowhere)

    func bind(_ keeper: LandKeeper<TurnSkeletonState>) { lock.withLock { self.keeper = keeper } }
    var closeCount: Int { lock.withLock { closes } }

    var hasJoinsAwaitingSync: Bool { false }
    nonisolated func closeOutputs(for failure: LandFailure) { lock.withLock { closes += 1 } }
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
        if let keeper = lock.withLock({ self.keeper }) {
            let replacement = self.replacement
            keeper.assumeIsolated { keeper in // lint-allow: turns-isolated: a re-entry that then tries to attach another transport
                keeper.submitSyncStream([outputDraft(7)])
                keeper.setTransport(replacement)
            }
        }
        return InTurnSyncOutput(.committed(clearDirtyFlags: false), syncStream: [], keepsEvents: false)
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
    joinsWait: Bool = false,
    onJoin: Bool = false,
    onInitialize: Bool = false
) async -> (LandKeeper<TurnSkeletonState>, TurnSkeletonReenteringTransport, ReevaluationSubmissionTracker) {
    let keeper = makeKeeper(recording: true, onJoin: onJoin, onInitialize: onInitialize)
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

    @Test("An attach during a turn body is refused: the bound requester stays the gate, closed once, and the land ends")
    func attachDuringABodyIsRefused() async throws {
        let keeper = makeKeeper(recording: false)
        let port = TurnSkeletonAttachingTransport()
        port.bind(keeper)

        // Never attached: the request binds `port`, which the sentinel then closes.
        let result = await keeper.syncTurnNow(via: port, reason: .syncNow)

        guard case let .landFailed(reported) = result else {
            Issue.record("the turn returned \(result), not .landFailed")
            return
        }
        #expect(reported.kind == .keeperReentry)
        // Both re-entries refused; the gate they reach is the bound requester, closed once (a
        // second refusal and `failLand` skip the gate already closed).
        #expect(await keeper.reentryViolationsForTesting == 2)
        #expect(port.closeCount == 1)
        // The replacement was never attached, so nothing reached it.
        #expect(port.replacement.closeCount == 0)
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

    /// The settle is a turn body (#700 K1b-5a step 2): each of its port calls goes through
    /// `callOut`, and a settle requested from a callback is refused as a nested body.
    @Test("A re-entry during the settle's port calls or its draft factories ends the land in the settle turn", arguments: [
        TurnSkeletonReenteringTransport.Where.settleCheck, .settlePhase, .nestedSettle, .settleDraftFactory,
    ])
    func reentryDuringTheSettleEndsTheLand(at reenter: TurnSkeletonReenteringTransport.Where) async throws {
        let (keeper, transport, tracker) = await attachedKeeper(reenter)
        await keeper.awaitInitialization()
        #expect(await keeper.debugFreeze(generation: 1, timeout: .seconds(10)))
        transport.armSettleCheck()

        let outcome = await keeper.settleTurn(via: transport, fence: turnSkeletonSettleFence)

        guard case .failed(let reported) = outcome else {
            Issue.record("expected the settle to end the land, got \(outcome)")
            return
        }
        #expect(reported.kind == .keeperReentry)
        #expect(keeper.failure?.kind == .keeperReentry)
        #expect(await keeper.reentryViolationsForTesting == 1)
        #expect(transport.closeCount == 1)
        #expect(await keeper.bodyDepthForTesting == 0)
        // A re-entry at the in-turn check ends the land before the phase runs; nothing of a
        // refused phase is recorded, and the turn ends with the terminal entry. A factory runs
        // after the phase, so its batch is recorded whole first, as the sync-only turn's is.
        #expect(transport.settlePhaseCount == (reenter == .settleCheck ? 0 : 1))
        let recordedBatch = reenter == .settleDraftFactory ? ["sync-output"] : []
        #expect(tracker.traceForTesting == recordedBatch + ["terminal", "endTurn"])
    }

    /// The input turn's output step is a turn body's (#700 K1b-5a step 2): a draft factory of
    /// its sync phase runs in the body, outside any call out, and one that re-enters ends the land
    /// in that turn.
    @Test("A draft factory's re-entry in an input turn's sync phase ends the land in that turn")
    func inputTurnFactoryReentryEndsTheLand() async throws {
        let (keeper, transport, _) = await attachedKeeper(.draftFactory, onJoin: true)
        await keeper.awaitInitialization()

        // The join's OnJoin is applied by an input turn, whose phase returns the re-entering
        // factory.
        await #expect(throws: LandInputRejection.landClosed) {
            try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
        }

        #expect(keeper.failure?.kind == .keeperReentry)
        #expect(await keeper.reentryViolationsForTesting == 1)
        #expect(await keeper.lateReentriesAppliedForTesting == 0, "applied by the backstop, not in the turn")
        #expect(transport.closeCount == 1)
        #expect(await keeper.bodyDepthForTesting == 0)
        #expect(await keeper.currentState().value == 1, "the OnJoin applied before the phase")
    }

    /// Every port call an input turn's body makes goes through `callOut`: the fake re-enters at
    /// the nth port call made during a body, for each n until the body makes no more, and each
    /// re-entry ends the land in that call, before the body reads the call's answer. The late
    /// backstop applies none.
    @Test("A re-entry at any port call of an input turn ends the land in that call")
    func inputTurnReentryAtEveryPortCall() async throws {
        var reentered: [Int] = []
        var passes: [Int?] = []
        for n in 1...30 {
            let (keeper, transport, _) = await attachedKeeper(.nthCallInBody, onJoin: true)
            await keeper.awaitInitialization()
            transport.armNthCallInBody(n)
            var rejection: (any Error)?
            do {
                try await keeper.join(playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"))
            } catch {
                rejection = error
            }
            guard transport.reenteredAtNth else {
                #expect(rejection == nil && keeper.failure == nil, "past the last call (\(n)): \(String(describing: rejection))")
                break
            }
            reentered.append(n)
            #expect(rejection as? LandInputRejection == .landClosed, "call \(n): \(String(describing: rejection))")
            #expect(keeper.failure?.kind == .keeperReentry, "call \(n)")
            #expect(await keeper.reentryViolationsForTesting == 1, "call \(n)")
            #expect(await keeper.lateReentriesAppliedForTesting == 0, "call \(n): applied by the backstop, not in the call")
            // Applied by the call's own `callOut`: a bare call's refusal is applied by a later
            // mailbox check instead (`applyPendingTransportFailure`), with the same failure.
            #expect(await keeper.reentriesAppliedInCallForTesting == 1, "call \(n): not applied by its call's callOut")
            #expect(transport.closeCount == 1, "call \(n)")
            #expect(await keeper.bodyDepthForTesting == 0, "call \(n)")
            passes.append(keeper.failure?.position.pass)
        }
        // The calls of an OnJoin's input turn on a land without periodic sync, in order: the
        // consumed join's report (its witness, then the report), the turn's in-turn check, the
        // joins read before the phase (its witness, then the read), the recording's witness, the
        // phase, and the joins read after the committed phase (its witness, then the read).
        #expect(reentered == Array(1...9), "calls that re-entered: \(reentered)")
        // Each failure names the turn's own pass, the join report's (before the pass is
        // numbered) included.
        #expect(passes.first != nil && passes.allSatisfy { $0 == passes.first }, "the failures' passes: \(passes)")
    }

    /// Initialization is a turn body (#700 K1b-5a step 2): every port call it makes goes through
    /// `callOut`. A refusal ends the land in that call; OnInitialize had applied, and no output
    /// step follows.
    @Test("A re-entry at any port call of the initialization ends the land in that call")
    func initializationReentryAtEveryPortCall() async throws {
        var reentered: [Int] = []
        for n in 1...30 {
            let (keeper, transport, _) = await attachedKeeper(.nthCallInBody, onInitialize: true)
            transport.armNthCallInBody(n)
            await keeper.awaitInitialization()
            guard transport.reenteredAtNth else {
                #expect(keeper.failure == nil, "past the last call (\(n))")
                break
            }
            reentered.append(n)
            #expect(keeper.failure?.kind == .keeperReentry, "call \(n)")
            #expect(await keeper.reentryViolationsForTesting == 1, "call \(n)")
            #expect(await keeper.lateReentriesAppliedForTesting == 0, "call \(n): applied by the backstop, not in the call")
            #expect(await keeper.reentriesAppliedInCallForTesting == 1, "call \(n): not applied by its call's callOut")
            #expect(transport.closeCount == 1, "call \(n)")
            #expect(await keeper.bodyDepthForTesting == 0, "call \(n)")
            #expect(await keeper.currentState().value == 1, "call \(n): OnInitialize applied before the calls")
        }
        // The initialize marker's witness, the in-turn check, the joins read before the phase
        // (its witness, then the read), the recording's witness, the phase, and the joins read
        // after the committed phase (its witness, then the read).
        #expect(reentered == Array(1...8), "calls that re-entered: \(reentered)")
    }

    /// `submitSyncStream`'s own body checks its drafts' factories (#884's second track): a factory
    /// that re-enters ends the land in that body, not in the backstop.
    @Test("A draft factory that re-enters during submitSyncStream ends the land in its body")
    func submitSyncStreamFactoryReentryEndsTheLand() async throws {
        let (keeper, transport, _) = await attachedKeeper(.nowhere)
        await keeper.awaitInitialization()
        let draft = SyncStreamDraft(.output(observedTickId: 0, make: { [weak keeper] streamIndex, index in
            keeper?.assumeIsolated { $0.submitSyncStream([]) } // lint-allow: turns-isolated: a draft factory that calls back into its keeper
            return ReevaluationRecordedSyncOutput(
                index: index, turnKind: .syncOnly, observedTickId: 0,
                streamIndex: streamIndex, sequence: Int64(streamIndex), broadcastHash: 0xbeef_0007
            )
        }))

        await keeper.submitSyncStream([draft])

        #expect(keeper.failure?.kind == .keeperReentry)
        #expect(await keeper.reentryViolationsForTesting == 1)
        #expect(await keeper.lateReentriesAppliedForTesting == 0, "applied by the backstop, not in the body")
        #expect(transport.closeCount == 1)
    }

    /// J2's stale-join refusal (#234) goes through `callOut` (#700 K1b-5b): a re-entry at either
    /// of its port calls ends the land in that call, and the drain check refuses the join as
    /// shutting down before the player limit and the insert.
    @Test("A re-entry at the stale-join refusal ends the land and refuses the join", arguments: [1, 2])
    func staleRefusalReentryRefusesTheJoin(at call: Int) async throws {
        let (keeper, transport, tracker) = await attachedKeeper(.nthCallInBody, onJoin: true)
        await keeper.awaitInitialization()
        // The in-turn check (`runsSyncPhaseInTurn`), then the refusal.
        transport.armNthCallInBody(call)

        var refusal: JoinError?
        do {
            _ = try await keeper.joinReportingAdmission(
                session: PlayerSession(playerID: "p1"),
                clientID: ClientID("c1"),
                sessionID: SessionID("s1"),
                services: LandServices(),
                admitThroughTransport: true
            )
        } catch let error as JoinError {
            refusal = error
        }

        #expect(transport.reenteredAtNth)
        guard case .landShuttingDown = refusal else {
            Issue.record("the join's outcome: \(String(describing: refusal))")
            return
        }
        #expect(keeper.failure?.kind == .keeperReentry)
        #expect(await keeper.reentryViolationsForTesting == 1)
        #expect(await keeper.reentriesAppliedInCallForTesting == 1)
        #expect(await keeper.lateReentriesAppliedForTesting == 0)
        #expect(await keeper.currentState().value == 0, "no OnJoin applied")
        // The tickless land's turn record ends after the terminal entry, as after the settle's
        // and the sync-only turn's refusals (#896 round 1).
        await keeper.waitForRecorderSubmissionsForTesting()
        let fromTerminal = Array(tracker.traceForTesting.drop { $0 != "terminal" })
        #expect(fromTerminal == ["terminal", "endTurn"], "\(tracker.traceForTesting)")
    }

    /// A batch's queued failure is applied before its join report (#884's second track), so a
    /// re-entry refused in that report can't take its place as the cause.
    @Test("A queued failure in the batch stays the cause when the join report re-enters", arguments: [1, 2])
    func queuedFailureOutranksAJoinReportReentry(at call: Int) async throws {
        let (keeper, transport, _) = await attachedKeeper(.nthCallInBody, onJoin: true)
        await keeper.awaitInitialization()
        // The report's witness (1) or the report (2).
        transport.armNthCallInBody(call)
        let join = LandKeeper<TurnSkeletonState>.PendingItem.lifecycle(LandKeeper<TurnSkeletonState>.PendingLifecycleItem(
            sequence: 1_000, kind: .join, playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"),
            deviceID: nil, isGuest: nil, metadata: [:], resolverOutputs: [:], resolvedAtTick: 0
        ))
        let queued = LandKeeper<TurnSkeletonState>.PendingItem.landFailure(LandKeeper<TurnSkeletonState>.PendingLandFailureItem(
            sequence: 1_001, resolvedAtTick: 0, failure: TurnSkeletonFailingPhaseTransport.failure
        ))

        _ = await keeper.runInputTurnForTesting([join, queued])

        #expect(transport.reenteredAtNth, "the report wasn't made")
        #expect(keeper.failure?.kind == TurnSkeletonFailingPhaseTransport.failure.kind, "the cause: \(String(describing: keeper.failure))")
        #expect(await keeper.reentryViolationsForTesting == 1)
        #expect(await keeper.reentriesAppliedInCallForTesting == 1)
        #expect(await keeper.lateReentriesAppliedForTesting == 0)
        #expect(await keeper.currentState().value == 1, "the OnJoin applied before the failure item")
    }

    /// A failure in the batch stages the drain, and the join report's call-out flushes it while the
    /// turn goes on. The teardown's first step runs on the keeper, so the transport hears
    /// `landDidFail` after the failing turn's last port call, as before the move (#914 review).
    /// Limit: a keeper whose teardown runs off the keeper fails this test only if that task
    /// reaches `landDidFail` within the report's 500 ms wait.
    @Test("A failed land's teardown starts after the failing turn's join report")
    func teardownWaitsForTheFailingTurn() async throws {
        let (keeper, transport, _) = await attachedKeeper(.nowhere, onJoin: true)
        await keeper.awaitInitialization()
        transport.armReportWaitsForTeardown()
        let join = LandKeeper<TurnSkeletonState>.PendingItem.lifecycle(LandKeeper<TurnSkeletonState>.PendingLifecycleItem(
            sequence: 1_000, kind: .join, playerID: PlayerID("p1"), clientID: ClientID("c1"), sessionID: SessionID("s1"),
            deviceID: nil, isGuest: nil, metadata: [:], resolverOutputs: [:], resolvedAtTick: 0
        ))
        let queued = LandKeeper<TurnSkeletonState>.PendingItem.landFailure(LandKeeper<TurnSkeletonState>.PendingLandFailureItem(
            sequence: 1_001, resolvedAtTick: 0, failure: TurnSkeletonFailingPhaseTransport.failure
        ))

        _ = await keeper.runInputTurnForTesting([join, queued])
        // The suite's time limit bounds the wait.
        for await _ in transport.teardownReached.stream { break }

        #expect(transport.reportAndTeardownOrder == ["joinReport", "landDidFail"])
    }

    /// A refusal in initialization's turn fails the land, and the keeper starts no tick or sync
    /// loop on it (#891 review): the drain may already have run, and a loop started after it
    /// would keep the keeper alive. Unarmed, the same land starts both.
    @Test("A land whose initialization was refused starts no loops", arguments: [false, true])
    func refusedInitializationStartsNoLoops(refused: Bool) async throws {
        let keeper = LandKeeper<TurnSkeletonState>(
            definition: turnSkeletonTickLandWithOnInitialize(),
            initialState: TurnSkeletonState(),
            enableLiveStateHashRecording: true,
            autoStartLoops: true,
            enableLoopPhaseOffset: false,
            landID: "turn-skeleton:loops"
        )
        let transport = TurnSkeletonReenteringTransport(reenter: .nthCallInBody, joinsWait: false)
        transport.attach(keeper)
        await keeper.setTransport(transport)
        if refused { transport.armNthCallInBody(1) }

        await keeper.awaitInitialization()

        #expect(transport.reenteredAtNth == refused)
        #expect((keeper.failure?.kind == .keeperReentry) == refused)
        #expect((await keeper.appliedTickPhaseOffset == nil) == refused, "the tick loop")
        #expect((await keeper.appliedSyncPhaseOffset == nil) == refused, "the sync loop")
        await keeper.forceShutdown()
    }

    /// Every port call a requested sync-only turn makes goes through `callOut`, as the input
    /// turn's do.
    @Test("A re-entry at any port call of a sync-only turn ends the land in that call")
    func syncOnlyReentryAtEveryPortCall() async throws {
        var reentered: [Int] = []
        for n in 1...30 {
            let (keeper, transport, tracker) = await attachedKeeper(.nthCallInBody)
            await keeper.awaitInitialization()
            transport.armNthCallInBody(n)
            let result = await keeper.syncTurnNow(via: transport, reason: .syncNow)
            guard transport.reenteredAtNth else {
                #expect(keeper.failure == nil, "past the last call (\(n)): \(result)")
                break
            }
            reentered.append(n)
            guard case let .landFailed(reported) = result else {
                Issue.record("call \(n): the turn returned \(result), not .landFailed")
                continue
            }
            #expect(reported.kind == .keeperReentry, "call \(n)")
            #expect(await keeper.reentryViolationsForTesting == 1, "call \(n)")
            #expect(await keeper.lateReentriesAppliedForTesting == 0, "call \(n): applied by the backstop, not in the call")
            #expect(await keeper.reentriesAppliedInCallForTesting == 1, "call \(n): not applied by its call's callOut")
            #expect(transport.closeCount == 1, "call \(n)")
            #expect(tracker.traceForTesting.suffix(2) == ["terminal", "endTurn"], "call \(n): \(tracker.traceForTesting)")
        }
        // The recording's witness, the phase, and the joins read after the committed phase (its
        // witness, then the read).
        #expect(reentered == Array(1...4), "calls that re-entered: \(reentered)")
    }

    /// A failure applied outside a turn body would close the gate at depth zero, where a
    /// callback from the close isn't refused and reaches the model the failure holds (an
    /// exclusivity trap). Both paths apply it in a turn now (#700 K1b-5 plan §6, C1 and C2).
    @Test("A failure's gate close that calls back is refused: the noted failure's sync-only turn and the test hook", arguments: [false, true])
    func failureCloseReentryIsRefused(viaTestHook: Bool) async throws {
        let (keeper, transport, _) = await attachedKeeper(.closeOutputs)
        await keeper.awaitInitialization()
        let noted = LandFailure(kind: .eventEncode, detail: "noted outside a turn", position: LandFailurePosition(stage: .eventFlush))
        if viaTestHook {
            await keeper.failLandForTesting(noted)
        } else {
            keeper.notePendingFailure(noted)
            let result = await keeper.syncTurnNow(via: transport, reason: .syncNow)
            #expect(result == .landFailed(noted))
        }
        // Refused, and the land failed once, with the failure it applied: a re-entry that ended
        // it instead would be `keeperReentry`.
        #expect(await keeper.reentryViolationsForTesting == 1)
        #expect(keeper.failure == noted)
        // The failure's close, and the refusing entry's own close nested inside it (the
        // same-gate skip covers only a refusal that closed first). A close is idempotent.
        #expect(transport.closeCount == 2)
        #expect(await keeper.bodyDepthForTesting == 0)
    }

    /// Every port call the settle makes goes through `callOut`, as the input turn's do; the
    /// terminal entry is recorded before the turn's end.
    @Test("A re-entry at any port call of the settle ends the land in that call")
    func settleReentryAtEveryPortCall() async throws {
        var reentered: [Int] = []
        for n in 1...30 {
            let (keeper, transport, tracker) = await attachedKeeper(.nthCallInBody)
            await keeper.awaitInitialization()
            #expect(await keeper.debugFreeze(generation: 1, timeout: .seconds(10)))
            transport.armNthCallInBody(n)
            let outcome = await keeper.settleTurn(via: transport, fence: turnSkeletonSettleFence)
            guard transport.reenteredAtNth else {
                #expect(keeper.failure == nil, "past the last call (\(n)): \(outcome)")
                break
            }
            reentered.append(n)
            guard case .failed(let reported) = outcome else {
                Issue.record("call \(n): expected the settle to end the land, got \(outcome)")
                continue
            }
            #expect(reported.kind == .keeperReentry, "call \(n)")
            #expect(await keeper.reentryViolationsForTesting == 1, "call \(n)")
            #expect(await keeper.lateReentriesAppliedForTesting == 0, "call \(n): applied by the backstop, not in the call")
            // Applied by the call's own `callOut`: a bare call's refusal is applied by a later
            // mailbox check instead (`applyPendingTransportFailure`), with the same failure.
            #expect(await keeper.reentriesAppliedInCallForTesting == 1, "call \(n): not applied by its call's callOut")
            #expect(transport.closeCount == 1, "call \(n)")
            #expect(tracker.traceForTesting.suffix(2) == ["terminal", "endTurn"], "call \(n): \(tracker.traceForTesting)")
        }
        // The in-turn check, the recording's witness, and the settle phase.
        #expect(reentered == Array(1...3), "calls that re-entered: \(reentered)")
    }

    /// The body applies `.failed` while it holds the keeper's model: `failLand` runs inside the
    /// hold, so this path traps if it reaches `self.model`.
    @Test("A sync phase that reports a failed plan without its failure ends the land in that turn")
    func failedPlanWithoutItsFailureEndsTheLand() async throws {
        let keeper = makeKeeper(recording: true)
        let transport = TurnSkeletonFailingPhaseTransport(result: .failed, drafts: [])
        await keeper.setTransport(transport)
        let tracker = await keeper.recorderSubmissionsForTesting
        tracker.startTraceForTesting()

        let result = await keeper.syncTurnNow(via: transport, reason: .syncNow)

        #expect(result == .failed)
        let failure = try #require(keeper.failure)
        #expect(failure.kind == .syncPlan)
        #expect(failure.detail == "the transport reported a failed sync plan")
        #expect(tracker.traceForTesting == ["terminal", "endTurn"])
        #expect(await keeper.inTurnSyncDueForTesting == false)
        #expect(await withinHangBound { await keeper.waitUntilDrainStartedForTesting() })
        await keeper.waitUntilDrained()
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
        // The follow-up may already have asked again (and found none), so at least once.
        #expect(transport.joinsAskedCount >= 1)
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

    @Test("A tickless intake whose input the backstop drops is refused, not reported applied", arguments: [true, false])
    func backstopDropInAnIntakeIsRefused(action: Bool) async throws {
        let keeper = LandKeeper<TurnSkeletonState>(
            definition: turnSkeletonLandWithIntakes(), initialState: TurnSkeletonState(),
            autoStartLoops: false, landID: "turn-skeleton:1"
        )
        let player = PlayerID("p1"), client = ClientID("c1"), session = SessionID("s1")
        try await keeper.join(playerID: player, clientID: client, sessionID: session)
        // A re-entry from inside the intake's segment, after its append, that no call out sees:
        // the backstop in `withTurn`'s defer ends the land and drops the appended input.
        await keeper.setInTurnProbeForTesting { label in
            guard label == "action-queued" || label == "client-event-queued" else { return }
            keeper.assumeIsolated { $0.submitSyncStream([outputDraft(9)]) } // lint-allow: turns-isolated: a re-entry inside an intake's segment, for the backstop's drop
        }
        await #expect(throws: LandInputRejection.landClosed) {
            if action {
                _ = try await keeper.handleActionEnvelope(
                    ActionEnvelope(typeIdentifier: String(describing: TurnSkeletonAction.self),
                                   payload: AnyCodable(TurnSkeletonAction(value: 7))),
                    playerID: player, clientID: client, sessionID: session
                )
            } else {
                try await keeper.handleClientEvent(
                    AnyClientEvent(TurnSkeletonEvent(value: 7)), playerID: player, clientID: client, sessionID: session
                )
            }
        }
        #expect(keeper.failure?.kind == .keeperReentry)
        #expect(await keeper.lateReentriesAppliedForTesting == 1)
        #expect(await keeper.currentState().value == 0)
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
