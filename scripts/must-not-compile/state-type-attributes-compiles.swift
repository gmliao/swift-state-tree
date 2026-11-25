// expect: compiles
import SwiftStateTree
import SwiftStateTurns

// The attributes a state type may carry (#100): this project's macros, qualified or not, and
// built-in attributes that add no members.
@available(macOS 10.15, *)
@StateNodeBuilder
@SnapshotConvertible
struct AllowedAttributesState: StateNodeProtocol {
    @Sync(.broadcast)
    var hp: Int = 0

    init() {}
}

@SwiftStateTurns.PlainData
@SwiftStateTree.SnapshotConvertible
struct AllowedAttributesValue: Codable, Sendable {
    var hp: Int = 0
}

@SnapshotConvertible
@PlainData
struct AllowedAttributesPair: Codable, Sendable {
    var hp: Int = 0
}
