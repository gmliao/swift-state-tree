// expect-error: local type cannot have attached extension macro
import SwiftStateTree

// A payload can't be declared inside a function: Swift doesn't attach an extension macro to a
// local type, and @Payload's extension role makes the type PlainData. Declare it at file scope
// or inside another type. (If a later Swift lifts this, the snippet fails and the limit goes.)
func handler() {
    @Payload
    struct LocalEvent: ServerEventPayload {
        let n: Int
    }
}
