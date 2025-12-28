import Foundation
import SwiftStateTreeMessagePack

public struct MessagePackTransportCodec: TransportCodec {
    public let encoding: TransportEncoding = .messagePack
    private let serializer = MessagePackSerializer()

    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try serializer.encode(value)
        if TransportCodecSizeProfiler.isEnabled {
            let profiler = TransportCodecSizeProfiler.shared
            profiler.enableIfNeeded()
            profiler.recordEncode(encoding: .messagePack, bytes: data.count)
        }
        return data
    }

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        if TransportCodecSizeProfiler.isEnabled {
            let profiler = TransportCodecSizeProfiler.shared
            profiler.enableIfNeeded()
            profiler.recordDecode(encoding: .messagePack, bytes: data.count)
        }
        return try serializer.decode(type, from: data)
    }
}
