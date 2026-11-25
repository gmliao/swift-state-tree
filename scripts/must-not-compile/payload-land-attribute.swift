// expect-error: @Land can't be on a payload type
import SwiftStateTree

// @Land is a member and memberAttribute macro: on a @Payload type it would add members the
// witness and the field metadata don't see. Any attached macro this project doesn't list is
// refused (#837).
@StateNodeBuilder
struct PayloadLandTarget: StateNodeProtocol {
    @Sync(.broadcast)
    var hp: Int = 0

    init() {}
}

@Payload
@Land(PayloadLandTarget.self)
struct PayloadLandEvent: ServerEventPayload {
    let hp: Int
}
