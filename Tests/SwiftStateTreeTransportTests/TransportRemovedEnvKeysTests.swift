import Foundation
import Testing
@testable import SwiftStateTreeTransport

/// The auto dirty switch and its change-object metric are removed: their keys are ignored, and
/// a set one is reported once per process.
@Suite("Removed environment keys")
struct TransportRemovedEnvKeysTests {
    @Test("The set removed keys are reported once, in order, and other keys are ignored")
    func reportedOnce() {
        let check = TransportRemovedEnvKeys(environment: [
            "AUTO_DIRTY_SAMPLE_EVERY": "4",
            "AUTO_DIRTY_TRACKING": "false",
            "ENABLE_DIRTY_TRACKING": "true",
            "USE_SYNC_TABLES": "false",
        ])
        #expect(check.takeFirst() == ["AUTO_DIRTY_TRACKING", "AUTO_DIRTY_SAMPLE_EVERY"])
        #expect(check.takeFirst().isEmpty)
    }

    @Test("Nothing is reported when no removed key is set")
    func nothingSet() {
        let check = TransportRemovedEnvKeys(environment: ["ENABLE_DIRTY_TRACKING": "false"])
        #expect(check.takeFirst().isEmpty)
    }

    @Test("Every removed key is reported, an empty value included")
    func everyKey() {
        let environment = Dictionary(uniqueKeysWithValues: TransportRemovedEnvKeys.all.map { ($0, "") })
        #expect(TransportRemovedEnvKeys(environment: environment).takeFirst() == TransportRemovedEnvKeys.all)
    }

    /// The removed switch turned dirty tracking off after 30 syncs that changed most objects.
    @Test("Dirty tracking stays as configured through many syncs that change every field")
    func dirtyTrackingStays() async throws {
        for dirtyTracking in [true, false] {
            let run = await DirtyIdentityRun(envConfig: dirtyIdentityConfig(dirtyTracking: dirtyTracking), encoding: .messagepack)
            try await run.runScript()
            for round in 0..<40 {
                try await run.step(1, move: 1, title: "r\(round)")
                await run.sync()
            }
            #expect(await run.adapter.dirtyTrackingEnabledForTesting() == dirtyTracking)
        }
    }
}
