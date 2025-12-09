import Foundation

/// Unique identifier for a Land instance.
///
/// This type provides a structured way to identify lands, with support for
/// conversion to/from String for backward compatibility and distributed actor systems.
public struct LandID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let rawValue: String
    
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        rawValue = try container.decode(String.self)
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    
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

