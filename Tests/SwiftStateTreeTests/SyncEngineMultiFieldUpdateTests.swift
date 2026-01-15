import Testing
import SwiftStateTree

// Mock State for Testing
@StateNodeBuilder
struct MockPlayerState: StateNodeProtocol {
    @Sync(.broadcast)
    var position: IVec2 = IVec2(x: 0, y: 0)
    
    @Sync(.broadcast)
    var rotation: Int = 0
    
    // Helper struct for IVec2 if not available in scope
    struct IVec2: Codable, Equatable, Sendable, CustomStringConvertible {
        var x: Int
        var y: Int
        var description: String { "(\(x), \(y))" }
    }
    
    init() {}
}

@StateNodeBuilder
struct MockGameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: MockPlayerState] = [:]
    
    init() {}
}

struct SyncEngineMultiFieldUpdateTests {
    
    @Test
    func testMultiFieldUpdateBundlingWithDictionary() throws {
        // 1. Setup
        var engine = SyncEngine()
        let clientID = PlayerID("client-1")
        let playerID = PlayerID("test-player")
        
        var startState = MockGameState()
        startState.players[playerID] = MockPlayerState()
        
        // 2. Generate Initial First Sync (to populate cache)
        let firstSyncUpdate = try engine.generateDiff(
            for: clientID,
            from: startState
        )
        
        // 3. Verify First Sync
        if case .firstSync(let patches) = firstSyncUpdate {
            print("First Sync Patches: \(patches.count)")
        } else {
            #expect(Bool(false), "Expected .firstSync on first call")
        }
        
        // 4. Modify State (Position AND Rotation for specific player)
        var nextState = startState
        // Simulate modifying the player state inside the dictionary
        // Note: Dictionary value modification implies replacing the value struct
        var player = nextState.players[playerID]!
        player.position = MockPlayerState.IVec2(x: 100, y: 200)
        player.rotation = 90
        nextState.players[playerID] = player
        
        // 5. Generate Diff
        let update = try engine.generateDiff(
            for: clientID,
            from: nextState,
            useDirtyTracking: false // Force full value comparison
        )
        
        // 6. Verify Results
        guard case .diff(let patches) = update else {
            #expect(Bool(false), "Expected .diff update, got \(update)")
            return
        }
        
        print("Diff Patches: \(patches)")
        
        // A. Assert we have exactly 2 patches
        // Even though it's in a dictionary, SyncEngine should produce patches for the nested fields
        // Path should be like: /players/test-player/position and /players/test-player/rotation
        // OR it might be a single patch for /players/test-player if the dictionary value is treated atomically?
        // Let's verify what actually happens.
        // Based on SyncEngine logic:
        // - Dictionary is a Map.
        // - `compareSnapshotValues` handles `.object`.
        // - `SyncEngine` treats dictionary values (StateNodes) as nested objects if they are converted to SnapshotValue.object.
        // - If `MockPlayerState` is a StateNode, it serializes to a SnapshotValue.object map.
        // - So it should recurse and find the leaf changes.
        
        // Expectation: 2 patches targeting leaf nodes.
        #expect(patches.count == 2, "Should have exactly 2 patches for 2 changed fields in dictionary")
        
        // B. Verify patch contents and paths
        let paths = Set(patches.map { $0.path })
        // PlayerID wraps a String or UUID. Assuming string interpolation works.
        // If PlayerID is just `struct PlayerID: Hashable, ExpressibleByStringLiteral { let id: String ... }`
        // We can cast or use description. 
        // Best guess: It's ExpressibleByStringLiteral, so interpolation might just use description.
        // Let's assume playerID.description = "test-player" or similar.
        // The safe bet is string interpolation: "\(playerID)"
        let expectedPosPath = "/players/\(playerID)/position"
        let expectedRotPath = "/players/\(playerID)/rotation"
        
        #expect(paths.contains(expectedPosPath), "Should contain patch for position at \(expectedPosPath)")
        #expect(paths.contains(expectedRotPath), "Should contain patch for rotation at \(expectedRotPath)")
        
        // C. Verify values
        if let posPatch = patches.first(where: { $0.path == expectedPosPath }),
           case .set(let val) = posPatch.operation {
             #expect(val == (try? SnapshotValue.make(from: MockPlayerState.IVec2(x: 100, y: 200))))
        }
        
        if let rotPatch = patches.first(where: { $0.path == expectedRotPath }),
           case .set(let val) = rotPatch.operation {
             if case .int(let intVal) = val {
                 #expect(intVal == 90)
             } else {
                 #expect(Bool(false), "Expected .int(90) but got \(val)")
             }
        }
    }
}
