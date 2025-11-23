# SwiftStateTree DSL 設計草案 v0.2

> 單一 StateTree + 同步規則 + Realm DSL

## 目標

- 用**一棵權威狀態樹 StateTree** 表示整個領域的狀態
- 用 **@Sync 規則** 控制伺服器要把哪些資料同步給誰
- 用 **Realm DSL** 定義領域、指令處理、Tick 設定
- **UI 計算全部交給客戶端**，伺服器只送「邏輯資料」

---

## 目錄

1. [整體理念與資料流](#整體理念與資料流)
2. [通訊模式：RPC 與 Event](#通訊模式-rpc-與-event)
3. [StateTree：狀態樹結構](#statetree-狀態樹結構)
4. [同步規則 DSL：@Sync / SyncPolicy](#同步規則-dsl-sync-syncpolicy)
5. [Realm DSL：領域宣告語法](#realm-dsl-領域宣告語法)
6. [RPC 處理：RPC DSL](#rpc-處理-rpc-dsl)
7. [Event 處理：On(Event) DSL](#event-處理-onevent-dsl)
8. [Runtime 大致結構：RealmActor + SyncEngine](#runtime-大致結構-realmactor-syncengine)
9. [端到端範例](#端到端範例)
10. [語法速查表](#語法速查表)
11. [相關文檔](#相關文檔)

---

## 整體理念與資料流

### 伺服器只做三件事

1. **維護唯一真實狀態**：StateTree（狀態樹）
2. **根據指令（Command）更新這棵樹**
3. **根據同步規則 SyncPolicy**，為每個玩家產生專屬 JSON，同步出去

### 資料流

#### RPC 流程（Client -> Server，有 Response）

```
Client 發 RPC
  → Server RealmActor 處理
  → 更新 StateTree（可選）
  → 返回 Response（可包含狀態快照，用於 late join）
  → Client 收到 Response
```

#### Event 流程（雙向，無 Response）

```
Client -> Server Event:
  Client 發 Event
    → Server RealmActor 處理
    → 可選：更新 StateTree / 觸發邏輯

Server -> Client Event:
  Server 推送 Event
    → 所有相關 Client 接收
    → Client 更新本地狀態 / UI
```

#### 狀態同步流程

```
StateTree 狀態變化
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
// result: JoinResponse { success: Bool, realmID: String, state: StateSnapshot? }

// Server 處理 RPC
func handle(_ rpc: GameRPC, from player: PlayerID) async -> RPCResponse {
    switch rpc {
    case .join(let id, let name):
        state.players[id] = PlayerState(...)
        let snapshot = syncEngine.snapshot(for: id, from: state)
        return .success(JoinResponse(realmID: realmID, state: snapshot))
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
    return .success(JoinResponse(realmID: realmID, state: snapshot))  // 包含狀態

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

**設計決策**：採用 **選項 C（Realm DSL 中定義）**

- `AllowedClientEvents` **只限制 Client->Server 的 Event**（`ClientEvent`）
- **Server->Client 的 Event 不受限制**（`ServerEvent`，因為是 Server 自己控制的）
- 在 Realm DSL 中使用 `AllowedClientEvents` 定義允許的 `ClientEvent`

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

## StateTree：狀態樹結構

### 目標

- 只一棵樹 `StateTree` 表示整個領域狀態
- 不再額外定一個 `UIGameState` 在伺服器
- UI 專用計算丟給 Client

### 範例

```swift
// 單一權威狀態樹（遊戲場景範例）
@StateTree
struct GameStateTree {
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

> **StateTree 是單一來源真相（single source of truth）。**  
> UI 只會收到「裁切後的 JSON 表示」。

---

## 同步規則 DSL：@Sync / SyncPolicy

### 基本概念

`@Sync` 會標在 `StateTree` 的欄位上，定義這個欄位對同步引擎的策略。

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

## Realm DSL：領域宣告語法

### 使用場景

定義「這種領域」的：
- 對應 state type（StateTree）
- 最大玩家數（遊戲場景）
- Tick 間隔（遊戲場景）
- Idle timeout 等（遊戲場景）
- command handler
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
    public var baseURL: String?
    public var webSocketURL: String?
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

```swift
public struct RealmContext {
    public let realmID: String
    public let services: RealmServices
    public let transport: GameTransport
    
    // 推送 Event（替代原本的 broadcast/send）
    public func sendEvent(_ event: GameEvent, to target: EventTarget) async {
        switch target {
        case .all:
            await transport.broadcast(event, in: realmID)
        case .player(let id):
            await transport.send(event, to: id, in: realmID)
        case .players(let ids):
            for id in ids {
                await transport.send(event, to: id, in: realmID)
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

## Runtime 大致結構：RealmActor + SyncEngine

### RealmActor（概念）

```swift
actor RealmActor {
    private var state: StateTree
    private let def: RealmDefinition<StateTree>
    private let syncEngine: SyncEngine
    private let ctx: RealmContext
    
    init(definition: RealmDefinition<StateTree>, context: RealmContext) {
        self.def = definition
        self.state = StateTree()
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
    func snapshot(for player: PlayerID, from tree: StateTree) throws -> Data {
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
       return .success(.joinResult(JoinResponse(realmID: ctx.realmID, state: snapshot)))
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
       return .success(.joinResult(JoinResponse(realmID: ctx.realmID, state: snapshot)))
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

## 命名說明

### Realm vs App vs Feature

**核心概念**：`Realm`（領域/土地）是 StateTree 生長的地方

- **Realm**：核心名稱，通用於所有場景
- **App**：`Realm` 的別名，適合 App 場景
- **Feature**：`Realm` 的別名，適合功能模組場景

**使用建議**：
- 遊戲場景：使用 `Realm`
- App 場景：使用 `App` 或 `Realm`
- 功能模組：使用 `Feature` 或 `Realm`
- 通用場景：使用 `Realm`

**內部實作**：所有別名都指向 `Realm`，實作完全相同。

## 相關文檔

- **[APP_APPLICATION.md](./APP_APPLICATION.md)**：StateTree 在 App 開發中的應用
  - SNS App 完整範例
  - 與現有方案比較（Redux、MVVM、TCA）
  - 跨平台實現（Android/Kotlin、TypeScript）
  - 狀態同步方式詳解

---

## 語法速查表

### 1. StateTree + Sync

```swift
@StateTree
struct GameStateTree {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState]
    
    @Sync(.perPlayer(\.ownerID))
    var hands: [PlayerID: HandState]
    
    @Sync(.serverOnly)
    var hiddenDeck: [Card]
}
```

### 2. Realm 定義（混合模式）

```swift
// 使用 Realm（核心名稱）
let realm = Realm("match-3", using: GameStateTree.self) {
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

### 設計決策：採用選項 C（Realm DSL 中定義）

**決定**：使用 Realm DSL 中的 `AllowedClientEvents` 來限制 Client->Server Event。

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

### Realm DSL 定義（選項 C）

**範例：採用選項 C**

```swift
// Realm DSL 中定義允許的 Client Event（只限制 Client->Server）
let matchRealm = Realm("match-3", using: GameStateTree.self) {
    Config {
        MaxPlayers(4)
        Tick(every: .milliseconds(100))
    }
    
    // 定義這個領域允許的 Client Event（只能指定 ClientEvent 類型）
    AllowedClientEvents {
        ClientEvent.playerReady
        ClientEvent.heartbeat
        ClientEvent.uiInteraction
        // 只有這些 ClientEvent 可以被 Client 發送到這個領域
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
protocol RealmNode {}

struct AllowedClientEventsNode: RealmNode {
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
actor RealmActor {
    private let allowedClientEvents: Set<ClientEventType>
    
    func handleEvent(_ event: GameEvent, from player: PlayerID) async throws {
        switch event {
        case .fromClient(let clientEvent):
            // 檢查 ClientEvent 是否在允許列表中
            guard allowedClientEvents.contains(ClientEventType(type(of: clientEvent))) else {
                throw EventError.notAllowed("ClientEvent type not allowed in this realm")
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

2. **不同領域可以有不同的 ClientEvent 規則**
   ```swift
   // 卡牌遊戲領域
   let cardRealm = Realm("card-game", using: CardGameStateTree.self) {
       AllowedClientEvents {
           ClientEvent.playerReady
           ClientEvent.playCard
           ClientEvent.discardCard
       }
   }
   
   // 即時對戰領域
   let battleRealm = Realm("realtime-battle", using: BattleStateTree.self) {
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

- **SwiftStateTreeCore**：StateTree、@Sync、SyncPolicy、StateTree 核心
- **SwiftStateTreeServer**：RealmDefinition、RealmActor、SyncEngine、RPC/Event 處理、GameTransport
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

