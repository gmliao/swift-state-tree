import Foundation
import SwiftStateTree

/// Supported transport encodings for WebSocket payloads.
public enum TransportEncoding: String, Sendable {
    case json
    case opcodeJsonArray
}

/// Encodes and decodes transport payloads.
public protocol TransportCodec: Sendable {
    var encoding: TransportEncoding { get }
    func encode<T: Encodable>(_ value: T) throws -> Data
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T
}

/// JSON-based transport codec.
///
/// Each codec instance maintains its own encoder and decoder for reuse.
/// This provides better performance than creating new instances for each operation,
/// while ensuring thread safety since each codec instance is typically used by
/// a single actor (e.g., TransportAdapter).
public struct JSONTransportCodec: TransportCodec {
    public let encoding: TransportEncoding = .json
    
    /// Per-instance JSONEncoder for encoding operations.
    /// 
    /// Safe for reuse because:
    /// - JSONEncoder is thread-safe in practice (no mutable state shared between encode calls)
    /// - Each codec instance is typically used by a single actor (TransportAdapter)
    /// - Reusing the encoder instance provides better performance than creating new ones
    private let encoder: JSONEncoder
    
    /// Per-instance JSONDecoder for decoding operations.
    /// 
    /// Safe for reuse because:
    /// - JSONDecoder is thread-safe in practice (no mutable state shared between decode calls)
    /// - Each codec instance is typically used by a single actor (TransportAdapter)
    /// - Reusing the decoder instance provides better performance than creating new ones
    private let decoder: JSONDecoder

    public init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []  // No pretty printing for performance
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func encode<T: Encodable>(_ value: T) throws -> Data {
        // Reuse per-instance encoder for better performance.
        // The encoder is safe to reuse because JSONEncoder is thread-safe in practice,
        // and each codec instance is typically used by a single actor.
        return try encoder.encode(value)
    }

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        // Reuse per-instance decoder for better performance.
        // The decoder is safe to reuse because JSONDecoder is thread-safe in practice,
        // and each codec instance is typically used by a single actor.
        return try decoder.decode(type, from: data)
    }
}

public extension TransportEncoding {
    /// Create a codec for the selected encoding.
    /// Note: opcodeJsonArray uses JSON codec for decoding (incoming messages are still JSON)
    /// but a specialized encoder for outgoing messages.
    func makeCodec() -> any TransportCodec {
        switch self {
        case .json, .opcodeJsonArray:
            return JSONTransportCodec()
        }
    }
}
