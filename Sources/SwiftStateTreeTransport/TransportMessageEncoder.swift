// Sources/SwiftStateTreeTransport/TransportMessageEncoder.swift
//
// Encoder for TransportMessage with support for JSON and Opcode array formats.

import Foundation
import SwiftStateTree

// MARK: - Message Kind Opcodes

/// Opcode values for MessageKind in opcode array format.
/// Uses 101+ range to avoid conflict with StateUpdateOpcode (0-2).
public enum MessageKindOpcode: Int, Sendable {
    case action = 101
    case actionResponse = 102
    case event = 103
    case join = 104
    case joinResponse = 105
    case error = 106
    
    public init?(kind: MessageKind) {
        switch kind {
        case .action: self = .action
        case .actionResponse: self = .actionResponse
        case .event: self = .event
        case .join: self = .join
        case .joinResponse: self = .joinResponse
        case .error: self = .error
        }
    }
    
    public var messageKind: MessageKind {
        switch self {
        case .action: return .action
        case .actionResponse: return .actionResponse
        case .event: return .event
        case .join: return .join
        case .joinResponse: return .joinResponse
        case .error: return .error
        }
    }
}

// MARK: - TransportMessageEncoder Protocol

/// Encodes TransportMessage for wire transmission.
public protocol TransportMessageEncoder: Sendable {
    var encoding: TransportEncoding { get }
    func encode(_ message: TransportMessage) throws -> Data
}

// MARK: - JSON Encoder

/// JSON object-based transport message encoder.
public struct JSONTransportMessageEncoder: TransportMessageEncoder {
    public let encoding: TransportEncoding = .json
    
    private let encoder: JSONEncoder
    
    public init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        self.encoder = encoder
    }
    
    public func encode(_ message: TransportMessage) throws -> Data {
        try encoder.encode(message)
    }
}

// MARK: - Opcode Array Encoder

/// Opcode + JSON array transport message encoder.
///
/// Encodes TransportMessage as a compact JSON array:
/// - joinResponse: [opcode, requestID, success, landType?, landInstanceId?, playerSlot?]
/// - actionResponse: [opcode, requestID, response]
/// - error: [opcode, code, message, details?]
/// - Other formats as needed
// MARK: - Opcode Array Encoder

/// Opcode + JSON array transport message encoder.
///
/// Encodes TransportMessage as a compact JSON array:
/// - joinResponse: [opcode, requestID, success, landType?, landInstanceId?, playerSlot?]
/// - actionResponse: [opcode, requestID, response]
/// - error: [opcode, code, message, details?]
/// - Other formats as needed
public struct OpcodeTransportMessageEncoder: TransportMessageEncoder {
    public let encoding: TransportEncoding = .opcodeJsonArray
    
    private let encoder: JSONEncoder
    private let eventHashes: [String: Int]?
    private let clientEventHashes: [String: Int]?
    private let enablePayloadCompression: Bool
    
    public init(
        eventHashes: [String: Int]? = nil,
        clientEventHashes: [String: Int]? = nil,
        enablePayloadCompression: Bool = false
    ) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        self.encoder = encoder
        self.eventHashes = eventHashes
        self.clientEventHashes = clientEventHashes
        self.enablePayloadCompression = enablePayloadCompression
    }
    
    public func encode(_ message: TransportMessage) throws -> Data {
        let array = try encodeToArray(message)
        return try encoder.encode(array)
    }
    
    // ... existing private methods ...
    
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
            return encodeActionResponse(opcode: opcode, payload: payload)
            
        case .error(let payload):
            return encodeError(opcode: opcode, payload: payload)
            
        case .action(let payload):
            return encodeAction(opcode: opcode, payload: payload)
            
        case .join(let payload):
            return encodeJoin(opcode: opcode, payload: payload)
            
        case .event(let event):
            return try encodeEvent(opcode: opcode, event: event)
        }
    }
    
    // ... encodeJoinResponse, encodeActionResponse, encodeError, encodeAction, encodeJoin methods ...
    
    private func encodeJoinResponse(opcode: MessageKindOpcode, payload: TransportJoinResponsePayload) -> [AnyCodable] {
        var result: [AnyCodable] = [
            AnyCodable(opcode.rawValue),
            AnyCodable(payload.requestID),
            AnyCodable(payload.success ? 1 : 0)
        ]
        
        // Optional fields - only include if present
        if payload.landType != nil || payload.landInstanceId != nil || payload.playerSlot != nil || payload.reason != nil {
            result.append(AnyCodable(payload.landType))
        }
        if payload.landInstanceId != nil || payload.playerSlot != nil || payload.reason != nil {
            result.append(AnyCodable(payload.landInstanceId))
        }
        if payload.playerSlot != nil || payload.reason != nil {
            result.append(AnyCodable(payload.playerSlot))
        }
        if payload.reason != nil {
            result.append(AnyCodable(payload.reason))
        }
        
        return result
    }
    
    private func encodeActionResponse(opcode: MessageKindOpcode, payload: TransportActionResponsePayload) -> [AnyCodable] {
        // Encode response payload: Array or Object
        let responseValue: AnyCodable
        if enablePayloadCompression {
            responseValue = encodePayloadAsArray(payload.response)
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
    
    private func encodeAction(opcode: MessageKindOpcode, payload: TransportActionPayload) -> [AnyCodable] {
        // Encode action payload: Array or Object (same rule as Event)
        let payloadValue: AnyCodable
        if enablePayloadCompression {
            payloadValue = encodePayloadAsArray(payload.action.payload)
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
                payloadValue = encodePayloadAsArray(clientEvent.payload)
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
                payloadValue = encodePayloadAsArray(serverEvent.payload)
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
    
    private func encodePayloadAsArray(_ payload: Any) -> AnyCodable {
        // Extract the actual payload value from AnyCodable if needed
        let actualPayload: Any
        if let anyCodable = payload as? AnyCodable {
            // If payload is AnyCodable, extract its base value
            actualPayload = anyCodable.base
        } else {
            actualPayload = payload
        }
        
        // All payload types (ActionPayload, ResponsePayload, ClientEventPayload, ServerEventPayload)
        // must use @Payload macro which generates encodeAsArray() with correct field order.
        // The default PayloadCompression.encodeAsArray() implementation is fatalError,
        // so if a type doesn't have @Payload macro, it will crash at runtime.
        guard let payloadCompression = actualPayload as? any PayloadCompression else {
            // This should never happen for valid payload types, but provide a clear error message
            fatalError("Payload type '\(type(of: actualPayload))' must conform to PayloadCompression and use @Payload macro for compression support.")
        }
        
        let array = payloadCompression.encodeAsArray()
        return AnyCodable(array)
    }
}

// MARK: - TransportEncoding Extension

public extension TransportEncoding {
    /// Create a message encoder for the selected encoding.
    func makeMessageEncoder(
        eventHashes: [String: Int]? = nil,
        clientEventHashes: [String: Int]? = nil,
        enablePayloadCompression: Bool = false
    ) -> any TransportMessageEncoder {
        switch self {
        case .json:
            return JSONTransportMessageEncoder()
        case .opcodeJsonArray:
            return OpcodeTransportMessageEncoder(
                eventHashes: eventHashes,
                clientEventHashes: clientEventHashes,
                enablePayloadCompression: enablePayloadCompression
            )
        }
    }
}
