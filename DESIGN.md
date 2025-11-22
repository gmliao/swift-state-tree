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
2. [StateTree：RoomTree 結構](#statetree-roomtree-結構)
3. [同步規則 DSL：@Sync / SyncPolicy](#同步規則-dsl-sync-syncpolicy)
4. [Room DSL：房型宣告語法](#room-dsl-房型宣告語法)
5. [指令處理：On(Command) DSL](#指令處理-oncommand-dsl)
6. [Runtime 大致結構：RoomActor + SyncEngine](#runtime-大致結構-roomactor-syncengine)
7. [端到端範例：從 Command 到 Client JSON](#端到端範例從-command-到-client-json)
8. [語法速查表](#語法速查表)

---

## 整體理念與資料流

### 伺服器只做三件事

1. **維護唯一真實狀態**：RoomTree
2. **根據指令（Command）更新這棵樹**
3. **根據同步規則 SyncPolicy**，為每個玩家產生專屬 JSON，同步出去

### 資料流

```
Client 發 Command 
  → Server RoomActor
  → 更新 RoomTree
  → SyncEngine 依 @Sync 規則裁切
  → 為每個 Player 產生 JSON
  → 傳回各自 Client
  → Client 收 JSON 
  → 自己算 ViewModel / ViewState 
  → 畫 UI
```

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
    
    // Command 處理放在 On 區塊（下面一節詳細說明）
    On(GameCommand.self) { state, command, ctx in
        switch command {
        case let .join(playerID, name):
            state.players[playerID] = PlayerState(name: name, hpCurrent: 100, hpMax: 100)
            state.hands[playerID] = HandState(ownerID: playerID, cards: [])
            ctx.broadcast(.systemText("\(name) joined"))
            
        case .start:
            state.round = 1
            ctx.broadcast(.systemText("Game started"))
            
        case let .attack(attacker, target, damage):
            guard var targetState = state.players[target] else { return }
            targetState.hpCurrent = max(0, targetState.hpCurrent - damage)
            state.players[target] = targetState
            ctx.broadcast(.damage(from: attacker, to: target, amount: damage))
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

public struct OnCommandNode<C>: RoomNode {
    public let handler: (inout RoomTree, C, RoomContext) -> Void
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

## 指令處理：On(Command) DSL

### Command 型別

```swift
enum GameCommand {
    case join(PlayerID, name: String)
    case start
    case attack(attacker: PlayerID, target: PlayerID, damage: Int)
}
```

### DSL 寫法

```swift
On(GameCommand.self) { state, command, ctx in
    switch command {
    case let .join(playerID, name):
        state.players[playerID] = PlayerState(name: name, hpCurrent: 100, hpMax: 100)
        ctx.broadcast(.systemText("\(name) 加入了房間"))
        
    case .start:
        state.round = 1
        ctx.broadcast(.systemText("遊戲開始"))
        
    case let .attack(attacker, target, damage):
        guard var targetState = state.players[target] else { return }
        targetState.hpCurrent = max(0, targetState.hpCurrent - damage)
        state.players[target] = targetState
        ctx.broadcast(.damage(from: attacker, to: target, amount: damage))
    }
}
```

### RoomContext（提供 broadcast / service / random 等）

```swift
public struct RoomContext {
    public let roomID: String
    public let services: RoomServices
    public let transport: GameTransport
    
    public func broadcast(_ event: OutgoingEvent) {
        Task {
            await transport.broadcast(event, in: roomID)
        }
    }
    
    public func send(to player: PlayerID, _ event: OutgoingEvent) {
        Task {
            await transport.send(event, to: player, in: roomID)
        }
    }
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
    
    func handle(_ command: GameCommand, from player: PlayerID) async {
        // 1. 更新 state（呼叫 On handler）
        applyCommand(command, from: player)
        
        // 2. 對所有玩家同步當前狀態（依 @Sync 規則）
        let players = Array(state.players.keys)
        for pid in players {
            let payload = try syncEngine.snapshot(for: pid, from: state)
            await ctx.transport.send(.stateUpdate(payload), to: pid, in: ctx.roomID)
        }
    }
    
    private func applyCommand(_ command: GameCommand, from player: PlayerID) {
        // pseudo：從 def.nodes 找 OnCommandNode<GameCommand>，然後執行 handler
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

## 端到端範例：從 Command 到 Client JSON

### 流程

1. **Client A 送**：`join(playerID: "A", name: "Alice")`

2. **RoomActor 收到，呼叫 applyCommand**：
   - 更新 `state.players["A"]`
   - 更新 `state.hands["A"]`

3. **SyncEngine.snapshot(for: "A", from: state)**：
   - `players`：broadcast → 全部輸出
   - `hands`：perPlayer(ownerID) → 只輸出 A 的
   - `hiddenDeck`：serverOnly → 不輸出

4. **SyncEngine.snapshot(for: "B", from: state)**：
   - `players`：broadcast → 全部輸出
   - `hands`：perPlayer(ownerID) → 只輸出 B 的（此時可能不存在或空）

5. **Client 收到 JSON，自行計算 UI**：

```swift
// Client (SwiftUI 例)
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

### 2. Room 定義

```swift
let room = Room("match-3", using: RoomTree.self) {
    Config {
        MaxPlayers(4)
        Tick(every: .milliseconds(100))
    }
    
    On(GameCommand.self) { state, command, ctx in
        // ... 更新 state + broadcast event ...
    }
}
```

### 3. Command 例子

```swift
enum GameCommand {
    case join(PlayerID, name: String)
    case start
    case attack(attacker: PlayerID, target: PlayerID, damage: Int)
}
```

### 4. Context 介面（伺服端）

```swift
ctx.broadcast(.systemText("xxx"))
ctx.send(to: playerID, .privateMessage("yyy"))
```

---

## 後續實作建議

如果之後要實作，可以拆成：

- **SwiftStateTreeCore 模組**：RoomTree、@Sync、SyncPolicy
- **SwiftStateTreeServer 模組**：RoomDefinition、RoomActor、SyncEngine、RoomServices、GameTransport

再加一份「專案目錄結構建議」，讓你直接在 Xcode 裡開 package 起手。

