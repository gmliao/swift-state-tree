// expect-error: does not conform to protocol 'PlainData'
import SwiftStateTree

// A constraint the macro can't read (an alias) passes the macro; the compiler refuses it.
typealias Wire = Codable & Sendable

@Payload
struct WireEvent<T: Wire>: ServerEventPayload {
    let value: T
}
