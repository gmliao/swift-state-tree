// expect: compiles
import SwiftStateTree

// @StateNodeBuilder and @SnapshotConvertible on one type: @SnapshotConvertible writes no PlainData
// witness, so the two don't both declare `_plainDataCheck`.
@StateNodeBuilder
@SnapshotConvertible
struct UnitState: StateNodeProtocol {
    @Sync(.broadcast)
    var hp: Int = 0

    init() {}
}

@SwiftStateTree.StateNodeBuilder
@SwiftStateTree.SnapshotConvertible
struct QualifiedUnitState: StateNodeProtocol {
    @Sync(.broadcast)
    var hp: Int = 0

    init() {}
}
