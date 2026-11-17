// Sources/SwiftStateTreeTransport/MessagePackTransportMessageEncoder.swift
//
// MessagePack encoder for TransportMessage using opcode array format.
// Uses the same array structure as OpcodeTransportMessageEncoder but serializes with MessagePack.

import Foundation
import SwiftStateTree
import SwiftStateTreeMessagePack

/// MessagePack + Opcode array transport message encoder.
///
/// Encodes TransportMessage as a compact MessagePack array (same structure as opcodeJsonArray):
/// - joinResponse: [opcode, requestID, success, landType?, landInstanceId?, playerSlot?, encoding?, reason?, stateUpdateFeatures?]
/// - actionResponse: [opcode, requestID, response]
/// - error: [opcode, code, message, details?]
/// - action: [opcode, requestID, typeIdentifier, payload]
/// - join: [opcode, requestID, landType, landInstanceId?, playerID?, deviceID?, metadata?]
/// - event: [opcode, direction(0=client,1=server), type, payload, rawBody?]
///
/// The array structure is identical to OpcodeTransportMessageEncoder, but uses MessagePack binary serialization
/// instead of JSON text serialization.
public struct MessagePackTransportMessageEncoder: TransportMessageEncoder {
    public let encoding: TransportEncoding = .messagepack
    
    private let eventHashes: [String: Int]?
    private let clientEventHashes: [String: Int]?
    private let enablePayloadCompression: Bool
    
    public init(
        eventHashes: [String: Int]? = nil,
        clientEventHashes: [String: Int]? = nil,
        enablePayloadCompression: Bool = false
    ) {
        self.eventHashes = eventHashes
        self.clientEventHashes = clientEventHashes
        self.enablePayloadCompression = enablePayloadCompression
    }
    
    public func encode(_ message: TransportMessage) throws -> Data {
        // Generate array structure (same as OpcodeTransportMessageEncoder)
        let array = try encodeToArray(message)
        
        // Convert [AnyCodable] to MessagePackValue array
        let messagePackArray = try array.map { try anyCodableToMessagePackValue($0) }
        
        // Serialize with MessagePack
        return try pack(.array(messagePackArray))
    }

    /// Encode a server event body (opcode removed) directly to MessagePackValue.
    /// This avoids an extra pack/unpack cycle when building opcode 107 frames.
    func encodeServerEventBody(_ event: AnyServerEvent) throws -> MessagePackValue {
        let transportMsg = TransportMessage.event(event: .fromServer(event: event))
        let array = try encodeToArray(transportMsg)
        let messagePackArray = try array.map { try anyCodableToMessagePackValue($0) }
        guard messagePackArray.count >= 2 else {
            throw EncodingError.invalidValue(event, .init(
                codingPath: [],
                debugDescription: "MessagePack event array is too short"
            ))
        }
        return .array(Array(messagePackArray.dropFirst()))
    }
    
    // MARK: - Array Encoding (same logic as OpcodeTransportMessageEncoder)
    
    private func encodeToArray(_ message: TransportMessage) throws -> [AnyCodable] {
        guard let opcode = MessageKindOpcode(kind: message.kind) else {
            throw EncodingError.invalidValue(message.kind, .init(
                codingPath: [],
                debugDescription: "Unknown MessageKind: \(message.kind)"
            ))
        }
        
        switch message.payload {
        case .joinResponse(let payload):
            return encodeJoinResponse(opcode: opcode, payload: payload)
            
        case .actionResponse(let payload):
            return try encodeActionResponse(opcode: opcode, payload: payload)
            
        case .error(let payload):
            return encodeError(opcode: opcode, payload: payload)
            
        case .action(let payload):
            return try encodeAction(opcode: opcode, payload: payload)
            
        case .join(let payload):
            return encodeJoin(opcode: opcode, payload: payload)
            
        case .event(let event):
            return try encodeEvent(opcode: opcode, event: event)
        }
    }
    
    private func encodeJoinResponse(opcode: MessageKindOpcode, payload: TransportJoinResponsePayload) -> [AnyCodable] {
        var result: [AnyCodable] = [
            AnyCodable(opcode.rawValue),
            AnyCodable(payload.requestID),
            AnyCodable(payload.success ? 1 : 0)
        ]
        
        // Optional fields, positional, up to the last one present.
        let optionals: [AnyCodable?] = [
            payload.landType.map(AnyCodable.init),
            payload.landInstanceId.map(AnyCodable.init),
            payload.playerSlot.map(AnyCodable.init),
            payload.encoding.map(AnyCodable.init),
            payload.reason.map(AnyCodable.init),
            payload.stateUpdateFeatures.map(AnyCodable.init),
        ]
        if let last = optionals.lastIndex(where: { $0 != nil }) {
            result.append(contentsOf: optionals[...last].map { $0 ?? AnyCodable(nil as String?) })
        }
        
        return result
    }
    
    private func encodeActionResponse(opcode: MessageKindOpcode, payload: TransportActionResponsePayload) throws -> [AnyCodable] {
        // Encode response payload: Array or Object
        let responseValue: AnyCodable
        if enablePayloadCompression {
            responseValue = try encodePayloadAsArray(payload.response)
        } else {
            responseValue = payload.response
        }
        
        return [
            AnyCodable(opcode.rawValue),
            AnyCodable(payload.requestID),
            responseValue
        ]
    }
    
    private func encodeError(opcode: MessageKindOpcode, payload: ErrorPayload) -> [AnyCodable] {
        var result: [AnyCodable] = [
            AnyCodable(opcode.rawValue),
            AnyCodable(payload.code),
            AnyCodable(payload.message)
        ]
        
        if let details = payload.details {
            result.append(AnyCodable(details))
        }
        
        return result
    }
    
    private func encodeAction(opcode: MessageKindOpcode, payload: TransportActionPayload) throws -> [AnyCodable] {
        // Encode action payload: Array or Object (same rule as Event)
        let payloadValue: AnyCodable
        if enablePayloadCompression {
            payloadValue = try encodePayloadAsArray(payload.action.payload)
        } else {
            payloadValue = payload.action.payload
        }
        
        return [
            AnyCodable(opcode.rawValue),
            AnyCodable(payload.requestID),
            AnyCodable(payload.action.typeIdentifier),
            payloadValue
        ]
    }
    
    private func encodeJoin(opcode: MessageKindOpcode, payload: TransportJoinPayload) -> [AnyCodable] {
        var result: [AnyCodable] = [
            AnyCodable(opcode.rawValue),
            AnyCodable(payload.requestID),
            AnyCodable(payload.landType)
        ]
        
        // Optional trailing fields
        if payload.landInstanceId != nil || payload.playerID != nil || payload.deviceID != nil || payload.metadata != nil {
            result.append(AnyCodable(payload.landInstanceId))
        }
        if payload.playerID != nil || payload.deviceID != nil || payload.metadata != nil {
            result.append(AnyCodable(payload.playerID))
        }
        if payload.deviceID != nil || payload.metadata != nil {
            result.append(AnyCodable(payload.deviceID))
        }
        if let metadata = payload.metadata {
            result.append(AnyCodable(metadata))
        }
        
        return result
    }
    
    /// Encode Event: [opcode, direction(0=client,1=server), type(int|string), payload, rawBody?]
    private func encodeEvent(opcode: MessageKindOpcode, event: TransportEvent) throws -> [AnyCodable] {
        switch event {
        case .fromClient(let clientEvent):
            // Check for opcode, fallback to string type
            let typeValue: AnyCodable
            if let hash = clientEventHashes?[clientEvent.type] {
                typeValue = AnyCodable(hash)
            } else {
                typeValue = AnyCodable(clientEvent.type)
            }
            
            // Encode payload: Array or Object
            let payloadValue: AnyCodable
            if enablePayloadCompression {
                payloadValue = try encodePayloadAsArray(clientEvent.payload)
            } else {
                payloadValue = AnyCodable(clientEvent.payload)
            }
            
            var result: [AnyCodable] = [
                AnyCodable(opcode.rawValue),
                AnyCodable(0), // 0 = fromClient
                typeValue,
                payloadValue
            ]
            if let rawBody = clientEvent.rawBody {
                result.append(AnyCodable(rawBody))
            }
            return result
            
        case .fromServer(let serverEvent):
            // Check for opcode, fallback to string type
            let typeValue: AnyCodable
            if let hash = eventHashes?[serverEvent.type] {
                typeValue = AnyCodable(hash)
            } else {
                typeValue = AnyCodable(serverEvent.type)
            }
            
            // Encode payload: Array or Object
            let payloadValue: AnyCodable
            if enablePayloadCompression {
                payloadValue = try encodePayloadAsArray(serverEvent.payload, typed: serverEvent.wireForm)
            } else {
                payloadValue = AnyCodable(serverEvent.payload)
            }
            
            var result: [AnyCodable] = [
                AnyCodable(opcode.rawValue),
                AnyCodable(1), // 1 = fromServer
                typeValue,
                payloadValue
            ]
            if let rawBody = serverEvent.rawBody {
                result.append(AnyCodable(rawBody))
            }
            return result
        }
    }
    
    /// The positional form of a payload: the payload's fields as one `MessagePackValue`, which `anyCodableToMessagePackValue` passes through, written by the
    /// type's `@Payload` writer (#521). `typed` is the event's typed value when it carries one;
    /// otherwise the payload is unwrapped from its box and cast.
    private func encodePayloadAsArray(_ payload: Any, typed: (any ServerEventPayload)? = nil) throws -> AnyCodable {
        if let typed {
            return AnyCodable(try MessagePackPayloadFieldWriter.positional(typed))
        }
        // Extract the actual payload value from AnyCodable if needed
        let actualPayload: Any
        if let anyCodable = payload as? AnyCodable {
            actualPayload = anyCodable.base
        } else {
            actualPayload = payload
        }

        // Support empty payloads in compressed mode.
        // Some message variants may encode "no payload" as `Void` / `()`.
        if actualPayload is Void {
            return AnyCodable([AnyCodable]())
        }

        // Every payload type (ActionPayload, ResponsePayload, ClientEventPayload,
        // ServerEventPayload) is a PayloadCompression; a type without `@Payload` throws from its
        // writer. A value that isn't a payload type at all (a raw dictionary, array or primitive)
        // still ends the process here (#544).
        guard let payloadCompression = actualPayload as? any PayloadCompression else {
            fatalError("Payload type '\(type(of: actualPayload))' must conform to PayloadCompression and use @Payload macro for compression support.")
        }
        return AnyCodable(try MessagePackPayloadFieldWriter.positional(payloadCompression))
    }
    
    // MARK: - MessagePack Conversion
    
    /// Convert AnyCodable to MessagePackValue
    private func anyCodableToMessagePackValue(_ value: AnyCodable) throws -> MessagePackValue {
        // A positional payload is already a value (`encodePayloadAsArray`).
        if let value = value.base as? MessagePackValue {
            return value
        }
        // Use MessagePackValueEncoder to convert AnyCodable to MessagePackValue
        return try MessagePackValueEncoder().encode(value)
    }
}
