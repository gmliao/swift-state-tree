import Foundation
import SwiftStateTree

/// Supported transport encodings for WebSocket payloads.
public enum TransportEncoding: String, Sendable {
    case json
}

/// Encodes and decodes transport payloads.
public protocol TransportCodec: Sendable {
    var encoding: TransportEncoding { get }
    func encode<T: Encodable>(_ value: T) throws -> Data
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T
}

/// JSON-based transport codec.
///
/// Uses per-encoding encoder instances to ensure consistent JSON output ordering
/// in parallel encoding scenarios. While JSONEncoder is thread-safe, using separate
/// instances per encoding operation ensures deterministic output regardless of
/// concurrent access patterns.
public struct JSONTransportCodec: TransportCodec {
    public let encoding: TransportEncoding = .json
    
    /// Shared JSONDecoder instance for decoding operations.
    /// JSONDecoder is thread-safe and can be safely used concurrently.
    private static let sharedDecoder = JSONDecoder()

    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> Data {
        // Create a new encoder for each encoding operation to ensure
        // consistent JSON key ordering in parallel encoding scenarios.
        // While this has a small performance cost, it ensures deterministic
        // output which is critical for testing and correctness.
        let encoder = JSONEncoder()
        encoder.outputFormatting = []  // No pretty printing for performance
        return try encoder.encode(value)
    }

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        // Reuse shared decoder instance for better performance
        // JSONDecoder is thread-safe and can be used concurrently
        return try Self.sharedDecoder.decode(type, from: data)
    }
}

public extension TransportEncoding {
    /// Create a codec for the selected encoding.
    func makeCodec() -> any TransportCodec {
        switch self {
        case .json:
            return JSONTransportCodec()
        }
    }
}
