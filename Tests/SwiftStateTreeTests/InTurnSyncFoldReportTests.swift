// Tests/SwiftStateTreeTests/InTurnSyncFoldReportTests.swift
//
// The keeper reports each in-turn sync fold to its transport (`noteInTurnSyncFold`), marked
// overdue when the tick's deadline had already passed, and only when the transport records
// folds (`recordsInTurnSyncFolds`, read when the transport is attached).

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
            Tick(every: .seconds(3600)) { (state: inout FoldReportState, _: LandContext) in
                state.ticks += 1
            }
            StateSync(every: .seconds(3600)) { (_: FoldReportState, _: LandContext) in }
        }
    }
}

/// In-turn transport that records the folds it is told about.
private final class FoldRecordingTransport: LandKeeperTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var notes: [Bool] = []
    let records: Bool

    init(records: Bool) { self.records = records }

    var folds: [Bool] { lock.withLock { notes } }

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { true }
    var recordsInTurnSyncFolds: Bool { records }
    func noteInTurnSyncFold(overdue: Bool) { lock.withLock { notes.append(overdue) } }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool
    ) -> InTurnSyncResult {
        includeSync ? .committed(clearDirtyFlags: true) : .notRequested
    }
}

@Suite("In-turn sync: folds reported to the transport", .timeLimit(.minutes(1)))
struct InTurnSyncFoldReportTests {
    private func makeKeeper(_ transport: FoldRecordingTransport) async throws -> LandKeeper<FoldReportState> {
        let keeper = LandKeeper<FoldReportState>(
            definition: foldReportLand(),
            initialState: FoldReportState(),
            enableLoopPhaseOffset: false,
            transport: transport
        )
        #expect(await keeper.isUsingInTurnSync())
        try await Self.waitForLoops(keeper)
        return keeper
    }

    /// The keeper initializes, and starts its loops, on the first join; the fold needs the tick
    /// task. Waits until both loops are configured.
    private static func waitForLoops(_ keeper: LandKeeper<FoldReportState>) async throws {
        try await keeper.join(
            playerID: PlayerID("fold-player"),
            clientID: ClientID("fold-client"),
            sessionID: SessionID("fold-session")
        )
        for _ in 0..<200 {
            let tick = await keeper.appliedTickPhaseOffset
            let sync = await keeper.appliedSyncPhaseOffset
            if tick != nil && sync != nil { return }
            try await safeTaskSleep(for: .milliseconds(5))
        }
        Issue.record("the keeper's loops did not start")
    }

    /// One sync loop iteration with the next tick `untilTick` away (negative: overdue), then
    /// the tick that takes a fold.
    private func syncThenTick(_ keeper: LandKeeper<FoldReportState>, untilTick: Duration) async {
        await keeper.setNextTickDeadlineForTesting(ContinuousClock.now + untilTick)
        await keeper.runSyncLoopIterationForTesting()
        await keeper.stepTickOnce()
    }

    @Test("each fold is reported once, overdue when the tick's deadline had passed")
    func foldsAreReported() async throws {
        let transport = FoldRecordingTransport(records: true)
        let keeper = try await makeKeeper(transport)
        await syncThenTick(keeper, untilTick: .milliseconds(1))     // coincident
        await syncThenTick(keeper, untilTick: .milliseconds(-20))   // overdue
        await syncThenTick(keeper, untilTick: .seconds(10))         // no fold: a sync-only turn
        #expect(transport.folds == [false, true])
        #expect(await keeper.foldedSyncs == 2)
        #expect(await keeper.overdueFoldedSyncs == 1)
        await keeper.forceShutdown()
    }

    @Test("a transport that doesn't record folds is not called")
    func notCalledWhenNotRecording() async throws {
        let transport = FoldRecordingTransport(records: false)
        let keeper = try await makeKeeper(transport)
        await syncThenTick(keeper, untilTick: .milliseconds(1))
        await syncThenTick(keeper, untilTick: .milliseconds(-20))
        #expect(transport.folds.isEmpty)
        #expect(await keeper.foldedSyncs == 2, "the keeper's own counters still count")
        await keeper.forceShutdown()
    }

    @Test("the recording flag is read when the transport is attached with setTransport")
    func flagReadOnSetTransport() async throws {
        let keeper = LandKeeper<FoldReportState>(
            definition: foldReportLand(),
            initialState: FoldReportState(),
            enableLoopPhaseOffset: false
        )
        let transport = FoldRecordingTransport(records: true)
        await keeper.setTransport(transport)
        #expect(await keeper.isUsingInTurnSync())
        try await Self.waitForLoops(keeper)
        await syncThenTick(keeper, untilTick: .milliseconds(-20))
        #expect(transport.folds == [true])
        await keeper.forceShutdown()
    }
}
