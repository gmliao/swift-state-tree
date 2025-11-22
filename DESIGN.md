# SwiftStateTree DSL 設計草案 v0.2

> 單一 StateTree + 同步規則 + Room DSL

## 目標

- 用**一棵權威狀態樹 RoomTree** 表示整個房間的遊戲世界
- 用 **@Sync 規則** 控制伺服器要把哪些資料同步給誰
- 用 **Room DSL** 定義房型、指令處理、Tick 設定
- **UI 計算全部交給客戶端**，伺服器只送「邏輯資料」

---

## 目錄

1. [整體理念與資料流](#整體理念與資料流)
2. [通訊模式：RPC 與 Event](#通訊模式-rpc-與-event)
3. [StateTree：RoomTree 結構](#statetree-roomtree-結構)
4. [同步規則 DSL：@Sync / SyncPolicy](#同步規則-dsl-sync-syncpolicy)
5. [Room DSL：房型宣告語法](#room-dsl-房型宣告語法)
6. [RPC 處理：RPC DSL](#rpc-處理-rpc-dsl)
7. [Event 處理：On(Event) DSL](#event-處理-onevent-dsl)
8. [Runtime 大致結構：RoomActor + SyncEngine](#runtime-大致結構-roomactor-syncengine)
9. [端到端範例](#端到端範例)
10. [App 開發應用](#app-開發應用)
11. [跨平台實現：Android / 其他平台](#跨平台實現-android--其他平台)
12. [語法速查表](#語法速查表)

---

## 整體理念與資料流

### 伺服器只做三件事

1. **維護唯一真實狀態**：RoomTree
2. **根據指令（Command）更新這棵樹**
3. **根據同步規則 SyncPolicy**，為每個玩家產生專屬 JSON，同步出去

### 資料流

#### RPC 流程（Client -> Server，有 Response）

```
Client 發 RPC
  → Server RoomActor 處理
  → 更新 RoomTree（可選）
  → 返回 Response（可包含狀態快照，用於 late join）
  → Client 收到 Response
```

#### Event 流程（雙向，無 Response）

```
Client -> Server Event:
  Client 發 Event
    → Server RoomActor 處理
    → 可選：更新 RoomTree / 觸發邏輯

Server -> Client Event:
  Server 推送 Event
    → 所有相關 Client 接收
    → Client 更新本地狀態 / UI
```

#### 狀態同步流程

```
RoomTree 狀態變化
  → SyncEngine 依 @Sync 規則裁切
  → 為每個 Player 產生 JSON
  → 透過 Event 推送給 Client
  → Client 更新本地狀態
```

---

## 通訊模式：RPC 與 Event

### 兩種通訊模式

系統採用兩種通訊模式，各自有不同的語義和用途：

#### 1. RPC（Client -> Server only，有 Response）

**用途**：需要立即回饋的操作
- 查詢操作（取得手牌、驗證是否可攻擊）
- 需要驗證的狀態修改（加入房間、抽卡）
- 需要結果的操作（drawCard 需要知道抽到哪張卡）

**特點**：
- **單向**：只有 Client 可以發起 RPC 給 Server
- **有 Response**：Server 必須回傳結果
- **等待回應**：Client 發送後會等待 Server 回應
- **可選包含狀態**：Response 可以包含完整的狀態快照（用於 late join）

**範例**：

```swift
// Client 發起 RPC
let result = try await client.rpc(.join(playerID: id, name: "Alice"))
// result: JoinResponse { success: Bool, roomID: String, state: StateSnapshot? }

// Server 處理 RPC
func handle(_ rpc: GameRPC, from player: PlayerID) async -> RPCResponse {
    switch rpc {
    case .join(let id, let name):
        state.players[id] = PlayerState(...)
        let snapshot = syncEngine.snapshot(for: id, from: state)
        return .success(JoinResponse(roomID: roomID, state: snapshot))
    }
}
```

#### 2. Event（雙向，無 Response）

**用途**：通知、推送，不需要立即回應
- 狀態同步推送（Server -> Client）
- 遊戲事件（傷害、特效等）
- 系統訊息（Server -> Client）
- UI 事件通知（Client -> Server）
- 心跳（Client -> Server）

**特點**：
- **雙向**：Client 和 Server 都可以發送 Event
- **無 Response**：發送方不等待回應（fire-and-forget）
- **非阻塞**：接收方異步處理，不影響其他操作

**範例**：

```swift
// Client -> Server Event（必須是在 AllowedClientEvents 中定義的 ClientEvent）
client.sendEvent(.fromClient(.playerReady(playerID: id)))
client.sendEvent(.fromClient(.heartbeat(timestamp: now)))
client.sendEvent(.fromClient(.uiInteraction(playerID: id, action: "button_clicked")))

// Server -> Client Event（Server 可以自由發送，不受限制）
server.sendEvent(.fromServer(.stateUpdate(snapshot)))
server.sendEvent(.fromServer(.gameEvent(.damage(from: attacker, to: target))))
server.sendEvent(.fromServer(.systemMessage("Game started")))
```

### RPC Response 設計

RPC Response 可以選擇性包含狀態快照，用於特殊場景：

#### 包含狀態的場景

```swift
// Late Join：新加入的玩家需要完整狀態
case .join(let id, let name):
    state.players[id] = PlayerState(...)
    let snapshot = syncEngine.snapshot(for: id, from: state)
    return .success(JoinResponse(roomID: roomID, state: snapshot))  // 包含狀態

// 抽卡：需要立即知道抽到的卡
case .drawCard(let id):
    let card = state.deck.popLast()!
    state.hands[id]?.cards.append(card)
    return .success(DrawCardResponse(card: card, state: snapshot))  // 可選包含狀態
```

#### 不包含狀態的場景

```swift
// 查詢操作：只需要查詢結果
case .getPlayerHand(let id):
    return .success(GetHandResponse(cards: state.hands[id]?.cards ?? []))  // 不包含狀態

// 簡單修改：狀態變化透過 Event 推送
case .attack(let attacker, let target, let damage):
    // 修改狀態
    state.players[target]?.hpCurrent -= damage
    // 推送 Event（包含狀態更新）
    await ctx.sendEvent(.stateUpdate(snapshot), to: .all)
    // Response 只返回成功/失敗
    return .success(AttackResponse(success: true))
```

### Event 處理範圍

**設計決策**：採用 **選項 C（Room DSL 中定義）**

- `AllowedClientEvents` **只限制 Client->Server 的 Event**（`ClientEvent`）
- **Server->Client 的 Event 不受限制**（`ServerEvent`，因為是 Server 自己控制的）
- 在 Room DSL 中使用 `AllowedClientEvents` 定義允許的 `ClientEvent`

#### ClientEvent 分類

1. **遊戲邏輯 Event**（Server 需要處理並可能修改狀態）
   - `.playerReady(playerID)`: 玩家準備
   - `.playerAction(playerID, action)`: 玩家動作

2. **通知類 Event**（Server 只記錄，不修改狀態）
   - `.heartbeat(timestamp)`: 心跳
   - `.uiInteraction(playerID, action)`: UI 事件（用於分析）

#### ServerEvent 分類

Server 可以自由定義和發送 ServerEvent（不受 AllowedClientEvents 限制）：
- `.stateUpdate(snapshot)`: 狀態更新
- `.gameEvent(GameEventDetail)`: 遊戲事件
- `.systemMessage(String)`: 系統訊息

---

## StateTree：RoomTree 結構

### 目標

- 只一棵樹 `RoomTree` 表示整個房間狀態
- 不再額外定一個 `UIGameState` 在伺服器
- UI 專用計算丟給 Client

### 範例

```swift
// 單一權威狀態樹
@StateTree
struct RoomTree {
    // 所有玩家的公開狀態（血量、名字等），可以廣播給大家
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
    
    // 回合資訊，所有人都可以知道現在輪到誰
    @Sync(.broadcast)
    var turn: PlayerID?
    
    // 手牌：每個玩家只看得到自己的
    @Sync(.perPlayer(\.ownerID))
    var hands: [PlayerID: HandState] = [:]
    
    // 伺服器內部用，不同步給任何 Client
    @Sync(.serverOnly)
    var hiddenDeck: [Card] = []
    
    // 其他純邏輯狀態（例如倒數、回合數等）
    @Sync(.broadcast)
    var round: Int = 0
}

struct PlayerID: Hashable, Codable {
    let rawValue: String
}

struct PlayerState: Codable {
    var name: String
    var hpCurrent: Int
    var hpMax: Int
}

struct HandState: Codable {
    var ownerID: PlayerID
    var cards: [Card]
}

struct Card: Codable {
    let id: Int
    let suit: Int
    let rank: Int
}
```

> **RoomTree 是單一來源真相（single source of truth）。**  
> UI 只會收到「裁切後的 JSON 表示」。

---

## 同步規則 DSL：@Sync / SyncPolicy

### 基本概念

`@Sync` 會標在 `RoomTree` 的欄位上，定義這個欄位對同步引擎的策略。

### 範例

```swift
@Sync(.broadcast)
var players: [PlayerID: PlayerState]

@Sync(.serverOnly)
var hiddenDeck: [Card]

@Sync(.perPlayer(\.ownerID))
var hands: [PlayerID: HandState]
```

### SyncPolicy enum 初版設計

```swift
public enum SyncPolicy {
    /// 完全不對任何 client 同步（伺服器內部用）
    case serverOnly
    
    /// 同一份資料同步給所有 client
    case broadcast
    
    /// 依玩家 ID 過濾，例如手牌：
    /// - 某個集合元素有 ownerID
    /// - 只把 ownerID == 該 Player 的元素傳給他
    case perPlayer(PartialKeyPath<Any>)   // 實作時會用更嚴謹的型別
    
    /// 用一個 mask function 改寫值（例如只給卡牌背面）
    case masked((Any) -> Any)
    
    /// 完全客製：給 (playerID, rawValue) → 返回要不要同步 & 同步什麼
    case custom((PlayerID, Any) -> Any?)
}
```

> 實作上你會用泛型 + type erasure 處理，這邊先當設計理念。

### @Sync Attribute 草案

```swift
@propertyWrapper
public struct Sync<Value> {
    public let policy: SyncPolicy
    public var wrappedValue: Value
    
    public init(wrappedValue: Value, _ policy: SyncPolicy) {
        self.wrappedValue = wrappedValue
        self.policy = policy
    }
}
```

> （之後可以用 macro / 宏把這些自動展開）

---

## Room DSL：房型宣告語法

### 使用場景

定義「這種房間」的：
- 對應 state type（RoomTree）
- 最大玩家數
- Tick 間隔
- Idle timeout 等
- command handler
- 之後還可以掛 service / DI

### 語法示例

```swift
let matchRoom = Room("match-3", using: RoomTree.self) {
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
            return .success(.joinResult(JoinResponse(roomID: ctx.roomID, state: snapshot)))
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

### Room DSL 元件（設計概念）

```swift
public protocol RoomNode {}

public struct ConfigNode: RoomNode {
    public var maxPlayers: Int?
    public var tickInterval: Duration?
    public var idleTimeout: Duration?
}

// RPC 節點：支援統一 RPC 型別或特定 RPC case
public struct RPCNode<C>: RoomNode {
    public let handler: (inout RoomTree, C, RoomContext) async -> RPCResponse
}

// 特定 RPC case 的節點（用於簡單的 RPC）
public struct SpecificRPCNode<C>: RoomNode {
    public let handler: (inout RoomTree, C, RoomContext) async -> RPCResponse
}

// Event 節點：支援統一 Event 型別或特定 ClientEvent case
public struct OnEventNode<E>: RoomNode {
    public let handler: (inout RoomTree, E, RoomContext) async -> Void
}

// 特定 ClientEvent case 的節點（用於簡單的 Event）
public struct OnSpecificEventNode<E>: RoomNode {
    public let handler: (inout RoomTree, E, RoomContext) async -> Void
}
```

配合 `@resultBuilder`：

```swift
@resultBuilder
public enum RoomDSL {
    public static func buildBlock(_ components: RoomNode...) -> [RoomNode] {
        components
    }
}

public struct RoomDefinition<State> {
    public let id: String
    public let nodes: [RoomNode]
}

public func Room<State>(
    _ id: String,
    using stateType: State.Type,
    @RoomDSL _ content: () -> [RoomNode]
) -> RoomDefinition<State> {
    RoomDefinition(id: id, nodes: content())
}
```

---

## RPC 處理：RPC DSL

### RPC 型別定義

```swift
enum GameRPC: Codable {
    // 查詢操作
    case getPlayerHand(PlayerID)
    case canAttack(PlayerID, target: PlayerID)
    case getRoomInfo
    
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
    case roomInfo(RoomInfo)
    case empty
}

struct JoinResponse: Codable {
    let roomID: String
    let state: StateSnapshot?  // 可選：用於 late join
}
```

### RPC DSL 寫法（混合模式）

為了避免 handler 過於肥大，支援兩種寫法：

#### 方式 1：針對特定 RPC 的獨立 Handler（推薦用於簡單邏輯）

```swift
let matchRoom = Room("match-3", using: RoomTree.self) {
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
let matchRoom = Room("match-3", using: RoomTree.self) {
    Config { ... }
    
    // 複雜邏輯用統一 handler
    RPC(GameRPC.self) { state, rpc, ctx -> RPCResponse in
        return await handleRPC(&state, rpc, ctx)
    }
}

// 提取複雜邏輯到獨立函數
private func handleRPC(
    _ state: inout RoomTree,
    _ rpc: GameRPC,
    _ ctx: RoomContext
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
    _ state: inout RoomTree,
    _ id: PlayerID,
    _ name: String,
    _ ctx: RoomContext
) async -> RPCResponse {
    state.players[id] = PlayerState(name: name, hpCurrent: 100, hpMax: 100)
    state.hands[id] = HandState(ownerID: id, cards: [])
    let snapshot = syncEngine.snapshot(for: id, from: state)
    await ctx.sendEvent(.fromServer(.stateUpdate(snapshot)), to: .all)
    return .success(.joinResult(JoinResponse(roomID: ctx.roomID, state: snapshot)))
}
```

#### 方式 3：混合使用（推薦）

結合兩種方式的優點：

```swift
let matchRoom = Room("match-3", using: RoomTree.self) {
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
let matchRoom = Room("match-3", using: RoomTree.self) {
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
let matchRoom = Room("match-3", using: RoomTree.self) {
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
    _ state: inout RoomTree,
    _ event: ClientEvent,
    _ ctx: RoomContext
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
    _ state: inout RoomTree,
    _ id: PlayerID,
    _ ctx: RoomContext
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
let matchRoom = Room("match-3", using: RoomTree.self) {
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

### RoomContext（提供 sendEvent / service / random 等）

```swift
public struct RoomContext {
    public let roomID: String
    public let services: RoomServices
    public let transport: GameTransport
    
    // 推送 Event（替代原本的 broadcast/send）
    public func sendEvent(_ event: GameEvent, to target: EventTarget) async {
        switch target {
        case .all:
            await transport.broadcast(event, in: roomID)
        case .player(let id):
            await transport.send(event, to: id, in: roomID)
        case .players(let ids):
            for id in ids {
                await transport.send(event, to: id, in: roomID)
            }
        }
    }
}

enum EventTarget {
    case all
    case player(PlayerID)
    case players([PlayerID])
}
```

---

## Runtime 大致結構：RoomActor + SyncEngine

### RoomActor（概念）

```swift
actor RoomActor {
    private var state: RoomTree
    private let def: RoomDefinition<RoomTree>
    private let syncEngine: SyncEngine
    private let ctx: RoomContext
    
    init(definition: RoomDefinition<RoomTree>, context: RoomContext) {
        self.def = definition
        self.state = RoomTree()
        self.syncEngine = SyncEngine()
        self.ctx = context
    }
    
    // 處理 RPC（Client -> Server）
    func handleRPC(_ rpc: GameRPC, from player: PlayerID) async -> RPCResponse {
        // 從 def.nodes 找 RPCNode<GameRPC>，執行 handler
        guard let rpcNode = findRPCNode(rpc) else {
            return .failure("Unknown RPC type")
        }
        return await rpcNode.handler(&state, rpc, ctx)
    }
    
    // 處理 Event（雙向）
    func handleEvent(_ event: GameEvent, from player: PlayerID?) async {
        // 從 def.nodes 找 OnEventNode<GameEvent>，執行 handler
        guard let eventNode = findEventNode(event) else {
            return  // 未知的 Event 類型，忽略
        }
        await eventNode.handler(&state, event, ctx)
    }
    
    // 內部觸發狀態同步（例如 Tick 或狀態變化後）
    func syncState() async {
        let players = Array(state.players.keys)
        for pid in players {
            let snapshot = try syncEngine.snapshot(for: pid, from: state)
            await ctx.sendEvent(.stateUpdate(snapshot), to: .player(pid))
        }
    }
}
```

### SyncEngine（概念）

```swift
struct SyncEngine {
    func snapshot(for player: PlayerID, from tree: RoomTree) throws -> Data {
        // 1. 反射 / macro 生成的 Metadata：知道每個欄位的 SyncPolicy
        // 2. 逐欄位根據 policy 過濾：
        //    - serverOnly → 忽略
        //    - broadcast → 原值
        //    - perPlayer → 過濾 ownerID == player
        //    - masked/custom → 呼叫對應函式
        // 3. 組出一個 Codable 的中介 struct（或 JSON object）
        // 4. encode 成 JSON / MsgPack 等
        Data()
    }
}
```

---

## 端到端範例

### 範例 1：玩家加入（RPC + Event，包含 late join）

#### 流程

1. **Client A 發送 RPC**：`.join(playerID: "A", name: "Alice")`

2. **Server 處理 RPC**：
   ```swift
   case .join(let id, let name):
       state.players[id] = PlayerState(name: name, hpCurrent: 100, hpMax: 100)
       state.hands[id] = HandState(ownerID: id, cards: [])
       let snapshot = syncEngine.snapshot(for: id, from: state)
       await ctx.sendEvent(.stateUpdate(snapshot), to: .all)
       return .success(.joinResult(JoinResponse(roomID: ctx.roomID, state: snapshot)))
   ```

3. **Client A 收到 RPC Response**：
   - 包含完整狀態快照（late join 使用）
   - Client A 立即更新本地狀態，無需等待 Event

4. **所有 Client 收到 Event**：
   - `.stateUpdate(snapshot)` 包含裁切後的狀態
   - 其他玩家看到 A 加入

5. **SyncEngine.snapshot(for: "A", from: state)** 的裁切邏輯：
   - `players`：broadcast → 全部輸出
   - `hands`：perPlayer(ownerID) → 只輸出 A 的
   - `hiddenDeck`：serverOnly → 不輸出

### 範例 2：攻擊操作（RPC 不包含狀態，透過 Event 推送）

#### 流程

1. **Client A 發送 RPC**：`.attack(attacker: "A", target: "B", damage: 10)`

2. **Server 處理 RPC**：
   ```swift
   case .attack(let attacker, let target, let damage):
       state.players[target]?.hpCurrent -= damage
       let snapshot = syncEngine.snapshot(for: attacker, from: state)
       await ctx.sendEvent(.stateUpdate(snapshot), to: .all)
       await ctx.sendEvent(.gameEvent(.damage(from: attacker, to: target, amount: damage)), to: .all)
       return .success(.empty)  // 不包含狀態，透過 Event 取得
   ```

3. **Client A 收到 RPC Response**：
   - 只是 `.success(.empty)`
   - 知道操作成功，等待 Event 獲取狀態更新

4. **所有 Client 收到兩個 Event**：
   - `.stateUpdate(snapshot)`：更新狀態（B 的血量減少）
   - `.gameEvent(.damage(...))`：觸發傷害動畫、音效等

### 範例 3：玩家準備（Event 雙向）

#### 流程

1. **Client A 發送 Event**：`.playerReady(playerID: "A")`

2. **Server 處理 Event**：
   ```swift
   case .playerReady(let id):
       state.readyPlayers.insert(id)
       await ctx.sendEvent(.gameEvent(.playerReady(id)), to: .all)
       // 如果所有人都準備好，開始遊戲
       if state.readyPlayers.count == state.players.count {
           state.round = 1
           await ctx.sendEvent(.gameEvent(.gameStarted), to: .all)
       }
   ```

3. **所有 Client 收到 Event**：
   - `.gameEvent(.playerReady("A"))`：UI 顯示 A 已準備
   - 如果所有人都準備好：`.gameEvent(.gameStarted)`：開始遊戲

### 範例 4：Late Join 場景

#### 場景

玩家在遊戲進行中才加入，需要立即取得完整狀態。

#### 流程

1. **Client 發送 RPC**：`.join(playerID: "C", name: "Charlie")`

2. **Server 處理**：
   ```swift
   case .join(let id, let name):
       state.players[id] = PlayerState(...)
       // 生成完整的狀態快照（包含所有可見資料）
       let snapshot = syncEngine.snapshot(for: id, from: state)
       await ctx.sendEvent(.stateUpdate(snapshot), to: .all)
       // Response 包含完整狀態，Client C 可以立即同步
       return .success(.joinResult(JoinResponse(roomID: ctx.roomID, state: snapshot)))
   ```

3. **Client C 收到 Response**：
   ```swift
   let response = try await client.rpc(.join(...))
   if case .success(.joinResult(let joinResponse)) = response,
      let snapshot = joinResponse.state {
       // 立即更新本地狀態（late join）
       updateLocalState(snapshot)
   }
   ```

### Client 端狀態管理範例

```swift
// Client (SwiftUI 例)
class GameClient: ObservableObject {
    @Published var localState: StateSnapshot?
    
    func handleEvent(_ event: GameEvent) {
        switch event {
        case .stateUpdate(let snapshot):
            localState = snapshot  // 更新本地狀態
        case .gameEvent(let detail):
            handleGameEvent(detail)  // 觸發動畫、音效
        }
    }
    
    // UI 計算
    var playerViewStates: [PlayerViewState] {
        localState?.players.map { PlayerViewState(from: $0) } ?? []
    }
}

struct PlayerViewState {
    let name: String
    let hpText: String
    let hpProgress: Double
    let isLowHP: Bool
    
    init(from state: PlayerState) {
        let percent = Double(state.hpCurrent) / Double(state.hpMax)
        self.name = state.name
        self.hpText = "\(state.hpCurrent) / \(state.hpMax)"
        self.hpProgress = percent
        self.isLowHP = percent < 0.3
    }
}
```

---

## App 開發應用

### 適用場景

StateTree 設計不僅適用於遊戲伺服器，也非常適合 App 開發，特別是：

- **即時推送類型的 App**：SNS（Twitter、Facebook）、即時通訊（WhatsApp、Telegram）、協作工具（Slack、Discord）
- **需要狀態同步的 App**：雲端筆記（Notion）、任務管理（Todoist）、雲端儲存（Dropbox）
- **複雜狀態管理的 App**：電商 App、社交 App、協作工具

### 核心優勢

1. **單一狀態樹**：取代 Redux/Vuex/TCA，統一管理所有狀態
2. **聲明式同步規則**：不需要寫分散的同步邏輯
3. **清晰的通訊模式**：RPC（API 呼叫）+ Event（即時推送）
4. **型別安全的 DSL**：編譯時檢查，避免執行時錯誤

### SNS App 完整範例

#### 狀態樹定義

```swift
@StateTree
struct SNSAppState {
    // 用戶資料（本地持久化 + 雲端同步）
    @Sync(.local(key: "user_profile"))
    @Sync(.cloud(endpoint: "/api/user"))
    var currentUser: User?
    
    // Timeline（快取 + 雲端同步）
    @Sync(.cache(ttl: .minutes(5)))
    @Sync(.cloud(endpoint: "/api/timeline"))
    var timeline: [Post] = []
    
    // 通知（即時推送，僅記憶體）
    @Sync(.memory)
    var notifications: [Notification] = []
    
    // 未讀數量（本地計算）
    @Sync(.memory)
    var unreadCount: Int {
        notifications.filter { !$0.isRead }.count
    }
    
    // 草稿（僅本地持久化）
    @Sync(.local(key: "drafts"))
    var drafts: [DraftPost] = []
    
    // UI 狀態（僅記憶體）
    @Sync(.memory)
    var uiState: UIState = UIState()
    
    // 連線狀態
    @Sync(.memory)
    var connectionStatus: ConnectionStatus = .disconnected
}

struct User: Codable {
    let id: String
    let username: String
    let avatar: URL?
    var followersCount: Int
    var followingCount: Int
}

struct Post: Codable, Identifiable {
    let id: String
    let authorID: String
    let content: String
    let createdAt: Date
    var likesCount: Int
    var commentsCount: Int
    var isLiked: Bool
}

struct Notification: Codable, Identifiable {
    let id: String
    let type: NotificationType
    let fromUser: User
    let postID: String?
    var isRead: Bool
    let createdAt: Date
}

enum NotificationType: Codable {
    case like(postID: String)
    case comment(postID: String)
    case follow
    case mention(postID: String)
}
```

#### RPC 定義（API 呼叫）

```swift
enum SNSRPC: Codable {
    // 查詢操作
    case fetchTimeline(page: Int)
    case fetchUserProfile(userID: String)
    case fetchPost(postID: String)
    
    // 狀態修改（需要立即回饋）
    case createPost(content: String)
    case likePost(postID: String)
    case unlikePost(postID: String)
    case followUser(userID: String)
    case unfollowUser(userID: String)
    case markNotificationAsRead(notificationID: String)
}
```

#### Event 定義（即時推送）

```swift
// Client -> Server Event
enum SNSClientEvent: Codable {
    case viewPost(postID: String)        // 追蹤用戶行為
    case scrollTimeline(position: Int)   // 分析用
    case heartbeat
}

// Server -> Client Event（即時推送）
enum SNSServerEvent: Codable {
    case newPost(Post)                   // 新貼文出現
    case postUpdated(Post)               // 貼文被更新（例如按讚數變化）
    case notification(Notification)      // 新通知
    case userOnline(userID: String)      // 用戶上線
    case userOffline(userID: String)     // 用戶下線
}

enum GameEvent: Codable {
    case fromClient(SNSClientEvent)
    case fromServer(SNSServerEvent)
}
```

#### App 定義（DSL）

```swift
let snsApp = App("sns-app", using: SNSAppState.self) {
    Config {
        BaseURL("https://api.snsapp.com")
        WebSocketURL("wss://realtime.snsapp.com")
        CachePolicy(.expiresAfter(.minutes(5)))
    }
    
    AllowedClientEvents {
        SNSClientEvent.viewPost
        SNSClientEvent.scrollTimeline
        SNSClientEvent.heartbeat
    }
    
    // ========== RPC 處理（API 呼叫） ==========
    
    // 簡單的查詢：獨立 handler
    RPC(SNSRPC.fetchTimeline) { state, page, ctx -> RPCResponse in
        let posts = try await ctx.api.get("/timeline?page=\(page)")
        if page == 0 {
            state.timeline = posts  // 刷新
        } else {
            state.timeline.append(contentsOf: posts)  // 載入更多
        }
        return .success(.timeline(posts))
    }
    
    // 複雜的狀態修改：統一 handler
    RPC(SNSRPC.self) { state, rpc, ctx -> RPCResponse in
        switch rpc {
        case .createPost(let content):
            return await handleCreatePost(&state, content, ctx)
        case .likePost(let postID):
            return await handleLikePost(&state, postID, ctx)
        default:
            return await handleOtherRPC(&state, rpc, ctx)
        }
    }
    
    // ========== Event 處理（即時推送） ==========
    
    // 簡單的 Event：獨立 handler
    On(SNSClientEvent.heartbeat) { state, _, ctx in
        state.connectionStatus = .connected
    }
    
    // 複雜的 Event：統一 handler（處理即時推送）
    On(GameEvent.self) { state, event, ctx in
        switch event {
        case .fromServer(.newPost(let post)):
            // 新貼文推送到 Timeline
            state.timeline.insert(post, at: 0)
            if !ctx.isCurrentPage(.timeline) {
                showNotification("新貼文：\(post.content.prefix(50))...")
            }
            
        case .fromServer(.notification(let notification)):
            // 新通知推送到通知列表
            state.notifications.insert(notification, at: 0)
            updateBadge(count: state.unreadCount)
            
        case .fromClient(.viewPost(let postID)):
            // 追蹤用戶行為（分析用）
            analytics.track("view_post", params: ["post_id": postID])
            
        default:
            break
        }
    }
}

// Handler 函數
private func handleCreatePost(
    _ state: inout SNSAppState,
    _ content: String,
    _ ctx: AppContext
) async -> RPCResponse {
    let post = try await ctx.api.post("/posts", body: ["content": content])
    state.timeline.insert(post, at: 0)
    await ctx.sendEvent(.fromServer(.newPost(post)), to: .followers)
    return .success(.post(post))
}
```

### 與現有方案比較

#### vs Redux / Vuex

**Redux/Vuex：**
- 分散的 reducer 和 action
- 手動管理同步邏輯
- 需要額外的 middleware

**StateTree：**
- 單一狀態樹 + 聲明式同步規則
- DSL 定義處理邏輯，集中且型別安全
- 內建同步策略

#### vs TCA (The Composable Architecture)

**TCA：**
- 需要定義 State + Action + Reducer
- 處理邏輯分散在各個 reducer

**StateTree：**
- 更簡潔的 DSL
- 混合模式：簡單用獨立 handler，複雜用統一 handler

#### vs SwiftUI StateObject

**SwiftUI：**
- 需要手動管理 loading 狀態
- 狀態同步邏輯分散

**StateTree：**
- RPC 自動處理 loading 狀態
- 聲明式同步規則

### 其他應用場景

#### 即時通訊 App（WhatsApp、Telegram）

```swift
@StateTree
struct ChatAppState {
    @Sync(.local) var conversations: [Conversation]
    @Sync(.memory) var messages: [Message]
    @Sync(.memory) var onlineUsers: Set<UserID>
}

On(SNSServerEvent.newMessage) { state, message, ctx in
    state.messages.append(message)
    playNotificationSound()
}
```

#### 協作工具（Slack、Discord）

```swift
@StateTree
struct CollaborationAppState {
    @Sync(.cloud) var channels: [Channel]
    @Sync(.memory) var currentChannel: Channel?
    @Sync(.memory) var onlineUsers: Set<UserID>
}

On(SNSServerEvent.userOnline) { state, userID, ctx in
    state.onlineUsers.insert(userID)
}
```

---

## 跨平台實現：Android / 其他平台

### 實現可行性

StateTree 設計的核心理念是**語言無關的協議和架構**，可以跨平台實現：

1. **狀態樹結構**：可以用任何語言實現（Swift、Kotlin、TypeScript、Rust 等）
2. **同步規則**：`@Sync` 可以用 annotation/decorator 實現
3. **RPC + Event 協議**：使用標準的序列化格式（JSON、Protobuf、MsgPack）
4. **DSL**：每個語言可以用自己的方式實現（Kotlin DSL、TypeScript decorators）

### Android (Kotlin) 實現範例

#### 狀態樹定義

```kotlin
@StateTree
data class SNSAppState(
    // 用戶資料（本地持久化 + 雲端同步）
    @Sync(SyncPolicy.Local("user_profile"))
    @Sync(SyncPolicy.Cloud("/api/user"))
    var currentUser: User? = null,
    
    // Timeline（快取 + 雲端同步）
    @Sync(SyncPolicy.Cache(ttl = Duration.ofMinutes(5)))
    @Sync(SyncPolicy.Cloud("/api/timeline"))
    var timeline: List<Post> = emptyList(),
    
    // 通知（即時推送）
    @Sync(SyncPolicy.Memory)
    var notifications: List<Notification> = emptyList(),
    
    // UI 狀態
    @Sync(SyncPolicy.Memory)
    var uiState: UIState = UIState()
)

@StateTree
annotation class StateTree

enum class SyncPolicy {
    Local(val key: String),
    Cloud(val endpoint: String),
    Cache(val ttl: Duration),
    Memory
}
```

#### RPC 定義

```kotlin
sealed class SNSRPC {
    data class FetchTimeline(val page: Int) : SNSRPC()
    data class CreatePost(val content: String) : SNSRPC()
    data class LikePost(val postID: String) : SNSRPC()
}
```

#### DSL 定義（Kotlin DSL）

```kotlin
val snsApp = App("sns-app", SNSAppState::class) {
    config {
        baseURL = "https://api.snsapp.com"
        webSocketURL = "wss://realtime.snsapp.com"
    }
    
    allowedClientEvents {
        SNSClientEvent.ViewPost::class
        SNSClientEvent.Heartbeat::class
    }
    
    // RPC 處理
    rpc(SNSRPC.FetchTimeline::class) { state, rpc, ctx ->
        val posts = ctx.api.get("/timeline?page=${rpc.page}")
        state.timeline = if (rpc.page == 0) posts else state.timeline + posts
        RPCResponse.Success(RPCResultData.Timeline(posts))
    }
    
    // Event 處理
    on(SNSClientEvent.Heartbeat::class) { state, event, ctx ->
        state.connectionStatus = ConnectionStatus.Connected
    }
    
    on(GameEvent::class) { state, event, ctx ->
        when (event) {
            is GameEvent.FromServer -> when (event.serverEvent) {
                is SNSServerEvent.NewPost -> {
                    state.timeline = listOf(event.serverEvent.post) + state.timeline
                }
                is SNSServerEvent.Notification -> {
                    state.notifications = listOf(event.serverEvent.notification) + state.notifications
                }
            }
            is GameEvent.FromClient -> { /* 處理 client event */ }
        }
    }
}
```

### TypeScript / JavaScript 實現範例

#### 狀態樹定義

```typescript
@StateTree
class SNSAppState {
    @Sync({ local: { key: "user_profile" }, cloud: { endpoint: "/api/user" } })
    currentUser?: User;
    
    @Sync({ cache: { ttl: "5m" }, cloud: { endpoint: "/api/timeline" } })
    timeline: Post[] = [];
    
    @Sync({ memory: true })
    notifications: Notification[] = [];
}

function StateTree(target: any) { /* 實作 */ }
function Sync(options: SyncOptions) { /* 實作 */ }
```

#### DSL 定義

```typescript
const snsApp = App("sns-app", SNSAppState, {
    config: {
        baseURL: "https://api.snsapp.com",
        webSocketURL: "wss://realtime.snsapp.com"
    },
    
    allowedClientEvents: [
        SNSClientEvent.ViewPost,
        SNSClientEvent.Heartbeat
    ],
    
    rpc: {
        [SNSRPC.FetchTimeline]: async (state, rpc, ctx) => {
            const posts = await ctx.api.get(`/timeline?page=${rpc.page}`);
            state.timeline = rpc.page === 0 ? posts : [...state.timeline, ...posts];
            return { success: true, data: { timeline: posts } };
        }
    },
    
    events: {
        [SNSClientEvent.Heartbeat]: (state, event, ctx) => {
            state.connectionStatus = ConnectionStatus.Connected;
        },
        
        [GameEvent]: (state, event, ctx) => {
            if (event.type === "fromServer") {
                switch (event.serverEvent.type) {
                    case "newPost":
                        state.timeline = [event.serverEvent.post, ...state.timeline];
                        break;
                }
            }
        }
    }
});
```

### 跨平台實現的優勢

1. **統一的架構**：
   - 所有平台使用相同的設計理念
   - 狀態結構可以共享（使用相同的資料模型）
   - RPC/Event 協議可以跨平台

2. **協議層標準化**：
   - 序列化格式統一（JSON、Protobuf）
   - RPC 和 Event 的協議定義可以共享
   - 狀態樹結構可以跨平台共享

3. **開發體驗一致**：
   - iOS 和 Android 使用相似的 DSL
   - 學習成本低（一次學習，多平台適用）
   - 測試邏輯可以共享（狀態變化邏輯）

### 實現建議

1. **核心模組（語言無關）**：
   - 定義協議格式（JSON Schema、Protobuf）
   - 定義狀態樹結構（可以用 JSON Schema 描述）
   - 定義 RPC/Event 協議

2. **平台特定實現**：
   - **Swift**：使用 Swift Macros、Property Wrappers
   - **Kotlin**：使用 Kotlin DSL、Annotations
   - **TypeScript**：使用 Decorators、Type System

3. **共享層**：
   - 狀態模型定義（可以用 JSON Schema 生成）
   - RPC/Event 型別定義（可以用 Protobuf 生成）
   - 測試邏輯（狀態變化測試可以跨平台共享）

### 與現有跨平台方案比較

#### vs Flutter / React Native

**Flutter/RN：**
- 需要寫平台特定程式碼
- 狀態管理分散（Redux、MobX）

**StateTree：**
- 統一的架構設計
- 每個平台用原生語言實現（性能更好）
- 狀態管理集中且一致

#### vs KMM (Kotlin Multiplatform)

**KMM：**
- 共享業務邏輯
- UI 層還是需要平台特定

**StateTree：**
- 可以配合 KMM 使用
- 共享狀態樹定義和處理邏輯
- UI 層用各平台原生框架

---

## 語法速查表

### 1. StateTree + Sync

```swift
@StateTree
struct RoomTree {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState]
    
    @Sync(.perPlayer(\.ownerID))
    var hands: [PlayerID: HandState]
    
    @Sync(.serverOnly)
    var hiddenDeck: [Card]
}
```

### 2. Room 定義（混合模式）

```swift
let room = Room("match-3", using: RoomTree.self) {
    Config {
        MaxPlayers(4)
        Tick(every: .milliseconds(100))
    }
    
    AllowedClientEvents {
        ClientEvent.playerReady
        ClientEvent.heartbeat
        ClientEvent.uiInteraction
    }
    
    // RPC 處理：混合模式
    // 簡單的查詢：用獨立 handler
    RPC(GameRPC.getPlayerHand) { state, id, ctx -> RPCResponse in
        return .success(.hand(state.hands[id]?.cards ?? []))
    }
    
    // 複雜的狀態修改：用統一 handler
    RPC(GameRPC.self) { state, rpc, ctx -> RPCResponse in
        switch rpc {
        case .join(let id, let name):
            return await handleJoin(&state, id, name, ctx)
        // ...
        }
    }
    
    // Event 處理：混合模式
    // 簡單的 Event：用獨立 handler
    On(ClientEvent.heartbeat) { state, timestamp, ctx in
        state.playerLastActivity[ctx.playerID] = timestamp
    }
    
    // 複雜的 Event：用統一 handler
    On(GameEvent.self) { state, event, ctx in
        switch event {
        case .fromClient(.playerReady(let id)):
            await handlePlayerReady(&state, id, ctx)
        // ...
        }
    }
}
```

### 3. RPC 例子

```swift
enum GameRPC: Codable {
    case join(playerID: PlayerID, name: String)
    case drawCard(playerID: PlayerID)
    case attack(attacker: PlayerID, target: PlayerID, damage: Int)
    case getPlayerHand(PlayerID)
}
```

### 4. Event 例子

```swift
// Client -> Server Event（需要在 AllowedClientEvents 中定義）
enum ClientEvent: Codable {
    case playerReady(PlayerID)
    case heartbeat(timestamp: Date)
    case uiInteraction(PlayerID, action: String)
}

// Server -> Client Event（不受限制）
enum ServerEvent: Codable {
    case stateUpdate(StateSnapshot)
    case gameEvent(GameEventDetail)
    case systemMessage(String)
}

// 統一的 Event 包裝
enum GameEvent: Codable {
    case fromClient(ClientEvent)   // Client -> Server
    case fromServer(ServerEvent)   // Server -> Client
}
```

### 5. Context 介面（伺服端）

```swift
// 推送 Event
await ctx.sendEvent(.stateUpdate(snapshot), to: .all)
await ctx.sendEvent(.gameEvent(.damage(...)), to: .all)
await ctx.sendEvent(.systemMessage("xxx"), to: .player(playerID))
```

---

## Event 範圍限制設計決策

### 設計決策：採用選項 C（Room DSL 中定義）

**決定**：使用 Room DSL 中的 `AllowedClientEvents` 來限制 Client->Server Event。

**重要限制**：
- `AllowedClientEvents` **只限制 Client->Server 的 Event**（`ClientEvent`）
- **Server->Client 的 Event 不受限制**（因為是 Server 自己控制的）
- 需要在 Event 型別定義中明確區分 `ClientEvent` 和 `ServerEvent`

### Event 型別定義

首先需要將 Event 明確區分為兩種：

### Event 型別設計

```swift
// Client -> Server Event（需要限制）
enum ClientEvent: Codable {
    case playerReady(PlayerID)
    case heartbeat(timestamp: Date)
    case uiInteraction(PlayerID, action: String)
    // 更多 Client Event...
}

// Server -> Client Event（不受限制，Server 自己控制）
enum ServerEvent: Codable {
    case stateUpdate(StateSnapshot)
    case gameEvent(GameEventDetail)
    case systemMessage(String)
    // Server 可以自由定義和發送
}

// 統一的 Event 包裝（用於傳輸層）
enum GameEvent: Codable {
    case fromClient(ClientEvent)   // Client -> Server
    case fromServer(ServerEvent)   // Server -> Client
}
```

### Room DSL 定義（選項 C）

**範例：採用選項 C**

```swift
// Room DSL 中定義允許的 Client Event（只限制 Client->Server）
let matchRoom = Room("match-3", using: RoomTree.self) {
    Config {
        MaxPlayers(4)
        Tick(every: .milliseconds(100))
    }
    
    // 定義這個房間允許的 Client Event（只能指定 ClientEvent 類型）
    AllowedClientEvents {
        ClientEvent.playerReady
        ClientEvent.heartbeat
        ClientEvent.uiInteraction
        // 只有這些 ClientEvent 可以被 Client 發送到這個房間
        // ServerEvent 不受此限制（Server 可以自由發送）
    }
    
    // Event 處理（處理允許的 ClientEvent）
    On(GameEvent.self) { state, event, ctx in
        switch event {
        case .fromClient(let clientEvent):
            // 只會收到 AllowedClientEvents 中定義的 ClientEvent
            switch clientEvent {
            case .playerReady(let id):
                state.readyPlayers.insert(id)
                // Server 可以自由發送 ServerEvent
                await ctx.sendEvent(.fromServer(.gameEvent(.playerReady(id))), to: .all)
                
            case .heartbeat(let timestamp):
                // 更新心跳時間
                state.playerLastActivity[id] = timestamp
                
            case .uiInteraction(let id, let action):
                // 記錄 UI 事件
                analytics.track(id, action: action)
            }
            
        case .fromServer:
            // ServerEvent 不應該從 Client 收到（應該被傳輸層過濾）
            break
        }
    }
    
    // RPC 處理
    RPC(GameRPC.self) { state, rpc, ctx -> RPCResponse in
        // ...
    }
}

### DSL 實作概念

```swift
// DSL 實作：AllowedClientEvents 只接受 ClientEvent
protocol RoomNode {}

struct AllowedClientEventsNode: RoomNode {
    let allowedClientEvents: Set<ClientEventType>
    
    init(@AllowedClientEventsBuilder _ builder: () -> Set<ClientEventType>) {
        self.allowedClientEvents = builder()
    }
}

@resultBuilder
enum AllowedClientEventsBuilder {
    static func buildBlock(_ events: ClientEventType...) -> Set<ClientEventType> {
        Set(events)
    }
    
    // 只接受 ClientEvent 類型
    static func buildExpression(_ eventType: ClientEvent.Type) -> ClientEventType {
        ClientEventType(eventType)
    }
}

// Runtime 驗證（只驗證 ClientEvent）
actor RoomActor {
    private let allowedClientEvents: Set<ClientEventType>
    
    func handleEvent(_ event: GameEvent, from player: PlayerID) async throws {
        switch event {
        case .fromClient(let clientEvent):
            // 檢查 ClientEvent 是否在允許列表中
            guard allowedClientEvents.contains(ClientEventType(type(of: clientEvent))) else {
                throw EventError.notAllowed("ClientEvent type not allowed in this room")
            }
            // 處理允許的 ClientEvent
            await processClientEvent(clientEvent, from: player)
            
        case .fromServer:
            // ServerEvent 不應該從 Client 收到
            // 如果收到，可能是傳輸層錯誤
            throw EventError.invalidSource("ServerEvent should not come from client")
        }
    }
}
```

### 設計要點

1. **AllowedClientEvents 只限制 ClientEvent**
   - 只能列舉 `ClientEvent` 的類型
   - `ServerEvent` 不受限制（Server 自己控制）

2. **不同房型可以有不同的 ClientEvent 規則**
   ```swift
   // 卡牌遊戲房間
   let cardRoom = Room("card-game", using: CardRoomTree.self) {
       AllowedClientEvents {
           ClientEvent.playerReady
           ClientEvent.playCard
           ClientEvent.discardCard
       }
   }
   
   // 即時對戰房間
   let battleRoom = Room("realtime-battle", using: BattleRoomTree.self) {
       AllowedClientEvents {
           ClientEvent.playerReady
           ClientEvent.movementUpdate
           ClientEvent.skillCast
       }
   }
   ```

3. **Server 可以自由發送 ServerEvent**
   ```swift
   // 在任何 RPC 或 Event handler 中
   await ctx.sendEvent(.fromServer(.stateUpdate(snapshot)), to: .all)
   await ctx.sendEvent(.fromServer(.gameEvent(.damage(...))), to: .all)
   // 不需要在 AllowedClientEvents 中定義
   ```

### RPC Response 是否總是包含狀態？

**當前設計**：可選包含狀態（用於 late join 等場景）

**考慮**：
- 總是包含狀態：一致性高，但可能浪費頻寬
- 可選包含狀態：靈活，但需要明確的設計決策
- 永遠不包含狀態：統一透過 Event 推送，但 late join 需要額外處理

## 後續實作建議

### 模組拆分建議

#### Swift 版本

- **SwiftStateTreeCore**：RoomTree、@Sync、SyncPolicy、StateTree 核心
- **SwiftStateTreeServer**：RoomDefinition、RoomActor、SyncEngine、RPC/Event 處理、GameTransport
- **SwiftStateTreeClient**：Client SDK、狀態同步、RPC/Event 客戶端

#### 跨平台版本

- **StateTree Protocol**（語言無關）：協議定義、JSON Schema、Protobuf 定義
- **StateTree Swift**：Swift 實現（使用 Macros、Property Wrappers）
- **StateTree Kotlin**：Kotlin 實現（使用 DSL、Annotations）
- **StateTree TypeScript**：TypeScript 實現（使用 Decorators）

### 專案目錄結構建議

```
StateTree/
├── Protocol/              # 語言無關的協議定義
│   ├── schemas/           # JSON Schema
│   ├── protobuf/          # Protobuf 定義
│   └── docs/              # 協議文檔
├── Swift/                 # Swift 實現
│   ├── StateTreeCore/     # 核心模組
│   ├── StateTreeServer/   # 伺服器模組
│   └── StateTreeClient/   # 客戶端模組
├── Kotlin/                # Kotlin 實現
│   ├── state-tree-core/   # 核心模組
│   └── state-tree-dsl/    # DSL 模組
├── TypeScript/            # TypeScript 實現
│   ├── state-tree-core/   # 核心模組
│   └── state-tree-dsl/    # DSL 模組
└── Examples/              # 範例專案
    ├── GameServer/        # 遊戲伺服器範例
    └── SNSApp/            # SNS App 範例
```

### 開發順序建議

1. **Phase 1：核心設計**
   - 定義協議格式（JSON Schema / Protobuf）
   - 實作 Swift 版本的核心功能
   - 建立遊戲伺服器範例

2. **Phase 2：App 開發支援**
   - 實作 App 版本的同步策略（Local、Cloud、Cache）
   - 建立 SNS App 範例
   - 優化離線支援

3. **Phase 3：跨平台實現**
   - 實作 Kotlin 版本
   - 實作 TypeScript 版本
   - 確保協議層一致性

4. **Phase 4：優化和擴展**
   - 性能優化
   - 工具鏈（Code Generation、Linting）
   - 文檔和測試覆蓋率

