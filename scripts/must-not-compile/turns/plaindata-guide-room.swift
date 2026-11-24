// expect-error: this field's type isn't PlainData: add @PlainData to your struct or enum
import SwiftStateTurns

// The turn guide's refused `Room` ("Your own types"): a class and a clock instant in the state.
// `PlayerID` stands in for the repository's ID, which this set doesn't import.
@PlainData
struct PlayerID: Hashable, Sendable {
    var rawValue: String
}

final class Connection {}

@PlainData
struct Room {
    var players: [PlayerID: Connection]       // Connection is a class
    var lastChat: ContinuousClock.Instant
}
