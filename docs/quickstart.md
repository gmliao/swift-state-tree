# 快速開始

## 前置需求

- Swift 6
- macOS 14+

## 方案 A：直接跑 Demo

```bash
cd Examples/HummingbirdDemo
swift run HummingbirdDemo
```

## 方案 B：最小單房間伺服器

### 1) 定義 State 與 Payload

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
}

@Payload
struct JoinAction: ActionPayload {
    typealias Response = JoinResponse
    let playerID: PlayerID
    let name: String
}

@Payload
struct JoinResponse: ResponsePayload {
    let status: String
}

@Payload
struct PingEvent: ClientEventPayload {
    let sentAt: Int
}

@Payload
struct PongEvent: ServerEventPayload {
    let sentAt: Int
}
```

### 2) 定義 Land

```swift
let land = Land("demo", using: GameState.self) {
    AccessControl {
        MaxPlayers(4)
    }

    ClientEvents {
        Register(PingEvent.self)
    }

    ServerEvents {
        Register(PongEvent.self)
    }

    Lifetime {
        Tick(every: .milliseconds(100)) { state, ctx in
            // Game logic here
        }
        DestroyWhenEmpty(after: .seconds(30))
    }

    Rules {
        HandleAction(JoinAction.self) { state, action, ctx in
            state.players[action.playerID] = PlayerState(name: action.name)
            return JoinResponse(status: "ok")
        }

        HandleEvent(PingEvent.self) { state, event, ctx in
            ctx.spawn {
                await ctx.sendEvent(PongEvent(sentAt: event.sentAt), to: .player(ctx.playerID))
            }
        }
    }
}
```

### 3) 使用 Hummingbird Hosting

```swift
import SwiftStateTreeHummingbird

@main
struct DemoServer {
    static func main() async throws {
        let server = try await LandServer.makeServer(
            configuration: .init(),
            land: land,
            initialState: GameState()
        )
        try await server.run()
    }
}
```

## 進階範例

### 範例 1：多玩家互動遊戲

這個範例展示如何建立一個支援多玩家互動的簡單遊戲：

```swift
import SwiftStateTree

// State 定義
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

// Land 定義
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
        Tick(every: .milliseconds(100)) { state, ctx in
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
                        ctx.spawn {
                            await ctx.sendEvent(GameOverEvent(winnerID: winnerID), to: .all)
                        }
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
            
            // Notify all players
            ctx.spawn {
                await ctx.sendEvent(
                    PlayerJoinedEvent(playerID: action.playerID, name: action.name),
                    to: .all
                )
            }
            
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
            
            // Notify all players
            let newHP = state.players[action.targetID]?.hpCurrent ?? 0
            ctx.spawn {
                await ctx.sendEvent(
                    DamageEvent(
                        attackerID: action.attackerID,
                        targetID: action.targetID,
                        damage: action.damage,
                        targetHP: newHP
                    ),
                    to: .all
                )
            }
            
            return AttackResponse(success: true, message: "Attack successful")
        }
        
        HandleEvent(PingEvent.self) { state, event, ctx in
            // Simple heartbeat handling
            ctx.spawn {
                await ctx.sendEvent(PongEvent(sentAt: event.sentAt), to: .player(ctx.playerID))
            }
        }
    }
}
```

### 範例 2：完整的事件處理流程

這個範例展示如何處理雙向事件通訊：

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
            
            // Broadcast to all players
            ctx.spawn {
                await ctx.sendEvent(
                    ChatMessageBroadcastEvent(
                        playerID: event.playerID,
                        playerName: playerName,
                        message: event.message,
                        timestamp: event.timestamp
                    ),
                    to: .all
                )
            }
        }
        
        HandleEvent(PlayerReadyEvent.self) { state, event, ctx in
            // Mark player as ready
            state.readyPlayers.insert(event.playerID)
            state.players[event.playerID]?.isReady = true
            
            // Check if all players are ready
            let allReady = state.players.keys.allSatisfy { state.readyPlayers.contains($0) }
            
            if allReady && state.players.count >= 2 {
                // Notify all players
                ctx.spawn {
                    await ctx.sendEvent(
                        AllPlayersReadyEvent(readyPlayers: Array(state.readyPlayers)),
                        to: .all
                    )
                }
            }
        }
    }
}
```

### 範例 3：錯誤處理

這個範例展示如何處理各種錯誤情況：

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

### 範例 4：使用 Resolver 載入資料

這個範例展示如何在 Action handler 中使用 Resolver：

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

## 相關文檔

- [概觀](overview.md) - 了解系統架構
- [Land DSL](core/land-dsl.md) - 深入了解 Land DSL
- [同步規則](core/sync.md) - 了解狀態同步機制
- [Runtime 運作機制](core/runtime.md) - 了解執行器運作方式
