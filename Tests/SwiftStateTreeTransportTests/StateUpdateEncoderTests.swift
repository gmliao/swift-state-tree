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
    // removed header slot check

    let patch = json?[1] as? [Any]
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
    // removed header slot check
    #expect(json?.count == 1)
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
    // removed header slot check

    let addPatch = json?[1] as? [Any]
    #expect((addPatch?[0] as? String) == "/items")
    #expect((addPatch?[1] as? Int) == StatePatchOpcode.add.rawValue)
    #expect((addPatch?[2] as? String) == "sword")

    let removePatch = json?[2] as? [Any]
    #expect((removePatch?[0] as? String) == "/buffs")
    #expect((removePatch?[1] as? Int) == StatePatchOpcode.remove.rawValue)
}

@Test("OpcodeJSONStateUpdateDecoder decodes diff payload and metadata")
func testOpcodeStateUpdateDecoderDiff() throws {
    let decoder = OpcodeJSONStateUpdateDecoder()
    let payload: [Any] = [
        StateUpdateOpcode.diff.rawValue,
        ["/hp", StatePatchOpcode.set.rawValue, 10]
    ]

    let data = try JSONSerialization.data(withJSONObject: payload)
    let decoded = try decoder.decode(data: data)

    #expect(decoded.landID == nil)
    #expect(decoded.update == .diff([StatePatch(path: "/hp", operation: .set(.int(10)))]))
}

@Test("OpcodeJSONStateUpdateDecoder decodes firstSync with add and remove patches")
func testOpcodeStateUpdateDecoderFirstSync() throws {
    let decoder = OpcodeJSONStateUpdateDecoder()
    let payload: [Any] = [
        StateUpdateOpcode.firstSync.rawValue,
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
        StateUpdateOpcode.noChange.rawValue
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
    // removed header slot check

    let patch = json?[1] as? [Any]
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

@Test("OpcodeJSONStateUpdateEncoder compresses dynamic keys with define-on-first-use and force-definition")
func testOpcodeStateUpdateEncoderDynamicKeyCompression() throws {
    // 1. Setup PathHasher with a wildcard pattern
    let hasher = PathHasher(pathHashes: ["players.*": 12345])
    let encoder = OpcodeJSONStateUpdateEncoder(pathHasher: hasher)
    
    // 2. Encode FIRST usage of dynamic key "uuid-1" (as part of firstSync)
    // This should Define the key: [Slot, "uuid-1"]
    let update1 = StateUpdate.firstSync([
        StatePatch(path: "/players/uuid-1", operation: .set(.int(100)))
    ])
    
    let data1 = try encoder.encode(update: update1, landID: "land-1", playerID: PlayerID("p1"))
    let json1 = try JSONSerialization.jsonObject(with: data1) as? [Any]
    
    // Validate Structure: [Op, Patch...]
    // Patch: [Hash, DynamicKey, Op, Val]
    let patch1 = json1?[1] as? [Any]
    #expect((patch1?[0] as? UInt32) == 12345) // Hash
    
    // Dynamic Key Definition: [Slot, "uuid-1"]
    let dynamicKeyDef = patch1?[1] as? [Any]
    #expect(dynamicKeyDef?.count == 2)
    let slot = dynamicKeyDef?[0] as? Int
    #expect(slot != nil)
    #expect((dynamicKeyDef?[1] as? String) == "uuid-1")
    
    // 3. Encode SAME key "uuid-1" in a normal diff
    // This should use the SLOT: Slot
    let update2 = StateUpdate.diff([
        StatePatch(path: "/players/uuid-1", operation: .set(.int(200)))
    ])
    
    let data2 = try encoder.encode(update: update2, landID: "land-1", playerID: PlayerID("p1"))
    let json2 = try JSONSerialization.jsonObject(with: data2) as? [Any]
    
    let patch2 = json2?[1] as? [Any]
    let dynamicKeyUsage = patch2?[1] as? Int
    #expect(dynamicKeyUsage == slot)


    // 4. Encode SAME key "uuid-1" in ANOTHER firstSync (simulating Late Join for another player)
    // This MUST trigger Force Definition: [Slot, "uuid-1"] 
    // Even though the key is known to the encoder, firstSync requires definitions.
    let update3 = StateUpdate.firstSync([
        StatePatch(path: "/players/uuid-1", operation: .set(.int(100)))
    ])
    
    let data3 = try encoder.encode(update: update3, landID: "land-1", playerID: PlayerID("p2")) // Different player
    let json3 = try JSONSerialization.jsonObject(with: data3) as? [Any]
    
    let patch3 = json3?[1] as? [Any]
    let dynamicKeyRedef = patch3?[1] as? [Any]
    #expect(dynamicKeyRedef?.count == 2)
    let slotRedef = dynamicKeyRedef?[0] as? Int
    #expect(slotRedef == slot) // Should be same slot ID
    #expect((dynamicKeyRedef?[1] as? String) == "uuid-1") // Should supply string again
}

@Test("OpcodeJSONStateUpdateEncoder defines dynamic keys per player on first diff")
func testOpcodeStateUpdateEncoderDynamicKeyPerPlayerDefinitionOnDiff() throws {
    let hasher = PathHasher(pathHashes: ["players.*": 12345])
    let encoder = OpcodeJSONStateUpdateEncoder(pathHasher: hasher)

    let update1 = StateUpdate.diff([
        StatePatch(path: "/players/uuid-1", operation: .set(.int(100)))
    ])

    let data1 = try encoder.encode(update: update1, landID: "land-1", playerID: PlayerID("p1"))
    let json1 = try JSONSerialization.jsonObject(with: data1) as? [Any]
    let patch1 = json1?[1] as? [Any]
    let dynamicKeyDef1 = patch1?[1] as? [Any]
    #expect(dynamicKeyDef1?.count == 2)
    let slot1 = dynamicKeyDef1?[0] as? Int
    #expect(slot1 != nil)
    #expect((dynamicKeyDef1?[1] as? String) == "uuid-1")

    let update2 = StateUpdate.diff([
        StatePatch(path: "/players/uuid-1", operation: .set(.int(200)))
    ])

    let data2 = try encoder.encode(update: update2, landID: "land-1", playerID: PlayerID("p2"))
    let json2 = try JSONSerialization.jsonObject(with: data2) as? [Any]
    let patch2 = json2?[1] as? [Any]
    let dynamicKeyDef2 = patch2?[1] as? [Any]
    #expect(dynamicKeyDef2?.count == 2)
    let slot2 = dynamicKeyDef2?[0] as? Int
    #expect(slot2 != nil)
    #expect(slot2 == slot1)
    #expect((dynamicKeyDef2?[1] as? String) == "uuid-1")
}

@Test("OpcodeJSONStateUpdateEncoder resets dynamic key table on firstSync for same player")
func testOpcodeStateUpdateEncoderDynamicKeyResetOnFirstSyncForSamePlayer() throws {
    let hasher = PathHasher(pathHashes: ["players.*": 12345])
    let encoder = OpcodeJSONStateUpdateEncoder(pathHasher: hasher)

    let update1 = StateUpdate.diff([
        StatePatch(path: "/players/uuid-1", operation: .set(.int(100)))
    ])

    let data1 = try encoder.encode(update: update1, landID: "land-1", playerID: PlayerID("p1"))
    let json1 = try JSONSerialization.jsonObject(with: data1) as? [Any]
    let patch1 = json1?[1] as? [Any]
    let dynamicKeyDef1 = patch1?[1] as? [Any]
    #expect(dynamicKeyDef1?.count == 2)
    let slot1 = dynamicKeyDef1?[0] as? Int
    #expect(slot1 != nil)

    let update2 = StateUpdate.firstSync([
        StatePatch(path: "/players/uuid-1", operation: .set(.int(200)))
    ])

    let data2 = try encoder.encode(update: update2, landID: "land-1", playerID: PlayerID("p1"))
    let json2 = try JSONSerialization.jsonObject(with: data2) as? [Any]
    let patch2 = json2?[1] as? [Any]
    let dynamicKeyDef2 = patch2?[1] as? [Any]
    #expect(dynamicKeyDef2?.count == 2)
    let slot2 = dynamicKeyDef2?[0] as? Int
    #expect(slot2 != nil)
    #expect((dynamicKeyDef2?[1] as? String) == "uuid-1")

    let update3 = StateUpdate.diff([
        StatePatch(path: "/players/uuid-1", operation: .set(.int(300)))
    ])

    let data3 = try encoder.encode(update: update3, landID: "land-1", playerID: PlayerID("p1"))
    let json3 = try JSONSerialization.jsonObject(with: data3) as? [Any]
    let patch3 = json3?[1] as? [Any]
    let dynamicKeyUsage3 = patch3?[1] as? Int
    #expect(dynamicKeyUsage3 == slot2)
    #expect(slot2 == slot1)
}

@Test("OpcodeJSONStateUpdateEncoder isolates dynamic key tables per land")
func testOpcodeStateUpdateEncoderDynamicKeyPerLandIsolation() throws {
    let hasher = PathHasher(pathHashes: ["players.*": 12345])
    let encoder = OpcodeJSONStateUpdateEncoder(pathHasher: hasher)

    let update1 = StateUpdate.diff([
        StatePatch(path: "/players/uuid-1", operation: .set(.int(100)))
    ])

    let data1 = try encoder.encode(update: update1, landID: "land-1", playerID: PlayerID("p1"))
    let json1 = try JSONSerialization.jsonObject(with: data1) as? [Any]
    let patch1 = json1?[1] as? [Any]
    let dynamicKeyDef1 = patch1?[1] as? [Any]
    #expect(dynamicKeyDef1?.count == 2)
    #expect((dynamicKeyDef1?[1] as? String) == "uuid-1")

    let update2 = StateUpdate.diff([
        StatePatch(path: "/players/uuid-1", operation: .set(.int(200)))
    ])

    let data2 = try encoder.encode(update: update2, landID: "land-2", playerID: PlayerID("p1"))
    let json2 = try JSONSerialization.jsonObject(with: data2) as? [Any]
    let patch2 = json2?[1] as? [Any]
    let dynamicKeyDef2 = patch2?[1] as? [Any]
    #expect(dynamicKeyDef2?.count == 2)
    #expect((dynamicKeyDef2?[1] as? String) == "uuid-1")
}

@Test("OpcodeJSONStateUpdateEncoder legacy format does not compress dynamic key paths")
func testOpcodeStateUpdateEncoderLegacyFormatDynamicKeyPath() throws {
    let encoder = OpcodeJSONStateUpdateEncoder()
    let update = StateUpdate.diff([
        StatePatch(path: "/players/uuid-1", operation: .set(.int(100)))
    ])

    let data = try encoder.encode(update: update, landID: "land-1", playerID: PlayerID("p1"))
    let json = try JSONSerialization.jsonObject(with: data) as? [Any]
    let patch = json?[1] as? [Any]
    #expect((patch?[0] as? String) == "/players/uuid-1")
    #expect((patch?[1] as? Int) == StatePatchOpcode.set.rawValue)
    #expect((patch?[2] as? Int) == 100)
}


