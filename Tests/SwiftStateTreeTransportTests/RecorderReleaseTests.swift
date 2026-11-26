// Tests/SwiftStateTreeTransportTests/RecorderReleaseTests.swift
//
// A keeper that is dropped releases its re-evaluation recorder, and the recorder's deinit
// deletes its unsaved spool file (#910). The tick and sync loops hold the keeper weakly while
// they sleep, so a started loop doesn't keep a dropped keeper alive. The adapter holds its keeper
// on purpose (#346); the drain breaks that link, so an attached keeper is released only after it.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@Suite("A dropped keeper releases its recorder and its spool file (#910)", .serialized)
struct RecorderReleaseTests {
    private struct Outcome {
        let recorderReleased: Bool
        let spoolExists: Bool
        let spoolPath: String
    }

    /// Opens the recorder's spool (the metadata does), keeps only a weak reference, runs `drop`
    /// with the keeper, and waits up to two seconds for the recorder to go.
    private func dropping<K>(_ make: () async -> (keeper: K, recorder: ReevaluationRecorder?), before drop: (K) async -> Void = { _ in }) async throws -> Outcome {
        weak var recorder: ReevaluationRecorder?
        var path: String?
        do {
            let made = await make()
            let r = try #require(made.recorder)
            await r.setMetadata(ReevaluationRecordMetadata(
                landID: "recorder-release", landType: "recorder-release",
                createdAt: Date(timeIntervalSince1970: 1_800_000_000), metadata: [:],
                landDefinitionID: "recorder-release", rngSeed: DeterministicSeed.fromLandID("recorder-release")
            ))
            path = await r.getSpoolPath()
            recorder = r
            await drop(made.keeper)
        }
        for _ in 0..<200 where recorder != nil {
            try await Task.sleep(for: .milliseconds(10)) // wall-clock: a deinit has no event to wait on; a bounded poll until the weak reference clears, 2 s far past a loop's next 10 ms wake-up
        }
        // The deinit's discard runs on the writer's queue.
        let spool = try #require(path)
        for _ in 0..<100 where FileManager.default.fileExists(atPath: spool) && recorder == nil {
            try await Task.sleep(for: .milliseconds(10)) // wall-clock: the file's removal runs on the writer's queue, with no event the test can await; a bounded poll
        }
        return Outcome(recorderReleased: recorder == nil, spoolExists: FileManager.default.fileExists(atPath: spool), spoolPath: spool)
    }

    private func keeper(_ definition: LandDefinition<VerifierState>, loops: Bool) async -> (keeper: LandKeeper<VerifierState>, recorder: ReevaluationRecorder?) {
        let keeper = LandKeeper<VerifierState>(
            definition: definition, initialState: VerifierState(),
            enableLiveStateHashRecording: true, autoStartLoops: loops
        )
        await keeper.awaitInitialization()
        // Long enough for a 10 ms loop to have run.
        if loops { try? await Task.sleep(for: .milliseconds(50)) } // wall-clock: lets a 10 ms loop start and bind its keeper, so the drop happens with the loop running; a loop not yet started would hide the leak, never cause a false failure
        return (keeper, await keeper.getReevaluationRecorder())
    }

    @Test("No loop and no adapter: the recorder goes and deletes its spool")
    func plainKeeper() async throws {
        let outcome = try await dropping { await keeper(makeVerifierLand(), loops: false) }
        #expect(outcome.recorderReleased)
        #expect(!outcome.spoolExists)
    }

    @Test("A started tick loop doesn't keep a dropped keeper")
    func tickLoop() async throws {
        let land = Land("recorder-release-tick", using: VerifierState.self) {
            Lifetime { Tick(every: .milliseconds(10)) { state, _ in state.ticks += 1 } }
        }
        let outcome = try await dropping { await keeper(land, loops: true) }
        #expect(outcome.recorderReleased)
        #expect(!outcome.spoolExists)
    }

    @Test("A started sync loop doesn't keep a dropped keeper")
    func syncLoop() async throws {
        let land = Land("recorder-release-sync", using: VerifierState.self) {
            Lifetime { StateSync(every: .milliseconds(10)) { _, _ in } }
        }
        let outcome = try await dropping { await keeper(land, loops: true) }
        #expect(outcome.recorderReleased)
        #expect(!outcome.spoolExists)
    }

    @Test("An attached adapter keeps its keeper until the drain; after forceShutdown both go")
    func adapterUntilTheDrain() async throws {
        let kept = try await dropping {
            let fixture = await VerifierFixture.make(encoding: .json)
            return (fixture, await fixture.keeper.getReevaluationRecorder())
        }
        // The adapter's link is a cycle by design (#346), broken by the drain's last call.
        #expect(!kept.recorderReleased)
        #expect(kept.spoolExists)
        // The kept keeper lives to the process's end; its file is removed here, not left behind.
        try? FileManager.default.removeItem(atPath: kept.spoolPath)

        let drained = try await dropping({
            let fixture = await VerifierFixture.make(encoding: .json)
            return (fixture, await fixture.keeper.getReevaluationRecorder())
        }, before: { fixture in await fixture.keeper.forceShutdown() })
        #expect(drained.recorderReleased)
        #expect(!drained.spoolExists)
    }
}
