// expect-error: @Payload already makes this type PlainData; remove @PlainData
import SwiftStateTree

@Payload
@PlainData
struct TwiceEvent: ServerEventPayload {
    let n: Int
}
