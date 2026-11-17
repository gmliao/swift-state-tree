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
}

