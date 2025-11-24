// Sources/SwiftStateTreeBenchmarks/BenchmarkData.swift

import Foundation
import SwiftStateTree

// MARK: - Test Data Structures

/// Test nested structure: Player state with multiple fields
@State
struct BenchmarkPlayerState: StateProtocol {
    var name: String
    var hpCurrent: Int
    var hpMax: Int
}

/// Test nested structure: Hand state containing cards
@State
struct BenchmarkHandState: StateProtocol {
    var ownerID: PlayerID
    var cards: [BenchmarkCard]
}

/// Test nested structure: Card with multiple properties
@State
struct BenchmarkCard: StateProtocol {
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

// MARK: - Test Data Generation

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

