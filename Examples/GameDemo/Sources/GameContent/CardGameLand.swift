// Examples/GameDemo/Sources/GameContent/CardGameLand.swift
//
// Card game land definition for benchmarking multi-player sync.

import Foundation
import SwiftStateTree

// MARK: - Card Game Land

public enum CardGame {
    public static func makeLand() -> LandDefinition<CardGameState> {
        Land(
            "card-game",
            using: CardGameState.self
        ) {
            AccessControl {
                AllowPublic(true)
                MaxPlayers(50)  // Support many players for sync benchmark tests
            }
            
            Rules {
                OnJoin { (state: inout CardGameState, ctx: LandContext) in
                    let playerID = ctx.playerID
                    
                    // Initialize player state
                    if state.players[playerID] == nil {
                        state.players[playerID] = CardGamePlayerState(
                            name: "Player \(playerID.rawValue)",
                            totalScore: 0,
                            gamesWon: 0,
                            isActive: true
                        )
                    }
                    
                    // Initialize player hand
                    if state.hands[playerID] == nil {
                        state.hands[playerID] = PlayerHand(
                            cards: [],
                            score: 0,
                            lastDrawTick: ctx.tickId ?? 0
                        )
                    }
                }
            }
            
            Lifetime {
                // Tick every 100ms to update game state
                Tick(every: .milliseconds(100)) { (state: inout CardGameState, ctx: LandContext) in
                    guard let tickId = ctx.tickId else {
                        return
                    }
                    
                    state.tickCount = tickId
                    
                    // Initialize deck if empty
                    if state.deck.isEmpty {
                        initializeDeck(&state)
                    }
                    
                    // Auto-draw cards for players periodically
                    // Strategy: Similar to benchmark's dirtyPlayerRatio (0.20 = 20% of players update per tick)
                    // Draw interval varies to create more realistic update patterns
                    let drawInterval: Int64 = 10  // Base interval: every 10 ticks (1 second)
                    let allPlayerIDs = Array(state.hands.keys).sorted { $0.rawValue < $1.rawValue }
                    guard !allPlayerIDs.isEmpty else { return }
                    
                    // Update ~20% of players per tick (similar to benchmark's dirtyPlayerRatio)
                    let dirtyPlayerRatio = 0.20
                    let numPlayersToUpdate = max(1, Int(Double(allPlayerIDs.count) * dirtyPlayerRatio))
                    let startIndex = Int(tickId % Int64(allPlayerIDs.count))
                    
                    for offset in 0..<numPlayersToUpdate {
                        let playerIndex = (startIndex + offset) % allPlayerIDs.count
                        let playerID = allPlayerIDs[playerIndex]
                        guard var hand = state.hands[playerID] else { continue }
                        defer { state.hands[playerID] = hand }
                        
                        // Check if it's time to draw a card (with some variation)
                        let ticksSinceLastDraw = tickId - hand.lastDrawTick
                        let effectiveInterval = drawInterval + Int64(offset % 3)  // Vary interval slightly
                        if ticksSinceLastDraw >= effectiveInterval && !state.deck.isEmpty {
                            // Draw a card
                            if let drawnCard = drawCard(from: &state.deck) {
                                hand.cards.append(drawnCard)
                                hand.lastDrawTick = tickId
                                
                                // Update score based on card value
                                hand.score += drawnCard.value
                                
                                // Update player's total score
                                if var player = state.players[playerID] {
                                    player.totalScore += drawnCard.value
                                    state.players[playerID] = player
                                }
                                
                                state.deckSize = state.deck.count
                            }
                        }
                        
                        // Limit hand size to 10 cards
                        if hand.cards.count > 10 {
                            // Move excess cards to public pile
                            let excessCards = hand.cards.suffix(hand.cards.count - 10)
                            state.publicCards.append(contentsOf: excessCards)
                            hand.cards = Array(hand.cards.prefix(10))
                        }
                    }
                    
                    // Update game phase
                    if state.gamePhase == "waiting" && !state.players.isEmpty {
                        state.gamePhase = "playing"
                        state.currentRound = 1
                        state.turnOrder = Array(state.players.keys).sorted(by: { $0.rawValue < $1.rawValue })
                    }
                    
                    // Rotate turn order periodically
                    if !state.turnOrder.isEmpty && tickId % 20 == 0 {
                        state.currentPlayerIndex = (state.currentPlayerIndex + 1) % state.turnOrder.count
                    }
                    
                    // Update public cards periodically (move some cards from deck to public)
                    if tickId % 30 == 0 && !state.deck.isEmpty && state.publicCards.count < 20 {
                        if let card = drawCard(from: &state.deck) {
                            state.publicCards.append(card)
                            state.deckSize = state.deck.count
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - Helper Functions
    
    private static func initializeDeck(_ state: inout CardGameState) {
        var cards: [Card] = []
        var cardID = state.nextCardID
        
        // Create a standard 52-card deck
        for suit in 0..<4 {
            for rank in 0..<13 {
                let value = rank + 1  // Ace = 1, King = 13
                cards.append(Card(
                    id: cardID,
                    suit: suit,
                    rank: rank,
                    value: value
                ))
                cardID += 1
            }
        }
        
        // Shuffle deck (deterministic shuffle based on tick count)
        var generator = SeededRandomNumberGenerator(seed: UInt64(bitPattern: state.tickCount))
        cards.shuffle(using: &generator)
        
        state.deck = cards
        state.deckSize = cards.count
        state.nextCardID = cardID
    }
    
    private static func drawCard(from deck: inout [Card]) -> Card? {
        guard !deck.isEmpty else {
            return nil
        }
        return deck.removeFirst()
    }
}

// MARK: - Deterministic Random Number Generator

struct SeededRandomNumberGenerator: RandomNumberGenerator {
    var seed: UInt64
    
    mutating func next() -> UInt64 {
        seed = seed &* 1103515245 &+ 12345
        return seed
    }
}
