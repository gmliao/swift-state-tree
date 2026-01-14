// Sources/SwiftStateTreeTransport/TransportMessageDecoder.swift
//
// Decoder for TransportMessage with support for opcode array format.

import Foundation
import SwiftStateTree

/// Decodes TransportMessage from opcode array format.
public struct OpcodeTransportMessageDecoder {
    public init() {}
    
    /// Decode a TransportMessage from opcode array format.
    /// 
    /// Formats:
    /// - joinResponse: [105, requestID, success(0/1), landType?, landInstanceId?, playerSlot?, encoding?, reason?]
    /// - actionResponse: [102, requestID, response]
    /// - error: [106, code, message, details?]
    /// - action: [101, requestID, typeIdentifier, payload(base64)]
    /// - join: [104, requestID, landType, landInstanceId?, playerID?, deviceID?, metadata?]
    /// - event: [103, direction(0=client,1=server), type, payload, rawBody?]
    public func decode(from data: Data) throws -> TransportMessage {
        // Parse JSON array
        let json = try JSONSerialization.jsonObject(with: data)
        guard let array = json as? [Any], array.count >= 2 else {
            throw TransportMessageDecodingError.invalidFormat("Expected JSON array with at least 2 elements")
        }
        
        // Get opcode
        guard let opcodeValue = array[0] as? Int,
              let opcode = MessageKindOpcode(rawValue: opcodeValue) else {
            throw TransportMessageDecodingError.invalidFormat("Invalid or unknown opcode: \(array[0])")
        }
        
        // Decode based on opcode
        switch opcode {
        case .join:
            return try decodeJoin(array: array)
        case .joinResponse:
            return try decodeJoinResponse(array: array)
        case .action:
            return try decodeAction(array: array)
        case .actionResponse:
            return try decodeActionResponse(array: array)
        case .event:
            return try decodeEvent(array: array)
        case .error:
            return try decodeError(array: array)
        }
    }
    
    // MARK: - Decode Join
    
    private func decodeJoin(array: [Any]) throws -> TransportMessage {
        guard array.count >= 3 else {
            throw TransportMessageDecodingError.invalidFormat("Join array too short: expected at least 3 elements")
        }
        
        let requestID = try stringValue(array[1], name: "requestID")
        let landType = try stringValue(array[2], name: "landType")
        let landInstanceId = array.count > 3 ? optionalStringValue(array[3]) : nil
        let playerID = array.count > 4 ? optionalStringValue(array[4]) : nil
        let deviceID = array.count > 5 ? optionalStringValue(array[5]) : nil
        let metadataDict = array.count > 6 ? (array[6] as? [String: Any]) : nil
        let metadata = metadataDict.map { dict in
            dict.mapValues { AnyCodable($0) }
        }
        
        let payload = TransportJoinPayload(
            requestID: requestID,
            landType: landType,
            landInstanceId: landInstanceId,
            playerID: playerID,
            deviceID: deviceID,
            metadata: metadata
        )
        
        return TransportMessage(kind: .join, payload: .join(payload))
    }
    
    // MARK: - Decode JoinResponse
    
    private func decodeJoinResponse(array: [Any]) throws -> TransportMessage {
        guard array.count >= 3 else {
            throw TransportMessageDecodingError.invalidFormat("JoinResponse array too short: expected at least 3 elements")
        }
        
        let requestID = try stringValue(array[1], name: "requestID")
        let success = (array[2] as? Int) == 1
        let landType = array.count > 3 ? optionalStringValue(array[3]) : nil
        let landInstanceId = array.count > 4 ? optionalStringValue(array[4]) : nil
        let playerSlotRaw = array.count > 5 ? (array[5] as? Int) : nil
        let playerSlot = playerSlotRaw.map { Int32($0) }
        let encoding = array.count > 6 ? optionalStringValue(array[6]) : nil
        let reason = array.count > 7 ? optionalStringValue(array[7]) : nil
        
        let payload = TransportJoinResponsePayload(
            requestID: requestID,
            success: success,
            landType: landType,
            landInstanceId: landInstanceId,
            playerSlot: playerSlot,
            encoding: encoding,
            reason: reason
        )
        
        return TransportMessage(kind: .joinResponse, payload: .joinResponse(payload))
    }
    
    // MARK: - Decode Action
    
    private func decodeAction(array: [Any]) throws -> TransportMessage {
        guard array.count >= 4 else {
            throw TransportMessageDecodingError.invalidFormat("Action array too short: expected at least 4 elements")
        }
        
        let requestID = try stringValue(array[1], name: "requestID")
        let typeIdentifier = try stringValue(array[2], name: "typeIdentifier")
        let payloadBase64 = try stringValue(array[3], name: "payload")
        
        // Create ActionEnvelope
        let actionEnvelope = ActionEnvelope(
            typeIdentifier: typeIdentifier,
            payload: AnyCodable(payloadBase64)
        )
        
        let payload = TransportActionPayload(
            requestID: requestID,
            action: actionEnvelope
        )
        
        return TransportMessage(kind: .action, payload: .action(payload))
    }
    
    // MARK: - Decode ActionResponse
    
    private func decodeActionResponse(array: [Any]) throws -> TransportMessage {
        guard array.count >= 3 else {
            throw TransportMessageDecodingError.invalidFormat("ActionResponse array too short: expected at least 3 elements")
        }
        
        let requestID = try stringValue(array[1], name: "requestID")
        let response = array[2]
        
        let payload = TransportActionResponsePayload(
            requestID: requestID,
            response: AnyCodable(response)
        )
        
        return TransportMessage(kind: .actionResponse, payload: .actionResponse(payload))
    }
    
    // MARK: - Decode Event
    
    private func decodeEvent(array: [Any]) throws -> TransportMessage {
        guard array.count >= 4 else {
            throw TransportMessageDecodingError.invalidFormat("Event array too short: expected at least 4 elements")
        }
        
        let direction = try intValue(array[1], name: "direction")
        let typeValue = array[2]
        let payloadValue = array[3]
        let rawBodyString = array.count > 4 ? (array[4] as? String) : nil
        let rawBody = rawBodyString.flatMap { $0.data(using: .utf8) }
        
        // Determine event type (can be Int opcode or String)
        let eventType: String
        if typeValue is Int {
            // TODO: Support opcode to type mapping if needed
            throw TransportMessageDecodingError.invalidFormat("Event opcode not yet supported, use string type")
        } else if let typeStr = typeValue as? String {
            eventType = typeStr
        } else {
            throw TransportMessageDecodingError.invalidFormat("Event type must be Int or String, got: \(type(of: typeValue))")
        }
        
        // Decode payload
        let payload: AnyCodable
        if let payloadArray = payloadValue as? [Any] {
            // Payload is array format
            payload = AnyCodable(payloadArray)
        } else {
            // Payload is object
            payload = AnyCodable(payloadValue)
        }
        
        let event: TransportEvent
        if direction == 0 {
            // fromClient
            event = .fromClient(event: AnyClientEvent(
                type: eventType,
                payload: payload,
                rawBody: rawBody
            ))
        } else {
            // fromServer
            event = .fromServer(event: AnyServerEvent(
                type: eventType,
                payload: payload,
                rawBody: rawBody
            ))
        }
        
        return TransportMessage(kind: .event, payload: .event(event))
    }
    
    // MARK: - Decode Error
    
    private func decodeError(array: [Any]) throws -> TransportMessage {
        guard array.count >= 3 else {
            throw TransportMessageDecodingError.invalidFormat("Error array too short: expected at least 3 elements")
        }
        
        let code = try stringValue(array[1], name: "code")
        let message = try stringValue(array[2], name: "message")
        let detailsDict = array.count > 3 ? (array[3] as? [String: Any]) : nil
        let details = detailsDict.map { dict in
            dict.mapValues { AnyCodable($0) }
        }
        
        let error = ErrorPayload(
            code: code,
            message: message,
            details: details
        )
        
        return TransportMessage(kind: .error, payload: .error(error))
    }
    
    // MARK: - Helper Methods
    
    private func stringValue(_ value: Any, name: String) throws -> String {
        guard let str = value as? String else {
            throw TransportMessageDecodingError.invalidFormat("\(name) must be String, got: \(type(of: value))")
        }
        return str
    }
    
    private func optionalStringValue(_ value: Any) -> String? {
        if let str = value as? String {
            return str
        } else if value is NSNull {
            return nil
        } else {
            return nil
        }
    }
    
    private func intValue(_ value: Any, name: String) throws -> Int {
        guard let int = value as? Int else {
            throw TransportMessageDecodingError.invalidFormat("\(name) must be Int, got: \(type(of: value))")
        }
        return int
    }
}

/// Errors that can occur during TransportMessage decoding.
public enum TransportMessageDecodingError: Error, Sendable {
    case invalidFormat(String)
}
