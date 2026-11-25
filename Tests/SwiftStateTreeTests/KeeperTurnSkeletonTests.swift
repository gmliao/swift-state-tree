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

/// An in-turn transport that calls back into its keeper's `submitSyncStream` from inside one
/// of the keeper's synchronous calls: the sync phase, or the joins-awaiting-sync read. It
/// reads its own gate right after the refused call returns.
final class TurnSkeletonReenteringTransport: LandKeeperTransport, @unchecked Sendable {
    enum Where { case nowhere, phase, joinsAwaitingSync }

    private let lock = NSLock()
    private let reenter: Where
    private weak var keeper: LandKeeper<TurnSkeletonState>?
    private var closes = 0
    private var closedAtReentry: Bool?
    private var phases = 0

    init(reenter: Where) { self.reenter = reenter }

    func attach(_ keeper: LandKeeper<TurnSkeletonState>) { lock.withLock { self.keeper = keeper } }

    /// Whether the gate was closed right after the refused call returned (nil: no re-entry).
    var gateClosedAtReentry: Bool? { lock.withLock { closedAtReentry } }
    var closeCount: Int { lock.withLock { closes } }
    var phaseCount: Int { lock.withLock { phases } }

    private func reenterNow() {
        guard let keeper = lock.withLock({ self.keeper }) else { return }
        keeper.assumeIsolated { $0.submitSyncStream([outputDraft(99)]) } // lint-allow: turns-isolated: the synchronous callback the sentinel refuses
        lock.withLock { closedAtReentry = closes > 0 }
    }

    nonisolated func closeOutputs(for failure: LandFailure) {
        lock.withLock { closes += 1 }
    }

    var hasJoinsAwaitingSync: Bool {
        if reenter == .joinsAwaitingSync { reenterNow() }
        return false
    }

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
        lock.withLock { phases += 1 }
        if reenter == .phase { reenterNow() }
        // Otherwise a success, so only the re-entry can fail the turn.
        return InTurnSyncOutput(.committed(clearDirtyFlags: false), syncStream: [outputDraft(1)])
    }
    func waitForWriterDrainForInTurnSync() async {}
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

private struct BodyError: Error {}

@Suite("The turn skeleton: outputs, the depth and the re-entry sentinel (#700 K1b-5a)", .timeLimit(.minutes(1)))
struct KeeperTurnSkeletonTests {
    @Test("A re-entry during a requested sync-only turn ends the land in that turn", arguments: [
        TurnSkeletonReenteringTransport.Where.phase, .joinsAwaitingSync,
    ])
    func reentryEndsTheLandInTheTurn(at reenter: TurnSkeletonReenteringTransport.Where) async throws {
        let keeper = makeKeeper(recording: true)
        let transport = TurnSkeletonReenteringTransport(reenter: reenter)
        transport.attach(keeper)
        await keeper.setTransport(transport)
        let tracker = await keeper.recorderSubmissionsForTesting
        tracker.startTraceForTesting()

        // An otherwise idle land: this turn is the only step it takes.
        let result = await keeper.syncTurnNow(via: transport, reason: .syncNow)

        guard case let .landFailed(reported) = result else {
            Issue.record("the turn returned \(result), not .landFailed")
            return
        }
        #expect(reported.kind == .keeperReentry)
        #expect(keeper.failure?.kind == .keeperReentry)
        // Closed by the sentinel, inside the transport's call, before the turn went on.
        #expect(transport.gateClosedAtReentry == true)
        #expect(await keeper.reentryViolationsForTesting == 1)
        #expect(await keeper.bodyDepthForTesting == 0)
        // The refused draft was never numbered; the turn's records: the phase's own draft
        // (recorded before the failure when the re-entry came after the phase), the terminal
        // entry, then the turn's end.
        let trace = tracker.traceForTesting
        switch reenter {
        case .phase:
            #expect(Array(trace.prefix(2)) == ["terminal", "endTurn"], "trace \(trace)")
        case .joinsAwaitingSync:
            #expect(Array(trace.prefix(3)) == ["sync-output", "terminal", "endTurn"], "trace \(trace)")
        case .nowhere:
            break
        }
        // No follow-up turn was scheduled from the refused answer.
        #expect(await keeper.joinSyncTurnsForTesting == 0)
    }

    @Test("Without a re-entry the same turn commits, and nothing is refused")
    func noReentryCommits() async throws {
        let keeper = makeKeeper(recording: true)
        let transport = TurnSkeletonReenteringTransport(reenter: .nowhere)
        transport.attach(keeper)
        await keeper.setTransport(transport)
        let tracker = await keeper.recorderSubmissionsForTesting
        tracker.startTraceForTesting()

        #expect(await keeper.syncTurnNow(via: transport, reason: .syncNow) == .committed(clearDirtyFlags: false))
        #expect(keeper.failure == nil)
        #expect(transport.closeCount == 0)
        #expect(await keeper.reentryViolationsForTesting == 0)
        #expect(Array(tracker.traceForTesting.prefix(2)) == ["sync-output", "endTurn"])
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
                effect: { applied.bump() },
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
            effect: { order.add("effect") },
            observe: { _ in order.add("body end") }
        )
        #expect(order.entries == ["body end", "effect", "effect", "effect"])
    }
}

private final class OrderLog: @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    func add(_ s: String) { lock.withLock { log.append(s) } }
    var entries: [String] { lock.withLock { log } }
}
