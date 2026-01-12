
import Foundation
import Testing
@testable import SwiftStateTree
import SwiftStateTreeDeterministicMath

// MARK: - Test StateNode

@StateNodeBuilder
struct AtomicTypeStateNode: StateNodeProtocol {
    @Sync(.broadcast)
    var angle: Angle = Angle(degrees: 0)
    
    @Sync(.broadcast)
    var position: Position2 = Position2(x: 0, y: 0)
    
    @Sync(.broadcast)
    var map: [Int: Angle] = [:]
    
    @Sync(.broadcast)
    var structMap: [String: SimpleStruct] = [:]
}

struct SimpleStruct: Codable, Equatable, Sendable {
    var x: Int
    var y: Int
}

// MARK: - Atomic Type Diff Tests

@Test("Angle update generates atomic replacement patch")
func testAngleUpdate_GeneratesAtomicReplacement() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = AtomicTypeStateNode()
    let playerID = PlayerID("test")
    
    // First sync
    _ = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Update angle
    state.angle = Angle(degrees: 90)
    
    // Act
    let update = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert
    if case .diff(let patches) = update {
        #expect(patches.count == 1)
        let patch = patches[0]
        
        // CRITICAL: We expect path to be "/angle", NOT "/angle/degrees"
        #expect(patch.path == "/angle", "Should generate atomic patch for Angle, got partial update at: \(patch.path)")
        
        if case .set(let value) = patch.operation {
            if case .object = value {
                // Success
            } else {
                Issue.record("Value should be object")
            }
        }
    } else {
        Issue.record("Should return .diff")
    }
}

@Test("Position2 update generates atomic replacement patch")
func testPosition2Update_GeneratesAtomicReplacement() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = AtomicTypeStateNode()
    let playerID = PlayerID("test")
    
    // First sync
    _ = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Update position
    state.position = Position2(x: 10, y: 20)
    
    // Act
    let update = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert
    if case .diff(let patches) = update {
        #expect(patches.count == 1)
        let patch = patches[0]
        
        // CRITICAL: We expect path to be "/position", NOT "/position/v/x" or "/position/v"
        #expect(patch.path == "/position", "Should generate atomic patch for Position2, got partial update at: \(patch.path)")
    } else {
        Issue.record("Should return .diff")
    }
}

@Test("Map of Angles generates atomic replacements for values")
func testMapOfAngles_GeneratesAtomicReplacement() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = AtomicTypeStateNode()
    let playerID = PlayerID("test")
    
    state.map[1] = Angle(degrees: 0)
    
    // First sync
    _ = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Update angle in map
    state.map[1] = Angle(degrees: 180)
    
    // Act
    let update = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert
    if case .diff(let patches) = update {
        #expect(patches.count == 1)
        let patch = patches[0]
        
        // CRITICAL: We expect path to be "/map/1", NOT "/map/1/degrees"
        #expect(patch.path == "/map/1", "Should generate atomic patch for map value, got: \(patch.path)")
    } else {
        Issue.record("Should return .diff")
    }
}

@Test("Simple struct generates atomic updates by default (unless @StateNode)")
func testSimpleStruct_GeneratesAtomicUpdates() throws {
    // Arrange
    var syncEngine = SyncEngine()
    var state = AtomicTypeStateNode()
    let playerID = PlayerID("test")
    
    state.structMap["s"] = SimpleStruct(x: 1, y: 1)
    
    // First sync
    _ = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Update one field
    state.structMap["s"]?.x = 2
    
    // Act
    let update = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert
    if case .diff(let patches) = update {
        #expect(patches.count == 1)
        let patch = patches[0]
        // Since SimpleStruct is not a StateNode, it is treated atomically
        #expect(patch.path == "/structMap/s") 
    } else {
        Issue.record("Should return .diff")
    }
}

@Test func testDictionaryRemoval() throws {
    // Arrange
    var syncEngine = SyncEngine()
    let playerID = PlayerID("p1")
    
    // Initial state with a map containing an item
    var state = AtomicTypeStateNode()
    state.map[1] = Angle(degrees: 90)
    
    // First sync
    _ = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Remove the item
    state.map.removeValue(forKey: 1)
    
    // Act
    let update = try syncEngine.generateDiff(for: playerID, from: state)
    
    // Assert
    if case .diff(let patches) = update {
        #expect(patches.count == 1)
        let patch = patches[0]
        if case .delete = patch.operation {
            // Success
        } else {
            Issue.record("Patch operation should be .delete but got \(patch.operation)")
        }
        #expect(patch.path == "/map/1")
    } else {
        Issue.record("Should return .diff")
    }
}
