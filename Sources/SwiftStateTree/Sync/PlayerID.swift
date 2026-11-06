// Sources/SwiftStateTree/Sync/PlayerID.swift

import Foundation

/// Player identifier (account level)
public struct PlayerID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public var description: String { rawValue }
    
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    /// Encoded as its string (#154), the shape `SnapshotValue` gives state.
    public init(from decoder: Decoder) throws {
        self.rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

extension PlayerID: CodingKeyRepresentable {
    /// A `[PlayerID: X]` encodes as an object keyed by the string, not as a key/value array (#154).
    public var codingKey: any CodingKey { IdentifierCodingKey(rawValue) }

    public init?<Key: CodingKey>(codingKey: Key) {
        self.init(codingKey.stringValue)
    }
}

/// The coding key of an identifier used as a dictionary key: its string.
struct IdentifierCodingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ stringValue: String) {
        self.stringValue = stringValue
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        return nil
    }
}

