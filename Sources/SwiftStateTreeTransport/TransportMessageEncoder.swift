// Sources/SwiftStateTreeTransport/TransportMessageEncoder.swift
//
// Encoder for TransportMessage with support for JSON and Opcode array formats.

import Foundation
import SwiftStateTree

// MARK: - Transport Protocol Opcodes

/// Opcode values for MessageKind in opcode array format.
/// Uses 101+ range to avoid conflict with StateUpdateOpcode (0-2).
///
/// ## Opcode Ranges
/// - **101-106**: Message type opcodes (enum cases)
/// - **107+**: Special frame opcodes (static constants)
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
    
    // MARK: Special Frame Opcodes (107+)
    
    /// State update with merged events (opcode 107).
    /// Format: [107, stateUpdatePayload, eventsArray]
    /// Used to merge broadcast events with state updates for efficiency.
    ///
    /// Note: This is not a MessageKind opcode, but a special frame format
    /// for optimizing state updates with events.
    public static let stateUpdateWithEvents: Int64 = 107
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
        // Object keys in UTF-8 byte order, not hash order, so a message's bytes don't depend on
        // the process (as the state-update encoders, `CanonicalEmitOrderTests`).
        encoder.outputFormatting = [.sortedKeys]
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
        // Object keys in UTF-8 byte order, not hash order, so a message's bytes don't depend on
        // the process (as the state-update encoders, `CanonicalEmitOrderTests`).
        encoder.outputFormatting = [.sortedKeys]
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
    
    // ... encodeJoinResponse, encodeActionResponse, encodeError, encodeAction, encodeJoin methods ...
    
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
    
    /// The positional form of a payload: an `Encodable` that writes the payload's fields into one JSON array, written by the
    /// type's `@Payload` writer (#521). `typed` is the event's typed value when it carries one;
    /// otherwise the payload is unwrapped from its box and cast.
    private func encodePayloadAsArray(_ payload: Any, typed: (any ServerEventPayload)? = nil) throws -> AnyCodable {
        if let typed {
            return AnyCodable(PositionalPayloadJSON(payload: typed))
        }
        // Extract the actual payload value from AnyCodable if needed
        let actualPayload: Any
        if let anyCodable = payload as? AnyCodable {
            actualPayload = anyCodable.base
        } else {
            actualPayload = payload
        }

        // An empty payload, `Void`, is an empty array, as in the MessagePack encoder: the
        // immediate ACK of an action queued for a tick is `.completed(AnyCodable(()))` (#541).
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
        return AnyCodable(PositionalPayloadJSON(payload: payloadCompression))
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
        case .messagepack:
            return MessagePackTransportMessageEncoder(
                eventHashes: eventHashes,
                clientEventHashes: clientEventHashes,
                enablePayloadCompression: enablePayloadCompression
            )
        }
    }
}

/// A payload's positional form for the JSON encoders (#521): the `@Payload` writer's fields as
/// one array. A leaf is encoded with its own `Codable`, any other field through `AnyCodable`, as
/// each field of the `[AnyCodable]` array it replaces was.
struct PositionalPayloadJSON: Encodable {
    let payload: any PayloadCompression

    func encode(to encoder: Encoder) throws {
        var writer = JSONPayloadFieldWriter(container: encoder.unkeyedContainer())
        try payload._writePayloadFields(into: &writer)
    }
}

struct JSONPayloadFieldWriter: _PayloadFieldWriter {
    var container: UnkeyedEncodingContainer

    mutating func leaf<T: _PayloadWireLeaf>(_ value: T) throws {
        try container.encode(value)
    }

    mutating func fallback<T: Encodable>(_ value: T) throws {
        try container.encode(AnyCodable(value))
    }
}
