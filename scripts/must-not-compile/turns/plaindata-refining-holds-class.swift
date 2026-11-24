// expect-error: does not conform to protocol 'PlainData'
import SwiftStateTurns

// Nor can a struct that holds a class, conforming through a refining protocol without the macro.
final class Box { var n = 0 }
protocol Payload: PlainData {}
struct HoldsRef: Payload { var box: Box }
