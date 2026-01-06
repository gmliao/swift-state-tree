// Tests/SwiftStateTreeDeterministicMathTests/IntegrationTests.swift
//
// Integration tests for DeterministicMath with StateNode and JSON serialization.

import Foundation
import Testing
@testable import SwiftStateTreeDeterministicMath
@testable import SwiftStateTree

// MARK: - Test StateNode with IVec2

@StateNodeBuilder
struct TestGameStateWithIVec2: StateNodeProtocol {
    @Sync(.broadcast)
    var playerPosition: IVec2 = IVec2(x: 0.0, y: 0.0)
    
    @Sync(.broadcast)
    var playerPositions: [PlayerID: IVec2] = [:]
}

@Test("IVec2 works in StateNode sync")
func testIVec2InStateNode() throws {
    var state = TestGameStateWithIVec2()
    let playerID = PlayerID("player1")
    
    state.playerPosition = IVec2(x: 1.0, y: 2.0)
    state.playerPositions[playerID] = IVec2(x: 3.0, y: 4.0)
    
    // Test that values are stored correctly
    #expect(state.playerPosition.x == 1000)
    #expect(state.playerPosition.y == 2000)
    #expect(state.playerPositions[playerID]?.x == 3000)
    #expect(state.playerPositions[playerID]?.y == 4000)
    
    // Test JSON serialization
    let encoder = JSONEncoder()
    let data = try encoder.encode(state.playerPosition)
    
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(IVec2.self, from: data)
    
    #expect(decoded == state.playerPosition)
}

@Test("IVec2 serializes correctly in JSON")
func testIVec2JSONSerialization() throws {
    let vec = IVec2(x: 1.0, y: 2.0)
    
    let encoder = JSONEncoder()
    let data = try encoder.encode(vec)
    
    // Verify JSON structure
    let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(json != nil)
    #expect(json?["x"] as? Int == 1000)
    #expect(json?["y"] as? Int == 2000)
    
    // Verify deserialization
    let decoder = JSONDecoder()
    let decoded = try decoder.decode(IVec2.self, from: data)
    #expect(decoded == vec)
}

// MARK: - SchemaGen Integration Test

@StateNodeBuilder
struct TestStateNodeWithDeterministicMath: StateNodeProtocol {
    @Sync(.broadcast)
    var playerPosition: Position2 = Position2(v: IVec2(x: 0.0, y: 0.0))
    
    @Sync(.broadcast)
    var playerVelocity: Velocity2 = Velocity2(v: IVec2(x: 0.0, y: 0.0))
    
    @Sync(.broadcast)
    var positions: [PlayerID: IVec2] = [:]
}

@Test("Position2 works in StateNode and can be extracted for schema")
func testPosition2InStateNodeSchema() {
    var state = TestStateNodeWithDeterministicMath()
    let playerID = PlayerID("player1")
    
    state.playerPosition = Position2(x: 1.0, y: 2.0)
    state.playerVelocity = Velocity2(x: 0.1, y: 0.05)
    state.positions[playerID] = IVec2(x: 3.0, y: 4.0)
    
    // Verify values are stored correctly
    #expect(state.playerPosition.v.x == 1000)
    #expect(state.playerPosition.v.y == 2000)
    #expect(state.playerVelocity.v.x == 100)
    #expect(state.playerVelocity.v.y == 50)
    #expect(state.positions[playerID]?.x == 3000)
    #expect(state.positions[playerID]?.y == 4000)
    
    // Verify JSON serialization works
    do {
        let encoder = JSONEncoder()
        let data = try encoder.encode(state.playerPosition)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json != nil)
        #expect(json?["v"] != nil)
        
        let vDict = json?["v"] as? [String: Any]
        #expect(vDict?["x"] as? Int == 1000)
        #expect(vDict?["y"] as? Int == 2000)
    } catch {
        Issue.record("Failed to serialize Position2: \(error)")
    }
}
