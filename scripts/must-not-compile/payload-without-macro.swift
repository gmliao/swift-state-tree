// expect-error: does not conform to protocol 'PlainData'
import SwiftStateTree

// A payload conformed without @Payload or @PlainData: the payload protocols refine PlainData.
struct BareEvent: ServerEventPayload {
    let n: Int
}
