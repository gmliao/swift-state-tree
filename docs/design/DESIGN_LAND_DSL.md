# Land DSL：領域宣告、Action 處理、Event 處理

> 本文檔說明 SwiftStateTree 的 Land DSL 設計


## 核心概念：StateTree vs Land

### 🌳 StateTree：世界本體

`StateTree` = 這個世界「長什麼樣子」：

- 有哪些資料（玩家、商品、白板、聊天…）
- 每個欄位的同步規則 `@Sync(...)`
- snapshot / diff / dirty tracking 都在這一層

它只是 **一個「世界的資料結構」＋「同步策略」**，  
還沒有說「這個世界開在哪裡？誰可以進來？怎麼玩？」

---

### 🎡 Land：這棵樹實際被開成「一個樂園」的地方

`Land` 是將 `StateTree` 實例化為一個可運行的「樂園實體」的配置。它的職責分為三個核心部分：

#### 1️⃣ 誰可以進來看這棵樹？（大門規則）

- 權限 / 身分 / playerID / role
- 是否允許加入？人數上限？
- 沒進來 = 根本看不到這棵樹的任何東西（連 Sync 都不開始）

👉 `Land` 管的是 **「這個樂園的大門怎麼管」**。

#### 2️⃣ 我提供哪些功能讓你操作這棵樹？（遊戲規則）

- 可以呼叫什麼 Action / Command：
  - `move`
  - `attack`
  - `sendMessage`
  - `addToCart`
- `OnJoin / OnLeave` 時要怎麼改樹
- `Tick` 的時候要怎麼推進樹
- 允許哪些 ClientEvent

👉 `Land` 決定 **「你在這個樂園裡可以玩哪些設施、按哪些按鈕，按了會怎麼改世界」**。

#### 3️⃣ 這個樂園的營業時間是什麼？（營業時間 / 生命週期管理）

**核心概念**：Land 的**生命週期管理（Lifetime Management）**，定義這個「樂園實體」何時開始、如何運行、何時結束。

**包含的決策**：

1. **何時建立這棵樹的 instance？（開園時機）**
   - 第一個人進來才開園？（Lazy initialization）
   - 系統啟動時就預先開好？（Eager initialization）
   - 定時建立？（Scheduled creation）
   - 基於條件觸發？（Condition-based creation）

2. **如何運行？（運行時配置）**
   - Tick 要不要一直跑？頻率多少？（例如：遊戲需要 100ms tick，聊天室不需要）
   - 要不要定期存檔？（Snapshot persistence）
   - 要不要記錄 replay / log？（Audit trail）
   - 是否需要狀態恢復機制？（State recovery）

3. **何時關園？（銷毀規則）**
   - 沒人了就自動銷毀？（Destroy when empty）
   - 結束後保留一段時間？（Retention period）
   - 要不要存到 DB（存檔）？（Persist on shutdown）
   - 是否需要優雅關閉流程？（Graceful shutdown）

**實際應用場景**：
- **遊戲房間**：第一人進入時建立，沒人後 5 分鐘自動銷毀，每 30 秒存檔
- **聊天室**：系統啟動時建立，常駐運行，不需要 tick，每小時記錄 log
- **白板協作**：第一人進入時建立，最後一人離開後保留 1 小時，然後自動銷毀
- **單人遊戲**：玩家登入時建立，登出時存檔並銷毀

👉 這就是 **「樂園的營業時間、關門規則、是否每天清場」**，也就是 **Land 的完整生命週期管理**。

---

### ✅ 一句話定義

> **StateTree = 樹長什麼樣（世界地圖 & 狀態），欄位級同步規則。**
>
> **Land = 這棵樹被開成一個「樂園實體」之後的：**
> - **大門規則**（誰能進、多少人）
> - **遊戲規則**（能做什麼、怎麼操作）
> - **營業時間**（生命週期管理：何時建立、如何運行、何時關閉、是否存檔）

---

## Land DSL：領域宣告語法

### 使用場景

定義「這種領域」的：
- 對應 state type（StateTree）
- 大門規則（誰可以進入、人數限制）
- 遊戲規則（可用的 Action/Event handler）
- 營業時間（Tick 間隔、生命週期管理、持久化策略）
- 之後還可以掛 service / DI

### 語義化別名

- **App 場景**：`App` 是 `Land` 的別名
- **功能模組**：`Feature` 是 `Land` 的別名

### 語法示例（現有版本）

```swift
// 使用 Land（核心名稱）
let matchLand = Land("match-3", using: GameStateTree.self) {
    // 1️⃣ 大門規則：誰可以進來（整合在 Config 中）
    Config {
        MaxPlayers(4)
        Tick(every: .milliseconds(100))  // ✅ Tick-based：自動批次更新
        IdleTimeout(.seconds(60))
    }
    
    // ✅ 可選：定義 Tick handler（每 tick 執行）
    // 簡單邏輯可以直接寫，複雜邏輯建議拆分成獨立函數
    OnTick { state, ctx in
        await handleTick(&state, ctx)
    }
    
    // 2️⃣ 遊戲規則：定義允許的 ClientEvent（只限制 Client->Server）
    AllowedClientEvents {
        ClientEvent.playerReady
        ClientEvent.heartbeat
        ClientEvent.uiInteraction
    }
    
    // 2️⃣ 遊戲規則：Action 處理（混合模式）
    Action(GameAction.getPlayerHand) { state, id, ctx -> ActionResult in
        return .success(.hand(state.hands[id]?.cards ?? []))
    }
    
    Action(GameAction.self) { state, action, ctx -> ActionResult in
        switch action {
        case .join(let id, let name):
            state.players[id] = PlayerState(name: name, hpCurrent: 100, hpMax: 100)
            state.hands[id] = HandState(ownerID: id, cards: [])
            
            // ✅ Tick-based：自動標記變化，等待 tick 批次同步
            // ✅ Event-driven：手動調用 syncNow() 立即同步
            await ctx.syncNow()  // 或讓系統自動處理（如果有 Tick）
            
            // Late join：返回完整快照
            let snapshot = syncEngine.snapshot(for: id, from: state)
            return .success(.joinResult(JoinResponse(landID: ctx.landID, state: snapshot)))
            
        case .attack(let attacker, let target, let damage):
            state.players[target]?.hpCurrent -= damage
            
            // ✅ Tick-based：自動標記變化，等待 tick 批次同步
            // ✅ Event-driven：手動調用 syncNow() 立即同步
            // 重要操作可以強迫立即同步
            await ctx.syncNow()
            
            return .success(.empty)
            
        default:
            return await handleOtherAction(&state, action, ctx)
        }
    }
    
    // 2️⃣ 遊戲規則：Event 處理（混合模式）
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

### 語法示例（未來版本：更明確的三職責分組）

未來的 DSL 語法可能會更明確地分組為三個職責：

```swift
@Land(RoomState.self)
struct RoomLand {
    // 1️⃣ 大門規則：誰可以進來看這棵樹
    AccessControl {
        AllowPublic()              // 或 OnlyVIP(), OnlyTeacher(), ...
        MaxPlayers(10)
        // 未來可擴展：權限檢查、角色限制等
    }
    
    // 2️⃣ 遊戲規則：提供哪些功能讓你操作這棵樹
    OnJoin { state, ctx in
        // 玩家加入時的處理
    }
    
    OnLeave { state, ctx in
        // 玩家離開時的處理
    }
    
    Action("attack") { state, action, ctx in
        // 攻擊 Action 處理
    }
    
    Action("sendChat") { state, action, ctx in
        // 聊天 Action 處理
    }
    
    AllowedClientEvents {
        ClientEvent.playerReady
        ClientEvent.heartbeat
    }
    
    // 3️⃣ 營業時間：這個樂園的生命週期和運行規則（Lifetime Management）
    Lifetime {
        // 開園時機：第一個人進來才建立（Lazy initialization）
        CreateOnFirstJoin()
        
        // 運行配置：Tick 頻率和處理邏輯
        Tick(every: .milliseconds(50)) { state, ctx in
            // Tick handler：每 50ms 執行一次
            await handleTick(&state, ctx)
        }
        
        // 持久化策略：定期存檔
        PersistSnapshot(every: .seconds(30))    // 每 30 秒存檔一次
        
        // 關園規則：沒人了 5 分鐘後自動銷毀
        DestroyWhenEmpty(after: .minutes(5))
        
        // 可選：關閉前的最後處理（存檔、通知等）
        OnShutdown { state in
            await saveFinalState(state)
        }
    }
}
```

**注意**：目前版本的 DSL 已經涵蓋了三個核心職責，但語法較為扁平化。未來版本可能會採用更明確的分組結構，使三個職責更加清晰。

### Land DSL 元件（設計概念）

```swift
public protocol LandNode {}

public struct ConfigNode: LandNode {
    public var maxPlayers: Int?
    public var tickInterval: Duration?
    public var idleTimeout: Duration?
    // 注意：baseURL 和 webSocketURL 已移除
    // 網路層細節應該在 Transport 層處理，而不是在 StateTree/Land 層
}

// Action 節點：支援統一 Action 型別或特定 Action case
public struct ActionHandlerNode<C>: LandNode {
    public let handler: (inout StateTree, C, LandContext) async -> ActionResult
}

// 特定 Action case 的節點（用於簡單的 Action）
public struct SpecificActionHandlerNode<C>: LandNode {
    public let handler: (inout StateTree, C, LandContext) async -> ActionResult
}

// Event 節點：支援統一 Event 型別或特定 ClientEvent case
public struct OnEventNode<E>: LandNode {
    public let handler: (inout StateTree, E, LandContext) async -> Void
}

// 特定 ClientEvent case 的節點（用於簡單的 Event）
public struct OnSpecificEventNode<E>: LandNode {
    public let handler: (inout StateTree, E, LandContext) async -> Void
}
```

配合 `@resultBuilder`：

```swift
@resultBuilder
public enum LandDSL {
    public static func buildBlock(_ components: LandNode...) -> [LandNode] {
        components
    }
}

public struct LandDefinition<State> {
    public let id: String
    public let nodes: [LandNode]
}

// 核心函數：Land
public func Land<State>(
    _ id: String,
    using stateType: State.Type,
    @LandDSL _ content: () -> [LandNode]
) -> LandDefinition<State> {
    LandDefinition(id: id, nodes: content())
}

// 語義化別名
public typealias App<State> = Land<State>
public typealias Feature<State> = Land<State>
```

### 三個核心職責與 DSL 元件的對應

將 Land 的三個核心職責映射到現有的 DSL 元件：

| 核心職責 | 對應的 DSL 元件 | 說明 |
|---------|---------------|------|
| **1️⃣ 大門規則** | `ConfigNode` 中的 `maxPlayers` | 控制誰可以進入、人數上限 |
| | 未來可擴展：`AccessControlNode` | 權限檢查、角色限制等 |
| **2️⃣ 遊戲規則** | `ActionHandlerNode` / `SpecificActionHandlerNode` | 定義可用的 Action 操作 |
| | `OnEventNode` / `OnSpecificEventNode` | 定義可處理的 Event |
| | `AllowedClientEvents` | 限制 Client 可發送的 Event |
| | `OnJoin` / `OnLeave` (未來) | 玩家加入/離開時的處理 |
| **3️⃣ 營業時間<br>（生命週期管理）** | `ConfigNode` 中的 `tickInterval` | Tick 頻率（如何運行） |
| | `ConfigNode` 中的 `idleTimeout` | 空閒超時（何時銷毀） |
| | `OnTick` (未來) | Tick 處理邏輯 |
| | 未來可擴展：`LifetimeNode` | 完整生命週期管理：<br>• 開園時機（Lazy/Eager 建立）<br>• 運行配置（Tick 頻率、存檔間隔）<br>• 關園規則（銷毀條件、保留時間）<br>• 持久化策略（是否存檔、replay/log） |

**現有實現**：目前的 DSL 將這三個職責整合在 `ConfigNode` 和各種 handler 節點中。  
**未來方向**：可能會採用更明確的分組結構（如 `AccessControl`、`Lifetime`），使三個職責更加清晰和易於理解。

---

## Action 處理：Action DSL

### Action 型別定義

```swift
enum GameAction: Codable {
    // 查詢操作
    case getPlayerHand(PlayerID)
    case canAttack(PlayerID, target: PlayerID)
    case getLandInfo
    
    // 需要結果的狀態修改
    case join(playerID: PlayerID, name: String)
    case drawCard(playerID: PlayerID)
    case attack(attacker: PlayerID, target: PlayerID, damage: Int)
}

enum ActionResult: Codable {
    case success(ActionResultData)
    case failure(String)
}

enum ActionResultData: Codable {
    case joinResult(JoinResponse)
    case hand([Card])
    case card(Card)
    case landInfo(LandInfo)
    case empty
}

struct JoinResponse: Codable {
    let landID: String
    let state: StateSnapshot?  // 可選：用於 late join
}
```

### Action DSL 寫法（混合模式）

為了避免 handler 過於肥大，支援兩種寫法：

#### 方式 1：針對特定 Action 的獨立 Handler（推薦用於簡單邏輯）

```swift
// 使用 Land（核心名稱）
let matchLand = Land("match-3", using: GameStateTree.self) {
    Config { ... }
    
    // 簡單的查詢 Action：用獨立 handler
    Action(GameAction.getPlayerHand) { state, id, ctx -> ActionResult in
        return .success(.hand(state.hands[id]?.cards ?? []))
    }
    
    Action(GameAction.canAttack) { state, (attacker, target), ctx -> ActionResult in
        guard let attackerState = state.players[attacker],
              let targetState = state.players[target] else {
            return .failure("Player not found")
        }
        let canAttack = attackerState.hpCurrent > 0 && targetState.hpCurrent > 0
        return .success(.empty)  // 或定義 CanAttackResponse
    }
    
    // 複雜的 Action：用統一 handler 或提取到函數
    Action(GameAction.join) { state, (id, name), ctx -> ActionResult in
        return await handleJoin(&state, id, name, ctx)
    }
}
```

#### 方式 2：統一的 Action Handler（適合複雜邏輯或需要共享邏輯）

```swift
let matchLand = Land("match-3", using: GameStateTree.self) {
    Config { ... }
    
    // 複雜邏輯用統一 handler
    Action(GameAction.self) { state, action, ctx -> ActionResult in
        return await handleAction(&state, action, ctx)
    }
}

// 提取複雜邏輯到獨立函數
private func handleAction(
    _ state: inout GameStateTree,
    _ action: GameAction,
    _ ctx: LandContext
) async -> ActionResult {
    switch action {
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
    _ ctx: LandContext
) async -> ActionResult {
    state.players[id] = PlayerState(name: name, hpCurrent: 100, hpMax: 100)
    state.hands[id] = HandState(ownerID: id, cards: [])
    let snapshot = syncEngine.snapshot(for: id, from: state)
    await ctx.sendEvent(.fromServer(.stateUpdate(snapshot)), to: .all)
    return .success(.joinResult(JoinResponse(landID: ctx.landID, state: snapshot)))
}
```

#### 方式 3：混合使用（推薦）

結合兩種方式的優點：

```swift
let matchLand = Land("match-3", using: GameStateTree.self) {
    Config { ... }
    
    // 簡單的查詢 Action：用獨立 handler
    Action(GameAction.getPlayerHand) { state, id, ctx -> ActionResult in
        return .success(.hand(state.hands[id]?.cards ?? []))
    }
    
    Action(GameAction.canAttack) { state, (attacker, target), ctx -> ActionResult in
        guard state.players[attacker] != nil,
              state.players[target] != nil else {
            return .failure("Player not found")
        }
        return .success(.empty)
    }
    
    // 複雜的狀態修改 Action：用統一 handler
    Action(GameAction.self) { state, action, ctx -> ActionResult in
        switch action {
        case .join(let id, let name):
            return await handleJoin(&state, id, name, ctx)
        case .drawCard(let id):
            return await handleDrawCard(&state, id, ctx)
        case .attack(let attacker, let target, let damage):
            return await handleAttack(&state, attacker, target, damage, ctx)
        default:
            return .failure("Unknown Action")
        }
    }
}
```

**建議**：
- 簡單的查詢 Action（如 `getPlayerHand`、`canAttack`）→ 使用 `Action(GameAction.xxx)`
- 複雜的狀態修改 Action（如 `join`、`drawCard`、`attack`）→ 使用 `Action(GameAction.self)` 或提取到函數
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
// 使用 Land（核心名稱）
let matchLand = Land("match-3", using: GameStateTree.self) {
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
let matchLand = Land("match-3", using: GameStateTree.self) {
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
    _ ctx: LandContext
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
    _ ctx: LandContext
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
let matchLand = Land("match-3", using: GameStateTree.self) {
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

在 Action handler 或內部邏輯中，Server 可以自由推送 ServerEvent（**不受 AllowedClientEvents 限制**）：

```swift
// 在任何 handler 中，Server 可以自由發送 ServerEvent
await ctx.sendEvent(.fromServer(.stateUpdate(snapshot)), to: .all)
await ctx.sendEvent(.fromServer(.gameEvent(.damage(from: attacker, to: target, amount: 10))), to: .all)
await ctx.sendEvent(.fromServer(.systemMessage("Private message")), to: .player(playerID))

// 不需要在 AllowedClientEvents 中定義這些 ServerEvent
```

### LandContext（提供 sendEvent / service / random 等）

**設計原則**：LandContext **不應該**知道 Transport 的存在，WebSocket 細節不應該暴露到 StateTree 層。

**設計模式**：LandContext 採用 **Request-scoped Context** 模式，類似 NestJS 的 Request Context。

#### 類似 NestJS Request Context

LandContext 的設計概念類似 NestJS 的 Request Context：

| 特性 | NestJS Request Context | StateTree LandContext |
|------|----------------------|----------------------|
| **建立時機** | 每個 HTTP 請求 | 每個 Action/Event 請求 |
| **生命週期** | 請求開始 → 請求結束 | 請求開始 → 請求結束 |
| **包含資訊** | user、params、headers、ip 等 | playerID、clientID、sessionID、landID 等 |
| **傳遞方式** | Dependency Injection | 作為參數傳遞給 handler |
| **釋放時機** | 請求處理完成後 | 請求處理完成後 |

**關鍵點**：
- ✅ **請求級別**：每次 Action/Event 請求建立一個新的 LandContext
- ✅ **不持久化**：處理完成後釋放，不保留在記憶體中
- ✅ **資訊集中**：請求相關資訊（playerID、clientID、sessionID）集中在 context 中
- ✅ **請求隔離**：每個請求有獨立的 context，不會互相干擾

```swift
// ✅ 正確：LandContext 不包含 Transport
public struct LandContext {
    public let landID: String
    public let playerID: PlayerID      // 帳號識別（用戶身份）
    public let clientID: ClientID      // 裝置識別（客戶端實例，應用端提供）
    public let sessionID: SessionID    // 會話識別（動態生成，用於追蹤）
    public let services: LandServices  // 服務抽象，不依賴 HTTP
    
    // ❌ 移除：public let transport: GameTransport
    
    // ✅ 推送 Event（透過閉包委派，不暴露 Transport）
    public func sendEvent(_ event: GameEvent, to target: EventTarget) async {
        // 實作在 Runtime 層（LandActor），不暴露 Transport 細節
        await sendEventHandler(event, target)
    }
    
    // ✅ 手動強迫立即同步狀態（無論是否有 Tick）
    public func syncNow() async {
        await syncHandler()
    }
    
    // ✅ 標記狀態變化（Tick-based 模式使用）
    public func markDirty(_ path: String? = nil) {
        // 標記變化，等待 tick 批次同步
        // 實作在 Runtime 層
    }
    
    // ✅ 透過閉包委派，不暴露 Transport
    private let sendEventHandler: (GameEvent, EventTarget) async -> Void
    private let syncHandler: () async -> Void
    
    internal init(
        landID: String,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID,
        services: LandServices,
        sendEventHandler: @escaping (GameEvent, EventTarget) async -> Void,
        syncHandler: @escaping () async -> Void
    ) {
        self.landID = landID
        self.playerID = playerID
        self.clientID = clientID
        self.sessionID = sessionID
        self.services = services
        self.sendEventHandler = sendEventHandler
        self.syncHandler = syncHandler
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

#### LandContext 的生命週期

**重要**：LandContext 不是「每個玩家有一個」，而是「每次請求建立一個」。

```swift
// 範例：Alice 發送多個 Action

// 請求 1：Alice 發送 join Action
// ├─ 建立 LandContext #1
// │  ├─ playerID: "alice-123"
// │  ├─ clientID: "device-mobile-001"
// │  └─ sessionID: "session-001"
// └─ 處理完成後，LandContext #1 被釋放

// 請求 2：Alice 發送 attack Action
// ├─ 建立 LandContext #2
// │  ├─ playerID: "alice-123"      (相同)
// │  ├─ clientID: "device-mobile-001" (相同)
// │  └─ sessionID: "session-001"    (相同)
// └─ 處理完成後，LandContext #2 被釋放
```

**設計要點**：
1. **請求級別**：每次 Action/Event 請求建立一個新的 LandContext
2. **不持久化**：處理完成後釋放，不保留在記憶體中
3. **輕量級**：只包含該請求需要的資訊
4. **請求隔離**：每個請求有獨立的 context，不會互相干擾

// 服務抽象（不依賴 HTTP 細節）
public struct LandServices {
    public let timelineService: TimelineService?
    public let userService: UserService?
    // ... 其他服務（可選）
}

// 服務協議（不依賴 HTTP）
protocol TimelineService {
    func fetch(page: Int) async throws -> [Post]
}

// 實作時可以選擇 HTTP、gRPC、或其他方式
// 這些實作細節在 Transport 層注入，不在 Land 定義中
struct HTTPTimelineService: TimelineService {
    let baseURL: String
    func fetch(page: Int) async throws -> [Post] {
        // HTTP 實作細節在這裡
    }
}
```

### Tick Handler 實作範例

**設計原則**：OnTick handler 應該簡潔，複雜邏輯拆分成獨立函數。

```swift
// ✅ 推薦：OnTick 只調用函數，邏輯拆分到獨立函數
let gameLand = Land("game-room", using: GameStateTree.self) {
    Config {
        Tick(every: .milliseconds(100))
    }
    
    // ✅ OnTick：簡潔，只調用函數
    OnTick { state, ctx in
        await handleTick(&state, ctx)
    }
    
    // Action Handler...
}

// ✅ 複雜邏輯拆分成獨立函數
private func handleTick(
    _ state: inout GameStateTree,
    _ ctx: LandContext
) async {
    // 1. AI 自動行動
    await handleAIActions(&state, ctx)
    
    // 2. 自動恢復
    handleAutoRegeneration(&state)
    
    // 3. 檢查遊戲狀態
    checkGameStatus(&state)
    
    // ✅ 狀態變化會自動標記，Tick 結束後自動批次同步
}

private func handleAIActions(
    _ state: inout GameStateTree,
    _ ctx: LandContext
) async {
    for (playerID, player) in state.players {
        guard player.isAI, player.hpCurrent > 0 else { continue }
        
        let action = await aiController.decideAction(for: playerID, state: state)
        executeAction(action, in: &state)
    }
}

private func handleAutoRegeneration(_ state: inout GameStateTree) {
    for (playerID, player) in state.players {
        if player.hpCurrent < player.hpMax {
            state.players[playerID]?.hpCurrent += 1
        }
    }
}

private func checkGameStatus(_ state: inout GameStateTree) {
    let alivePlayers = state.players.values.filter { $0.hpCurrent > 0 }
    if alivePlayers.count <= 1 {
        state.gameStatus = .finished
        state.winner = alivePlayers.first?.id
    }
}
```

**優勢**：
- ✅ **可讀性**：OnTick 簡潔，邏輯清晰
- ✅ **可測試**：每個函數可以獨立測試
- ✅ **可重用**：函數可以在其他地方重用
- ✅ **易維護**：邏輯分離，容易修改

**使用場景**：
- AI Battle：AI 自動決策和行動
- 自動恢復：血量、魔法值自動恢復
- 倒數計時：回合倒數、遊戲時間倒數
- 定期檢查：檢查遊戲結束條件、清理過期資料

---

