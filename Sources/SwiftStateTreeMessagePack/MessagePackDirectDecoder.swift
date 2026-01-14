import Foundation
import SwiftStateTree

enum MessagePackDirectDecodingError: Error {
    case invalidFormat(String)
    case unsupportedValue(String)
}

struct MessagePackDirectDecoder {
    func decodeTransportMessage(from value: MessagePackValue) throws -> TransportMessage {
        let map = try stringKeyedMap(from: value, context: "transport message")
        guard let kindValue = map["kind"], case let .string(kindRaw) = kindValue else {
            throw MessagePackDirectDecodingError.invalidFormat("Missing kind")
        }
        guard let kind = MessageKind(rawValue: kindRaw) else {
            throw MessagePackDirectDecodingError.invalidFormat("Unknown kind: \(kindRaw)")
        }
        guard let payloadValue = map["payload"] else {
            throw MessagePackDirectDecodingError.invalidFormat("Missing payload")
        }

        let payloadMap = try stringKeyedMap(from: payloadValue, context: "payload")
        switch kind {
        case .action:
            guard let actionValue = payloadMap["action"] else {
                throw MessagePackDirectDecodingError.invalidFormat("Missing action payload")
            }
            return TransportMessage(kind: kind, payload: .action(try decodeTransportActionPayload(from: actionValue)))
        case .actionResponse:
            guard let responseValue = payloadMap["actionResponse"] else {
                throw MessagePackDirectDecodingError.invalidFormat("Missing actionResponse payload")
            }
            return TransportMessage(kind: kind, payload: .actionResponse(try decodeTransportActionResponsePayload(from: responseValue)))
        case .event:
            guard let eventValue = payloadMap["event"] else {
                throw MessagePackDirectDecodingError.invalidFormat("Missing event payload")
            }
            // TransportEventPayload removed - TransportEvent is now used directly
            let event = try decodeTransportEvent(from: eventValue)
            return TransportMessage(kind: kind, payload: .event(event))
        case .join:
            guard let joinValue = payloadMap["join"] else {
                throw MessagePackDirectDecodingError.invalidFormat("Missing join payload")
            }
            return TransportMessage(kind: kind, payload: .join(try decodeTransportJoinPayload(from: joinValue)))
        case .joinResponse:
            guard let joinValue = payloadMap["joinResponse"] else {
                throw MessagePackDirectDecodingError.invalidFormat("Missing joinResponse payload")
            }
            return TransportMessage(kind: kind, payload: .joinResponse(try decodeTransportJoinResponsePayload(from: joinValue)))
        case .error:
            guard let errorValue = payloadMap["error"] else {
                throw MessagePackDirectDecodingError.invalidFormat("Missing error payload")
            }
            return TransportMessage(kind: kind, payload: .error(try decodeErrorPayload(from: errorValue)))
        }
    }

    func decodeStateUpdate(from value: MessagePackValue) throws -> StateUpdate {
        let map = try stringKeyedMap(from: value, context: "state update")
        guard let typeValue = map["type"], case let .string(typeRaw) = typeValue else {
            throw MessagePackDirectDecodingError.invalidFormat("Missing update type")
        }
        switch typeRaw {
        case "noChange":
            return .noChange
        case "firstSync":
            let patches = try decodeStatePatches(from: map["patches"], context: "firstSync")
            return .firstSync(patches)
        case "diff":
            let patches = try decodeStatePatches(from: map["patches"], context: "diff")
            return .diff(patches)
        default:
            throw MessagePackDirectDecodingError.invalidFormat("Unknown update type: \(typeRaw)")
        }
    }

    func decodeStateSnapshot(from value: MessagePackValue) throws -> StateSnapshot {
        let map = try stringKeyedMap(from: value, context: "state snapshot")
        guard let valuesValue = map["values"] else {
            return StateSnapshot()
        }
        let valuesMap = try stringKeyedMap(from: valuesValue, context: "snapshot values")
        var values: [String: SnapshotValue] = [:]
        for (key, value) in valuesMap {
            values[key] = try decodeSnapshotValue(from: value)
        }
        return StateSnapshot(values: values)
    }

    func decodeActionEnvelope(from value: MessagePackValue) throws -> ActionEnvelope {
        let map = try stringKeyedMap(from: value, context: "action envelope")
        guard let typeValue = map["typeIdentifier"], case let .string(typeIdentifier) = typeValue else {
            throw MessagePackDirectDecodingError.invalidFormat("Missing action typeIdentifier")
        }
        guard let payloadValue = map["payload"] else {
            throw MessagePackDirectDecodingError.invalidFormat("Missing action payload")
        }
        // ActionEnvelope.payload is AnyCodable, not Data
        let payload = try decodeAnyCodable(from: payloadValue)
        return ActionEnvelope(typeIdentifier: typeIdentifier, payload: payload)
    }

    private func decodeTransportActionPayload(from value: MessagePackValue) throws -> TransportActionPayload {
        let map = try stringKeyedMap(from: value, context: "action payload")
        let requestID = try decodeRequiredString(map["requestID"], context: "requestID")
        // landID removed - server identifies land from session mapping
        guard let actionValue = map["action"] else {
            throw MessagePackDirectDecodingError.invalidFormat("Missing action envelope")
        }
        let action = try decodeActionEnvelope(from: actionValue)
        return TransportActionPayload(requestID: requestID, action: action)
    }

    private func decodeTransportActionResponsePayload(from value: MessagePackValue) throws -> TransportActionResponsePayload {
        let map = try stringKeyedMap(from: value, context: "actionResponse payload")
        let requestID = try decodeRequiredString(map["requestID"], context: "requestID")
        guard let responseValue = map["response"] else {
            throw MessagePackDirectDecodingError.invalidFormat("Missing actionResponse response")
        }
        let response = try decodeAnyCodable(from: responseValue)
        return TransportActionResponsePayload(requestID: requestID, response: response)
    }

    // TransportEventPayload removed - TransportEvent is now used directly in MessagePayload
    // This method is no longer needed

    private func decodeTransportEvent(from value: MessagePackValue) throws -> TransportEvent {
        let map = try stringKeyedMap(from: value, context: "transport event")
        if let fromClientValue = map["fromClient"] {
            let clientMap = try stringKeyedMap(from: fromClientValue, context: "fromClient")
            guard let eventValue = clientMap["event"] else {
                throw MessagePackDirectDecodingError.invalidFormat("Missing fromClient event")
            }
            return .fromClient(event: try decodeAnyClientEvent(from: eventValue))
        }
        if let fromServerValue = map["fromServer"] {
            let serverMap = try stringKeyedMap(from: fromServerValue, context: "fromServer")
            guard let eventValue = serverMap["event"] else {
                throw MessagePackDirectDecodingError.invalidFormat("Missing fromServer event")
            }
            return .fromServer(event: try decodeAnyServerEvent(from: eventValue))
        }
        throw MessagePackDirectDecodingError.invalidFormat("Missing fromClient/fromServer event")
    }

    private func decodeAnyClientEvent(from value: MessagePackValue) throws -> AnyClientEvent {
        let map = try stringKeyedMap(from: value, context: "client event")
        let type = try decodeRequiredString(map["type"], context: "client event type")
        guard let payloadValue = map["payload"] else {
            throw MessagePackDirectDecodingError.invalidFormat("Missing client event payload")
        }
        let payload = try decodeAnyCodable(from: payloadValue)
        let rawBody = try decodeOptionalBinaryData(map["rawBody"], context: "client event rawBody")
        return AnyClientEvent(type: type, payload: payload, rawBody: rawBody)
    }

    private func decodeAnyServerEvent(from value: MessagePackValue) throws -> AnyServerEvent {
        let map = try stringKeyedMap(from: value, context: "server event")
        let type = try decodeRequiredString(map["type"], context: "server event type")
        guard let payloadValue = map["payload"] else {
            throw MessagePackDirectDecodingError.invalidFormat("Missing server event payload")
        }
        let payload = try decodeAnyCodable(from: payloadValue)
        let rawBody = try decodeOptionalBinaryData(map["rawBody"], context: "server event rawBody")
        return AnyServerEvent(type: type, payload: payload, rawBody: rawBody)
    }

    private func decodeTransportJoinPayload(from value: MessagePackValue) throws -> TransportJoinPayload {
        let map = try stringKeyedMap(from: value, context: "join payload")
        let requestID = try decodeRequiredString(map["requestID"], context: "requestID")
        let landType = try decodeRequiredString(map["landType"], context: "landType")
        let landInstanceId = try decodeOptionalString(map["landInstanceId"], context: "landInstanceId")
        let playerID = try decodeOptionalString(map["playerID"], context: "playerID")
        let deviceID = try decodeOptionalString(map["deviceID"], context: "deviceID")
        let metadata = try decodeOptionalAnyCodableDictionary(map["metadata"], context: "metadata")
        return TransportJoinPayload(
            requestID: requestID,
            landType: landType,
            landInstanceId: landInstanceId,
            playerID: playerID,
            deviceID: deviceID,
            metadata: metadata
        )
    }

    private func decodeTransportJoinResponsePayload(from value: MessagePackValue) throws -> TransportJoinResponsePayload {
        let map = try stringKeyedMap(from: value, context: "joinResponse payload")
        let requestID = try decodeRequiredString(map["requestID"], context: "requestID")
        let success = try decodeRequiredBool(map["success"], context: "success")
        let landType = try decodeOptionalString(map["landType"], context: "landType")
        let landInstanceId = try decodeOptionalString(map["landInstanceId"], context: "landInstanceId")
        let landID = try decodeOptionalString(map["landID"], context: "landID")
        let playerID = try decodeOptionalString(map["playerID"], context: "playerID")
        let reason = try decodeOptionalString(map["reason"], context: "reason")
        return TransportJoinResponsePayload(
            requestID: requestID,
            success: success,
            landType: landType,
            landInstanceId: landInstanceId,
            landID: landID,
            playerID: playerID,
            reason: reason
        )
    }

    private func decodeErrorPayload(from value: MessagePackValue) throws -> ErrorPayload {
        let map = try stringKeyedMap(from: value, context: "error payload")
        let code = try decodeRequiredString(map["code"], context: "code")
        let message = try decodeRequiredString(map["message"], context: "message")
        let details = try decodeOptionalAnyCodableDictionary(map["details"], context: "details")
        return ErrorPayload(code: code, message: message, details: details)
    }

    private func decodeStatePatches(from value: MessagePackValue?, context: String) throws -> [StatePatch] {
        guard let value else {
            throw MessagePackDirectDecodingError.invalidFormat("Missing patches for \(context)")
        }
        guard case let .array(values) = value else {
            throw MessagePackDirectDecodingError.invalidFormat("Invalid patches for \(context)")
        }
        return try values.map { try decodeStatePatch(from: $0) }
    }

    private func decodeStatePatch(from value: MessagePackValue) throws -> StatePatch {
        let map = try stringKeyedMap(from: value, context: "state patch")
        let path = try decodeRequiredString(map["path"], context: "patch path")
        let op = try decodeRequiredString(map["op"], context: "patch op")
        switch op {
        case "replace":
            guard let value = map["value"] else {
                throw MessagePackDirectDecodingError.invalidFormat("Missing value for replace")
            }
            return StatePatch(path: path, operation: .set(try decodeSnapshotValue(from: value)))
        case "add":
            guard let value = map["value"] else {
                throw MessagePackDirectDecodingError.invalidFormat("Missing value for add")
            }
            return StatePatch(path: path, operation: .add(try decodeSnapshotValue(from: value)))
        case "remove":
            return StatePatch(path: path, operation: .delete)
        default:
            throw MessagePackDirectDecodingError.invalidFormat("Unknown patch op: \(op)")
        }
    }

    private func decodeSnapshotValue(from value: MessagePackValue) throws -> SnapshotValue {
        switch value {
        case .nil:
            return .null
        case .bool(let value):
            return .bool(value)
        case .int(let value):
            guard value >= Int64(Int.min) && value <= Int64(Int.max) else {
                throw MessagePackDirectDecodingError.unsupportedValue("Int64 out of range for SnapshotValue")
            }
            return .int(Int(value))
        case .uint(let value):
            guard value <= UInt64(Int.max) else {
                throw MessagePackDirectDecodingError.unsupportedValue("UInt64 too large for SnapshotValue")
            }
            return .int(Int(value))
        case .float(let value):
            return .double(Double(value))
        case .double(let value):
            return .double(value)
        case .string(let value):
            return .string(value)
        case .binary(let value):
            return .string(value.base64EncodedString())
        case .array(let values):
            return .array(try values.map { try decodeSnapshotValue(from: $0) })
        case .map(let values):
            var object: [String: SnapshotValue] = [:]
            for (key, value) in values {
                guard case let .string(keyString) = key else {
                    throw MessagePackDirectDecodingError.invalidFormat("Non-string snapshot key")
                }
                object[keyString] = try decodeSnapshotValue(from: value)
            }
            return .object(object)
        case .extended:
            throw MessagePackDirectDecodingError.unsupportedValue("Unsupported extended snapshot value")
        }
    }

    private func decodeAnyCodable(from value: MessagePackValue) throws -> AnyCodable {
        switch value {
        case .nil:
            return AnyCodable(Optional<Int>.none)
        case .bool(let value):
            return AnyCodable(value)
        case .int(let value):
            if value >= Int64(Int.min) && value <= Int64(Int.max) {
                return AnyCodable(Int(value))
            }
            return AnyCodable(value)
        case .uint(let value):
            if value <= UInt64(Int.max) {
                return AnyCodable(Int(value))
            }
            return AnyCodable(value)
        case .float(let value):
            return AnyCodable(Double(value))
        case .double(let value):
            return AnyCodable(value)
        case .string(let value):
            return AnyCodable(value)
        case .binary(let value):
            return AnyCodable(value)
        case .array(let values):
            let array = try values.map { try decodeAnyCodable(from: $0).base }
            return AnyCodable(array)
        case .map(let values):
            var object: [String: Any] = [:]
            for (key, value) in values {
                guard case let .string(keyString) = key else {
                    throw MessagePackDirectDecodingError.invalidFormat("Non-string AnyCodable key")
                }
                object[keyString] = try decodeAnyCodable(from: value).base
            }
            return AnyCodable(object)
        case .extended(_, let data):
            return AnyCodable(data)
        }
    }

    private func decodeOptionalAnyCodableDictionary(
        _ value: MessagePackValue?,
        context: String
    ) throws -> [String: AnyCodable]? {
        guard let value else { return nil }
        if case .nil = value { return nil }
        let map = try stringKeyedMap(from: value, context: context)
        var result: [String: AnyCodable] = [:]
        for (key, value) in map {
            result[key] = try decodeAnyCodable(from: value)
        }
        return result
    }

    private func decodeRequiredString(_ value: MessagePackValue?, context: String) throws -> String {
        guard let value else {
            throw MessagePackDirectDecodingError.invalidFormat("Missing \(context)")
        }
        guard case let .string(string) = value else {
            throw MessagePackDirectDecodingError.invalidFormat("Invalid \(context) string")
        }
        return string
    }

    private func decodeRequiredBool(_ value: MessagePackValue?, context: String) throws -> Bool {
        guard let value else {
            throw MessagePackDirectDecodingError.invalidFormat("Missing \(context)")
        }
        guard case let .bool(value) = value else {
            throw MessagePackDirectDecodingError.invalidFormat("Invalid \(context) bool")
        }
        return value
    }

    private func decodeOptionalString(_ value: MessagePackValue?, context: String) throws -> String? {
        guard let value else { return nil }
        if case .nil = value { return nil }
        guard case let .string(string) = value else {
            throw MessagePackDirectDecodingError.invalidFormat("Invalid \(context) string")
        }
        return string
    }

    private func decodeOptionalBinaryData(_ value: MessagePackValue?, context: String) throws -> Data? {
        guard let value else { return nil }
        if case .nil = value { return nil }
        return try decodeBinaryData(from: value, context: context)
    }

    private func decodeBinaryData(from value: MessagePackValue, context: String) throws -> Data {
        switch value {
        case .binary(let data):
            return data
        case .string(let string):
            if let data = Data(base64Encoded: string) {
                return data
            }
            throw MessagePackDirectDecodingError.invalidFormat("Invalid base64 for \(context)")
        default:
            throw MessagePackDirectDecodingError.invalidFormat("Invalid binary data for \(context)")
        }
    }

    private func stringKeyedMap(from value: MessagePackValue, context: String) throws -> [String: MessagePackValue] {
        guard case let .map(values) = value else {
            throw MessagePackDirectDecodingError.invalidFormat("Expected map for \(context)")
        }
        var map: [String: MessagePackValue] = [:]
        for (key, value) in values {
            guard case let .string(keyString) = key else {
                throw MessagePackDirectDecodingError.invalidFormat("Non-string key in \(context)")
            }
            map[keyString] = value
        }
        return map
    }
}

