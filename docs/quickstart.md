[English](quickstart.md) | [中文版](quickstart.zh-TW.md)

# Quick Start

## Prerequisites

- Swift 6
- macOS 14+

## Option A: Run Demo Directly

```bash
cd Examples/HummingbirdDemo
swift run DemoServer
```

## Option B: Minimal Single-Room Server

### 1) Define State and Payload

```swift
import SwiftStateTree

@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
}

@SnapshotConvertible
struct PlayerState: Codable, Sendable {
    var name: String
    var cookies: Int = 0
}

@Payload
struct ClickCookieEvent: ClientEventPayload {
    /// Number of cookies to add for this click (default is 1)
    let amount: Int
    
    init(amount: Int = 1) {
        self.amount = amount
    }
}
```

### 2) Define Land

```swift
let land = Land("demo", using: GameState.self) {
    AccessControl {
        MaxPlayers(4)
    }

    ClientEvents {
        Register(ClickCookieEvent.self)
    }

    Lifetime {
        OnJoin { state, ctx in
            // Initialize player state when they join
            let playerID = ctx.playerID
            let playerName = ctx.metadata["username"] as? String ?? "Player"
            state.players[playerID] = PlayerState(name: playerName, cookies: 0)
        }
        
        // Game logic updates (can modify state)
        Tick(every: .milliseconds(100)) { (state: inout GameState, ctx: LandContext) in
            // Game logic here
        }
        
        // Network synchronization (read-only callback for type inference)
        StateSync(every: .milliseconds(100)) { (state: GameState, ctx: LandContext) in
            // Read-only callback - will be called during sync
            // Do NOT modify state here - use Tick for state mutations
            // Use for logging, metrics, or other read-only operations
        }
        
        DestroyWhenEmpty(after: .seconds(30)) { state, ctx in
            ctx.logger.info("Land is empty, destroying...")
        }
    }

    Rules {
        HandleEvent(ClickCookieEvent.self) { state, event, ctx in
            // Add cookies to the player who clicked
            if var player = state.players[ctx.playerID] {
                player.cookies += event.amount
                state.players[ctx.playerID] = player
            }
        }
    }
}
```

### 3) Use Hummingbird Hosting

```swift
import SwiftStateTreeHummingbird

@main
struct DemoServer {
    static func main() async throws {
        // Create LandHost to manage HTTP server and game logic
        let host = LandHost(configuration: LandHost.HostConfiguration(
            host: "localhost",
            port: 8080
        ))

        // Register land type
        try await host.register(
            landType: "demo",
            land: land,
            initialState: GameState(),
            webSocketPath: "/game",
            configuration: LandServerConfiguration(
                allowGuestMode: true,
                allowAutoCreateOnJoin: true
            )
        )

        // Run unified server
        try await host.run()
    }
}
```

## Advanced Examples

### Example 1: Multiplayer Interactive Game

This example demonstrates how to build a simple game that supports multiplayer interactions:

```swift
import SwiftStateTree

// State definition
@StateNodeBuilder
struct GameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
    
    @Sync(.broadcast)
    var gameStatus: String = "waiting"  // waiting, playing, finished
    
    @Sync(.perPlayerSlice())
    var scores: [PlayerID: Int] = [:]
}

@SnapshotConvertible
struct PlayerState: Codable, Sendable {
    var name: String
    var hpCurrent: Int
    var hpMax: Int
}

// Actions
@Payload
struct JoinGameAction: ActionPayload {
    typealias Response = JoinGameResponse
    let playerID: PlayerID
    let name: String
}

@Payload
struct JoinGameResponse: ResponsePayload {
    let success: Bool
    let message: String
}

@Payload
struct AttackAction: ActionPayload {
    typealias Response = AttackResponse
    let attackerID: PlayerID
    let targetID: PlayerID
    let damage: Int
}

@Payload
struct AttackResponse: ResponsePayload {
    let success: Bool
    let message: String
}

// Events
@Payload
struct PlayerJoinedEvent: ServerEventPayload {
    let playerID: PlayerID
    let name: String
}

@Payload
struct DamageEvent: ServerEventPayload {
    let attackerID: PlayerID
    let targetID: PlayerID
    let damage: Int
    let targetHP: Int
}

@Payload
struct GameOverEvent: ServerEventPayload {
    let winnerID: PlayerID
}

// Land definition
let gameLand = Land("multiplayer-game", using: GameState.self) {
    AccessControl {
        MaxPlayers(4)
    }
    
    ClientEvents {
        Register(PingEvent.self)
    }
    
    ServerEvents {
        Register(PlayerJoinedEvent.self)
        Register(DamageEvent.self)
        Register(GameOverEvent.self)
    }
    
    Lifetime {
        Tick(every: .milliseconds(100)) { (state: inout GameState, ctx: LandContext) in
            // Check if game should start
            if state.gameStatus == "waiting" && state.players.count >= 2 {
                state.gameStatus = "playing"
            }
            
            // Check for game over
            let alivePlayers = state.players.values.filter { $0.hpCurrent > 0 }
            if state.gameStatus == "playing" && alivePlayers.count == 1 {
                state.gameStatus = "finished"
                if let winner = alivePlayers.first {
                    let winnerID = state.players.first(where: { $0.value.name == winner.name })?.key
                    if let winnerID = winnerID {
                        ctx.emitEvent(GameOverEvent(winnerID: winnerID), to: .all)
                    }
                }
            }
        }
        DestroyWhenEmpty(after: .seconds(60))
    }
    
    Rules {
        HandleAction(JoinGameAction.self) { state, action, ctx in
            // Check if game is full
            guard state.players.count < 4 else {
                return JoinGameResponse(success: false, message: "Game is full")
            }
            
            // Check if game has started
            guard state.gameStatus == "waiting" else {
                return JoinGameResponse(success: false, message: "Game has already started")
            }
            
            // Add player
            state.players[action.playerID] = PlayerState(
                name: action.name,
                hpCurrent: 100,
                hpMax: 100
            )
            state.scores[action.playerID] = 0
            
            // Notify all players (deterministic output)
            ctx.emitEvent(
                PlayerJoinedEvent(playerID: action.playerID, name: action.name),
                to: .all
            )
            
            return JoinGameResponse(success: true, message: "Joined successfully")
        }
        
        HandleAction(AttackAction.self) { state, action, ctx in
            // Validate game status
            guard state.gameStatus == "playing" else {
                return AttackResponse(success: false, message: "Game is not in progress")
            }
            
            // Validate attacker
            guard let attacker = state.players[action.attackerID],
                  attacker.hpCurrent > 0 else {
                return AttackResponse(success: false, message: "Attacker is not alive")
            }
            
            // Validate target
            guard let target = state.players[action.targetID],
                  target.hpCurrent > 0,
                  action.targetID != action.attackerID else {
                return AttackResponse(success: false, message: "Invalid target")
            }
            
            // Apply damage
            state.players[action.targetID]?.hpCurrent = max(0, target.hpCurrent - action.damage)
            
            // Update score
            state.scores[action.attackerID] = (state.scores[action.attackerID] ?? 0) + action.damage
            
            // Notify all players (deterministic output)
            let newHP = state.players[action.targetID]?.hpCurrent ?? 0
            ctx.emitEvent(
                DamageEvent(
                    attackerID: action.attackerID,
                    targetID: action.targetID,
                    damage: action.damage,
                    targetHP: newHP
                ),
                to: .all
            )
            
            return AttackResponse(success: true, message: "Attack successful")
        }
        
        HandleEvent(PingEvent.self) { state, event, ctx in
            // Simple heartbeat handling (deterministic output)
            ctx.emitEvent(PongEvent(sentAt: event.sentAt), to: .player(ctx.playerID))
        }
    }
}
```

### Example 2: Complete Event Handling Flow

This example demonstrates how to handle bidirectional event communication:

```swift
// Client Events
@Payload
struct ChatMessageEvent: ClientEventPayload {
    let playerID: PlayerID
    let message: String
    let timestamp: Date
}

@Payload
struct PlayerReadyEvent: ClientEventPayload {
    let playerID: PlayerID
}

// Server Events
@Payload
struct ChatMessageBroadcastEvent: ServerEventPayload {
    let playerID: PlayerID
    let playerName: String
    let message: String
    let timestamp: Date
}

@Payload
struct AllPlayersReadyEvent: ServerEventPayload {
    let readyPlayers: [PlayerID]
}

// State
@StateNodeBuilder
struct LobbyState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerInfo] = [:]
    
    @Sync(.broadcast)
    var readyPlayers: Set<PlayerID> = []
    
    @Sync(.broadcast)
    var chatMessages: [ChatMessage] = []
}

@SnapshotConvertible
struct PlayerInfo: Codable, Sendable {
    var name: String
    var isReady: Bool
}

@SnapshotConvertible
struct ChatMessage: Codable, Sendable {
    var playerID: PlayerID
    var playerName: String
    var message: String
    var timestamp: Date
}

// Land
let lobbyLand = Land("lobby", using: LobbyState.self) {
    AccessControl {
        MaxPlayers(10)
    }
    
    ClientEvents {
        Register(ChatMessageEvent.self)
        Register(PlayerReadyEvent.self)
    }
    
    ServerEvents {
        Register(ChatMessageBroadcastEvent.self)
        Register(AllPlayersReadyEvent.self)
    }
    
    Rules {
        HandleEvent(ChatMessageEvent.self) { state, event, ctx in
            // Validate message
            guard !event.message.trimmingCharacters(in: .whitespaces).isEmpty else {
                return  // Ignore empty messages
            }
            
            // Get player name
            let playerName = state.players[event.playerID]?.name ?? "Unknown"
            
            // Add to chat history (limit to last 100 messages)
            let chatMessage = ChatMessage(
                playerID: event.playerID,
                playerName: playerName,
                message: event.message,
                timestamp: event.timestamp
            )
            state.chatMessages.append(chatMessage)
            if state.chatMessages.count > 100 {
                state.chatMessages.removeFirst()
            }
            
            // Broadcast to all players (deterministic output)
            ctx.emitEvent(
                ChatMessageBroadcastEvent(
                    playerID: event.playerID,
                    playerName: playerName,
                    message: event.message,
                    timestamp: event.timestamp
                ),
                to: .all
            )
        }
        
        HandleEvent(PlayerReadyEvent.self) { state, event, ctx in
            // Mark player as ready
            state.readyPlayers.insert(event.playerID)
            state.players[event.playerID]?.isReady = true
            
            // Check if all players are ready
            let allReady = state.players.keys.allSatisfy { state.readyPlayers.contains($0) }
            
            if allReady && state.players.count >= 2 {
                // Notify all players (deterministic output)
                ctx.emitEvent(
                    AllPlayersReadyEvent(readyPlayers: Array(state.readyPlayers)),
                    to: .all
                )
            }
        }
    }
}
```

### Example 3: Error Handling

This example demonstrates how to handle various error scenarios:

```swift
// Custom errors
enum GameError: Error {
    case roomFull
    case gameStarted
    case playerNotFound
    case invalidAction
    case insufficientResources
}

// State
@StateNodeBuilder
struct ResourceGameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
    
    @Sync(.perPlayerSlice())
    var resources: [PlayerID: ResourceState] = [:]
}

@SnapshotConvertible
struct ResourceState: Codable, Sendable {
    var gold: Int
    var wood: Int
    var stone: Int
}

// Actions
@Payload
struct PurchaseAction: ActionPayload {
    typealias Response = PurchaseResponse
    let playerID: PlayerID
    let itemType: String
    let cost: ResourceState
}

@Payload
struct PurchaseResponse: ResponsePayload {
    let success: Bool
    let message: String
    let newResources: ResourceState?
}

// Land
let resourceGameLand = Land("resource-game", using: ResourceGameState.self) {
    Rules {
        HandleAction(PurchaseAction.self) { state, action, ctx in
            // Validate player exists
            guard state.players[action.playerID] != nil else {
                throw LandError.invalidAction("Player not found")
            }
            
            // Get current resources
            guard let currentResources = state.resources[action.playerID] else {
                throw LandError.invalidAction("Player resources not initialized")
            }
            
            // Check if player has enough resources
            guard currentResources.gold >= action.cost.gold,
                  currentResources.wood >= action.cost.wood,
                  currentResources.stone >= action.cost.stone else {
                return PurchaseResponse(
                    success: false,
                    message: "Insufficient resources",
                    newResources: nil
                )
            }
            
            // Deduct resources
            var newResources = currentResources
            newResources.gold -= action.cost.gold
            newResources.wood -= action.cost.wood
            newResources.stone -= action.cost.stone
            
            state.resources[action.playerID] = newResources
            
            // Return success with updated resources
            return PurchaseResponse(
                success: true,
                message: "Purchase successful",
                newResources: newResources
            )
        }
    }
}
```

### Example 4: Using Resolver to Load Data

This example demonstrates how to use Resolver in Action handlers:

```swift
// Resolver
struct ProductInfoResolver: ContextResolver {
    typealias Output = ProductInfo
    
    static func resolve(ctx: ResolverContext) async throws -> ProductInfo {
        let action = ctx.actionPayload as? PurchaseAction
        guard let productID = action?.productID else {
            throw ResolverError.missingParameter("productID")
        }
        
        // Load from database (simulated)
        let data = try await ctx.services.database.fetchProduct(by: productID)
        return ProductInfo(
            id: data.id,
            name: data.name,
            price: data.price,
            stock: data.stock
        )
    }
}

@SnapshotConvertible
struct ProductInfo: Codable, Sendable, ResolverOutput {
    let id: String
    let name: String
    let price: Double
    let stock: Int
}

// Action with Resolver
@Payload
struct PurchaseAction: ActionPayload {
    typealias Response = PurchaseResponse
    let playerID: PlayerID
    let productID: String
    let quantity: Int
}

// Land with Resolver
let shopLand = Land("shop", using: ShopState.self) {
    Rules {
        HandleAction(
            PurchaseAction.self,
            resolvers: ProductInfoResolver.self
        ) { state, action, ctx in
            // Resolver has already executed, productInfo is available
            guard let product = ctx.productInfo else {
                return PurchaseResponse(success: false, message: "Product not found")
            }
            
            // Check stock
            guard product.stock >= action.quantity else {
                return PurchaseResponse(success: false, message: "Insufficient stock")
            }
            
            // Process purchase
            // ...
            
            return PurchaseResponse(success: true, message: "Purchase successful")
        }
    }
}
```

## Related Documentation

- [Overview](overview.md) - Understand system architecture
- [Land DSL](core/land-dsl.md) - Deep dive into Land DSL
- [Sync Rules](core/sync.md) - Understand state synchronization mechanisms
- [Runtime Operation](core/runtime.md) - Understand executor operation
