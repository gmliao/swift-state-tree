// Sources/SwiftStateTreeBenchmarks/BenchmarkData.swift

import Foundation
import SwiftStateTree

// MARK: - Test Data Structures

/// Test nested structure: Player state with multiple fields
struct BenchmarkPlayerState: StateProtocol {
    var name: String
    var hpCurrent: Int
    var hpMax: Int
}

/// Test nested structure: Hand state containing cards
struct BenchmarkHandState: StateProtocol {
    var ownerID: PlayerID
    var cards: [BenchmarkCard]
}

/// Test nested structure: Card with multiple properties
struct BenchmarkCard: StateProtocol {
    let id: Int
    let suit: Int
    let rank: Int
}

/// Player-specific StateNode with multiple fields for testing dirty tracking
@StateNodeBuilder
struct BenchmarkPlayerStateNode: StateNodeProtocol {
    @Sync(.broadcast)
    var hpCurrent: Int = 100
    
    @Sync(.broadcast)
    var hpMax: Int = 100
    
    @Sync(.broadcast)
    var level: Int = 1
    
    @Sync(.broadcast)
    var experience: Int = 0
    
    @Sync(.broadcast)
    var positionX: Double = 0.0
    
    @Sync(.broadcast)
    var positionY: Double = 0.0
    
    @Sync(.broadcast)
    var status: String = "idle"
    
    @Sync(.broadcast)
    var lastAction: String = "none"
}

/// Test StateNode with nested struct structures for benchmarking
@StateNodeBuilder
struct BenchmarkStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: BenchmarkPlayerState] = [:]
    
    @Sync(.perPlayerDictionaryValue())
    var playerNodes: [PlayerID: BenchmarkPlayerStateNode] = [:]
    
    @Sync(.perPlayerDictionaryValue())
    var hands: [PlayerID: BenchmarkHandState] = [:]
    
    @Sync(.serverOnly)
    var hiddenDeck: [BenchmarkCard] = []
    
    @Sync(.broadcast)
    var round: Int = 0
    
    @Sync(.broadcast)
    var gamePhase: String = "waiting"
    
    @Sync(.broadcast)
    var turnOrder: [PlayerID] = []
    
    @Sync(.broadcast)
    var score: Int = 0
    
    @Sync(.broadcast)
    var timestamp: Int64 = 0
    
    @Sync(.perPlayerDictionaryValue())
    var playerScores: [PlayerID: Int] = [:]
    
    @Sync(.broadcast)
    var activePlayers: [PlayerID] = []
    
    @Sync(.broadcast)
    var gameConfig: [String: String] = [:]
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
        
        // Add player state node with multiple fields
        state.playerNodes[playerID] = BenchmarkPlayerStateNode(
            hpCurrent: 100,
            hpMax: 100,
            level: 1,
            experience: 0,
            positionX: Double(i * 10),
            positionY: Double(i * 10),
            status: "idle",
            lastAction: "none"
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
        
        // Initialize perPlayer fields
        state.playerScores[playerID] = 0
    }
    
    // Initialize broadcast fields
    state.round = 1
    state.gamePhase = "waiting"
    state.turnOrder = Array(state.players.keys).sorted(by: { $0.rawValue < $1.rawValue })
    state.score = 0
    state.timestamp = Int64(Date().timeIntervalSince1970)
    state.activePlayers = Array(state.players.keys)
    state.gameConfig = ["mode": "standard", "version": "1.0"]
    
    return state
}

