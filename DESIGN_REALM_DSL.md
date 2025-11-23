# Realm DSL：領域宣告、RPC 處理、Event 處理

> 本文檔說明 SwiftStateTree 的 Realm DSL 設計


## Realm DSL：領域宣告語法

### 使用場景

定義「這種領域」的：
- 對應 state type（StateTree）
- 最大玩家數（遊戲場景）
- Tick 間隔（遊戲場景）
- Idle timeout 等（遊戲場景）
- RPC/Event handler
- 之後還可以掛 service / DI

### 核心概念

**Realm（領域/土地）**：StateTree 生長的地方
- App 場景：`App` 是 `Realm` 的別名
- 功能模組：`Feature` 是 `Realm` 的別名

### 語法示例

```swift
// 使用 Realm（核心名稱）
let matchRealm = Realm("match-3", using: GameStateTree.self) {
    Config {
        MaxPlayers(4)
        Tick(every: .milliseconds(100))
        IdleTimeout(.seconds(60))
    }
    
    // 定義允許的 ClientEvent（只限制 Client->Server）
    AllowedClientEvents {
        ClientEvent.playerReady
        ClientEvent.heartbeat
        ClientEvent.uiInteraction
    }
    
    // RPC 處理：混合模式（簡單的用獨立 handler，複雜的用統一 handler）
    RPC(GameRPC.getPlayerHand) { state, id, ctx -> RPCResponse in
        return .success(.hand(state.hands[id]?.cards ?? []))
    }
    
    RPC(GameRPC.self) { state, rpc, ctx -> RPCResponse in
        switch rpc {
        case .join(let id, let name):
            state.players[id] = PlayerState(name: name, hpCurrent: 100, hpMax: 100)
            state.hands[id] = HandState(ownerID: id, cards: [])
            let snapshot = syncEngine.snapshot(for: id, from: state)
            await ctx.sendEvent(.fromServer(.stateUpdate(snapshot)), to: .all)
            return .success(.joinResult(JoinResponse(realmID: ctx.realmID, state: snapshot)))
        default:
            return await handleOtherRPC(&state, rpc, ctx)
        }
    }
    
    // Event 處理：混合模式（簡單的用獨立 handler，複雜的用統一 handler）
    On(ClientEvent.heartbeat) { state, timestamp, ctx in
        state.playerLastActivity[ctx.playerID] = timestamp
    }
    
    On(GameEvent.self) { state, event, ctx in
        switch event {
        case .fromClient(.playerReady(let id)):
            await handlePlayerReady(&state, id, ctx)
        case .fromClient(.uiInteraction(let id, let action)):
            analytics.track(id, action: action)
        default:
            break
        }
    }
}
```

### Realm DSL 元件（設計概念）

```swift
public protocol RealmNode {}

public struct ConfigNode: RealmNode {
    public var maxPlayers: Int?
    public var tickInterval: Duration?
    public var idleTimeout: Duration?
    // 注意：baseURL 和 webSocketURL 已移除
    // 網路層細節應該在 Transport 層處理，而不是在 StateTree/Realm 層
}

// RPC 節點：支援統一 RPC 型別或特定 RPC case
public struct RPCNode<C>: RealmNode {
    public let handler: (inout StateTree, C, RealmContext) async -> RPCResponse
}

// 特定 RPC case 的節點（用於簡單的 RPC）
public struct SpecificRPCNode<C>: RealmNode {
    public let handler: (inout StateTree, C, RealmContext) async -> RPCResponse
}

// Event 節點：支援統一 Event 型別或特定 ClientEvent case
public struct OnEventNode<E>: RealmNode {
    public let handler: (inout StateTree, E, RealmContext) async -> Void
}

// 特定 ClientEvent case 的節點（用於簡單的 Event）
public struct OnSpecificEventNode<E>: RealmNode {
    public let handler: (inout StateTree, E, RealmContext) async -> Void
}
```

配合 `@resultBuilder`：

```swift
@resultBuilder
public enum RealmDSL {
    public static func buildBlock(_ components: RealmNode...) -> [RealmNode] {
        components
    }
}

public struct RealmDefinition<State> {
    public let id: String
    public let nodes: [RealmNode]
}

// 核心函數：Realm
public func Realm<State>(
    _ id: String,
    using stateType: State.Type,
    @RealmDSL _ content: () -> [RealmNode]
) -> RealmDefinition<State> {
    RealmDefinition(id: id, nodes: content())
}

// 語義化別名
public typealias App<State> = Realm<State>
public typealias Feature<State> = Realm<State>
```

---

## RPC 處理：RPC DSL

### RPC 型別定義

```swift
enum GameRPC: Codable {
    // 查詢操作
    case getPlayerHand(PlayerID)
    case canAttack(PlayerID, target: PlayerID)
    case getRealmInfo
    
    // 需要結果的狀態修改
    case join(playerID: PlayerID, name: String)
    case drawCard(playerID: PlayerID)
    case attack(attacker: PlayerID, target: PlayerID, damage: Int)
}

enum RPCResponse: Codable {
    case success(RPCResultData)
    case failure(String)
}

enum RPCResultData: Codable {
    case joinResult(JoinResponse)
    case hand([Card])
    case card(Card)
    case realmInfo(RealmInfo)
    case empty
}

struct JoinResponse: Codable {
    let realmID: String
    let state: StateSnapshot?  // 可選：用於 late join
}
```

### RPC DSL 寫法（混合模式）

為了避免 handler 過於肥大，支援兩種寫法：

#### 方式 1：針對特定 RPC 的獨立 Handler（推薦用於簡單邏輯）

```swift
// 使用 Realm（核心名稱）
let matchRealm = Realm("match-3", using: GameStateTree.self) {
    Config { ... }
    
    // 簡單的查詢 RPC：用獨立 handler
    RPC(GameRPC.getPlayerHand) { state, id, ctx -> RPCResponse in
        return .success(.hand(state.hands[id]?.cards ?? []))
    }
    
    RPC(GameRPC.canAttack) { state, (attacker, target), ctx -> RPCResponse in
        guard let attackerState = state.players[attacker],
              let targetState = state.players[target] else {
            return .failure("Player not found")
        }
        let canAttack = attackerState.hpCurrent > 0 && targetState.hpCurrent > 0
        return .success(.empty)  // 或定義 CanAttackResponse
    }
    
    // 複雜的 RPC：用統一 handler 或提取到函數
    RPC(GameRPC.join) { state, (id, name), ctx -> RPCResponse in
        return await handleJoin(&state, id, name, ctx)
    }
}
```

#### 方式 2：統一的 RPC Handler（適合複雜邏輯或需要共享邏輯）

```swift
let matchRealm = Realm("match-3", using: GameStateTree.self) {
    Config { ... }
    
    // 複雜邏輯用統一 handler
    RPC(GameRPC.self) { state, rpc, ctx -> RPCResponse in
        return await handleRPC(&state, rpc, ctx)
    }
}

// 提取複雜邏輯到獨立函數
private func handleRPC(
    _ state: inout GameStateTree,
    _ rpc: GameRPC,
    _ ctx: RealmContext
) async -> RPCResponse {
    switch rpc {
    case .getPlayerHand(let id):
        return .success(.hand(state.hands[id]?.cards ?? []))
    case .join(let id, let name):
        return await handleJoin(&state, id, name, ctx)
    case .drawCard(let id):
        return await handleDrawCard(&state, id, ctx)
    case .attack(let attacker, let target, let damage):
        return await handleAttack(&state, attacker, target, damage, ctx)
    }
}

private func handleJoin(
    _ state: inout GameStateTree,
    _ id: PlayerID,
    _ name: String,
    _ ctx: RealmContext
) async -> RPCResponse {
    state.players[id] = PlayerState(name: name, hpCurrent: 100, hpMax: 100)
    state.hands[id] = HandState(ownerID: id, cards: [])
    let snapshot = syncEngine.snapshot(for: id, from: state)
    await ctx.sendEvent(.fromServer(.stateUpdate(snapshot)), to: .all)
    return .success(.joinResult(JoinResponse(realmID: ctx.realmID, state: snapshot)))
}
```

#### 方式 3：混合使用（推薦）

結合兩種方式的優點：

```swift
let matchRealm = Realm("match-3", using: GameStateTree.self) {
    Config { ... }
    
    // 簡單的查詢 RPC：用獨立 handler
    RPC(GameRPC.getPlayerHand) { state, id, ctx -> RPCResponse in
        return .success(.hand(state.hands[id]?.cards ?? []))
    }
    
    RPC(GameRPC.canAttack) { state, (attacker, target), ctx -> RPCResponse in
        guard state.players[attacker] != nil,
              state.players[target] != nil else {
            return .failure("Player not found")
        }
        return .success(.empty)
    }
    
    // 複雜的狀態修改 RPC：用統一 handler
    RPC(GameRPC.self) { state, rpc, ctx -> RPCResponse in
        switch rpc {
        case .join(let id, let name):
            return await handleJoin(&state, id, name, ctx)
        case .drawCard(let id):
            return await handleDrawCard(&state, id, ctx)
        case .attack(let attacker, let target, let damage):
            return await handleAttack(&state, attacker, target, damage, ctx)
        default:
            return .failure("Unknown RPC")
        }
    }
}
```

**建議**：
- 簡單的查詢 RPC（如 `getPlayerHand`、`canAttack`）→ 使用 `RPC(GameRPC.xxx)`
- 複雜的狀態修改 RPC（如 `join`、`drawCard`、`attack`）→ 使用 `RPC(GameRPC.self)` 或提取到函數
- 按邏輯分組處理（如查詢類、狀態修改類）

---

## Event 處理：On(Event) DSL

### Event 型別定義

```swift
// Client -> Server Event（需要限制，在 AllowedClientEvents 中定義）
enum ClientEvent: Codable {
    case playerReady(PlayerID)
    case heartbeat(timestamp: Date)
    case uiInteraction(PlayerID, action: String)
    // 更多 Client Event...
}

// Server -> Client Event（不受限制，Server 自由定義）
enum ServerEvent: Codable {
    case stateUpdate(StateSnapshot)
    case gameEvent(GameEventDetail)
    case systemMessage(String)
    // Server 可以自由定義和發送
}

enum GameEventDetail: Codable {
    case damage(from: PlayerID, to: PlayerID, amount: Int)
    case playerJoined(PlayerID, name: String)
    case playerReady(PlayerID)
    case gameStarted
}

// 統一的 Event 包裝（用於傳輸層）
enum GameEvent: Codable {
    case fromClient(ClientEvent)   // Client -> Server
    case fromServer(ServerEvent)   // Server -> Client
}
```

### Event DSL 寫法（混合模式）

為了避免 handler 過於肥大，支援兩種寫法：

#### 方式 1：針對特定 ClientEvent 的獨立 Handler（推薦用於簡單邏輯）

```swift
// 使用 Realm（核心名稱）
let matchRealm = Realm("match-3", using: GameStateTree.self) {
    Config { ... }
    
    AllowedClientEvents {
        ClientEvent.playerReady
        ClientEvent.heartbeat
        ClientEvent.uiInteraction
        ClientEvent.playCard
        ClientEvent.discardCard
    }
    
    // 簡單的 Event 用獨立 handler（避免 switch 過大）
    On(ClientEvent.heartbeat) { state, timestamp, ctx in
        // 更新玩家最後活動時間
        state.playerLastActivity[ctx.playerID] = timestamp
    }
    
    On(ClientEvent.uiInteraction) { state, (id, action), ctx in
        // 記錄 UI 事件
        analytics.track(id, action: action)
    }
    
    // 複雜的 Event 可以用完整 handler 或提取到函數
    On(ClientEvent.playerReady) { state, id, ctx in
        await handlePlayerReady(&state, id, ctx)
    }
}
```

#### 方式 2：統一的 GameEvent Handler（適合複雜邏輯或需要共享邏輯）

```swift
let matchRealm = Realm("match-3", using: GameStateTree.self) {
    Config { ... }
    
    AllowedClientEvents {
        ClientEvent.playerReady
        ClientEvent.heartbeat
        ClientEvent.uiInteraction
        ClientEvent.playCard
        ClientEvent.discardCard
    }
    
    // 複雜邏輯用統一 handler
    On(GameEvent.self) { state, event, ctx in
        switch event {
        case .fromClient(let clientEvent):
            await handleClientEvent(&state, clientEvent, ctx)
        case .fromServer:
            // ServerEvent 不應該從 Client 收到
            break
        }
    }
}

// 提取複雜邏輯到獨立函數
private func handleClientEvent(
    _ state: inout GameStateTree,
    _ event: ClientEvent,
    _ ctx: RealmContext
) async {
    switch event {
    case .playerReady(let id):
        await handlePlayerReady(&state, id, ctx)
    case .heartbeat(let timestamp):
        state.playerLastActivity[ctx.playerID] = timestamp
    case .uiInteraction(let id, let action):
        analytics.track(id, action: action)
    case .playCard(let id, let card):
        await handlePlayCard(&state, id, card, ctx)
    case .discardCard(let id, let card):
        await handleDiscardCard(&state, id, card, ctx)
    }
}

private func handlePlayerReady(
    _ state: inout GameStateTree,
    _ id: PlayerID,
    _ ctx: RealmContext
) async {
    state.readyPlayers.insert(id)
    await ctx.sendEvent(.fromServer(.gameEvent(.playerReady(id))), to: .all)
    if state.readyPlayers.count == state.players.count {
        state.round = 1
        await ctx.sendEvent(.fromServer(.gameEvent(.gameStarted)), to: .all)
    }
}
```

#### 方式 3：混合使用（推薦）

結合兩種方式的優點：

```swift
let matchRealm = Realm("match-3", using: GameStateTree.self) {
    Config { ... }
    
    AllowedClientEvents {
        ClientEvent.playerReady
        ClientEvent.heartbeat
        ClientEvent.uiInteraction
        ClientEvent.playCard
        ClientEvent.discardCard
    }
    
    // 簡單的 Event：用獨立 handler
    On(ClientEvent.heartbeat) { state, timestamp, ctx in
        state.playerLastActivity[ctx.playerID] = timestamp
    }
    
    On(ClientEvent.uiInteraction) { state, (id, action), ctx in
        analytics.track(id, action: action)
    }
    
    // 複雜的 Event：用統一 handler 或提取到函數
    On(GameEvent.self) { state, event, ctx in
        switch event {
        case .fromClient(.playerReady(let id)):
            await handlePlayerReady(&state, id, ctx)
        case .fromClient(.playCard(let id, let card)):
            await handlePlayCard(&state, id, card, ctx)
        case .fromClient(.discardCard(let id, let card)):
            await handleDiscardCard(&state, id, card, ctx)
        default:
            break
        }
    }
}
```

**建議**：
- 簡單的 Event（如 `heartbeat`、`uiInteraction`）→ 使用 `On(ClientEvent.xxx)`
- 複雜的 Event（如 `playerReady`、`playCard`）→ 使用 `On(GameEvent.self)` 或提取到函數
- 按邏輯分組處理（如遊戲邏輯、系統事件）

### Server 推送 Event

在 RPC handler 或內部邏輯中，Server 可以自由推送 ServerEvent（**不受 AllowedClientEvents 限制**）：

```swift
// 在任何 handler 中，Server 可以自由發送 ServerEvent
await ctx.sendEvent(.fromServer(.stateUpdate(snapshot)), to: .all)
await ctx.sendEvent(.fromServer(.gameEvent(.damage(from: attacker, to: target, amount: 10))), to: .all)
await ctx.sendEvent(.fromServer(.systemMessage("Private message")), to: .player(playerID))

// 不需要在 AllowedClientEvents 中定義這些 ServerEvent
```

### RealmContext（提供 sendEvent / service / random 等）

**設計原則**：RealmContext **不應該**知道 Transport 的存在，WebSocket 細節不應該暴露到 StateTree 層。

**設計模式**：RealmContext 採用 **Request-scoped Context** 模式，類似 NestJS 的 Request Context。

#### 類似 NestJS Request Context

RealmContext 的設計概念類似 NestJS 的 Request Context：

| 特性 | NestJS Request Context | StateTree RealmContext |
|------|----------------------|----------------------|
| **建立時機** | 每個 HTTP 請求 | 每個 RPC/Event 請求 |
| **生命週期** | 請求開始 → 請求結束 | 請求開始 → 請求結束 |
| **包含資訊** | user、params、headers、ip 等 | playerID、clientID、sessionID、realmID 等 |
| **傳遞方式** | Dependency Injection | 作為參數傳遞給 handler |
| **釋放時機** | 請求處理完成後 | 請求處理完成後 |

**關鍵點**：
- ✅ **請求級別**：每次 RPC/Event 請求建立一個新的 RealmContext
- ✅ **不持久化**：處理完成後釋放，不保留在記憶體中
- ✅ **資訊集中**：請求相關資訊（playerID、clientID、sessionID）集中在 context 中
- ✅ **請求隔離**：每個請求有獨立的 context，不會互相干擾

```swift
// ✅ 正確：RealmContext 不包含 Transport
public struct RealmContext {
    public let realmID: String
    public let playerID: PlayerID      // 帳號識別（用戶身份）
    public let clientID: ClientID      // 裝置識別（客戶端實例，應用端提供）
    public let sessionID: SessionID    // 會話識別（動態生成，用於追蹤）
    public let services: RealmServices  // 服務抽象，不依賴 HTTP
    
    // ❌ 移除：public let transport: GameTransport
    
    // ✅ 推送 Event（透過閉包委派，不暴露 Transport）
    public func sendEvent(_ event: GameEvent, to target: EventTarget) async {
        // 實作在 Runtime 層（RealmActor），不暴露 Transport 細節
        await sendEventHandler(event, target)
    }
    
    // ✅ 透過閉包委派，不暴露 Transport
    private let sendEventHandler: (GameEvent, EventTarget) async -> Void
    
    internal init(
        realmID: String,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID,
        services: RealmServices,
        sendEventHandler: @escaping (GameEvent, EventTarget) async -> Void
    ) {
        self.realmID = realmID
        self.playerID = playerID
        self.clientID = clientID
        self.sessionID = sessionID
        self.services = services
        self.sendEventHandler = sendEventHandler
    }
}

enum EventTarget {
    case all
    case player(PlayerID)      // 發送給該 playerID 的所有連接（所有裝置/標籤頁）
    case client(ClientID)       // 發送給特定 clientID（單一裝置的所有標籤頁）
    case session(SessionID)     // 發送給特定 sessionID（單一連接）
    case players([PlayerID])
}

// 三層識別系統
struct PlayerID: Hashable, Codable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
}

struct ClientID: Hashable, Codable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
}

struct SessionID: Hashable, Codable {
    let rawValue: String
    init(_ rawValue: String) { self.rawValue = rawValue }
}
```

#### RealmContext 的生命週期

**重要**：RealmContext 不是「每個玩家有一個」，而是「每次請求建立一個」。

```swift
// 範例：Alice 發送多個 RPC

// 請求 1：Alice 發送 join RPC
// ├─ 建立 RealmContext #1
// │  ├─ playerID: "alice-123"
// │  ├─ clientID: "device-mobile-001"
// │  └─ sessionID: "session-001"
// └─ 處理完成後，RealmContext #1 被釋放

// 請求 2：Alice 發送 attack RPC
// ├─ 建立 RealmContext #2
// │  ├─ playerID: "alice-123"      (相同)
// │  ├─ clientID: "device-mobile-001" (相同)
// │  └─ sessionID: "session-001"    (相同)
// └─ 處理完成後，RealmContext #2 被釋放
```

**設計要點**：
1. **請求級別**：每次 RPC/Event 請求建立一個新的 RealmContext
2. **不持久化**：處理完成後釋放，不保留在記憶體中
3. **輕量級**：只包含該請求需要的資訊
4. **請求隔離**：每個請求有獨立的 context，不會互相干擾

// 服務抽象（不依賴 HTTP 細節）
public struct RealmServices {
    public let timelineService: TimelineService?
    public let userService: UserService?
    // ... 其他服務（可選）
}

// 服務協議（不依賴 HTTP）
protocol TimelineService {
    func fetch(page: Int) async throws -> [Post]
}

// 實作時可以選擇 HTTP、gRPC、或其他方式
// 這些實作細節在 Transport 層注入，不在 Realm 定義中
struct HTTPTimelineService: TimelineService {
    let baseURL: String
    func fetch(page: Int) async throws -> [Post] {
        // HTTP 實作細節在這裡
    }
}
```

---

