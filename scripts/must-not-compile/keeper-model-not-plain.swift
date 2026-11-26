// expect-error: this field's type isn't PlainData
import SwiftStateTree

// The keeper's model is @PlainData (#700 K1b-4): a field holding an erased value, a reference or
// a closure doesn't compile. `KeeperModel` itself is internal, so this package can't name it: the
// snippet pins the macro on a stand-in shaped like it (generic over the land's state, with an
// AnyCodable beside the plain fields). The test target pins `KeeperModel` itself
// (KeeperCensusTests, `requirePlain`).
@PlainData
struct SnippetKeeperModel<State: StateNodeProtocol> {
    var state: State
    var players: [PlayerID: Int] = [:]
    var lastCommittedTickId: Int64 = -1
    var cached: AnyCodable
}
