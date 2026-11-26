// expect-error: this field's type isn't PlainData
import SwiftStateTree

// The keeper's model is @PlainData (#700 K1b-4): a field holding an erased value, a reference or
// a closure doesn't compile. Shaped like KeeperModel: generic over the land's state, with an
// AnyCodable beside the plain fields.
@PlainData
struct SnippetKeeperModel<State: StateNodeProtocol> {
    var state: State
    var players: [PlayerID: Int] = [:]
    var lastCommittedTickId: Int64 = -1
    var cached: AnyCodable
}
