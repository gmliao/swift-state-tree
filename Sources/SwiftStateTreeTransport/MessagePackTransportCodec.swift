import Foundation
import SwiftStateTreeMessagePack

/// MessagePack-based transport codec.
///
/// Uses MessagePack binary serialization for encoding/decoding transport messages.
/// For incoming messages from clients, this codec decodes MessagePack binary data.
/// For outgoing messages, the MessagePackTransportMessageEncoder handles encoding
/// using opcode array format with MessagePack serialization.
public struct MessagePackTransportCodec: TransportCodec {
    public let encoding: TransportEncoding = .messagepack
    private let serializer = MessagePackSerializer()

    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> Data {
        return try serializer.encode(value)
    }

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        return try serializer.decode(type, from: data)
    }
}
