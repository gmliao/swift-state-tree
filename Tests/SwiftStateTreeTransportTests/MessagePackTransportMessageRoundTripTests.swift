// Tests/SwiftStateTreeTransportTests/MessagePackTransportMessageRoundTripTests.swift
//
// Every TransportMessage payload, with every field set, survives each wire form: the
// MessagePack map form ({kind, payload}) through MessagePackTransportCodec, and the opcode array
// serialized as MessagePack (decoded by MessagePackTransportCodec) and as JSON (decoded by
// OpcodeTransportMessageDecoder). The opcode array leaves out the fields in
// `notCarriedByOpcodeArray`, and only those.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
@testable import SwiftStateTreeMessagePack

/// Every message kind. `fixtures(for:)` switches over the kind exhaustively, so a new kind
/// does not compile until it has a fixture; add it here too.
private let allKinds: [MessageKind] = [.action, .actionResponse, .event, .join, .joinResponse, .error]

private let anyPayload = AnyCodable(["value": 7, "name": "x", "tags": ["a", "b"]] as [String: Any])

/// One message per payload shape, with every optional field set.
private func fixtures(for kind: MessageKind) -> [TransportMessage] {
    switch kind {
    case .action:
        return [TransportMessage.action(
            requestID: "req-1",
            action: ActionEnvelope(typeIdentifier: "MoveAction", payload: anyPayload)
        )]
    case .actionResponse:
        return [TransportMessage.actionResponse(requestID: "req-2", response: anyPayload)]
    case .event:
        return [
            TransportMessage(kind: .event, payload: .event(.fromClient(event: AnyClientEvent(
                type: "Chat", payload: anyPayload, rawBody: Data([1, 2, 3])
            )))),
            TransportMessage(kind: .event, payload: .event(.fromServer(event: AnyServerEvent(
                type: "Tick", payload: anyPayload, rawBody: Data([4, 5])
            )))),
        ]
    case .join:
        return [TransportMessage(kind: .join, payload: .join(TransportJoinPayload(
            requestID: "req-3",
            landType: "game",
            landInstanceId: "room-1",
            playerID: "p1",
            deviceID: "d1",
            metadata: ["stateUpdateFeatures": AnyCodable(["pathIndex"])]
        )))]
    case .joinResponse:
        return [TransportMessage(kind: .joinResponse, payload: .joinResponse(TransportJoinResponsePayload(
            requestID: "req-4",
            success: true,
            landType: "game",
            landInstanceId: "room-1",
            landID: "game:room-1",
            playerID: "p1",
            playerSlot: 3,
            encoding: "messagepack",
            reason: "ok",
            stateUpdateFeatures: ["pathIndex", "fieldMerge"]
        )))]
    case .error:
        return [TransportMessage(kind: .error, payload: .error(ErrorPayload(
            code: "E_TEST", message: "boom", details: ["field": AnyCodable("x")]
        )))]
    }
}

/// The payload structs a fixture carries, so a field added without a fixture value is caught.
private func payloadStructs(_ message: TransportMessage) -> [Any] {
    switch message.payload {
    case .action(let payload): return [payload, payload.action]
    case .actionResponse(let payload): return [payload]
    case .event(.fromClient(let event)): return [event]
    case .event(.fromServer(let event)): return [event]
    case .join(let payload): return [payload]
    case .joinResponse(let payload): return [payload]
    case .error(let payload): return [payload]
    }
}

private func nilFieldNames(_ value: Any) -> [String] {
    Mirror(reflecting: value).children.compactMap { child in
        let mirror = Mirror(reflecting: child.value)
        guard mirror.displayStyle == .optional, mirror.children.isEmpty else { return nil }
        // `AnyServerEvent.wireForm` is the typed value an encoder may use, not a wire field (#521).
        guard child.label != "wireForm" else { return nil }
        return child.label ?? "?"
    }
}

/// Canonical JSON of a message: equal JSON means equal fields, including AnyCodable values.
private func canonicalJSON(_ message: TransportMessage) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return String(decoding: try encoder.encode(message), as: UTF8.self)
}

@Test("Every fixture sets every field of its payload")
func testRoundTripFixturesAreComplete() {
    for kind in allKinds {
        let messages = fixtures(for: kind)
        #expect(!messages.isEmpty, "no fixture for \(kind)")
        for message in messages {
            #expect(message.kind == kind)
            for payload in payloadStructs(message) {
                let missing = nilFieldNames(payload)
                #expect(missing.isEmpty, "\(kind) fixture leaves \(type(of: payload)) fields nil: \(missing)")
            }
        }
    }
}

@Test("The MessagePack map form round-trips every TransportMessage field")
func testMessagePackMapFormRoundTripsEveryField() throws {
    let codec = MessagePackTransportCodec()
    for kind in allKinds {
        for message in fixtures(for: kind) {
            let encoded = try codec.encode(message)
            guard case .map = try unpack(encoded) else {
                Issue.record("\(kind): expected the map form")
                continue
            }
            let decoded = try codec.decode(TransportMessage.self, from: encoded)
            #expect(try canonicalJSON(decoded) == canonicalJSON(message), "\(kind) map form lost or changed a field")
        }
    }
}

@Test("A MessagePack opcode-array joinResponse decodes every field the array carries")
func testMessagePackOpcodeJoinResponseKeepsStateUpdateFeatures() throws {
    guard case .joinResponse(let sent) = fixtures(for: .joinResponse)[0].payload else {
        Issue.record("Expected a joinResponse fixture")
        return
    }
    let encoded = try MessagePackTransportMessageEncoder().encode(fixtures(for: .joinResponse)[0])
    guard case .array = try unpack(encoded) else {
        Issue.record("Expected the opcode array form")
        return
    }
    let decoded = try MessagePackTransportCodec().decode(TransportMessage.self, from: encoded)
    guard case .joinResponse(let received) = decoded.payload else {
        Issue.record("Expected a joinResponse payload")
        return
    }
    // The array carries no playerID; landID is rebuilt from landType and landInstanceId.
    #expect(received.requestID == sent.requestID)
    #expect(received.success == sent.success)
    #expect(received.landType == sent.landType)
    #expect(received.landInstanceId == sent.landInstanceId)
    #expect(received.landID == sent.landID)
    #expect(received.playerSlot == sent.playerSlot)
    #expect(received.encoding == sent.encoding)
    #expect(received.reason == sent.reason)
    #expect(received.stateUpdateFeatures == sent.stateUpdateFeatures)
}

/// The fields the opcode array leaves out on purpose, by kind: joinResponse has no `playerID`
/// slot (`landID` is rebuilt from `landType` and `landInstanceId`, so it round-trips).
private let notCarriedByOpcodeArray: [MessageKind: [String]] = [.joinResponse: ["playerID"]]

/// `canonicalJSON(message)` without the fields the opcode array leaves out.
private func canonicalJSONCarriedByOpcodeArray(_ message: TransportMessage) throws -> String {
    var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(message)) as? [String: Any])
    if let fields = notCarriedByOpcodeArray[message.kind] {
        var payload = try #require(object["payload"] as? [String: Any])
        var body = try #require(payload[message.kind.rawValue] as? [String: Any])
        for field in fields {
            #expect(body.removeValue(forKey: field) != nil, "\(message.kind).\(field) is set in the fixture")
        }
        payload[message.kind.rawValue] = body
        object["payload"] = payload
    }
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

private func canonicalJSONReencoded(_ message: TransportMessage) throws -> String {
    let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(message))
    return String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
}

@Test("The opcode array, as MessagePack and as JSON, round-trips every field it carries")
func testOpcodeArrayRoundTripsEveryCarriedField() throws {
    let messagepackEncoder = MessagePackTransportMessageEncoder()
    let jsonEncoder = OpcodeTransportMessageEncoder()
    let codec = MessagePackTransportCodec()
    let jsonDecoder = OpcodeTransportMessageDecoder()
    for kind in allKinds {
        for message in fixtures(for: kind) {
            let expected = try canonicalJSONCarriedByOpcodeArray(message)

            let packed = try messagepackEncoder.encode(message)
            guard case .array = try unpack(packed) else {
                Issue.record("\(kind): expected the opcode array")
                continue
            }
            let fromMessagePack = try codec.decode(TransportMessage.self, from: packed)
            #expect(try canonicalJSONReencoded(fromMessagePack) == expected, "\(kind) MessagePack opcode array lost or changed a field")

            let text = try jsonEncoder.encode(message)
            let fromJSON = try jsonDecoder.decode(from: text)
            #expect(try canonicalJSONReencoded(fromJSON) == expected, "\(kind) JSON opcode array lost or changed a field")
        }
    }
}
