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
}
@PlainData
indirect enum Tree {
    case leaf(Int)
    case node(Tree, Tree)
}
