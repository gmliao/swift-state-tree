import Foundation
import SwiftStateTreeTransport

let transportTestCodec: any TransportCodec = MessagePackTransportCodec()

func encodeTransportMessage<T: Encodable>(_ value: T) throws -> Data {
    try transportTestCodec.encode(value)
}

func decodeTransportMessage<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    try transportTestCodec.decode(type, from: data)
}
