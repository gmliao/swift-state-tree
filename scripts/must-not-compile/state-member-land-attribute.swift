// expect-error: @Land on 'Nested' can't be in a state type
import SwiftStateTree

// A macro attached to a member can add declarations to the state type that nothing checks (#837).
// @Land, a member and memberAttribute macro, is the one real macro that stands in for such a peer
// here, on a nested type.
@StateNodeBuilder
struct MemberLandTarget: StateNodeProtocol {
    @Sync(.broadcast)
    var hp: Int = 0

    init() {}
}

@StateNodeBuilder
struct MemberLandState: StateNodeProtocol {
    @Sync(.broadcast)
    var hp: Int = 0

    init() {}

    @Land(MemberLandTarget.self)
    struct Nested {}
}
