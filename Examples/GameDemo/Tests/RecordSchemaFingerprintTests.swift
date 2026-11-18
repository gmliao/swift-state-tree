// Every GameDemo land has a record schema fingerprint (#521 D15), so each can record and replay
// (GameServer runs the E2E with recording on); the field-less PlayAction, ShootEvent,
// UpgradeWeaponEvent and ParkEntitiesAction are hashed as they are, not refused. Each value is
// pinned: a change to one means a land's types changed, and its records stop replaying.

import Foundation
import GameContent
import SwiftStateTree
import Testing

@Suite("Record schema fingerprint: GameDemo lands")
struct RecordSchemaFingerprintTests {
    @Test("every GameDemo land fingerprints, to its pinned value")
    func everyLandFingerprints() throws {
        let fingerprints: [(land: String, value: String, pinned: String)] = [
            ("hero-defense", try ReevaluationSchemaFingerprint.compute(for: HeroDefense.makeLand()), "cfcbd0f770e31422"),
            ("visibility-test", try ReevaluationSchemaFingerprint.compute(for: VisibilityTest.makeLand()), "f7d54852220db45b"),
            (
                "visibility-test broadcast",
                try ReevaluationSchemaFingerprint.compute(for: VisibilityTest.makeLand(VisibilityTestBroadcastState.self)),
                "13aa677613d3fe7d"
            ),
            ("resolver-test", try ReevaluationSchemaFingerprint.compute(for: ResolverTest.makeLand()), "05b9d95456055dff"),
            ("card-game", try ReevaluationSchemaFingerprint.compute(for: CardGame.makeLand()), "98bd582740eb0dd8"),
        ]
        for entry in fingerprints {
            #expect(entry.value == entry.pinned, "\(entry.land): \(entry.value)")
        }
    }
}
