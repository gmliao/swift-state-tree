// expect-error: @Land can't be on a state type
import SwiftStateTree

// @Land is a member and memberAttribute macro: on a state type it would add members
// @StateNodeBuilder doesn't see. Any attached macro this project doesn't list is refused (#100).
@StateNodeBuilder
struct LandAttributeTarget: StateNodeProtocol {
    @Sync(.broadcast)
    var hp: Int = 0

    init() {}
}

@StateNodeBuilder
@Land(LandAttributeTarget.self)
struct LandAttributeState: StateNodeProtocol {
    @Sync(.broadcast)
    var hp: Int = 0

    init() {}
}
