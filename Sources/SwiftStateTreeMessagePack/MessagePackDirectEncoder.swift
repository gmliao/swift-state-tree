import Foundation
import SwiftStateTree

enum MessagePackDirectEncodingError: Error {
    case unsupportedAnyCodable(String)
}

private struct AnyEncodable: Encodable {
    let value: any Encodable

    init(_ value: any Encodable) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        try value.encode(to: encoder)
    }
}

struct MessagePackDirectEncoder {
    func encode(_ message: TransportMessage) throws -> Data {
        let value = try encodeTransportMessage(message)
        return try pack(value)
    }

    func encode(_ update: StateUpdate) throws -> Data {
        let value = try encodeStateUpdate(update)
        return try pack(value)
    }

    func encode(_ snapshot: StateSnapshot) throws -> Data {
        let value = encodeStateSnapshot(snapshot)
        return try pack(value)
    }

    func encode(_ envelope: ActionEnvelope) throws -> Data {
        let value = encodeActionEnvelope(envelope)
        return try pack(value)
    }

    fileprivate func encodeTransportMessage(_ message: TransportMessage) throws -> MessagePackValue {
        var map: [MessagePackValue: MessagePackValue] = [:]
        map[.string("kind")] = .string(message.kind.rawValue)
        map[.string("payload")] = try encodeMessagePayload(message.payload)
        return .map(map)
    }

    private func encodeMessagePayload(_ payload: MessagePayload) throws -> MessagePackValue {
        switch payload {
        case .action(let payload):
            return .map([.string("action"): encodeTransportActionPayload(payload)])
        case .actionResponse(let payload):
            return .map([.string("actionResponse"): try encodeTransportActionResponsePayload(payload)])
        case .event(let payload):
            return .map([.string("event"): try encodeTransportEventPayload(payload)])
        case .join(let payload):
            return .map([.string("join"): try encodeTransportJoinPayload(payload)])
        case .joinResponse(let payload):
            return .map([.string("joinResponse"): encodeTransportJoinResponsePayload(payload)])
        case .error(let payload):
            return .map([.string("error"): try encodeErrorPayload(payload)])
        }
    }

    private func encodeTransportActionPayload(_ payload: TransportActionPayload) -> MessagePackValue {
        var map: [MessagePackValue: MessagePackValue] = [:]
        map[.string("requestID")] = .string(payload.requestID)
        map[.string("landID")] = .string(payload.landID)
        map[.string("action")] = encodeActionEnvelope(payload.action)
        return .map(map)
    }

    private func encodeTransportActionResponsePayload(_ payload: TransportActionResponsePayload) throws -> MessagePackValue {
        var map: [MessagePackValue: MessagePackValue] = [:]
        map[.string("requestID")] = .string(payload.requestID)
        map[.string("response")] = try encodeAnyCodable(payload.response)
        return .map(map)
    }

    private func encodeTransportEventPayload(_ payload: TransportEventPayload) throws -> MessagePackValue {
        var map: [MessagePackValue: MessagePackValue] = [:]
        map[.string("landID")] = .string(payload.landID)
        map[.string("event")] = try encodeTransportEvent(payload.event)
        return .map(map)
    }

    private func encodeTransportEvent(_ event: TransportEvent) throws -> MessagePackValue {
        switch event {
        case .fromClient(let event):
            return .map([
                .string("fromClient"): .map([
                    .string("event"): try encodeAnyClientEvent(event)
                ])
            ])
        case .fromServer(let event):
            return .map([
                .string("fromServer"): .map([
                    .string("event"): try encodeAnyServerEvent(event)
                ])
            ])
        }
    }

    private func encodeAnyClientEvent(_ event: AnyClientEvent) throws -> MessagePackValue {
        var map: [MessagePackValue: MessagePackValue] = [:]
        map[.string("type")] = .string(event.type)
        map[.string("payload")] = try encodeAnyCodable(event.payload)
        if let rawBody = event.rawBody {
            map[.string("rawBody")] = .binary(rawBody)
        }
        return .map(map)
    }

    private func encodeAnyServerEvent(_ event: AnyServerEvent) throws -> MessagePackValue {
        var map: [MessagePackValue: MessagePackValue] = [:]
        map[.string("type")] = .string(event.type)
        map[.string("payload")] = try encodeAnyCodable(event.payload)
        if let rawBody = event.rawBody {
            map[.string("rawBody")] = .binary(rawBody)
        }
        return .map(map)
    }

    private func encodeTransportJoinPayload(_ payload: TransportJoinPayload) throws -> MessagePackValue {
        var map: [MessagePackValue: MessagePackValue] = [:]
        map[.string("requestID")] = .string(payload.requestID)
        map[.string("landType")] = .string(payload.landType)
        if let landInstanceId = payload.landInstanceId {
            map[.string("landInstanceId")] = .string(landInstanceId)
        }
        if let playerID = payload.playerID {
            map[.string("playerID")] = .string(playerID)
        }
        if let deviceID = payload.deviceID {
            map[.string("deviceID")] = .string(deviceID)
        }
        if let metadata = payload.metadata {
            map[.string("metadata")] = try encodeAnyCodableDictionary(metadata)
        }
        return .map(map)
    }

    private func encodeTransportJoinResponsePayload(_ payload: TransportJoinResponsePayload) -> MessagePackValue {
        var map: [MessagePackValue: MessagePackValue] = [:]
        map[.string("requestID")] = .string(payload.requestID)
        map[.string("success")] = .bool(payload.success)
        if let landType = payload.landType {
            map[.string("landType")] = .string(landType)
        }
        if let landInstanceId = payload.landInstanceId {
            map[.string("landInstanceId")] = .string(landInstanceId)
        }
        if let landID = payload.landID {
            map[.string("landID")] = .string(landID)
        }
        if let playerID = payload.playerID {
            map[.string("playerID")] = .string(playerID)
        }
        if let reason = payload.reason {
            map[.string("reason")] = .string(reason)
        }
        return .map(map)
    }

    private func encodeErrorPayload(_ payload: ErrorPayload) throws -> MessagePackValue {
        var map: [MessagePackValue: MessagePackValue] = [:]
        map[.string("code")] = .string(payload.code)
        map[.string("message")] = .string(payload.message)
        if let details = payload.details {
            map[.string("details")] = try encodeAnyCodableDictionary(details)
        }
        return .map(map)
    }

    fileprivate func encodeStateUpdate(_ update: StateUpdate) throws -> MessagePackValue {
        var map: [MessagePackValue: MessagePackValue] = [:]
        switch update {
        case .noChange:
            map[.string("type")] = .string("noChange")
        case .firstSync(let patches):
            map[.string("type")] = .string("firstSync")
            map[.string("patches")] = try encodeStatePatches(patches)
        case .diff(let patches):
            map[.string("type")] = .string("diff")
            map[.string("patches")] = try encodeStatePatches(patches)
        }
        return .map(map)
    }

    private func encodeStatePatches(_ patches: [StatePatch]) throws -> MessagePackValue {
        let values = try patches.map { try encodeStatePatch($0) }
        return .array(values)
    }

    private func encodeStatePatch(_ patch: StatePatch) throws -> MessagePackValue {
        var map: [MessagePackValue: MessagePackValue] = [:]
        map[.string("path")] = .string(patch.path)
        switch patch.operation {
        case .set(let value):
            map[.string("op")] = .string("replace")
            map[.string("value")] = encodeSnapshotValue(value)
        case .delete:
            map[.string("op")] = .string("remove")
        case .add(let value):
            map[.string("op")] = .string("add")
            map[.string("value")] = encodeSnapshotValue(value)
        }
        return .map(map)
    }

    fileprivate func encodeStateSnapshot(_ snapshot: StateSnapshot) -> MessagePackValue {
        var map: [MessagePackValue: MessagePackValue] = [:]
        map[.string("values")] = encodeSnapshotValues(snapshot.values)
        return .map(map)
    }

    private func encodeSnapshotValues(_ values: [String: SnapshotValue]) -> MessagePackValue {
        var map: [MessagePackValue: MessagePackValue] = [:]
        for (key, value) in values {
            map[.string(key)] = encodeSnapshotValue(value)
        }
        return .map(map)
    }

    func encodeSnapshotValue(_ value: SnapshotValue) -> MessagePackValue {
        switch value {
        case .null:
            return .nil
        case .bool(let value):
            return .bool(value)
        case .int(let value):
            return .int(Int64(value))
        case .double(let value):
            return .double(value)
        case .string(let value):
            return .string(value)
        case .array(let values):
            return .array(values.map { encodeSnapshotValue($0) })
        case .object(let values):
            return encodeSnapshotValues(values)
        }
    }

    fileprivate func encodeActionEnvelope(_ envelope: ActionEnvelope) -> MessagePackValue {
        var map: [MessagePackValue: MessagePackValue] = [:]
        map[.string("typeIdentifier")] = .string(envelope.typeIdentifier)
        map[.string("payload")] = .binary(envelope.payload)
        return .map(map)
    }

    fileprivate func encodeAnyCodableDictionary(_ value: [String: AnyCodable]) throws -> MessagePackValue {
        var map: [MessagePackValue: MessagePackValue] = [:]
        for (key, value) in value {
            map[.string(key)] = try encodeAnyCodable(value)
        }
        return .map(map)
    }

    func encodeAnyCodable(_ value: AnyCodable) throws -> MessagePackValue {
        switch value.base {
        case is Void:
            return .nil
        case let value as Bool:
            return .bool(value)
        case let value as Int:
            return .int(Int64(value))
        case let value as Int8:
            return .int(Int64(value))
        case let value as Int16:
            return .int(Int64(value))
        case let value as Int32:
            return .int(Int64(value))
        case let value as Int64:
            return .int(value)
        case let value as UInt:
            return .uint(UInt64(value))
        case let value as UInt8:
            return .uint(UInt64(value))
        case let value as UInt16:
            return .uint(UInt64(value))
        case let value as UInt32:
            return .uint(UInt64(value))
        case let value as UInt64:
            return .uint(value)
        case let value as Float:
            return .float(value)
        case let value as Double:
            return .double(value)
        case let value as String:
            return .string(value)
        case let value as Data:
            return .binary(value)
        case let value as Date:
            return .double(value.timeIntervalSinceReferenceDate)
        case let value as UUID:
            return .string(value.uuidString)
        case let value as URL:
            return .string(value.absoluteString)
        case let value as Decimal:
            let number = NSDecimalNumber(decimal: value)
            if number == .notANumber {
                return .string(number.stringValue)
            }
            return .double(number.doubleValue)
        case let value as NSNumber:
            return encodeNSNumber(value)
        case let value as PlayerID:
            return .string(value.rawValue)
        case let value as LandID:
            return .string(value.rawValue)
        case let value as SnapshotValue:
            return encodeSnapshotValue(value)
        case let value as [AnyCodable]:
            return .array(try value.map { try encodeAnyCodable($0) })
        case let value as [Any]:
            return .array(try value.map { try encodeAnyCodable(AnyCodable($0)) })
        case let value as [String: AnyCodable]:
            return try encodeAnyCodableDictionary(value)
        case let value as [String: Any]:
            var map: [MessagePackValue: MessagePackValue] = [:]
            for (key, value) in value {
                map[.string(key)] = try encodeAnyCodable(AnyCodable(value))
            }
            return .map(map)
        case let value as any Encodable:
            return try MessagePackValueEncoder().encode(AnyEncodable(value))
        default:
            let typeName = String(describing: Swift.type(of: value.base))
            throw MessagePackDirectEncodingError.unsupportedAnyCodable(typeName)
        }
    }

    private func encodeNSNumber(_ value: NSNumber) -> MessagePackValue {
        if CFGetTypeID(value) == CFBooleanGetTypeID() {
            return .bool(value.boolValue)
        }
        if CFNumberIsFloatType(value) {
            return .double(value.doubleValue)
        }
        let intValue = value.int64Value
        if intValue >= 0 {
            return .uint(UInt64(intValue))
        }
        return .int(intValue)
    }
}
