// Every GameDemo land has a record schema fingerprint (#521 D15), so each can record and replay
// (GameServer runs the E2E with recording on); the field-less PlayAction, ShootEvent,
// UpgradeWeaponEvent and ParkEntitiesAction are hashed as they are, not refused. Each value is
// pinned: a change to one means a land's types changed, and its records stop replaying. The
// tracked records hold Hero Defense's current fingerprint, so a type change that moves the pin
// fails here until they are re-recorded.

import Foundation
import GameContent
import SwiftStateTree
import Testing

@Suite("Record schema fingerprint: GameDemo lands")
struct RecordSchemaFingerprintTests {
    @Test("every GameDemo land fingerprints, to its pinned value")
    func everyLandFingerprints() throws {
        let fingerprints: [(land: String, value: String, pinned: String)] = [
            ("hero-defense", try ReevaluationSchemaFingerprint.compute(for: HeroDefense.makeLand()), "0df25863c8632fb6"),
            ("visibility-test", try ReevaluationSchemaFingerprint.compute(for: VisibilityTest.makeLand()), "c041d8caea2aee46"),
            (
                "visibility-test broadcast",
                try ReevaluationSchemaFingerprint.compute(for: VisibilityTest.makeLand(VisibilityTestBroadcastState.self)),
                "3b3fe021ae9fb5da"
            ),
            ("resolver-test", try ReevaluationSchemaFingerprint.compute(for: ResolverTest.makeLand()), "b3f9fe2ca2424670"),
            ("card-game", try ReevaluationSchemaFingerprint.compute(for: CardGame.makeLand()), "1e311682d1720885"),
        ]
        for entry in fingerprints {
            #expect(entry.value == entry.pinned, "\(entry.land): \(entry.value)")
        }
    }

    @Test("each tracked Hero Defense record holds the land's current fingerprint", arguments: [
        "1-hero-defense.sstr", "2-hero-defense.sstr", "3-hero-defense.sstr",
    ])
    func trackedRecordsMatch(fileName: String) async throws {
        let path = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // GameDemo
            .appendingPathComponent("reevaluation-records")
            .appendingPathComponent(fileName)
            .path
        let metadata = try await ReevaluationRecordFile.openSource(filePath: path).getMetadata()
        #expect(metadata.version == ReevaluationRecordVersion.current)
        #expect(metadata.schemaFingerprint == (try ReevaluationSchemaFingerprint.compute(for: HeroDefense.makeLand())))
    }
}
