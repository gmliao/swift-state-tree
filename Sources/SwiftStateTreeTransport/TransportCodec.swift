import Foundation
import SwiftStateTree

/// Supported transport encodings for WebSocket payloads.
public enum TransportEncoding: String, Sendable {
    case json
    case messagePack
}

/// Encodes and decodes transport payloads.
public protocol TransportCodec: Sendable {
    var encoding: TransportEncoding { get }
    func encode<T: Encodable>(_ value: T) throws -> Data
    func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T
}

/// JSON-based transport codec.
public struct JSONTransportCodec: TransportCodec {
    public let encoding: TransportEncoding = .json

    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        if TransportCodecSizeProfiler.isEnabled {
            let profiler = TransportCodecSizeProfiler.shared
            profiler.enableIfNeeded()
            profiler.recordEncode(encoding: .json, bytes: data.count)
        }
        return data
    }

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if TransportCodecSizeProfiler.isEnabled {
            let profiler = TransportCodecSizeProfiler.shared
            profiler.enableIfNeeded()
            profiler.recordDecode(encoding: .json, bytes: data.count)
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

public extension TransportEncoding {
    /// Create a codec for the selected encoding.
    func makeCodec() -> any TransportCodec {
        switch self {
        case .json:
            return JSONTransportCodec()
        case .messagePack:
            return MessagePackTransportCodec()
        }
    }
}
