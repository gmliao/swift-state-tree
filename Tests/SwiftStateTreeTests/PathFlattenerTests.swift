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
    }

    /// #287: an optional's patterns are its inner type's, as for the value it holds; an optional
    /// atomic value (`Position2?`) is one value on the wire, so it stays a leaf.
    @Test("Patterns below an optional follow its inner type, except into an atomic type")
    func optionalsFollowTheirInnerType() throws {
        let schema = try ShapeMatrixRoundTripTests.schema()
        let hashes = try #require(schema.lands[ShapeMatrixRoundTripTests.landType]?.pathHashes)
        for pattern in ["holder", "holder.tag", "holder.inner", "holder.inner.at", "holder.inner.heading",
                        "maybePoints", "maybePoints.*", "maybeByKey", "maybeByKey.*"] {
            #expect(hashes[pattern] == DeterministicHash.fnv1a32(pattern), "\(pattern)")
        }
        // An optional atomic adds nothing below it.
        for pattern in hashes.keys {
            #expect(!pattern.hasPrefix("maybePos."), "\(pattern) is below an optional atomic")
            #expect(!pattern.hasPrefix("holder.inner.at."), "\(pattern) is below an optional atomic")
        }
        #expect(hashes["maybePos"] != nil)
        // Elements of an optional container get their type's usual patterns, as elsewhere.
        #expect(Set(hashes.keys.filter { $0.hasPrefix("maybePoints.*.") }) == Set(hashes.keys.filter { $0.hasPrefix("points.*.") }.map { "maybePoints" + $0.dropFirst("points".count) }))
    }
}
