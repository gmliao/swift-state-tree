// Sources/SwiftStateTree/Sync/SyncError.swift

import Foundation

public enum SyncError: Error, Equatable {
    case unsupportedValue(String)
    case unsupportedKey(String)
    /// Two keys of a map convert to the same string (#535 D8): one would silently overwrite the
    /// other on every client. A synced field that throws it ends the land. Only the library's
    /// conversion checks it: a custom `toSnapshotValue()` that builds its own `.object` has
    /// merged its keys before the library sees them.
    case collidingKeys(String)
    /// A value nests deeper than a state conversion may descend (#716): `counter` ran out at
    /// `limit`. `field` names the root field, filled in where a conversion knows it; nil below.
    /// A synced field that throws it ends the land.
    case nestingTooDeep(counter: NestingBudget.Counter, limit: Int, field: String?)
}

