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

```
StateTree 狀態變化
  → SyncEngine 依 @Sync 規則裁切
  → 為每個 Player 產生 JSON
  → 透過 Event 推送給 Client
  → Client 更新本地狀態
```

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

