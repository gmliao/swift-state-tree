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

/// An encoder that writes an action's reply from the keeper's outcome (#700 K1a): the response
/// stays its own type up to the frame, never boxed into `Any` (`AnyCodable`), which allocates for
/// a response that doesn't fit an existential's inline buffer. The bytes are the ones
/// `encode(.actionResponse(requestID:response: outcome.boundaryValue))` writes.
package protocol ActionResponseFrameEncoder: Sendable {
    func encodeActionResponse(requestID: String, outcome: InputOutcome) throws -> Data
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
        try DecimalScan.check(message)
        return try encoder.encode(message)
    }
}

extension JSONTransportMessageEncoder: ActionResponseFrameEncoder {
    package func encodeActionResponse(requestID: String, outcome: InputOutcome) throws -> Data {
        let message = ActionResponseJSONMessage(requestID: requestID, outcome: outcome)
        try DecimalScan.check(message)
        return try encoder.encode(message)
    }
}

/// `TransportMessage.actionResponse`'s JSON object, written from the outcome:
/// `{"kind": "actionResponse", "payload": {"actionResponse": {"requestID": …, "response": …}}}`,
/// with `null` for no response, as `AnyCodable(())` writes.
private struct ActionResponseJSONMessage: Encodable {
    let requestID: String
    let outcome: InputOutcome

    private enum MessageKeys: String, CodingKey { case kind, payload }
    private enum PayloadKeys: String, CodingKey { case actionResponse }
    private enum ResponseKeys: String, CodingKey { case requestID, response }

    func encode(to encoder: Encoder) throws {
        var message = encoder.container(keyedBy: MessageKeys.self)
        try message.encode(MessageKind.actionResponse, forKey: .kind)
        var payload = message.nestedContainer(keyedBy: PayloadKeys.self, forKey: .payload)
        var body = payload.nestedContainer(keyedBy: ResponseKeys.self, forKey: .actionResponse)
        try body.encode(requestID, forKey: .requestID)
        switch outcome {
        case .none: try body.encodeNil(forKey: .response)
        // Opened, not converted: the response isn't boxed again.
        case .response(let response): try body.encode(response, forKey: .response)
        }
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
        try DecimalScan.check(array)
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
            fatalError("PROBE #543 mutant a: no Void branch in encodePayloadAsArray (pre-#542)")
        }

        // Every payload type (ActionPayload, ResponsePayload, ClientEventPayload,
        // ServerEventPayload) is a PayloadCompression; a type without `@Payload` throws from its
        // writer. A value that isn't a payload type at all (a raw dictionary, array or primitive,
        // from an untyped event or a record) throws too: a server event that doesn't encode ends
        // its land, never the process (#544, #538).
        guard let payloadCompression = actualPayload as? any PayloadCompression else {
            throw UntypedPayloadError(typeName: String(describing: type(of: actualPayload)))
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

extension OpcodeTransportMessageEncoder: ActionResponseFrameEncoder {
    package func encodeActionResponse(requestID: String, outcome: InputOutcome) throws -> Data {
        let array = ActionResponseOpcodeArray(
            opcode: MessageKindOpcode.actionResponse.rawValue,
            requestID: requestID,
            outcome: outcome,
            positional: enablePayloadCompression
        )
        try DecimalScan.check(array)
        return try encoder.encode(array)
    }
}

/// The opcode array of an action's reply, `[opcode, requestID, response]`, written from the
/// outcome. No response is `[]` in the positional form and `null` otherwise, as the encoders
/// write `AnyCodable(())`.
private struct ActionResponseOpcodeArray: Encodable {
    let opcode: Int
    let requestID: String
    let outcome: InputOutcome
    let positional: Bool

    func encode(to encoder: Encoder) throws {
        var array = encoder.unkeyedContainer()
        try array.encode(opcode)
        try array.encode(requestID)
        switch outcome {
        case .none:
            if positional { fatalError("PROBE #543 mutant a: no Void branch in the positional action response (pre-#542)") } else { try array.encodeNil() }
        case .response(let response):
            // Opened, not converted: the response isn't boxed again.
            if positional { try Self.encodePositional(response, into: &array) } else { try array.encode(response) }
        }
    }

    private static func encodePositional<P: PayloadCompression>(_ payload: P, into array: inout UnkeyedEncodingContainer) throws {
        try array.encode(PositionalPayloadJSONOf(payload: payload))
    }
}

/// `PositionalPayloadJSON` for a payload of a known type: holding it doesn't box it.
private struct PositionalPayloadJSONOf<P: PayloadCompression>: Encodable {
    let payload: P

    func encode(to encoder: Encoder) throws {
        var writer = JSONPayloadFieldWriter(container: encoder.unkeyedContainer())
        try payload._writePayloadFields(into: &writer)
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
