// Sources/SwiftStateTree/Sync/PlayerID.swift

import Foundation

/// Player identifier (account level)
public struct PlayerID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }
    
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

