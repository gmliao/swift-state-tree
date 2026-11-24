// expect-error: does not conform to protocol 'PlainData'
import SwiftStateTurns

// A class can't become PlainData through a protocol that refines it: it lacks the checks that
// only @PlainData writes, and @PlainData refuses a class.
protocol Payload: PlainData {}
final class Sneaky: Payload { var count = 0 }
