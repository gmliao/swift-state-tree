// expect-error: inside #if isn't converted
import SwiftStateTree

// The conversion reads only top-level members, so a stored property inside #if would be checked
// but never converted.
@SnapshotConvertible
struct IfStoredValue: Codable, Sendable {
    var hp: Int = 0
    #if DEBUG
    var trace: Int = 0
    #endif
}
