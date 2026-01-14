import Foundation
import SwiftStateTree

public struct MessagePackSerializer: Sendable {
    public init() {}

    public func encode<T: Encodable>(_ value: T) throws -> Data {
        let data: Data
        let directEncoder = MessagePackDirectEncoder()
        if let message = value as? TransportMessage {
            data = try directEncoder.encode(message)
        } else if let update = value as? StateUpdate {
            data = try directEncoder.encode(update)
        } else if let snapshot = value as? StateSnapshot {
            data = try directEncoder.encode(snapshot)
        } else if let envelope = value as? ActionEnvelope {
            data = try directEncoder.encode(envelope)
        } else {
            let packed = try MessagePackValueEncoder().encode(value)
            data = try pack(packed)
        }
        return data
    }

    public func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let unpacked = try unpack(data)
        let directDecoder = MessagePackDirectDecoder()
        if type == TransportMessage.self {
            return try directDecoder.decodeTransportMessage(from: unpacked) as! T
        }
        if type == StateUpdate.self {
            return try directDecoder.decodeStateUpdate(from: unpacked) as! T
        }
        if type == StateSnapshot.self {
            return try directDecoder.decodeStateSnapshot(from: unpacked) as! T
        }
        if type == ActionEnvelope.self {
            return try directDecoder.decodeActionEnvelope(from: unpacked) as! T
        }
        return try MessagePackValueDecoder().decode(type, from: unpacked)
    }
}
