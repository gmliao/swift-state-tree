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
public struct OpcodeTransportMessageEncoder: TransportMessageEncoder {
    public let encoding: TransportEncoding = .opcodeJsonArray
    
    private let encoder: JSONEncoder
    
    public init() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = []
        self.encoder = encoder
    }
    
    public func encode(_ message: TransportMessage) throws -> Data {
        let array = try encodeToArray(message)
        return try encoder.encode(array)
    }
    
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
    
    // MARK: - Payload Encoding
    
    /// Encode JoinResponse: [opcode, requestID, success(0/1), landType?, landInstanceId?, playerSlot?, reason?]
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
    
    /// Encode ActionResponse: [opcode, requestID, response]
    private func encodeActionResponse(opcode: MessageKindOpcode, payload: TransportActionResponsePayload) -> [AnyCodable] {
        [
            AnyCodable(opcode.rawValue),
            AnyCodable(payload.requestID),
            payload.response
        ]
    }
    
    /// Encode Error: [opcode, code, message, details?]
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
    
    /// Encode Action: [opcode, requestID, typeIdentifier, payload(base64)]
    private func encodeAction(opcode: MessageKindOpcode, payload: TransportActionPayload) -> [AnyCodable] {
        [
            AnyCodable(opcode.rawValue),
            AnyCodable(payload.requestID),
            AnyCodable(payload.action.typeIdentifier),
            AnyCodable(payload.action.payload.base64EncodedString())
        ]
    }
    
    /// Encode Join: [opcode, requestID, landType, landInstanceId?, playerID?, deviceID?, metadata?]
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
    
    /// Encode Event: [opcode, direction(0=client,1=server), type, payload, rawBody?]
    private func encodeEvent(opcode: MessageKindOpcode, event: TransportEvent) throws -> [AnyCodable] {
        switch event {
        case .fromClient(let clientEvent):
            var result: [AnyCodable] = [
                AnyCodable(opcode.rawValue),
                AnyCodable(0), // 0 = fromClient
                AnyCodable(clientEvent.type),
                AnyCodable(clientEvent.payload)
            ]
            if let rawBody = clientEvent.rawBody {
                result.append(AnyCodable(rawBody))
            }
            return result
            
        case .fromServer(let serverEvent):
            var result: [AnyCodable] = [
                AnyCodable(opcode.rawValue),
                AnyCodable(1), // 1 = fromServer
                AnyCodable(serverEvent.type),
                AnyCodable(serverEvent.payload)
            ]
            if let rawBody = serverEvent.rawBody {
                result.append(AnyCodable(rawBody))
            }
            return result
        }
    }
}

// MARK: - TransportEncoding Extension

public extension TransportEncoding {
    /// Create a message encoder for the selected encoding.
    func makeMessageEncoder() -> any TransportMessageEncoder {
        switch self {
        case .json:
            return JSONTransportMessageEncoder()
        case .opcodeJsonArray:
            return OpcodeTransportMessageEncoder()
        }
    }
}
