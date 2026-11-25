// expect: compiles
import SwiftStateTree
import SwiftStateTurns

// The attributes a @PlainData or @Payload type takes (#837): this project's macros where they
// belong, each bare or qualified by a module that exports it, and built-in attributes that add
// no members.
@available(macOS 14, *)
@PlainData
struct PlainDataAvailable {
    var hp: Int = 0
}

@SwiftStateTurns.PlainData
struct PlainDataQualified {
    var hp: Int = 0
}

@available(macOS 14, *)
@PlainData
enum PlainDataPhase {
    case lobby
}

@available(macOS 14, *)
@Payload
struct PayloadAvailable: ServerEventPayload {
    let hp: Int
}

@SwiftStateTree.Payload
struct PayloadQualified: ServerEventPayload {
    let hp: Int
}

@SnapshotConvertible
@PlainData
struct SnapshotPlainData: Equatable {
    var hp: Int = 0
}
