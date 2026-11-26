// Tests/SwiftStateTreeTests/TickLandFailureBeforeFirstTickTests.swift
//
// A tick land's failure outside a tick turn writes its terminal entry into the frame of the last
// tick, frame 0 before any tick. Replay skips a frame's handler only when the failure ended its
// inputs, so a failure in a frame that hasn't committed (whose handler never ran) must say so
// (#901). Each case records the failure, replays it, and checks the server events.

import Foundation
import Testing
@testable import SwiftStateTree

/// `foldReportLandEmitting` with an OnInitialize: only a land with one runs initialization's
/// turn body, whose call outs the initialization case refuses.
private func foldReportLandInitializing() -> LandDefinition<FoldReportState> {
    Land("fold-report-test", using: FoldReportState.self) {
        ServerEvents { Register(FoldTickEvent.self) }
        Lifetime {
            OnInitialize { _, _ in }
            Tick(every: .seconds(3600)) { state, ctx in
                state.ticks += 1
                ctx.emitEvent(FoldTickEvent(ticks: state.ticks), to: .all)
            }
            StateSync(every: .seconds(3600)) { _, _ in }
        }
    }
}

@Suite("A tick land's failure before its first tick ends frame 0's inputs (#901)", .timeLimit(.minutes(1)))
struct TickLandFailureBeforeFirstTickTests {
    /// Where the land fails, outside any tick turn.
    enum Site: String, CaseIterable {
        /// A sync-only turn's re-entry at its first port call (the sync-phase query).
        case syncOnlyFirstCall
        /// A sync-only turn's re-entry at its second port call (the phase).
        case syncOnlySecondCall
        /// A failure a transport noted outside a turn, applied by the next sync-only turn.
        case mailbox
        /// A settle's re-entry at its first call out.
        case settle
        /// A body's re-entry outside any call out, applied after the body (the intakes' path).
        case lateBackstop
    }

    private static let failure = LandFailure(kind: .syncPlan, detail: "the transport's noted failure", position: LandFailurePosition(stage: .syncPhase))

    @Test("a failure outside a tick turn replays as it ran, before and after the first tick",
          arguments: Site.allCases, [false, true])
    func failureOutsideATickReplays(site: Site, afterFirstTick: Bool) async throws {
        let transport = FoldRecordingTransport(records: true)
        let keeper = try await InTurnSyncFoldReportTests().makeKeeper(transport, definition: foldReportLandEmitting(), recording: true)
        let deadline = ContinuousClock.now
        if afterFirstTick { await keeper.stepTickOnceForTesting(at: deadline) }
        switch site {
        case .syncOnlyFirstCall, .syncOnlySecondCall:
            transport.armNthCallInBody(site == .syncOnlyFirstCall ? 1 : 2, keeper: keeper, joinsWait: false)
            await Self.runSyncOnlyTurn(keeper, deadline: deadline)
            #expect(transport.reenteredAtNth)
        case .mailbox:
            keeper.notePendingFailure(Self.failure)
            await Self.runSyncOnlyTurn(keeper, deadline: deadline)
        case .settle:
            try #require(await keeper.debugFreeze(generation: 1, timeout: .seconds(10)))
            transport.armNthCallInBody(1, keeper: keeper, joinsWait: false)
            let outcome = await keeper.settleTurn(
                via: transport,
                fence: LandKeeper<FoldReportState>.SettleFence(generation: 1, deadline: .now + .seconds(10))
            )
            guard case .failed = outcome else {
                Issue.record("the settle's outcome: \(outcome)")
                return
            }
        case .lateBackstop:
            try await keeper.runTestBodyForTesting(staging: 0, effect: { _ in }, observe: { _ in
                keeper.assumeIsolated { $0.submitSyncStream([]) } // lint-allow: turns-isolated: the synchronous callback the sentinel refuses
            })
            #expect(await keeper.lateReentriesAppliedForTesting == 1)
        }

        let failure = try #require(keeper.failure)
        #expect(failure.kind == (site == .mailbox ? .syncPlan : .keeperReentry))
        // Before the first tick no handler ran in frame 0, so the failure ended its inputs; after
        // it, the frame is the committed tick, whose handler ran.
        #expect(failure.position.endsInputs == (afterFirstTick ? nil : true))
        #expect(await keeper.currentState().ticks == (afterFirstTick ? 1 : 0))
        try await Self.expectReplayMatches(keeper)
    }

    /// Initialization's first call out re-enters: the land fails before any tick (#901).
    @Test("a refused initialization replays as it ran")
    func refusedInitializationReplays() async throws {
        let transport = FoldRecordingTransport(records: true, reentersAtFirstPhaseQuery: true)
        let definition = foldReportLandInitializing()
        let landID = "\(definition.id):\(UUID().uuidString)"
        let keeper = LandKeeper<FoldReportState>(
            definition: definition,
            initialState: FoldReportState(),
            enableLiveStateHashRecording: true,
            enableLoopPhaseOffset: false,
            landID: landID,
            transport: transport
        )
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
        await keeper.awaitInitialization()

        let failure = try #require(keeper.failure)
        #expect(failure.kind == .keeperReentry)
        #expect(failure.position.endsInputs == true)
        #expect(await keeper.currentState().ticks == 0)
        try await Self.expectReplayMatches(keeper, definition: foldReportLandInitializing())
    }

    /// Controls: a failure inside the first tick turn keeps the flag its site passes. The fold
    /// report sits before the inputs (ended); the joins read after the tick's commit (the handler
    /// ran).
    @Test("a failure inside the first tick turn replays as it ran", arguments: [
        FoldRecordingTransport.Reentry.foldNote, .joinsRead,
    ])
    func failureInsideTheFirstTickReplays(_ reentry: FoldRecordingTransport.Reentry) async throws {
        let transport = FoldRecordingTransport(records: true)
        let keeper = try await InTurnSyncFoldReportTests().makeKeeper(transport, definition: foldReportLandEmitting(), recording: true)
        let deadline = ContinuousClock.now
        transport.arm(reentry, keeper: keeper, joinsWait: reentry != .foldNote)
        if reentry == .foldNote {
            await keeper.setNextTickDeadlineForTesting(deadline + .seconds(1))
            await keeper.runSyncLoopIterationForTesting(at: deadline + .seconds(1) - .milliseconds(1))
        }
        await keeper.stepTickOnceForTesting(at: deadline + .seconds(1) + .milliseconds(1))

        let failure = try #require(keeper.failure)
        #expect(failure.kind == .keeperReentry)
        #expect(failure.position.endsInputs == (reentry == .foldNote ? true : nil))
        #expect(await keeper.currentState().ticks == (reentry == .foldNote ? 0 : 1))
        try await Self.expectReplayMatches(keeper)
    }

    /// One sync-only turn, well before the next tick's deadline.
    private static func runSyncOnlyTurn(_ keeper: LandKeeper<FoldReportState>, deadline: ContinuousClock.Instant) async {
        await keeper.setNextTickDeadlineForTesting(deadline + .seconds(5))
        await keeper.runSyncLoopIterationForTesting(at: deadline - .seconds(10))
    }

    /// Saves the keeper's record, shuts it down, and replays the record: no server-event
    /// mismatch, and the events verified. The record must also carry the failure itself, as
    /// live reported it, in `frame`: without its terminal entry a record of a land that failed
    /// before its first tick has no frame at all, so replay steps no tick and the server-event
    /// checks pass on nothing.
    private static func expectReplayMatches(
        _ keeper: LandKeeper<FoldReportState>,
        definition: LandDefinition<FoldReportState> = foldReportLandEmitting(),
        frame: Int64 = 0
    ) async throws {
        let liveFailure = try #require(keeper.failure)
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("failure-before-first-tick-\(UUID().uuidString).sstr").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        await keeper.waitForRecorderSubmissionsForTesting()
        let recorder = try #require(await keeper.getReevaluationRecorder())
        try await recorder.save(to: path)
        await keeper.forceShutdown()
        let result = try await ReevaluationEngine.run(
            definition: definition,
            initialState: FoldReportState(),
            recordFilePath: path
        )
        #expect(result.liveFailure == liveFailure, "\(String(describing: result.liveFailure)) vs \(liveFailure)")
        let recorded = try await ReevaluationRecordFile.openSource(filePath: path).getLandFailure()
        #expect(recorded?.tickId == frame, "the terminal entry's frame: \(String(describing: recorded?.tickId))")
        #expect(result.serverEventMismatches.isEmpty, "\(result.serverEventMismatches.map(\.tickId))")
        #expect(result.serverEventVerification == .passed)
    }
}
