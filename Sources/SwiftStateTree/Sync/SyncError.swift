// Sources/SwiftStateTree/Sync/SyncError.swift

import Foundation

public enum SyncError: Error, Equatable {
    case unsupportedValue(String)
    case unsupportedKey(String)
}

