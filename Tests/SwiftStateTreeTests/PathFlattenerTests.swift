import Testing
import Foundation
@testable import SwiftStateTree

/// Test PathFlattener with various nested structures.
@Suite("PathFlattener Tests")
struct PathFlattenerTests {
    
    @Test("Simple flat structure")
    func testSimpleFlatStructure() {
        // GameState { round: Int, score: Int }
        let definitions: [String: JSONSchema] = [
            "GameState": JSONSchema(
                type: .object,
                properties: [
                    "round": JSONSchema(type: .integer),
                    "score": JSONSchema(type: .integer)
                ],
                required: ["round", "score"]
            )
        ]
        
        let paths = PathFlattener.flatten(rootTypeName: "GameState", definitions: definitions)
        
        #expect(paths.keys.contains("round"))
        #expect(paths.keys.contains("score"))
        #expect(paths.count == 2)
    }
    
    @Test("Map with wildcard")
    func testMapWithWildcard() {
        // GameState { players: [Int32: PlayerData] }
        // PlayerData { hp: Int }
        let definitions: [String: JSONSchema] = [
            "GameState": JSONSchema(
                type: .object,
                properties: [
                    "players": JSONSchema(ref: "#/defs/PlayersMap")
                ],
                required: ["players"]
            ),
            "PlayersMap": JSONSchema(
                type: .object,
                additionalProperties: JSONSchema(ref: "#/defs/PlayerData"),
                xStateTree: StateTreeMetadata(nodeKind: .map)
            ),
            "PlayerData": JSONSchema(
                type: .object,
                properties: [
                    "hp": JSONSchema(type: .integer)
                ],
                required: ["hp"]
            )
        ]
        
        let paths = PathFlattener.flatten(rootTypeName: "GameState", definitions: definitions)
        
        #expect(paths.keys.contains("players"))
        #expect(paths.keys.contains("players.*"))
        #expect(paths.keys.contains("players.*.hp"))
        #expect(paths.count == 3)
    }
    
    @Test("Nested maps (深層巢狀)")
    func testNestedMaps() {
        // GameState {
        //   guilds: [String: Guild]
        // }
        // Guild {
        //   members: [Int32: Member]
        // }
        // Member {
        //   name: String,
        //   level: Int
        // }
        let definitions: [String: JSONSchema] = [
            "GameState": JSONSchema(
                type: .object,
                properties: [
                    "guilds": JSONSchema(
                        type: .object,
                        additionalProperties: JSONSchema(ref: "#/defs/Guild"),
                        xStateTree: StateTreeMetadata(nodeKind: .map)
                    )
                ]
            ),
            "Guild": JSONSchema(
                type: .object,
                properties: [
                    "members": JSONSchema(
                        type: .object,
                        additionalProperties: JSONSchema(ref: "#/defs/Member"),
                        xStateTree: StateTreeMetadata(nodeKind: .map)
                    )
                ]
            ),
            "Member": JSONSchema(
                type: .object,
                properties: [
                    "name": JSONSchema(type: .string),
                    "level": JSONSchema(type: .integer)
                ]
            )
        ]
        
        let paths = PathFlattener.flatten(rootTypeName: "GameState", definitions: definitions)
        
        // Expected paths:
        // guilds
        // guilds.*
        // guilds.*.members
        // guilds.*.members.*
        // guilds.*.members.*.name
        // guilds.*.members.*.level
        
        #expect(paths.keys.contains("guilds"))
        #expect(paths.keys.contains("guilds.*"))
        #expect(paths.keys.contains("guilds.*.members"))
        #expect(paths.keys.contains("guilds.*.members.*"))
        #expect(paths.keys.contains("guilds.*.members.*.name"))
        #expect(paths.keys.contains("guilds.*.members.*.level"))
        #expect(paths.count == 6)
    }
    
    @Test("Mixed nested structure with arrays and maps")
    func testMixedNestedStructure() {
        // GameState {
        //   players: [Int32: Player]
        // }
        // Player {
        //   inventory: [Item],
        //   position: IVec2
        // }
        // Item {
        //   id: String,
        //   count: Int
        // }
        // IVec2 {
        //   x: Int,
        //   y: Int
        // }
        let definitions: [String: JSONSchema] = [
            "GameState": JSONSchema(
                type: .object,
                properties: [
                    "players": JSONSchema(
                        type: .object,
                        additionalProperties: JSONSchema(ref: "#/defs/Player"),
                        xStateTree: StateTreeMetadata(nodeKind: .map)
                    )
                ]
            ),
            "Player": JSONSchema(
                type: .object,
                properties: [
                    "inventory": JSONSchema(
                        type: .array,
                        items: JSONSchema(ref: "#/defs/Item"),
                        xStateTree: StateTreeMetadata(nodeKind: .array)
                    ),
                    "position": JSONSchema(ref: "#/defs/IVec2")
                ]
            ),
            "Item": JSONSchema(
                type: .object,
                properties: [
                    "id": JSONSchema(type: .string),
                    "count": JSONSchema(type: .integer)
                ]
            ),
            "IVec2": JSONSchema(
                type: .object,
                properties: [
                    "x": JSONSchema(type: .integer),
                    "y": JSONSchema(type: .integer)
                ],
                xStateTree: StateTreeMetadata(nodeKind: .object, atomic: true)
            )
        ]
        
        let paths = PathFlattener.flatten(rootTypeName: "GameState", definitions: definitions)
        
        // Expected paths include:
        #expect(paths.keys.contains("players"))
        #expect(paths.keys.contains("players.*"))
        #expect(paths.keys.contains("players.*.inventory"))
        #expect(paths.keys.contains("players.*.inventory.*"))
        #expect(paths.keys.contains("players.*.inventory.*.id"))
        #expect(paths.keys.contains("players.*.inventory.*.count"))
        #expect(paths.keys.contains("players.*.position"))
        #expect(paths.keys.contains("players.*.position.x"))
        #expect(paths.keys.contains("players.*.position.y"))
        
        // Total: 9 paths
        #expect(paths.count == 9)
    }
    
    @Test("Hash collision detection")
    func testHashCollisionDetection() {
        // Create a schema with many paths to test for collisions
        let definitions: [String: JSONSchema] = [
            "GameState": JSONSchema(
                type: .object,
                properties: [
                    "field1": JSONSchema(type: .integer),
                    "field2": JSONSchema(type: .integer),
                    "field3": JSONSchema(type: .integer),
                    "players": JSONSchema(
                        type: .object,
                        additionalProperties: JSONSchema(
                            type: .object,
                            properties: [
                                "hp": JSONSchema(type: .integer),
                                "mana": JSONSchema(type: .integer),
                                "level": JSONSchema(type: .integer)
                            ]
                        ),
                        xStateTree: StateTreeMetadata(nodeKind: .map)
                    )
                ]
            )
        ]
        
        let paths = PathFlattener.flatten(rootTypeName: "GameState", definitions: definitions)
        
        // Check that all hashes are unique
        let hashes = Array(paths.values)
        let uniqueHashes = Set(hashes)
        
        #expect(hashes.count == uniqueHashes.count, "Hash collision detected!")
        
        // Print paths and hashes for inspection
        for (path, hash) in paths.sorted(by: { $0.key < $1.key }) {
            print("\(path) -> 0x\(String(hash, radix: 16))")
        }
    }
}
