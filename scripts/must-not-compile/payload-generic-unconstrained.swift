// expect-error: generic parameter 'T' is stored in 'value'; a payload must declare 'T: PlainData'
import SwiftStateTree

// A payload conforms unconditionally, so a stored parameter must be PlainData itself.
@Payload
struct BoxEvent<T: Codable & Sendable>: ServerEventPayload {
    let value: T
}
