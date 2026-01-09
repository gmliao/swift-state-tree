// Tests/SwiftStateTreeTransportTests/StateUpdateEncoderTests.swift
//
// Tests for state update encoders.

import Foundation
import Testing
import SwiftStateTree
import SwiftStateTreeTransport

@Test("OpcodeJSONStateUpdateEncoder encodes diff payload as opcode array")
func testOpcodeStateUpdateEncoderDiff() throws {
    let encoder = OpcodeJSONStateUpdateEncoder()
    let update = StateUpdate.diff([
        StatePatch(path: "/hp", operation: .set(.int(10)))
    ])

    let data = try encoder.encode(update: update, landID: "land-1", playerID: PlayerID("player-1"))
    let json = try JSONSerialization.jsonObject(with: data) as? [Any]

    #expect((json?[0] as? Int) == StateUpdateOpcode.diff.rawValue)
    #expect((json?[1] as? String) == "player-1")

    let patch = json?[2] as? [Any]
    #expect((patch?[0] as? String) == "/hp")
    #expect((patch?[1] as? Int) == StatePatchOpcode.set.rawValue)
    #expect((patch?[2] as? Int) == 10)
}

@Test("OpcodeJSONStateUpdateEncoder encodes noChange payload as opcode array")
func testOpcodeStateUpdateEncoderNoChange() throws {
    let encoder = OpcodeJSONStateUpdateEncoder()
    let update = StateUpdate.noChange

    let data = try encoder.encode(update: update, landID: "land-1", playerID: PlayerID("player-1"))
    let json = try JSONSerialization.jsonObject(with: data) as? [Any]

    #expect((json?[0] as? Int) == StateUpdateOpcode.noChange.rawValue)
    #expect((json?[1] as? String) == "player-1")
    #expect(json?.count == 2)
}

@Test("OpcodeJSONStateUpdateEncoder encodes firstSync payload with patch opcodes")
func testOpcodeStateUpdateEncoderFirstSync() throws {
    let encoder = OpcodeJSONStateUpdateEncoder()
    let update = StateUpdate.firstSync([
        StatePatch(path: "/items", operation: .add(.string("sword"))),
        StatePatch(path: "/buffs", operation: .delete)
    ])

    let data = try encoder.encode(update: update, landID: "land-1", playerID: PlayerID("player-1"))
    let json = try JSONSerialization.jsonObject(with: data) as? [Any]

    #expect((json?[0] as? Int) == StateUpdateOpcode.firstSync.rawValue)
    #expect((json?[1] as? String) == "player-1")

    let addPatch = json?[2] as? [Any]
    #expect((addPatch?[0] as? String) == "/items")
    #expect((addPatch?[1] as? Int) == StatePatchOpcode.add.rawValue)
    #expect((addPatch?[2] as? String) == "sword")

    let removePatch = json?[3] as? [Any]
    #expect((removePatch?[0] as? String) == "/buffs")
    #expect((removePatch?[1] as? Int) == StatePatchOpcode.remove.rawValue)
}

@Test("OpcodeJSONStateUpdateDecoder decodes diff payload and metadata")
func testOpcodeStateUpdateDecoderDiff() throws {
    let decoder = OpcodeJSONStateUpdateDecoder()
    let payload: [Any] = [
        StateUpdateOpcode.diff.rawValue,
        "player-1",
        ["/hp", StatePatchOpcode.set.rawValue, 10]
    ]

    let data = try JSONSerialization.data(withJSONObject: payload)
    let decoded = try decoder.decode(data: data)

    #expect(decoded.landID == nil)
    #expect(decoded.playerID == PlayerID("player-1"))
    #expect(decoded.update == .diff([StatePatch(path: "/hp", operation: .set(.int(10)))]))
}

@Test("OpcodeJSONStateUpdateDecoder decodes firstSync with add and remove patches")
func testOpcodeStateUpdateDecoderFirstSync() throws {
    let decoder = OpcodeJSONStateUpdateDecoder()
    let payload: [Any] = [
        StateUpdateOpcode.firstSync.rawValue,
        "player-1",
        ["/items", StatePatchOpcode.add.rawValue, "sword"],
        ["/buffs", StatePatchOpcode.remove.rawValue]
    ]

    let data = try JSONSerialization.data(withJSONObject: payload)
    let decoded = try decoder.decode(data: data)

    #expect(decoded.update == .firstSync([
        StatePatch(path: "/items", operation: .add(.string("sword"))),
        StatePatch(path: "/buffs", operation: .delete)
    ]))
}

@Test("OpcodeJSONStateUpdateDecoder decodes noChange payload")
func testOpcodeStateUpdateDecoderNoChange() throws {
    let decoder = OpcodeJSONStateUpdateDecoder()
    let payload: [Any] = [
        StateUpdateOpcode.noChange.rawValue,
        "player-1"
    ]

    let data = try JSONSerialization.data(withJSONObject: payload)
    let decoded = try decoder.decode(data: data)

    #expect(decoded.update == .noChange)
}
