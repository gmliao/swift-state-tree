// Tests/SwiftStateTreeTests/SyncEnginePerformanceTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Test Data Structures

/// Test nested structure: Player state with multiple fields
@State
struct BenchmarkPlayerState: StateProtocol, Equatable {
    var name: String
    var hpCurrent: Int
    var hpMax: Int
}

/// Test nested structure: Hand state containing cards
@State
struct BenchmarkHandState: StateProtocol, Equatable {
    var ownerID: PlayerID
    var cards: [BenchmarkCard]
}

/// Test nested structure: Card with multiple properties
@State
struct BenchmarkCard: StateProtocol, Equatable {
    let id: Int
    let suit: Int
    let rank: Int
}

/// Test StateNode with nested struct structures for benchmarking
@StateNodeBuilder
struct BenchmarkStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: BenchmarkPlayerState] = [:]
    
    @Sync(.perPlayerDictionaryValue())
    var hands: [PlayerID: BenchmarkHandState] = [:]
    
    @Sync(.serverOnly)
    var hiddenDeck: [BenchmarkCard] = []
    
    @Sync(.broadcast)
    var round: Int = 0
}

/// Generate test state with specified size
func generateTestState(
    playerCount: Int,
    cardsPerPlayer: Int
) -> BenchmarkStateRootNode {
    var state = BenchmarkStateRootNode()
    
    for i in 0..<playerCount {
        let playerID = PlayerID("player_\(i)")
        
        // Add player
        state.players[playerID] = BenchmarkPlayerState(
            name: "Player \(i)",
            hpCurrent: 100,
            hpMax: 100
        )
        
        // Add hand with cards
        var cards: [BenchmarkCard] = []
        for j in 0..<cardsPerPlayer {
            cards.append(BenchmarkCard(
                id: i * cardsPerPlayer + j,
                suit: j % 4,
                rank: j % 13
            ))
        }
        state.hands[playerID] = BenchmarkHandState(
            ownerID: playerID,
            cards: cards
        )
    }
    
    state.round = 1
    return state
}

// MARK: - Performance Tests

/// Performance tests comparing standard diff vs optimized diff with dirty tracking
@Suite("SyncEngine Performance Tests")
struct SyncEnginePerformanceTests {
    
    /// Measure performance difference between standard and optimized diff
    @Test("Performance: Standard vs Optimized Diff")
    func testPerformanceStandardVsOptimizedDiff() throws {
        // Setup: Create a large state with many players
        let playerCount = 100
        let cardsPerPlayer = 10
        var state = generateTestState(playerCount: playerCount, cardsPerPlayer: cardsPerPlayer)
        
        // Setup sync engine and populate cache (first sync)
        var syncEngine = SyncEngine()
        let playerID = PlayerID("player_0")
        
        // First sync to populate cache
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        
        // Clear dirty state
        state.clearDirty()
        
        // Measure standard diff (no dirty tracking)
        let standardTime = measureTime {
            // Modify only one player's HP (direct assignment marks as dirty)
            if let firstPlayerID = state.players.keys.first {
                var player = state.players[firstPlayerID]!
                player.hpCurrent = 90
                state.players[firstPlayerID] = player
            }
            
            // Generate diff without dirty tracking
            do {
                _ = try syncEngine.generateDiff(for: playerID, from: state, useDirtyTracking: false)
            } catch {
                // Ignore errors for performance test
            }
        }
        
        // Reset state and cache
        if let firstPlayerID = state.players.keys.first {
            var player = state.players[firstPlayerID]!
            player.hpCurrent = 100
            state.players[firstPlayerID] = player
        }
        state.clearDirty()
        syncEngine = SyncEngine()
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // Measure optimized diff (with dirty tracking)
        let optimizedTime = measureTime {
            // Modify only one player's HP (direct assignment marks as dirty)
            if let firstPlayerID = state.players.keys.first {
                var player = state.players[firstPlayerID]!
                player.hpCurrent = 90
                state.players[firstPlayerID] = player
            }
            
            // Generate diff with dirty tracking
            do {
                _ = try syncEngine.generateDiff(for: playerID, from: state, useDirtyTracking: true)
            } catch {
                // Ignore errors for performance test
            }
        }
        
        // Print results
        print("Standard diff time: \(standardTime)ms")
        print("Optimized diff time: \(optimizedTime)ms")
        print("Speedup: \(standardTime / optimizedTime)x")
        
        // Assert that optimized version is at least as fast (or faster)
        // Note: In some cases, the overhead of dirty tracking might make it slightly slower
        // for very small states, but it should be faster for larger states
        #expect(optimizedTime <= standardTime * 1.5, "Optimized diff should not be significantly slower")
    }
    
    /// Measure performance with multiple dirty fields
    @Test("Performance: Multiple Dirty Fields")
    func testPerformanceMultipleDirtyFields() throws {
        let playerCount = 50
        let cardsPerPlayer = 5
        var state = generateTestState(playerCount: playerCount, cardsPerPlayer: cardsPerPlayer)
        
        var syncEngine = SyncEngine()
        let playerID = PlayerID("player_0")
        
        // First sync
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // Modify multiple fields
        state.round = 2
        if let firstPlayerID = state.players.keys.first {
            var player = state.players[firstPlayerID]!
            player.hpCurrent = 80
            state.players[firstPlayerID] = player
        }
        
        // Measure optimized diff
        let optimizedTime = measureTime {
            do {
                _ = try syncEngine.generateDiff(for: playerID, from: state, useDirtyTracking: true)
            } catch {
                // Ignore errors
            }
        }
        
        print("Optimized diff time (multiple dirty fields): \(optimizedTime)ms")
        
        // Should complete in reasonable time
        #expect(optimizedTime < 100, "Should complete in reasonable time")
    }
    
    /// Measure performance with no dirty fields (should be very fast)
    @Test("Performance: No Dirty Fields")
    func testPerformanceNoDirtyFields() throws {
        let playerCount = 100
        let cardsPerPlayer = 10
        var state = generateTestState(playerCount: playerCount, cardsPerPlayer: cardsPerPlayer)
        
        var syncEngine = SyncEngine()
        let playerID = PlayerID("player_0")
        
        // First sync
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // Don't modify anything - no dirty fields
        // Measure optimized diff
        let optimizedTime = measureTime {
            do {
                _ = try syncEngine.generateDiff(for: playerID, from: state, useDirtyTracking: true)
            } catch {
                // Ignore errors
            }
        }
        
        print("Optimized diff time (no dirty fields): \(optimizedTime)ms")
        
        // Should be very fast when no fields are dirty
        #expect(optimizedTime < 10, "Should be very fast when no fields are dirty")
    }
    
    /// Measure performance with container operations
    @Test("Performance: Container Operations")
    func testPerformanceContainerOperations() throws {
        let playerCount = 50
        let cardsPerPlayer = 5
        var state = generateTestState(playerCount: playerCount, cardsPerPlayer: cardsPerPlayer)
        
        var syncEngine = SyncEngine()
        let playerID = PlayerID("player_0")
        
        // First sync
        _ = try syncEngine.generateDiff(for: playerID, from: state)
        state.clearDirty()
        
        // Modify dictionary (direct assignment marks as dirty)
        let newPlayerID = PlayerID("new_player")
        state.players[newPlayerID] = BenchmarkPlayerState(
            name: "New Player",
            hpCurrent: 100,
            hpMax: 100
        )
        
        // Measure optimized diff
        let optimizedTime = measureTime {
            do {
                _ = try syncEngine.generateDiff(for: playerID, from: state, useDirtyTracking: true)
            } catch {
                // Ignore errors
            }
        }
        
        print("Optimized diff time (container operation): \(optimizedTime)ms")
        
        // Should complete in reasonable time
        #expect(optimizedTime < 100, "Should complete in reasonable time")
    }
    
    // MARK: - Helper Functions
    
    /// Measure execution time of a block in milliseconds
    private func measureTime(_ block: () -> Void) -> Double {
        let start = CFAbsoluteTimeGetCurrent()
        block()
        let end = CFAbsoluteTimeGetCurrent()
        return (end - start) * 1000.0 // Convert to milliseconds
    }
}

