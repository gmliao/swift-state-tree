// Examples/GameDemo/Sources/GameContent/States/CardGameState.swift
//
// Card game state for benchmarking multi-player sync with per-player state.

import Foundation
import SwiftStateTree

// MARK: - Card

@SnapshotConvertible
public struct Card: StateProtocol {
    public let id: Int
    public let suit: Int  // 0-3: Spades, Hearts, Diamonds, Clubs
    public let rank: Int  // 0-12: Ace, 2-10, Jack, Queen, King
    public let value: Int  // Game value (1-13)

    public init(id: Int, suit: Int, rank: Int, value: Int) {
        self.id = id
        self.suit = suit
        self.rank = rank
        self.value = value
    }
}

extension Card: SnapshotValueDecodable {
    public init(fromSnapshotValue value: SnapshotValue) throws {
        guard case .object(let dict) = value else {
            throw SnapshotDecodeError.typeMismatch(expected: "object", got: value)
        }
        let idVal: Int = try _snapshotDecode(dict["id"] ?? .null)
        let suitVal: Int = try _snapshotDecode(dict["suit"] ?? .null)
        let rankVal: Int = try _snapshotDecode(dict["rank"] ?? .null)
        let valueVal: Int = try _snapshotDecode(dict["value"] ?? .null)
        self.init(id: idVal, suit: suitVal, rank: rankVal, value: valueVal)
    }
}

// MARK: - Player Hand (Per-Player State)

@SnapshotConvertible
public struct PlayerHand: StateProtocol {
    public var cards: [Card]
    public var score: Int
    public var lastDrawTick: Int64
    
    public init(cards: [Card] = [], score: Int = 0, lastDrawTick: Int64 = 0) {
        self.cards = cards
        self.score = score
        self.lastDrawTick = lastDrawTick
    }
}

// MARK: - Player State (Broadcast)

@SnapshotConvertible
public struct CardGamePlayerState: StateProtocol {
    public var name: String
    public var totalScore: Int
    public var gamesWon: Int
    public var isActive: Bool

    public init(name: String, totalScore: Int = 0, gamesWon: Int = 0, isActive: Bool = true) {
        self.name = name
        self.totalScore = totalScore
        self.gamesWon = gamesWon
        self.isActive = isActive
    }

    /// No-argument init for @SnapshotConvertible-generated decoder.
    public init() {
        self.init(name: "", totalScore: 0, gamesWon: 0, isActive: true)
    }
}

// MARK: - Card Game State

@StateNodeBuilder
public struct CardGameState: StateNodeProtocol {
    // Broadcast state (visible to all players)
    @Sync(.broadcast)
    public var players: [PlayerID: CardGamePlayerState] = [:]
    
    @Sync(.broadcast)
    public var publicCards: [Card] = []  // Cards on the table (visible to all)
    
    @Sync(.broadcast)
    public var currentRound: Int = 0
    
    @Sync(.broadcast)
    public var gamePhase: String = "waiting"  // waiting, playing, finished
    
    @Sync(.broadcast)
    public var deckSize: Int = 0
    
    @Sync(.broadcast)
    public var turnOrder: [PlayerID] = []
    
    @Sync(.broadcast)
    public var currentPlayerIndex: Int = 0
    
    // Per-player state (each player only sees their own hand)
    @Sync(.perPlayerSlice())
    public var hands: [PlayerID: PlayerHand] = [:]
    
    // Server-only state
    @Sync(.serverOnly)
    public var deck: [Card] = []
    
    @Sync(.serverOnly)
    public var nextCardID: Int = 0
    
    @Sync(.serverOnly)
    public var tickCount: Int64 = 0
    
    public init() {
        // Initialize empty state
    }
}
