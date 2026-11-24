// expect: compiles
import SwiftStateTurns

// Existentials of a protocol that refines PlainData, on their own and inside the wrappers the
// macro unwraps; a conformer through the protocol uses @PlainData.
protocol Payload: PlainData, Sendable {}
@PlainData
struct Move: Payload { var dx: Int }
@PlainData
struct Queue {
    var head: any Payload
    var next: (any Payload)?
    var all: [any Payload]
    var byName: [String: any Payload]
    var nested: [[any Payload]?]
    var sendable: any Payload & Sendable
    var grouped: any (Payload & Sendable)
    var later: ContiguousArray<any Payload>
    var spelledOptional: Optional<any Payload>
    var spelledArray: Array<any Payload>
    var spelledDictionary: Dictionary<String, any Payload>
    var qualified: Swift.Array<any Payload>
}
@PlainData
indirect enum Tree {
    case leaf(Int)
    case node(Tree, Tree)
}
