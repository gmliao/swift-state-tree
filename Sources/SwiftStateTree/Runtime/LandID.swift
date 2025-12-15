import Foundation

/// Unique identifier for a Land instance.
///
/// LandID uses a structured format: `landType:instanceId`
/// - `landType`: The type of Land (e.g., "lobby", "game1", "battle")
/// - `instanceId`: The unique instance identifier (UUID v4)
///
/// Example: `game1:550e8400-e29b-41d4-a716-446655440000`
///
/// This type provides a structured way to identify lands, with support for
/// conversion to/from String for backward compatibility and distributed actor systems.
public struct LandID: Hashable, Codable, Sendable, CustomStringConvertible {
    /// The type of Land (e.g., "lobby", "game1", "battle")
    public let landType: String
    
    /// The unique instance identifier
    public let instanceId: String
    
    /// The complete landID string (landType:instanceId)
    public var rawValue: String {
        if landType.isEmpty {
            return instanceId
        }
        return "\(landType):\(instanceId)"
    }
    
    /// Initialize with landType and instanceId
    /// - Parameters:
    ///   - landType: The type of Land
    ///   - instanceId: The unique instance identifier
    public init(landType: String, instanceId: String) {
        self.landType = landType
        self.instanceId = instanceId
    }
    
    /// Initialize from a raw string value.
    ///
    /// Parses the string as `landType:instanceId`. If no colon is found,
    /// the entire string is treated as instanceId with an empty landType.
    /// - Parameter rawValue: The raw string value to parse
    public init(_ rawValue: String) {
        if let colonIndex = rawValue.firstIndex(of: ":") {
            self.landType = String(rawValue[..<colonIndex])
            self.instanceId = String(rawValue[rawValue.index(after: colonIndex)...])
        } else {
            // Backward compatibility: no colon means entire string is instanceId
            self.landType = ""
            self.instanceId = rawValue
        }
    }
    
    /// Generate a new LandID with the specified landType and a random UUID v4 instanceId.
    /// - Parameter landType: The type of Land
    /// - Returns: A new LandID with a unique instanceId
    public static func generate(landType: String) -> LandID {
        return LandID(landType: landType, instanceId: UUID().uuidString.lowercased())
    }
    
    // MARK: - Codable
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        self.init(rawValue)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    
    // MARK: - CustomStringConvertible
    
    public var description: String {
        rawValue
    }
}

// MARK: - String Interoperability

extension LandID {
    /// Create a LandID from a String.
    public init(string: String) {
        self.init(string)
    }
    
    /// Convert LandID to String.
    public var stringValue: String {
        rawValue
    }
}

extension String {
    /// Convert String to LandID.
    public var asLandID: LandID {
        LandID(self)
    }
}
