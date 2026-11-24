// expect-error: Date isn't plain data; store an Int64 of milliseconds
import SwiftStateTree
import Foundation

// A Date field: @Payload refuses it with the replacement named.
@Payload
struct StampEvent: ServerEventPayload {
    let at: Date
}
