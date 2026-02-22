import Testing
@testable import SwiftStateTree

@Test("StateSnapshotDiff returns empty when both are identical")
func testDiffIdentical() {
    let a: [String: Any] = ["players": ["p1": ["position": ["v": ["x": 64000, "y": 36000]]]]]
    let b: [String: Any] = ["players": ["p1": ["position": ["v": ["x": 64000, "y": 36000]]]]]
    let diffs = StateSnapshotDiff.compare(recorded: a, computed: b, pathPrefix: "")
    #expect(diffs.isEmpty)
}

@Test("StateSnapshotDiff returns path and values when different")
func testDiffSingleField() {
    let a: [String: Any] = ["players": ["p1": ["position": ["v": ["x": 98100, "y": 35689]]]]]
    let b: [String: Any] = ["players": ["p1": ["position": ["v": ["x": 0, "y": 0]]]]]
    let diffs = StateSnapshotDiff.compare(recorded: a, computed: b, pathPrefix: "")
    #expect(diffs.count == 2)
    let paths = Set(diffs.map { $0.path })
    #expect(paths.contains("players.p1.position.v.x"))
    #expect(paths.contains("players.p1.position.v.y"))
}
