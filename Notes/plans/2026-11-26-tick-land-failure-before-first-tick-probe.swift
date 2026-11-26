// Probe for Notes/plans/2026-11-26-tick-land-failure-before-first-tick.md (#901). Not compiled
// here: it ran as an extension appended to Tests/SwiftStateTreeTests/InTurnSyncFoldReportTests.swift
// (it uses that file's private `foldReportLandEmitting()` and `makeKeeper`), at #896's round 1
// head, and printed the lines quoted in the plan's Probes section.

// PROBE (#901 design, not for commit): a tick land's failure outside a tick turn, before and
// after the first tick, recorded and replayed. Prints the failure's position, the tick counters'
// effect (ticks), and the replay's server-event result.
extension InTurnSyncFoldReportTests {
    enum Probe901Site: String, CaseIterable {
        case failLandDefault, testBodyCallOut, lateBackstop, mailboxThenSyncOnly, syncOnlyFirstCall, tick0FoldNote, tick0JoinsRead
    }

    @Test("PROBE 901", arguments: Probe901Site.allCases, [false, true])
    func probe901(site: Probe901Site, afterFirstTick: Bool) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("p901-\(UUID().uuidString).sstr").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let transport = FoldRecordingTransport(records: true)
        let keeper = try await makeKeeper(transport, definition: foldReportLandEmitting(), recording: true)
        let deadline = ContinuousClock.now
        if afterFirstTick { await keeper.stepTickOnceForTesting(at: deadline) }
        let reenter: () -> Void = { keeper.assumeIsolated { $0.submitSyncStream([]) } } // lint-allow: turns-isolated: probe
        switch site {
        case .failLandDefault:
            await keeper.failLandForTesting(LandFailure(kind: .syncPlan, detail: "probe", position: LandFailurePosition(stage: .syncPhase)))
        case .testBodyCallOut:
            _ = try? await keeper.runTestBodyForTesting(staging: 0, effect: { _ in }, callingOut: reenter)
        case .lateBackstop:
            _ = try? await keeper.runTestBodyForTesting(staging: 0, effect: { _ in }, observe: { _ in reenter() })
        case .mailboxThenSyncOnly:
            keeper.notePendingFailure(LandFailure(kind: .syncPlan, detail: "probe", position: LandFailurePosition(stage: .syncPhase)))
            await keeper.setNextTickDeadlineForTesting(deadline + .seconds(5))
            await keeper.runSyncLoopIterationForTesting(at: deadline - .seconds(10))
        case .syncOnlyFirstCall:
            transport.armNthCallInBody(1, keeper: keeper, joinsWait: false)
            await keeper.setNextTickDeadlineForTesting(deadline + .seconds(5))
            await keeper.runSyncLoopIterationForTesting(at: deadline - .seconds(10))
        case .tick0FoldNote, .tick0JoinsRead:
            // Inside a tick turn: tick 0 (or tick 1 after the first) itself.
            let reentry: FoldRecordingTransport.Reentry = site == .tick0FoldNote ? .foldNote : .joinsRead
            transport.arm(reentry, keeper: keeper, joinsWait: reentry != .foldNote)
            let base = deadline + .seconds(afterFirstTick ? 1 : 0)
            if reentry == .foldNote {
                await keeper.setNextTickDeadlineForTesting(base + .seconds(1))
                await keeper.runSyncLoopIterationForTesting(at: base + .seconds(1) - .milliseconds(1))
            }
            await keeper.stepTickOnceForTesting(at: base + .seconds(1) + .milliseconds(1))
        }
        let failure = keeper.failure
        let ticks = await keeper.currentState().ticks
        guard failure != nil else {
            print("probe-901 site=\(site.rawValue) after=\(afterFirstTick) NO-FAILURE ticks=\(ticks)")
            await keeper.forceShutdown()
            return
        }
        await keeper.waitForRecorderSubmissionsForTesting()
        let recorder = try #require(await keeper.getReevaluationRecorder())
        try await recorder.save(to: path)
        await keeper.forceShutdown()
        let result = try await ReevaluationEngine.run(definition: foldReportLandEmitting(), initialState: FoldReportState(), recordFilePath: path)
        print("probe-901 site=\(site.rawValue) after=\(afterFirstTick) kind=\(failure!.kind) tickId=\(String(describing: failure!.position.tickId)) endsInputs=\(String(describing: failure!.position.endsInputs)) ticks=\(ticks) mismatches=\(result.serverEventMismatches.map(\.tickId)) verification=\(result.serverEventVerification)")
    }

    @Test("PROBE 901 shutdown before the first tick", arguments: [false, true])
    func probe901Shutdown(afterFirstTick: Bool) async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("p901s-\(UUID().uuidString).sstr").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let transport = FoldRecordingTransport(records: true)
        let keeper = try await makeKeeper(transport, definition: foldReportLandEmitting(), recording: true)
        if afterFirstTick { await keeper.stepTickOnceForTesting(at: ContinuousClock.now) }
        let recorder = try #require(await keeper.getReevaluationRecorder())
        await keeper.forceShutdown()
        await keeper.waitForRecorderSubmissionsForTesting()
        try await recorder.save(to: path)
        let result = try await ReevaluationEngine.run(definition: foldReportLandEmitting(), initialState: FoldReportState(), recordFilePath: path)
        print("probe-901 site=shutdown after=\(afterFirstTick) ticks=\(await keeper.currentState().ticks) mismatches=\(result.serverEventMismatches.map(\.tickId)) verification=\(result.serverEventVerification)")
    }
}
