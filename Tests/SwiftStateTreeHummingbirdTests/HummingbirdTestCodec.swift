import Foundation
import SwiftStateTreeTransport

let hummingbirdTestCodec: any TransportCodec = MessagePackTransportCodec()

func encodeHummingbirdTransportMessage<T: Encodable>(_ value: T) throws -> Data {
    try hummingbirdTestCodec.encode(value)
}

func decodeHummingbirdTransportMessage<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    try hummingbirdTestCodec.decode(type, from: data)
}
