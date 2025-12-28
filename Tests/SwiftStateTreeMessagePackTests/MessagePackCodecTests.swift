import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeMessagePack

private func stringKeyedMap(_ value: MessagePackValue) -> [String: MessagePackValue]? {
    guard case let .map(values) = value else {
        return nil
    }
    var map: [String: MessagePackValue] = [:]
    for (key, value) in values {
        guard case let .string(keyString) = key else {
            return nil
        }
        map[keyString] = value
    }
    return map
}

@Test("MessagePack encodes ActionEnvelope payload as binary")
func testMessagePackBinaryPayload() throws {
    let serializer = MessagePackSerializer()
    let payloadData = Data([0x01, 0x02, 0x03])
    let envelope = ActionEnvelope(typeIdentifier: "DummyAction", payload: payloadData)
    let message = TransportMessage.action(requestID: "req-1", landID: "demo", action: envelope)

    let encoded = try serializer.encode(message)
    let root = try unpack(encoded)

    guard let rootMap = stringKeyedMap(root) else {
        Issue.record("Expected root map")
        return
    }
    guard let payloadValue = rootMap["payload"], let payloadMap = stringKeyedMap(payloadValue) else {
        Issue.record("Expected payload map")
        return
    }
    guard let actionValue = payloadMap["action"], let actionMap = stringKeyedMap(actionValue) else {
        Issue.record("Expected action payload map")
        return
    }
    guard let envelopeValue = actionMap["action"], let envelopeMap = stringKeyedMap(envelopeValue) else {
        Issue.record("Expected action envelope map")
        return
    }
    guard let payloadField = envelopeMap["payload"] else {
        Issue.record("Expected payload field")
        return
    }
    guard case let .binary(decodedPayload) = payloadField else {
        Issue.record("Expected binary payload")
        return
    }
    #expect(decodedPayload == payloadData)
}

@Test("MessagePack round-trips AnyCodable dictionaries with binary")
func testMessagePackAnyCodableRoundTrip() throws {
    let serializer = MessagePackSerializer()
    let bytes = Data([0x0a, 0x0b])
    let response: [String: Any] = [
        "count": 7,
        "flag": true,
        "bytes": bytes,
        "nested": ["name": "moss"]
    ]
    let message = TransportMessage.actionResponse(requestID: "req-2", response: AnyCodable(response))

    let encoded = try serializer.encode(message)
    let decoded = try serializer.decode(TransportMessage.self, from: encoded)

    guard case .actionResponse(let payload) = decoded.payload else {
        Issue.record("Expected actionResponse payload")
        return
    }
    guard let dict = payload.response.base as? [String: Any] else {
        Issue.record("Expected AnyCodable dictionary")
        return
    }
    #expect(dict["count"] as? Int == 7)
    #expect(dict["flag"] as? Bool == true)
    guard let decodedBytes = dict["bytes"] as? Data else {
        Issue.record("Expected binary bytes")
        return
    }
    #expect(decodedBytes == bytes)
    guard let nested = dict["nested"] as? [String: Any] else {
        Issue.record("Expected nested dictionary")
        return
    }
    #expect(nested["name"] as? String == "moss")
}
