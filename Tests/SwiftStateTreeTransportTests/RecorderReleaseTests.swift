// Tests/SwiftStateTreeTransportTests/RecorderReleaseTests.swift
//
// A keeper that is dropped releases its re-evaluation recorder, and the recorder's deinit
// deletes its unsaved spool file (#910). The tick and sync loops hold the keeper weakly while
// they sleep, so a started loop doesn't keep a dropped keeper alive. The adapter holds its keeper
// on purpose (#346); the drain breaks that link, so an attached keeper is released only after it.

import Foundation
import Testing
import SwiftStateTreeTestSupport
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@Suite("A dropped keeper releases its recorder and its spool file (#910)", .serialized)
struct RecorderReleaseTests {
    private struct Outcome {
        let recorderReleased: Bool
        let spoolExists: Bool
        let spoolPath: String
    }

    /// Polls `condition` every 10 ms until it holds or `testHangBound` passes; `false` on the bound.
    private func poll(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + testHangBound
        while !condition() {
            guard ContinuousClock.now < deadline else { return false } // wall-clock: the hang bound of the poll below, never reached by a passing run
            try await Task.sleep(for: .milliseconds(10)) // wall-clock: a deinit, and the file removal on the writer's queue, have no event the test can await; a poll bounded by the hang bound, which a passing run leaves at once
        }
        return true
    }

    /// Opens the recorder's spool (the metadata does), keeps only a weak reference, runs `drop`
    /// with the keeper, and waits, up to the hang bound, for the recorder to go and its file with it.
    private func dropping<K>(_ make: () async throws -> (keeper: K, recorder: ReevaluationRecorder?), before drop: (K) async -> Void = { _ in }) async throws -> Outcome {
        weak var recorder: ReevaluationRecorder?
        var path: String?
        do {
            let made = try await make()
            let r = try #require(made.recorder)
            path = try await openSpool(r)
            recorder = r
            await drop(made.keeper)
        }
        let released = try await poll { recorder == nil }
        let spool = try #require(path)
        // The deinit's discard runs on the writer's queue.
        let removed = released ? try await poll { !FileManager.default.fileExists(atPath: spool) } : false
        return Outcome(recorderReleased: released, spoolExists: !removed, spoolPath: spool)
    }

    private func openSpool(_ recorder: ReevaluationRecorder) async throws -> String {
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: "recorder-release", landType: "recorder-release",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000), metadata: [:],
            landDefinitionID: "recorder-release", rngSeed: DeterministicSeed.fromLandID("recorder-release")
        ))
        return try #require(await recorder.getSpoolPath())
    }

    /// A keeper on `definition`. With `started`, it returns after the loop's handler has run once
    /// (the log's first entry): the loop has bound its keeper at least once before the drop.
    private func keeper(_ definition: LandDefinition<VerifierState>, started: EventLog? = nil) async throws -> (keeper: LandKeeper<VerifierState>, recorder: ReevaluationRecorder?) {
        let keeper = LandKeeper<VerifierState>(
            definition: definition, initialState: VerifierState(),
            enableLiveStateHashRecording: true, autoStartLoops: started != nil
        )
        await keeper.awaitInitialization()
        if let started {
            let ran = await started.waitFor { !$0.isEmpty }
            try #require(ran, "the loop's handler never ran")
        }
        return (keeper, await keeper.getReevaluationRecorder())
    }

    @Test("No loop and no adapter: the recorder goes and deletes its spool")
    func plainKeeper() async throws {
        let outcome = try await dropping { try await keeper(makeVerifierLand()) }
        #expect(outcome.recorderReleased)
        #expect(!outcome.spoolExists)
    }

    @Test("A started tick loop doesn't keep a dropped keeper")
    func tickLoop() async throws {
        let log = EventLog()
        // An hour's sync interval keeps the sync loop, which a tick land always starts, from
        // running `runSync` during the test. It doesn't isolate the sync loop: a strong binding
        // before that loop's `while` would hold the keeper here too. The sync row pins the sync loop.
        let land = Land("recorder-release-tick", using: VerifierState.self) {
            Lifetime {
                Tick(every: .milliseconds(10)) { state, _ in state.ticks += 1; log.append("tick") }
                StateSync(every: .seconds(3600)) { _, _ in }
            }
        }
        let outcome = try await dropping { try await keeper(land, started: log) }
        #expect(outcome.recorderReleased)
        #expect(!outcome.spoolExists)
    }

    @Test("A started sync loop doesn't keep a dropped keeper")
    func syncLoop() async throws {
        let log = EventLog()
        let land = Land("recorder-release-sync", using: VerifierState.self) {
            Lifetime { StateSync(every: .milliseconds(10)) { _, _ in log.append("sync") } }
        }
        let outcome = try await dropping { try await keeper(land, started: log) }
        #expect(outcome.recorderReleased)
        #expect(!outcome.spoolExists)
    }

    @Test("An attached adapter keeps its keeper until the drain; after forceShutdown both go")
    func adapterUntilTheDrain() async throws {
        weak var keeper: LandKeeper<VerifierState>?
        weak var recorder: ReevaluationRecorder?
        var path: String?
        do {
            let fixture = await VerifierFixture.make(encoding: .json)
            let r = try #require(await fixture.keeper.getReevaluationRecorder())
            path = try await openSpool(r)
            keeper = fixture.keeper
            recorder = r
        }
        // The adapter's link is a cycle by design (#346): with the fixture dropped, nothing in the
        // process can release the keeper until the drain's last call breaks it.
        #expect(keeper != nil)
        #expect(recorder != nil)
        let spool = try #require(path)
        #expect(FileManager.default.fileExists(atPath: spool))

        // The same keeper, drained.
        await keeper?.forceShutdown()
        #expect(try await poll { recorder == nil })
        #expect(try await poll { !FileManager.default.fileExists(atPath: spool) })
    }
}
