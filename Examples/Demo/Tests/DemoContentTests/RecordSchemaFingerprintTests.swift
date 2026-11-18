// Every Demo land has a record schema fingerprint (#521 D15), so each can record and replay
// (DemoServer runs the E2E with recording on); the field-less IncrementAction is hashed as it is,
// not refused. Each value is pinned: a change to one means a land's types changed, and its
// records stop replaying.

import DemoContent
import SwiftStateTree
import Testing

@Suite("Record schema fingerprint: Demo lands")
struct RecordSchemaFingerprintTests {
    @Test("every Demo land fingerprints, to its pinned value")
    func everyLandFingerprints() throws {
        let fingerprints: [(land: String, value: String, pinned: String)] = [
            ("counter", try ReevaluationSchemaFingerprint.compute(for: CounterDemo.makeLand()), "510edc8eabab6901"),
            ("cookie", try ReevaluationSchemaFingerprint.compute(for: CookieGame.makeLand()), "4923ccae0a167fec"),
            ("deterministic-math", try ReevaluationSchemaFingerprint.compute(for: DeterministicMathDemo.makeLand()), "8cb5e6b3ad567c97"),
        ]
        for entry in fingerprints {
            #expect(entry.value == entry.pinned, "\(entry.land): \(entry.value)")
        }
    }
}
