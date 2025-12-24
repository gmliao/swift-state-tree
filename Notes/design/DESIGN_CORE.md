# 核心概念：整體理念、StateTree、同步規則

> 本文檔說明 SwiftStateTree 的核心設計理念
> 
> 相關文檔：
> - [DESIGN_SYNC_FIRSTSYNC.md](./DESIGN_SYNC_FIRSTSYNC.md) - 首次同步機制（First Sync）
> - [DESIGN_POLICY_FILTERING.md](./DESIGN_POLICY_FILTERING.md) - Policy 過濾機制：篩子層層過濾與樹的深度優先遍歷

## 整體理念與資料流

### 伺服器只做三件事

1. **維護唯一真實狀態**：StateTree（狀態樹，包含一個 StateNode 作為根部）
2. **根據 Action 和 Event 更新這棵樹**
3. **根據同步規則 SyncPolicy**，為每個玩家產生專屬 JSON，同步出去（支援遞迴過濾）

### 資料流

#### Action 流程（Client -> Server，有 Response）

```
Client 發 Action
  → Server LandKeeper 處理
  → 更新 StateTree（可選，更新根部的 StateNode）
  → 返回 Response（可包含狀態快照，用於 late join）
  → Client 收到 Response
```

#### Event 流程（雙向，無 Response）

```
Client -> Server Event:
  Client 發 Event
    → Server LandKeeper 處理
    → 可選：更新 StateTree（更新根部的 StateNode）/ 觸發邏輯

Server -> Client Event:
  Server 推送 Event
    → 所有相關 Client 接收
    → Client 更新本地狀態 / UI
```

#### 狀態同步流程

**兩種同步模式**：

1. **Tick-based（自動批次更新）**：
```
StateTree（根部 StateNode）狀態變化
  → 標記為「需要同步」
  → 等待 Tick（例如 100ms）
  → SyncEngine 依 @Sync 規則裁切（支援遞迴過濾）
  → ⏳ 分層計算：broadcast（共用）+ perPlayer（個別）
  → ⏳ Merge 合併差異
  → ⏳ 透過 Event 推送給 Client（path-based diff）
  → Client 更新本地狀態
```

2. **Event-driven（手動強迫刷新）**：
```
StateTree（根部 StateNode）狀態變化
  → 手動調用 syncNow()
  → SyncEngine 依 @Sync 規則裁切（支援遞迴過濾）
  → ⏳ 分層計算：broadcast（共用）+ perPlayer（個別）
  → ⏳ Merge 合併差異
  → ⏳ 透過 Event 推送給 Client（path-based diff）
  → Client 更新本地狀態
```

**當前實現狀態**：
- ✅ **完整快照生成**：`SyncEngine.snapshot(for:from:)` 已實現，可用於 late join
- ✅ **遞迴過濾**：支援巢狀 StateNode 的遞迴過濾，每個節點獨立套用 @Sync 政策
- ✅ **差異計算機制**：已實現
  - ✅ **緩存上次快照**：broadcast 部分共用一份，perPlayer 部分每個玩家一份
  - ✅ **比較差異**：新舊快照比較，找出變化的路徑
  - ✅ **分層計算**：先計算 broadcast（所有人共用），再計算 perPlayer（每個人不同）
  - ✅ **Merge 合併**：合併 broadcast 和 perPlayer 的差異
  - ✅ **Path-based diff**：只發送變化的部分（path + value + operation）
  - ✅ **First Sync 信號**：首次同步時返回 `StateUpdate.firstSync`，告知客戶端同步引擎已啟動

> **首次同步機制**：SwiftStateTree 採用「Join Snapshot + FirstSync + Diff」模式。
> 詳見 [DESIGN_SYNC_FIRSTSYNC.md](./DESIGN_SYNC_FIRSTSYNC.md)。

---

## 名詞定義與架構

### 核心概念

**StateTree（狀態樹）**：
- 包含一個 `StateNode` 作為根部的樹狀結構
- 表示整個領域的狀態
- 是單一來源真相（single source of truth）
- 可以長出多個 `StateNode`（支援巢狀結構）

**StateNode（狀態節點）**：
- 樹中的節點，可以巢狀遞迴
- 使用 `@StateNodeBuilder` macro 標記
- 實作 `StateNodeProtocol`
- 支援 `@Sync` 政策，可以進行遞迴過濾
- 可以是根節點（RootNode）或子節點

**State（狀態資料）**：
- 簡單的資料結構，不需要同步政策
- 使用 `@State` macro 標記
- 實作 `StateProtocol`（Codable + Sendable）
- 整包更新，不支援內部細分過濾

### 架構層級

```
StateTree（狀態樹）
└── StateNode（根節點，RootNode）
    ├── @Sync 欄位
    │   ├── 基本型別（Int, String, Bool 等）
    │   ├── State（簡單資料結構，整包更新）
    │   └── StateNode（巢狀節點，可遞迴過濾）
    │       ├── @Sync 欄位
    │       └── ...（可以無限巢狀）
    └── @Internal 欄位（伺服器內部使用）
```

### 使用場景對比

| 特性 | `@State` + `StateProtocol` | `@StateNodeBuilder` + `StateNodeProtocol` |
|------|---------------------------|------------------------------------------|
| 用途 | 簡單資料結構 | 需要同步政策的節點 |
| 同步方式 | 整包更新 | 可以細分過濾 |
| 支援 perPlayer | ✅ 可以（頂層） | ✅ 可以（頂層 + 遞迴） |
| 內部細分過濾 | ❌ 不行 | ✅ 可以（遞迴過濾） |
| 使用場景 | 純資料，整包同步 | 複雜結構，需要內部過濾 |

### StateTree DSL 設計

StateTree 採用 **Property Wrapper + Macro** 的設計方式：

- **根節點**：使用 `@StateNodeBuilder` macro 標記 struct（通常命名為 `*RootNode`）
- **子節點**：使用 `@StateNodeBuilder` macro 標記 struct（通常命名為 `*Node`）
- **資料結構**：使用 `@State` macro 標記 struct（通常命名為 `*State`）
- **同步欄位**：使用 `@Sync` property wrapper 標記需要同步的欄位
- **內部欄位**：使用 `@Internal` property wrapper 標記伺服器內部使用的欄位
- **計算屬性**：原生支援，自動跳過驗證

### 範例

#### 範例 1：使用 State（整包更新）

```swift
// 簡單資料結構：整包更新，不需要細分過濾
@State
struct PlayerState: StateProtocol {
    var name: String
    var hpCurrent: Int
    var hpMax: Int
}

@State
struct HandState: StateProtocol {
    var ownerID: PlayerID
    var cards: [Card]
}

// 根節點：StateTree 的根部
@StateNodeBuilder
struct GameStateRootNode: StateNodeProtocol {
    // 所有玩家的公開狀態（整包更新）
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
    
    // 手牌：每個玩家只看得到自己的（整包更新）
    @Sync(.perPlayerSlice())
    var hands: [PlayerID: HandState] = [:]
    
    // 回合資訊
    @Sync(.broadcast)
    var round: Int = 0
}
```

**行為**：
- `players` 是 `.broadcast` → 所有玩家看到完整的 `PlayerState`（整包）
- `hands` 是 `.perPlayerSlice()` → 每個玩家只看到自己的 `HandState`（整包）
- `PlayerState` 和 `HandState` 內部不會再細分過濾

**⚠️ 重要：必須使用系統提供的 CRUD 函數**

對於 Dictionary、Array 等集合類型，**必須通過 `@Sync` property wrapper 的 setter 來修改**，才能正確觸發 dirty tracking：

```swift
// ✅ 正確：使用 @Sync setter（自動標記 dirty）
state.players[playerID] = PlayerState(...)  // 會觸發 @Sync setter，自動標記 players 為 dirty
state.round = 1  // 會觸發 @Sync setter，自動標記 round 為 dirty
state.hands[playerID] = HandState(...)  // 會觸發 @Sync setter，自動標記 hands 為 dirty

// ❌ 錯誤：直接修改字典內容（不會觸發 dirty tracking）
// var dict = state.players  // 取得字典副本
// dict[playerID] = PlayerState(...)  // 修改副本
// state.players = dict  // 需要重新賦值才能觸發 setter，但這樣會丟失 dirty tracking
```

**為什麼必須使用系統提供的函數？**

1. **Dirty Tracking 依賴 Setter**：`@Sync` property wrapper 的 `wrappedValue` setter 會自動標記字段為 dirty
2. **直接修改不會觸發 Setter**：如果直接修改字典/數組的內部內容而不通過 setter，dirty tracking 無法檢測到變化
3. **優化版 Diff 的準確性**：優化版 diff（`useDirtyTracking: true`）只比較 dirty 字段，如果字段沒有被標記為 dirty，變化可能被忽略

**對於 ReactiveDictionary 和 ReactiveSet**

如果使用 `ReactiveDictionary` 或 `ReactiveSet`，它們內建了 dirty tracking，可以直接使用它們的方法：

```swift
@StateNodeBuilder
struct GameStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)
    var players: ReactiveDictionary<PlayerID, PlayerState> = ReactiveDictionary()
    
    @Sync(.broadcast)
    var activePlayers: ReactiveSet<PlayerID> = ReactiveSet()
}

// ✅ 正確：使用 ReactiveDictionary/ReactiveSet 的方法（自動標記 dirty）
state.players[playerID] = PlayerState(...)  // 自動標記 dirty
state.players.removeValue(forKey: playerID)  // 自動標記 dirty
state.activePlayers.insert(playerID)  // 自動標記 dirty
state.activePlayers.remove(playerID)  // 自動標記 dirty
```

#### 範例 2：使用 StateNode（可以細分過濾）

```swift
// 巢狀節點：需要內部細分過濾
@StateNodeBuilder
struct PlayerStateNode: StateNodeProtocol {
    @Sync(.broadcast)
    var position: Vec2
    
    @Sync(.broadcast)
    var hp: Int
    
    // 只有自己看到的東西（可以細分過濾）
    @Sync(.perPlayer { inventory, pid in inventory[pid] })
    var inventory: [PlayerID: [Item]]
}

// 根節點：StateTree 的根部
@StateNodeBuilder
struct RoomStateRootNode: StateNodeProtocol {
    // 整張 players 字典對所有人可見（裡面再細分）
    @Sync(.broadcast)
    var players: [PlayerID: PlayerStateNode] = [:]
}
```

**行為**：
- `players` 是 `.broadcast` → 所有玩家看到 `players` 字典
- 但每個 `PlayerStateNode` 會遞迴套用 `@Sync` 政策：
  - `position` 和 `hp` → 所有人可見（broadcast）
  - `inventory` → 只有該玩家可見（perPlayer，遞迴過濾）

#### 範例 3：混合使用

```swift
// 簡單資料結構（整包更新）
@State
struct Card: StateProtocol {
    let id: Int
    let suit: Int
    let rank: Int
}

// 巢狀節點（可以細分過濾）
@StateNodeBuilder
struct PlayerStateNode: StateNodeProtocol {
    @Sync(.broadcast) var name: String
    @Sync(.broadcast) var hp: Int
    @Sync(.perPlayer { ... }) var inventory: [PlayerID: [Item]]
}

// 根節點
@StateNodeBuilder
struct GameStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerStateNode] = [:]  // 可以遞迴過濾
    
    @Sync(.perPlayerSlice())
    var hands: [PlayerID: [Card]] = [:]  // Card 是 State，整包更新
}
```

> **StateTree 是單一來源真相（single source of truth）。**  
> StateTree 包含一個 StateNode 作為根部，可以長出多個 StateNode（支援巢狀）。  
> UI 只會收到「裁切後的 JSON 表示」。

### 欄位標記規則

StateNode 中的欄位需要明確標記其用途：

1. **`@Sync`**：需要同步的欄位（必須標記）
   - `.broadcast`：同步給所有 Client
   - `.serverOnly`：伺服器內部用，不同步給 Client（但仍會被同步引擎知道）
   - `.perPlayer(...)`：依玩家 ID 過濾後同步
   - `.masked(...)`：用 mask function 改寫值後同步
   - `.custom(...)`：完全客製的同步邏輯

2. **`@Internal`**：伺服器內部使用的欄位（可選標記）
   - 不需要同步給 Client
   - 不需要被同步引擎知道
   - 純粹伺服器內部計算用的暫存值、快取等
   - 驗證機制會自動跳過

3. **Computed Properties**：計算屬性（不需要標記）
   - 自動跳過驗證
   - 原生 Swift 支援，不需要特別處理

### 驗證規則

`@StateNodeBuilder` macro 會自動驗證：

- ✅ **`@Sync` 標記的欄位**：需要同步（broadcast/perPlayer/serverOnly）
- ✅ **`@Internal` 標記的欄位**：伺服器內部使用，跳過驗證
- ✅ **Computed properties**：自動跳過驗證
- ❌ **未標記的 stored property**：編譯錯誤（必須明確標記）

**設計原則**：
- 所有 stored properties 必須明確標記用途
- `@Sync(.serverOnly)` vs `@Internal` 的差異：
  - `@Sync(.serverOnly)`：同步引擎知道這個欄位存在，但不輸出給 Client
  - `@Internal`：完全不需要同步引擎知道，純粹伺服器內部使用

### 遞迴過濾機制

當 StateNode 包含其他 StateNode 時，會進行遞迴過濾：

```swift
@StateNodeBuilder
struct PlayerStateNode: StateNodeProtocol {
    @Sync(.broadcast) var position: Vec2
    @Sync(.perPlayer { ... }) var inventory: [PlayerID: [Item]]
}

@StateNodeBuilder
struct RoomStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerStateNode] = [:]
}
```

**過濾流程**：
1. `RoomStateRootNode.players` 是 `.broadcast` → 所有玩家看到字典
2. 字典中的每個 `PlayerStateNode` 會遞迴套用 `@Sync` 政策：
   - `position` → 所有人可見（broadcast）
   - `inventory` → 只有該玩家可見（perPlayer）

**與 State 的差異**：
- `State`（`@State` + `StateProtocol`）：整包更新，不支援遞迴過濾
- `StateNode`（`@StateNodeBuilder` + `StateNodeProtocol`）：支援遞迴過濾，可以細分

---

## 效能優化：@SnapshotConvertible Macro

### 概述

`@SnapshotConvertible` Macro 自動為使用者定義的型別生成 `SnapshotValueConvertible` protocol 實作，避免使用 runtime reflection（Mirror），大幅提升轉換效能。

### 使用方式

```swift
// 只需要標記 @SnapshotConvertible
@SnapshotConvertible
struct PlayerState: Codable {
    var name: String
    var hpCurrent: Int
    var hpMax: Int
}

// Macro 自動生成以下程式碼：
// extension PlayerState: SnapshotValueConvertible {
//     func toSnapshotValue() throws -> SnapshotValue {
//         return .object([
//             "name": .string(name),
//             "hpCurrent": .int(hpCurrent),
//             "hpMax": .int(hpMax)
//         ])
//     }
// }
```

### 效能優勢

1. **基本型別直接轉換**：String, Int, Bool 等基本型別直接生成轉換程式碼，完全避免 Mirror
2. **自動生成**：使用者只需標記，無需手寫任何程式碼
3. **編譯時生成**：型別安全，減少執行時錯誤
4. **遞迴優化**：巢狀結構會優先檢查是否實作 protocol，完全避免 Mirror

### 處理邏輯

Macro 會根據欄位型別生成不同的轉換程式碼：

- **基本型別**（String, Int, Bool 等）：直接生成 `.string(name)`, `.int(hpCurrent)` 等
- **Optional 型別**：使用 `try SnapshotValue.make(from: value)` 處理 nil
- **複雜型別**（Array, Dictionary, Struct 等）：使用 `try SnapshotValue.make(from: value)`，內部會優先檢查 protocol

### 適用場景

- ✅ 在 StateTree 中頻繁使用的巢狀結構
- ✅ 需要高效能轉換的使用者定義型別
- ✅ 複雜的多層級巢狀結構

### 與 make(from:) 的整合

`SnapshotValue.make(from:)` 會優先檢查型別是否實作 `SnapshotValueConvertible`：

```swift
public extension SnapshotValue {
    static func make(from value: Any) throws -> SnapshotValue {
        // Priority 1: Check protocol (best performance)
        if let convertible = value as? SnapshotValueConvertible {
            return try convertible.toSnapshotValue()
        }
        
        // Priority 2: Handle basic types directly
        // ...
        
        // Priority 3: Fallback to Mirror
        // ...
    }
}
```

這樣設計確保了：
- 實作 protocol 的型別：完全避免 Mirror（最佳效能）
- 基本型別：直接轉換（良好效能）
- 其他型別：使用 Mirror fallback（確保功能完整）

---

## 同步規則 DSL：@Sync / SyncPolicy

### 基本概念

`@Sync` 會標在 `StateNode` 的欄位上，定義這個欄位對同步引擎的策略。當欄位值是 `StateNode` 時，會進行遞迴過濾。

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

### @Sync Property Wrapper

```swift
@propertyWrapper
public struct Sync<Value: Sendable>: Sendable {
    public let policy: SyncPolicy<Value>
    public var wrappedValue: Value
    
    public init(wrappedValue: Value, _ policy: SyncPolicy<Value>) {
        self.wrappedValue = wrappedValue
        self.policy = policy
    }
}
```

### @Internal Property Wrapper

```swift
/// 標記為伺服器內部使用，不需要同步，也不需要驗證
@propertyWrapper
public struct Internal<Value: Sendable>: Sendable {
    public var wrappedValue: Value
    
    public init(wrappedValue: Value) {
        self.wrappedValue = wrappedValue
    }
}
```

### @StateNodeBuilder Macro

```swift
/// Macro 會自動：
/// 1. 驗證所有 stored properties 都有 @Sync 或 @Internal 標記
/// 2. 生成 getSyncFields() 的實作（不再需要 runtime reflection）
/// 3. 生成 validateSyncFields() 的實作
/// 4. 生成 snapshot(for:) 方法（支援遞迴過濾）
/// 5. 生成 broadcastSnapshot() 方法
/// 6. 提供編譯時檢查
@attached(member, names: arbitrary)
public macro StateNodeBuilder() = #externalMacro(
    module: "SwiftStateTreeMacros",
    type: "StateNodeBuilderMacro"
)
```

### @State Macro

```swift
/// Macro 會自動：
/// 1. 驗證 struct 符合 StateProtocol（Codable + Sendable）
/// 2. 提供編譯時檢查
/// 3. 不生成程式碼，只做驗證
@attached(peer)
public macro State() = #externalMacro(
    module: "SwiftStateTreeMacros",
    type: "StateMacro"
)
```

**為什麼 Macro 需要獨立模組？**

Swift Macro 的架構要求將 Macro 定義和實作分離：

1. **編譯器插件機制**：
   - Macro 實作需要作為編譯器插件（Compiler Plugin）執行
   - 編譯器在編譯過程中會調用獨立的插件來展開 Macro
   - 這需要 Macro 實作在獨立的 Swift Package 中

2. **依賴管理**：
   - Macro 實作依賴 `SwiftSyntax` 庫（用於解析和生成 Swift 程式碼的語法樹）
   - `SwiftSyntax` 是一個龐大的庫，編譯時間較長
   - 將 Macro 實作放在獨立模組中，可以避免主專案直接編譯 `SwiftSyntax`
   - 減少主專案的編譯時間和依賴複雜度

3. **程式碼隔離與安全性**：
   - Macro 的展開過程在安全的沙盒環境中進行
   - 與主專案的程式碼隔離，確保 Macro 執行不會直接影響主專案
   - 增強安全性和穩定性

4. **模組架構**：
   ```
   SwiftStateTree (主模組)
   ├── 定義 Macro：@StateNodeBuilder, @State, @SnapshotConvertible
   └── 使用 Macro：@StateNodeBuilder struct GameStateRootNode { ... }
   
   SwiftStateTreeMacros (獨立模組)
   ├── 實作 Macro：StateNodeBuilderMacro, StateMacro, SnapshotConvertibleMacro
   └── 依賴 SwiftSyntax
   ```

**目前的實作狀態**：
- ✅ `@Sync` 和 `@Internal` property wrapper 已實作
- ✅ `@StateNodeBuilder` macro 已實作（生成 snapshot 方法，支援遞迴過濾）
- ✅ `@State` macro 已實作（驗證 StateProtocol）
- ✅ `@SnapshotConvertible` macro 已實作（生成 SnapshotValueConvertible）

**優勢**：
- ✅ **編譯時檢查**：Macro 在編譯期驗證，無需 runtime reflection
- ✅ **效能提升**：`getSyncFields()` 和 `snapshot(for:)` 由 Macro 生成，避免 Mirror 反射
- ✅ **型別安全**：編譯期就能發現缺少 `@Sync` 的欄位
- ✅ **遞迴過濾**：支援巢狀 StateNode 的遞迴過濾
- ✅ **語法自然**：像定義普通 struct，學習成本低

---

## StateTree vs Land：設計理念對比

### 最終結論

**StateTree → 宣告式 DSL（Declarative DSL）**

- **描述「這是什麼狀態」**：定義資料結構
- **描述「同步規則」**：定義哪些欄位如何同步
- **使用 Property Wrapper + Macro**：`@Sync`、`@Internal`、`@StateTreeBuilder`
- **適合作資料模型**：純資料結構，不包含行為邏輯

```swift
@StateNodeBuilder
struct GameStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerStateNode] = [:]
    
    @Internal
    var cache: [String: Any] = [:]
}
```

**Land → Builder DSL（Result Builder DSL）**

- **描述「這個領域要做什麼」**：定義行為邏輯
- **Action handler**：處理客戶端請求
- **Event handler**：處理事件
- **Tick handler**：定期執行邏輯
- **Config**：領域配置
- **適合作行為邏輯**：定義領域的行為和處理流程

```swift
let matchLand = Land("match-3", using: GameStateTree.self) {
    Config {
        MaxPlayers(4)
        Tick(every: .milliseconds(100))
    }
    
    Action(GameAction.join) { state, (id, name), ctx -> ActionResult in
        state.players[id] = PlayerState(name: name, hpCurrent: 100, hpMax: 100)
        await ctx.syncNow()
        return .success(.joinResult(...))
    }
    
    On(ClientEvent.heartbeat) { state, timestamp, ctx in
        state.playerLastActivity[ctx.playerID] = timestamp
    }
}
```

**設計原則**：
- ✅ **資料與行為分離**：StateTree 定義資料，Land 定義行為
- ✅ **語法風格一致**：StateTree 用 Property Wrapper，Land 用 Result Builder
- ✅ **職責清晰**：StateTree 是「什麼」，Land 是「如何做」

