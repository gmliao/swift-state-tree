# 核心概念：整體理念、StateTree、同步規則

> 本文檔說明 SwiftStateTree 的核心設計理念

## 整體理念與資料流

### 伺服器只做三件事

1. **維護唯一真實狀態**：StateTree（狀態樹）
2. **根據 RPC 和 Event 更新這棵樹**
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

**兩種同步模式**：

1. **Tick-based（自動批次更新）**：
```
StateTree 狀態變化
  → 標記為「需要同步」
  → 等待 Tick（例如 100ms）
  → SyncEngine 依 @Sync 規則裁切
  → 分層計算：broadcast（共用）+ perPlayer（個別）
  → Merge 合併差異
  → 透過 Event 推送給 Client（path-based diff）
  → Client 更新本地狀態
```

2. **Event-driven（手動強迫刷新）**：
```
StateTree 狀態變化
  → 手動調用 syncNow()
  → SyncEngine 依 @Sync 規則裁切
  → 分層計算：broadcast（共用）+ perPlayer（個別）
  → Merge 合併差異
  → 透過 Event 推送給 Client（path-based diff）
  → Client 更新本地狀態
```

**差異計算機制**：
- ✅ **緩存上次快照**：broadcast 部分共用一份，perPlayer 部分每個玩家一份
- ✅ **比較差異**：新舊快照比較，找出變化的路徑
- ✅ **分層計算**：先計算 broadcast（所有人共用），再計算 perPlayer（每個人不同）
- ✅ **Merge 合併**：合併 broadcast 和 perPlayer 的差異
- ✅ **Path-based diff**：只發送變化的部分（path + value + operation）

---

## StateTree：狀態樹結構

### 目標

- 只一棵樹 `StateTree` 表示整個領域狀態
- 不再額外定一個 `UIGameState` 在伺服器
- UI 專用計算丟給 Client

### StateTree DSL 設計

StateTree 採用 **Property Wrapper + Macro** 的設計方式：

- **語法**：使用 `@StateTreeBuilder` macro 標記 struct
- **同步欄位**：使用 `@Sync` property wrapper 標記需要同步的欄位
- **內部欄位**：使用 `@Internal` property wrapper 標記伺服器內部使用的欄位
- **計算屬性**：原生支援，自動跳過驗證

### 範例

```swift
// 單一權威狀態樹（遊戲場景範例）
@StateTreeBuilder
struct GameStateTree: StateTreeProtocol {
    // 所有玩家的公開狀態（血量、名字等），可以廣播給大家
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
    
    // 回合資訊，所有人都可以知道現在輪到誰
    @Sync(.broadcast)
    var turn: PlayerID?
    
    // 手牌：每個玩家只看得到自己的
    @Sync(.perPlayerDictionaryValue())
    var hands: [PlayerID: HandState] = [:]
    
    // 伺服器內部用，不同步給任何 Client（但仍會被同步引擎知道）
    @Sync(.serverOnly)
    var hiddenDeck: [Card] = []
    
    // 伺服器內部計算用的暫存值（不需要同步引擎知道）
    @Internal
    var lastProcessedTimestamp: Date = Date()
    
    @Internal
    var aiDecisionCache: [PlayerID: AIDecision] = [:]
    
    // 其他純邏輯狀態（例如倒數、回合數等）
    @Sync(.broadcast)
    var round: Int = 0
    
    // 計算屬性：自動跳過驗證，不需要標記
    var totalPlayers: Int {
        players.count
    }
    
    var averageHP: Double {
        let total = players.values.reduce(0) { $0 + $1.hpCurrent }
        return Double(total) / Double(players.count)
    }
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

### 欄位標記規則

StateTree 中的欄位需要明確標記其用途：

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

`@StateTreeBuilder` macro 會自動驗證：

- ✅ **`@Sync` 標記的欄位**：需要同步（broadcast/perPlayer/serverOnly）
- ✅ **`@Internal` 標記的欄位**：伺服器內部使用，跳過驗證
- ✅ **Computed properties**：自動跳過驗證
- ❌ **未標記的 stored property**：編譯錯誤（必須明確標記）

**設計原則**：
- 所有 stored properties 必須明確標記用途
- `@Sync(.serverOnly)` vs `@Internal` 的差異：
  - `@Sync(.serverOnly)`：同步引擎知道這個欄位存在，但不輸出給 Client
  - `@Internal`：完全不需要同步引擎知道，純粹伺服器內部使用

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

### @StateTreeBuilder Macro

```swift
/// Macro 會自動：
/// 1. 驗證所有 stored properties 都有 @Sync 或 @Internal 標記
/// 2. 生成 getSyncFields() 的實作（不再需要 runtime reflection）
/// 3. 生成 validateSyncFields() 的實作
/// 4. 提供編譯時檢查
@attached(member, names: arbitrary)
public macro StateTreeBuilder() = #externalMacro(
    module: "SwiftStateTreeMacros",
    type: "StateTreeBuilderMacro"
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
   ├── 定義 Macro：@StateTreeBuilder
   └── 使用 Macro：@StateTreeBuilder struct GameStateTree { ... }
   
   SwiftStateTreeMacros (獨立模組)
   ├── 實作 Macro：StateTreeBuilderMacro
   └── 依賴 SwiftSyntax
   ```

**目前的實作狀態**：
- ✅ `@Sync` 和 `@Internal` property wrapper 已實作
- ✅ 驗證邏輯已實作（使用 runtime reflection）
- ⏳ `@StateTreeBuilder` macro 待實作（需要建立獨立的 `SwiftStateTreeMacros` 模組）

**暫時方案**：
目前使用 runtime reflection 來實作 `getSyncFields()` 和 `validateSyncFields()`，功能完整但效能較差。未來實作 Macro 後，這些方法會由 Macro 在編譯時生成，效能會大幅提升。

**優勢**（實作 Macro 後）：
- ✅ **編譯時檢查**：Macro 在編譯期驗證，無需 runtime reflection
- ✅ **效能提升**：`getSyncFields()` 由 Macro 生成，避免 Mirror 反射
- ✅ **型別安全**：編譯期就能發現缺少 `@Sync` 的欄位
- ✅ **語法自然**：像定義普通 struct，學習成本低

### SwiftStateTreeMacros 模組

`SwiftStateTreeMacros` 是 `@StateTreeBuilder` macro 的實作模組，作為獨立的 Swift Package 存在。

#### 模組結構

```
SwiftStateTreeMacros/
├── Package.swift              # Macro 模組定義
├── Sources/
│   └── SwiftStateTreeMacros/
│       └── StateTreeBuilderMacro.swift  # Macro 實作
└── Tests/
    └── SwiftStateTreeMacrosTests/
        └── StateTreeBuilderMacroTests.swift
```

#### 依賴關係

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/apple/swift-syntax.git", from: "509.0.0")
]
```

#### Macro 實作功能

`StateTreeBuilderMacro` 會執行以下操作：

1. **驗證所有 stored properties**：
   - 檢查每個 stored property 是否有 `@Sync` 或 `@Internal` 標記
   - 如果發現未標記的 stored property，產生編譯錯誤

2. **生成 `getSyncFields()` 方法**：
   ```swift
   // 編譯前（開發者寫的）
   @StateTreeBuilder
   struct GameStateTree: StateTreeProtocol {
       @Sync(.broadcast)
       var players: [PlayerID: PlayerState] = [:]
   }
   
   // 編譯後（Macro 展開的）
   struct GameStateTree: StateTreeProtocol {
       @Sync(.broadcast)
       var players: [PlayerID: PlayerState] = [:]
       
       // Macro 自動生成
       public func getSyncFields() -> [SyncFieldInfo] {
           return [
               SyncFieldInfo(name: "players", policyType: "broadcast")
           ]
       }
   }
   ```

3. **生成 `validateSyncFields()` 方法**：
   ```swift
   // Macro 自動生成
   public func validateSyncFields() -> Bool {
       // 編譯時已驗證，直接返回 true
       return true
   }
   ```

#### 使用方式

在主專案的 `Package.swift` 中：

```swift
dependencies: [
    .package(path: "../SwiftStateTree"),
    // SwiftStateTreeMacros 會自動被引入（作為 SwiftStateTree 的依賴）
]
```

在程式碼中使用：

```swift
import SwiftStateTree

@StateTreeBuilder  // 使用 Macro
struct GameStateTree: StateTreeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
}
```

#### 編譯流程

1. **編譯時**：
   - 編譯器發現 `@StateTreeBuilder` macro
   - 調用 `SwiftStateTreeMacros` 模組中的 `StateTreeBuilderMacro`
   - Macro 展開，生成 `getSyncFields()` 和 `validateSyncFields()` 方法
   - 驗證所有 stored properties 都有適當標記

2. **執行時**：
   - 使用 Macro 生成的程式碼，無需 runtime reflection
   - 效能大幅提升

#### 與主模組的關係

- **SwiftStateTree**（主模組）：
  - 定義 `@StateTreeBuilder` macro（使用 `#externalMacro`）
  - 定義 `StateTreeProtocol`、`@Sync`、`@Internal` 等
  - 使用者直接 import 這個模組

- **SwiftStateTreeMacros**（獨立模組）：
  - 實作 `StateTreeBuilderMacro`
  - 依賴 `SwiftSyntax`
  - 只在編譯時使用，不會出現在執行時依賴中

---

## StateTree vs Realm：設計理念對比

### 最終結論

**StateTree → 宣告式 DSL（Declarative DSL）**

- **描述「這是什麼狀態」**：定義資料結構
- **描述「同步規則」**：定義哪些欄位如何同步
- **使用 Property Wrapper + Macro**：`@Sync`、`@Internal`、`@StateTreeBuilder`
- **適合作資料模型**：純資料結構，不包含行為邏輯

```swift
@StateTreeBuilder
struct GameStateTree: StateTreeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: PlayerState] = [:]
    
    @Internal
    var cache: [String: Any] = [:]
}
```

**Realm → Builder DSL（Result Builder DSL）**

- **描述「這個領域要做什麼」**：定義行為邏輯
- **RPC handler**：處理客戶端請求
- **Event handler**：處理事件
- **Tick handler**：定期執行邏輯
- **Config**：領域配置
- **適合作行為邏輯**：定義領域的行為和處理流程

```swift
let matchRealm = Realm("match-3", using: GameStateTree.self) {
    Config {
        MaxPlayers(4)
        Tick(every: .milliseconds(100))
    }
    
    RPC(GameRPC.join) { state, (id, name), ctx -> RPCResponse in
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
- ✅ **資料與行為分離**：StateTree 定義資料，Realm 定義行為
- ✅ **語法風格一致**：StateTree 用 Property Wrapper，Realm 用 Result Builder
- ✅ **職責清晰**：StateTree 是「什麼」，Realm 是「如何做」

