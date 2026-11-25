// expect-error: @Land can't be on a state type
import SwiftStateTree

// The same refusal on a @SnapshotConvertible value stored in state (#100).
@StateNodeBuilder
struct LandAttributeTarget: StateNodeProtocol {
    @Sync(.broadcast)
    var hp: Int = 0

    init() {}
}

@SnapshotConvertible
@Land(LandAttributeTarget.self)
struct LandAttributeValue: Codable, Sendable {
    var hp: Int = 0
}
