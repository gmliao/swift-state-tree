// Tests/SwiftStateTreeTransportTests/StateUpdateEncoderTests.swift
//
// Tests for state update encoders.

import Foundation
import Testing
import SwiftStateTree
import SwiftStateTreeTransport

// MARK: - JSONStateUpdateEncoder Tests

@Test("JSONStateUpdateEncoder encodes diff payload as JSON object")
func testJSONStateUpdateEncoderDiff() throws {
    let encoder = JSONStateUpdateEncoder()
    let update = StateUpdate.diff([
        StatePatch(path: "/hp", operation: .set(.int(10)))
    ])

    let data = try encoder.encode(update: update, landID: "land-1", playerID: PlayerID("player-1"))
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(StateUpdate.self, from: data)

    if case .diff(let patches) = decoded {
        #expect(patches.count == 1)
        #expect(patches[0].path == "/hp")
        if case .set(let value) = patches[0].operation {
            #expect(value == .int(10))
        } else {
            Issue.record("Expected .set operation")
        }
    } else {
        Issue.record("Expected .diff case")
    }
}

@Test("JSONStateUpdateEncoder encodes noChange payload as JSON object")
func testJSONStateUpdateEncoderNoChange() throws {
    let encoder = JSONStateUpdateEncoder()
    let update = StateUpdate.noChange

    let data = try encoder.encode(update: update, landID: "land-1", playerID: PlayerID("player-1"))
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(StateUpdate.self, from: data)

    #expect(decoded == .noChange)
}

@Test("JSONStateUpdateEncoder encodes firstSync payload as JSON object")
func testJSONStateUpdateEncoderFirstSync() throws {
    let encoder = JSONStateUpdateEncoder()
    let update = StateUpdate.firstSync([
        StatePatch(path: "/items", operation: .add(.string("sword"))),
        StatePatch(path: "/buffs", operation: .delete)
    ])

    let data = try encoder.encode(update: update, landID: "land-1", playerID: PlayerID("player-1"))
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(StateUpdate.self, from: data)

    if case .firstSync(let patches) = decoded {
        #expect(patches.count == 2)
        #expect(patches[0].path == "/items")
        #expect(patches[1].path == "/buffs")
    } else {
        Issue.record("Expected .firstSync case")
    }
}

@Test("JSONStateUpdateDecoder decodes diff payload")
func testJSONStateUpdateDecoderDiff() throws {
    let decoder = JSONStateUpdateDecoder()
    let update = StateUpdate.diff([
        StatePatch(path: "/hp", operation: .set(.int(10)))
    ])
    
    let encoder = JSONEncoder()
    let data = try encoder.encode(update)
    let decoded = try decoder.decode(data: data)

    #expect(decoded.landID == nil)
    #expect(decoded.playerID == nil)
    if case .diff(let patches) = decoded.update {
        #expect(patches.count == 1)
        #expect(patches[0].path == "/hp")
    } else {
        Issue.record("Expected .diff case")
    }
}

@Test("JSONStateUpdateDecoder decodes firstSync payload")
func testJSONStateUpdateDecoderFirstSync() throws {
    let decoder = JSONStateUpdateDecoder()
    let update = StateUpdate.firstSync([
        StatePatch(path: "/items", operation: .add(.string("sword"))),
        StatePatch(path: "/buffs", operation: .delete)
    ])
    
    let encoder = JSONEncoder()
    let data = try encoder.encode(update)
    let decoded = try decoder.decode(data: data)

    if case .firstSync(let patches) = decoded.update {
        #expect(patches.count == 2)
        #expect(patches[0].path == "/items")
        #expect(patches[1].path == "/buffs")
    } else {
        Issue.record("Expected .firstSync case")
    }
}

@Test("JSONStateUpdateDecoder decodes noChange payload")
func testJSONStateUpdateDecoderNoChange() throws {
    let decoder = JSONStateUpdateDecoder()
    let update = StateUpdate.noChange
    
    let encoder = JSONEncoder()
    let data = try encoder.encode(update)
    let decoded = try decoder.decode(data: data)

    #expect(decoded.update == .noChange)
}

@Test("JSONStateUpdateEncoder encodes nested object payload")
func testJSONStateUpdateEncoderNestedObject() throws {
    let encoder = JSONStateUpdateEncoder()
    let update = StateUpdate.diff([
        StatePatch(
            path: "/player",
            operation: .set(.object([
                "name": .string("Alice"),
                "hp": .int(100),
                "inventory": .array([.string("sword"), .string("potion")])
            ]))
        )
    ])

    let data = try encoder.encode(update: update, landID: "land-1", playerID: PlayerID("player-1"))
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(StateUpdate.self, from: data)

    if case .diff(let patches) = decoded {
        #expect(patches.count == 1)
        #expect(patches[0].path == "/player")
        if case .set(let value) = patches[0].operation {
            if case .object(let obj) = value {
                #expect(obj["name"] == .string("Alice"))
                #expect(obj["hp"] == .int(100))
                if case .array(let arr) = obj["inventory"] {
                    #expect(arr.count == 2)
                    #expect(arr[0] == .string("sword"))
                    #expect(arr[1] == .string("potion"))
                } else {
                    Issue.record("Expected inventory to be an array")
                }
            } else {
                Issue.record("Expected .object value")
            }
        } else {
            Issue.record("Expected .set operation")
        }
    } else {
        Issue.record("Expected .diff case")
    }
}

@Test("JSONStateUpdateDecoder decodes nested object payload")
func testJSONStateUpdateDecoderNestedObject() throws {
    let decoder = JSONStateUpdateDecoder()
    let update = StateUpdate.diff([
        StatePatch(
            path: "/player",
            operation: .set(.object([
                "name": .string("Bob"),
                "level": .int(5),
                "stats": .object([
                    "str": .int(10),
                    "dex": .int(8)
                ])
            ]))
        )
    ])
    
    let encoder = JSONEncoder()
    let data = try encoder.encode(update)
    let decoded = try decoder.decode(data: data)

    if case .diff(let patches) = decoded.update {
        #expect(patches.count == 1)
        #expect(patches[0].path == "/player")
        if case .set(let value) = patches[0].operation {
            if case .object(let obj) = value {
                #expect(obj["name"] == .string("Bob"))
                #expect(obj["level"] == .int(5))
                if case .object(let stats) = obj["stats"] {
                    #expect(stats["str"] == .int(10))
                    #expect(stats["dex"] == .int(8))
                } else {
                    Issue.record("Expected stats to be an object")
                }
            } else {
                Issue.record("Expected .object value")
            }
        } else {
            Issue.record("Expected .set operation")
        }
    } else {
        Issue.record("Expected .diff case")
    }
}

// MARK: - OpcodeJSONStateUpdateEncoder Tests

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

@Test("OpcodeJSONStateUpdateEncoder encodes nested object payload")
func testOpcodeStateUpdateEncoderNestedObject() throws {
    let encoder = OpcodeJSONStateUpdateEncoder()
    let update = StateUpdate.diff([
        StatePatch(
            path: "/player",
            operation: .set(.object([
                "name": .string("Alice"),
                "hp": .int(100),
                "inventory": .array([.string("sword"), .string("potion")])
            ]))
        )
    ])

    let data = try encoder.encode(update: update, landID: "land-1", playerID: PlayerID("player-1"))
    let json = try JSONSerialization.jsonObject(with: data) as? [Any]

    #expect((json?[0] as? Int) == StateUpdateOpcode.diff.rawValue)
    #expect((json?[1] as? String) == "player-1")

    let patch = json?[2] as? [Any]
    #expect((patch?[0] as? String) == "/player")
    #expect((patch?[1] as? Int) == StatePatchOpcode.set.rawValue)
    
    // Verify nested object structure
    if let valueObj = patch?[2] as? [String: Any] {
        #expect((valueObj["name"] as? String) == "Alice")
        #expect((valueObj["hp"] as? Int) == 100)
        if let inventoryArr = valueObj["inventory"] as? [String] {
            #expect(inventoryArr.count == 2)
            #expect(inventoryArr[0] == "sword")
            #expect(inventoryArr[1] == "potion")
        } else {
            Issue.record("Expected inventory to be an array")
        }
    } else {
        Issue.record("Expected nested object value")
    }
}

@Test("OpcodeJSONStateUpdateDecoder decodes nested object payload")
func testOpcodeStateUpdateDecoderNestedObject() throws {
    let decoder = OpcodeJSONStateUpdateDecoder()
    let payload: [Any] = [
        StateUpdateOpcode.diff.rawValue,
        "player-1",
        [
            "/player",
            StatePatchOpcode.set.rawValue,
            [
                "name": "Bob",
                "level": 5,
                "stats": [
                    "str": 10,
                    "dex": 8
                ]
            ] as [String: Any]
        ]
    ]

    let data = try JSONSerialization.data(withJSONObject: payload)
    let decoded = try decoder.decode(data: data)

    #expect(decoded.landID == nil)
    #expect(decoded.playerID == PlayerID("player-1"))
    if case .diff(let patches) = decoded.update {
        #expect(patches.count == 1)
        #expect(patches[0].path == "/player")
        if case .set(let value) = patches[0].operation {
            if case .object(let obj) = value {
                #expect(obj["name"] == .string("Bob"))
                #expect(obj["level"] == .int(5))
                if case .object(let stats) = obj["stats"] {
                    #expect(stats["str"] == .int(10))
                    #expect(stats["dex"] == .int(8))
                } else {
                    Issue.record("Expected stats to be an object")
                }
            } else {
                Issue.record("Expected .object value")
            }
        } else {
            Issue.record("Expected .set operation")
        }
    } else {
        Issue.record("Expected .diff case")
    }
}
