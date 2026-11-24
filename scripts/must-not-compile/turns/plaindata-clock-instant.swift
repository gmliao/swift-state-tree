// expect-error: this field's type isn't PlainData: add @PlainData to your struct or enum
import SwiftStateTurns

// A clock instant in the state: it isn't plain data (TurnInstant is). docs/turns/README.md,
// § Plain data and tools, shows this as the form to change.
@PlainData
struct Room {
    var lastChat: ContinuousClock.Instant
}
