// expect-error: @Land can't be on a PlainData type
import SwiftStateTree

// @Land is a member and memberAttribute macro: on a @PlainData type it would add members the
// witness doesn't see. Any attached macro this project doesn't list is refused (#837).
@StateNodeBuilder
struct PlainDataLandTarget: StateNodeProtocol {
    @Sync(.broadcast)
    var hp: Int = 0

    init() {}
}

@PlainData
@Land(PlainDataLandTarget.self)
struct PlainDataLandValue {
    var hp: Int = 0
}
