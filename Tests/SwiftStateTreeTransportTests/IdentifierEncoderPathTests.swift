// Tests/SwiftStateTreeTransportTests/IdentifierEncoderPathTests.swift
//
// One shape for identifiers on every encoder path (#154): a PlayerID is a string and a
// [PlayerID: X] is an object keyed by the string, in standalone event frames (103) in every
// message encoding, in action responses, in events merged into state updates (107, through
// SnapshotValue), and inbound a client payload decodes only that shape.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeMessagePack

@Payload
struct IdentifierProbeEvent: ServerEventPayload {
    let playerID: PlayerID
    let owners: [PlayerID]
    let byPlayer: [PlayerID: Int]
}

@Payload
struct IdentifierProbeClientEvent: ClientEventPayload {
    let target: PlayerID
    let byPlayer: [PlayerID: Int]
}

private let probe = IdentifierProbeEvent(playerID: PlayerID("p1"), owners: [PlayerID("p2")], byPlayer: [PlayerID("p3"): 1])

/// Every dictionary key anywhere in `value`.
private func allKeys(_ value: Any) -> Set<String> {
    if let dict = value as? [String: Any] {
        return dict.reduce(into: Set(dict.keys)) { $0.formUnion(allKeys($1.value)) }
    }
    if let array = value as? [Any] {
        return array.reduce(into: Set<String>()) { $0.formUnion(allKeys($1)) }
    }
    return []
}

/// Whether `value` contains `needle` (a string leaf) or a dictionary equal to `object` anywhere.
private func contains(_ value: Any, string needle: String) -> Bool {
    if let string = value as? String { return string == needle }
    if let dict = value as? [String: Any] { return dict.values.contains { contains($0, string: needle) } }
    if let array = value as? [Any] { return array.contains { contains($0, string: needle) } }
    return false
}

private func contains(_ value: Any, object: [String: Int]) -> Bool {
    if let dict = value as? [String: Any] {
        if dict.count == object.count, object.allSatisfy({ (dict[$0.key] as? Int) == $0.value }) { return true }
        return dict.values.contains { contains($0, object: object) }
    }
    if let array = value as? [Any] { return array.contains { contains($0, object: object) } }
    return false
}

/// The identifier shape #154 requires, in a decoded frame.
private func expectStringIdentifiers(_ decoded: Any, _ path: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(!allKeys(decoded).contains("rawValue"), "\(path): no {rawValue} object", sourceLocation: sourceLocation)
    #expect(contains(decoded, string: "p1"), "\(path): playerID as a string", sourceLocation: sourceLocation)
    #expect(contains(decoded, string: "p2"), "\(path): [PlayerID] elements as strings", sourceLocation: sourceLocation)
    #expect(contains(decoded, object: ["p3": 1]), "\(path): [PlayerID: Int] as an object keyed by the string", sourceLocation: sourceLocation)
}

private func json(_ data: Data) throws -> Any {
    try JSONSerialization.jsonObject(with: data)
}

private func messagePackAny(_ value: MessagePackValue) -> Any {
    switch value {
    case .nil: return NSNull()
    case .bool(let b): return b
    case .int(let i): return Int(i)
    case .uint(let u): return Int(u)
    case .float(let f): return Double(f)
    case .double(let d): return d
    case .string(let s): return s
    case .binary(let d): return d
    case .array(let a): return a.map(messagePackAny)
    case .map(let m):
        var dict: [String: Any] = [:]
        for (k, v) in m {
            if case .string(let key) = k { dict[key] = messagePackAny(v) }
        }
        return dict
    case .extended: return NSNull()
    }
}

@Suite("Identifier shape on every encoder path (#154)")
struct IdentifierEncoderPathTests {

    @Test("Standalone event frames (103) in json, opcodeJsonArray and messagepack")
    func eventFrames() throws {
        let message = TransportMessage.event(event: .fromServer(event: AnyServerEvent(probe)))
        expectStringIdentifiers(try json(JSONTransportMessageEncoder().encode(message)), "json")
        for compression in [false, true] {
            let opcode = try OpcodeTransportMessageEncoder(enablePayloadCompression: compression).encode(message)
            expectStringIdentifiers(try json(opcode), "opcodeJsonArray compression=\(compression)")
            let packed = try MessagePackTransportMessageEncoder(enablePayloadCompression: compression).encode(message)
            expectStringIdentifiers(messagePackAny(try unpack(packed)), "messagepack compression=\(compression)")
        }
    }

    @Test("Action responses in json, opcodeJsonArray and messagepack")
    func actionResponses() throws {
        let message = TransportMessage(
            kind: .actionResponse,
            payload: .actionResponse(TransportActionResponsePayload(requestID: "r1", response: AnyCodable(probe)))
        )
        expectStringIdentifiers(try json(JSONTransportMessageEncoder().encode(message)), "json")
        expectStringIdentifiers(try json(OpcodeTransportMessageEncoder().encode(message)), "opcodeJsonArray")
        expectStringIdentifiers(messagePackAny(try unpack(MessagePackTransportMessageEncoder().encode(message))), "messagepack")
    }

    @Test("Events merged into state updates (107) go through SnapshotValue: the same shape")
    func mergedEvents() throws {
        let snapshot = try SnapshotValue.make(from: AnyServerEvent(probe).payload.base)
        expectStringIdentifiers(try json(JSONEncoder().encode(snapshot)), "SnapshotValue")
    }

    @Test("Inbound client payloads decode the string shape and reject the {rawValue} shape")
    func inboundPayloads() throws {
        let decoder = OpcodeTransportMessageDecoder()
        func clientEvent(_ payload: String) throws -> IdentifierProbeClientEvent {
            let message = try decoder.decode(from: Data(#"[103, 0, "IdentifierProbeClient", \#(payload)]"#.utf8))
            guard case .event(.fromClient(let event)) = message.payload else {
                throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not a client event"))
            }
            return try JSONDecoder().decode(IdentifierProbeClientEvent.self, from: JSONEncoder().encode(event.payload))
        }
        let decoded = try clientEvent(#"{"target":"p9","byPlayer":{"p3":1}}"#)
        #expect(decoded.target == PlayerID("p9"))
        #expect(decoded.byPlayer == [PlayerID("p3"): 1])
        #expect(throws: DecodingError.self) { try clientEvent(#"{"target":{"rawValue":"p9"},"byPlayer":{}}"#) }
        #expect(throws: DecodingError.self) { try clientEvent(#"{"target":"p9","byPlayer":[{"rawValue":"p3"},1]}"#) }
    }
}
